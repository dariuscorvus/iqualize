import XCTest
import IQCaptureProtocol
@testable import iQualize

/// End-to-end tests of CaptureClient.readResampled (#133) against a synthetic
/// ring the test owns — no helper process, no mmap, no audio device. The
/// writer produces interleaved sines at 48 kHz × (1 ± drift) relative to the
/// reader's consumption, exactly the unlocked-clock situation the drift
/// compensator exists for.
final class CaptureClientResampleTests: XCTestCase {

    private static let headerSize = 64          // matches the helper's (stride+63)&~63
    private static let capacityFloats = 32768   // 16384 stereo frames, power of two
    private static let sampleRate = 48000.0
    private static let callbackFrames = 512
    private static let amplitude = 0.5
    private static let toneL = 997.0
    private static let toneR = 1499.0

    /// Owns the ring region and writes drifting interleaved stereo sines the
    /// way the capture helper does: sample stores, then the head.
    private final class SyntheticWriter {
        let region: UnsafeMutableRawPointer
        let data: UnsafeMutablePointer<Float>
        let writeHeadPtr: UnsafeMutablePointer<UInt64>
        let mask: UInt64
        var head: UInt64 = 0                    // in floats
        var phaseL = 0.0
        var phaseR = 0.0
        var pendingFrames = 0.0

        init() {
            region = UnsafeMutableRawPointer.allocate(
                byteCount: headerSize + capacityFloats * MemoryLayout<Float>.size,
                alignment: 4096)
            let header = region.bindMemory(to: SharedHeader.self, capacity: 1)
            header.pointee = SharedHeader(
                writeHead: 0, readHead: 0,
                sampleRate: sampleRate, channels: 2,
                capacityFloats: UInt32(capacityFloats))
            data = region.advanced(by: headerSize)
                .bindMemory(to: Float.self, capacity: capacityFloats)
            data.initialize(repeating: 0, count: capacityFloats)
            writeHeadPtr = region
                .advanced(by: MemoryLayout<SharedHeader>.offset(of: \.writeHead)!)
                .assumingMemoryBound(to: UInt64.self)
            mask = UInt64(capacityFloats - 1)
        }

        deinit { region.deallocate() }

        /// One reader-callback's worth of wall-clock production at the
        /// writer's (drifting) rate, whole frames with remainder carry.
        func produce(rateFactor: Double) {
            pendingFrames += Double(callbackFrames) * rateFactor
            let whole = Int(pendingFrames)
            pendingFrames -= Double(whole)
            write(frames: whole)
        }

        func write(frames: Int) {
            let incL = 2 * Double.pi * toneL / sampleRate
            let incR = 2 * Double.pi * toneR / sampleRate
            for _ in 0..<frames {
                data[Int(head & mask)] = Float(amplitude * sin(phaseL))
                data[Int((head &+ 1) & mask)] = Float(amplitude * sin(phaseR))
                head &+= 2
                phaseL = (phaseL + incL).truncatingRemainder(dividingBy: 2 * .pi)
                phaseR = (phaseR + incR).truncatingRemainder(dividingBy: 2 * .pi)
            }
            writeHeadPtr.pointee = head
        }
    }

    private func makeClient(_ writer: SyntheticWriter) -> CaptureClient {
        let client = CaptureClient()
        client.attach(region: writer.region, headerSize: Self.headerSize,
                      capacityFloats: Self.capacityFloats,
                      sampleRate: Self.sampleRate, channels: 2)
        return client
    }

    /// Coherent single-window tone amplitude via complex correlation — the
    /// measurement that reads 1-5 dB low on the pre-#133 pipeline.
    private func coherentAmplitude(_ samples: ArraySlice<Float>, frequency: Double) -> Double {
        var re = 0.0, im = 0.0
        var phase = 0.0
        let inc = 2 * Double.pi * frequency / Self.sampleRate
        for s in samples {
            re += Double(s) * cos(phase)
            im -= Double(s) * sin(phase)
            phase += inc
        }
        let n = Double(samples.count)
        return 2 * (re * re + im * im).squareRoot() / n
    }

    private func channel(_ interleaved: [Float], _ ch: Int) -> [Float] {
        stride(from: ch, to: interleaved.count, by: 2).map { interleaved[$0] }
    }

