import ArgumentParser
import IQControlProtocol

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preset", abstract: "Switch the active preset by name or ID.")

    @Argument(help: "Preset name (case-insensitive) or UUID.")
    var name: String

    func run() {
        let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.selectPreset, stringArg: name)))
        if let status = response.status {
            print("Switched to \(status.activePresetName)")
        }
    }
}
