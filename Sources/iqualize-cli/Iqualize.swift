import ArgumentParser
import IQControlProtocol

@main
struct Iqualize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iqualize",
        abstract: "Control a running iQualize instance from the command line.",
        subcommands: [Status.self, Version.self, Presets.self, PresetCommand.self, Bypass.self, Gain.self, Balance.self, Limiter.self, Capture.self, Spectrum.self, Band.self, Tldr.self],
        defaultSubcommand: Status.self
    )

    /// ArgumentParser treats any token starting with `-` as option-like, so a bare negative
    /// value is rejected unless disambiguated. Two distinct shapes need two distinct fixes:
    /// - `--flag -2` (an `@Option` value, e.g. `band set --gain -2`): merge into `--flag=-2`
    ///   — the `=` form is unambiguous to ArgumentParser without needing `--` at all, and
    ///   inserting `--` here would instead break the `--flag` -> value association entirely
    ///   (observed: `band set --gain -2` errors "missing value for --gain" once flanked).
    /// - A bare `@Argument` value (e.g. `iqualize balance -0.5`, `gain input -5`): insert
    ///   `--` in front of the first remaining negative-number-looking token not already
    ///   merged above.
    /// Rather than make every user of a numeric command learn either escape hatch, both are
    /// applied automatically before parsing.
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let negativeNumber = #"^-\d+(\.\d+)?$"#

        var merged: [String] = []
        var i = 0
        while i < arguments.count {
            let token = arguments[i]
            if token.hasPrefix("--"), !token.contains("="), i + 1 < arguments.count,
               arguments[i + 1].range(of: negativeNumber, options: .regularExpression) != nil {
                merged.append("\(token)=\(arguments[i + 1])")
                i += 2
            } else {
                merged.append(token)
                i += 1
            }
        }
        arguments = merged

        if !arguments.contains("--"),
           let index = arguments.firstIndex(where: { $0.range(of: negativeNumber, options: .regularExpression) != nil }) {
            arguments.insert("--", at: index)
        }
        Iqualize.main(arguments)
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the app version and build commit.")

    func run() {
        let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.status)))
        guard let status = response.status else {
            printErr("Error: missing status in response")
            return
        }
        print(formatVersion(status))
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show app version, capture/bypass/limiter state, active preset, gain, balance, spectrum overlays, and output device.")

    func run() {
        let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.status)))
        guard let status = response.status else {
            printErr("Error: missing status in response")
            return
        }
        print(formatStatus(status))
    }
}

/// Router for everything preset-related beyond the bare `iqualize preset <name>` switch
/// command (which stays a separate top-level `PresetCommand` — see its file for why: a
/// free-form positional argument there would make a preset literally named "Save" or "New"
/// unreachable). `defaultSubcommand: List.self` makes bare `iqualize presets` (no further
/// token) behave exactly like it did before this became a router — see PresetLifecycleCommand.swift
/// for `List` and every other nested subcommand.
struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presets", abstract: "List all presets.",
        subcommands: [List.self, Save.self, Reset.self, Delete.self, New.self, Rename.self, Duplicate.self,
                      Favorite.self, Pin.self, Unpin.self, Import.self, Export.self,
                      Hidden.self, Restore.self, Opra.self],
        defaultSubcommand: List.self)
}
