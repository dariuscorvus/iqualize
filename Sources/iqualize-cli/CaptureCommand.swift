import ArgumentParser
import IQControlProtocol

struct Capture: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capture", abstract: "Get or set whether iQualize is capturing system audio.")

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
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setCapture, boolArg: true)))
        case .off:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setCapture, boolArg: false)))
        case .toggle:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.toggleCapture)))
        }
        print("Capture: \(response.status?.isRunning == true ? "on" : "off")")
    }
}
