// TapProcessRefresh — does a live CATap pick up a process that launched after it?
//
// Answers the blocking question in issue #140: AudioEngine currently does a full
// stop()+start() whenever a new Core Audio process appears (#87), splicing ~100 ms
// of silence into playback. The capture helper already updates the live tap's
// description in place for mic exclusions (#131, main.swift:185-202), but that only
// proves *exclusion* changes take effect — not that a refresh makes the tap
// re-resolve membership and pick up a newly-launched app.
//
// Method: create a global tap, then start a tone process AFTER the tap exists and
// measure RMS through the tap across four phases.
//
//   A  baseline        nothing playing              expect silence
//   B  late process    tone started after the tap   silence here = #87 reproduced
//   C  description     re-set kAudioTapPropertyDescription, list unchanged
//   D  tap list        re-set the aggregate's kAudioAggregateDeviceTapListKey
//   E  full rebuild    tear down and recreate tap + aggregate  (CONTROL)
//
// Phase E is the control and is what makes a negative result meaningful: it is the
// thing production does today, so it must show the tone. If E is silent too, the
// tone never reached the tap and the run says nothing about C or D.
//
// Usage: swift run TapProcessRefresh
// Needs audio-capture TCC permission; run it from a terminal that has it.
//
// READ THIS BEFORE TRUSTING A NEGATIVE RESULT.
//
// This spike runs as a bare terminal binary, which is NOT the context the capture
// helper runs in. The helper is signed, bundled, and carries the app's TCC grant.
// That difference already produced one wrong conclusion: setting
// kAudioTapPropertyDescription returns '!hog' (kAudioDevicePermissionsError) here at
// every point in a tap's life, and it was briefly taken as proof that live tap
// updates are impossible. Probed inside the real helper the same call returns noErr.
// The tap-refresh path in iQualizeCapture is built on that, and works.
//
// Creating a tap and capturing audio both succeed here, which is exactly what makes
// the permissions error misleading — the rig looks fully functional. So: a POSITIVE
// result from this spike is trustworthy, a NEGATIVE one is a hypothesis that needs
// re-testing inside the helper before anyone acts on it.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - State (nonisolated for the IOProc)

nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var aggID = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
nonisolated(unsafe) var tapDesc: CATapDescription?
nonisolated(unsafe) var tapUUID = UUID()

// Level accumulator, written by the IOProc and drained on the main thread.
nonisolated(unsafe) var sumSquares: Double = 0
nonisolated(unsafe) var sampleCount: Int = 0
nonisolated(unsafe) var peak: Float = 0
let levelLock = NSLock()

func check(_ status: OSStatus, _ message: String) {
    guard status != noErr else { return }
    FileHandle.standardError.write("FATAL \(message): OSStatus \(status)\n".data(using: .utf8)!)
    teardown()
    exit(1)
}

// MARK: - Level measurement

func resetLevel() {
    levelLock.lock()
    sumSquares = 0
    sampleCount = 0
    peak = 0
    levelLock.unlock()
}

/// Returns (rms dBFS, peak dBFS, frames seen). -inf is reported as -120.
func readLevel() -> (rms: Double, peak: Double, frames: Int) {
    levelLock.lock()
    let s = sumSquares, n = sampleCount, p = peak
    levelLock.unlock()
    guard n > 0 else { return (-120, -120, 0) }
    let rms = (s / Double(n)).squareRoot()
    let toDB = { (x: Double) in x > 1e-9 ? 20 * log10(x) : -120 }
    return (toDB(rms), toDB(Double(p)), n)
}

// MARK: - Tap + aggregate lifecycle

func selfProcessObject() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid = getpid()
    var obj = AudioObjectID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                               UInt32(MemoryLayout<pid_t>.size), &pid, &sz, &obj)
    return obj
}

func processObjectList() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

