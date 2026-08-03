import XCTest
@testable import iQualize

final class AudioRuntimeStatusTests: XCTestCase {
    func testInitialStatusHasSeparatedInactiveTelemetry() {
        let status = AudioRuntimeStatus.initial

        XCTAssertEqual(status.lifecycleState, .inactive)
        XCTAssertFalse(status.userEnabled)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.captureFormat)
        XCTAssertNil(status.renderFormat)
        XCTAssertNil(status.dspSampleRate)
        XCTAssertNil(status.outputDevice)
        XCTAssertNil(status.lastFailure)
        XCTAssertEqual(status.captureHelperRestartCount, 0)
    }

    func testLifecycleUpdatePreservesTelemetryAndDerivesRunningFlag() {
        let output = CoreAudioOutputDevice(id: 42, name: "USB DAC", uid: "dac", nominalSampleRate: 96_000)
        let format = AudioRuntimeStatus.StreamFormat(sampleRate: 48_000, channelCount: 2)
        let status = AudioRuntimeStatus.initial
            .updatingOutputDevice(output)
            .updatingFormats(captureFormat: format, renderFormat: format, dspSampleRate: 48_000)
            .updatingLifecycle(state: .running, userEnabled: true, captureHelperRestartCount: 3)

        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.captureFormat?.sampleRate, 48_000)
        XCTAssertEqual(status.renderFormat?.sampleRate, 48_000)
        XCTAssertEqual(status.dspSampleRate, 48_000)
        XCTAssertEqual(status.outputDevice?.nominalSampleRate, 96_000)
        XCTAssertNil(status.outputDevice?.outputChannelCount)
        XCTAssertNil(status.lastFailure)
        XCTAssertEqual(status.captureHelperRestartCount, 3)
    }

    func testFailedLifecycleUpdateCarriesLastFailureWithoutClearingTelemetry() {
        let output = CoreAudioOutputDevice(id: 42, name: "USB DAC", uid: "dac", nominalSampleRate: 96_000)
        let format = AudioRuntimeStatus.StreamFormat(sampleRate: 48_000, channelCount: 2)
        let running = AudioRuntimeStatus.initial
            .updatingOutputDevice(output)
            .updatingFormats(captureFormat: format, renderFormat: format, dspSampleRate: 48_000)
            .updatingLifecycle(state: .running, userEnabled: true, captureHelperRestartCount: 2)

        let failed = running.updatingLifecycle(
            state: .failed,
            userEnabled: true,
            lastFailure: .deviceUnavailable(.defaultOutputNotReady)
        )

        XCTAssertEqual(failed.lifecycleState, .failed)
        XCTAssertTrue(failed.userEnabled)
        XCTAssertFalse(failed.isRunning)
        XCTAssertEqual(failed.captureFormat, format)
        XCTAssertEqual(failed.renderFormat, format)
        XCTAssertEqual(failed.dspSampleRate, 48_000)
        XCTAssertEqual(failed.outputDevice, output)
        XCTAssertEqual(failed.lastFailure, .deviceUnavailable(.defaultOutputNotReady))
        XCTAssertEqual(failed.captureHelperRestartCount, 2)
    }

    func testClearingActiveStreamFormatsPreservesOutputDeviceTelemetryAndLastFailure() {
        let output = CoreAudioOutputDevice(id: 7, name: "Built-in", uid: "builtin", nominalSampleRate: 44_100)
        let format = AudioRuntimeStatus.StreamFormat(sampleRate: 48_000, channelCount: 2)
        let status = AudioRuntimeStatus.initial
            .updatingOutputDevice(output)
            .updatingFormats(captureFormat: format, renderFormat: format, dspSampleRate: 48_000)
            .updatingLifecycle(
                state: .failed,
                userEnabled: true,
                lastFailure: .permissionDenied(.processTap(status: -54)),
                captureHelperRestartCount: 4
            )
            .clearingActiveStreamFormats()

        XCTAssertNil(status.captureFormat)
        XCTAssertNil(status.renderFormat)
        XCTAssertNil(status.dspSampleRate)
        XCTAssertEqual(status.outputDevice, output)
        XCTAssertEqual(status.lastFailure, .permissionDenied(.processTap(status: -54)))
        XCTAssertEqual(status.captureHelperRestartCount, 4)
    }

    func testOutputHardwareRateAndChannelsAreDistinctFromDSPRate() {
        let output = CoreAudioOutputDevice(
            id: 7,
            name: "DAC",
            uid: "dac",
            nominalSampleRate: 192_000,
            outputChannelCount: 8
        )
        let capture = AudioRuntimeStatus.StreamFormat(sampleRate: 48_000, channelCount: 2)
        let render = AudioRuntimeStatus.StreamFormat(sampleRate: 48_000, channelCount: 2)
        let status = AudioRuntimeStatus.initial
            .updatingOutputDevice(output)
            .updatingFormats(captureFormat: capture, renderFormat: render, dspSampleRate: 48_000)

        XCTAssertEqual(status.outputDevice?.nominalSampleRate, 192_000)
        XCTAssertEqual(status.outputDevice?.outputChannelCount, 8)
        XCTAssertEqual(status.captureFormat?.channelCount, 2)
        XCTAssertEqual(status.renderFormat?.channelCount, 2)
        XCTAssertEqual(status.dspSampleRate, 48_000)
    }
}
