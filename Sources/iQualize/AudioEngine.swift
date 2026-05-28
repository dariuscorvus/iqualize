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
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

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

    /// Rebuild the engine after AVAudioEngine reports its configuration changed.
    /// Routes through stop() + start() so we re-bind to whatever the system's
    /// current default output is. Reuses `isRestarting` to coalesce with the
    /// default-device listener and prevent re-entrance.
    private func restartAfterConfigChange() {
        guard !isRestarting, isRunning else { return }
        isRestarting = true
        stop()
        do {
            try start()
        } catch {
            self.error = error.localizedDescription
        }
        isRestarting = false
        onStateChange?()
    }

    // MARK: - EQ Control

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try start()
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            stop()
        }
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
        guard !isRestarting else { return }

        if let deviceID = try? getDefaultOutputDeviceID(),
           let name = try? getDeviceName(deviceID) {
            outputDeviceName = name
        }

        if isRunning {
            isRestarting = true
            stop()
            do {
                try start()
            } catch {
                self.error = error.localizedDescription
            }
            isRestarting = false
        }

        onStateChange?()
    }
}
