import XCTest
@testable import iQualize

/// Exercises BiquadFilterChain directly — the DSP path AudioEngine uses for
/// split-channel EQ, and for any bands beyond AVAudioUnitEQ's native capacity
/// in linked mode (see #114: there's no app-imposed band count limit).
final class BiquadFilterChainTests: XCTestCase {

    private func band(_ frequency: Float, gain: Float = 3.0) -> EQBand {
        EQBand(frequency: frequency, gain: gain, bandwidth: 1.0, filterType: .parametric)
    }

    /// AVAudioUnitEQ's native capacity is 31 bands; a chain well beyond that
    /// must still process a full buffer without crashing or producing
    /// non-finite output — this is the DSP layer's half of "no fixed limit."
    func testProcessesMoreBandsThanAVAudioUnitEQNativeCapacity() {
        let bandCount = 40
        let bands = (0..<bandCount).map { band(Float(40 + $0 * 400)) }
        let chain = BiquadFilterChain(bands: bands, sampleRate: 48000)

        var buffer = [Float](repeating: 0, count: 512)
        buffer[0] = 1.0 // impulse
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frameCount: ptr.count)
        }

        XCTAssertTrue(buffer.allSatisfy { $0.isFinite })
        XCTAssertTrue(buffer.contains { $0 != 0 })
    }

    /// updateCoefficients must resize its internal state when band count grows
    /// past the previous count, not just when it shrinks.
    func testUpdateCoefficientsGrowsPastPreviousCount() {
        let chain = BiquadFilterChain(bands: [band(1000)], sampleRate: 48000)
        let grown = (0..<35).map { band(Float(50 + $0 * 500)) }
        chain.updateCoefficients(bands: grown, sampleRate: 48000)

        var buffer = [Float](repeating: 0, count: 256)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frameCount: ptr.count)
        }

        XCTAssertTrue(buffer.allSatisfy { $0.isFinite })
    }

    func testCoefficientRampCompletesAfterConfiguredFrameCount() {
        let chain = BiquadFilterChain(bands: [band(1000, gain: 0)], sampleRate: 48000)
        chain.updateCoefficients(
            bands: [band(1000, gain: 12)],
            sampleRate: 48000
        )

        XCTAssertEqual(chain.rampStateForTesting().frames, BiquadFilterChain.coefficientRampFrames)
        XCTAssertEqual(chain.rampStateForTesting().position, 0)

        var buffer = [Float](repeating: 0, count: Int(BiquadFilterChain.coefficientRampFrames))
        buffer[0] = 1
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: pointer.count)
        }

        let ramp = chain.rampStateForTesting()
        XCTAssertEqual(ramp.position, BiquadFilterChain.coefficientRampFrames)
        XCTAssertEqual(ramp.frames, BiquadFilterChain.coefficientRampFrames)
        XCTAssertTrue(buffer.allSatisfy { $0.isFinite })
    }

    func testResetPublishesZeroStateWithoutDroppingFilterConfiguration() {
        let chain = BiquadFilterChain(bands: [band(1000, gain: 6)], sampleRate: 48000)
        var impulse = [Float](repeating: 0, count: 128)
        impulse[0] = 1
        impulse.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: pointer.count)
        }
        XCTAssertTrue(impulse.dropFirst().contains { $0 != 0 })

        chain.reset()

        XCTAssertEqual(chain.currentSnapshotCounts().bands, 1)
        let ramp = chain.rampStateForTesting()
        XCTAssertEqual(ramp.frames, 0)
        XCTAssertEqual(ramp.position, 0)

        var silence = [Float](repeating: 0, count: 128)
        silence.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: pointer.count)
        }
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }

    func testPresetResetStartsWithZeroStateWhileStillRampingCoefficients() {
        let chain = BiquadFilterChain(bands: [band(1000, gain: 0)], sampleRate: 48000)
        var impulse = [Float](repeating: 0, count: 128)
        impulse[0] = 1
        impulse.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: pointer.count)
        }

        chain.updateCoefficients(
            bands: [band(1000, gain: 12)],
            sampleRate: 48000,
            resetState: true
        )

        let ramp = chain.rampStateForTesting()
        XCTAssertEqual(ramp.frames, BiquadFilterChain.coefficientRampFrames)
        XCTAssertEqual(ramp.position, 0)

        var silence = [Float](repeating: 0, count: 128)
        silence.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: pointer.count)
        }
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }
}
