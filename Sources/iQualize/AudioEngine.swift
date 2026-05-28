import CoreAudio
import AudioToolbox
import AVFoundation
import Foundation
import Observation
import os.log

private let appLog = OSLog(subsystem: "com.iqualize", category: "audio")

/// Locate the capture helper executable inside the app bundle.
/// Built as `iQualizeCapture` and installed at
/// `Contents/Helpers/iQualizeCapture` by install.sh.
func capture_helperURL() -> URL {
    return Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/iQualizeCapture")
}

private func transportTypeName(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBluetooth:   return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeBuiltIn:     return "BuiltIn"
    case kAudioDeviceTransportTypeUSB:         return "USB"
    case kAudioDeviceTransportTypeHDMI:        return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeAggregate:   return "Aggregate"
    case kAudioDeviceTransportTypeVirtual:     return "Virtual"
    case kAudioDeviceTransportTypeAVB:         return "AVB"
    case kAudioDeviceTransportTypeFireWire:    return "FireWire"
    case kAudioDeviceTransportTypePCI:         return "PCI"
    case kAudioDeviceTransportTypeUnknown:     return "Unknown"
    default:                                   return "0x" + String(t, radix: 16)
    }
}

private func readUInt32(_ deviceID: AudioDeviceID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
    return value
}

/// Set the I/O buffer frame size on a device's output scope. Lower values
/// reduce latency at the cost of higher CPU and risk of dropouts. Devices
/// silently clamp to their allowed range.
func setBufferFrameSize(forDevice deviceID: AudioDeviceID, frames: UInt32) {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = frames
    _ = AudioObjectSetPropertyData(
        deviceID, &addr, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &size
    )
}

/// Log a per-device latency breakdown so the user can see exactly where the
/// audible delay is coming from for their current output. Reads buffer size,
/// the device's reported latency (`kAudioDevicePropertyLatency`), stream
/// latency, and safety-offset frames. Sum tells you the round-trip latency
/// from "engine renders sample" to "speaker emits sample" — for Bluetooth
/// devices this is dominated by the device-reported latency.
func logDeviceLatencyBreakdown(deviceID: AudioDeviceID, label: String) {
    let name = (try? getDeviceName(deviceID)) ?? "?"
    let transport = readUInt32(deviceID, kAudioDevicePropertyTransportType,
                               scope: kAudioObjectPropertyScopeGlobal)

    // Nominal sample rate — used to convert frames into milliseconds.
    var srAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var sr: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(deviceID, &srAddr, 0, nil, &srSize, &sr)
    let rate = sr > 0 ? sr : 48000

    // Buffer frame size + the device's allowed range.
    let buf = readUInt32(deviceID, kAudioDevicePropertyBufferFrameSize)
    var rangeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSizeRange,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var range = AudioValueRange()
    var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(deviceID, &rangeAddr, 0, nil, &rangeSize, &range)

    // Device-reported latency + safety offset (additional fixed delay added
    // for the playback path on top of the buffer).
    let devLatency = readUInt32(deviceID, kAudioDevicePropertyLatency)
    let safetyOffset = readUInt32(deviceID, kAudioDevicePropertySafetyOffset)

    // Stream-level latency on output streams. Most devices have a single
    // output stream; we sum across whatever exists.
    var streamsAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamsSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize)
    let streamCount = Int(streamsSize) / MemoryLayout<AudioObjectID>.size
    var streams = [AudioObjectID](repeating: 0, count: streamCount)
    AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &streamsSize, &streams)
    var streamLatency: UInt32 = 0
    for s in streams {
        streamLatency &+= readUInt32(s, kAudioStreamPropertyLatency,
                                     scope: kAudioObjectPropertyScopeGlobal)
    }

    let totalFrames = buf &+ devLatency &+ safetyOffset &+ streamLatency
    func ms(_ frames: UInt32) -> Double { Double(frames) / rate * 1000.0 }
    let summary = String(
        format: "%@: name=%@ transport=%@ sr=%.0f  buffer=%u (%.2fms; range %.0f..%.0f)  device-latency=%u (%.2fms)  stream-latency=%u (%.2fms)  safety-offset=%u (%.2fms)  TOTAL=%.2fms",
        label, name, transportTypeName(transport), rate,
        buf, ms(buf), range.mMinimum, range.mMaximum,
        devLatency, ms(devLatency),
        streamLatency, ms(streamLatency),
        safetyOffset, ms(safetyOffset),
        ms(totalFrames)
    )
    os_log(.default, log: appLog, "%{public}@", summary)
}

