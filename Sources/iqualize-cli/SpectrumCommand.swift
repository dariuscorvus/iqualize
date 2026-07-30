import ArgumentParser
import IQControlProtocol

struct Spectrum: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spectrum",
        abstract: "Get or set the spectrum analyzer overlays.",
        subcommands: [Pre.self, Post.self, Tldr.self]
    )

    struct Pre: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set the Pre-EQ spectrum overlay.")

        enum Action: String, ExpressibleByArgument, CaseIterable {
            case on, off, toggle, tldr
        }

        @Argument(help: "on, off, toggle, or tldr. Omit to just print the current state.")
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
            case .tldr:
                printTldr(matching: "spectrum pre")
                return
            }
            print("Pre-EQ spectrum: \(response.status?.preEqSpectrumEnabled == true ? "on" : "off")")
        }
    }

    struct Post: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set the Post-EQ spectrum overlay.")

        enum Action: String, ExpressibleByArgument, CaseIterable {
            case on, off, toggle, tldr
        }

        @Argument(help: "on, off, toggle, or tldr. Omit to just print the current state.")
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
            case .tldr:
                printTldr(matching: "spectrum post")
                return
            }
            print("Post-EQ spectrum: \(response.status?.postEqSpectrumEnabled == true ? "on" : "off")")
        }
    }

    struct Tldr: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tldr", abstract: "Show quick usage examples for every spectrum command.")
        func run() { printTldr(matching: "spectrum") }
    }
}
