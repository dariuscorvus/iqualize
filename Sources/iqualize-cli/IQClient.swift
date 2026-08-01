import Darwin
import Foundation
import IQControlProtocol

enum IQClientError: Error, CustomStringConvertible {
    case appNotReachable
    case malformedResponse
    /// The app answered but the frame didn't arrive whole. Distinct from `appNotReachable`
    /// because the app is plainly running — telling the user to check their install would be
    /// wrong, and relaunching it would be pointless.
    case truncatedResponse(FrameReadError)
    /// A whole frame arrived and failed to decode.
    case decodeFailed(Error)

    var description: String {
        switch self {
        case .appNotReachable: return "Couldn't reach iQualize. Is it installed?"
        case .malformedResponse: return "Received a malformed response from iQualize."
        case .truncatedResponse(let reason):
            return "iQualize's response was cut short (\(reason))."
        case .decodeFailed(let error):
            return "Couldn't decode iQualize's response: \(error)"
        }
    }
}

/// Talks to the running app's `CLIControlServer` over the Unix domain socket at
/// `CLIControlPaths.socketPath`. If the app isn't running, launches it and retries for a
/// few seconds before giving up.
enum IQClient {
    static func send(_ request: CLIRequest) throws -> CLIResponse {
        try send(request, attempt: sendOnce, launch: launchApp, wait: { usleep(100_000) })
    }

    /// The retry policy, with its side effects injected so a test can observe them.
    ///
    /// Only a genuine connection failure justifies launching the app and retrying. A
    /// truncated or undecodable response means the app answered — retrying it 50 times and
    /// then blaming the user's install is what made #167 so hard to diagnose.
    static func send(
        _ request: CLIRequest,
        attempt: (CLIRequest) throws -> CLIResponse,
        launch: () -> Void,
        wait: () -> Void,
        retries: Int = 50 // 50 × 100ms — ~5s total before giving up
    ) throws -> CLIResponse {
        do {
            return try attempt(request)
        } catch let error as IQClientError {
            guard case .appNotReachable = error else { throw error }
        }

        launch()
        for _ in 0..<retries {
            wait()
            do {
                return try attempt(request)
            } catch let error as IQClientError {
                guard case .appNotReachable = error else { throw error }
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

        // 30s, not 5 — the OPRA catalog search/import commands do a real network fetch on a
        // cache miss. A longer timeout costs nothing for fast commands; the response arrives
        // as soon as it's ready regardless of how long we're willing to wait.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let data = try? JSONEncoder().encode(request) else {
            throw IQClientError.malformedResponse
        }
        guard UnixSocketIO.writeFrame(data, fd: fd) else { throw IQClientError.appNotReachable }

        let responseData: Data
        do {
            responseData = try UnixSocketIO.readFrame(fd: fd)
        } catch let error as FrameReadError {
            // Nothing at all came back: the app isn't listening in any useful sense, so the
            // launch-and-retry path is the right response. Anything else means it answered.
            if case .noData = error { throw IQClientError.appNotReachable }
            throw IQClientError.truncatedResponse(error)
        }

        do {
            return try JSONDecoder().decode(CLIResponse.self, from: responseData)
        } catch {
            throw IQClientError.decodeFailed(error)
        }
    }
}
