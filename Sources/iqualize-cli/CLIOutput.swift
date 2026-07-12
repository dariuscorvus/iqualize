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

func formatStatus(_ status: CLIStatusPayload) -> String {
    let mode = status.gainIsGlobal ? "shared" : "per-preset"
    return """
    Bypass: \(status.bypassed ? "on" : "off")
    Preset: \(status.activePresetName)
    Gain: \(String(format: "input %+.1f dB, output %+.1f dB", status.inputGainDB, status.outputGainDB)) (\(mode))
    Output device: \(status.outputDeviceName)
    """
}
