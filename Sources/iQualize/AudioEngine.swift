import CoreAudio
import AudioToolbox
import AVFAudio
import Foundation
import Observation
import os.log

private let appLog = OSLog(subsystem: "com.iqualize", category: "audio")

/// Locate the capture helper executable inside the app bundle. Built as
/// `iQualizeCapture` and installed at `Contents/Helpers/iQualizeCapture` by
/// install.sh. See docs/CONTINUITY.md for why capture lives in a separate process.
func captureHelperURL() -> URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iQualizeCapture")
}

func defaultOutputDeviceChanged(previousUID: String?, currentUID: String?) -> Bool {
    guard let currentUID else { return false }
    return currentUID != previousUID
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
/// Multiplies back the stereo-pair headroom attenuation of the mixdown tap
/// (see GainPolicy.tapHeadroomCompensation). Applied unconditionally — the tap
/// attenuates in Bypass too, so Bypass must compensate to sound like app-off.
nonisolated(unsafe) private var rtVolumeCompensation: Float = 1.0
/// Per-channel biquad filter chains, run in this callback ahead of AVAudioUnitEQ.
/// Only active when rtBiquadChainActive is true. Two roles, depending on mode:
/// in split channel mode they carry the full band lists (AVAudioUnitEQ is bypassed
/// entirely); in linked mode they carry only the bands beyond AVAudioUnitEQ's fixed
/// native capacity (see AudioEngine.avEQNativeBandCount), so there's no hard cap on
/// band count in either mode.
/// Channels 2+ (e.g. 5.1/7.1 surround) pass through unprocessed — per-channel
/// EQ for >2 channels is a separate feature.
nonisolated(unsafe) private var rtBiquadChainL: BiquadFilterChain?
nonisolated(unsafe) private var rtBiquadChainR: BiquadFilterChain?
nonisolated(unsafe) private var rtBiquadChainActive: Bool = false

/// AVAudioSourceNode render block: pulls interleaved audio from the capture
/// client's shared ring buffer, deinterleaves into separate channel buffers
/// for the non-interleaved AVAudioEngine format.
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

    // Preallocated in start() for the AU's maximumFramesPerSlice default;
    // growing here on the audio thread is a never-expected fallback.
    if rtScratchCapacity < interleavedCount {
        rtScratchBuffer?.deallocate()
        rtScratchBuffer = .allocate(capacity: interleavedCount)
        rtScratchCapacity = interleavedCount
    }
    guard let scratch = rtScratchBuffer else { return noErr }

    // All-or-nothing: a full drift-compensated block (#133), or silence
    // while the ring seeds / after an underrun.
    if client.readResampled(scratch, frames: frames) == 0 {
        scratch.initialize(repeating: 0.0, count: interleavedCount)
    }

    for i in 0..<bufferList.count {
        guard let outData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let balance = i == 0 ? rtBalanceLeft : rtBalanceRight
        deinterleaveChannel(scratch, into: outData, channel: i, channelCount: ch,
                            frames: frames, gain: rtInputGain * balance * rtVolumeCompensation)
    }

    // Apply per-channel biquad EQ when a chain is configured — either the whole
    // preset in split channel mode (AVAudioUnitEQ bypassed), or the overflow
    // bands beyond AVAudioUnitEQ's native capacity in linked mode (runs ahead
    // of it in the graph, feeding it already-partially-EQ'd audio).
    if rtBiquadChainActive {
        if bufferList.count > 0, let outL = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
            rtBiquadChainL?.process(outL, frameCount: frames)
        }
        if bufferList.count > 1, let outR = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
            rtBiquadChainR?.process(outR, frameCount: frames)
        }
    }

    return noErr
}

/// Copy one channel out of an interleaved buffer, applying the channel's total
/// linear gain. The render callback's only per-sample math; exercised directly
/// by the unit tests with synthetic buffers.
func deinterleaveChannel(
    _ input: UnsafePointer<Float>,
    into output: UnsafeMutablePointer<Float>,
    channel: Int,
    channelCount: Int,
    frames: Int,
    gain: Float
) {
    for f in 0..<frames {
        output[f] = input[f * channelCount + channel] * gain
    }
}

// MARK: - AudioEngine

@available(macOS 14.2, *)
@Observable
@MainActor
final class AudioEngine {
    /// AVAudioUnitEQ's own native band capacity — an AudioEngine implementation
    /// detail, not a user-facing limit. See the comment at its allocation in start(),
    /// and docs/EQ_BAND_CAPACITY.md for why this can't just be raised.
    private static let avEQNativeBandCount = 31

