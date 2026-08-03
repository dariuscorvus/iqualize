// CaptureClient — launches the iQualizeCapture helper and reads captured
// system audio from its shared-memory ring buffer.
//
// This file is the main app's *consumer* end of the IPC contract documented
// in iQualizeCapture/main.swift. By moving tap creation out of the main app
// process, we make the main app look like a plain media app to coreaudiod —
// preemptible by Continuity for AirPods handoff, just like Spotify.

import Foundation
import Darwin
import IQCaptureProtocol
import IQRingAtomics
import os.log

private let clientLog = OSLog(subsystem: "com.iqualize", category: "capture-client")

enum CaptureClientError: Error, LocalizedError, Equatable, Sendable {
    case helperMissing(path: String)
    case handshakeTimeout(seconds: Double)
    case malformedHandshake
    case helperStartupFailed(CaptureStartupFailure)
    case unexpectedExit(status: Int32, signaled: Bool)
    case handshakeReadFailed(errno: Int32)
    case sharedMemoryOpenFailed(errno: Int32)
    case sharedMemoryStatFailed(errno: Int32)
    case sharedMemoryMapFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .helperMissing(let path):
            return "Capture helper is missing or not executable at \(path)."
        case .handshakeTimeout(let seconds):
            return "Capture helper handshake timed out after \(seconds) seconds."
        case .malformedHandshake:
            return "Capture helper sent a malformed startup message."
        case .helperStartupFailed(let failure):
            return "Capture helper failed during \(failure.stage.rawValue) with exit code \(failure.exitCode)."
        case .unexpectedExit(let status, let signaled):
            return signaled
                ? "Capture helper terminated by signal \(status) before the handshake."
                : "Capture helper exited with status \(status) before the handshake."
        case .handshakeReadFailed(let errno):
            return "Capture helper handshake read failed with errno \(errno)."
        case .sharedMemoryOpenFailed(let errno):
            return "Capture helper shared memory open failed with errno \(errno)."
        case .sharedMemoryStatFailed(let errno):
            return "Capture helper shared memory stat failed with errno \(errno)."
        case .sharedMemoryMapFailed(let errno):
            return "Capture helper shared memory mapping failed with errno \(errno)."
        }
    }
}

// The shared-memory layout and handshake validation live in IQCaptureProtocol
// (SharedHeader, CaptureGeometry) — one definition shared with the helper.

final class CaptureClient: @unchecked Sendable {
    static let defaultHandshakeTimeoutNanoseconds: UInt64 = 10_000_000_000

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

    // Cached field pointers into the shared header, so every cross-process
    // atomic access goes through one audited pointer per field.
    private var writeHeadPtr: UnsafeMutablePointer<UInt64>?
    private var readHeadPtr: UnsafeMutablePointer<UInt64>?
    private var capacityFrames: Int = 0
    private var baseTargetFill: Int = 0
    private let handshakeTimeoutNanoseconds: UInt64

    // Drift-compensator state (#133). Render-thread-only, same single-consumer
    // contract as the old read(): no synchronization needed.
    private enum DriftState { case seeding, running }
    private var driftState: DriftState = .seeding
    /// Absolute source read position: integer frames + fraction in [0, 1).
    /// Kept split (not one Double) so precision never degrades with uptime.
    private var srcFrame: UInt64 = 0
    private var srcFrac: Double = 0
    private var fillEMA: Double = 0
    /// Head position when we entered .seeding. Re-seeding waits until the
    /// writer has produced a full target *beyond* this, so recovery always
    /// lands on fresh audio — gating on the absolute head would re-seed
    /// instantly against a stalled writer and loop-replay the last ~2 s.
    private var seedFloorFrames: UInt64 = 0
    /// High-water mark of callback sizes. The effective target is at least
    /// 2× this, so a pathologically large slice (e.g. 4096 frames) re-seeds
    /// once at a workable fill instead of latching into permanent underrun.
    private var maxCallbackFrames: Int = 0

