import ArgumentParser
import IQControlProtocol

struct Limiter: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "limiter", abstract: "Get or set the peak limiter.")

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
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPeakLimiter, boolArg: true)))
        case .off:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setPeakLimiter, boolArg: false)))
        case .toggle:
            response = requireOK(sendOrExit(CLIRequest(command: CLICommand.togglePeakLimiter)))
        }
        print("Peak limiter: \(response.status?.peakLimiter == true ? "on" : "off")")
    }
}