    private(set) var isRunning = false
    private(set) var lifecycleState: AudioLifecycleState = .inactive
    private(set) var userEnabled = false
    private(set) var lifecycleHistory: [AudioLifecycleTransition] = []
    private(set) var outputDeviceName = "Unknown"
    private(set) var outputDeviceUID: String?
    private(set) var error: String?
    /// Unexpected helper terminations since the app launched. This is kept
    /// outside CaptureClient because a recovery creates a fresh client.
    private(set) var captureHelperRestartCount: UInt64 = 0

    // Capture lives in a separate helper process (see CaptureClient.swift +
    // Sources/iQualizeCapture/main.swift). This main process owns no CATap,
    // no aggregate, no IOProc — only the AVAudioEngine output. That separation
    // is what lets Continuity preempt our render the way it preempts Spotify.
    // See docs/CONTINUITY.md.
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
    private var lifecycleCoordinator: AudioLifecycleCoordinator?
    var onStateChange: (() -> Void)?
    /// Resolves a pinned preset for a device UID, if any. Wired by the caller that owns
    /// both AudioEngine and PresetStore — kept as a closure so AudioEngine stays decoupled
    /// from the store type, same pattern as `onStateChange`.
    var pinnedPresetProvider: ((String) -> EQPresetData?)?

    // Spectrum analyzers — one per tap point
    let preEqAnalyzer = SpectrumAnalyzer()
    let postEqAnalyzer = SpectrumAnalyzer()
    private var sourceNode: AVAudioSourceNode?
    private var sourceTapInstalled = false
    private var eqTapInstalled = false

    var activePreset: EQPresetData = .flat {
        didSet {
            applyBands(from: oldValue)
            if !gainIsGlobal {
                inputGainDB = activePreset.inputGainDB ?? 0
                outputGainDB = activePreset.outputGainDB ?? 0
            }
        }
    }

    /// When true, `inputGainDB`/`outputGainDB` are shared across all presets and untouched
    /// by preset switches. When false, they're resolved from `activePreset` on every switch.
    var gainIsGlobal: Bool = false

    var peakLimiter: Bool = true {
        didSet { applyBands() }
    }

    var bypassed: Bool = false {
        didSet {
            applyBands()
            updateInputGain()
            updateBalance()
            updateOutputGain()
        }
    }

    var balance: Float = 0.0 {
        didSet { updateBalance() }
    }

    var splitChannelActive: Bool = false {
        didSet { applyBands() }
    }

    var inputGainDB: Float = 0.0 {
        didSet { updateInputGain() }
    }

    var outputGainDB: Float = 0.0 {
        didSet { updateOutputGain() }
    }

    /// Bypass is a true passthrough: In, Out, and Balance are neutralized while
    /// bypassed and restored on un-bypass, without touching the stored/displayed
    /// control values (see #118). The math lives in GainPolicy.
    private func updateInputGain() {
        rtInputGain = GainPolicy.inputGain(dB: inputGainDB, bypassed: bypassed)
    }

    private func updateBalance() {
        (rtBalanceLeft, rtBalanceRight) = GainPolicy.balanceGains(balance, bypassed: bypassed)
    }

    private func updateOutputGain() {
        outputGainEQ?.globalGain = GainPolicy.outputGainDB(outputGainDB, bypassed: bypassed)
    }

    var maxGainDB: Float = 12
    private(set) var outputSampleRate: Double = 48000

    /// Capture-ring drift telemetry (#133) for the CLI status surface.
    /// nil while the engine is stopped. Counters reset on every capture
    /// (re)start — each start() builds a fresh CaptureClient.
    func captureTelemetry() -> CaptureClient.Telemetry? {
        captureClient?.telemetrySnapshot()
    }

