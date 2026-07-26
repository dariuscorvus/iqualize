import Foundation

/// Pure gain math for the render path. AudioEngine's main-thread setters call
/// these before writing the results into the rt* globals the render callback
/// reads; the unit tests call them directly.
enum GainPolicy {

    /// Compensation for the headroom attenuation Core Audio applies to stereo
    /// mixdown taps on multi-channel output devices: the tap scales the mix by
    /// 1/(stereo pairs), so 2ch plays at 0 dB but 4ch at -6 dB, 6ch at -9.5 dB,
    /// 8ch at -12 dB (#107, Apple Developer Forums thread 806799). Multiplying
    /// by the pair count restores unity. 1.0 on stereo and mono devices. Odd
    /// channel counts floor to the nearest full pair — the attenuation is only
    /// documented for even counts.
    static func tapHeadroomCompensation(outputChannels: Int) -> Float {
        Float(max(1, outputChannels / 2))
    }

    /// Input gain as a linear factor. Unity while bypassed — Bypass is a true
    /// passthrough (#118).
    static func inputGain(dB: Float, bypassed: Bool) -> Float {
        bypassed ? 1.0 : powf(10, dB / 20)
    }

    /// Per-channel balance factors. -1 = full left, 0 = center, +1 = full
    /// right; panning attenuates the opposite channel. Neutral while bypassed
    /// (#118).
    static func balanceGains(_ balance: Float, bypassed: Bool) -> (left: Float, right: Float) {
        if bypassed { return (1.0, 1.0) }
        return (balance <= 0 ? 1.0 : 1.0 - balance,
                balance >= 0 ? 1.0 : 1.0 + balance)
    }

    /// Output gain in dB for the output-gain EQ node. 0 dB while bypassed
    /// (#118).
    static func outputGainDB(_ dB: Float, bypassed: Bool) -> Float {
        bypassed ? 0 : dB
    }
}
