import XCTest
@testable import iQualize

/// Exercises deinterleaveChannel — the render callback's per-sample math —
/// with synthetic buffers, so the production DSP path is tested without an
/// audio device.
final class RenderMathTests: XCTestCase {

    /// Interleaved stereo: L = 0.1, 0.2, 0.3; R = -0.1, -0.2, -0.3.
    private let stereoInput: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]

    private func extract(channel: Int, channelCount: Int, from input: [Float],
                         frames: Int, gain: Float) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                deinterleaveChannel(inPtr.baseAddress!, into: outPtr.baseAddress!,
                                    channel: channel, channelCount: channelCount,
                                    frames: frames, gain: gain)
            }
        }
        return output
    }

    func testDeinterleavesStereo() {
        XCTAssertEqual(extract(channel: 0, channelCount: 2, from: stereoInput, frames: 3, gain: 1.0),
                       [0.1, 0.2, 0.3])
        XCTAssertEqual(extract(channel: 1, channelCount: 2, from: stereoInput, frames: 3, gain: 1.0),
                       [-0.1, -0.2, -0.3])
    }

    func testAppliesGain() {
        let expected = [Float]([0.1, 0.2, 0.3]).map { $0 * 0.5 }
        XCTAssertEqual(extract(channel: 0, channelCount: 2, from: stereoInput, frames: 3, gain: 0.5),
                       expected)
    }

    func testBypassOnSixChannelDeviceTriplesTheTappedSignal() {
        // End-to-end gain a bypassed engine applies on a 6ch device: input
        // gain and balance neutralized (#118), compensation x3 (#107). Output
        // must be exactly input x3 — cancelling the tap's 1/3 attenuation.
        let gain = GainPolicy.inputGain(dB: -5, bypassed: true)
            * GainPolicy.balanceGains(0.25, bypassed: true).left
            * GainPolicy.tapHeadroomCompensation(outputChannels: 6)
        let expected = [Float]([0.1, 0.2, 0.3]).map { $0 * 3.0 }
        XCTAssertEqual(extract(channel: 0, channelCount: 2, from: stereoInput, frames: 3, gain: gain),
                       expected)
    }
}
