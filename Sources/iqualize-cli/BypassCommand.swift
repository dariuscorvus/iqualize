import ArgumentParser
import IQControlProtocol

struct Bypass: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bypass", abstract: "Get or set EQ bypass.")

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
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setBypass, boolArg: true)))
        case .off:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setBypass, boolArg: false)))
        case .toggle:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.toggleBypass)))
        }
        print("Bypass: \(response.status?.bypassed == true ? "on" : "off")")
    }
}
