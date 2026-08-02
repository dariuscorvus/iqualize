// iQualize Capture Helper
//
// Tiny child process spawned by the main iQualize app to host the CATap +
// aggregate IOProc. The main app does NO audio capture itself — it only
// reads captured audio from a shared-memory ring buffer this helper fills.
//
// Why separate processes:
// Empirically (see docs/CONTINUITY.md, 2026-05-28 experiments), a process that
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
import IQRingAtomics
import os.log

private let capLog = OSLog(subsystem: "com.iqualize", category: "capture-helper")

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
/// Points at headerPtr.pointee.writeHead — the one field published across
/// processes with release semantics (see iq_ring_atomics.h).
nonisolated(unsafe) var writeHeadFieldPtr: UnsafeMutablePointer<UInt64>? = nil
nonisolated(unsafe) var dataPtr: UnsafeMutablePointer<Float>? = nil
nonisolated(unsafe) var dataMask: UInt64 = 0
nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var aggID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var procID: AudioDeviceIOProcID?
nonisolated(unsafe) var tapDescription: AnyObject?
nonisolated(unsafe) var baseExcludedObjects: [AudioObjectID] = []
nonisolated(unsafe) var excludedMicUsers: Set<AudioObjectID> = []
nonisolated(unsafe) var micPollTimer: DispatchSourceTimer?
/// Process objects seen at the last poll, for spotting newly-launched apps (#140).
nonisolated(unsafe) var knownProcessObjects: Set<AudioObjectID> = []
/// Newly-appeared processes still being watched for output, and the polls each has
/// left. A process registers with the HAL before it starts playing, so checking
/// once at appearance would miss nearly everyone.
nonisolated(unsafe) var pendingNewProcesses: [AudioObjectID: Int] = [:]

// MARK: - Helpers

func stderrLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func caCheckExit(_ status: OSStatus, _ msg: String, code: Int32) {
    if status != noErr {
        stderrLog("[capture] \(msg): OSStatus \(status)")
        cleanupOnce()
        exit(code)
    }
}

@Sendable func cleanup() {
    micPollTimer?.cancel()
    micPollTimer = nil
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

// The stdin-EOF watcher thread and the SIGTERM dispatch handler both race to
// call cleanup() on shutdown (CaptureClient.stop() closes stdin and sends
// SIGTERM with no gap between them, as a belt-and-suspenders pair). Guard so
// cleanup only actually runs once — otherwise both paths can fire concurrently
// and double-tear-down the same CoreAudio objects and mapped memory.
private let cleanupLock = NSLock()
nonisolated(unsafe) private var didCleanup = false

@Sendable func cleanupOnce() {
    cleanupLock.lock()
    defer { cleanupLock.unlock() }
    guard !didCleanup else { return }
    didCleanup = true
    cleanup()
}

// MARK: - Call exclusion (#131)
//
// While a process runs a voice session (WhatsApp/FaceTime/the phone-relay
// daemon hold the microphone), macOS ducks all "other audio" on the output
// device but exempts the session owner's own stream. Tapping + muting a call
// app and re-rendering its voice through the main app's engine turns that
// voice into "other audio" — the OS ducks it (~18 dB measured, #131) and
// calls sound far too quiet. Excluding mic-holding processes from the tap
// lets their audio play natively at session-owner volume. Their audio skips
// the EQ while they hold the mic and returns to the tap when they release it.
//
// Polled, not listened: the process-list property listener goes silent for a
// process that itself holds an active CATap (#87) — assume per-process
// properties behave the same and poll.

func processObjectList() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func processFlag(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
}

/// A call runs BOTH directions: mic capture and voice playback. Requiring
/// both keeps mic-only processes (dictation, screen recording, audio
/// measurement tools) in the tap — excluding them buys nothing and every
/// description update churns the live tap.
func processInCall(_ obj: AudioObjectID) -> Bool {
    processFlag(obj, kAudioProcessPropertyIsRunningInput)
        && processFlag(obj, kAudioProcessPropertyIsRunningOutput)
}

func processLogName(_ obj: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var bundleID: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let err = withUnsafeMutablePointer(to: &bundleID) { ptr in
        AudioObjectGetPropertyData(obj, &address, 0, nil, &size, ptr)
    }
    let bid = err == noErr ? (bundleID as String) : ""
    return bid.isEmpty ? "audio object \(obj)" : bid
}

func micUsingProcesses() -> Set<AudioObjectID> {
    Set(processObjectList().filter(processInCall))
}

/// Push the current exclusion list (base + mic users) into the live tap.
/// kAudioTapPropertyDescription is documented settable on an existing tap.
@available(macOS 14.2, *)
func applyTapExclusions() {
    guard let desc = tapDescription as? CATapDescription,
          tapID != kAudioObjectUnknown else { return }
    desc.processes = baseExcludedObjects + excludedMicUsers.filter { !baseExcludedObjects.contains($0) }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var descRef: CATapDescription? = desc
    let err = withUnsafeMutablePointer(to: &descRef) { ptr in
        AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                   UInt32(MemoryLayout<CATapDescription?>.stride), ptr)
    }
    if err != noErr {
        os_log(.error, log: capLog, "tap description update failed: OSStatus %{public}d", err)
    }
}

