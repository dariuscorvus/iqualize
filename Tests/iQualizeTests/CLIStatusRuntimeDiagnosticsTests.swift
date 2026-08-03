import Foundation
import IQControlProtocol
import XCTest

@testable import iqualize_cli

final class CLIStatusRuntimeDiagnosticsTests: XCTestCase {
    private let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func makeStatus(
        runtimeLifecycleState: String? = nil,
        runtimeCaptureSampleRate: Double? = nil,
        runtimeCaptureChannelCount: UInt32? = nil,
        runtimeRenderSampleRate: Double? = nil,
        runtimeRenderChannelCount: UInt32? = nil,
        runtimeDSPSampleRate: Double? = nil,
        runtimeOutputDeviceUID: String? = nil,
        runtimeOutputDeviceNominalSampleRate: Double? = nil,
        runtimeOutputDeviceChannelCount: UInt32? = nil,
        runtimeRatesDiffer: Bool? = nil,
        runtimeResamplingActive: Bool? = nil,
        runtimeUnavailableReason: String? = nil
    ) -> CLIStatusPayload {
        CLIStatusPayload(
            bypassed: false,
            activePresetID: presetID,
            activePresetName: "Flat",
            inputGainDB: 0,
            outputGainDB: 0,
            balance: 0,
            gainIsGlobal: true,
            outputDeviceName: "MacBook Speakers",
            isRunning: true,
            peakLimiter: true,
            preEqSpectrumEnabled: false,
            postEqSpectrumEnabled: true,
            appVersion: "0.59.0",
            gitCommit: "abcdef0",
            runtimeLifecycleState: runtimeLifecycleState,
            runtimeCaptureSampleRate: runtimeCaptureSampleRate,
            runtimeCaptureChannelCount: runtimeCaptureChannelCount,
            runtimeRenderSampleRate: runtimeRenderSampleRate,
            runtimeRenderChannelCount: runtimeRenderChannelCount,
            runtimeDSPSampleRate: runtimeDSPSampleRate,
            runtimeOutputDeviceUID: runtimeOutputDeviceUID,
            runtimeOutputDeviceNominalSampleRate: runtimeOutputDeviceNominalSampleRate,
            runtimeOutputDeviceChannelCount: runtimeOutputDeviceChannelCount,
            runtimeRatesDiffer: runtimeRatesDiffer,
            runtimeResamplingActive: runtimeResamplingActive,
            runtimeUnavailableReason: runtimeUnavailableReason
        )
    }

    func testOldStatusFormattingIsUnchangedWhenRuntimeDiagnosticsAreAbsent() {
        let output = formatStatus(makeStatus())

        XCTAssertEqual(output, """
        Version: 0.59.0 (abcdef0)
        Capture: on
        Bypass: off
        Peak limiter: on
        Preset: Flat
        Gain: input +0.0 dB, output +0.0 dB (shared)
        Balance: center
        Pre-EQ spectrum: off
        Post-EQ spectrum: on
        Output device: MacBook Speakers
        """)
        XCTAssertFalse(output.contains("Runtime diagnostics:"))
    }

    func testRuntimeDiagnosticsFormattingIncludesUnavailableForNilValues() {
        let output = formatStatus(makeStatus(
            runtimeLifecycleState: "running",
            runtimeCaptureSampleRate: 48_000,
            runtimeCaptureChannelCount: 2,
            runtimeRenderSampleRate: 48_000,
            runtimeRenderChannelCount: 2,
            runtimeDSPSampleRate: 48_000,
            runtimeRatesDiffer: false,
            runtimeResamplingActive: true
        ))

        XCTAssertTrue(output.contains("Runtime diagnostics:"))
        XCTAssertTrue(output.contains("  Lifecycle: running"))
        XCTAssertTrue(output.contains("  Capture stream: 48000 Hz, 2 channels"))
        XCTAssertTrue(output.contains("  Render stream: 48000 Hz, 2 channels"))
        XCTAssertTrue(output.contains("  DSP sample rate: 48000 Hz"))
        XCTAssertTrue(output.contains("  Output device UID: Unavailable"))
        XCTAssertTrue(output.contains("  Output device nominal rate: Unavailable"))
        XCTAssertTrue(output.contains("  Output device channels: Unavailable"))
        XCTAssertTrue(output.contains("  Rates differ: no"))
        XCTAssertTrue(output.contains("  Drift/resampling active: yes"))
        XCTAssertTrue(output.contains("  Unavailable: Unavailable"))
    }

    func testDecodingOldStatusPayloadLeavesRuntimeDiagnosticsNil() throws {
        let json = """
        {
          "bypassed": false,
          "activePresetID": "00000000-0000-0000-0000-000000000001",
          "activePresetName": "Flat",
          "inputGainDB": 0,
          "outputGainDB": 0,
          "balance": 0,
          "gainIsGlobal": true,
          "outputDeviceName": "MacBook Speakers",
          "isRunning": true,
          "peakLimiter": true,
          "preEqSpectrumEnabled": false,
          "postEqSpectrumEnabled": true,
          "appVersion": "0.59.0",
          "gitCommit": "abcdef0"
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(CLIStatusPayload.self, from: json)

        XCTAssertEqual(status.activePresetName, "Flat")
        XCTAssertNil(status.runtimeLifecycleState)
        XCTAssertNil(status.runtimeCaptureSampleRate)
        XCTAssertNil(status.runtimeCaptureChannelCount)
        XCTAssertNil(status.runtimeRenderSampleRate)
        XCTAssertNil(status.runtimeRenderChannelCount)
        XCTAssertNil(status.runtimeDSPSampleRate)
        XCTAssertNil(status.runtimeOutputDeviceUID)
        XCTAssertNil(status.runtimeOutputDeviceNominalSampleRate)
        XCTAssertNil(status.runtimeOutputDeviceChannelCount)
        XCTAssertNil(status.runtimeRatesDiffer)
        XCTAssertNil(status.runtimeResamplingActive)
        XCTAssertNil(status.runtimeUnavailableReason)
    }
}
