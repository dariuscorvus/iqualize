import XCTest
@testable import iQualize

final class RuntimeDiagnosticsPresentationTests: XCTestCase {
    func testUnavailableRowsDoNotInferDSPFromHardwareOutputRate() {
        let snapshot = RuntimeDiagnosticsSnapshot(status: AudioRuntimeStatus(
            lifecycleState: .inactive,
            userEnabled: false,
            isRunning: false,
            captureFormat: nil,
            renderFormat: nil,
            dspSampleRate: nil,
            outputDevice: CoreAudioOutputDevice(
                id: 42,
                name: "Studio Display Speakers",
                uid: nil,
                nominalSampleRate: 96_000,
                outputChannelCount: nil
            ),
            lastFailure: nil,
            captureHelperRestartCount: 0
        ))

        let presentation = RuntimeDiagnosticsPresentation.make(snapshot: snapshot)

        XCTAssertEqual(value("Effective Capture Format", in: presentation), "Unavailable")
        XCTAssertEqual(value("Render/DSP Format", in: presentation), "Render: Unavailable; DSP sample rate: Unavailable")
        XCTAssertEqual(value("Output Device Nominal Sample Rate", in: presentation), "96000 Hz")
        XCTAssertEqual(value("Output Device UID", in: presentation), "Unavailable")
        XCTAssertEqual(value("Output Device Output Channels", in: presentation), "Unavailable")
        XCTAssertEqual(value("Rates Differ", in: presentation), "Unavailable")
        XCTAssertEqual(value("Last Failure", in: presentation), "Unavailable")
        XCTAssertTrue(presentation.report.contains("DSP sample rate: Unavailable"))
        XCTAssertFalse(presentation.report.contains("DSP sample rate: 96000 Hz"))
    }

    func testFormatsRatesDifferDriftAndFailureForReport() {
        let status = AudioRuntimeStatus(
            lifecycleState: .running,
            userEnabled: true,
            isRunning: true,
            captureFormat: .init(sampleRate: 44_100, channelCount: 2),
            renderFormat: .init(sampleRate: 48_000, channelCount: 2),
            dspSampleRate: 48_000,
            outputDevice: CoreAudioOutputDevice(
                id: 7,
                name: "External DAC",
                uid: "dac-uid",
                nominalSampleRate: 96_000,
                outputChannelCount: 8
            ),
            lastFailure: .deviceUnavailable(.coreAudioStatus(-200)),
            captureHelperRestartCount: 3
        )
        let telemetry = CaptureClient.Telemetry(
            fillFrames: 512,
            driftPpm: -12.345,
            underruns: 2,
            overrunResyncs: 1
        )

        let presentation = RuntimeDiagnosticsPresentation.make(snapshot: .init(status: status, captureTelemetry: telemetry))

        XCTAssertEqual(value("Effective Capture Format", in: presentation), "44100 Hz, 2 ch")
        XCTAssertEqual(value("Render/DSP Format", in: presentation), "Render: 48000 Hz, 2 ch; DSP sample rate: 48000 Hz")
        XCTAssertEqual(value("Output Device Name", in: presentation), "External DAC")
        XCTAssertEqual(value("Output Device UID", in: presentation), "dac-uid")
        XCTAssertEqual(value("Output Device Output Channels", in: presentation), "8")
        XCTAssertEqual(value("Lifecycle State", in: presentation), "running (user enabled: Yes, running: Yes)")
        XCTAssertEqual(value("Rates Differ", in: presentation), "Yes")
        XCTAssertEqual(
            value("Drift/Resampling Status", in: presentation),
            "Resampling expected; drift -12.35 ppm; fill 512 frames; underruns 2; overrun resyncs 1"
        )
        XCTAssertEqual(value("Last Failure", in: presentation), "Core Audio device unavailable (status -200)")
        XCTAssertTrue(presentation.report.hasPrefix("iQualize Diagnostic Report\n"))
        XCTAssertTrue(presentation.report.contains("Output Device UID: dac-uid"))
    }

    func testMatchingEffectiveAndHardwareRatesReportNoDifference() {
        let status = AudioRuntimeStatus(
            lifecycleState: .running,
            userEnabled: true,
            isRunning: true,
            captureFormat: .init(sampleRate: 48_000, channelCount: 2),
            renderFormat: .init(sampleRate: 48_000, channelCount: 2),
            dspSampleRate: 48_000,
            outputDevice: .init(
                id: 1,
                name: "Built-in Output",
                uid: "builtin",
                nominalSampleRate: 48_000,
                outputChannelCount: 2
            ),
            lastFailure: nil,
            captureHelperRestartCount: 0
        )

        let presentation = RuntimeDiagnosticsPresentation.make(snapshot: .init(status: status))

        XCTAssertEqual(value("Rates Differ", in: presentation), "No")
        XCTAssertEqual(value("Drift/Resampling Status", in: presentation), "Unavailable")
    }

    private func value(_ label: String, in presentation: RuntimeDiagnosticsPresentation) -> String? {
        presentation.rows.first { $0.label == label }?.value
    }
}