    // Telemetry, published from the render thread with relaxed stores and
    // read by telemetrySnapshot() on any thread. Counters reset whenever a
    // new CaptureClient is built — i.e. on every capture (re)start.
    private let telemetrySlots: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 4)
        p.initialize(repeating: 0, count: 4)
        return p
    }()
    private enum TelemetrySlot {
        static let fillFrames = 0
        static let driftPpmBits = 1
        static let underruns = 2
        static let overrunResyncs = 3
    }

    struct Telemetry: Sendable {
        var fillFrames: Int
        var driftPpm: Double
        var underruns: UInt64
        var overrunResyncs: UInt64
    }

    init(handshakeTimeoutNanoseconds: UInt64 = CaptureClient.defaultHandshakeTimeoutNanoseconds) {
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
    }

    func telemetrySnapshot() -> Telemetry {
        Telemetry(
            fillFrames: Int(truncatingIfNeeded: iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.fillFrames)),
            driftPpm: Double(bitPattern: iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.driftPpmBits)),
            underruns: iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.underruns),
            overrunResyncs: iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.overrunResyncs)
        )
    }

    deinit {
        telemetrySlots.deallocate()
    }

    /// Launches the helper, reads the handshake, maps its shared memory.
    /// Throws if anything fails — caller should treat as a hard error.
    func start(helperURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw CaptureClientError.helperMissing(path: helperURL.path)
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

        do {
            intentionallyStopping = false
            try proc.run()
            process = proc

            // Read the single JSON handshake line with a poll deadline. A
            // blocking read here runs on the main actor and used to leave the
            // entire app wedged when the helper stopped making progress.
            let readFD = stdoutPipe.fileHandleForReading.fileDescriptor
            var lineData = try readHandshake(from: readFD, process: proc)
            if let newlineIdx = lineData.firstIndex(of: 0x0a) {
                lineData = lineData.prefix(upTo: newlineIdx)
            }

            let helperFailure: CaptureStartupFailure?
            do {
                helperFailure = try CaptureStartupFailure.decodeIfPresent(from: lineData)
            } catch {
                throw CaptureClientError.malformedHandshake
            }
            if let helperFailure {
                throw CaptureClientError.helperStartupFailed(helperFailure)
            }

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                throw CaptureClientError.malformedHandshake
            }
            guard let shmPath = json["shmPath"] as? String,
                  let totalSize = json["totalSize"] as? Int,
                  let headerSize = json["headerSize"] as? Int,
                  let sr = json["sampleRate"] as? Double,
                  let ch = json["channels"] as? Int,
                  let capFloats = json["ringCapacityFloats"] as? Int else {
                throw CaptureClientError.malformedHandshake
            }

            let layoutVersion: UInt32?
            if let rawLayoutVersion = json["layoutVersion"] {
                guard let intLayoutVersion = rawLayoutVersion as? Int,
                      let exactLayoutVersion = UInt32(exactly: intLayoutVersion) else {
                    throw CaptureProtocolError.invalidGeometry("layoutVersion=\(rawLayoutVersion)")
                }
                layoutVersion = exactLayoutVersion
            } else {
                layoutVersion = nil
            }

            // Absent layoutVersion means a legacy version-1 helper. Validate
            // the version and every geometry value before any of it reaches
            // mmap, bindMemory, the ring mask, or a division (#175).
            let geometry = CaptureGeometry(
                layoutVersion: layoutVersion,
                totalSize: totalSize, headerSize: headerSize,
                sampleRate: sr, channels: ch, capacityFloats: capFloats)
            try geometry.validate()

            // Open the file-backed shared memory region the helper created.
            let fd = shmPath.withCString { open($0, O_RDWR) }
            if fd < 0 {
                throw CaptureClientError.sharedMemoryOpenFailed(errno: errno)
            }
            shmFD = fd

            var statBuffer = stat()
            guard fstat(fd, &statBuffer) == 0 else {
                throw CaptureClientError.sharedMemoryStatFailed(errno: errno)
            }
            guard statBuffer.st_size == off_t(totalSize) else {
                throw CaptureProtocolError.invalidGeometry(
                    "fileSize=\(statBuffer.st_size), expected totalSize=\(totalSize)")
            }

            guard let mapped = mmap(nil, size_t(totalSize),
                                    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  mapped != MAP_FAILED else {
                throw CaptureClientError.sharedMemoryMapFailed(errno: errno)
            }
            mappedRegion = mapped
            mappedSize = size_t(totalSize)

            // Unlink the backing file now that both sides hold it mapped. The
            // storage stays alive via our + the helper's open fd/mmap regardless
            // of how either process later exits (crash, SIGKILL, whatever) — the
            // OS reclaims it once both fds close, with no dependence on either
            // side's cleanup code actually running. Also closes the window where
            // a predictable, world-writable path in /tmp is reachable by name.
            _ = shmPath.withCString { unlink($0) }

            // The handshake and the mapped header describe the same region
            // through two channels; a disagreement means the shm writer is
            // not the binary that sent this handshake — refuse to attach.
            try geometry.validate(
                against: mapped.bindMemory(to: SharedHeader.self, capacity: 1).pointee)

            attach(region: mapped, headerSize: headerSize,
                   capacityFloats: capFloats, sampleRate: sr, channels: UInt32(ch))

            os_log(.default, log: clientLog,
                   "capture helper ready: pid=%{public}d sr=%{public}.0f ch=%{public}u cap=%{public}d target=%{public}d",
                   proc.processIdentifier, sr, UInt32(ch), capFloats, baseTargetFill)
        } catch {
            // The caller cannot own this client until start() succeeds, so
            // failed handshakes must release the process and any mapped state
            // here rather than relying on AudioEngine teardown.
            stop()
            throw error
        }
    }

    private func readHandshake(from fd: Int32, process: Process) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ handshakeTimeoutNanoseconds
        var lineData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)

        while !lineData.contains(0x0a) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw CaptureClientError.handshakeTimeout(
                    seconds: Double(handshakeTimeoutNanoseconds) / 1_000_000_000
                )
            }

            let remaining = deadline - now
            let timeoutMilliseconds = min(
                UInt64(Int32.max),
                max(1, (remaining + 999_999) / 1_000_000)
            )
            var descriptor = pollfd(
                fd: fd,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let ready = poll(&descriptor, 1, Int32(timeoutMilliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw CaptureClientError.handshakeReadFailed(errno: errno)
            }
            if ready == 0 {
                throw CaptureClientError.handshakeTimeout(
                    seconds: Double(handshakeTimeoutNanoseconds) / 1_000_000_000
                )
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw CaptureClientError.handshakeReadFailed(errno: EBADF)
            }

            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                lineData.append(buf, count: n)
                if lineData.count > CaptureStartupFailure.maxLineBytes {
                    throw CaptureClientError.malformedHandshake
                }
            } else if n == 0 {
                process.waitUntilExit()
                throw CaptureClientError.unexpectedExit(
                    status: process.terminationStatus,
                    signaled: process.terminationReason == .uncaughtSignal
                )
            } else if errno != EINTR {
                throw CaptureClientError.handshakeReadFailed(errno: errno)
            }
        }
        return lineData
    }

    /// Binds an already-mapped ring region and derives the drift-compensator
    /// parameters. Split out of start() so the resampler tests can drive a
    /// synthetic ring they allocate themselves — no helper process, no mmap.
    func attach(region: UnsafeMutableRawPointer, headerSize: Int,
                capacityFloats capFloats: Int, sampleRate sr: Float64, channels ch: UInt32) {
        headerPtr = region.bindMemory(to: SharedHeader.self, capacity: 1)
        dataPtr = region.advanced(by: headerSize)
            .bindMemory(to: Float.self, capacity: capFloats)
        writeHeadPtr = region
            .advanced(by: MemoryLayout<SharedHeader>.offset(of: \.writeHead)!)
            .assumingMemoryBound(to: UInt64.self)
        readHeadPtr = region
            .advanced(by: MemoryLayout<SharedHeader>.offset(of: \.readHead)!)
            .assumingMemoryBound(to: UInt64.self)

        sampleRate = sr
        channels = ch
        capacityFloats = UInt32(capFloats)
        mask = UInt64(capFloats - 1)
        capacityFrames = capFloats / Int(ch)
        baseTargetFill = DriftPolicy.targetFillFrames(sampleRate: sr, capacityFrames: capacityFrames)

        driftState = .seeding
        seedFloorFrames = 0
        srcFrame = 0
        srcFrac = 0
        fillEMA = 0
        maxCallbackFrames = 0
    }

    func stop() {
        intentionallyStopping = true
        if let proc = process {
            // Closing stdin tells the helper's watcher to exit cleanly.
            // SIGTERM is a backup if the watcher isn't fast enough.
            (proc.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
            if proc.isRunning {
                proc.terminate()
            }
            // Bounded grace before SIGKILL: the helper's SIGTERM path unlinks
            // its shm file and tears down its CoreAudio objects, and an
            // immediate SIGKILL forfeits that cleanup. Production helpers
            // exit on stdin-EOF in well under this.
            let killDeadline = DispatchTime.now().uptimeNanoseconds &+ 500_000_000
            while proc.isRunning && DispatchTime.now().uptimeNanoseconds < killDeadline {
                usleep(10_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
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
        writeHeadPtr = nil
        readHeadPtr = nil
    }

    /// Drift-compensated read for the render callback (#133): pulls `frames`
    /// interleaved frames from the ring, resampling by a ratio a hair off 1.0
    /// (Catmull-Rom, fill-level P-controller — see DriftPolicy) so the two
    /// unlocked device clocks never walk the ring into an edge.
    ///
    /// All-or-nothing: returns `frames` with `dest` fully written, or 0 while
    /// seeding / after an underrun (caller outputs silence). Render thread
    /// only. Only touches mapped memory — no syscalls, no allocation.
    func readResampled(_ dest: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard let data = dataPtr, let writeHeadField = writeHeadPtr,
              let readHeadField = readHeadPtr, frames > 0 else { return 0 }
        let ch = Int(channels)
        let chU = UInt64(channels)

        // One acquire-load snapshot per callback, paired with the helper's
        // release-store: every sample behind this head is visible. Floor to
        // whole frames; a torn partial frame at the head is treated as
        // unwritten.
        let writeFrames = iq_load_acquire_u64(writeHeadField) / chU

        if frames > maxCallbackFrames { maxCallbackFrames = frames }
        let effTarget = max(baseTargetFill, 2 * maxCallbackFrames)

        if driftState == .seeding {
            // Wait for a full target of audio past the seed floor (+1 so the
            // interpolator's left neighbor exists), then start exactly
            // `effTarget` behind the writer — the operating point is chosen,
            // not startup-race-determined.
            guard writeFrames >= seedFloorFrames &+ UInt64(effTarget) &+ 1 else {
                iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.fillFrames, 0)
                iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.driftPpmBits, Double(0).bitPattern)
                return 0
            }
            srcFrame = DriftPolicy.seedPosition(writeFrames: writeFrames, targetFill: effTarget)
            srcFrac = 0
            fillEMA = Double(effTarget)
            driftState = .running
        }

        var fill = Double(writeFrames &- srcFrame) - srcFrac

        // Reader stalled long enough for the backlog to exceed the overrun
        // threshold: jump back to target rather than splicing out minutes of
        // backlog at 500 ppm. Instantaneous check — a stall is a step, not
        // drift, so the EMA must not see it.
        let overrunThreshold = DriftPolicy.overrunThresholdFrames(
            targetFill: effTarget, capacityFrames: capacityFrames)
        if fill > Double(overrunThreshold) {
            iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.overrunResyncs,
                                 iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.overrunResyncs) &+ 1)
            srcFrame = DriftPolicy.seedPosition(writeFrames: writeFrames, targetFill: effTarget)
            srcFrac = 0
            fillEMA = Double(effTarget)
            fill = Double(effTarget)
        }

        // The fill this callback measured (post-reseed if one happened) — the
        // quantity the controller regulates, and what telemetry reports.
        let measuredFill = fill

        let alpha = DriftPolicy.emaAlpha(frames: frames, sampleRate: sampleRate)
        fillEMA += alpha * (fill - fillEMA)
        let ratio = DriftPolicy.resampleRatio(fillEMA: fillEMA, targetFill: Double(effTarget),
                                              sampleRate: sampleRate)

        // Source span this callback will touch, including the interpolator's
        // +2 lookahead. Not enough data means the writer stalled — the target
        // is ~4× a normal callback, so this is never tight timing. Zero-fill,
        // count once, and wait in .seeding for fresh post-stall audio.
        let span = UInt64(Double(frames) * ratio + srcFrac) &+ UInt64(DriftPolicy.windowMarginFrames)
        if srcFrame &+ span >= writeFrames {
            iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.underruns,
                                 iq_load_relaxed_u64(telemetrySlots + TelemetrySlot.underruns) &+ 1)
            driftState = .seeding
            seedFloorFrames = writeFrames
            iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.fillFrames, 0)
            return 0
        }

        // Interpolating copy. No separate history buffer: the ring behind the
        // read position stays valid for capacity − fill ≈ 300 ms, so x[-1] is
        // always resident, and the span check above bounds x[+2].
        var idx = srcFrame
        var frac = srcFrac
        let m = mask
        for f in 0..<frames {
            let t = Float(frac)
            let base = (idx &- 1) &* chU
            for c in 0..<ch {
                let cU = UInt64(c)
                let xm1 = data[Int((base &+ cU) & m)]
                let x0 = data[Int((base &+ chU &+ cU) & m)]
                let x1 = data[Int((base &+ 2 &* chU &+ cU) & m)]
                let x2 = data[Int((base &+ 3 &* chU &+ cU) & m)]
                dest[f * ch + c] = DriftPolicy.catmullRom(xm1, x0, x1, x2, t)
            }
            frac += ratio
            let carry = Int(frac)   // 0 or 1: ratio ≤ 1 + 500 ppm
            idx &+= UInt64(carry)
            frac -= Double(carry)
        }
        srcFrame = idx
        srcFrac = frac

        // Floor of the fractional position, release-published for symmetry
        // and tooling — the writer never reads it.
        iq_store_release_u64(readHeadField, srcFrame &* chU)
        iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.fillFrames,
                             UInt64(max(0, measuredFill.rounded())))
        iq_store_relaxed_u64(telemetrySlots + TelemetrySlot.driftPpmBits,
                             ((ratio - 1) * 1e6).bitPattern)
        return frames
    }

    /// Raw-pointer bridge for the audio callback. AudioEngine's publication
    /// quiescence protocol keeps the owning CaptureClient alive until every
    /// reader has left, so this conversion never takes ownership or performs
    /// callback-side ARC traffic.
    static func readResampledRT(
        _ opaque: UnsafeMutableRawPointer,
        destination: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Int {
        let client = Unmanaged<CaptureClient>.fromOpaque(opaque).takeUnretainedValue()
        return client.readResampled(destination, frames: frames)
    }
}