// MARK: - Real-time Audio Callbacks (free functions, no actor isolation)
// These run on Core Audio's IO thread. They MUST be free functions — not closures
// defined inside a @MainActor class — because Swift 6 strict concurrency inserts
// runtime isolation checks that crash on non-main threads.

nonisolated(unsafe) private var rtCaptureClient: CaptureClient?
nonisolated(unsafe) private var rtChannelCount: UInt32 = 2

/// Scratch buffer for deinterleaving (allocated once, reused).
nonisolated(unsafe) private var rtScratchBuffer: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtScratchCapacity: Int = 0
nonisolated(unsafe) private var rtBalanceLeft: Float = 1.0
nonisolated(unsafe) private var rtBalanceRight: Float = 1.0
nonisolated(unsafe) private var rtInputGain: Float = 1.0
/// Per-channel biquad filter chains for split channel mode.
/// Only active when rtSplitChannelActive is true.
/// Channels 2+ (e.g. 5.1/7.1 surround) pass through unprocessed — per-channel
/// EQ for >2 channels is a separate feature.
nonisolated(unsafe) private var rtBiquadChainL: BiquadFilterChain?
nonisolated(unsafe) private var rtBiquadChainR: BiquadFilterChain?
nonisolated(unsafe) private var rtSplitChannelActive: Bool = false

/// AVAudioSourceNode render block: pulls interleaved audio from ring buffer,
/// deinterleaves into separate channel buffers for the non-interleaved AVAudioEngine format.
private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    guard let client = rtCaptureClient else { return noErr }
    let ch = Int(rtChannelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames * ch
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    if rtScratchCapacity < interleavedCount {
        rtScratchBuffer?.deallocate()
        rtScratchBuffer = .allocate(capacity: interleavedCount)
        rtScratchCapacity = interleavedCount
    }
    guard let scratch = rtScratchBuffer else { return noErr }

    let read = client.read(scratch, count: interleavedCount)
    if read < interleavedCount {
        scratch.advanced(by: read).initialize(repeating: 0.0, count: interleavedCount - read)
    }

    for i in 0..<bufferList.count {
        guard let outData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channelIndex = i
        let gain = channelIndex == 0 ? rtBalanceLeft : rtBalanceRight
        for f in 0..<frames {
            outData[f] = scratch[f * ch + channelIndex] * rtInputGain * gain
        }
    }

    // Apply per-channel biquad EQ when split channel mode is active.
    // This runs INSTEAD of AVAudioUnitEQ (which is bypassed in split mode).
    if rtSplitChannelActive {
        if bufferList.count > 0, let outL = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
            rtBiquadChainL?.process(outL, frameCount: frames)
        }
        if bufferList.count > 1, let outR = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
            rtBiquadChainR?.process(outR, frameCount: frames)
        }
    }

    return noErr
}

// MARK: - AudioEngine

@available(macOS 14.2, *)
@Observable
@MainActor
final class AudioEngine {
    private(set) var isRunning = false
    private(set) var outputDeviceName = "Unknown"
    private(set) var error: String?

    /// The user wants EQ enabled. Distinct from `isRunning` (which reflects
    /// whether the engine is currently rendering) — when AirPods leave to
    /// iPhone, we stop the engine but `userEnabled` stays true so we resume
    /// automatically when AirPods return.
    private var userEnabled = false

    /// UID of the output device the user was on when EQ was enabled. Set in
    /// the first start(), cleared in setEnabled(false). On route change, we
    /// only follow the new default if it matches this UID — otherwise we
    /// idle the engine, freeing the fallback device so the user's preferred
    /// output (typically AirPods) can return via Continuity.
    private var preferredOutputUID: String?

    // Capture lives in a separate helper process (see CaptureClient.swift +
    // Sources/iQualizeCapture/main.swift). This main process owns no CATap,
    // no aggregate, no IOProc — only the AVAudioEngine output. That separation
    // is what lets Continuity preempt our render the way it preempts Spotify.
    private var captureClient: CaptureClient?
    private var engine: AVAudioEngine?
    private var eq: AVAudioUnitEQ?
    private var outputGainEQ: AVAudioUnitEQ?
    private var limiter: AVAudioUnitEffect?


