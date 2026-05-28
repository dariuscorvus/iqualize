// iQualize Capture Helper
//
// Tiny child process spawned by the main iQualize app to host the CATap +
// aggregate IOProc. The main app does NO audio capture itself — it only
// reads captured audio from a shared-memory ring buffer this helper fills.
//
// Why separate processes:
// Empirically (see CONTINUITY.md, 2026-05-28 experiments), a process that
// both (a) owns an active CATap and (b) has a render IOProc on the same
// output device is treated by coreaudiod as non-preemptible by Continuity.
// Killing the iQualize process instantly frees the AirPods for handoff;
// stopping just the render but keeping the tap also frees them. So the
// blocker is the *combination* in one process. Split them and the render
// process becomes a normal media app that Continuity can preempt.

import CoreAudio
import AudioToolbox
import Darwin
import Foundation
import os.log

private let capLog = OSLog(subsystem: "com.iqualize", category: "capture-helper")

// Swift's auto-imported shm_open is unavailable because the POSIX
// declaration is variadic. Re-declare as a fixed-arity C function.
// MARK: - Shared layout

struct SharedHeader {
    var writeHead: UInt64 = 0
    var readHead: UInt64 = 0
    var sampleRate: Float64 = 0
    var channels: UInt32 = 0
    var capacityFloats: UInt32 = 0
    var _pad: (UInt64, UInt64, UInt32) = (0, 0, 0)
}

// MARK: - State (all nonisolated for the IOProc + signal handlers)

// File-backed shared memory in /tmp. Cross-process access works via standard
// POSIX file permissions — no POSIX-shm namespace quirks (which empirically
// reject O_RDWR between two binaries with different code-signing identifiers
// on macOS, even with 0o666 + fchmod).
nonisolated(unsafe) var shmPath: String = "/tmp/iqualize-cap-\(getpid()).bin"
nonisolated(unsafe) var shmFD: Int32 = -1
nonisolated(unsafe) var shmTotalSize: size_t = 0
nonisolated(unsafe) var headerPtr: UnsafeMutablePointer<SharedHeader>? = nil
nonisolated(unsafe) var dataPtr: UnsafeMutablePointer<Float>? = nil
nonisolated(unsafe) var dataMask: UInt64 = 0
nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var aggID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var procID: AudioDeviceIOProcID?

// MARK: - Helpers

func stderrLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func caCheckExit(_ status: OSStatus, _ msg: String, code: Int32) {
    if status != noErr {
        stderrLog("[capture] \(msg): OSStatus \(status)")
        exit(code)
    }
}

@Sendable func cleanup() {
    if aggID != kAudioObjectUnknown {
        if let p = procID {
            AudioDeviceStop(aggID, p)
            if #available(macOS 14.2, *) {
                AudioDeviceDestroyIOProcID(aggID, p)
            }
        }
        AudioHardwareDestroyAggregateDevice(aggID)
    }
    if tapID != kAudioObjectUnknown {
        if #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
    if shmFD >= 0 {
        if let h = headerPtr {
            munmap(UnsafeMutableRawPointer(h), shmTotalSize)
        }
        close(shmFD)
        unlink(shmPath)
    }
}

// MARK: - Entry point (gated on macOS 14.2 for CATap availability)

