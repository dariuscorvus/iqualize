import ArgumentParser
import IQControlProtocol

@main
struct Iqualize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iqualize",
        abstract: "Control a running iQualize instance from the command line.",
        subcommands: [Status.self, Presets.self, PresetCommand.self, Bypass.self, Gain.self],
        defaultSubcommand: Status.self
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show bypass state, active preset, gain, and output device.")

    func run() {
        let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.status)))
        guard let status = response.status else {
            printErr("Error: missing status in response")
            return
        }
        print(formatStatus(status))
    }
}

struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "presets", abstract: "List all presets.")

    func run() {
        let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.listPresets)))
        guard let presets = response.presets else {
            printErr("Error: missing presets in response")
            return
        }
        for preset in presets {
            let active = preset.isActive ? "*" : " "
            let favorite = preset.isFavorite ? "♥" : " "
            print("\(active) \(favorite) \(preset.name)")
        }
    }
}
