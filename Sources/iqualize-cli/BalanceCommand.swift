import ArgumentParser
import IQControlProtocol

struct Balance: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Get or set stereo balance, from -1 (hard left) to 1 (hard right)."
    )

    @Argument(help: "Balance from -1 to 1. Omit to just print the current value.")
    var value: Float?

    func run() {
        let request = value.map { CLIRequest(command: CLICommand.setBalance, floatArg: $0) }
            ?? CLIRequest(command: CLICommand.status)
        let response = requireOK(sendOrExit(request))
        if let status = response.status {
            print("Balance: \(formatBalance(status.balance))")
        }
    }
}
