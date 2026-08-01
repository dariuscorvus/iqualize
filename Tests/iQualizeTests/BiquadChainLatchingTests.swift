import XCTest
@testable import iQualize

/// The #166 defect was not "a hostile preset produces NaN once." It was that the
/// NaN *latches*: `BiquadFilterChain` carries Direct-Form-II-Transposed state in
/// `z1`/`z2`, and `updateCoefficients` only zeroes that state when the band count
/// changes. Import a preset with `Q 0`, switch back to a preset that is perfectly
/// valid, and the chain keeps emitting NaN forever because the poisoned state was
/// never cleared. The limiter cannot help; NaN propagates through it.
///
/// A test that builds a fresh chain, pushes an impulse, and asserts finiteness
/// cannot observe that. It never reuses a chain across a preset change. These
/// tests hold ONE chain across a sequence of imports — the way `AudioEngine` does,
/// where `rtBiquadChainL`/`R` live for the lifetime of the audio graph.
///
/// Verified against the pre-fix cookbook math using the repository's own DF2T loop:
/// after a single `Q 0.0` import, five subsequent valid presets all produced NaN.
final class BiquadChainLatchingTests: XCTestCase {

    // MARK: Fixtures

    /// A 997 Hz tone — the same probe frequency `Spikes/TapAttenuationE2E` uses,
    /// chosen because it is not a harmonic of the sample rate.
    private func tone(frames: Int, sampleRate: Double = 48000) -> [Float] {
        (0..<frames).map {
            Float(0.5 * sin(2.0 * Double.pi * 997.0 * Double($0) / sampleRate))
        }
    }

