import Darwin
import Foundation
import IQControlProtocol

enum IQClientError: Error, CustomStringConvertible {
    case appNotReachable
    case malformedResponse

    var description: String {
        switch self {
        case .appNotReachable: return "Couldn't reach iQualize. Is it installed?"
        case .malformedResponse: return "Received a malformed response from iQualize."
        }
    }
}

/// Talks to the running app's `CLIControlServer` over the Unix domain socket at
/// `CLIControlPaths.socketPath`. If the app isn't running, launches it and retries for a
/// few seconds before giving up.
enum IQClient {
    static func send(_ request: CLIRequest) throws -> CLIResponse {
        if let response = try? sendOnce(request) {
            return response
        }

        launchApp()
        for _ in 0..<50 {
            usleep(100_000) // 100ms — ~5s total before giving up
            if let response = try? sendOnce(request) {
                return response
            }
        }
        throw IQClientError.appNotReachable
    }

    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "iQualize"]
        try? process.run()
    }

    private static func sendOnce(_ request: CLIRequest) throws -> CLIResponse {
        guard var addr = UnixSocketIO.makeSockaddrUn(path: CLIControlPaths.socketPath) else {
            throw IQClientError.appNotReachable
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IQClientError.appNotReachable }
        defer { close(fd) }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw IQClientError.appNotReachable }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let data = try JSONEncoder().encode(request)
        guard UnixSocketIO.writeFrame(data, fd: fd) else { throw IQClientError.appNotReachable }

        guard let responseData = UnixSocketIO.readLine(fd: fd) else {
            throw IQClientError.malformedResponse
        }
        return try JSONDecoder().decode(CLIResponse.self, from: responseData)
    }
}
