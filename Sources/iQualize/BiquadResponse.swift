import Foundation

// MARK: - Biquad Coefficients

struct BiquadCoefficients: Sendable {
    let b0: Double, b1: Double, b2: Double
    let a0: Double, a1: Double, a2: Double

    /// Unity gain. Normalizes to `NormalizedBiquadCoeffs.passthrough`, and is what
    /// `BiquadResponse.coefficients` falls back to rather than publishing a
    /// non-finite coefficient into the filter state (#166).
    static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)
}

// MARK: - Biquad Response Computation

enum BiquadResponse {

    /// Highest fraction of Nyquist a band center is allowed to reach. As `f0 → Nyquist`,
    /// `sin(w0) → 0`, the octaves→Q conversion's `sinh` argument overflows, `Q → 0`, and
    /// `alpha = sin(w0) / 2Q` evaluates to `0/0 = NaN` (#166). At 8 octaves — the widest
    /// bandwidth the app allows — the overflow starts within 0.4% of Nyquist; 0.98 keeps
    /// a wide margin and is above 20 kHz at every sample rate from 44.1 kHz up, so it
    /// never touches an in-range band at a normal rate.
    private static let maxNyquistFraction = 0.98

    /// Compute biquad coefficients for a band using Audio EQ Cookbook formulas.
    ///
    /// Defense in depth behind `PresetImporter`'s clamp. A band with a non-finite
    /// parameter carries no usable intent and becomes `passthrough`; a finite but
    /// out-of-range one is clamped, including against Nyquist for this sample rate. The
    /// result is checked once more before it is returned, because a NaN reaching
    /// `BiquadFilterChain` latches in its Direct-Form-II-Transposed state forever (#166).
    static func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate.isFinite, sampleRate > 0,
              band.frequency.isFinite, band.gain.isFinite, band.bandwidth.isFinite
        else { return .passthrough }

        let gain = Double(band.gain.clamped(to: EQBand.gainRange))
        let bw = Double(band.bandwidth.clamped(to: EQBand.bandwidthRange))
        let f0 = min(Double(band.frequency.clamped(to: EQBand.frequencyRange)),
                     maxNyquistFraction * sampleRate / 2)

        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        // Bandwidth (octaves) → Q conversion
        let sinW0Safe = abs(sinW0) > 1e-10 ? sinW0 : 1e-10
        let Q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0Safe))

        let alpha = sinW0 / (2.0 * Q)

        return finiteOrPassthrough(cookbook(band.filterType, gain: gain, cosW0: cosW0, alpha: alpha))
    }

    /// Rejects anything the DSP must never see: a non-finite coefficient, or an `a0` of
    /// zero, which normalization would turn into one.
    private static func finiteOrPassthrough(_ c: BiquadCoefficients) -> BiquadCoefficients {
        let all = [c.b0, c.b1, c.b2, c.a0, c.a1, c.a2]
        guard all.allSatisfy({ $0.isFinite }), c.a0 != 0 else { return .passthrough }
        return c
    }

    private static func cookbook(_ filterType: FilterType, gain: Double,
                                 cosW0: Double, alpha: Double) -> BiquadCoefficients {
        switch filterType {
        case .parametric:
            let A = pow(10.0, gain / 40.0)
            return BiquadCoefficients(
                b0: 1.0 + alpha * A,
                b1: -2.0 * cosW0,
                b2: 1.0 - alpha * A,
                a0: 1.0 + alpha / A,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha / A
            )

        case .lowShelf:
            let A = pow(10.0, gain / 40.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            return BiquadCoefficients(
                b0: A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha),
                b1: 2.0 * A * ((A - 1) - (A + 1) * cosW0),
                b2: A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha),
                a0: (A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha,
                a1: -2.0 * ((A - 1) + (A + 1) * cosW0),
                a2: (A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha
            )

        case .highShelf:
            let A = pow(10.0, gain / 40.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            return BiquadCoefficients(
                b0: A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha),
                b1: -2.0 * A * ((A - 1) + (A + 1) * cosW0),
                b2: A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha),
                a0: (A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha,
                a1: 2.0 * ((A - 1) - (A + 1) * cosW0),
                a2: (A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha
            )

        case .lowPass:
            return BiquadCoefficients(
                b0: (1.0 - cosW0) / 2.0,
                b1: 1.0 - cosW0,
                b2: (1.0 - cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .highPass:
            return BiquadCoefficients(
                b0: (1.0 + cosW0) / 2.0,
                b1: -(1.0 + cosW0),
                b2: (1.0 + cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .bandPass:
            return BiquadCoefficients(
                b0: alpha,
                b1: 0.0,
                b2: -alpha,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .notch:
            return BiquadCoefficients(
                b0: 1.0,
                b1: -2.0 * cosW0,
                b2: 1.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        }
    }
}
