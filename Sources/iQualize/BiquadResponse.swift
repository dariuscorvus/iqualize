import Foundation

// MARK: - Biquad Coefficients

struct BiquadCoefficients: Sendable {
    let b0: Double, b1: Double, b2: Double
    let a0: Double, a1: Double, a2: Double
}

// MARK: - Biquad Response Computation

enum BiquadResponse {

    /// Compute biquad coefficients for a band using Audio EQ Cookbook formulas.
    static func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        let f0 = Double(band.frequency)
        let gain = Double(band.gain)
        let bw = Double(max(band.bandwidth, 0.05))

        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        // Bandwidth (octaves) → Q conversion
        let sinW0Safe = abs(sinW0) > 1e-10 ? sinW0 : 1e-10
        let Q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0Safe))

        let alpha = sinW0 / (2.0 * Q)

        switch band.filterType {
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
