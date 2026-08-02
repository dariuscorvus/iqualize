import XCTest
@testable import iQualize

@MainActor
private final class LifecycleProbe {
    var starts = 0
    var stops = 0
    var activeOperations = 0
    var maximumActiveOperations = 0
    var failuresRemaining = 0
    var readinessChecks = 0
    var ready = true
    var readyAfterChecks: Int?
    var publishedErrors: [String?] = []

    func start() throws {
        starts += 1
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        defer { activeOperations -= 1 }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "LifecycleTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "synthetic startup failure"])
        }
    }

    func stop() {
        stops += 1
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        activeOperations -= 1
    }

    func isReady() -> Bool {
        readinessChecks += 1
        if let readyAfterChecks {
            return readinessChecks >= readyAfterChecks
        }
        return ready
    }
}

private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            releaseContinuation = continuation
            let entered = enteredContinuation
            enteredContinuation = nil
            lock.unlock()
            entered?.resume()
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if releaseContinuation != nil {
                lock.unlock()
                continuation.resume()
            } else {
                enteredContinuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

final class AudioLifecycleTests: XCTestCase {
    private func makePolicy(
        delays: [UInt64] = [0, 0],
        readinessAttempts: Int = 1
    ) -> AudioLifecycleRetryPolicy {
        AudioLifecycleRetryPolicy(
            delaysNanoseconds: delays,
            readinessPollIntervalNanoseconds: 0,
            readinessPollAttempts: readinessAttempts
        )
    }

    private func makeCoordinator(
        probe: LifecycleProbe,
        wakePolicy: AudioLifecycleRetryPolicy = AudioLifecycleRetryPolicy(
            delaysNanoseconds: [0], readinessPollIntervalNanoseconds: 0, readinessPollAttempts: 1
        ),
        helperPolicy: AudioLifecycleRetryPolicy = AudioLifecycleRetryPolicy(
            delaysNanoseconds: [0, 0], readinessPollIntervalNanoseconds: 0, readinessPollAttempts: 1
        ),
        historyLimit: Int = 32,
        sleeper: @escaping AudioLifecycleCoordinator.Sleep = { _ in }
    ) -> AudioLifecycleCoordinator {
        AudioLifecycleCoordinator(
            startOperation: { @MainActor in try probe.start() },
            stopOperation: { @MainActor in probe.stop() },
            readiness: { @MainActor in probe.isReady() },
            publishSnapshot: { @MainActor _ in },
            publishError: { @MainActor message in probe.publishedErrors.append(message) },
            wakePolicy: wakePolicy,
            helperPolicy: helperPolicy,
            historyLimit: historyLimit,
            sleeper: sleeper
        )
    }

    func testFailedStartCleansUpAndPreservesError() async {
        let probe = await MainActor.run { LifecycleProbe() }
        await MainActor.run { probe.failuresRemaining = 1 }
        let coordinator = makeCoordinator(probe: probe)

        await coordinator.setUserEnabled(true)

        let snapshot = await coordinator.snapshot()
        let values = await MainActor.run { (probe.starts, probe.stops, probe.publishedErrors) }
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertTrue(snapshot.userEnabled)
        XCTAssertEqual(values.0, 1)
        XCTAssertEqual(values.1, 1)
        XCTAssertTrue(values.2.contains("synthetic startup failure"))
    }

    func testHelperRecoveryRetriesAndReturnsToRunning() async {
        let probe = await MainActor.run { LifecycleProbe() }
        let coordinator = makeCoordinator(
            probe: probe,
            helperPolicy: makePolicy(delays: [0, 0])
        )

        await coordinator.setUserEnabled(true)
        await MainActor.run { probe.failuresRemaining = 2 }
        await coordinator.helperTerminated()

        let snapshot = await coordinator.snapshot()
        let values = await MainActor.run { (probe.starts, probe.stops) }
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertTrue(snapshot.userEnabled)
        XCTAssertEqual(values.0, 4)
        XCTAssertGreaterThanOrEqual(values.1, 3)
    }

    func testRepeatedHelperFailuresEventuallyBecomeTerminal() async {
        let probe = await MainActor.run { LifecycleProbe() }
        let coordinator = makeCoordinator(
            probe: probe,
            helperPolicy: makePolicy(delays: [])
        )

        await coordinator.setUserEnabled(true)
        await coordinator.helperTerminated()
        await coordinator.helperTerminated()
        await coordinator.helperTerminated()
        await coordinator.helperTerminated()

        let snapshot = await coordinator.snapshot()
        let stops = await MainActor.run { probe.stops }
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertGreaterThanOrEqual(stops, 4)
        XCTAssertTrue(snapshot.history.contains {
            $0.outcome == .failed && $0.message?.contains("failed repeatedly") == true
        })
    }

    func testWakeWaitsForReadinessAndRetries() async {
        let probe = await MainActor.run { LifecycleProbe() }
        let coordinator = makeCoordinator(
            probe: probe,
            wakePolicy: makePolicy(delays: [0], readinessAttempts: 2)
        )

        await coordinator.setUserEnabled(true)
        await coordinator.sleep()
        await MainActor.run {
            probe.readyAfterChecks = 2
        }
        await coordinator.wake()

        let snapshot = await coordinator.snapshot()
        let checks = await MainActor.run { probe.readinessChecks }
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertGreaterThanOrEqual(checks, 2)
    }

    func testDisablingDuringWakeRecoveryCancelsThePendingRecovery() async {
        let probe = await MainActor.run { LifecycleProbe() }
        await MainActor.run { probe.ready = false }
        let gate = SleepGate()
        let coordinator = makeCoordinator(
            probe: probe,
            wakePolicy: makePolicy(delays: [0], readinessAttempts: 2),
            sleeper: { _ in await gate.sleep() }
        )

        await coordinator.setUserEnabled(true)
        await coordinator.sleep()

        let wakeTask = Task { await coordinator.wake() }
        await gate.waitUntilEntered()
        let disableTask = Task { await coordinator.setUserEnabled(false) }
        gate.release()

        await wakeTask.value
        await disableTask.value

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.state, .inactive)
        XCTAssertFalse(snapshot.userEnabled)
    }

    func testHistoryIsBoundedAndRequestsAreSerialized() async {
        let probe = await MainActor.run { LifecycleProbe() }
        let coordinator = makeCoordinator(probe: probe, historyLimit: 4)

        for _ in 0..<5 {
            await coordinator.setUserEnabled(true)
            await coordinator.setUserEnabled(false)
        }

        let snapshot = await coordinator.snapshot()
        let maximumActive = await MainActor.run { probe.maximumActiveOperations }
        XCTAssertLessThanOrEqual(snapshot.history.count, 4)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(snapshot.state, .inactive)
    }
}
