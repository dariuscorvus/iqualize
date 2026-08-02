import Darwin
import Foundation
import IQControlProtocol
import os.log

private let cliLog = OSLog(subsystem: "com.iqualize", category: "cli")

enum PresetSwitchPolicy {
    case prompt
    case failIfDirty
    case discard

    func decision(isDirty: Bool) -> PresetSwitchDecision {
        switch self {
        case .prompt:
            return isDirty ? .prompt : .proceed
        case .failIfDirty:
            return isDirty ? .fail : .proceed
        case .discard:
            return .proceed
        }
    }
}

enum PresetSwitchDecision: Equatable {
    case proceed
    case prompt
    case fail
}

/// Methods the CLI control channel can invoke, implemented by `MenuBarController`. All
/// isolated to the main actor since they touch `AudioEngine`/`PresetStore`/window state.
@available(macOS 14.2, *)
@MainActor
protocol CLICommandHandling: AnyObject {
    func statusSnapshot() -> CLIStatusPayload
    func listPresetSummaries() -> [CLIPresetSummary]
    func resolvePreset(idOrName: String) -> EQPresetData?
    @discardableResult func applyPreset(id: UUID, policy: PresetSwitchPolicy) throws -> Bool
    func setBypassed(_ bypassed: Bool)
    @discardableResult func toggleBypassed() -> Bool
    func setInputGain(_ db: Float)
    func setOutputGain(_ db: Float)
    func setBalance(_ value: Float)
    func setPeakLimiter(_ enabled: Bool)
    @discardableResult func togglePeakLimiter() -> Bool
    func setGainIsGlobal(_ global: Bool)
    @discardableResult func toggleGainIsGlobal() -> Bool
    func setPreEqSpectrum(_ enabled: Bool)
    @discardableResult func togglePreEqSpectrum() -> Bool
    func setPostEqSpectrum(_ enabled: Bool)
    @discardableResult func togglePostEqSpectrum() -> Bool
    func setCapture(_ enabled: Bool) async
    @discardableResult func toggleCapture() async -> Bool

    // Band editing
    func listBands() -> [CLIBandSummary]
    func addBand(frequency: Float?, gain: Float?, bandwidth: Float?, filterType: String?) throws -> CLIBandSummary
    func deleteBand(index: Int?, matchFrequency: Float?) throws
    func setBand(index: Int?, matchFrequency: Float?, frequency: Float?, gain: Float?, bandwidth: Float?, filterType: String?) throws -> CLIBandSummary
    func moveBand(index: Int?, matchFrequency: Float?, direction: String) throws -> CLIBandSummary
    func setBandMute(index: Int?, matchFrequency: Float?, muted: Bool) throws -> CLIBandSummary
    @discardableResult func toggleBandMute(index: Int?, matchFrequency: Float?) throws -> CLIBandSummary

    // Preset lifecycle
    @discardableResult func saveActivePreset() -> CLIPresetSummary
    func resetActivePreset()
    func deletePreset(idOrName: String) throws
    func newPreset(name: String?) throws -> CLIPresetSummary
    func renamePreset(idOrName: String, newName: String) throws -> CLIPresetSummary
    func duplicatePreset(idOrName: String, newName: String?) throws -> CLIPresetSummary
    func setFavoritePreset(idOrName: String, favorite: Bool) throws -> Bool
    func toggleFavoritePreset(idOrName: String) throws -> Bool
    func pinPreset(idOrName: String) throws
    func unpinPreset() throws
    func listHiddenPresets() -> [CLIPresetSummary]
    func restoreBuiltInPreset(idOrName: String) throws

    // Import/export
    func importPresetFile(path: String, overwrite: Bool) throws -> CLIPresetSummary
    func exportPreset(idOrName: String?, outputPath: String) throws

    // OPRA catalog
    func searchOPRA(query: String) async throws -> [CLIOPRAProductSummary]
    func importOPRA(query: String, curveAuthor: String?, overwrite: Bool) async throws -> CLIPresetSummary
}

