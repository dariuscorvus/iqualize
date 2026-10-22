import CoreAudio
import Foundation

/// Immutable, point-in-time runtime telemetry for the audio stack.
///
/// Keep the meanings distinct:
/// - captureFormat describes the helper/tap stream consumed by iQualize.
/// - renderFormat describes the AVAudioEngine source/render graph format.
/// - dspSampleRate is the rate used for EQ/biquad coefficients.
/// - outputDevice describes the current system default output hardware.
///
/// The hardware output device's nominal sample rate is telemetry only. DSP
/// coefficients must continue to use dspSampleRate, which is derived from the
/// capture/render stream.
struct AudioRuntimeStatus: Sendable, Equatable {
    struct StreamFormat: Sendable, Equatable {
        let sampleRate: Double
        let channelCount: UInt32

        init(sampleRate: Double, channelCount: UInt32) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    let lifecycleState: AudioLifecycleState
    let userEnabled: Bool
    let isRunning: Bool
    let captureFormat: StreamFormat?
    let renderFormat: StreamFormat?
    let dspSampleRate: Double?
    let outputDevice: CoreAudioOutputDevice?
    let lastFailure: AudioRuntimeFailure?
    let captureHelperRestartCount: UInt64

    static let initial = AudioRuntimeStatus(
        lifecycleState: .inactive,
        userEnabled: false,
        isRunning: false,
        captureFormat: nil,
        renderFormat: nil,
        dspSampleRate: nil,
        outputDevice: nil,
        lastFailure: nil,
        captureHelperRestartCount: 0
    )

    init(
        lifecycleState: AudioLifecycleState,
        userEnabled: Bool,
        isRunning: Bool,
        captureFormat: StreamFormat?,
        renderFormat: StreamFormat?,
        dspSampleRate: Double?,
        outputDevice: CoreAudioOutputDevice?,
        lastFailure: AudioRuntimeFailure?,
        captureHelperRestartCount: UInt64
    ) {
        self.lifecycleState = lifecycleState
        self.userEnabled = userEnabled
        self.isRunning = isRunning
        self.captureFormat = captureFormat
        self.renderFormat = renderFormat
        self.dspSampleRate = dspSampleRate
        self.outputDevice = outputDevice
        self.lastFailure = lastFailure
        self.captureHelperRestartCount = captureHelperRestartCount
    }

    func updatingLifecycle(
        state: AudioLifecycleState,
        userEnabled: Bool,
        lastFailure: AudioRuntimeFailure? = nil,
        captureHelperRestartCount: UInt64? = nil
    ) -> AudioRuntimeStatus {
        AudioRuntimeStatus(
            lifecycleState: state,
            userEnabled: userEnabled,
            isRunning: state == .running,
            captureFormat: captureFormat,
            renderFormat: renderFormat,
            dspSampleRate: dspSampleRate,
            outputDevice: outputDevice,
            lastFailure: lastFailure,
            captureHelperRestartCount: captureHelperRestartCount ?? self.captureHelperRestartCount
        )
    }

    func updatingFormats(
        captureFormat: StreamFormat?,
        renderFormat: StreamFormat?,
        dspSampleRate: Double?
    ) -> AudioRuntimeStatus {
        AudioRuntimeStatus(
            lifecycleState: lifecycleState,
            userEnabled: userEnabled,
            isRunning: isRunning,
            captureFormat: captureFormat,
            renderFormat: renderFormat,
            dspSampleRate: dspSampleRate,
            outputDevice: outputDevice,
            lastFailure: lastFailure,
            captureHelperRestartCount: captureHelperRestartCount
        )
    }

    func updatingOutputDevice(_ outputDevice: CoreAudioOutputDevice?) -> AudioRuntimeStatus {
        AudioRuntimeStatus(
            lifecycleState: lifecycleState,
            userEnabled: userEnabled,
            isRunning: isRunning,
            captureFormat: captureFormat,
            renderFormat: renderFormat,
            dspSampleRate: dspSampleRate,
            outputDevice: outputDevice,
            lastFailure: lastFailure,
            captureHelperRestartCount: captureHelperRestartCount
        )
    }

    func clearingActiveStreamFormats() -> AudioRuntimeStatus {
        updatingFormats(captureFormat: nil, renderFormat: nil, dspSampleRate: nil)
    }
}

struct CoreAudioOutputDevice: Sendable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String?
    let nominalSampleRate: Double?
    let outputChannelCount: UInt32?
    let transportType: UInt32?

    init(
        id: AudioDeviceID,
        name: String,
        uid: String?,
        nominalSampleRate: Double?,
        outputChannelCount: UInt32? = nil,
        transportType: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.uid = uid
        self.nominalSampleRate = nominalSampleRate
        self.outputChannelCount = outputChannelCount
        self.transportType = transportType
    }

    /// UID the capture helper may tap directly instead of the global stereo
    /// mixdown, or nil to keep the global tap. Only wired stereo hardware
    /// qualifies: multi-channel devices rely on the mixdown's headroom
    /// compensation (#107), Bluetooth devices on the Continuity handoff proven
    /// with the global tap (docs/CONTINUITY.md), and AirPlay, virtual and
    /// aggregate devices were never measured with a device-bound tap.
    var deviceTapUID: String? {
        guard outputChannelCount == 2, let transportType,
              Self.wiredTransportTypes.contains(transportType) else { return nil }
        return uid
    }

    private static let wiredTransportTypes: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypeThunderbolt,
        kAudioDeviceTransportTypePCI,
    ]
}

/// Read-only view assembled off the audio callback. Both the diagnostics window
/// and the CLI status surface consume this same snapshot so they cannot drift in
/// how they interpret effective formats versus live capture telemetry.
struct AudioRuntimeDiagnosticsSnapshot: Sendable {
    let status: AudioRuntimeStatus
    let captureTelemetry: CaptureClient.Telemetry?

    init(status: AudioRuntimeStatus, captureTelemetry: CaptureClient.Telemetry? = nil) {
        self.status = status
        self.captureTelemetry = captureTelemetry
    }
}
