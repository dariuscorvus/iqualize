import CoreAudio
import AudioToolbox
import AVFAudio
import Foundation
import IQRingAtomics
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

/// Scratch buffer for deinterleaving (allocated once, reused).
nonisolated(unsafe) private var rtScratchBuffer: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtScratchCapacity: Int = 0

/// Complete immutable configuration acquired by the render callback. The
/// callback-visible fields are raw pointers and scalars, so acquiring them does
/// not retain a CaptureClient or BiquadFilterChain. The private owner fields
/// retain those objects off the callback path until the publication quiescence
/// protocol retires this snapshot.
struct RenderConfiguration: @unchecked Sendable {
    let captureClient: UnsafeMutableRawPointer?
    let channelCount: UInt32
    let scratchBuffer: UnsafeMutablePointer<Float>?
    let scratchCapacity: Int
    let balanceLeft: Float
    let balanceRight: Float
    let inputGain: Float
    /// Multiplies back the stereo-pair headroom attenuation of the mixdown tap
    /// (see GainPolicy.tapHeadroomCompensation). Applied unconditionally — the tap
    /// attenuates in Bypass too, so Bypass must compensate to sound like app-off.
    let volumeCompensation: Float
    /// Per-channel biquad filter chains, run in this callback ahead of AVAudioUnitEQ.
    /// In split channel mode they carry the full band lists; in linked mode they
    /// carry only the bands beyond AVAudioUnitEQ's fixed native capacity. There is
    /// no bounded internal capacity here: each publication allocates exactly the
    /// requested chain sizes off the real-time path, preserving unlimited bands.
    let biquadChainL: UnsafeMutableRawPointer?
    let biquadChainR: UnsafeMutableRawPointer?

    // These owners are deliberately not read by the render callback. They live
    // inside the published storage so an old snapshot keeps its raw pointers
    // valid until the main-actor reclamation pass destroys that storage.
    private let captureClientOwner: CaptureClient?
    private let biquadChainLOwner: BiquadFilterChain?
    private let biquadChainROwner: BiquadFilterChain?

    var biquadChainActive: Bool { biquadChainL != nil || biquadChainR != nil }

    init(
        captureClient: CaptureClient?,
        channelCount: UInt32,
        scratchBuffer: UnsafeMutablePointer<Float>? = nil,
        scratchCapacity: Int = 0,
        balanceLeft: Float,
        balanceRight: Float,
        inputGain: Float,
        volumeCompensation: Float,
        biquadChainL: BiquadFilterChain?,
        biquadChainR: BiquadFilterChain?
    ) {
        self.captureClientOwner = captureClient
        self.biquadChainLOwner = biquadChainL
        self.biquadChainROwner = biquadChainR
        self.captureClient = captureClient.map { Unmanaged.passUnretained($0).toOpaque() }
        self.channelCount = channelCount
        self.scratchBuffer = scratchBuffer
        self.scratchCapacity = scratchCapacity
        self.balanceLeft = balanceLeft
        self.balanceRight = balanceRight
        self.inputGain = inputGain
        self.volumeCompensation = volumeCompensation
        self.biquadChainL = biquadChainL.map { Unmanaged.passUnretained($0).toOpaque() }
        self.biquadChainR = biquadChainR.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    /// Test-only owner access. The render callback reads only the raw pointer
    /// fields below and never calls this property.
    var biquadChainLForTesting: BiquadFilterChain? {
        guard let biquadChainL else { return nil }
        return Unmanaged<BiquadFilterChain>.fromOpaque(biquadChainL).takeUnretainedValue()
    }

    var biquadChainRForTesting: BiquadFilterChain? {
        guard let biquadChainR else { return nil }
        return Unmanaged<BiquadFilterChain>.fromOpaque(biquadChainR).takeUnretainedValue()
    }
}

struct RenderConfigurationHandle {
    fileprivate let pointer: UnsafeMutableRawPointer?

    private var storage: UnsafeMutablePointer<RenderConfiguration>? {
        pointer?.assumingMemoryBound(to: RenderConfiguration.self)
    }