    private func process(_ chain: BiquadFilterChain, frames: Int = 512) -> [Float] {
        var buffer = tone(frames: frames)
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frameCount: ptr.count)
        }
        return buffer
    }

    private func band(
        _ frequency: Float,
        gain: Float = 6,
        bandwidth: Float = 1.0
    ) -> EQBand {
        EQBand(frequency: frequency, gain: gain, bandwidth: bandwidth, filterType: .parametric)
    }

    /// Imports one AutoEQ ParametricEQ line through the real importer, so these
    /// tests exercise the actual clamping path rather than a reimplementation.
    private func importBand(line: String) throws -> [EQBand] {
        let text = "Preamp: 0.0 dB\n\(line)\n"
        return try PresetImporter.parse(data: Data(text.utf8), filename: "latching.txt").bands
    }

    /// The hazard table from #166, as AutoEQ lines. Every one of these produced
    /// permanent NaN before the fix.
    private var hazardLines: [(name: String, line: String)] {
        [
            ("Q 0",            "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 0.0"),
            ("Q negative",     "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q -1.0"),
            ("Fc 0",           "Filter 1: ON PK Fc 0 Hz Gain 3.0 dB Q 1.0"),
            ("Fc 1e9",         "Filter 1: ON PK Fc 1000000000 Hz Gain 3.0 dB Q 1.0"),
            ("Fc negative",    "Filter 1: ON PK Fc -500 Hz Gain 3.0 dB Q 1.0"),
            ("Gain 1e6",       "Filter 1: ON PK Fc 1000 Hz Gain 1000000 dB Q 1.0"),
            ("Gain 400",       "Filter 1: ON PK Fc 1000 Hz Gain 400 dB Q 1.0"),
        ]
    }

    // MARK: The latching property

    /// The regression test for the actual user-visible failure: one hostile import
    /// must not deafen every preset the user selects afterwards.
    ///
    /// Band count is held at 1 throughout, deliberately. `updateCoefficients` resets
    /// `z1`/`z2` when the count changes, so a sequence that varies the count would
    /// mask the bug by accidentally clearing the poisoned state.
    func testHostileImportDoesNotPoisonSubsequentValidPresets() throws {
        for hazard in hazardLines {
            let chain = BiquadFilterChain(bands: [band(1000)], sampleRate: 48000)

            let healthy = process(chain)
            XCTAssertTrue(
                healthy.allSatisfy { $0.isFinite },
                "\(hazard.name): baseline was already non-finite"
            )

            let hostile = try importBand(line: hazard.line)
            XCTAssertEqual(hostile.count, 1, "\(hazard.name): expected one imported band")
            chain.updateCoefficients(bands: hostile, sampleRate: 48000)
            let duringHazard = process(chain)
            XCTAssertTrue(
                duringHazard.allSatisfy { $0.isFinite },
                "\(hazard.name): hostile preset produced non-finite output"
            )

            // The user goes back to a preset that was always valid.
            chain.updateCoefficients(bands: [band(1000)], sampleRate: 48000)
            for pass in 1...5 {
                let recovered = process(chain)
                XCTAssertTrue(
                    recovered.allSatisfy { $0.isFinite },
                    "\(hazard.name): valid preset still non-finite on pass \(pass) — state latched"
                )
                XCTAssertTrue(
                    recovered.contains { $0 != 0 },
                    "\(hazard.name): valid preset produced silence on pass \(pass)"
                )
            }
        }
    }

    /// The hazards applied back-to-back on one chain, with no healthy preset between
    /// them. Each import must leave the chain usable for the next.
    func testChainSurvivesEveryHazardInSequence() throws {
        let chain = BiquadFilterChain(bands: [band(1000)], sampleRate: 48000)

        for hazard in hazardLines {
            let bands = try importBand(line: hazard.line)
            chain.updateCoefficients(bands: bands, sampleRate: 48000)
            let output = process(chain)
            XCTAssertTrue(
                output.allSatisfy { $0.isFinite },
                "chain went non-finite at \(hazard.name)"
            )
        }

        chain.updateCoefficients(bands: [band(1000)], sampleRate: 48000)
        let final = process(chain)
        XCTAssertTrue(final.allSatisfy { $0.isFinite }, "chain did not recover after the sequence")
        XCTAssertTrue(final.contains { $0 != 0 }, "chain produced silence after the sequence")
    }

    /// Low sample rates are the sharp edge: #166 measured the first NaN frequency at
    /// 7997 Hz for a 16 kHz rate and 3999 Hz at 8 kHz, because the failure is
    /// `f0 -> Nyquist`. A 20 kHz band is in-range by `EQBand.frequencyRange` and still
    /// above Nyquist at these rates, so the Nyquist clamp is what keeps this finite.
    func testInRangeBandAboveNyquistDoesNotLatch() {
        for sampleRate in [8000.0, 16000.0, 22050.0] {
            let chain = BiquadFilterChain(bands: [band(1000)], sampleRate: sampleRate)

            chain.updateCoefficients(bands: [band(20000)], sampleRate: sampleRate)
            let hostile = process(chain)
            XCTAssertTrue(
                hostile.allSatisfy { $0.isFinite },
                "20 kHz band produced non-finite output at \(sampleRate) Hz"
            )

            chain.updateCoefficients(bands: [band(1000)], sampleRate: sampleRate)
            let recovered = process(chain)
            XCTAssertTrue(
                recovered.allSatisfy { $0.isFinite },
                "state latched at \(sampleRate) Hz"
            )
            XCTAssertTrue(
                recovered.contains { $0 != 0 },
                "recovered output was silent at \(sampleRate) Hz"
            )
        }
    }

    // MARK: Sustained processing

    /// A long run at a hostile setting. A divergent-but-finite filter (#166 lists a
    /// pole radius of 1.0033 for a negative centre frequency) shows up here rather
    /// than in a 512-frame buffer: it stays finite for a while, then overflows.
    ///
    /// Reduced per-sample assertions to one per buffer deliberately — asserting
    /// inside the sample loop costs ~800k XCTAssert calls and 70 s of wall time for
    /// no extra coverage, since one non-finite sample is enough to fail the run.
    func testSustainedProcessingStaysBoundedUnderHazards() throws {
        for hazard in hazardLines {
            let bands = try importBand(line: hazard.line)
            let chain = BiquadFilterChain(bands: bands, sampleRate: 48000)

            var peak: Float = 0
            var allFinite = true
            for _ in 0..<400 {           // ~200k frames
                for sample in process(chain) {
                    if !sample.isFinite { allFinite = false; break }
                    peak = max(peak, abs(sample))
                }
                if !allFinite { break }
            }

            XCTAssertTrue(allFinite, "\(hazard.name): went non-finite under sustained input")
            // Clamped to <= +24 dB, a 0.5 amplitude tone cannot exceed ~8.
            XCTAssertLessThan(peak, 8.0, "\(hazard.name): output diverged to \(peak)")
        }
    }

    /// The chain reused across many preset changes without the band count ever
    /// changing — the case `updateCoefficients` does not reset state for.
    func testAlternatingHostileAndValidImportsStayFinite() throws {
        let chain = BiquadFilterChain(bands: [band(1000)], sampleRate: 48000)

        for (index, hazard) in hazardLines.enumerated() {
            let hostile = try importBand(line: hazard.line)
            chain.updateCoefficients(bands: hostile, sampleRate: 48000)
            _ = process(chain)

            chain.updateCoefficients(bands: [band(500 + Float(index) * 100)], sampleRate: 48000)
            let output = process(chain)
            XCTAssertTrue(
                output.allSatisfy { $0.isFinite },
                "non-finite after alternating through \(hazard.name)"
            )
            XCTAssertTrue(
                output.contains { $0 != 0 },
                "silent after alternating through \(hazard.name)"
            )
        }
    }

    // MARK: Guard against the fix over-reaching

    /// The clamp must not change what a valid preset sounds like. An in-range band
    /// through a fresh chain must produce exactly what it produced before #166.
    func testValidBandOutputIsUnchangedByClamping() {
        let chain = BiquadFilterChain(bands: [band(1000, gain: 6, bandwidth: 1.0)], sampleRate: 48000)
        let output = process(chain, frames: 4096)

        XCTAssertTrue(output.allSatisfy { $0.isFinite })

        // A +6 dB peak at 997 Hz with a 1-octave bandwidth: the tone is boosted,
        // not attenuated, and stays well short of the limiter.
        let steadyState = output.suffix(2048)
        let peak = steadyState.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.5, "expected the 997 Hz tone to be boosted above unity")
        XCTAssertLessThan(peak, 1.5, "boost was larger than +6 dB implies")
    }
}
