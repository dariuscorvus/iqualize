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
}
