import ArgumentParser
import IQControlProtocol

struct Gain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gain",
        abstract: "Get or set input/output gain.",
        subcommands: [Input.self, Output.self, Link.self]
    )

    struct Input: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set input gain, in dB.")

        @Argument(help: "Gain in dB. Omit to just print the current value.")
        var db: Float?

        func run() {
            let request = db.map { CLIRequest(command: CLICommand.setInputGain, floatArg: $0) }
                ?? CLIRequest(command: CLICommand.status)
            let response = requireOK(sendOrExit(request))
            if let status = response.status {
                print(String(format: "Input gain: %+.1f dB", status.inputGainDB))
            }
        }
    }

    struct Output: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set output gain, in dB.")

        @Argument(help: "Gain in dB. Omit to just print the current value.")
        var db: Float?

        func run() {
            let request = db.map { CLIRequest(command: CLICommand.setOutputGain, floatArg: $0) }
                ?? CLIRequest(command: CLICommand.status)
            let response = requireOK(sendOrExit(request))
            if let status = response.status {
                print(String(format: "Output gain: %+.1f dB", status.outputGainDB))
            }
        }
    }

    struct Link: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set whether In/Out gain is shared across all presets.")

        enum Action: String, ExpressibleByArgument, CaseIterable {
            case on, off, toggle
        }

        @Argument(help: "on, off, or toggle. Omit to just print the current state.")
        var action: Action?

        func run() {
            let response: CLIResponse
            switch action {
            case nil:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.status)))
            case .on:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setGainIsGlobal, boolArg: true)))
            case .off:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setGainIsGlobal, boolArg: false)))
            case .toggle:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.toggleGainIsGlobal)))
            }
            print("Gain link: \(response.status?.gainIsGlobal == true ? "on" : "off")")
        }
    }
}