    init() {
        do {
            let deviceID = try getDefaultOutputDeviceID()
            outputDeviceName = try getDeviceName(deviceID)
            outputDeviceUID = try? getDeviceUID(deviceID)
        } catch {
            outputDeviceName = "Unknown"
        }
        installDeviceChangeListener()

        lifecycleCoordinator = AudioLifecycleCoordinator(
            startOperation: { @MainActor [weak self] in
                guard let self else {
                    throw NSError(domain: "iQualize", code: -200,
                                  userInfo: [NSLocalizedDescriptionKey: "Audio engine is unavailable"])
                }
                try self.startGraph()
            },
            stopOperation: { @MainActor [weak self] in
                self?.teardown()
            },
            readiness: { @MainActor in
                isDefaultOutputDeviceReady()
            },
            publishSnapshot: { @MainActor [weak self] snapshot in
                self?.applyLifecycleSnapshot(snapshot)
            },
            publishError: { @MainActor [weak self] message in
                if let message {
                    os_log(.error, log: appLog, "audio lifecycle failure: %{public}@", message)
                }
                self?.error = message
            }
        )
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

    private func startGraph() throws {
        error = nil

        let outputDeviceID = try getDefaultOutputDeviceID()
        outputDeviceName = try getDeviceName(outputDeviceID)
        outputDeviceUID = try? getDeviceUID(outputDeviceID)

        // 1. Launch the capture helper — it owns the CATap, tap-only aggregate,
        //    and IOProc in a separate process. We just consume its shared-memory
        //    ring buffer. This is the architectural fix for AirPods Continuity
        //    handoff: by not having a CATap in this process, Continuity's
        //    preemption can release our render from the AirPods (see docs/CONTINUITY.md).
        let client = CaptureClient()
        client.onUnexpectedTermination = { [weak self] in
            guard let self else { return }
            self.captureHelperRestartCount &+= 1
            Task { @MainActor in
                guard let lifecycleCoordinator = self.lifecycleCoordinator else { return }
                await lifecycleCoordinator.helperTerminated()
                self.applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
            }
        }
        try client.start(helperURL: captureHelperURL())
        self.captureClient = client

        let sampleRate = client.sampleRate
        let channels = client.channels
        self.outputSampleRate = sampleRate
        rtCaptureClient = client
        rtChannelCount = channels

        // Preallocate the render scratch for the AU maximumFramesPerSlice
        // default (4096) so the render callback never allocates in practice.
        let scratchFloats = 4096 * Int(channels)
        if rtScratchCapacity < scratchFloats {
            rtScratchBuffer?.deallocate()
            rtScratchBuffer = .allocate(capacity: scratchFloats)
            rtScratchCapacity = scratchFloats
        }

        os_log(.default, log: appLog,
               "capture helper sr: %{public}.0f  ch: %{public}u  output: %{public}@",
               sampleRate, channels, outputDeviceName as NSString)

        let avEngine = AVAudioEngine()

        // Use AVAudioEngine's default-output behavior — do NOT bind the output AU
        // to a specific device via kAudioOutputUnitProperty_CurrentDevice. Explicit
        // binding is part of what made the pre-split single-process render
        // non-preemptible by the Continuity arbiter. Letting the engine follow the
        // system default output keeps us in the same route-following path normal
        // media apps use. We still rebuild on default-device changes via the
        // existing kAudioHardwarePropertyDefaultOutputDevice listener below.

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels))!

        let sourceNode = AVAudioSourceNode(format: format, renderBlock: renderCallback)
        self.sourceNode = sourceNode

        // AVAudioUnitEQ (Apple's AUNBandEQ) natively processes up to
        // Self.avEQNativeBandCount bands — it's allocated at a fixed size and,
        // per Apple's own kAUNBandEQProperty_MaxNumberOfBands, can't grow past
        // its own hardware/OS-defined ceiling regardless of what's requested
        // here. Any bands beyond that run through rtBiquadChainL/R instead
        // (see applyBands and the render callback above), so there's no
        // app-imposed cap on band count — only CPU.
        let eqNode = AVAudioUnitEQ(numberOfBands: Self.avEQNativeBandCount)
        self.eq = eqNode
        applyBands()

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
        self.outputGainEQ = outputGainNode
        updateOutputGain()

        avEngine.attach(sourceNode)
        avEngine.attach(eqNode)
        avEngine.attach(outputGainNode)
        avEngine.attach(limiterNode)
        avEngine.connect(sourceNode, to: eqNode, format: format)
        avEngine.connect(eqNode, to: outputGainNode, format: format)
        avEngine.connect(outputGainNode, to: limiterNode, format: format)
        avEngine.connect(limiterNode, to: avEngine.outputNode, format: format)

        // The capture helper's stereo mixdown tap is attenuated by Core Audio
        // on multi-channel output devices (#107) — multiply the loss back in
        // at the source node, ahead of the EQ and limiter so the limiter still
        // guards the restored level. Recomputed on every start(); device
        // switches funnel through the lifecycle coordinator's stop + start path.
        let outputChannels = Int(avEngine.outputNode.outputFormat(forBus: 0).channelCount)
        rtVolumeCompensation = GainPolicy.tapHeadroomCompensation(outputChannels: outputChannels)
        os_log(.default, log: appLog,
               "output hw channels: %{public}d  tap headroom compensation: x%{public}.1f",
               outputChannels, rtVolumeCompensation)

