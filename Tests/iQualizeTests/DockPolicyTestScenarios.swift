import AppKit
import Foundation
#if !DOCK_POLICY_STANDALONE
@testable import iQualize
#endif

// Shared by XCTest and the standalone CLT harness. Neither touches NSApp or
// standard defaults: only the policy API is faked, not settings persistence.
@MainActor
enum DockPolicyTestScenarios {
    private struct CheckFailure: Error {
        let message: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
    }

    private static func withStore(_ body: (SettingsStore, UserDefaults) throws -> Void) rethrows {
        let suite = "DockPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SettingsStore(userDefaults: defaults), defaults)
    }

    static func livePreferenceControlsBothDirections() throws {
        try withStore { store, defaults in
            var policy: NSApplication.ActivationPolicy = .regular
            var requests: [NSApplication.ActivationPolicy] = []
            var reasons: [DockPolicyController.Reason] = []
            let controller = DockPolicyController(
                settings: store,
                currentPolicy: { policy },
                setPolicy: { requested in
                    requests.append(requested)
                    policy = requested
                    return true
                },
                logTransition: { transition in
                    reasons.append(transition.reason)
                    precondition(transition.result == true && transition.observed == transition.to)
                }
            )

            store.set(\.hideFromDock, true)
            try check(controller.reconcile(reason: .bootstrap), "hide request failed")
            try check(policy == .accessory, "hide=true did not request accessory")
            try check(SettingsStore(userDefaults: defaults).state.hideFromDock, "hide=true was not persisted")

            // The same controller must read the store again, not a launch snapshot.
            store.set(\.hideFromDock, false)
            try check(controller.reconcile(reason: .settingsChanged), "show request failed")
            try check(policy == .regular, "hide=false did not request regular")
            try check(!SettingsStore(userDefaults: defaults).state.hideFromDock, "hide=false was not persisted")
            try check(requests == [.accessory, .regular], "unexpected policy requests")
            try check(reasons == [.bootstrap, .settingsChanged], "wrong transition reasons")
        }
    }

    static func matchingPoliciesSkipSetter() throws {
        try withStore { store, defaults in
            for hide in [false, true] {
                store.set(\.hideFromDock, hide)
                let before = defaults.data(forKey: iQualizeState.key)
                var setterCalls = 0
                var transitions: [DockPolicyController.Transition] = []
                let controller = DockPolicyController(
                    settings: store,
                    currentPolicy: { hide ? .accessory : .regular },
                    setPolicy: { _ in setterCalls += 1; return false },
                    logTransition: { transitions.append($0) }
                )

                try check(controller.reconcile(reason: .launchCompleted), "matching policy was not a successful no-op")
                try check(setterCalls == 0, "matching policy called setter")
                try check(transitions.count == 1 && transitions[0].result == nil, "no-op was not identified in log")
                try check(transitions[0].from == transitions[0].to && transitions[0].observed == transitions[0].to,
                          "no-op log lost the observed matching policy")
                try check(defaults.data(forKey: iQualizeState.key) == before, "no-op changed persisted settings")
            }
        }
    }

    static func failedSetterPreservesIntentAndReportsFailure() throws {
        try withStore { store, defaults in
            store.set(\.balance, 0.25)
            store.set(\.maxGainDB, 9)
            for hide in [true, false] {
                store.set(\.hideFromDock, hide)
                let before = defaults.data(forKey: iQualizeState.key)
                let existing: NSApplication.ActivationPolicy = hide ? .regular : .accessory
                let desired: NSApplication.ActivationPolicy = hide ? .accessory : .regular
                var requests: [NSApplication.ActivationPolicy] = []
                var transitions: [DockPolicyController.Transition] = []
                let controller = DockPolicyController(
                    settings: store,
                    currentPolicy: { existing },
                    setPolicy: { requests.append($0); return false },
                    logTransition: { transitions.append($0) }
                )

                try check(!controller.reconcile(reason: .dockQuit), "setter failure was not returned")
                try check(requests == [desired], "failure did not attempt desired policy exactly once")
                try check(transitions.count == 1, "failure was not logged exactly once")
                let transition = transitions[0]
                try check(transition.reason == .dockQuit && transition.from == existing && transition.to == desired &&
                          transition.observed == existing && transition.result == false,
                          "failure log lost reason/from/to/observed/result")
                try check(store.state.hideFromDock == hide, "failure changed live preference")
                try check(SettingsStore(userDefaults: defaults).state.hideFromDock == hide, "failure changed persisted intent")
                try check(defaults.data(forKey: iQualizeState.key) == before, "failure changed persisted settings blob")
            }
        }
    }

    static func setterResultAndObservedPolicyRemainDistinct() throws {
        try withStore { store, defaults in
            store.set(\.hideFromDock, true)
            let before = defaults.data(forKey: iQualizeState.key)
            var transitions: [DockPolicyController.Transition] = []
            let controller = DockPolicyController(
                settings: store,
                currentPolicy: { .regular },
                setPolicy: { _ in true },
                logTransition: { transitions.append($0) }
            )

            try check(controller.reconcile(reason: .launchCompleted), "API success Bool was replaced with an observation")
            try check(transitions.count == 1, "accepted request was not logged")
            try check(transitions[0].result == true && transitions[0].to == .accessory && transitions[0].observed == .regular,
                      "API result and differing observation were conflated")
            try check(defaults.data(forKey: iQualizeState.key) == before, "accepted request changed persisted intent")
        }
    }
}
