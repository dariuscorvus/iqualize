import XCTest
@testable import iQualize

final class GainPolicyTests: XCTestCase {

    // MARK: - Tap headroom compensation (#107)

    func testCompensationMatchesStereoPairCount() {
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 2), 1.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 4), 2.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 6), 3.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 8), 4.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 16), 8.0)
    }

    func testCompensationNeverDropsBelowUnity() {
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 0), 1.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 1), 1.0)
    }

    func testCompensationFloorsOddChannelCounts() {
        // The attenuation is only documented for even channel counts (Apple
        // Developer Forums thread 806799) — floor to the nearest full pair.
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 3), 1.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 5), 2.0)
        XCTAssertEqual(GainPolicy.tapHeadroomCompensation(outputChannels: 7), 3.0)
    }

    // MARK: - Input gain (#118)

    func testInputGainConvertsDecibels() {
        XCTAssertEqual(GainPolicy.inputGain(dB: 0, bypassed: false), 1.0)
        XCTAssertEqual(GainPolicy.inputGain(dB: -6, bypassed: false), 0.5012, accuracy: 0.001)
        XCTAssertEqual(GainPolicy.inputGain(dB: 6, bypassed: false), 1.9953, accuracy: 0.001)
        XCTAssertEqual(GainPolicy.inputGain(dB: 20, bypassed: false), 10.0, accuracy: 0.0001)
    }

    func testBypassNeutralizesInputGain() {
        // The #107 report: a preset with negative input gain kept attenuating
        // in Bypass. Bypass must force unity no matter the stored value.
        XCTAssertEqual(GainPolicy.inputGain(dB: -5, bypassed: true), 1.0)
        XCTAssertEqual(GainPolicy.inputGain(dB: 12, bypassed: true), 1.0)
    }

    // MARK: - Balance (#118)

    func testBalanceCenterIsUnity() {
        let g = GainPolicy.balanceGains(0, bypassed: false)
        XCTAssertEqual(g.left, 1.0)
        XCTAssertEqual(g.right, 1.0)
    }

    func testBalancePansByAttenuatingOppositeChannel() {
        let halfRight = GainPolicy.balanceGains(0.5, bypassed: false)
        XCTAssertEqual(halfRight.left, 0.5)
        XCTAssertEqual(halfRight.right, 1.0)

        let halfLeft = GainPolicy.balanceGains(-0.5, bypassed: false)
        XCTAssertEqual(halfLeft.left, 1.0)
        XCTAssertEqual(halfLeft.right, 0.5)

        let fullRight = GainPolicy.balanceGains(1, bypassed: false)
        XCTAssertEqual(fullRight.left, 0.0)
        XCTAssertEqual(fullRight.right, 1.0)

        let fullLeft = GainPolicy.balanceGains(-1, bypassed: false)
        XCTAssertEqual(fullLeft.left, 1.0)
        XCTAssertEqual(fullLeft.right, 0.0)
    }

    func testBypassNeutralizesBalance() {
        let g = GainPolicy.balanceGains(1, bypassed: true)
        XCTAssertEqual(g.left, 1.0)
        XCTAssertEqual(g.right, 1.0)
    }

    // MARK: - Output gain (#118)

    func testOutputGainPassesThroughWhenActive() {
        XCTAssertEqual(GainPolicy.outputGainDB(-5, bypassed: false), -5)
        XCTAssertEqual(GainPolicy.outputGainDB(3, bypassed: false), 3)
    }

    func testBypassNeutralizesOutputGain() {
        XCTAssertEqual(GainPolicy.outputGainDB(-5, bypassed: true), 0)
        XCTAssertEqual(GainPolicy.outputGainDB(3, bypassed: true), 0)
    }

    // MARK: - The #107 invariant

    func testBypassDoesNotNeutralizeCompensation() {
        // Bypass must sound like the app is off. The tap attenuates regardless
        // of Bypass, so compensation stays in the render path: with every user
        // gain neutralized, the channel gain is exactly the compensation
        // factor. Anyone folding compensation into the bypass neutralization
        // reintroduces the multi-channel volume drop and breaks this test.
        let comp = GainPolicy.tapHeadroomCompensation(outputChannels: 6)
        let input = GainPolicy.inputGain(dB: -5, bypassed: true)
        let balance = GainPolicy.balanceGains(0.7, bypassed: true)
        XCTAssertEqual(input * balance.left * comp, 3.0)
        XCTAssertEqual(input * balance.right * comp, 3.0)
    }
}
