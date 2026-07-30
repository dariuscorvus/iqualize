import ArgumentParser
import IQControlProtocol

/// Mirrors iQualize's internal `FilterType` enum — iqualize-cli can't import it directly
/// since executable targets aren't importable products. Case names (and therefore raw
/// values) must stay in sync with `Sources/iQualize/EQModels.swift`'s `FilterType`.
enum BandFilterType: String, ExpressibleByArgument, CaseIterable {
    case parametric, lowShelf, highShelf, lowPass, highPass, bandPass, notch
}

func validateBandAddressing(index: Int?, near: Float?) throws {
    guard (index == nil) != (near == nil) else {
        throw ValidationError("specify exactly one of --index or --near")
    }
}

func formatBand(_ band: CLIBandSummary) -> String {
    let muted = band.muted ? " (muted)" : ""
    return "#\(band.index)  \(formatFrequency(band.frequency))  \(String(format: "%+.1f dB", band.gain))  Q/BW \(String(format: "%.2f", band.bandwidth))  \(band.filterType)\(muted)"
}

func formatFrequency(_ hz: Float) -> String {
    hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
}

struct Band: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "band", abstract: "Add, edit, delete, move, or mute an EQ band on the active preset.",
        subcommands: [List.self, Add.self, Set.self, Delete.self, Move.self, Mute.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bands on the active preset, sorted by frequency.")

        func run() {
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.listBands)))
            guard let bands = response.bands else {
                printErr("Error: missing bands in response")
                return
            }
            if bands.isEmpty {
                print("No bands.")
            } else {
                for band in bands { print(formatBand(band)) }
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a new band. Omitted values default to a sane starting point.")

        @Option(name: .customLong("freq"), help: "Frequency in Hz. Omit to auto-pick the largest gap in the spectrum.")
        var frequency: Float?
        @Option(help: "Gain in dB. Defaults to 0.")
        var gain: Float?
        @Option(help: "Bandwidth in octaves. Defaults to 1.0.")
        var bandwidth: Float?
        @Option(help: "Filter type. Defaults to parametric.")
        var filter: BandFilterType?

        func run() {
            let args = CLIBandArgs(frequency: frequency, gain: gain, bandwidth: bandwidth, filterType: filter?.rawValue)
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.addBand, bandArgs: args)))
            if let band = response.bands?.first { print("Added \(formatBand(band))") }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one or more values of an existing band.")

        @Option(help: "1-based band index, sorted by frequency.")
        var index: Int?
        @Option(help: "Address the band nearest this frequency (Hz) instead of by index.")
        var near: Float?
        @Option(name: .customLong("freq"), help: "New frequency in Hz.")
        var frequency: Float?
        @Option(help: "New gain in dB.")
        var gain: Float?
        @Option(help: "New bandwidth in octaves.")
        var bandwidth: Float?
        @Option(help: "New filter type.")
        var filter: BandFilterType?

        func validate() throws {
            try validateBandAddressing(index: index, near: near)
        }

        func run() {
            let args = CLIBandArgs(index: index, matchFrequency: near, frequency: frequency, gain: gain, bandwidth: bandwidth, filterType: filter?.rawValue)
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setBand, bandArgs: args)))
            if let band = response.bands?.first { print(formatBand(band)) }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a band.")

        @Option(help: "1-based band index, sorted by frequency.")
        var index: Int?
        @Option(help: "Address the band nearest this frequency (Hz) instead of by index.")
        var near: Float?

        func validate() throws {
            try validateBandAddressing(index: index, near: near)
        }

        func run() {
            let args = CLIBandArgs(index: index, matchFrequency: near)
            requireOK(sendOrExit(CLIRequest(command: CLICommand.deleteBand, bandArgs: args)))
            print("Deleted.")
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Swap a band's frequency with its next-lower or next-higher neighbor.")

        enum Direction: String, ExpressibleByArgument, CaseIterable {
            case left, right
        }

        @Option(help: "1-based band index, sorted by frequency.")
        var index: Int?
        @Option(help: "Address the band nearest this frequency (Hz) instead of by index.")
        var near: Float?
        @Argument(help: "left or right.")
        var direction: Direction

        func validate() throws {
            try validateBandAddressing(index: index, near: near)
        }

        func run() {
            let args = CLIBandArgs(index: index, matchFrequency: near, direction: direction.rawValue)
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.moveBand, bandArgs: args)))
            if let band = response.bands?.first { print(formatBand(band)) }
        }
    }

    struct Mute: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mute, unmute, or toggle a band. Muting keeps its gain intact — it's silenced non-destructively.")

        enum Action: String, ExpressibleByArgument, CaseIterable {
            case on, off, toggle
        }

        @Option(help: "1-based band index, sorted by frequency.")
        var index: Int?
        @Option(help: "Address the band nearest this frequency (Hz) instead of by index.")
        var near: Float?
        @Argument(help: "on, off, or toggle.")
        var action: Action

        func validate() throws {
            try validateBandAddressing(index: index, near: near)
        }

        func run() {
            let args = CLIBandArgs(index: index, matchFrequency: near)
            let response: CLIResponse
            switch action {
            case .on:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setBandMute, boolArg: true, bandArgs: args)))
            case .off:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setBandMute, boolArg: false, bandArgs: args)))
            case .toggle:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.toggleBandMute, bandArgs: args)))
            }
            if let band = response.bands?.first { print(formatBand(band)) }
        }
    }
}
