import Foundation

enum AudioLifecycleState: String, Sendable, Equatable {
    case inactive
    case starting
    case running
    case stopping
    case failed
    case sleeping
    case recovering
}

enum AudioLifecycleTrigger: String, Sendable, Equatable {
    case userEnabled
    case userDisabled
    case sleep
    case wake
    case deviceChange
    case configurationChange
    case helperTermination
    case shutdown
}

enum AudioLifecycleOutcome: String, Sendable, Equatable {
    case accepted
    case failed
    case ignored
}

struct AudioLifecycleTransition: Sendable, Equatable {
    let from: AudioLifecycleState
    let to: AudioLifecycleState
    let trigger: AudioLifecycleTrigger
    let outcome: AudioLifecycleOutcome
    let message: String?
}

struct AudioLifecycleSnapshot: Sendable, Equatable {
    let state: AudioLifecycleState
    let userEnabled: Bool
    let history: [AudioLifecycleTransition]
}

struct AudioLifecycleRetryPolicy: Sendable, Equatable {
    let delaysNanoseconds: [UInt64]
    let readinessPollIntervalNanoseconds: UInt64
    let readinessPollAttempts: Int

    static let wake = AudioLifecycleRetryPolicy(
        delaysNanoseconds: [1, 2, 4, 8, 16].map { UInt64($0) * 1_000_000_000 },
        readinessPollIntervalNanoseconds: 100_000_000,
        readinessPollAttempts: 100
    )

    static let helper = AudioLifecycleRetryPolicy(
        delaysNanoseconds: [1, 2, 4].map { UInt64($0) * 1_000_000_000 },
        readinessPollIntervalNanoseconds: 100_000_000,
        readinessPollAttempts: 1
    )
}