    @ObservationIgnored
    nonisolated(unsafe) private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var configChangeObserver: NSObjectProtocol?
    @ObservationIgnored
    private var silenceTimer: Timer?
    @ObservationIgnored
    private var engineSilenced = false
    @ObservationIgnored
    private var lastNonSilentDate = Date()
    var onStateChange: (() -> Void)?

    // Spectrum analyzers — one per tap point
    let preEqAnalyzer = SpectrumAnalyzer()
    let postEqAnalyzer = SpectrumAnalyzer()
    private var sourceNode: AVAudioSourceNode?

    var activePreset: EQPresetData = .flat {
        didSet {
            applyBands(from: oldValue)
        }
    }

    var peakLimiter: Bool = true {
        didSet { applyBands() }
    }

    var bypassed: Bool = false {
        didSet { applyBands() }
    }

    var balance: Float = 0.0 {
        didSet {
            rtBalanceLeft = balance <= 0 ? 1.0 : 1.0 - balance
            rtBalanceRight = balance >= 0 ? 1.0 : 1.0 + balance
        }
    }

    var splitChannelActive: Bool = false {
        didSet {
            rtSplitChannelActive = splitChannelActive
            applyBands()
        }
    }

    var inputGainDB: Float = 0.0 {
        didSet {
            rtInputGain = powf(10, inputGainDB / 20)
        }
    }

    var outputGainDB: Float = 0.0 {
        didSet { outputGainEQ?.globalGain = outputGainDB }
    }

    var maxGainDB: Float = 12
    private(set) var outputSampleRate: Double = 48000

    init() {
        do {
            let deviceID = try getDefaultOutputDeviceID()
            outputDeviceName = try getDeviceName(deviceID)
        } catch {
            outputDeviceName = "Unknown"
        }
        installDeviceChangeListener()
    }

