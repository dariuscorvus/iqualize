import Darwin
import Foundation
import IQControlProtocol

/// Methods the CLI control channel can invoke, implemented by `MenuBarController`. All
/// isolated to the main actor since they touch `AudioEngine`/`PresetStore`/window state.
@available(macOS 14.2, *)
@MainActor
protocol CLICommandHandling: AnyObject {
    func statusSnapshot() -> CLIStatusPayload
    func listPresetSummaries() -> [CLIPresetSummary]
    func resolvePreset(idOrName: String) -> EQPresetData?
    @discardableResult func applyPreset(id: UUID) -> Bool
    func setBypassed(_ bypassed: Bool)
    @discardableResult func toggleBypassed() -> Bool
    func setInputGain(_ db: Float)
    func setOutputGain(_ db: Float)
    func setBalance(_ value: Float)
}

/// Local control channel for the `iqualize` CLI: a Unix domain socket serving one
/// newline-delimited JSON request/response per connection. The app isn't sandboxed, and
/// the socket lives under the user's own (0700) Application Support directory, so no
/// other local user can reach it and no entitlement changes are needed.
///
/// Socket I/O is plain blocking Darwin calls confined to `queue`; only the moment a
/// request is decoded do we hop onto the main actor (via `DispatchQueue.main.sync` +
/// `MainActor.assumeIsolated`, the same bridge already used in `iQualizeApp.swift`'s
/// sleep/wake handlers) to run the command against live app state.
@available(macOS 14.2, *)
final class CLIControlServer: @unchecked Sendable {
    private weak var handler: CLICommandHandling?
    private let socketPath = CLIControlPaths.socketPath
    private let queue = DispatchQueue(label: "com.iqualize.cliserver")
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(handler: CLICommandHandling) {
        self.handler = handler
    }

    func start() {
        guard var addr = UnixSocketIO.makeSockaddrUn(path: socketPath) else {
            NSLog("iQualize: control socket path too long (%d bytes), CLI control disabled: %@",
                  socketPath.utf8.count, socketPath)
            return
        }

        let dir = CLIControlPaths.controlDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            NSLog("iQualize: failed to create control directory: %@", "\(error)")
            return
        }

        // Remove a stale socket file left behind by a previous crash before binding.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("iQualize: failed to create control socket")
            return
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("iQualize: failed to bind control socket (errno %d)", errno)
            close(fd)
            return
        }

        guard listen(fd, 4) == 0 else {
            NSLog("iQualize: failed to listen on control socket (errno %d)", errno)
            close(fd)
            return
        }

        // Parent directory is 0700, but set the socket's own perms explicitly rather than
        // relying on umask behavior.
        chmod(socketPath, 0o600)

        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(socketPath)
    }

    // MARK: - Connection handling (runs on `queue`)

    private func acceptConnection() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        // A well-behaved client (our own CLI) writes its request immediately; don't let a
        // stuck/hostile connection wedge the server open indefinitely.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestData = UnixSocketIO.readLine(fd: clientFD),
              let request = try? JSONDecoder().decode(CLIRequest.self, from: requestData) else {
            Self.writeResponse(.failure("malformed request"), to: clientFD)
            return
        }

        guard let handler else {
            Self.writeResponse(.failure("app not ready"), to: clientFD)
            return
        }

        var response = CLIResponse.failure("internal error")
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                response = Self.handle(request, handler: handler)
            }
        }
        Self.writeResponse(response, to: clientFD)
    }

    @MainActor
    private static func handle(_ request: CLIRequest, handler: CLICommandHandling) -> CLIResponse {
        switch request.command {
        case CLICommand.status:
            return .success(status: handler.statusSnapshot())

        case CLICommand.listPresets:
            return .success(presets: handler.listPresetSummaries())

        case CLICommand.selectPreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            guard let preset = handler.resolvePreset(idOrName: name) else {
                return .failure("no preset named '\(name)'")
            }
            handler.applyPreset(id: preset.id)
            return .success(status: handler.statusSnapshot())

        case CLICommand.setBypass:
            guard let value = request.boolArg else { return .failure("missing bypass value") }
            handler.setBypassed(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.toggleBypass:
            handler.toggleBypassed()
            return .success(status: handler.statusSnapshot())

        case CLICommand.setInputGain:
            guard let db = request.floatArg else { return .failure("missing gain value") }
            handler.setInputGain(db)
            return .success(status: handler.statusSnapshot())

        case CLICommand.setOutputGain:
            guard let db = request.floatArg else { return .failure("missing gain value") }
            handler.setOutputGain(db)
            return .success(status: handler.statusSnapshot())

        case CLICommand.setBalance:
            guard let value = request.floatArg else { return .failure("missing balance value") }
            handler.setBalance(value)
            return .success(status: handler.statusSnapshot())

        default:
            return .failure("unknown command '\(request.command)'")
        }
    }

    // MARK: - Raw I/O helpers

    private static func writeResponse(_ response: CLIResponse, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        UnixSocketIO.writeFrame(data, fd: fd)
    }
}