/// Mirrors iQualizeCapture: global tap excluding ourselves, muted, fed into a
/// private tap-only aggregate device with an IOProc.
func buildTap() {
    var excluded: [AudioObjectID] = []
    let selfObj = selfProcessObject()
    if selfObj != kAudioObjectUnknown { excluded.append(selfObj) }

    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
    tapUUID = UUID()
    desc.uuid = tapUUID
    desc.muteBehavior = .unmuted   // unmuted: we only measure, we don't re-render
    desc.name = "TapProcessRefresh"
    check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")
    tapDesc = desc

    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapProcessRefresh-Aggregate",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]
        ],
    ]
    check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "create aggregate")

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

    let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
        let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        var localSum = 0.0
        var localPeak: Float = 0
        var localCount = 0
        for i in 0..<bufList.count {
            guard let buf = bufList[i].mData else { continue }
            let n = Int(bufList[i].mDataByteSize) / MemoryLayout<Float>.size
            let src = buf.assumingMemoryBound(to: Float.self)
            for j in 0..<n {
                let v = src[j]
                localSum += Double(v) * Double(v)
                let a = abs(v)
                if a > localPeak { localPeak = a }
            }
            localCount += n
        }
        levelLock.lock()
        sumSquares += localSum
        sampleCount += localCount
        if localPeak > peak { peak = localPeak }
        levelLock.unlock()
    }
    check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil, ioBlock), "create IOProc")
    check(AudioDeviceStart(aggID, ioProcID), "start IOProc")
}

func teardown() {
    if let proc = ioProcID, aggID != kAudioObjectUnknown {
        AudioDeviceStop(aggID, proc)
        AudioDeviceDestroyIOProcID(aggID, proc)
        ioProcID = nil
    }
    if aggID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(aggID)
        aggID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    tapDesc = nil
}

// MARK: - The two refresh strategies under test

/// Phase C: re-set kAudioTapPropertyDescription on the live tap with an unchanged
/// process list. This is exactly what applyTapExclusions() does for #131, minus
/// the exclusion-list change.
func refreshTapDescription() -> OSStatus {
    guard let desc = tapDesc, tapID != kAudioObjectUnknown else { return -1 }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var ref: CATapDescription? = desc
    return withUnsafeMutablePointer(to: &ref) { ptr in
        AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                   UInt32(MemoryLayout<CATapDescription?>.stride), ptr)
    }
}

/// Phase D: re-set the aggregate's tap list, nudging the aggregate to re-resolve
/// the tap without destroying either object.
func refreshAggregateTapList() -> OSStatus {
    guard aggID != kAudioObjectUnknown else { return -1 }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyTapList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var list = [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUUID.uuidString,
    ]] as CFArray
    return withUnsafeMutablePointer(to: &list) { ptr in
        AudioObjectSetPropertyData(aggID, &addr, 0, nil,
                                   UInt32(MemoryLayout<CFArray?>.stride), ptr)
    }
}

// MARK: - Tone process

/// Starts a tone in a process that did not exist when the tap was created.
func startTone() -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sox")
    // -n null input, synth a 60 s 997 Hz sine at -12 dBFS out the default device
    p.arguments = ["-n", "-d", "synth", "60", "sine", "997", "gain", "-12"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        FileHandle.standardError.write("could not start sox: \(error)\n".data(using: .utf8)!)
        teardown()
        exit(1)
    }
    return p
}

// MARK: - Description-set probe (`swift run TapProcessRefresh descset`)
//
// Phase C came back '!hog' (kAudioDevicePermissionsError), so this walks the same
// call through every point in a tap's life to see whether it ever succeeds.
//
// Resolved: it fails at all four points HERE and succeeds in the capture helper.
// The variable is the process, not the tap state — see the header. Keep this mode
// around as the control for that difference, not as evidence about the API.

func setDescription(_ desc: CATapDescription) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var ref: CATapDescription? = desc
    return withUnsafeMutablePointer(to: &ref) { ptr in
        AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                   UInt32(MemoryLayout<CATapDescription?>.stride), ptr)
    }
}

func fourCC(_ s: OSStatus) -> String {
    guard s != 0 else { return "ok" }
    let b = withUnsafeBytes(of: s.bigEndian) { Array($0) }
    let ascii = b.allSatisfy { $0 >= 32 && $0 < 127 }
    return ascii ? "'\(String(bytes: b, encoding: .ascii) ?? "?")'  (\(s))" : "\(s)"
}

