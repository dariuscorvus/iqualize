import Foundation

public enum CLIControlPaths {
    /// Directory holding the control socket, created with owner-only (0700) permissions.
    public static var controlDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iQualize", isDirectory: true)
    }

    /// Unix domain socket the running app listens on and the CLI connects to.
    public static var socketPath: String {
        controlDirectory.appendingPathComponent("control.sock").path
    }
}