/// Serializes every lifecycle request while keeping the Core Audio graph on
/// the main actor. The actor owns the state machine and request ordering. Its
/// operations are explicitly isolated to the main actor because AVFAudio and
/// the app's observable state remain main-actor objects.
actor AudioLifecycleCoordinator {
    typealias MainOperation = @MainActor @Sendable () throws -> Void
    typealias MainAction = @MainActor @Sendable () -> Void
    typealias MainReadiness = @MainActor @Sendable () -> Bool
    typealias Sleep = @Sendable (UInt64) async -> Void

    private let startOperation: MainOperation
    private let stopOperation: MainAction
    private let readiness: MainReadiness
    private let publishSnapshot: @MainActor @Sendable (AudioLifecycleSnapshot) -> Void
    private let publishError: @MainActor @Sendable (String?) -> Void
    private let sleeper: Sleep
    private let wakePolicy: AudioLifecycleRetryPolicy
    private let helperPolicy: AudioLifecycleRetryPolicy
    private let historyLimit: Int

    private var state: AudioLifecycleState = .inactive
    private var userEnabled = false
    private var history: [AudioLifecycleTransition] = []
    private var recoveryGeneration: UInt64 = 0
    private var recoveryActive = false
    private var helperFailureCount = 0
    private var helperFailureWindowStart: UInt64?
    private var lastSuccessfulStart: UInt64?

    private let helperFailureLimit = 3
    private let helperFailureWindowNanoseconds: UInt64 = 60_000_000_000
    private let stableOperationResetNanoseconds: UInt64 = 30_000_000_000

    // Every public request chains behind the previous request. Swift actors
    // serialize access to their stored properties, but they are re-entrant
    // across await points. This tail makes the lifecycle transitions
    // non-reentrant as well.
    private var serialTail: Task<Void, Never>?
    private var serialTailSequence: UInt64?
    private var nextSerialSequence: UInt64 = 0

    init(
        startOperation: @escaping MainOperation,
        stopOperation: @escaping MainAction,
        readiness: @escaping MainReadiness,
        publishSnapshot: @escaping @MainActor @Sendable (AudioLifecycleSnapshot) -> Void,
        publishError: @escaping @MainActor @Sendable (String?) -> Void,
        wakePolicy: AudioLifecycleRetryPolicy = .wake,
        helperPolicy: AudioLifecycleRetryPolicy = .helper,
        historyLimit: Int = 32,
        sleeper: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.startOperation = startOperation
        self.stopOperation = stopOperation
        self.readiness = readiness
        self.publishSnapshot = publishSnapshot
        self.publishError = publishError
        self.wakePolicy = wakePolicy
        self.helperPolicy = helperPolicy
        self.historyLimit = max(1, historyLimit)
        self.sleeper = sleeper
    }

    func snapshot() -> AudioLifecycleSnapshot {
        makeSnapshot()
    }

    func setUserEnabled(_ enabled: Bool) async {
        userEnabled = enabled
        recoveryGeneration &+= 1
        if !enabled {
            recoveryActive = false
            resetHelperFailureBudget()
        }
        await enqueue { [weak self] in
            await self?.performSetUserEnabled(enabled)
        }
    }

    func sleep() async {
        recoveryGeneration &+= 1
        recoveryActive = false
        await enqueue { [weak self] in
            await self?.performSleep()
        }
    }

    func wake() async {
        await enqueue { [weak self] in
            await self?.performWake()
        }
    }

    func deviceChanged() async {
        await enqueue { [weak self] in
            await self?.performRestart(trigger: .deviceChange)
        }
    }

    func configurationChanged() async {
        await enqueue { [weak self] in
            await self?.performRestart(trigger: .configurationChange)
        }
    }

    func helperTerminated() async {
        await enqueue { [weak self] in
            await self?.performHelperRecovery()
        }
    }

    func shutdown() async {
        userEnabled = false
        recoveryGeneration &+= 1
        recoveryActive = false
        await enqueue { [weak self] in
            await self?.performShutdown()
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = serialTail
        let sequence = nextSerialSequence
        nextSerialSequence &+= 1
        let task = Task {
            await previous?.value
            await operation()
        }
        serialTail = task
        serialTailSequence = sequence
        await task.value
        if serialTailSequence == sequence {
            serialTail = nil
            serialTailSequence = nil
        }
    }

    private func performSetUserEnabled(_ enabled: Bool) async {
        guard enabled == userEnabled else {
            publishIgnored(trigger: enabled ? .userEnabled : .userDisabled,
                           message: "a newer capture intent superseded this request")
            return
        }

        if !enabled {
            await stopIfNeeded(trigger: .userDisabled)
            return
        }

        guard state != .running, state != .starting, state != .sleeping else {
            publish()
            return
        }
        _ = await startOnce(trigger: .userEnabled)
    }

    private func performSleep() async {
        guard userEnabled else {
            await stopIfNeeded(trigger: .sleep)
            return
        }

        if state != .sleeping {
            if state != .inactive {
                transition(to: .stopping, trigger: .sleep)
                await stopOperation()
            }
            transition(to: .sleeping, trigger: .sleep)
        } else {
            publish()
        }
    }

    private func performWake() async {
        guard userEnabled else {
            publish()
            return
        }
        guard state == .sleeping || state == .failed || state == .inactive else {
            publish()
            return
        }
        _ = await recover(trigger: .wake, policy: wakePolicy, requireReadiness: true)
    }

    private func performRestart(trigger: AudioLifecycleTrigger) async {
        guard userEnabled, state == .running else {
            publishIgnored(trigger: trigger, message: "restart requested while capture was not running")
            return
        }

        transition(to: .stopping, trigger: trigger)
        await stopOperation()
        guard userEnabled else { return }
        _ = await startOnce(trigger: trigger)
    }

    private func performHelperRecovery() async {
        guard userEnabled,
              (state == .running || state == .starting || state == .recovering) else {
            publishIgnored(trigger: .helperTermination, message: "helper termination was not recoverable")
            return
        }
        resetHelperFailureBudgetIfStable()
        if helperFailureCount >= helperFailureLimit {
            let message = "Capture helper failed repeatedly. Re-enable capture to try again."
            await publishError(message)
            await stopOperation()
            transition(to: .failed, trigger: .helperTermination, outcome: .failed, message: message)
            return
        }
        helperFailureCount += 1
        if helperFailureWindowStart == nil {
            helperFailureWindowStart = DispatchTime.now().uptimeNanoseconds
        }
        await publishError("Capture helper terminated unexpectedly.")
        _ = await recover(trigger: .helperTermination, policy: helperPolicy, requireReadiness: false)
    }

    private func performShutdown() async {
        await stopIfNeeded(trigger: .shutdown)
    }

    private func stopIfNeeded(trigger: AudioLifecycleTrigger) async {
        guard state != .inactive else {
            transition(to: .inactive, trigger: trigger)
            return
        }
        transition(to: .stopping, trigger: trigger)
        await stopOperation()
        transition(to: .inactive, trigger: trigger)
    }

    private func startOnce(trigger: AudioLifecycleTrigger) async -> String? {
        guard userEnabled else { return "Capture is disabled." }
        transition(to: .starting, trigger: trigger)
        do {
            try await startOperation()
            await publishError(nil)
            lastSuccessfulStart = DispatchTime.now().uptimeNanoseconds
            transition(to: .running, trigger: trigger)
            return nil
        } catch {
            await stopOperation()
            let message = error.localizedDescription
            await publishError(message)
            transition(to: .failed, trigger: trigger, outcome: .failed, message: message)
            return message
        }
    }

    private func recover(
        trigger: AudioLifecycleTrigger,
        policy: AudioLifecycleRetryPolicy,
        requireReadiness: Bool
    ) async -> Bool {
        guard !recoveryActive else {
            publishIgnored(trigger: trigger, message: "recovery already in progress")
            return false
        }

        recoveryActive = true
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        defer { recoveryActive = false }

        transition(to: .recovering, trigger: trigger)
        await stopOperation()

        var lastError: String?
        for attempt in 0...policy.delaysNanoseconds.count {
            guard isCurrentRecovery(generation) else { return false }
            if attempt > 0 {
                await sleeper(policy.delaysNanoseconds[attempt - 1])
                guard isCurrentRecovery(generation) else { return false }
            }

            if requireReadiness {
                let ready = await waitForReadiness(policy: policy, generation: generation)
                if !ready {
                    lastError = "Default output device is not ready."
                    continue
                }
            }

            if let failure = await startOnce(trigger: trigger) {
                lastError = failure
            } else {
                return true
            }
            if attempt < policy.delaysNanoseconds.count {
                transition(to: .recovering, trigger: trigger, message: lastError)
            }
        }

        let message = lastError ?? "Audio recovery failed."
        await publishError(message)
        transition(to: .failed, trigger: trigger, outcome: .failed, message: message)
        return false
    }

    private func waitForReadiness(
        policy: AudioLifecycleRetryPolicy,
        generation: UInt64
    ) async -> Bool {
        for attempt in 0..<policy.readinessPollAttempts {
            guard isCurrentRecovery(generation) else { return false }
            if await readiness() { return true }
            if attempt + 1 < policy.readinessPollAttempts {
                await sleeper(policy.readinessPollIntervalNanoseconds)
            }
        }
        return false
    }

    private func isCurrentRecovery(_ generation: UInt64) -> Bool {
        userEnabled && recoveryGeneration == generation
    }

    private func resetHelperFailureBudgetIfStable() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastSuccessfulStart,
           now >= lastSuccessfulStart,
           now - lastSuccessfulStart >= stableOperationResetNanoseconds {
            resetHelperFailureBudget()
        } else if let helperFailureWindowStart,
                  now >= helperFailureWindowStart,
                  now - helperFailureWindowStart >= helperFailureWindowNanoseconds {
            resetHelperFailureBudget()
        }
    }

    private func resetHelperFailureBudget() {
        helperFailureCount = 0
        helperFailureWindowStart = nil
        lastSuccessfulStart = nil
    }

    private func transition(
        to newState: AudioLifecycleState,
        trigger: AudioLifecycleTrigger,
        outcome: AudioLifecycleOutcome = .accepted,
        message: String? = nil
    ) {
        let record = AudioLifecycleTransition(
            from: state,
            to: newState,
            trigger: trigger,
            outcome: outcome,
            message: message
        )
        state = newState
        history.append(record)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        publish()
    }

    private func publishIgnored(trigger: AudioLifecycleTrigger, message: String) {
        history.append(AudioLifecycleTransition(
            from: state,
            to: state,
            trigger: trigger,
            outcome: .ignored,
            message: message
        ))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        publish()
    }

    private func makeSnapshot() -> AudioLifecycleSnapshot {
        AudioLifecycleSnapshot(state: state, userEnabled: userEnabled, history: history)
    }

    private func publish() {
        let snapshot = makeSnapshot()
        let publishSnapshot = self.publishSnapshot
        Task { @MainActor in
            publishSnapshot(snapshot)
        }
    }
}