func runDescriptionSetProbe() {
    print("TapProcessRefresh — description-set probe (issue #140)\n")

    // Production parity: muted global tap, excluding self.
    var excluded: [AudioObjectID] = []
    let selfObj = selfProcessObject()
    if selfObj != kAudioObjectUnknown { excluded.append(selfObj) }
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
    tapUUID = UUID()
    desc.uuid = tapUUID
    desc.muteBehavior = .muted
    desc.name = "TapProcessRefresh-descset"
    check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")
    tapDesc = desc
    print("tap \(tapID) created (muted, global, excluding self)")

    // A victim to actually add to the exclusion list, so this is a real change
    // and not a no-op set. Any other audio process will do.
    let victim = processObjectList().first { $0 != selfObj && $0 != kAudioObjectUnknown }
    print("victim process object to exclude: \(victim.map(String.init) ?? "none found")\n")

    print("1  bare tap, no aggregate yet")
    desc.processes = excluded
    print("   no-op set            \(fourCC(setDescription(desc)))")
    if let victim {
        desc.processes = excluded + [victim]
        print("   real exclusion set   \(fourCC(setDescription(desc)))")
        desc.processes = excluded
        print("   revert set           \(fourCC(setDescription(desc)))")
    }

    // Now attach the aggregate + IOProc, exactly as the helper does.
    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapProcessRefresh-Aggregate",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
            [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]
        ],
    ]
    check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "create aggregate")
    Thread.sleep(forTimeInterval: 0.5)

    print("\n2  aggregate attached, IOProc NOT started")
    if let victim {
        desc.processes = excluded + [victim]
        print("   real exclusion set   \(fourCC(setDescription(desc)))")
    }

    let ioBlock: AudioDeviceIOBlock = { _, _, _, _, _ in }
    check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil, ioBlock), "create IOProc")
    check(AudioDeviceStart(aggID, ioProcID), "start IOProc")
    Thread.sleep(forTimeInterval: 0.5)

    print("\n3  IOProc running  <- what applyTapExclusions() does in production")
    if let victim {
        desc.processes = excluded + [victim]
        print("   real exclusion set   \(fourCC(setDescription(desc)))")
        desc.processes = excluded
        print("   revert set           \(fourCC(setDescription(desc)))")
    }

    AudioDeviceStop(aggID, ioProcID)
    Thread.sleep(forTimeInterval: 0.3)
    print("\n4  IOProc stopped again")
    if let victim {
        desc.processes = excluded + [victim]
        print("   real exclusion set   \(fourCC(setDescription(desc)))")
    }

    teardown()
    print("\n'!hog' is kAudioDevicePermissionsError.")
}

// MARK: - Process-list watch (`swift run TapProcessRefresh watch [seconds]`)
//
// Does the filter in pollProcessList() actually buy anything? It only helps if new
// process objects routinely appear WITHOUT playing audio. This mirrors production's
// 2 s poll and reports, for each newly-appeared object, whether it was already
// running output and whether it ever starts within the watch window.

func processName(_ obj: AudioObjectID) -> String {
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
    return bid.isEmpty ? "obj \(obj)" : bid
}

func isRunningOutput(_ obj: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &running) == noErr
    else { return false }
    return running != 0
}

func runWatch(seconds: Int) {
    print("watching the process list for \(seconds)s at production's 2 s cadence")
    print("launch some audio apps now\n")
    var known = Set(processObjectList())
    print("starting with \(known.count) process objects")
    var watching: [AudioObjectID: Int] = [:]      // object -> cycles observed
    var everPlayed = Set<AudioObjectID>()
    var appearedPlaying = 0, appearedSilent = 0

    let cycles = seconds / 2
    for _ in 0..<cycles {
        Thread.sleep(forTimeInterval: 2.0)
        let current = Set(processObjectList())
        for obj in current.subtracting(known) {
            let playing = isRunningOutput(obj)
            if playing { appearedPlaying += 1; everPlayed.insert(obj) }
            else { appearedSilent += 1 }
            watching[obj] = 0
            print(String(format: "  + %-42@ appeared %@",
                         processName(obj) as NSString,
                         playing ? "PLAYING" : "silent"))
        }
        // Follow the ones that appeared silent to see if they ever start.
        for (obj, seen) in watching {
            guard current.contains(obj) else { watching[obj] = nil; continue }
            if !everPlayed.contains(obj), isRunningOutput(obj) {
                everPlayed.insert(obj)
                print("    -> \(processName(obj)) started output after \((seen + 1) * 2)s")
            }
            if seen >= 5 { watching[obj] = nil } else { watching[obj] = seen + 1 }
        }
        known = current
    }

    print("\n--- summary ---")
    print("  new process objects:        \(appearedPlaying + appearedSilent)")
    print("  already playing on arrival: \(appearedPlaying)")
    print("  arrived silent:             \(appearedSilent)")
    print("  ever played during watch:   \(everPlayed.count)")
    let neverPlayed = (appearedPlaying + appearedSilent) - everPlayed.count
    print("  never played at all:        \(neverPlayed)   <- restarts the filter avoids")
}

