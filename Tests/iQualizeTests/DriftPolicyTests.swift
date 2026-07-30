import XCTest
@testable import iQualize

final class DriftPolicyTests: XCTestCase {

    // MARK: - Target fill / overrun threshold (#133)

    func testTargetFillAtCommonRates() {
        // 48 kHz stereo ring: 16384 frames capacity. 0.04 s = 1920, floored
        // to 2048.
        XCTAssertEqual(DriftPolicy.targetFillFrames(sampleRate: 48000, capacityFrames: 16384), 2048)
        XCTAssertEqual(DriftPolicy.targetFillFrames(sampleRate: 44100, capacityFrames: 16384), 2048)
        // 96 kHz: 0.04 s = 3840 wins over the floor.
        XCTAssertEqual(DriftPolicy.targetFillFrames(sampleRate: 96000, capacityFrames: 16384), 3840)
    }

    func testTargetFillCappedAtQuarterCapacity() {
        XCTAssertEqual(DriftPolicy.targetFillFrames(sampleRate: 48000, capacityFrames: 4096), 1024)
    }

    func testOverrunThresholdIsTripleTargetCappedClearOfCapacity() {
        XCTAssertEqual(DriftPolicy.overrunThresholdFrames(targetFill: 2048, capacityFrames: 16384), 6144)
        // Cap: never closer to capacity than an eighth of the ring.
        XCTAssertEqual(DriftPolicy.overrunThresholdFrames(targetFill: 6000, capacityFrames: 16384), 14336)
    }

    // MARK: - EMA

    func testEmaAlphaIsFrameCountAware() {
        // Two 512-frame callbacks must smooth exactly as much as one
        // 1024-frame callback: 1-a1024 == (1-a512)^2.
        let a512 = DriftPolicy.emaAlpha(frames: 512, sampleRate: 48000)
        let a1024 = DriftPolicy.emaAlpha(frames: 1024, sampleRate: 48000)
        XCTAssertEqual(1 - a1024, (1 - a512) * (1 - a512), accuracy: 1e-12)
    }

    func testEmaAlphaBounded() {
        let a = DriftPolicy.emaAlpha(frames: 512, sampleRate: 48000)
        XCTAssertGreaterThan(a, 0)
        XCTAssertLessThan(a, 1)
        // τ = 0.5 s at 48 kHz, 512-frame slice → ~0.021 per callback.
        XCTAssertEqual(a, 0.0211, accuracy: 0.001)
    }

    // MARK: - Resample ratio

    func testRatioIsUnityAtTarget() {
        XCTAssertEqual(DriftPolicy.resampleRatio(fillEMA: 2048, targetFill: 2048, sampleRate: 48000), 1.0)
    }

    func testRatioSign() {
        // Fill above target → consume faster than nominal → ratio > 1.
        XCTAssertGreaterThan(DriftPolicy.resampleRatio(fillEMA: 2148, targetFill: 2048, sampleRate: 48000), 1.0)
        XCTAssertLessThan(DriftPolicy.resampleRatio(fillEMA: 1948, targetFill: 2048, sampleRate: 48000), 1.0)
    }

    func testRatioClampsAtMaxCorrection() {
        XCTAssertEqual(DriftPolicy.resampleRatio(fillEMA: 16000, targetFill: 2048, sampleRate: 48000),
                       1.0 + DriftPolicy.maxCorrection)
        XCTAssertEqual(DriftPolicy.resampleRatio(fillEMA: 0, targetFill: 2048, sampleRate: 48000),
                       1.0 - DriftPolicy.maxCorrection)
    }

    func testSteadyStateResidualPrediction() {
        // Pure P: holding 100 ppm of drift needs ratio 1 + 1e-4, which the
        // controller produces at error = drift·τ·sr = 14.4 frames.
        let residual = 100e-6 * DriftPolicy.controllerTauSeconds * 48000
        let ratio = DriftPolicy.resampleRatio(fillEMA: 2048 + residual, targetFill: 2048, sampleRate: 48000)
        XCTAssertEqual(ratio, 1.0 + 100e-6, accuracy: 1e-9)
    }

    // MARK: - Seed position

    func testSeedPositionLandsTargetBehindWriter() {
        XCTAssertEqual(DriftPolicy.seedPosition(writeFrames: 10000, targetFill: 2048), 7952)
    }

    // MARK: - Catmull-Rom