    deinit {
        if let block = deviceChangeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address,
                DispatchQueue.main, block
            )
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }
        error = nil

        let outputDeviceID = try getDefaultOutputDeviceID()
        outputDeviceName = try getDeviceName(outputDeviceID)

        // First time around (user just toggled EQ on), remember this device
        // as the user's preferred output. On subsequent restarts from a
        // route-change handler we keep the original preferred so we can
        // tell "AirPods came back" from "user just enabled EQ on Teufel".
        if preferredOutputUID == nil {
            preferredOutputUID = try? getDeviceUID(outputDeviceID)
        }

        // 1. Launch the capture helper — it owns the CATap, aggregate, and
        //    IOProc in a separate process. We just consume its shared-memory
        //    ring buffer. This is the architectural fix for AirPods handoff:
        //    by not having a CATap in this process, Continuity's preemption
        //    can release our render IOProc on the AirPods (see CONTINUITY.md).
        let client = CaptureClient()
        client.onUnexpectedTermination = { [weak self] in
            guard let self else { return }
            self.error = "Capture helper terminated unexpectedly."
            self.stop()
            self.onStateChange?()
        }
        try client.start(helperURL: capture_helperURL())
        self.captureClient = client

        let sampleRate = client.sampleRate
        let channels = client.channels
        self.outputSampleRate = sampleRate
        rtCaptureClient = client
        rtChannelCount = channels

        os_log(.default, log: appLog,
               "capture helper sr: %{public}.0f  ch: %{public}u  output: %{public}@",
               sampleRate, channels, outputDeviceName as NSString)

        // Reduce the output device's I/O buffer size so the AVAudioEngine
        // output AU runs at low latency. Default macOS buffer is 512 frames
        // (~10.7ms at 48kHz); 256 cuts that roughly in half. Smaller would
        // be even better but risks dropouts under load. This only affects
        // devices that allow setting BufferFrameSize and we ignore failures
        // — some devices clamp to their own minimum.
        setBufferFrameSize(forDevice: outputDeviceID, frames: 256)
        logDeviceLatencyBreakdown(deviceID: outputDeviceID, label: "output device")

        let avEngine = AVAudioEngine()

        // Use AVAudioEngine's default-output behavior — do NOT bind the output AU
        // to a specific device via kAudioOutputUnitProperty_CurrentDevice. Explicit
        // binding appears to make the shared-mode stream non-preemptible by the
        // Continuity arbiter (Mac→iPhone handoff). Letting the engine use the
        // system default output (which is the AirPods at engine start) keeps the
        // stream in the regular default-device path that Continuity treats like
        // normal media playback. We still restart on default-device changes via
        // the existing kAudioHardwarePropertyDefaultOutputDevice listener.

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels))!

        let sourceNode = AVAudioSourceNode(format: format, renderBlock: renderCallback)
        self.sourceNode = sourceNode

        let eqNode = AVAudioUnitEQ(numberOfBands: EQPresetData.maxBandCount)
        for (i, eqBand) in eqNode.bands.enumerated() {
            if i < activePreset.bands.count {
                let band = activePreset.bands[i]
                eqBand.filterType = band.filterType.avType
                eqBand.frequency = band.frequency
                eqBand.bandwidth = band.bandwidth
                eqBand.gain = band.gain
                eqBand.bypass = false
            } else {
                eqBand.bypass = true
            }
        }
        eqNode.globalGain = 0
        if splitChannelActive && !bypassed {
            // Split channel mode: bypass AVAudioUnitEQ, set up biquad chains
            eqNode.bypass = true
            rtBiquadChainL = BiquadFilterChain(bands: activePreset.bands, sampleRate: sampleRate)
            rtBiquadChainR = BiquadFilterChain(bands: activePreset.rightBands ?? activePreset.bands, sampleRate: sampleRate)
            rtSplitChannelActive = true
        } else {
            eqNode.bypass = bypassed || activePreset.isFlat
        }
        self.eq = eqNode

        // Peak limiter: dynamic limiting at 0 dBFS (replaces static preamp hack)
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiterNode = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        let au = limiterNode.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0.0, 0)
        limiterNode.bypass = !peakLimiter || bypassed
        self.limiter = limiterNode

        let outputGainNode = AVAudioUnitEQ(numberOfBands: 0)
        outputGainNode.globalGain = outputGainDB
        self.outputGainEQ = outputGainNode

        avEngine.attach(sourceNode)
        avEngine.attach(eqNode)
        avEngine.attach(outputGainNode)
        avEngine.attach(limiterNode)
        avEngine.connect(sourceNode, to: eqNode, format: format)
        avEngine.connect(eqNode, to: outputGainNode, format: format)
        avEngine.connect(outputGainNode, to: limiterNode, format: format)
        avEngine.connect(limiterNode, to: avEngine.outputNode, format: format)

        try avEngine.start()
        self.engine = avEngine

        // Subscribe to engine configuration changes. AVAudioEngine fires this
        // when the underlying output device's I/O setup changes — including
        // when Continuity migrates AirPods to another device (iPhone seizure)
        // and when the AirPods return. The engine is paused at the moment the
        // notification fires; we rebuild against the new default output and
        // restart. Do NOT try to force the route back — that fights the
        // arbiter and reproduces the original bug.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                os_log(.default, log: appLog,
                       "AVAudioEngineConfigurationChange — restarting engine")
                self.restartAfterConfigChange()
            }
        }

        // 5b. Install spectrum analyzer taps (non-destructive, analysis only)
        // Closures must be @Sendable — they run on the audio render thread, not main.
        // Capture only Sendable values (SpectrumAnalyzer is @unchecked Sendable).
        let capturedSampleRate = sampleRate
        let preAnalyzer: SpectrumAnalyzer = self.preEqAnalyzer
        sourceNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            preAnalyzer.process(buffer, sampleRate: capturedSampleRate)
        }
        let postAnalyzer: SpectrumAnalyzer = self.postEqAnalyzer
        eqNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            postAnalyzer.process(buffer, sampleRate: capturedSampleRate)
        }

        isRunning = true

        // Silence-yield monitor: when the helper's ring buffer has no audio
        // activity for >2s, stop the engine so it releases the default output
        // device. With no app rendering, macOS keeps the user's preferred
        // device as default even when it's unavailable (AirPods on iPhone),
        // which is what makes auto-return work. When non-silent audio appears,
        // we restart the engine — it rebinds to whatever the current default
        // is (typically the returned AirPods).
        startSilenceMonitor()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        stopSilenceMonitor()

        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }

        rtCaptureClient = nil
        rtBiquadChainL = nil
        rtBiquadChainR = nil

        // Remove spectrum taps before stopping engine
        sourceNode?.removeTap(onBus: 0)
        eq?.removeTap(onBus: 0)
        sourceNode = nil

        engine?.stop()
        engine = nil
        eq = nil
        limiter = nil

        // Terminate the capture helper. It will clean up its CATap, aggregate,
        // IOProc, and shared memory.
        captureClient?.stop()
        captureClient = nil
    }

    /// Called from both AVAudioEngineConfigurationChange and the default-output
    /// listener. Decides whether to follow the route change.
    ///
    /// Key insight: if AirPods migrate to iPhone, macOS picks a fallback
    /// default (e.g., Teufel speakers). If iQualize FOLLOWS the fallback and
    /// keeps rendering there, the fallback stays busy and AirPods can't return
    /// to the Mac via Continuity. If iQualize IDLES on non-preferred fallbacks,
    /// the fallback is free and AirPods auto-return when iPhone is silent.
    private func reactToRouteChange() {
        guard !isRestarting else { return }
        guard userEnabled else { return }

        let currentUID: String?
        if let deviceID = try? getDefaultOutputDeviceID() {
            outputDeviceName = (try? getDeviceName(deviceID)) ?? outputDeviceName
            currentUID = try? getDeviceUID(deviceID)
        } else {
            currentUID = nil
        }

        let matchesPreferred = (preferredOutputUID == nil)
            || (currentUID == preferredOutputUID)

        isRestarting = true
        defer {
            isRestarting = false
            onStateChange?()
        }

        if matchesPreferred {
            // Either we have no preferred yet (first time), or current default
            // is the user's preferred device. Bring engine up on it.
            if isRunning {
                stop()
            }
            do {
                try start()
            } catch {
                os_log(.error, log: appLog,
                       "reactToRouteChange: start() failed: %{public}@",
                       error.localizedDescription)
                self.error = error.localizedDescription
                cleanupPartialStart()
            }
        } else {
            // Default switched to a fallback device. Idle the engine so we
            // don't keep the fallback busy — that's what blocks AirPods from
            // returning. preferredOutputUID is preserved so we can detect
            // the user's device coming back via this same listener.
            if isRunning {
                stop()
                os_log(.default, log: appLog,
                       "idled engine: default switched to non-preferred (%{public}@); waiting for preferred to return",
                       currentUID ?? "?")
                if let id = try? getDefaultOutputDeviceID() {
                    logDeviceLatencyBreakdown(deviceID: id,
                                              label: "fallback device (engine idle)")
                }
            }
        }
    }

    private func restartAfterConfigChange() { reactToRouteChange() }

    // MARK: - EQ Control

    func setEnabled(_ enabled: Bool) {
        if enabled {
            userEnabled = true
            do {
                try start()
            } catch {
                os_log(.error, log: appLog,
                       "start() failed: %{public}@",
                       error.localizedDescription)
                self.error = error.localizedDescription
                cleanupPartialStart()
            }
        } else {
            userEnabled = false
            preferredOutputUID = nil
            stop()
        }
    }

    // MARK: - Silence-yield

    // ~-40 dBFS. Empirically the helper's ring buffer floats around 0.01 even
    // with no app actively playing (system sounds, background processes, etc).
    // 0.03 filters that out while still triggering on quiet music.
    private static let silenceThreshold: Float = 0.03
    private static let silenceGracePeriod: TimeInterval = 2.0

    private func startSilenceMonitor() {
        stopSilenceMonitor()  // belt-and-suspenders
        engineSilenced = false
        lastNonSilentDate = Date()
        // 10ms cadence: the cheapest way to drive resume latency down. The
        // peek+compare is microseconds of work, so the CPU cost of polling
        // 100 Hz is negligible. Doesn't help the AirPods BT codec floor
        // (~150ms inherent), but does help wired/built-in playback feel near
        // instant on resume.
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSilence()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceMonitor() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        engineSilenced = false
    }

    private func checkSilence() {
        guard let engine, let client = captureClient else { return }
        let peak = client.peekRecentPeak(window: 4096)
        let now = Date()

        if peak >= AudioEngine.silenceThreshold {
            lastNonSilentDate = now
            if engineSilenced {
                // Audio returned — discard the stale buffered samples that
                // accumulated while we were paused, then resume. Without
                // resync we'd play back up to ~170ms of old audio before
                // catching up to the fresh data.
                client.resyncReadHead(targetLagSamples: 256)
                do {
                    try engine.start()
                    engineSilenced = false
                    os_log(.default, log: appLog, "engine resumed (audio activity)")
                } catch {
                    os_log(.error, log: appLog,
                           "engine resume failed: %{public}@",
                           error.localizedDescription)
                }
            }
        } else if !engineSilenced
                  && now.timeIntervalSince(lastNonSilentDate) >= AudioEngine.silenceGracePeriod {
            // Silent for the grace period — pause the engine. pause() keeps
            // the engine graph "warm" so resume is much faster than after a
            // full stop(). Empirically still releases the output device, so
            // AirPods can still migrate to iPhone during paused state.
            engine.pause()
            engineSilenced = true
            os_log(.default, log: appLog, "engine paused (sustained silence)")
        }
    }

    /// Tear down anything that may have been partially initialised by a
    /// failed start(). Mirrors stop()'s cleanup but doesn't gate on
    /// isRunning (start() throws before isRunning is set).
    private func cleanupPartialStart() {
        stopSilenceMonitor()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        rtCaptureClient = nil
        rtBiquadChainL = nil
        rtBiquadChainR = nil
        sourceNode?.removeTap(onBus: 0)
        eq?.removeTap(onBus: 0)
        sourceNode = nil
        engine?.stop()
        engine = nil
        eq = nil
        limiter = nil
        captureClient?.stop()
        captureClient = nil
    }

    private func applyBands(from old: EQPresetData? = nil) {
        guard let eq else { return }

        if splitChannelActive && !bypassed {
            // Split channel mode: bypass AVAudioUnitEQ, use custom biquad chains
            eq.bypass = true
            let sr = outputSampleRate

            let leftBands = activePreset.bands
            let rightBands = activePreset.rightBands ?? activePreset.bands

            if let chainL = rtBiquadChainL {
                chainL.updateCoefficients(bands: leftBands, sampleRate: sr)
            } else {
                rtBiquadChainL = BiquadFilterChain(bands: leftBands, sampleRate: sr)
            }

            if let chainR = rtBiquadChainR {
                chainR.updateCoefficients(bands: rightBands, sampleRate: sr)
            } else {
                rtBiquadChainR = BiquadFilterChain(bands: rightBands, sampleRate: sr)
            }
        } else {
            // Linked mode: use AVAudioUnitEQ, disable biquad chains
            rtBiquadChainL = nil
            rtBiquadChainR = nil

            let newCount = activePreset.bands.count
            let oldCount = old?.bands.count ?? 0

            for (i, band) in activePreset.bands.enumerated() {
                let eqBand = eq.bands[i]
                if i >= oldCount {
                    // New band — configure fully
                    eqBand.filterType = band.filterType.avType
                    eqBand.frequency = band.frequency
                    eqBand.bandwidth = band.bandwidth
                    eqBand.gain = band.gain
                    eqBand.bypass = false
                } else if let oldBand = old?.bands[i] {
                    // Existing band — only update changed params
                    if band.filterType != oldBand.filterType { eqBand.filterType = band.filterType.avType }
                    if band.frequency != oldBand.frequency { eqBand.frequency = band.frequency }
                    if band.gain != oldBand.gain { eqBand.gain = band.gain }
                    if band.bandwidth != oldBand.bandwidth { eqBand.bandwidth = band.bandwidth }
                } else {
                    // No old data — write everything
                    eqBand.filterType = band.filterType.avType
                    eqBand.frequency = band.frequency
                    eqBand.gain = band.gain
                    eqBand.bandwidth = band.bandwidth
                }
            }

            // Bypass bands that are no longer active
            if newCount < oldCount {
                for i in newCount..<oldCount {
                    eq.bands[i].bypass = true
                }
            }

            eq.globalGain = 0
            eq.bypass = bypassed || activePreset.isFlat
        }

        limiter?.bypass = !peakLimiter || bypassed
    }

    // MARK: - Device Change Handling

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleDeviceChange()
                }
            }
        }
        deviceChangeListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, block
        )
    }

    private var isRestarting = false

    private func handleDeviceChange() {
        reactToRouteChange()
    }
}