    /// Runs `seconds` of lockstep writer/reader simulation, returning the
    /// interleaved reader output.
    private func run(client: CaptureClient, writer: SyntheticWriter,
                     seconds: Double, rateFactor: Double) -> [Float] {
        let callbacks = Int(seconds * Self.sampleRate / Double(Self.callbackFrames))
        let dest = UnsafeMutablePointer<Float>.allocate(capacity: Self.callbackFrames * 2)
        defer { dest.deallocate() }
        var output: [Float] = []
        output.reserveCapacity(callbacks * Self.callbackFrames * 2)
        for _ in 0..<callbacks {
            writer.produce(rateFactor: rateFactor)
            let got = client.readResampled(dest, frames: Self.callbackFrames)
            if got == 0 {
                output.append(contentsOf: [Float](repeating: 0, count: Self.callbackFrames * 2))
            } else {
                output.append(contentsOf: UnsafeBufferPointer(start: dest, count: Self.callbackFrames * 2))
            }
        }
        return output
    }

    // MARK: - Steady drift

    func testDriftedWriterProducesCoherentOutputAndConvergedFill() {
        for drift in [100e-6, 0.0, -100e-6] {
            let writer = SyntheticWriter()
            let client = makeClient(writer)
            let output = run(client: client, writer: writer, seconds: 30, rateFactor: 1 + drift)

            let telemetry = client.telemetrySnapshot()
            XCTAssertEqual(telemetry.underruns, 0, "drift \(drift): no underruns in steady state")
            XCTAssertEqual(telemetry.overrunResyncs, 0, "drift \(drift): no resyncs in steady state")
            // Converged fill: target + drift·τ·sr residual, ± ripple.
            let expectedFill = 2048.0 + drift * DriftPolicy.controllerTauSeconds * Self.sampleRate
            XCTAssertEqual(Double(telemetry.fillFrames), expectedFill, accuracy: 20,
                           "drift \(drift): fill converges near target")
            XCTAssertEqual(telemetry.driftPpm, drift * 1e6, accuracy: 5,
                           "drift \(drift): reported correction matches the injected drift")

            // Analysis window: the last 4 s, long after convergence.
            let left = channel(output, 0)
            let right = channel(output, 1)
            let window = Int(4 * Self.sampleRate)
            let tailL = left[(left.count - window)...]
            let tailR = right[(right.count - window)...]

            // The resampler consumes `1+drift` source frames per output frame,
            // so the tone lands at f·(1+drift) in the reader's domain — the
            // physically correct result for unlocked clocks. Coherent
            // integration at that frequency must read the full source level:
            // this is exactly the measurement that reads 1-5 dB low on the
            // slipping pre-#133 pipeline.
            let ampL = coherentAmplitude(tailL, frequency: Self.toneL * (1 + drift))
            let dbErrorL = 20 * log10(ampL / Self.amplitude)
            XCTAssertEqual(dbErrorL, 0, accuracy: 0.1,
                           "drift \(drift): coherent 4 s tone level within 0.1 dB")

            let ampR = coherentAmplitude(tailR, frequency: Self.toneR * (1 + drift))
            XCTAssertEqual(20 * log10(ampR / Self.amplitude), 0, accuracy: 0.1,
                           "drift \(drift): right channel intact")

            // No splice: a dropped/repeated/silenced chunk steps the waveform
            // harder than a continuous 997 Hz sine ever can.
            let maxSlope = Float(1.05 * Self.amplitude * 2 * Double.pi * Self.toneL * (1 + drift) / Self.sampleRate)
            var maxDelta: Float = 0
            var prev = tailL.first!
            for s in tailL.dropFirst() {
                maxDelta = max(maxDelta, abs(s - prev))
                prev = s
            }
            XCTAssertLessThanOrEqual(maxDelta, maxSlope,
                                     "drift \(drift): no phase discontinuity in the output")

            // Channel separation: the right tone must not appear on the left.
            // Frame-based positions make L/R misalignment structural nonsense;
            // rectangular-window leakage of the 1499 Hz tone sits near -76 dB,
            // an actual swap at 0 dB.
            let bleed = coherentAmplitude(tailL, frequency: Self.toneR * (1 + drift))
            XCTAssertLessThan(20 * log10(max(bleed, 1e-12) / Self.amplitude), -60,
                              "drift \(drift): no L/R bleed")
        }
    }

    // MARK: - Seeding