@available(macOS 14.2, *)
func run() {
    os_log(.default, log: capLog, "run() start  pid=%{public}d ppid=%{public}d", getpid(), getppid())
    // 1. Resolve PIDs to exclude (parent + self) so we don't tap audio
    //    iQualize main or this helper produce.
    let parentPID = getppid()
    var translateAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func pidToObject(_ pid: pid_t) -> AudioObjectID {
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &translateAddr,
            UInt32(MemoryLayout<pid_t>.size), &p,
            &sz, &obj
        )
        return obj
    }

    var excluded: [AudioObjectID] = []
    let parentObj = pidToObject(parentPID)
    if parentObj != kAudioObjectUnknown { excluded.append(parentObj) }
    let ourObj = pidToObject(getpid())
    if ourObj != kAudioObjectUnknown { excluded.append(ourObj) }

    // 2. Create CATap
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
    tapDesc.uuid = UUID()
    tapDesc.muteBehavior = .muted
    tapDesc.name = "iQualize-EQ-Capture"

    os_log(.default, log: capLog, "about to create process tap")
    caCheckExit(
        AudioHardwareCreateProcessTap(tapDesc, &tapID),
        "Failed to create process tap", code: 10
    )
    os_log(.default, log: capLog, "tap created id=%{public}d", tapID)

    // 3. Read tap format
    var formatAddr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var tapFormat = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    caCheckExit(
        AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &tapFormat),
        "Failed to read tap format", code: 11
    )
    let sampleRate = tapFormat.mSampleRate
    let channels = tapFormat.mChannelsPerFrame
    let ringFrames = 16384
    let dataFloatsRaw = ringFrames * Int(channels)
    var pow2 = 1
    while pow2 < dataFloatsRaw { pow2 *= 2 }
    let dataFloatsPow2 = pow2
    dataMask = UInt64(dataFloatsPow2 - 1)

    // 4. Allocate shared memory
    let headerSize = (MemoryLayout<SharedHeader>.stride + 63) & ~63
    let dataBytes = dataFloatsPow2 * MemoryLayout<Float>.size
    shmTotalSize = size_t(headerSize + dataBytes)

    unlink(shmPath)
    shmFD = shmPath.withCString { open($0, O_CREAT | O_RDWR, 0o666) }
    if shmFD < 0 {
        stderrLog("[capture] open(\(shmPath)) failed: errno=\(errno)")
        cleanup(); exit(20)
    }
    // Belt-and-suspenders for cross-process access between differently
    // signed binaries: explicit fchmod after creation.
    _ = fchmod(shmFD, 0o666)
    if ftruncate(shmFD, off_t(shmTotalSize)) != 0 {
        stderrLog("[capture] ftruncate failed: errno=\(errno)")
        cleanup(); exit(21)
    }
    guard let mapped = mmap(nil, shmTotalSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmFD, 0),
          mapped != MAP_FAILED else {
        stderrLog("[capture] mmap failed: errno=\(errno)")
        cleanup(); exit(22)
    }

    headerPtr = mapped.bindMemory(to: SharedHeader.self, capacity: 1)
    headerPtr!.pointee = SharedHeader(
        writeHead: 0, readHead: 0,
        sampleRate: sampleRate,
        channels: channels,
        capacityFloats: UInt32(dataFloatsPow2)
    )
    dataPtr = mapped.advanced(by: headerSize).bindMemory(to: Float.self, capacity: dataFloatsPow2)
    memset(dataPtr, 0, dataBytes)

    // 5. Create aggregate (tap-only) and IOProc
    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "iQualize-Capture-Aggregate",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]
    caCheckExit(
        AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID),
        "Failed to create aggregate", code: 30
    )

    // Wait for device alive
    var aliveAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    for _ in 1...30 {
        var alive: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggID, &aliveAddr, 0, nil, &sz, &alive)
        if alive != 0 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }

    let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
        guard let header = headerPtr, let data = dataPtr else { return }
        let mask = dataMask

        let inBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        var writeHead = header.pointee.writeHead

        for i in 0..<inBufList.count {
            guard let buf = inBufList[i].mData else { continue }
            let count = Int(inBufList[i].mDataByteSize) / MemoryLayout<Float>.size
            let src = buf.assumingMemoryBound(to: Float.self)
            for j in 0..<count {
                data[Int(writeHead & mask)] = src[j]
                writeHead &+= 1
            }
        }
        header.pointee.writeHead = writeHead

        let outBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
        for i in 0..<outBufList.count {
            if let d = outBufList[i].mData {
                memset(d, 0, Int(outBufList[i].mDataByteSize))
            }
        }
    }

    caCheckExit(
        AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, ioBlock),
        "Failed to create IOProc", code: 31
    )
    caCheckExit(
        AudioDeviceStart(aggID, procID),
        "Failed to start aggregate", code: 32
    )
    os_log(.default, log: capLog, "aggregate started, about to handshake")

    // 6. Handshake to parent — use raw write(2) to avoid any Foundation
    //    FileHandle buffering quirks that may arise when our stdout is a pipe.
    let handshake: [String: Any] = [
        "shmPath": shmPath,
        "totalSize": shmTotalSize,
        "headerSize": headerSize,
        "sampleRate": sampleRate,
        "channels": Int(channels),
        "ringCapacityFloats": dataFloatsPow2,
    ]
    let jsonData = try! JSONSerialization.data(withJSONObject: handshake, options: [])
    var lineData = jsonData
    lineData.append(0x0a)  // \n terminator
    let lineCount = lineData.count
    var bytesWritten = 0
    lineData.withUnsafeBytes { buf in
        var remaining = buf.count
        var p = buf.baseAddress!
        while remaining > 0 {
            let n = write(STDOUT_FILENO, p, remaining)
            if n <= 0 {
                os_log(.error, log: capLog,
                       "handshake write returned %{public}d errno=%{public}d",
                       n, errno)
                break
            }
            bytesWritten += n
            remaining -= n
            p = p.advanced(by: n)
        }
    }
    fsync(STDOUT_FILENO)
    os_log(.default, log: capLog,
           "handshake sent: %{public}d/%{public}d bytes  json=%{public}@",
           bytesWritten, lineCount,
           String(data: jsonData, encoding: .utf8) ?? "?")

    // 7. Watch stdin for EOF (parent died) on a background thread
    let stdinThread = Thread {
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 {
                cleanup()
                exit(0)
            }
        }
    }
    stdinThread.start()
}

// Dispatch-based signal handling. C signal handlers run in a context where
// only async-signal-safe functions are allowed; AudioDeviceStop and friends
// are not, so calling cleanup() directly from signal(2) trips Swift's
// dispatch isolation check (EXC_BREAKPOINT). Mask the signals via signal(SIG_IGN)
// so the default action doesn't terminate us, then handle them on a dispatch
// queue where we can call CoreAudio APIs safely.
signal(SIGTERM, SIG_IGN)
signal(SIGINT,  SIG_IGN)
signal(SIGHUP,  SIG_IGN)

let signalQueue = DispatchQueue(label: "com.iqualize.capture.signals")
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
let sigInt  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: signalQueue)
let sigHup  = DispatchSource.makeSignalSource(signal: SIGHUP,  queue: signalQueue)
for src in [sigTerm, sigInt, sigHup] {
    src.setEventHandler { cleanup(); exit(0) }
    src.resume()
}

if #available(macOS 14.2, *) {
    run()
    dispatchMain()
} else {
    stderrLog("[capture] requires macOS 14.2+")
    exit(99)
}
