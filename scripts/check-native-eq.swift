// Offline production-DSP regression; no device, capture, or app required.
import AVFAudio
import AudioToolbox
import Foundation

@main struct CheckNativeEQ {
    static func main() throws {
        for rate in [44100.0, 48000.0] {
            try check(rate: rate)
        }
    }

    static func check(rate: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let engine = AVAudioEngine(), eq = AVAudioUnitEQ(numberOfBands: 31)
        let state = UnsafeMutablePointer<(Double, Double)>.allocate(capacity: 1)
        state.initialize(to: (0, 32))
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            for i in 0..<Int(frames) {
                let x = Float(sin(state.pointee.0))
                state.pointee.0 += 2 * .pi * state.pointee.1 / rate
                for b in UnsafeMutableAudioBufferListPointer(list) {
                    b.mData!.assumingMemoryBound(to: Float.self)[i] = x
                }
            }
            return noErr
        }
        engine.attach(source); engine.attach(eq)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop(); state.deinitialize(count: 1); state.deallocate() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func rms() throws -> Double {
            var sum = 0.0
            for block in 0..<120 {
                guard try engine.renderOffline(512, to: buffer) == .success else { fatalError("offline render failed") }
                if block >= 60 {
                    for i in 0..<Int(buffer.frameLength) {
                        let x = Double(buffer.floatChannelData![0][i]); sum += x*x
                    }
                }
            }
            return sqrt(sum / 30720)
        }
        func nativeGain(_ index: UInt32) -> Float {
            var value: AudioUnitParameterValue = 0
            precondition(AudioUnitGetParameter(eq.audioUnit, kAUNBandEQParam_Gain + index, kAudioUnitScope_Global, 0, &value) == noErr)
            return value
        }
        func checkGains(_ bands: [EQBand]) {
            for (index, band) in bands.enumerated() {
                let expected: Float = band.muted ? 0 : band.gain
                precondition(abs(nativeGain(UInt32(index)) - expected) < 0.001, "native gain mismatch at band \(index)")
            }
        }
        var issue = EQPresetData.vocalClarity.bands
        issue[0].filterType = .highPass; issue[0].gain = -3.7588596
        issue[1].filterType = .highPass; issue[1].gain = -6
        issue[2].gain = -22.341257
        let bass = EQPresetData.bassBoost.bands
        configureNativeEQBands(eq, bands: issue, oldBands: nil)
        let highpass = try rms()
        configureNativeEQBands(eq, bands: bass, oldBands: issue)
        let switched = try rms()
        checkGains(bass)
        precondition(abs(nativeGain(0) - 10) < 0.001 && abs(nativeGain(1) - 10) < 0.001)
        configureNativeEQBands(eq, bands: bass, oldBands: nil)
        let reference = try rms()
        precondition(abs(switched - reference) < 0.04 && switched > highpass * 10)
        var edited = bass; edited[0].gain = -8
        configureNativeEQBands(eq, bands: edited, oldBands: bass)
        let editedRMS = try rms()
        checkGains(edited)
        precondition(abs(nativeGain(0) + 8) < 0.001 && editedRMS < switched / 3)
        var adjusted = edited
        adjusted[0].frequency = 40
        configureNativeEQBands(eq, bands: adjusted, oldBands: edited)
        let frequencyRMS = try rms()
        checkGains(adjusted)
        precondition(abs(nativeGain(0) + 8) < 0.001, "frequency/bandwidth edit overwrote gain")
        var bandwidth = adjusted; bandwidth[0].bandwidth = 0.6
        configureNativeEQBands(eq, bands: bandwidth, oldBands: adjusted)
        let bandwidthRMS = try rms()
        checkGains(bandwidth)
        precondition(abs(nativeGain(0) + 8) < 0.001, "bandwidth edit overwrote gain")
        var mutedBell = bandwidth; mutedBell[0].muted = true
        configureNativeEQBands(eq, bands: mutedBell, oldBands: bandwidth)
        let mutedBellRMS = try rms()
        checkGains(mutedBell)
        configureNativeEQBands(eq, bands: bandwidth, oldBands: mutedBell)
        let unmutedBellRMS = try rms()
        checkGains(bandwidth)
        precondition(abs(nativeGain(0) + 8) < 0.001 && abs(unmutedBellRMS - bandwidthRMS) < 0.04, "unmute failed")
        var shelf = bandwidth; shelf[0].filterType = .lowShelf
        configureNativeEQBands(eq, bands: shelf, oldBands: bandwidth)
        let shelfRMS = try rms()
        checkGains(shelf)
        precondition(abs(nativeGain(0) + 8) < 0.001, "shelf switch overwrote gain")
        configureNativeEQBands(eq, bands: bandwidth, oldBands: shelf)
        let bellAgainRMS = try rms()
        checkGains(bandwidth)
        precondition(abs(nativeGain(0) + 8) < 0.001 && abs(bellAgainRMS - bandwidthRMS) < 0.04, "bell restore failed")
        print("\(rate) edits freq \(frequencyRMS), bandwidth \(bandwidthRMS), mute \(mutedBellRMS), unmute \(unmutedBellRMS), shelf \(shelfRMS), bell \(bellAgainRMS); AU gain \(nativeGain(0)), wrapper \(eq.bands[0].gain)")
        var together = adjusted
        together[0].gain = -5; together[0].bandwidth = 1.5
        configureNativeEQBands(eq, bands: together, oldBands: adjusted)
        _ = try rms()
        checkGains(together)
        precondition(abs(nativeGain(0) + 5) < 0.001, "combined gain/bandwidth edit overwrote gain")
        print("\(rate) #205 highpass \(highpass), switch \(switched), full \(reference), bell edited \(editedRMS)")

