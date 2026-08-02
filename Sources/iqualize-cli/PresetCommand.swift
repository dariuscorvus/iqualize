import ArgumentParser
import IQControlProtocol

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preset", abstract: "Switch the active preset by name or ID.")

    @Argument(help: "Preset name (case-insensitive) or UUID.")
    var name: String?

    @Flag(help: "Discard unsaved edits instead of failing.")
    var force = false

    @Flag(help: "Show quick usage examples for this command.")
    var tldr = false

    func validate() throws {
        guard tldr || name != nil else {
            throw ValidationError("Missing expected argument '<name>'")
        }
    }

    func run() {
        if tldr { printTldr(matching: "preset"); return }
        let response = requireOK(sendOrExit(CLIRequest(
            command: CLICommand.selectPreset, stringArg: name, force: force)))
        if let status = response.status {
            print("Switched to \(status.activePresetName)")
        }
    }
}