    // Callback-safe scalar/raw-pointer accessors. Returning the whole struct
    // would copy its owner references and introduce ARC traffic on the IO
    // thread, so the callback must use these fields instead.
    var captureClient: UnsafeMutableRawPointer? { storage?.pointee.captureClient }
    var channelCount: UInt32 { storage?.pointee.channelCount ?? 0 }
    var scratchBuffer: UnsafeMutablePointer<Float>? { storage?.pointee.scratchBuffer }
    var scratchCapacity: Int { storage?.pointee.scratchCapacity ?? 0 }
    var balanceLeft: Float { storage?.pointee.balanceLeft ?? 1 }
    var balanceRight: Float { storage?.pointee.balanceRight ?? 1 }
    var inputGain: Float { storage?.pointee.inputGain ?? 1 }
    var volumeCompensation: Float { storage?.pointee.volumeCompensation ?? 1 }
    var biquadChainL: UnsafeMutableRawPointer? { storage?.pointee.biquadChainL }
    var biquadChainR: UnsafeMutableRawPointer? { storage?.pointee.biquadChainR }

    /// Test-only value access. Production callback code must use the scalar
    /// accessors above so the owner references are never copied on the IO path.
    var configurationForTesting: RenderConfiguration? {
        storage?.pointee
    }

    func releaseRead() {
        rtLeave(rtRenderPublication)
    }
}

nonisolated(unsafe) private let rtRenderPublication: UnsafeMutablePointer<RTSnapshotPublication> = {
    let pointer = UnsafeMutablePointer<RTSnapshotPublication>.allocate(capacity: 1)
    pointer.initialize(to: RTSnapshotPublication())
    return pointer
}()

nonisolated(unsafe) private var retiredRenderConfigurations: [UnsafeMutableRawPointer] = []

func acquireRenderConfigurationForTesting() -> RenderConfigurationHandle {
    let pointer = rtEnter(rtRenderPublication)
    return RenderConfigurationHandle(pointer: pointer)
}

@discardableResult
func publishRenderConfigurationForTesting(_ configuration: RenderConfiguration?) -> Int {
    let newPointer: UnsafeMutableRawPointer? = configuration.map { value in
        let pointer = UnsafeMutablePointer<RenderConfiguration>.allocate(capacity: 1)
        pointer.initialize(to: value)
        return UnsafeMutableRawPointer(pointer)
    }
    if let oldPointer = publishSnapshot(rtRenderPublication, newPointer) {
        retiredRenderConfigurations.append(oldPointer)
    }
    // Never wait for a zero-reader window during an ordinary configuration
    // update. Audio callbacks may run continuously. A later main-thread pass
    // reclaims retired storage once the reader count reaches zero.
    _ = reclaimQuiescentRenderConfigurationsForTesting()
    return retiredRenderConfigurations.count
}

@discardableResult
func reclaimQuiescentRenderConfigurationsForTesting() -> Int {
    let readers = withUnsafePointer(to: &rtRenderPublication.pointee.readers) { pointer in
        iq_load_snapshot_readers(pointer)
    }
    guard readers == 0 else { return retiredRenderConfigurations.count }
    let retired = retiredRenderConfigurations
    retiredRenderConfigurations.removeAll(keepingCapacity: true)
    for oldPointer in retired {
        let pointer = oldPointer.assumingMemoryBound(to: RenderConfiguration.self)
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    return retiredRenderConfigurations.count
}

private func waitAndReclaimRenderConfigurations() {
    waitForSnapshotQuiescence(rtRenderPublication)
    _ = reclaimQuiescentRenderConfigurationsForTesting()
}

/// AVAudioSourceNode render block: pulls interleaved audio from the capture
/// client's shared ring buffer, deinterleaves into separate channel buffers
/// for the non-interleaved AVAudioEngine format.
private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let handle = acquireRenderConfigurationForTesting()
    guard let client = handle.captureClient else {
        renderSilence(bufferList, frameCount: Int(frameCount))
        handle.releaseRead()
        return noErr
    }
    let ch = Int(handle.channelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames.multipliedReportingOverflow(by: ch)

    // The render path never grows storage. The engine preallocates for the
    // audio unit's maximum slice during start; an unexpected oversized slice
    // is rendered as silence rather than allocating on the IO thread.
    guard !interleavedCount.overflow,
          renderScratchCapacityAllows(frameCount: frames, channelCount: ch,
                                      scratchCapacity: handle.scratchCapacity),
          let scratch = handle.scratchBuffer else {
        renderSilence(bufferList, frameCount: frames)
        handle.releaseRead()
        return noErr
    }
    let sampleCount = interleavedCount.partialValue

    // All-or-nothing: a full drift-compensated block (#133), or silence
    // while the ring seeds / after an underrun.
    if CaptureClient.readResampledRT(client, destination: scratch, frames: frames) == 0 {
        scratch.initialize(repeating: 0.0, count: sampleCount)
    }

    for i in 0..<bufferList.count {
        guard let outData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let balance = i == 0 ? handle.balanceLeft : handle.balanceRight
        deinterleaveChannel(scratch, into: outData, channel: i, channelCount: ch,
                            frames: frames, gain: handle.inputGain * balance * handle.volumeCompensation)
    }

    // Apply per-channel biquad EQ when a chain is configured — either the whole
    // preset in split channel mode (AVAudioUnitEQ bypassed), or the overflow
    // bands beyond AVAudioUnitEQ's native capacity in linked mode (runs ahead
    // of it in the graph, feeding it already-partially-EQ'd audio).
    if handle.biquadChainL != nil || handle.biquadChainR != nil {
        if bufferList.count > 0, let outL = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
            if let chain = handle.biquadChainL {
                BiquadFilterChain.processRT(chain, buffer: outL, frameCount: frames)
            }
        }
        if bufferList.count > 1, let outR = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
            if let chain = handle.biquadChainR {
                BiquadFilterChain.processRT(chain, buffer: outR, frameCount: frames)
            }
        }
    }

