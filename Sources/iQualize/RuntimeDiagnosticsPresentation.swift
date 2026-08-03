import Foundation

struct RuntimeDiagnosticsSnapshot: Sendable {
    let status: AudioRuntimeStatus
    let captureTelemetry: CaptureClient.Telemetry?

    init(status: AudioRuntimeStatus, captureTelemetry: CaptureClient.Telemetry? = nil) {
        self.status = status
        self.captureTelemetry = captureTelemetry
    }
}

struct RuntimeDiagnosticsPresentation: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    let rows: [Row]
    let report: String

    static let unavailable = "Unavailable"

    static func make(snapshot: RuntimeDiagnosticsSnapshot) -> RuntimeDiagnosticsPresentation {
        let status = snapshot.status
        let ratesDiffer = ratesDiffer(capture: status.captureFormat, render: status.renderFormat)

        let rows = [
            Row(label: "Effective Capture Format", value: format(status.captureFormat)),
            Row(label: "Render/DSP Format", value: renderDSPFormat(render: status.renderFormat, dspSampleRate: status.dspSampleRate)),
            Row(label: "Output Device Name", value: emptyAware(status.outputDevice?.name)),
            Row(label: "Output Device UID", value: emptyAware(status.outputDevice?.uid)),
            Row(label: "Output Device Nominal Sample Rate", value: formatSampleRate(status.outputDevice?.nominalSampleRate)),
            Row(label: "Output Device Output Channels", value: formatCount(status.outputDevice?.outputChannelCount)),
            Row(label: "Lifecycle State", value: formatLifecycle(status.lifecycleState, userEnabled: status.userEnabled, isRunning: status.isRunning)),
            Row(label: "Rates Differ", value: ratesDiffer.map { $0 ? "Yes" : "No" } ?? unavailable),
            Row(label: "Drift/Resampling Status", value: driftResamplingStatus(telemetry: snapshot.captureTelemetry, ratesDiffer: ratesDiffer)),
            Row(label: "Last Failure", value: format(status.lastFailure))
        ]

        let report = (["iQualize Diagnostic Report"] + rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        return RuntimeDiagnosticsPresentation(rows: rows, report: report)
    }

    private static func format(_ format: AudioRuntimeStatus.StreamFormat?) -> String {
        guard let format else { return unavailable }
        return "\(formatSampleRate(format.sampleRate)), \(format.channelCount) ch"
    }

    private static func renderDSPFormat(render: AudioRuntimeStatus.StreamFormat?, dspSampleRate: Double?) -> String {
        let renderValue = format(render)
        let dspValue = formatSampleRate(dspSampleRate)
        return "Render: \(renderValue); DSP sample rate: \(dspValue)"
    }

    private static func ratesDiffer(
        capture: AudioRuntimeStatus.StreamFormat?,
        render: AudioRuntimeStatus.StreamFormat?
    ) -> Bool? {
        guard let capture, let render else { return nil }
        return capture.sampleRate != render.sampleRate || capture.channelCount != render.channelCount
    }

    private static func driftResamplingStatus(telemetry: CaptureClient.Telemetry?, ratesDiffer: Bool?) -> String {
        guard let telemetry else {
            if ratesDiffer == true { return "Resampling expected; drift telemetry unavailable" }
            return unavailable
        }

        let resampling = ratesDiffer == true ? "Resampling expected" : "Resampling not expected"
        let drift = String(format: "%.2f ppm", telemetry.driftPpm)
        return "\(resampling); drift \(drift); fill \(telemetry.fillFrames) frames; underruns \(telemetry.underruns); overrun resyncs \(telemetry.overrunResyncs)"
    }

    private static func formatLifecycle(
        _ state: AudioLifecycleState,
        userEnabled: Bool,
        isRunning: Bool
    ) -> String {
        "\(state.rawValue) (user enabled: \(userEnabled ? "Yes" : "No"), running: \(isRunning ? "Yes" : "No"))"
    }

    private static func format(_ failure: AudioRuntimeFailure?) -> String {
        guard let failure else { return unavailable }
        switch failure {
        case .permissionDenied(.processTap(let status)):
            return "Permission denied: process tap" + statusSuffix(status)
        case .helperMissing(let detail):
            return "Capture helper missing at \(detail.path)"
        case .helperExited(let detail):
            return "Capture helper exited with status \(detail.status)" + (detail.signaled ? " (signaled)" : "")
        case .deviceUnavailable(.defaultOutputNotReady):
            return "Default output device not ready"
        case .deviceUnavailable(.coreAudioStatus(let status)):
            return "Core Audio device unavailable (status \(status))"
        case .transient(.handshakeTimeout(let seconds)):
            return String(format: "Handshake timed out after %.1f seconds", seconds)
        case .transient(.handshakeRead(let errno)):
            return "Handshake read failed (errno \(errno))"
        case .transient(.sharedMemoryOpen(let errno)):
            return "Shared memory open failed (errno \(errno))"
        case .transient(.sharedMemoryStat(let errno)):
            return "Shared memory stat failed (errno \(errno))"
        case .transient(.sharedMemoryMap(let errno)):
            return "Shared memory map failed (errno \(errno))"
        case .transient(.sharedMemoryStartup(let exitCode)):
            return "Shared memory startup failed (exit \(exitCode))"
        case .terminal(.malformedHandshake):
            return "Malformed helper handshake"
        case .terminal(.helperStartup(let stage, let exitCode, let osStatus)):
            return "Helper startup failed at \(stage.rawValue) (exit \(exitCode))" + statusSuffix(osStatus)
        case .terminal(.invalidCaptureGeometry):
            return "Invalid capture geometry"
        case .terminal(.captureProtocolViolation):
            return "Capture protocol violation"
        case .terminal(.engineUnavailable):
            return "Audio engine unavailable"
        case .terminal(.renderConfiguration):
            return "Render configuration failed"
        case .terminal(.unknown):
            return "Unknown terminal failure"
        }
    }

    private static func statusSuffix(_ status: Int32?) -> String {
        guard let status else { return "" }
        return " (status \(status))"
    }

    private static func formatSampleRate(_ sampleRate: Double?) -> String {
        guard let sampleRate else { return unavailable }
        return String(format: "%.0f Hz", sampleRate)
    }

    private static func formatCount(_ count: UInt32?) -> String {
        guard let count else { return unavailable }
        return "\(count)"
    }

    private static func emptyAware(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return unavailable }
        return value
    }
}
