// CaptureClient — launches the iQualizeCapture helper and reads captured
// system audio from its shared-memory ring buffer.
//
// This file is the main app's *consumer* end of the IPC contract documented
// in iQualizeCapture/main.swift. By moving tap creation out of the main app
// process, we make the main app look like a plain media app to coreaudiod —
// preemptible by Continuity for AirPods handoff, just like Spotify.

import Foundation
import Darwin
import os.log

@_silgen_name("shm_open")
private func c_shm_open(_ name: UnsafePointer<CChar>,
                        _ oflag: Int32,
                        _ mode: mode_t) -> Int32

private let clientLog = OSLog(subsystem: "com.iqualize", category: "capture-client")

// Must match Sources/iQualizeCapture/main.swift exactly.
private struct SharedHeader {
    var writeHead: UInt64
    var readHead: UInt64
    var sampleRate: Float64
    var channels: UInt32
    var capacityFloats: UInt32
    var _pad: (UInt64, UInt64, UInt32)
}

final class CaptureClient: @unchecked Sendable {
    private(set) var sampleRate: Float64 = 0
    private(set) var channels: UInt32 = 0
    private(set) var capacityFloats: UInt32 = 0

    /// Fires when the helper process unexpectedly terminates (anything other
    /// than our own `stop()` call). Dispatched to main.
    var onUnexpectedTermination: (@MainActor () -> Void)?

    private var process: Process?
    private var shmFD: Int32 = -1
    private var mappedRegion: UnsafeMutableRawPointer?
    private var mappedSize: size_t = 0
    private var headerPtr: UnsafeMutablePointer<SharedHeader>?
    private var dataPtr: UnsafeMutablePointer<Float>?
    private var mask: UInt64 = 0
    private var intentionallyStopping: Bool = false

    /// Launches the helper, reads the handshake, maps its shared memory.
    /// Throws if anything fails — caller should treat as a hard error.
    func start(helperURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw NSError(domain: "iQualize", code: -100,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Capture helper not found or not executable at \(helperURL.path)"])
        }

        let proc = Process()
        proc.executableURL = helperURL
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardInput = stdinPipe
        // Leave stderr inherited so helper errors land in iQualize's log.
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            if self.intentionallyStopping { return }
            os_log(.error, log: clientLog,
                   "capture helper terminated unexpectedly")
            Task { @MainActor in
                self.onUnexpectedTermination?()
            }
        }
        try proc.run()
        process = proc

        // Read handshake (single JSON line terminated by \n) via POSIX read(2)
        // directly on the pipe FD. FileHandle.read(upToCount:) hangs in this
        // configuration (Process pipes from a GUI-launched .app) — empirically
        // observed even after the helper has written + fsync'd the full line.
        let readFD = stdoutPipe.fileHandleForReading.fileDescriptor
        os_log(.default, log: clientLog,
               "reading handshake from FD %{public}d (helper pid=%{public}d)",
               readFD, proc.processIdentifier)
        var lineData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !lineData.contains(0x0a) {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(readFD, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                lineData.append(buf, count: n)
            } else if n == 0 {
                proc.waitUntilExit()
                throw NSError(domain: "iQualize", code: -102,
                              userInfo: [NSLocalizedDescriptionKey:
                                         "Capture helper exited before handshake (status=\(proc.terminationStatus))"])
            } else {
                if errno == EINTR { continue }
                throw NSError(domain: "iQualize", code: -106,
                              userInfo: [NSLocalizedDescriptionKey:
                                         "read(handshake) errno=\(errno)"])
            }
        }
        if let newlineIdx = lineData.firstIndex(of: 0x0a) {
            lineData = lineData.prefix(upTo: newlineIdx)
        }
        os_log(.default, log: clientLog,
               "handshake bytes=%{public}d line=%{public}@",
               lineData.count,
               String(data: lineData, encoding: .utf8) ?? "<binary>")

        let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] ?? [:]
        os_log(.default, log: clientLog, "parsed JSON keys=%{public}@",
               json.keys.sorted().joined(separator: ","))
        guard let shmName = json["shmName"] as? String,
              let totalSize = json["totalSize"] as? Int,
              let headerSize = json["headerSize"] as? Int,
              let sr = json["sampleRate"] as? Double,
              let ch = json["channels"] as? Int,
              let capFloats = json["ringCapacityFloats"] as? Int else {
            throw NSError(domain: "iQualize", code: -103,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Capture helper sent malformed handshake: \(String(data: lineData, encoding: .utf8) ?? "<binary>")"])
        }
        os_log(.default, log: clientLog,
               "handshake parsed: shm=%{public}@ size=%{public}d sr=%{public}.0f ch=%{public}d",
               shmName, totalSize, sr, ch)

        // Open the same shared memory region the helper created.
        let fd = shmName.withCString { c_shm_open($0, O_RDWR, 0o600) }
        if fd < 0 {
            throw NSError(domain: "iQualize", code: -104,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "shm_open(\(shmName)) failed: errno \(errno)"])
        }
        shmFD = fd

        guard let mapped = mmap(nil, size_t(totalSize),
                                PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            throw NSError(domain: "iQualize", code: -105,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "mmap failed: errno \(errno)"])
        }
        mappedRegion = mapped
        mappedSize = size_t(totalSize)

        headerPtr = mapped.bindMemory(to: SharedHeader.self, capacity: 1)
        dataPtr = mapped.advanced(by: headerSize)
            .bindMemory(to: Float.self, capacity: capFloats)

        sampleRate = sr
        channels = UInt32(ch)
        capacityFloats = UInt32(capFloats)
        mask = UInt64(capFloats - 1)

        os_log(.default, log: clientLog,
               "capture helper ready: pid=%{public}d sr=%{public}.0f ch=%{public}u cap=%{public}d",
               proc.processIdentifier, sr, UInt32(ch), capFloats)
    }

    func stop() {
        intentionallyStopping = true
        if let proc = process {
            // Closing stdin tells the helper's watcher to exit cleanly.
            // SIGTERM is a backup if the watcher isn't fast enough.
            (proc.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
            proc.terminate()
            proc.waitUntilExit()
            process = nil
        }
        if let mapped = mappedRegion {
            munmap(mapped, mappedSize)
            mappedRegion = nil
        }
        if shmFD >= 0 {
            close(shmFD)
            shmFD = -1
        }
        headerPtr = nil
        dataPtr = nil
    }

    /// Read up to `count` interleaved Float32 samples. Returns the actual
    /// count read (less than `count` on underrun). Safe to call from the
    /// AVAudioEngine render thread — only touches mmap'd memory, no syscalls.
    func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard let header = headerPtr, let data = dataPtr else { return 0 }
        let writeHead = header.pointee.writeHead
        var readHead = header.pointee.readHead
        let avail = Int(writeHead &- readHead)
        let toRead = min(count, avail)
        let m = mask
        for i in 0..<toRead {
            dest[i] = data[Int(readHead & m)]
            readHead &+= 1
        }
        header.pointee.readHead = readHead
        return toRead
    }
}
