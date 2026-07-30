import ArgumentParser
import IQControlProtocol

struct Spectrum: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spectrum",
        abstract: "Get or set the spectrum analyzer overlays.",
        subcommands: [Pre.self, Post.self]
    )

    struct Pre: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set the Pre-EQ spectrum overlay.")

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
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPreEqSpectrum, boolArg: true)))
            case .off:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPreEqSpectrum, boolArg: false)))
            case .toggle:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.togglePreEqSpectrum)))
            }
            print("Pre-EQ spectrum: \(response.status?.preEqSpectrumEnabled == true ? "on" : "off")")
        }
    }

    struct Post: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set the Post-EQ spectrum overlay.")

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
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPostEqSpectrum, boolArg: true)))
            case .off:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPostEqSpectrum, boolArg: false)))
            case .toggle:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.togglePostEqSpectrum)))
            }
            print("Post-EQ spectrum: \(response.status?.postEqSpectrumEnabled == true ? "on" : "off")")
        }
    }
}
