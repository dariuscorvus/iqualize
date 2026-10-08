import AppKit
import os.log

private let dockPolicyLog = OSLog(subsystem: "com.iqualize", category: "dock-policy")

/// Applies the live Dock preference without changing the user's persisted intent.
@MainActor
final class DockPolicyController {
    enum Reason: String {
        case bootstrap
        case launchCompleted = "launch-completed"
        case settingsChanged = "settings-changed"
        case dockQuit = "dock-quit"
    }

    struct Transition {
        let reason: Reason
        let from: NSApplication.ActivationPolicy
        let to: NSApplication.ActivationPolicy
        let observed: NSApplication.ActivationPolicy
        /// nil means the policies already matched and no setter was called.
        let result: Bool?
    }

    private let settings: SettingsStore
    private let currentPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let logTransition: @MainActor (Transition) -> Void

    init(
        settings: SettingsStore,
        currentPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
        setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool = { NSApp.setActivationPolicy($0) },
        logTransition: @escaping @MainActor (Transition) -> Void = DockPolicyController.log
    ) {
        self.settings = settings
        self.currentPolicy = currentPolicy
        self.setPolicy = setPolicy
        self.logTransition = logTransition
    }

    /// Returns the setter's Bool, or true for a matching-policy no-op.
    /// The immediate observed policy is logged separately from that API result.
    @discardableResult
    func reconcile(reason: Reason) -> Bool {
        let desired: NSApplication.ActivationPolicy = settings.state.hideFromDock ? .accessory : .regular
        let previous = currentPolicy()
        guard previous != desired else {
            logTransition(Transition(reason: reason, from: previous, to: desired, observed: previous, result: nil))
            return true
        }

        let succeeded = setPolicy(desired)
        logTransition(Transition(reason: reason, from: previous, to: desired, observed: currentPolicy(), result: succeeded))
        return succeeded
    }

    private static func log(_ transition: Transition) {
        let action = transition.result == nil ? "no-op" : "attempted"
        let result = transition.result.map { String($0) } ?? "not-attempted"
        os_log(transition.result == false ? .error : .debug, log: dockPolicyLog,
               "reason=%{public}@ action=%{public}@ from=%{public}ld to=%{public}ld observed=%{public}ld result=%{public}@",
               transition.reason.rawValue, action, transition.from.rawValue, transition.to.rawValue, transition.observed.rawValue, result)
    }
}