    func testReadsBeforeTargetFillReturnSilenceWithoutCounting() {
        let writer = SyntheticWriter()
        let client = makeClient(writer)
        let dest = UnsafeMutablePointer<Float>.allocate(capacity: Self.callbackFrames * 2)
        defer { dest.deallocate() }

        // 3 callbacks of production = 1536 frames < 2048 target.
        for _ in 0..<3 {
            writer.produce(rateFactor: 1.0)
            XCTAssertEqual(client.readResampled(dest, frames: Self.callbackFrames), 0)
        }
        let telemetry = client.telemetrySnapshot()
        XCTAssertEqual(telemetry.underruns, 0, "seeding is not an underrun")
        XCTAssertEqual(telemetry.fillFrames, 0)

        // Two more callbacks cross target+1; the seed lands and reads flow.
        writer.produce(rateFactor: 1.0)
        writer.produce(rateFactor: 1.0)
        XCTAssertEqual(client.readResampled(dest, frames: Self.callbackFrames), Self.callbackFrames)
    }

    // MARK: - Writer stall (underrun)

    func testWriterStallCountsOneUnderrunAndResumesCleanly() {
        let writer = SyntheticWriter()
        let client = makeClient(writer)

        var output = run(client: client, writer: writer, seconds: 10, rateFactor: 1.0)
        XCTAssertEqual(client.telemetrySnapshot().underruns, 0)

        // Writer stalls ~200 ms: reader callbacks continue with no production.
        let dest = UnsafeMutablePointer<Float>.allocate(capacity: Self.callbackFrames * 2)
        defer { dest.deallocate() }
        for _ in 0..<19 {
            let got = client.readResampled(dest, frames: Self.callbackFrames)
            if got == 0 {
                output.append(contentsOf: [Float](repeating: 0, count: Self.callbackFrames * 2))
            } else {
                output.append(contentsOf: UnsafeBufferPointer(start: dest, count: Self.callbackFrames * 2))
            }
        }
        XCTAssertEqual(client.telemetrySnapshot().underruns, 1,
                       "a stall counts once, not once per starved callback")

        // Writer resumes; the reader re-seeds on fresh audio and runs clean.
        let resumed = run(client: client, writer: writer, seconds: 10, rateFactor: 1.0)
        output.append(contentsOf: resumed)

        let telemetry = client.telemetrySnapshot()
        XCTAssertEqual(telemetry.underruns, 1, "no further underruns after resume")
        XCTAssertEqual(telemetry.overrunResyncs, 0)
        XCTAssertEqual(Double(telemetry.fillFrames), 2048, accuracy: 20, "fill re-converges")

        // Post-resume tail is a clean, full-level, correctly-routed tone.
        let left = channel(resumed, 0)
        let window = Int(4 * Self.sampleRate)
        let tailL = left[(left.count - window)...]
        let ampL = coherentAmplitude(tailL, frequency: Self.toneL)
        XCTAssertEqual(20 * log10(ampL / Self.amplitude), 0, accuracy: 0.1)
        let bleed = coherentAmplitude(tailL, frequency: Self.toneR)
        XCTAssertLessThan(20 * log10(max(bleed, 1e-12) / Self.amplitude), -60,
                          "channels stay aligned across an underrun re-seed")
    }

    // MARK: - Reader stall (overrun)

    func testReaderStallCountsOneResyncAndReturnsToTarget() {
        let writer = SyntheticWriter()
        let client = makeClient(writer)
        _ = run(client: client, writer: writer, seconds: 10, rateFactor: 1.0)

        // Reader stalls while the writer keeps going: fill must pass
        // 3×target = 6144 before the next read (10 callbacks — 9 lands the
        // integer arithmetic exactly on the threshold, which doesn't trip).
        for _ in 0..<10 {
            writer.produce(rateFactor: 1.0)
        }

        let dest = UnsafeMutablePointer<Float>.allocate(capacity: Self.callbackFrames * 2)
        defer { dest.deallocate() }
        XCTAssertEqual(client.readResampled(dest, frames: Self.callbackFrames), Self.callbackFrames,
                       "recovery read succeeds immediately — the data exists")

        let telemetry = client.telemetrySnapshot()
        XCTAssertEqual(telemetry.overrunResyncs, 1)
        XCTAssertEqual(telemetry.underruns, 0)
        XCTAssertEqual(Double(telemetry.fillFrames), 2048, accuracy: 20,
                       "resync jumps straight back to target")
    }
}