        // Type changes even with equal stored gains must publish the gain.
        let hp = [EQBand(frequency: 1000, gain: -8, filterType: .highPass)]
        let bell = [EQBand(frequency: 1000, gain: -8)]
        configureNativeEQBands(eq, bands: hp, oldBands: together); _ = try rms()
        configureNativeEQBands(eq, bands: bell, oldBands: hp); _ = try rms()
        precondition(abs(nativeGain(0) + 8) < 0.001)

        for (type, tone) in [(FilterType.highPass, 100.0), (.lowPass, 8000.0)] {
            state.pointee.1 = tone
            var band = EQBand(frequency: 1000, gain: 0, filterType: type)
            configureNativeEQBands(eq, bands: [band], oldBands: nil)
            let filtered = try rms()
            let old = band; band.muted = true
            configureNativeEQBands(eq, bands: [band], oldBands: [old])
            let muted = try rms()
            let mutedBand = band; band.muted = false
            configureNativeEQBands(eq, bands: [band], oldBands: [mutedBand])
            let restored = try rms()
            precondition(muted > filtered * 10 && muted > restored * 10)

            let chain = BiquadFilterChain(bands: [band], sampleRate: rate)
            var phase = 0.0
            func custom() -> Double {
                var data = (0..<Int(rate)).map { _ -> Float in
                    defer { phase += 2 * .pi * tone / rate }; return Float(sin(phase))
                }
                data.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, frameCount: $0.count) }
                return sqrt(data.suffix(data.count / 2).reduce(0.0) { $0 + Double($1*$1) } / Double(data.count / 2))
            }
            let c0 = custom(); band.muted = true
            chain.updateCoefficients(bands: [band], sampleRate: rate); let c1 = custom()
            band.muted = false
            chain.updateCoefficients(bands: [band], sampleRate: rate); let c2 = custom()
            precondition(c1 > c0 * 10 && c1 > c2 * 10)
            print("\(rate) \(type) native \(filtered) → \(muted) → \(restored); custom \(c0) → \(c1) → \(c2)")
        }
    }
}