/// Thrown by `CLICommandHandling` methods to surface a user-facing error message.
struct CLIHandlerError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
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

    /// Commands whose handler is `async` (real network I/O, e.g. the OPRA catalog fetch).
    /// These can't go through the synchronous `DispatchQueue.main.sync` bridge below — if
    /// the async work needs to resume back onto the main actor, that would deadlock against
    /// the very thread synchronously blocked waiting for it. Handled via a detached `Task`
    /// instead, which returns control to `acceptConnection`'s caller immediately so the
    /// queue stays free for other (fast, synchronous) connections in the meantime.
    private static let asyncCommands: Set<String> = [
        CLICommand.searchOPRA,
        CLICommand.importOPRA,
        CLICommand.setCapture,
        CLICommand.toggleCapture,
    ]

    private func acceptConnection() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }

        // A well-behaved client (our own CLI) writes its request immediately; don't let a
        // stuck/hostile connection wedge the server open indefinitely.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestData = try? UnixSocketIO.readFrame(fd: clientFD),
              let request = try? JSONDecoder().decode(CLIRequest.self, from: requestData) else {
            Self.writeResponse(.failure("malformed request"), to: clientFD)
            close(clientFD)
            return
        }

        guard let handler else {
            Self.writeResponse(.failure("app not ready"), to: clientFD)
            close(clientFD)
            return
        }

        if Self.asyncCommands.contains(request.command) {
            Task { @MainActor in
                let response = await Self.handleAsync(request, handler: handler)
                Self.writeResponse(response, to: clientFD)
                close(clientFD)
            }
            return
        }

        var response = CLIResponse.failure("internal error")
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                response = Self.handle(request, handler: handler)
            }
        }
        Self.writeResponse(response, to: clientFD)
        close(clientFD)
    }

    @MainActor
    private static func handleAsync(_ request: CLIRequest, handler: CLICommandHandling) async -> CLIResponse {
        switch request.command {
        case CLICommand.searchOPRA:
            guard let query = request.stringArg else { return .failure("missing search query") }
            do {
                return .success(opraProducts: try await handler.searchOPRA(query: query))
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.importOPRA:
            guard let query = request.stringArg else { return .failure("missing search query") }
            do {
                let preset = try await handler.importOPRA(query: query, curveAuthor: request.stringArg2, overwrite: request.boolArg ?? false)
                return .success(presets: [preset])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.setCapture:
            guard let value = request.boolArg else { return .failure("missing capture value") }
            await handler.setCapture(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.toggleCapture:
            _ = await handler.toggleCapture()
            return .success(status: handler.statusSnapshot())

        default:
            return .failure("unknown async command '\(request.command)'")
        }
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
            let policy: PresetSwitchPolicy = request.force == true ? .discard : .failIfDirty
            do {
                guard try handler.applyPreset(id: preset.id, policy: policy) else {
                    return .failure("preset switch was cancelled")
                }
                return .success(status: handler.statusSnapshot())
            } catch let error as CLIHandlerError {
                return .failure(error.message)
            } catch {
                return .failure(error.localizedDescription)
            }

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

        case CLICommand.setPeakLimiter:
            guard let value = request.boolArg else { return .failure("missing peak limiter value") }
            handler.setPeakLimiter(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.togglePeakLimiter:
            handler.togglePeakLimiter()
            return .success(status: handler.statusSnapshot())

        case CLICommand.setGainIsGlobal:
            guard let value = request.boolArg else { return .failure("missing gain-is-global value") }
            handler.setGainIsGlobal(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.toggleGainIsGlobal:
            handler.toggleGainIsGlobal()
            return .success(status: handler.statusSnapshot())

        case CLICommand.setPreEqSpectrum:
            guard let value = request.boolArg else { return .failure("missing pre-EQ spectrum value") }
            handler.setPreEqSpectrum(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.togglePreEqSpectrum:
            handler.togglePreEqSpectrum()
            return .success(status: handler.statusSnapshot())

        case CLICommand.setPostEqSpectrum:
            guard let value = request.boolArg else { return .failure("missing post-EQ spectrum value") }
            handler.setPostEqSpectrum(value)
            return .success(status: handler.statusSnapshot())

        case CLICommand.togglePostEqSpectrum:
            handler.togglePostEqSpectrum()
            return .success(status: handler.statusSnapshot())

        case CLICommand.listBands:
            return .success(bands: handler.listBands())

        case CLICommand.addBand:
            let args = request.bandArgs ?? CLIBandArgs()
            do {
                let band = try handler.addBand(frequency: args.frequency, gain: args.gain, bandwidth: args.bandwidth, filterType: args.filterType)
                return .success(bands: [band])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.deleteBand:
            let args = request.bandArgs ?? CLIBandArgs()
            do {
                try handler.deleteBand(index: args.index, matchFrequency: args.matchFrequency)
                return .success(bands: handler.listBands())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.setBand:
            let args = request.bandArgs ?? CLIBandArgs()
            do {
                let band = try handler.setBand(index: args.index, matchFrequency: args.matchFrequency, frequency: args.frequency, gain: args.gain, bandwidth: args.bandwidth, filterType: args.filterType)
                return .success(bands: [band])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.moveBand:
            let args = request.bandArgs ?? CLIBandArgs()
            guard let direction = args.direction else { return .failure("missing direction") }
            do {
                let band = try handler.moveBand(index: args.index, matchFrequency: args.matchFrequency, direction: direction)
                return .success(bands: [band])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.setBandMute:
            let args = request.bandArgs ?? CLIBandArgs()
            guard let muted = request.boolArg else { return .failure("missing mute value") }
            do {
                let band = try handler.setBandMute(index: args.index, matchFrequency: args.matchFrequency, muted: muted)
                return .success(bands: [band])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.toggleBandMute:
            let args = request.bandArgs ?? CLIBandArgs()
            do {
                let band = try handler.toggleBandMute(index: args.index, matchFrequency: args.matchFrequency)
                return .success(bands: [band])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.saveActivePreset:
            return .success(presets: [handler.saveActivePreset()])

        case CLICommand.resetActivePreset:
            handler.resetActivePreset()
            return .success(status: handler.statusSnapshot())

        case CLICommand.deletePreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            do {
                try handler.deletePreset(idOrName: name)
                return .success(status: handler.statusSnapshot())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.newPreset:
            do {
                let preset = try handler.newPreset(name: request.stringArg)
                return .success(presets: [preset])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.renamePreset:
            guard let name = request.stringArg, let newName = request.stringArg2 else { return .failure("missing old/new name") }
            do {
                let preset = try handler.renamePreset(idOrName: name, newName: newName)
                return .success(presets: [preset])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.duplicatePreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            do {
                let preset = try handler.duplicatePreset(idOrName: name, newName: request.stringArg2)
                return .success(presets: [preset])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.setFavoritePreset:
            guard let name = request.stringArg, let favorite = request.boolArg else { return .failure("missing preset name or favorite value") }
            do {
                _ = try handler.setFavoritePreset(idOrName: name, favorite: favorite)
                return .success(presets: handler.listPresetSummaries())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.toggleFavoritePreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            do {
                _ = try handler.toggleFavoritePreset(idOrName: name)
                return .success(presets: handler.listPresetSummaries())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.pinPreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            do {
                try handler.pinPreset(idOrName: name)
                return .success(status: handler.statusSnapshot())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.unpinPreset:
            do {
                try handler.unpinPreset()
                return .success(status: handler.statusSnapshot())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.listHiddenPresets:
            return .success(presets: handler.listHiddenPresets())

        case CLICommand.restoreBuiltInPreset:
            guard let name = request.stringArg else { return .failure("missing preset name") }
            do {
                try handler.restoreBuiltInPreset(idOrName: name)
                return .success(presets: handler.listHiddenPresets())
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.importPresetFile:
            guard let path = request.stringArg else { return .failure("missing file path") }
            do {
                let preset = try handler.importPresetFile(path: path, overwrite: request.boolArg ?? false)
                return .success(presets: [preset])
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        case CLICommand.exportPreset:
            guard let outputPath = request.stringArg2 else { return .failure("missing output path") }
            do {
                try handler.exportPreset(idOrName: request.stringArg, outputPath: outputPath)
                return .success()
            } catch let e as CLIHandlerError { return .failure(e.message) } catch { return .failure(error.localizedDescription) }

        default:
            return .failure("unknown command '\(request.command)'")
        }
    }

    // MARK: - Raw I/O helpers

    private static func writeResponse(_ response: CLIResponse, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(response) else {
            os_log(.error, log: cliLog, "failed to encode CLI response")
            return
        }
        // A dropped response leaves the CLI reporting a transport failure with no trace on
        // this side; #167 was diagnosed the hard way for exactly that reason.
        if !UnixSocketIO.writeFrame(data, fd: fd) {
            os_log(.error, log: cliLog,
                   "failed to write %{public}d-byte CLI response errno=%{public}d",
                   data.count, errno)
        }
    }
}
