import XCTest
@testable import iQualize

/// #166 — `BiquadResponse.coefficients` must never hand the DSP a non-finite
/// coefficient, and must not change what it produces for in-range input.
final class BiquadResponseTests: XCTestCase {

    private func band(_ frequency: Float, _ gain: Float, _ bandwidth: Float,
                      _ type: FilterType = .parametric) -> EQBand {
        EQBand(frequency: frequency, gain: gain, bandwidth: bandwidth, filterType: type)
    }

    private func assertCoeffs(_ c: BiquadCoefficients,
                              _ expected: [Double],
                              _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = [c.b0, c.b1, c.b2, c.a0, c.a1, c.a2]
        for (i, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a, e, accuracy: 1e-12,
                           "\(label) coefficient \(i): \(a) != \(e)", file: file, line: line)
        }
    }

    // MARK: Audio EQ Cookbook reference values

    /// Reference values computed independently from Robert Bristow-Johnson's
    /// Audio EQ Cookbook formulas at f0 = 1 kHz, BW = 1 octave, gain = +6 dB,
    /// fs = 48 kHz. These pin the formulas so the #166 guard cannot silently
    /// alter them.
    func testMatchesCookbookReferenceValues() {
        let f: Float = 1000, g: Float = 6, bw: Float = 1.0, fs = 48000.0

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .parametric), sampleRate: fs),
                     [1.06537972198056, -1.98288972274762, 0.934620278019442,
                      1.03276748199476, -1.98288972274762, 0.967232518005244], "parametric")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .lowShelf), sampleRate: fs),
                     [2.98546827084295, -5.59184177807279, 2.67465249003052,
                      2.93156613423586, -5.60887099222075, 2.71152541248964], "lowShelf")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .highShelf), sampleRate: fs),
                     [4.14094722915275, -7.92274085945729, 3.83013144834032,
                      2.11354967675587, -3.95872081372973, 1.89350895500965], "highShelf")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .lowPass), sampleRate: fs),
                     [0.00427756931309481, 0.00855513862618962, 0.00427756931309481,
                      1.04628529856034, -1.98288972274762, 0.953714701439657], "lowPass")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .highPass), sampleRate: fs),
                     [0.995722430686905, -1.99144486137381, 0.995722430686905,
                      1.04628529856034, -1.98288972274762, 0.953714701439657], "highPass")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .bandPass), sampleRate: fs),
                     [0.0462852985603429, 0, -0.0462852985603429,
                      1.04628529856034, -1.98288972274762, 0.953714701439657], "bandPass")

        assertCoeffs(BiquadResponse.coefficients(for: band(f, g, bw, .notch), sampleRate: fs),
                     [1, -1.98288972274762, 1,
                      1.04628529856034, -1.98288972274762, 0.953714701439657], "notch")
    }

    // MARK: In-range grid

    /// Every in-range parameter combination must give finite coefficients with a
    /// stable pole radius, at every sample rate the app runs at.
    func testInRangeGridIsFiniteAndStable() {
        let frequencies: [Float] = [20, 50, 120, 400, 1000, 3150, 8000, 14000, 20000]
        let gains: [Float] = [-24, -12, -3, 0, 3, 12, 24]
        let bandwidths: [Float] = [0.05, 0.25, 1.0, 3.0, 8.0]

        for fs in [44100.0, 48000.0, 96000.0] {
            for type in FilterType.allCases {
                for f in frequencies where Double(f) < fs / 2 {
                    for g in gains {
                        for bw in bandwidths {
                            let c = BiquadResponse.coefficients(for: band(f, g, bw, type), sampleRate: fs)
                            let all = [c.b0, c.b1, c.b2, c.a0, c.a1, c.a2]
                            XCTAssertTrue(all.allSatisfy { $0.isFinite },
                                          "non-finite: \(type) f=\(f) g=\(g) bw=\(bw) fs=\(fs)")
                            XCTAssertTrue(poleRadius(c) < 1.0,
                                          "unstable pole: \(type) f=\(f) g=\(g) bw=\(bw) fs=\(fs) r=\(poleRadius(c))")
                        }
                    }
                }
            }
        }
    }

    /// Largest magnitude of the two poles of a0 z^2 + a1 z + a2.
    private func poleRadius(_ c: BiquadCoefficients) -> Double {
        let a1 = c.a1 / c.a0, a2 = c.a2 / c.a0
        let disc = a1 * a1 - 4 * a2
        if disc >= 0 {
            let r1 = (-a1 + disc.squareRoot()) / 2
            let r2 = (-a1 - disc.squareRoot()) / 2
            return max(abs(r1), abs(r2))
        }
        // Complex conjugate pair: |root| = sqrt(a2).
        return abs(a2).squareRoot()
    }

    // MARK: Hostile inputs

    /// Every hazard-table entry from #166, plus the NaN cases. None may produce
    /// a non-finite coefficient.
    func testHostileInputsNeverProduceNonFiniteCoefficients() {
        var cases: [(String, EQBand, Double)] = [
            ("q=0 → bandwidth +Inf", band(1000, 3, .infinity), 48000),
            ("bandwidth NaN", band(1000, 3, .nan), 48000),
            ("bandwidth -Inf", band(1000, 3, -.infinity), 48000),
            ("bandwidth 0", band(1000, 3, 0), 48000),
            ("frequency 1e9", band(1e9, 3, 1.0), 48000),
            ("frequency ≥ Nyquist @16k", band(8000, 3, 1.0), 16000),
            ("frequency just under Nyquist @16k", band(7997, 3, 1.0), 16000),
            ("frequency ≥ Nyquist @8k", band(3999, 3, 1.0), 8000),
            ("frequency NaN", band(.nan, 3, 1.0), 48000),
            ("frequency -500", band(-500, 3, 1.0), 48000),
            ("frequency 0", band(0, 3, 1.0), 48000),
            ("gain 1e6 dB", band(1000, 1e6, 1.0), 48000),
            ("gain 400 dB", band(1000, 400, 1.0), 48000),
            ("gain NaN", band(1000, .nan, 1.0), 48000),
            ("gain -Inf", band(1000, -.infinity, 1.0), 48000),
            ("everything hostile", band(.infinity, .infinity, .infinity), 48000),
        ]
        cases += FilterType.allCases.map {
            ("all-hostile \($0)", EQBand(frequency: .nan, gain: .infinity, bandwidth: .nan, filterType: $0), 48000)
        }

        for (label, b, fs) in cases {
            let c = BiquadResponse.coefficients(for: b, sampleRate: fs)
            let all = [c.b0, c.b1, c.b2, c.a0, c.a1, c.a2]
            XCTAssertTrue(all.allSatisfy { $0.isFinite }, "non-finite coefficients for \(label): \(all)")
            XCTAssertNotEqual(c.a0, 0, "a0 == 0 for \(label)")

            let n = NormalizedBiquadCoeffs(from: c)
            XCTAssertTrue([n.b0, n.b1, n.b2, n.a1, n.a2].allSatisfy { $0.isFinite },
                          "non-finite normalized coefficients for \(label)")
        }
    }

    /// A non-finite band falls all the way back to passthrough, not to some
    /// arbitrary surviving filter.
    func testNonFiniteBandFallsBackToPassthrough() {
        let c = BiquadResponse.coefficients(for: band(.nan, .nan, .nan), sampleRate: 48000)
        let n = NormalizedBiquadCoeffs(from: c)
        XCTAssertEqual(n.b0, NormalizedBiquadCoeffs.passthrough.b0)
        XCTAssertEqual(n.b1, NormalizedBiquadCoeffs.passthrough.b1)
        XCTAssertEqual(n.b2, NormalizedBiquadCoeffs.passthrough.b2)
        XCTAssertEqual(n.a1, NormalizedBiquadCoeffs.passthrough.a1)
        XCTAssertEqual(n.a2, NormalizedBiquadCoeffs.passthrough.a2)
    }

    /// A frequency at or above Nyquist is clamped below it, not passed through —
    /// the resulting filter is still a real filter, not passthrough.
    func testFrequencyAtOrAboveNyquistIsClamped() {
        for fs in [8000.0, 16000.0, 44100.0, 48000.0] {
            for f in [Float(fs / 2), Float(fs), Float(fs * 10)] {
                let c = BiquadResponse.coefficients(for: band(f, 6, 1.0, .parametric), sampleRate: fs)
                XCTAssertTrue([c.b0, c.b1, c.b2, c.a0, c.a1, c.a2].allSatisfy { $0.isFinite },
                              "non-finite at f=\(f) fs=\(fs)")
                XCTAssertTrue(poleRadius(c) < 1.0, "unstable at f=\(f) fs=\(fs)")
            }
        }
    }

    // MARK: Impulse sweep through the chain

    /// 200k samples through `BiquadFilterChain` for every hazard case: a NaN in
    /// the DF2T state latches forever, so a long sweep is the only honest check.
    func testImpulseSweepStaysFiniteForEveryHazardCase() {
        let hazards: [(String, EQBand, Double)] = [
            ("normal", band(1000, 6, 1.0), 48000),
            ("q=0 → +Inf bandwidth", band(1000, 3, .infinity), 48000),
            ("frequency 1e9", band(1e9, 3, 1.0), 48000),
            ("frequency ≥ Nyquist @16k", band(8000, 3, 1.0), 16000),
            ("frequency ≥ Nyquist @8k", band(3999, 3, 1.0), 8000),
            ("gain 1e6 dB", band(1000, 1e6, 1.0), 48000),
            ("gain 400 dB", band(1000, 400, 1.0), 48000),
            ("frequency -500", band(-500, 3, 1.0), 48000),
            ("all NaN", band(.nan, .nan, .nan), 48000),
        ]

        for (label, b, fs) in hazards {
            let chain = BiquadFilterChain(bands: [b], sampleRate: fs)
            var buffer = [Float](repeating: 0, count: 200_000)
            buffer[0] = 1.0
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frameCount: ptr.count)
            }
            XCTAssertTrue(buffer.allSatisfy { $0.isFinite }, "non-finite output for \(label)")
            // The tail must have decayed — a divergent filter fails this even
            // while staying finite over 200k samples.
            XCTAssertLessThan(abs(buffer[199_999]), 1.0, "divergent tail for \(label)")
        }
    }

    /// The normal case still behaves like a filter: it rings and settles.
    func testNormalCaseImpulseResponseSettles() {
        let chain = BiquadFilterChain(bands: [band(1000, 6, 1.0)], sampleRate: 48000)
        var buffer = [Float](repeating: 0, count: 200_000)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frameCount: ptr.count)
        }
        XCTAssertEqual(Double(buffer[0]), 1.06537972198056 / 1.03276748199476, accuracy: 1e-6)
        XCTAssertLessThan(abs(buffer[199_999]), 1e-6)
    }
}