    handle.releaseRead()
    return noErr
}

/// Fill the source node's caller-owned output buffers without allocating. This
/// is used when the graph is inactive or asks for more frames than the bounded
/// scratch buffer can hold.
@inline(__always)
func renderSilence(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
    guard frameCount > 0 else { return }
    for index in 0..<bufferList.count {
        guard let data = bufferList[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
        data.initialize(repeating: 0, count: frameCount)
    }
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

/// The render callback may only use its preallocated scratch storage. An
/// oversized callback is rendered as silence rather than growing storage on
/// the real-time thread.
@inline(__always)
func renderScratchCapacityAllows(frameCount: Int, channelCount: Int, scratchCapacity: Int) -> Bool {
    guard frameCount >= 0, channelCount >= 0 else { return false }
    let (sampleCount, overflow) = frameCount.multipliedReportingOverflow(by: channelCount)
    return !overflow && sampleCount <= scratchCapacity
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
    /// The source AU is explicitly bounded before render resources are
    /// allocated. Requests above this value are rendered as silence rather
    /// than growing scratch storage on the IO thread.
    private static let renderMaximumFramesPerSlice: AVAudioFrameCount = 4096

    private(set) var isRunning = false
    private(set) var lifecycleState: AudioLifecycleState = .inactive
    private(set) var userEnabled = false
    private(set) var lifecycleHistory: [AudioLifecycleTransition] = []
    private(set) var outputDeviceName = "Unknown"
    private(set) var outputDeviceUID: String?
    private(set) var runtimeStatus: AudioRuntimeStatus = .initial
    private(set) var lastFailure: AudioRuntimeFailure?
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
    private var renderChannelCount: UInt32 = 2
    private var renderBalanceLeft: Float = 1.0
    private var renderBalanceRight: Float = 1.0
    private var renderInputGain: Float = 1.0
    private var renderVolumeCompensation: Float = 1.0
    private var renderBiquadChainL: BiquadFilterChain?
    private var renderBiquadChainR: BiquadFilterChain?

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
    /// Fired after a device change applies a pinned preset, so the owner can
    /// persist the new selection. AudioEngine itself never writes app
    /// persistence — same decoupling rationale as `pinnedPresetProvider`.
    var onPinnedPresetApplied: ((UUID) -> Void)?

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
        renderInputGain = GainPolicy.inputGain(dB: inputGainDB, bypassed: bypassed)
        publishRenderConfiguration()
    }

    private func updateBalance() {
        (renderBalanceLeft, renderBalanceRight) = GainPolicy.balanceGains(balance, bypassed: bypassed)
        publishRenderConfiguration()
    }

    private func updateOutputGain() {
        outputGainEQ?.globalGain = GainPolicy.outputGainDB(outputGainDB, bypassed: bypassed)
    }

    private func publishRenderConfiguration() {
        publishRenderConfigurationForTesting(RenderConfiguration(
            captureClient: captureClient,
            channelCount: renderChannelCount,
            scratchBuffer: rtScratchBuffer,
            scratchCapacity: rtScratchCapacity,
            balanceLeft: renderBalanceLeft,
            balanceRight: renderBalanceRight,
            inputGain: renderInputGain,
            volumeCompensation: renderVolumeCompensation,
            biquadChainL: renderBiquadChainL,
            biquadChainR: renderBiquadChainR
        ))
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
        refreshOutputDeviceTelemetry()
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
            publishFailure: { @MainActor [weak self] failure in
                self?.lastFailure = failure
                self?.publishRuntimeStatus()
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
        refreshOutputDeviceTelemetry()

        // 1. Launch the capture helper — it owns the CATap, tap-only aggregate,
        //    and IOProc in a separate process. We just consume its shared-memory
        //    ring buffer. This is the architectural fix for AirPods Continuity
        //    handoff: by not having a CATap in this process, Continuity's
        //    preemption can release our render from the AirPods (see docs/CONTINUITY.md).
        let client = CaptureClient()
        client.onUnexpectedTermination = { [weak self] in
            guard let self else { return }
            self.captureHelperRestartCount &+= 1
            self.publishRuntimeStatus()
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
        renderChannelCount = channels
        let captureFormat = AudioRuntimeStatus.StreamFormat(sampleRate: sampleRate, channelCount: channels)
        let renderFormat = AudioRuntimeStatus.StreamFormat(sampleRate: sampleRate, channelCount: channels)
        publishRuntimeStatus(captureFormat: captureFormat, renderFormat: renderFormat, dspSampleRate: sampleRate)

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
        sourceNode.auAudioUnit.maximumFramesToRender = Self.renderMaximumFramesPerSlice
        let maximumFramesPerSlice = Int(sourceNode.auAudioUnit.maximumFramesToRender)
        guard maximumFramesPerSlice > 0 else {
            throw NSError(domain: "iQualize", code: -201, userInfo: [
                NSLocalizedDescriptionKey: "Audio source returned an invalid maximum render slice"
            ])
        }
        let scratchFloats = maximumFramesPerSlice.multipliedReportingOverflow(by: Int(channels))
        guard !scratchFloats.overflow else {
            throw NSError(domain: "iQualize", code: -202, userInfo: [
                NSLocalizedDescriptionKey: "Audio render scratch size overflowed"
            ])
        }
        if rtScratchCapacity < scratchFloats.partialValue {
            rtScratchBuffer?.deallocate()
            rtScratchBuffer = .allocate(capacity: scratchFloats.partialValue)
            rtScratchCapacity = scratchFloats.partialValue
        }
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
        renderVolumeCompensation = GainPolicy.tapHeadroomCompensation(outputChannels: outputChannels)
        publishRenderConfiguration()
        os_log(.default, log: appLog,
               "output hw channels: %{public}d  tap headroom compensation: x%{public}.1f",
               outputChannels, renderVolumeCompensation)

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
        publishRuntimeStatus()
        onStateChange?()
    }

    private func refreshOutputDeviceTelemetry() {
        do {
            let outputDevice = try getDefaultOutputDevice()
            outputDeviceName = outputDevice.name
            outputDeviceUID = outputDevice.uid
            runtimeStatus = runtimeStatus.updatingOutputDevice(outputDevice)
        } catch {
            outputDeviceName = "Unknown"
            outputDeviceUID = nil
            runtimeStatus = runtimeStatus.updatingOutputDevice(nil)
        }
    }

    private func publishRuntimeStatus(
        captureFormat: AudioRuntimeStatus.StreamFormat? = nil,
        renderFormat: AudioRuntimeStatus.StreamFormat? = nil,
        dspSampleRate: Double? = nil,
        clearActiveStreamFormats: Bool = false
    ) {
        var next = runtimeStatus.updatingLifecycle(
            state: lifecycleState,
            userEnabled: userEnabled,
            lastFailure: lastFailure,
            captureHelperRestartCount: captureHelperRestartCount
        )
        if clearActiveStreamFormats {
            next = next.clearingActiveStreamFormats()
        } else if captureFormat != nil || renderFormat != nil || dspSampleRate != nil {
            next = next.updatingFormats(
                captureFormat: captureFormat ?? next.captureFormat,
                renderFormat: renderFormat ?? next.renderFormat,
                dspSampleRate: dspSampleRate ?? next.dspSampleRate
            )
        }
        runtimeStatus = next
    }

    /// Releases every resource acquired by start(), including resources from a
    /// start that failed before isRunning became true. Tap removal is guarded by
    /// explicit installation state because AVAudioNode raises an Objective-C
    /// exception when removeTap(onBus:) is called on an empty bus.
    private func teardown() {
        isRunning = false
        publishRuntimeStatus(clearActiveStreamFormats: true)

        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }

        // Keep the old owners alive while the graph stops. The callback holds
        // only opaque pointers, so dropping these properties before the graph
        // is quiescent would create a use-after-free window.
        let retiringClient = captureClient
        let retiringChainL = renderBiquadChainL
        let retiringChainR = renderBiquadChainR

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

        // No new callbacks can start after the graph stops. Retire the
        // configuration and wait only for a callback that was already in
        // flight before stopping the engine.
        captureClient = nil
        renderBiquadChainL = nil
        renderBiquadChainR = nil
        renderVolumeCompensation = 1.0
        publishRenderConfigurationForTesting(nil)
        waitAndReclaimRenderConfigurations()

        // Terminate the capture helper. It cleans up its own CATap, aggregate,
        // IOProc, and shared memory.
        retiringClient?.stop()

        // No callback can dereference the retired configuration now. Release the
        // scratch storage that the snapshot carried as a raw pointer.
        rtScratchBuffer?.deallocate()
        rtScratchBuffer = nil
        rtScratchCapacity = 0

        // Keep these locals alive until after reclamation so the lifetime proof
        // remains explicit even if the retired snapshot was already reclaimed.
        _ = retiringChainL
        _ = retiringChainR
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

    /// Build or update chains off the render thread. Reusing a chain preserves
    /// delay state and lets its immutable snapshots ramp coefficients during
    /// live edits. A changed preset identity requests the documented zero-state
    /// reset while still using the same coefficient ramp.
    private func updateBiquadChains(
        leftBands: [EQBand],
        rightBands: [EQBand],
        sampleRate: Double,
        resetState: Bool = false
    ) {
        if let chain = renderBiquadChainL {
            chain.updateCoefficients(bands: leftBands, sampleRate: sampleRate, resetState: resetState)
        } else {
            renderBiquadChainL = BiquadFilterChain(bands: leftBands, sampleRate: sampleRate)
        }
        if let chain = renderBiquadChainR {
            chain.updateCoefficients(bands: rightBands, sampleRate: sampleRate, resetState: resetState)
        } else {
            renderBiquadChainR = BiquadFilterChain(bands: rightBands, sampleRate: sampleRate)
        }
    }

    private func applyBands(from old: EQPresetData? = nil) {
        guard let eq else { return }
        let resetState = old.map { $0.id != activePreset.id } ?? false

        if splitChannelActive && !bypassed {
            // Split channel mode: bypass AVAudioUnitEQ, use custom biquad chains
            // for the full band lists — already unbounded, no AU capacity involved.
            eq.bypass = true
            let leftBands = withEffectiveGain(activePreset.bands)
            let rightBands = withEffectiveGain(activePreset.rightBands ?? activePreset.bands)
            updateBiquadChains(
                leftBands: leftBands,
                rightBands: rightBands,
                sampleRate: outputSampleRate,
                resetState: resetState
            )
            publishRenderConfiguration()
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
                updateBiquadChains(
                    leftBands: overflowBands,
                    rightBands: overflowBands,
                    sampleRate: outputSampleRate,
                    resetState: resetState
                )
            } else {
                renderBiquadChainL = nil
                renderBiquadChainR = nil
                publishRenderConfiguration()
                eq.globalGain = 0
                eq.bypass = bypassed || activePreset.isFlat
                limiter?.bypass = !peakLimiter || bypassed
                return
            }
            publishRenderConfiguration()

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
        let previousUID = outputDeviceUID
        refreshOutputDeviceTelemetry()
        let uid = outputDeviceUID
        let outputDeviceChanged = defaultOutputDeviceChanged(previousUID: previousUID, currentUID: uid)
        if outputDeviceChanged, let uid, let pinned = pinnedPresetProvider?(uid) {
            activePreset = pinned
            onPinnedPresetApplied?(pinned.id)
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
