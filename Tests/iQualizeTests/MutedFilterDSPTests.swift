import AVFAudio
import AudioToolbox
import XCTest
@testable import iQualize

final class MutedFilterDSPTests: XCTestCase {
    private func checkCustom(_ type: FilterType, tone: Double, sampleRate: Double) {
        var band = EQBand(frequency: 1000, gain: 0, filterType: type)
        let chain = BiquadFilterChain(bands: [band], sampleRate: sampleRate)
        var phase = 0.0
        func rms() -> Double {
            var data = (0..<Int(sampleRate)).map { _ -> Float in
                defer { phase += 2 * .pi * tone / sampleRate }
                return Float(sin(phase))
            }
            data.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, frameCount: $0.count) }
            return sqrt(data.suffix(data.count / 2).reduce(0.0) { $0 + Double($1 * $1) } / Double(data.count / 2))
        }
        XCTAssertLessThan(rms(), 0.25)
        band.muted = true
        chain.updateCoefficients(bands: [band], sampleRate: sampleRate)
        XCTAssertEqual(rms(), 1 / sqrt(2), accuracy: 0.02)
        band.muted = false
        chain.updateCoefficients(bands: [band], sampleRate: sampleRate)
        XCTAssertLessThan(rms(), 0.25)
    }

    func testCustomChainMuteAndRestoreHighAndLowPass() {
        for rate in [44100.0, 48000.0] {
            checkCustom(.highPass, tone: 100, sampleRate: rate)
            checkCustom(.lowPass, tone: 8000, sampleRate: rate)
        }
    }

    func testNativeEQMuteAndRestoreHighAndLowPass() throws {
        let cases = [44100.0, 48000.0].flatMap { rate in
            [(rate, FilterType.highPass, 100.0), (rate, .lowPass, 8000.0)]
        }
        for (rate, type, tone) in cases {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let engine = AVAudioEngine()
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            var phase = 0.0
            let source = AVAudioSourceNode(format: format) { _, _, frames, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                for i in 0..<Int(frames) {
                    let sample = Float(sin(phase)); phase += 2 * .pi * tone / rate
                    for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[i] = sample }
                }
                return noErr
            }
            engine.attach(source); engine.attach(eq)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            try engine.start()
            defer { engine.stop() }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            func rms() throws -> Double {
                var sum = 0.0
                for block in 0..<100 {
                    XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
                    if block >= 50 {
                        for i in 0..<Int(buffer.frameLength) {
                            let x = Double(buffer.floatChannelData![0][i]); sum += x * x
                        }
                    }
                }
                return sqrt(sum / (50 * 512))
            }
            var band = EQBand(frequency: 1000, gain: 0, filterType: type)
            configureNativeEQBands(eq, bands: [band], oldBands: nil)
            eq.bypass = true
            let dry = try rms()
            eq.bypass = false
            XCTAssertGreaterThan(dry, 0.1)
            XCTAssertLessThan(try rms(), dry / 4)
            let old = band; band.muted = true
            configureNativeEQBands(eq, bands: [band], oldBands: [old])
            XCTAssertEqual(try rms(), dry, accuracy: dry * 0.04)
            let muted = band; band.muted = false
            configureNativeEQBands(eq, bands: [band], oldBands: [muted])
            XCTAssertLessThan(try rms(), dry / 4)
        }
    }

    /// Issue #205's attached preset has high-pass bands at 32 and 64 Hz.
    /// Compare the first switch against a fully configured copy of the target
    /// using actual offline AUNBandEQ output, after settling.
    func testNativePresetSwitchFromIssue205HighPassToBassBoost() throws {
        for rate in [44100.0, 48000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let engine = AVAudioEngine(), eq = AVAudioUnitEQ(numberOfBands: 31)
            var phase = 0.0
            let source = AVAudioSourceNode(format: format) { _, _, frames, list in
                for i in 0..<Int(frames) {
                    let sample = Float(sin(phase)); phase += 2 * .pi * 32 / rate
                    for b in UnsafeMutableAudioBufferListPointer(list) {
                        b.mData!.assumingMemoryBound(to: Float.self)[i] = sample
                    }
                }
                return noErr
            }
            engine.attach(source); engine.attach(eq)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            try engine.start()
            defer { engine.stop() }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            func rms() throws -> Double {
                var sum = 0.0
                for block in 0..<120 {
                    XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
                    if block >= 60 {
                        for i in 0..<Int(buffer.frameLength) {
                            let x = Double(buffer.floatChannelData![0][i]); sum += x * x
                        }
                    }
                }
                return sqrt(sum / (60 * 512))
            }
            var custom = EQPresetData.vocalClarity.bands
            custom[0].filterType = .highPass; custom[0].gain = -3.7588596
            custom[1].filterType = .highPass; custom[1].gain = -6
            custom[2].gain = -22.341257
            let target = EQPresetData.bassBoost.bands
            configureNativeEQBands(eq, bands: custom, oldBands: nil)
            XCTAssertLessThan(try rms(), 0.2)
            configureNativeEQBands(eq, bands: target, oldBands: custom)
            let switched = try rms()
            for index in 0..<2 {
                var gain: AudioUnitParameterValue = 0
                XCTAssertEqual(AudioUnitGetParameter(eq.audioUnit, AudioUnitParameterID(kAUNBandEQParam_Gain + UInt32(index)), kAudioUnitScope_Global, 0, &gain), noErr)
                XCTAssertEqual(gain, 10, accuracy: 0.001)
            }
            configureNativeEQBands(eq, bands: target, oldBands: nil)
            XCTAssertEqual(switched, try rms(), accuracy: 0.04)
            XCTAssertGreaterThan(switched, 1.7)

            // Fewer bands must bypass all previously used slots.
            let two = [EQBand(frequency: 500, gain: 3), EQBand(frequency: 2000, gain: -3)]
            configureNativeEQBands(eq, bands: custom, oldBands: target)
            _ = try rms()
            configureNativeEQBands(eq, bands: two, oldBands: custom)
            let shrunk = try rms()
            configureNativeEQBands(eq, bands: two, oldBands: nil)
            XCTAssertEqual(shrunk, try rms(), accuracy: 0.02)
            XCTAssertTrue(eq.bands.dropFirst(2).allSatisfy(\.bypass))
        }
    }
}