/// Refresh the live tap when a newly-launched app starts playing.
///
/// A global tap is supposed to cover processes that start after it was created, but
/// #87 saw a late-launched app end up muted with its audio silently dropped rather
/// than routed. The main app used to fix that by restarting the whole tap, which
/// tore down this helper and spliced ~100 ms of silence into playback (#140). Setting
/// kAudioTapPropertyDescription on the live tap re-resolves it in place instead —
/// verified returning noErr here in the helper, with the IOProc running.
///
/// Only newly-appeared processes that actually start playing trigger a refresh.
/// Most process objects never play — measured 5 of 7 over a 30 s window — and every
/// description update churns the live tap, so refreshing on bare list growth would
/// trade a rare dropout for constant churn.
@available(macOS 14.2, *)
func pollNewOutputProcesses() {
    let current = Set(processObjectList())
    let firstPass = knownProcessObjects.isEmpty
    for appeared in current.subtracting(knownProcessObjects) {
        pendingNewProcesses[appeared] = newProcessWatchPolls
    }
    knownProcessObjects = current
    // run() seeds the tap against the processes alive at creation, so the first
    // poll's "new" processes are just that baseline.
    if firstPass { pendingNewProcesses.removeAll(); return }

    var startedOutput: [AudioObjectID] = []
    for (obj, pollsLeft) in pendingNewProcesses {
        guard current.contains(obj) else { pendingNewProcesses[obj] = nil; continue }
        if processFlag(obj, kAudioProcessPropertyIsRunningOutput) {
            pendingNewProcesses[obj] = nil
            startedOutput.append(obj)
        } else if pollsLeft <= 1 {
            pendingNewProcesses[obj] = nil
        } else {
            pendingNewProcesses[obj] = pollsLeft - 1
        }
    }
    guard !startedOutput.isEmpty else { return }

    applyTapExclusions()
    for obj in startedOutput {
        os_log(.default, log: capLog,
               "new output process %{public}@ — tap refreshed in place", processLogName(obj))
    }
}

/// How long a new process stays under observation, in poll ticks (1 s each).
let newProcessWatchPolls = 8

@available(macOS 14.2, *)
func pollMicUsers() {
    let mic = micUsingProcesses()
    guard mic != excludedMicUsers else { return }
    let added = mic.subtracting(excludedMicUsers)
    let removed = excludedMicUsers.subtracting(mic)
    excludedMicUsers = mic
    applyTapExclusions()
    for obj in added {
        os_log(.default, log: capLog,
               "call exclusion: +%{public}@ (holds mic, plays direct)", processLogName(obj))
    }
    for obj in removed {
        os_log(.default, log: capLog,
               "call exclusion: -%{public}@ (released mic, back through EQ)", processLogName(obj))
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
    baseExcludedObjects = excluded

    // Also exclude anything already holding the mic — a call may be in
    // progress when the tap is created, including on tap restarts (#131).
    excludedMicUsers = micUsingProcesses()
    for obj in excludedMicUsers where !baseExcludedObjects.contains(obj) {
        excluded.append(obj)
        os_log(.default, log: capLog,
               "call exclusion at start: %{public}@", processLogName(obj))
    }

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
    tapDescription = tapDesc
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
        cleanupOnce(); exit(20)
    }
    // Belt-and-suspenders for cross-process access between differently
    // signed binaries: explicit fchmod after creation.
    _ = fchmod(shmFD, 0o666)
    if ftruncate(shmFD, off_t(shmTotalSize)) != 0 {
        stderrLog("[capture] ftruncate failed: errno=\(errno)")
        cleanupOnce(); exit(21)
    }
    guard let mapped = mmap(nil, shmTotalSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmFD, 0),
          mapped != MAP_FAILED else {
        stderrLog("[capture] mmap failed: errno=\(errno)")
        cleanupOnce(); exit(22)
    }

    headerPtr = mapped.bindMemory(to: SharedHeader.self, capacity: 1)
    headerPtr!.pointee = SharedHeader(
        writeHead: 0, readHead: 0,
        sampleRate: sampleRate,
        channels: channels,
        capacityFloats: UInt32(dataFloatsPow2)
    )
    writeHeadFieldPtr = mapped
        .advanced(by: MemoryLayout<SharedHeader>.offset(of: \.writeHead)!)
        .assumingMemoryBound(to: UInt64.self)
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
        guard let header = headerPtr, let data = dataPtr,
              let writeHeadField = writeHeadFieldPtr else { return }
        let mask = dataMask

        let inBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        // Plain load: this IOProc thread is the only writer of writeHead.
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
        // Release-store pairs with the reader's acquire-load: the sample
        // stores above must be visible before the advanced head is.
        iq_store_release_u64(writeHeadField, writeHead)

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
           "handshake sent: %{public}d/%{public}d bytes  sr=%{public}.0f ch=%{public}u",
           bytesWritten, lineCount, sampleRate, channels)

    // 7. Watch stdin for EOF (parent died) on a background thread
    let stdinThread = Thread {
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 {
                cleanupOnce()
                exit(0)
            }
        }
    }
    stdinThread.start()

    // 8. Watch for processes starting/stopping mic use (calls) and update the tap's
    //    exclusion list live (#131), and for newly-launched apps starting playback,
    //    refreshing the tap in place rather than restarting it (#140).
    //    dispatchMain() below services the main queue.
    knownProcessObjects = Set(processObjectList())
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
    timer.setEventHandler {
        pollMicUsers()
        pollNewOutputProcesses()
    }
    timer.resume()
    micPollTimer = timer
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

let signalQueue = DispatchQueue(label: "codes.darius.iqualize.capture.signals")
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
let sigInt  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: signalQueue)
let sigHup  = DispatchSource.makeSignalSource(signal: SIGHUP,  queue: signalQueue)
for src in [sigTerm, sigInt, sigHup] {
    src.setEventHandler { cleanupOnce(); exit(0) }
    src.resume()
}

if #available(macOS 14.2, *) {
    run()
    dispatchMain()
} else {
    stderrLog("[capture] requires macOS 14.2+")
    exit(99)
}
