import ArgumentParser
import IQControlProtocol

struct Gain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gain",
        abstract: "Get or set input/output gain.",
        subcommands: [Input.self, Output.self]
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
}