        // Retain the graph before starting it so a thrown start() can still be
        // stopped by the shared teardown path.
        self.engine = avEngine
        try avEngine.start()

        // Subscribe to engine configuration changes. AVAudioEngine fires this
        // when the underlying output device's I/O setup changes — including
        // when Continuity migrates the output device (e.g. AirPods → iPhone,
        // and back). Rebuild against the new default output on this signal in
        // addition to the kAudioHardwarePropertyDefaultOutputDevice listener
        // below, since the two don't always fire in lockstep.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                os_log(.default, log: appLog,
                       "AVAudioEngineConfigurationChange — restarting")
                Task { @MainActor in
                    guard let lifecycleCoordinator = self.lifecycleCoordinator else { return }
                    await lifecycleCoordinator.configurationChanged()
                    self.applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
                }
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
        sourceTapInstalled = true
        let postAnalyzer: SpectrumAnalyzer = self.postEqAnalyzer
        eqNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            postAnalyzer.process(buffer, sampleRate: capturedSampleRate)
        }
        eqTapInstalled = true

    }

    /// Changes the user's capture intent. The coordinator serializes this
    /// request with device, configuration, sleep, and helper events.
    func setEnabled(_ enabled: Bool) async {
        guard let lifecycleCoordinator else { return }
        await lifecycleCoordinator.setUserEnabled(enabled)
        applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
    }

    func handleSleep() async {
        guard let lifecycleCoordinator else { return }
        await lifecycleCoordinator.sleep()
        applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
    }

    func handleWake() async {
        guard let lifecycleCoordinator else { return }
        await lifecycleCoordinator.wake()
        applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
    }

    func shutdown() async {
        guard let lifecycleCoordinator else { return }
        await lifecycleCoordinator.shutdown()
        applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
    }

    func requestShutdown() {
        Task { @MainActor [weak self] in
            await self?.shutdown()
        }
    }

    private func applyLifecycleSnapshot(_ snapshot: AudioLifecycleSnapshot) {
        lifecycleState = snapshot.state
        userEnabled = snapshot.userEnabled
        lifecycleHistory = snapshot.history
        isRunning = snapshot.state == .running
        onStateChange?()
    }

    /// Releases every resource acquired by start(), including resources from a
    /// start that failed before isRunning became true. Tap removal is guarded by
    /// explicit installation state because AVAudioNode raises an Objective-C
    /// exception when removeTap(onBus:) is called on an empty bus.
    private func teardown() {
        isRunning = false

        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }

        rtCaptureClient = nil
        rtBiquadChainL = nil
        rtBiquadChainR = nil
        rtBiquadChainActive = false
        rtVolumeCompensation = 1.0

        // Remove spectrum taps before stopping engine
        if sourceTapInstalled {
            sourceNode?.removeTap(onBus: 0)
            sourceTapInstalled = false
        }
        if eqTapInstalled {
            eq?.removeTap(onBus: 0)
            eqTapInstalled = false
        }
        sourceNode = nil

        engine?.stop()
        engine = nil
        eq = nil
        outputGainEQ = nil
        limiter = nil

        // Terminate the capture helper. It cleans up its own CATap, aggregate,
        // IOProc, and shared memory.
        captureClient?.stop()
        captureClient = nil
    }

    // MARK: - EQ Control

    /// A muted band's gain for DSP purposes is always 0, regardless of its stored `.gain` —
    /// the stored value is preserved so muting is non-destructive (needed for CLI mute,
    /// which has no second, un-muted copy of the bands the way the GUI's own
    /// `pushBandsToEngine` does by zeroing `.gain` in a transient copy while keeping the
    /// real value in `DreamViewModel.bands`).
    private func effectiveGain(_ band: EQBand) -> Float {
        band.muted ? 0 : band.gain
    }

    private func withEffectiveGain(_ bands: [EQBand]) -> [EQBand] {
        bands.map { band -> EQBand in
            var b = band; b.gain = effectiveGain(band); return b
        }
    }

    /// Push `bands` into `rtBiquadChainL`/`R`, creating the chains on first use.
    private func updateBiquadChains(leftBands: [EQBand], rightBands: [EQBand], sampleRate: Double) {
        if let chainL = rtBiquadChainL {
            chainL.updateCoefficients(bands: leftBands, sampleRate: sampleRate)
        } else {
            rtBiquadChainL = BiquadFilterChain(bands: leftBands, sampleRate: sampleRate)
        }
        if let chainR = rtBiquadChainR {
            chainR.updateCoefficients(bands: rightBands, sampleRate: sampleRate)
        } else {
            rtBiquadChainR = BiquadFilterChain(bands: rightBands, sampleRate: sampleRate)
        }
    }

    private func applyBands(from old: EQPresetData? = nil) {
        guard let eq else { return }

        if splitChannelActive && !bypassed {
            // Split channel mode: bypass AVAudioUnitEQ, use custom biquad chains
            // for the full band lists — already unbounded, no AU capacity involved.
            eq.bypass = true
            let leftBands = withEffectiveGain(activePreset.bands)
            let rightBands = withEffectiveGain(activePreset.rightBands ?? activePreset.bands)
            updateBiquadChains(leftBands: leftBands, rightBands: rightBands, sampleRate: outputSampleRate)
            rtBiquadChainActive = true
        } else {
            // Linked mode: AVAudioUnitEQ natively processes the first
            // Self.avEQNativeBandCount bands; any remaining bands run through
            // the biquad chains instead, cascaded ahead of it in the render
            // callback — so band count here is CPU-bound, not AU-bound.
            let allBands = activePreset.bands
            let newCount = min(allBands.count, Self.avEQNativeBandCount)
            let oldCount = min(old?.bands.count ?? 0, Self.avEQNativeBandCount)

            for i in 0..<newCount {
                let band = allBands[i]
                let eqBand = eq.bands[i]
                if i >= oldCount {
                    // New band — configure fully
                    eqBand.filterType = band.filterType.avType
                    eqBand.frequency = band.frequency
                    eqBand.bandwidth = band.bandwidth
                    eqBand.gain = effectiveGain(band)
                    eqBand.bypass = false
                } else if let oldBand = old?.bands[i] {
                    // Existing band — only update changed params
                    if band.filterType != oldBand.filterType { eqBand.filterType = band.filterType.avType }
                    if band.frequency != oldBand.frequency { eqBand.frequency = band.frequency }
                    if effectiveGain(band) != effectiveGain(oldBand) { eqBand.gain = effectiveGain(band) }
                    if band.bandwidth != oldBand.bandwidth { eqBand.bandwidth = band.bandwidth }
                }
            }

            // Bypass AU slots not currently in use (covers both a preset shrinking
            // and the very first call, where oldCount is 0 and eq.bands defaults
            // to un-bypassed).
            if newCount < eq.bands.count {
                for i in newCount..<eq.bands.count {
                    eq.bands[i].bypass = true
                }
            }

            if allBands.count > Self.avEQNativeBandCount {
                let overflowBands = withEffectiveGain(Array(allBands[Self.avEQNativeBandCount...]))
                updateBiquadChains(leftBands: overflowBands, rightBands: overflowBands, sampleRate: outputSampleRate)
                rtBiquadChainActive = true
            } else {
                rtBiquadChainL = nil
                rtBiquadChainR = nil
                rtBiquadChainActive = false
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

    private func handleDeviceChange() {
        var outputDeviceChanged = false
        if let deviceID = try? getDefaultOutputDeviceID() {
            let previousUID = outputDeviceUID
            if let name = try? getDeviceName(deviceID) {
                outputDeviceName = name
            }
            let uid = try? getDeviceUID(deviceID)
            outputDeviceUID = uid
            outputDeviceChanged = defaultOutputDeviceChanged(previousUID: previousUID, currentUID: uid)
            if outputDeviceChanged, let uid, let pinned = pinnedPresetProvider?(uid) {
                activePreset = pinned
                var s = iQualizeState.load()
                s.selectedPresetID = pinned.id
                s.save()
            }
        }

        guard outputDeviceChanged else {
            onStateChange?()
            return
        }

        Task { @MainActor in
            guard let lifecycleCoordinator = self.lifecycleCoordinator else { return }
            await lifecycleCoordinator.deviceChanged()
            self.applyLifecycleSnapshot(await lifecycleCoordinator.snapshot())
        }
        onStateChange?()
    }

    // MARK: - New-process tap coverage
    //
    // Used to live here: a 2 s poll of kAudioHardwarePropertyProcessObjectList that
    // called the old restart path whenever the list grew, so a late-launched app that the tap
    // had silently dropped (#87) would get picked up. It worked, but the restart is a
    // full stop() + start() — helper, tap, aggregate, ring and AVAudioEngine graph all
    // torn down — and spliced ~100 ms of silence into playback every time any app
    // started making noise (#140).
    //
    // The capture helper now refreshes the live tap in place instead, by re-setting
    // kAudioTapPropertyDescription (see pollNewOutputProcesses in iQualizeCapture).
    // It already polls every second for the #131 mic exclusions, so this costs no new
    // timer, no new IPC, and no dropout.
}
