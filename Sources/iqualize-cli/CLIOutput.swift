import Foundation
import IQControlProtocol

func printErr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Sends a request, exiting with code 2 ("couldn't reach the app at all") on transport
/// failure — auto-launch already happened inside `IQClient.send`, so a failure here means
/// even that didn't work.
func sendOrExit(_ request: CLIRequest) -> CLIResponse {
    do {
        return try IQClient.send(request)
    } catch {
        printErr("Error: \(error)")
        exit(2)
    }
}

/// Exits with code 1 ("command error", e.g. an unknown preset name) if the app reported
/// failure; otherwise passes the response through.
@discardableResult
func requireOK(_ response: CLIResponse) -> CLIResponse {
    if !response.ok {
        printErr("Error: \(response.error ?? "unknown error")")
        exit(1)
    }
    return response
}

func formatBalance(_ value: Float) -> String {
    if abs(value) < 0.01 { return "center" }
    let pct = Int(round(abs(value) * 100))
    return value < 0 ? "L\(pct)" : "R\(pct)"
}

/// "0.51.0 (abc1234)", commit omitted for unstamped builds.
func formatVersion(_ status: CLIStatusPayload) -> String {
    let version = status.appVersion ?? "unknown"
    return status.gitCommit.map { "\(version) (\($0))" } ?? version
}

private func formatUnavailable<T>(_ value: T?, _ transform: (T) -> String) -> String {
    value.map(transform) ?? "Unavailable"
}

private func formatRuntimeRate(_ value: Double?) -> String {
    formatUnavailable(value) { String(format: "%.0f Hz", $0) }
}

private func formatRuntimeChannels(_ value: UInt32?) -> String {
    formatUnavailable(value) { "\($0)" }
}

private func formatRuntimeBool(_ value: Bool?) -> String {
    formatUnavailable(value) { $0 ? "yes" : "no" }
}

private func hasRuntimeDiagnostics(_ status: CLIStatusPayload) -> Bool {
    status.runtimeLifecycleState != nil
        || status.runtimeCaptureSampleRate != nil
        || status.runtimeCaptureChannelCount != nil
        || status.runtimeRenderSampleRate != nil
        || status.runtimeRenderChannelCount != nil
        || status.runtimeDSPSampleRate != nil
        || status.runtimeOutputDeviceUID != nil
        || status.runtimeOutputDeviceNominalSampleRate != nil
        || status.runtimeOutputDeviceChannelCount != nil
        || status.runtimeRatesDiffer != nil
        || status.runtimeResamplingActive != nil
        || status.runtimeUnavailableReason != nil
}

private func formatRuntimeDiagnostics(_ status: CLIStatusPayload) -> String {
    """
    Runtime diagnostics:
      Lifecycle: \(status.runtimeLifecycleState ?? "Unavailable")
      Capture stream: \(formatRuntimeRate(status.runtimeCaptureSampleRate)), \(formatRuntimeChannels(status.runtimeCaptureChannelCount)) channels
      Render stream: \(formatRuntimeRate(status.runtimeRenderSampleRate)), \(formatRuntimeChannels(status.runtimeRenderChannelCount)) channels
      DSP sample rate: \(formatRuntimeRate(status.runtimeDSPSampleRate))
      Output device UID: \(status.runtimeOutputDeviceUID ?? "Unavailable")
      Output device nominal rate: \(formatRuntimeRate(status.runtimeOutputDeviceNominalSampleRate))
      Output device channels: \(formatRuntimeChannels(status.runtimeOutputDeviceChannelCount))
      Rates differ: \(formatRuntimeBool(status.runtimeRatesDiffer))
      Drift/resampling active: \(formatRuntimeBool(status.runtimeResamplingActive))
      Unavailable: \(status.runtimeUnavailableReason ?? "Unavailable")
    """
}

func formatStatus(_ status: CLIStatusPayload) -> String {
    let mode = status.gainIsGlobal ? "shared" : "per-preset"
    var lines = """
    Version: \(formatVersion(status))
    Capture: \(status.isRunning ? "on" : "off")
    Bypass: \(status.bypassed ? "on" : "off")
    Peak limiter: \(status.peakLimiter ? "on" : "off")
    Preset: \(status.activePresetName)
    Gain: \(String(format: "input %+.1f dB, output %+.1f dB", status.inputGainDB, status.outputGainDB)) (\(mode))
    Balance: \(formatBalance(status.balance))
    Pre-EQ spectrum: \(status.preEqSpectrumEnabled ? "on" : "off")
    Post-EQ spectrum: \(status.postEqSpectrumEnabled ? "on" : "off")
    Output device: \(status.outputDeviceName)
    """
    // Drift telemetry (#133); absent while the engine is stopped or from
    // older apps. Counters reset on every capture (re)start.
    if let fill = status.captureFillFrames,
       let ppm = status.captureDriftPpm,
       let underruns = status.captureUnderruns,
       let resyncs = status.captureOverrunResyncs {
        lines += "\n" + String(format: "Capture: fill %d frames, drift %+.1f ppm, underruns %d, resyncs %d",
                               fill, ppm, underruns, resyncs)
    }
    if let restarts = status.captureHelperRestarts, restarts > 0 {
        lines += "\nCapture helper restarts: \(restarts)"
    }
    if hasRuntimeDiagnostics(status) {
        lines += "\n" + formatRuntimeDiagnostics(status)
    }
    return lines
}
