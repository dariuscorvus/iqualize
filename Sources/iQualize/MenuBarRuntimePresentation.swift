import Foundation

struct MenuBarRuntimePresentation: Equatable {
    enum Status: Equatable {
        case active
        case bypassed
        case stopped
        case failed
        case sleeping
        case starting
        case recovering
        case stopping
    }

    let status: Status
    let title: String
    let accessibilityLabel: String
    let symbolName: String
    let appearsDisabled: Bool
    let showsRetryCapture: Bool
    let showsPermissionSettings: Bool

    var tooltip: String { accessibilityLabel }

    static func make(
        lifecycleState: AudioLifecycleState,
        userEnabled: Bool,
        bypassed: Bool,
        lastFailure: AudioRuntimeFailure?
    ) -> MenuBarRuntimePresentation {
        let status: Status
        switch lifecycleState {
        case .failed:
            status = .failed
        case .sleeping:
            status = .sleeping
        case .starting:
            status = .starting
        case .recovering:
            status = .recovering
        case .stopping:
            status = .stopping
        case .running where bypassed:
            status = .bypassed
        case .running:
            status = .active
        case .inactive:
            status = .stopped
        }

        let showsPermissionSettings = lastFailure?.isPermissionDenied == true
        let showsRetryCapture = lifecycleState == .failed && lastFailure?.isRetryable == true

        switch status {
        case .active:
            return .init(
                status: status,
                title: "Status: Active",
                accessibilityLabel: "iQualize active",
                symbolName: "slider.vertical.3",
                appearsDisabled: false,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .bypassed:
            return .init(
                status: status,
                title: "Status: Bypassed",
                accessibilityLabel: "iQualize bypassed",
                symbolName: "speaker.slash",
                appearsDisabled: false,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .stopped:
            return .init(
                status: status,
                title: userEnabled ? "Status: Stopped" : "Status: Off",
                accessibilityLabel: userEnabled ? "iQualize stopped" : "iQualize off",
                symbolName: "pause.circle",
                appearsDisabled: true,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .failed:
            return .init(
                status: status,
                title: failureTitle(for: lastFailure),
                accessibilityLabel: failureAccessibilityLabel(for: lastFailure),
                symbolName: "exclamationmark.triangle",
                appearsDisabled: false,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .sleeping:
            return .init(
                status: status,
                title: "Status: Sleeping",
                accessibilityLabel: "iQualize sleeping",
                symbolName: "moon.zzz",
                appearsDisabled: true,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .starting:
            return .init(
                status: status,
                title: "Status: Starting",
                accessibilityLabel: "iQualize starting capture",
                symbolName: "arrow.triangle.2.circlepath",
                appearsDisabled: false,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .recovering:
            return .init(
                status: status,
                title: "Status: Recovering",
                accessibilityLabel: "iQualize recovering capture",
                symbolName: "arrow.clockwise.circle",
                appearsDisabled: false,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        case .stopping:
            return .init(
                status: status,
                title: "Status: Stopping",
                accessibilityLabel: "iQualize stopping capture",
                symbolName: "stop.circle",
                appearsDisabled: true,
                showsRetryCapture: showsRetryCapture,
                showsPermissionSettings: showsPermissionSettings
            )
        }
    }

    private static func failureTitle(for failure: AudioRuntimeFailure?) -> String {
        guard let failure else { return "Status: Capture Failed" }
        switch failure {
        case .permissionDenied:
            return "Status: Audio Capture Permission Needed"
        case .helperMissing:
            return "Status: Capture Helper Missing"
        case .helperExited:
            return "Status: Capture Helper Stopped"
        case .deviceUnavailable:
            return "Status: Output Device Unavailable"
        case .transient:
            return "Status: Capture Interrupted"
        case .terminal:
            return "Status: Capture Failed"
        }
    }

    private static func failureAccessibilityLabel(for failure: AudioRuntimeFailure?) -> String {
        guard let failure else { return "iQualize capture failed" }
        switch failure {
        case .permissionDenied:
            return "iQualize needs audio capture permission"
        case .helperMissing:
            return "iQualize capture helper missing"
        case .helperExited:
            return "iQualize capture helper stopped"
        case .deviceUnavailable:
            return "iQualize output device unavailable"
        case .transient:
            return "iQualize capture interrupted"
        case .terminal:
            return "iQualize capture failed"
        }
    }
}

private extension AudioRuntimeFailure {
    var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    var isRetryable: Bool {
        switch self {
        case .permissionDenied, .helperExited, .deviceUnavailable, .transient:
            return true
        case .helperMissing, .terminal:
            return false
        }
    }
}