let mode = CommandLine.arguments.dropFirst().first
if mode == "descset" {
    runDescriptionSetProbe()
    exit(0)
}
if mode == "watch" {
    let secs = CommandLine.arguments.dropFirst(2).first.flatMap { Int($0) } ?? 30
    runWatch(seconds: secs)
    exit(0)
}

// MARK: - Run

func measure(_ label: String, settle: TimeInterval = 2.0, window: TimeInterval = 3.0) -> Double {
    Thread.sleep(forTimeInterval: settle)   // let the change take effect
    resetLevel()
    Thread.sleep(forTimeInterval: window)
    let (rms, pk, frames) = readLevel()
    print(String(format: "  %-22@  rms %7.1f dBFS   peak %7.1f dBFS   frames %d",
                 label as NSString, rms, pk, frames))
    return rms
}

print("TapProcessRefresh — issue #140 phase 0 spike")
print("pid \(getpid())")

let before = Set(processObjectList())
buildTap()
print("tap \(tapID)  aggregate \(aggID)  processes visible at creation: \(before.count)\n")

print("A  baseline (nothing playing)")
let baseline = measure("baseline")

print("\nB  tone process started AFTER the tap exists")
let tone = startTone()
let after = Set(processObjectList())
print("   new process objects: \(after.subtracting(before).count)")
let late = measure("late process")

print("\nC  re-set kAudioTapPropertyDescription (list unchanged)")
let cErr = refreshTapDescription()
print("   set returned OSStatus \(cErr)")
let afterDesc = measure("after description")

print("\nD  re-set aggregate kAudioAggregateDevicePropertyTapList")
let dErr = refreshAggregateTapList()
print("   set returned OSStatus \(dErr)")
let afterList = measure("after tap list")

print("\nE  full rebuild (CONTROL — this is what production does today)")
teardown()
buildTap()
let afterRebuild = measure("after rebuild")

tone.terminate()
teardown()

// MARK: - Verdict

/// A phase "hears" the tone if it sits well above the silent baseline.
let threshold = max(baseline + 20, -80.0)
func verdict(_ v: Double) -> String { v > threshold ? "TONE" : "silent" }

print("\n--- summary (tone threshold \(String(format: "%.1f", threshold)) dBFS) ---")
print("  A baseline           \(verdict(baseline))")
print("  B late process       \(verdict(late))")
print("  C description reset  \(verdict(afterDesc))")
print("  D tap list reset     \(verdict(afterList))")
print("  E full rebuild       \(verdict(afterRebuild))  <- control")

if late > threshold {
    print("\nNO REPRO: the late process was already captured without any refresh.")
    print("The restart in pollProcessList() may not be needed at all for this app.")
} else if afterRebuild <= threshold {
    print("\nINVALID: the control never heard the tone, so C and D prove nothing.")
    print("Check that sox is audible on the default output device and rerun.")
} else if afterDesc > threshold {
    print("\nPOSITIVE (C): re-setting the tap description picks up the new process.")
    print("Phase 2 is buildable in the helper with no restart.")
} else if afterList > threshold {
    print("\nPOSITIVE (D): the aggregate tap list needs the nudge, the tap alone is not enough.")
    print("Phase 2 is buildable, but against the aggregate rather than the tap.")
} else {
    print("\nNEGATIVE: only a full rebuild picks up the new process.")
    print("Fall back to Phase 1 (filter) + Phase 3 (debounce); Phase 2 is not viable.")
}
