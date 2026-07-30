import Foundation

/// Pure math for the capture-ring drift compensator (#133). The capture
/// helper fills the ring on the tap aggregate's clock; the render callback
/// drains it on the output device's clock. The clocks are unlocked, so the
/// reader resamples by a ratio a hair off 1.0 to hold the ring's fill level
/// at a fixed target — CaptureClient owns the state (positions, EMA,
/// counters); everything computable lives here so the unit tests exercise
/// the exact production math without an audio device.
enum DriftPolicy {

    /// Fill-smoothing time constant. Instantaneous fill sawtooths by a full
    /// writer IO block (≤1024 frames) at the IO cycle rate; 0.5 s attenuates
    /// that ripple by >30 dB so the controller sees the mean, while real
    /// drift (which changes over minutes) passes through.
    static let emaTauSeconds: Double = 0.5

    /// Fill-error decay time constant of the P-controller. With
    /// ratio − 1 = error/(τ·sr), fill error decays exponentially with τ = 3 s
    /// — at least 6× the EMA τ, so the cascaded loop cannot oscillate. Pure P
    /// leaves a steady-state error of drift·τ·sr (14 frames at 100 ppm):
    /// acceptable, and an integrator would add windup for nothing.
    static let controllerTauSeconds: Double = 3.0

    /// Resample-ratio clamp. ±500 ppm is 0.87 cent of pitch — far below
    /// audibility — and covers real consumer clock mismatch (typically
    /// <200 ppm) 2.5× over. Large fill errors are removed by re-seeding, not
    /// by the ratio, so the clamp only ever handles genuine drift.
    static let maxCorrection: Double = 500e-6

    /// Source frames the interpolator needs beyond the integer read position:
    /// Catmull-Rom takes one frame behind and two ahead.
    static let windowMarginFrames = 3

    /// Fill target the controller holds, and therefore the capture path's
    /// pinned latency: ~40 ms, floored at 2048 frames, capped at a quarter of
    /// the ring. 2048 at 48 kHz clears the writer's block (≤1024) plus the
    /// reader's slice (512) plus scheduling jitter with ~4× margin — so an
    /// underrun means the writer actually stalled, never tight timing — and
    /// leaves ~300 ms of overrun headroom. Before #133 the operating point
    /// was wherever the start() race left it, anywhere in 0–341 ms.
    static func targetFillFrames(sampleRate: Double, capacityFrames: Int) -> Int {
        min(capacityFrames / 4, max(2048, Int(sampleRate * 0.04)))
    }

    /// Fill level that triggers a re-seed instead of resampling. Instantaneous
    /// fill legitimately spikes one writer block above target; 3× target is
    /// unreachable except by a real reader stall, and splicing out that much
    /// backlog at 500 ppm would take minutes — jumping is the right recovery.
    /// Capped clear of capacity so the re-seed lands well before writer wrap.
    static func overrunThresholdFrames(targetFill: Int, capacityFrames: Int) -> Int {
        min(3 * targetFill, capacityFrames - capacityFrames / 8)
    }

    /// EMA coefficient for a callback of `frames` frames: 1 − exp(−n/(τ·sr)),
    /// so the time constant stays emaTauSeconds regardless of slice size.
    static func emaAlpha(frames: Int, sampleRate: Double) -> Double {
        1.0 - exp(-Double(frames) / (emaTauSeconds * sampleRate))
    }

    /// Resample ratio (source frames consumed per output frame):
    /// 1 + clamp((fillEMA − target)/(τ·sr), ±maxCorrection). Above target →
    /// ratio > 1, consume faster, fill falls.
    static func resampleRatio(fillEMA: Double, targetFill: Double, sampleRate: Double) -> Double {
        let correction = (fillEMA - targetFill) / (controllerTauSeconds * sampleRate)
        return 1.0 + min(max(correction, -maxCorrection), maxCorrection)
    }

    /// Absolute source frame to (re)seed the read position at: exactly
    /// targetFill behind the writer.
    static func seedPosition(writeFrames: UInt64, targetFill: Int) -> UInt64 {
        writeFrames &- UInt64(targetFill)
    }

    /// 4-point Catmull-Rom interpolation at fraction t ∈ [0, 1) between x0
    /// and x1, Horner form. Bit-exact passthrough at t = 0. Chosen over
    /// linear interpolation because linear dips up to −12 dB at 20 kHz at
    /// t = 0.5, which the cycling fraction would turn into audible HF
    /// flutter; Catmull-Rom stays within ~1 dB below 12 kHz.
    @inline(__always)
    static func catmullRom(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return x0 + t * (c1 + t * (c2 + t * c3))
    }
}