    func testCatmullRomEndpoints() {
        // t = 0 must be bit-exact passthrough of x0.
        XCTAssertEqual(DriftPolicy.catmullRom(0.3, 0.7, -0.2, 0.9, 0), 0.7)
        // t → 1 converges to x1.
        XCTAssertEqual(DriftPolicy.catmullRom(0.3, 0.7, -0.2, 0.9, 1), -0.2, accuracy: 1e-6)
    }

    func testCatmullRomReproducesLinearRamp() {
        // On collinear points the spline is the line itself.
        XCTAssertEqual(DriftPolicy.catmullRom(1, 2, 3, 4, 0.25), 2.25, accuracy: 1e-6)
        XCTAssertEqual(DriftPolicy.catmullRom(-3, -1, 1, 3, 0.5), 0, accuracy: 1e-6)
    }

    func testCatmullRomMidpointWeights() {
        // At t = 0.5 the kernel is (-1/16, 9/16, 9/16, -1/16).
        let v = DriftPolicy.catmullRom(1, 0, 0, 0, 0.5)
        XCTAssertEqual(v, -1.0 / 16.0, accuracy: 1e-6)
        let w = DriftPolicy.catmullRom(0, 1, 0, 0, 0.5)
        XCTAssertEqual(w, 9.0 / 16.0, accuracy: 1e-6)
    }

    // MARK: - Closed loop

    /// Difference-equation simulation of the whole loop: a writer drifting
    /// ±100 ppm against a reader in 512-frame callbacks. Verifies the fill
    /// converges to target + drift·τ·sr with no oscillation and no clamping —
    /// the same math CaptureClient.readResampled runs per callback.
    func testClosedLoopConvergesToPredictedResidual() {
        let sr = 48000.0
        let target = 2048.0
        let callbackFrames = 512

        for drift in [100e-6, -100e-6] {
            // The controller regulates fill as measured at callback start —
            // after the writer's production, before this callback consumes.
            // Track that quantity, exactly as readResampled sees it.
            var fill = target        // seed puts the measured fill at target
            var fillEMA = target
            var producedRemainder = 0.0
            var maxRatioDeviation = 0.0
            var measuredFill = target

            // 60 s: the sim starts with an artificial +512-frame disturbance
            // (production lands before the first measurement), and its decay
            // through the EMA lag needs ~40 s to drop under the assert
            // accuracy. Verified against a longer run: the fixed point is
            // exact from ~45 s on.
            let seconds = 60.0
            let callbacks = Int(seconds * sr / Double(callbackFrames))
            var lastAbsError = Double.infinity
            var errorGrewAfterSettling = false
            let residual = drift * DriftPolicy.controllerTauSeconds * sr

            for i in 0..<callbacks {
                // Writer produces at sr·(1+drift) while the reader consumes
                // one callback's worth of source frames.
                let produced = Double(callbackFrames) * (1 + drift) + producedRemainder
                let wholeProduced = floor(produced)
                producedRemainder = produced - wholeProduced
                fill += wholeProduced
                measuredFill = fill

                let alpha = DriftPolicy.emaAlpha(frames: callbackFrames, sampleRate: sr)
                fillEMA += alpha * (measuredFill - fillEMA)
                let ratio = DriftPolicy.resampleRatio(fillEMA: fillEMA, targetFill: target, sampleRate: sr)
                maxRatioDeviation = max(maxRatioDeviation, abs(ratio - 1))
                fill -= Double(callbackFrames) * ratio

                // After the EMA has settled (~5 s), the approach to the
                // residual must be monotone in the smoothed view — any
                // overshoot/oscillation grows the error between samples.
                let absError = abs(fillEMA - (target + residual))
                if i % 100 == 0 {
                    if Double(i) * Double(callbackFrames) / sr > 5, absError > lastAbsError + 0.5 {
                        errorGrewAfterSettling = true
                    }
                    lastAbsError = absError
                }
            }

            XCTAssertEqual(measuredFill, target + residual, accuracy: 2.0,
                           "measured fill must converge to target + drift·τ·sr for drift \(drift)")
            XCTAssertFalse(errorGrewAfterSettling, "no oscillation after EMA settling")
            XCTAssertLessThan(maxRatioDeviation, DriftPolicy.maxCorrection,
                              "±100 ppm drift must never hit the ratio clamp")
        }
    }
}
