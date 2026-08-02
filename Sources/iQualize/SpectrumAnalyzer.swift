import Accelerate
import AVFAudio

/// Real-time FFT spectrum analyzer. Processes AVAudioPCMBuffers from an installTap
/// callback and writes smoothed log-frequency magnitudes + peak hold values to a
/// SpectrumData double-buffer for UI consumption.
///
/// One instance per tap point (pre-EQ and post-EQ each get their own).
/// All processing happens in the tap callback — no additional threads.
final class SpectrumAnalyzer: @unchecked Sendable {
    let spectrumData = SpectrumData()

    // FFT configuration
    private let fftSize = 2048
    private let halfN = 1024
    private let log2n: vDSP_Length = 11  // log2(2048)
    private let fftSetup: FFTSetup
    private let hannWindow: [Float]
    private let binCount = SpectrumData.binCount  // 128 display bins

    // Pre-computed log-frequency bin edges (binCount+1 edges, from 20Hz to 20kHz)
    private let binEdgeFrequencies: [Float]

    // Pre-allocated work buffers (owned by audio thread — single writer)
    private let mono: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let dbMags: UnsafeMutablePointer<Float>
    private let monoMixScale: UnsafeMutablePointer<Float>

    // Smoothing state (owned by audio thread — no synchronization needed)
    private let smoothedMagnitudes: UnsafeMutablePointer<Float>
    private let peakMagnitudes: UnsafeMutablePointer<Float>
    private let peakHoldCounters: UnsafeMutablePointer<Int>

    // Smoothing constants
    private let decayFactor: Float = 0.85
    private let peakHoldFrames: Int = 47       // ~2s at ~23.4Hz FFT rate
    private let peakFallRate: Float = 1.7      // dB per FFT frame (~40 dB/s)
    private let silenceThreshold: Float = -89.0

    init() {
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!

        var window = [Float](repeating: 0, count: 2048)
        vDSP_hann_window(&window, vDSP_Length(2048), Int32(vDSP_HANN_NORM))
        hannWindow = window

        var edges = [Float](repeating: 0, count: 129)
        for i in 0...128 {
            let t = Float(i) / 128.0
            edges[i] = 20.0 * powf(1000.0, t)
        }
        binEdgeFrequencies = edges

        // Allocate work buffers
        mono = .allocate(capacity: 2048)
        mono.initialize(repeating: 0, count: 2048)
        realp = .allocate(capacity: 1024)
        realp.initialize(repeating: 0, count: 1024)
        imagp = .allocate(capacity: 1024)
        imagp.initialize(repeating: 0, count: 1024)
        magnitudes = .allocate(capacity: 1024)
        magnitudes.initialize(repeating: 0, count: 1024)
        dbMags = .allocate(capacity: 1024)
        dbMags.initialize(repeating: 0, count: 1024)
        monoMixScale = .allocate(capacity: 1)
        monoMixScale.initialize(to: 0)

        smoothedMagnitudes = .allocate(capacity: 128)
        smoothedMagnitudes.initialize(repeating: -90.0, count: 128)
        peakMagnitudes = .allocate(capacity: 128)
        peakMagnitudes.initialize(repeating: -90.0, count: 128)
        peakHoldCounters = .allocate(capacity: 128)
        peakHoldCounters.initialize(repeating: 0, count: 128)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        mono.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
        dbMags.deallocate()
        monoMixScale.deallocate()
        smoothedMagnitudes.deallocate()
        peakMagnitudes.deallocate()
        peakHoldCounters.deallocate()
    }

    /// Process a buffer from installTap. Call this directly in the tap closure.
    func process(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let samplesToProcess = min(frameCount, fftSize)

        // 1. Mix to mono (using raw pointers to avoid exclusivity issues)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            memcpy(mono, channelData[0], samplesToProcess * MemoryLayout<Float>.size)
        } else {
            // Zero mono buffer first
            memset(mono, 0, fftSize * MemoryLayout<Float>.size)
            let scale = 1.0 / Float(channelCount)
            monoMixScale.pointee = scale
            for ch in 0..<channelCount {
                // mono[i] += channelData[ch][i] * scale
                vDSP_vsma(channelData[ch], 1, monoMixScale, mono, 1, mono, 1, vDSP_Length(samplesToProcess))
            }
        }

        // Zero-pad if needed
        if samplesToProcess < fftSize {
            memset(mono.advanced(by: samplesToProcess), 0,
                   (fftSize - samplesToProcess) * MemoryLayout<Float>.size)
        }

        // 2. Apply Hann window (in-place via raw pointers)
        hannWindow.withUnsafeBufferPointer { winBuf in
            vDSP_vmul(mono, 1, winBuf.baseAddress!, 1, mono, 1, vDSP_Length(fftSize))
        }

        // 3. FFT
        var splitComplex = DSPSplitComplex(realp: realp, imagp: imagp)

        // Pack interleaved real data into split complex
        mono.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // 4. Square magnitudes
        vDSP_zvmags(&splitComplex, 1, magnitudes, 1, vDSP_Length(halfN))

        // Normalize
        var normFactor: Float = 1.0 / Float(halfN * halfN)
        vDSP_vsmul(magnitudes, 1, &normFactor, magnitudes, 1, vDSP_Length(halfN))

        // 5. Convert to dB: 10 * log10(mag + epsilon)
        var epsilon: Float = 1e-10
        vDSP_vsadd(magnitudes, 1, &epsilon, dbMags, 1, vDSP_Length(halfN))
        var count = Int32(halfN)
        vvlog10f(dbMags, dbMags, &count)
        var ten: Float = 10.0
        vDSP_vsmul(dbMags, 1, &ten, dbMags, 1, vDSP_Length(halfN))

        // 6. Map to log bins, smooth, write to shared buffer
        mapToLogBins(sampleRate: sampleRate)
    }

    private func mapToLogBins(sampleRate: Double) {
        let freqPerBin = Float(sampleRate) / Float(fftSize)

        for i in 0..<binCount {
            let loFreq = binEdgeFrequencies[i]
            let hiFreq = binEdgeFrequencies[i + 1]

            let loBin = Int(loFreq / freqPerBin)
            let hiBin = min(Int(hiFreq / freqPerBin), halfN - 1)

            if loBin >= halfN { continue }

            var raw: Float
            if loBin >= hiBin {
                raw = dbMags[min(max(loBin, 0), halfN - 1)]
            } else {
                var sum: Float = 0
                var count = 0
                for b in loBin...hiBin {
                    sum += dbMags[b]
                    count += 1
                }
                raw = sum / Float(count)
            }
            raw = max(raw, -90.0)

            // Smoothing: instant attack, exponential decay
            if raw > smoothedMagnitudes[i] {
                smoothedMagnitudes[i] = raw
            } else {
                smoothedMagnitudes[i] = smoothedMagnitudes[i] * decayFactor + raw * (1.0 - decayFactor)
            }

            if smoothedMagnitudes[i] < silenceThreshold {
                smoothedMagnitudes[i] = -90.0
            }

            // Peak hold
            if raw > peakMagnitudes[i] {
                peakMagnitudes[i] = raw
                peakHoldCounters[i] = peakHoldFrames
            } else if peakHoldCounters[i] > 0 {
                peakHoldCounters[i] -= 1
            } else {
                peakMagnitudes[i] -= peakFallRate
                if peakMagnitudes[i] < silenceThreshold {
                    peakMagnitudes[i] = -90.0
                }
            }
        }

        spectrumData.write(smoothedMagnitudes, peaks: peakMagnitudes)
    }
}
