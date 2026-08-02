import XCTest
import AVFAudio
@testable import iQualize

final class RenderConfigurationPublicationTests: XCTestCase {

    private final class FailureBox: @unchecked Sendable {
        let lock = NSLock()
        var value = false
    }
    private var retainedChains: [BiquadFilterChain] = []

    override func tearDown() {
        _ = publishRenderConfigurationForTesting(nil)
        _ = reclaimQuiescentRenderConfigurationsForTesting()
        retainedChains.removeAll()
        super.tearDown()
    }

    private func band(_ frequency: Float, gain: Float = 3.0) -> EQBand {
        EQBand(frequency: frequency, gain: gain, bandwidth: 1.0, filterType: .parametric)
    }

    private func bands(_ count: Int) -> [EQBand] {
        (0..<count).map { band(Float(40 + $0 * 90)) }
    }

    private static func bandCount(_ pointer: UnsafeMutableRawPointer?) -> Int {
        guard let pointer else { return -1 }
        return Unmanaged<BiquadFilterChain>.fromOpaque(pointer)
            .takeUnretainedValue()
            .currentSnapshotCounts()
            .bands
    }

    private func configuration(
        leftCount: Int,
        rightCount: Int,
        inputGain: Float = 1,
        balanceLeft: Float = 1,
        balanceRight: Float = 1
    ) -> RenderConfiguration {
        let left = BiquadFilterChain(bands: bands(leftCount), sampleRate: 48000)
        let right = BiquadFilterChain(bands: bands(rightCount), sampleRate: 48000)
        retainedChains.append(contentsOf: [left, right])
        return RenderConfiguration(
            captureClient: nil,
            channelCount: 2,
            scratchBuffer: nil,
            scratchCapacity: 0,
            balanceLeft: balanceLeft,
            balanceRight: balanceRight,
            inputGain: inputGain,
            volumeCompensation: 1,
            biquadChainL: left,
            biquadChainR: right
        )
    }

    func testReaderObservesCompleteOldOrNewConfigurationWhileBandCountsAlternate() {
        let old = configuration(leftCount: 1, rightCount: 4, inputGain: 0.5)
        XCTAssertEqual(publishRenderConfigurationForTesting(old), 0)

        let held = acquireRenderConfigurationForTesting()
        XCTAssertEqual(held.configurationForTesting?.inputGain, 0.5)
        XCTAssertEqual(Self.bandCount(held.configurationForTesting?.biquadChainL), 1)
        XCTAssertEqual(Self.bandCount(held.configurationForTesting?.biquadChainR), 4)

        let new = configuration(leftCount: 40, rightCount: 2, inputGain: 2)
        XCTAssertEqual(publishRenderConfigurationForTesting(new), 1, "old snapshot must be retired, not reclaimed, while a reader holds it")

        XCTAssertEqual(held.configurationForTesting?.inputGain, 0.5)
        XCTAssertEqual(Self.bandCount(held.configurationForTesting?.biquadChainL), 1)
        XCTAssertEqual(Self.bandCount(held.configurationForTesting?.biquadChainR), 4)
        held.releaseRead()

        XCTAssertEqual(reclaimQuiescentRenderConfigurationsForTesting(), 0)
        let latest = acquireRenderConfigurationForTesting()
        defer { latest.releaseRead() }
        XCTAssertEqual(latest.configurationForTesting?.inputGain, 2)
        XCTAssertEqual(Self.bandCount(latest.configurationForTesting?.biquadChainL), 40)
        XCTAssertEqual(Self.bandCount(latest.configurationForTesting?.biquadChainR), 2)
    }

    func testPublishedConfigurationDoesNotExposeMixedGainAndChainState() {
        let states: [(Float, Int, Int)] = [(0.25, 1, 3), (1.5, 36, 2), (0.75, 4, 44)]

        for state in states {
            XCTAssertGreaterThanOrEqual(
                publishRenderConfigurationForTesting(configuration(leftCount: state.1, rightCount: state.2, inputGain: state.0)),
                0
            )
            let handle = acquireRenderConfigurationForTesting()
            let snapshot = handle.configurationForTesting
            let observed = (
                snapshot?.inputGain ?? -1,
                Self.bandCount(snapshot?.biquadChainL),
                Self.bandCount(snapshot?.biquadChainR)
            )
            handle.releaseRead()
            XCTAssertTrue(
                states.contains { $0.0 == observed.0 && $0.1 == observed.1 && $0.2 == observed.2 },
                "observed mixed state: \(observed)"
            )
        }
    }

    func testConcurrentReaderSeesOnlyCompletePublishedConfigurations() {
        let first = configuration(leftCount: 2, rightCount: 5, inputGain: 0.25)
        let second = configuration(leftCount: 48, rightCount: 3, inputGain: 1.75)
        let expected: [(Float, Int, Int)] = [
            (0.25, 2, 5),
            (1.75, 48, 3)
        ]
        XCTAssertEqual(publishRenderConfigurationForTesting(first), 0)

        let queue = DispatchQueue(label: "iqualize.m3.outer-publication", attributes: .concurrent)
        let group = DispatchGroup()
        let failure = FailureBox()

        group.enter()
        queue.async {
            for iteration in 0..<1_000 {
                _ = publishRenderConfigurationForTesting(iteration.isMultiple(of: 2) ? first : second)
            }
            group.leave()
        }

        group.enter()
        queue.async {
            for _ in 0..<10_000 {
                let handle = acquireRenderConfigurationForTesting()
                guard let snapshot = handle.configurationForTesting else {
                    handle.releaseRead()
                    failure.lock.lock()
                    failure.value = true
                    failure.lock.unlock()
                    continue
                }

                let observed = (
                    snapshot.inputGain,
                    Self.bandCount(snapshot.biquadChainL),
                    Self.bandCount(snapshot.biquadChainR)
                )
                handle.releaseRead()

                if !expected.contains(where: {
                    $0.0 == observed.0 && $0.1 == observed.1 && $0.2 == observed.2
                }) {
                    failure.lock.lock()
                    failure.value = true
                    failure.lock.unlock()
                    break
                }
            }
            group.leave()
        }

        group.wait()
        failure.lock.lock()
        let failed = failure.value
        failure.lock.unlock()
        XCTAssertFalse(failed)
    }

    func testRetirementWaitsForQuiescenceAndReclaimsOffRenderPath() {
        XCTAssertEqual(publishRenderConfigurationForTesting(configuration(leftCount: 2, rightCount: 2)), 0)
        let reader = acquireRenderConfigurationForTesting()
        XCTAssertNotNil(reader.configurationForTesting)

        XCTAssertEqual(publishRenderConfigurationForTesting(configuration(leftCount: 3, rightCount: 3)), 1)
        XCTAssertEqual(reclaimQuiescentRenderConfigurationsForTesting(), 1)

        reader.releaseRead()
        XCTAssertEqual(reclaimQuiescentRenderConfigurationsForTesting(), 0)
    }

    func testPublishedSnapshotRetainsChainUntilReaderQuiescesAndReclaims() {
        weak var weakChain: BiquadFilterChain?
        do {
            let chain = BiquadFilterChain(bands: bands(1), sampleRate: 48000)
            weakChain = chain
            let configuration = RenderConfiguration(
                captureClient: nil,
                channelCount: 2,
                scratchBuffer: nil,
                scratchCapacity: 0,
                balanceLeft: 1,
                balanceRight: 1,
                inputGain: 1,
                volumeCompensation: 1,
                biquadChainL: chain,
                biquadChainR: nil
            )
            XCTAssertEqual(publishRenderConfigurationForTesting(configuration), 0)
        }

        XCTAssertNotNil(weakChain)
        let reader = acquireRenderConfigurationForTesting()
        XCTAssertNotNil(reader.configurationForTesting?.biquadChainL)

        _ = publishRenderConfigurationForTesting(nil)
        XCTAssertNotNil(weakChain)
        XCTAssertEqual(reclaimQuiescentRenderConfigurationsForTesting(), 1)

        reader.releaseRead()
        XCTAssertEqual(reclaimQuiescentRenderConfigurationsForTesting(), 0)
        XCTAssertNil(weakChain)
    }

    func testFixedConfigurationOutputIsUnchangedAcrossEquivalentFreshSnapshots() {
        let input = (0..<512).map { Float(sin(Double($0) * 0.07)) }
        var first = input
        var second = input
        let bands = [band(125, gain: -2), band(1000, gain: 5), band(8000, gain: 1)]

        first.withUnsafeMutableBufferPointer { ptr in
            BiquadFilterChain(bands: bands, sampleRate: 48000).process(ptr.baseAddress!, frameCount: ptr.count)
        }
        second.withUnsafeMutableBufferPointer { ptr in
            BiquadFilterChain(bands: bands, sampleRate: 48000).process(ptr.baseAddress!, frameCount: ptr.count)
        }

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isFinite })
    }

    func testThirtyOneBandBoundaryDoesNotRequireOverflowChain() {
        let config = RenderConfiguration(
            captureClient: nil,
            channelCount: 2,
            scratchBuffer: nil,
            scratchCapacity: 0,
            balanceLeft: 1,
            balanceRight: 1,
            inputGain: 1,
            volumeCompensation: 1,
            biquadChainL: nil,
            biquadChainR: nil
        )
        XCTAssertFalse(config.biquadChainActive)

        let chain = BiquadFilterChain(bands: bands(31), sampleRate: 48000)
        XCTAssertEqual(chain.currentSnapshotCounts().bands, 31)
        var buffer = [Float](repeating: 0, count: 128)
        buffer[0] = 1
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frameCount: ptr.count)
        }
        XCTAssertTrue(buffer.allSatisfy { $0.isFinite })
    }

    func testRenderScratchOverflowPolicyRejectsOversizedAndIntegerOverflowingSlices() {
        XCTAssertTrue(renderScratchCapacityAllows(frameCount: 4096, channelCount: 2, scratchCapacity: 8192))
        XCTAssertFalse(renderScratchCapacityAllows(frameCount: 4097, channelCount: 2, scratchCapacity: 8192))
        XCTAssertFalse(renderScratchCapacityAllows(frameCount: Int.max, channelCount: 2, scratchCapacity: Int.max))
        XCTAssertFalse(renderScratchCapacityAllows(frameCount: -1, channelCount: 2, scratchCapacity: 8192))
    }

    func testSpectrumAnalyzerProcessesRepeatedStereoBuffersWithoutChangingOutputShape() {
        let analyzer = SpectrumAnalyzer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        buffer.frameLength = 2048
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<2048 {
                samples[frame] = sin(Float(frame) * 0.03)
            }
        }

        for _ in 0..<32 {
            analyzer.process(buffer, sampleRate: 48_000)
        }

        var magnitudes = [Float](repeating: 0, count: SpectrumData.binCount)
        var peaks = [Float](repeating: 0, count: SpectrumData.binCount)
        magnitudes.withUnsafeMutableBufferPointer { magnitudePointer in
            peaks.withUnsafeMutableBufferPointer { peakPointer in
                analyzer.spectrumData.read(magnitudePointer.baseAddress!, peaks: peakPointer.baseAddress!)
            }
        }
        XCTAssertEqual(magnitudes.count, SpectrumData.binCount)
        XCTAssertEqual(peaks.count, SpectrumData.binCount)
        XCTAssertTrue(magnitudes.allSatisfy(\.isFinite))
        XCTAssertTrue(peaks.allSatisfy(\.isFinite))
    }

    func testMoreThanThirtyOneBandsRemainUnlimitedAndFinite() {
        for count in [32, 64, 96] {
            let chain = BiquadFilterChain(bands: bands(count), sampleRate: 48000)
            XCTAssertEqual(chain.currentSnapshotCounts().bands, count)
            var buffer = [Float](repeating: 0, count: 256)
            buffer[0] = 1
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frameCount: ptr.count)
            }
            XCTAssertTrue(buffer.allSatisfy { $0.isFinite }, "non-finite output at \(count) bands")
            XCTAssertTrue(buffer.contains { $0 != 0 }, "silent output at \(count) bands")
        }
    }

    func testAlternatingBandCountsWhileProcessingRemainConsistentAndFinite() {
        let chain = BiquadFilterChain(bands: bands(1), sampleRate: 48000)
        let queue = DispatchQueue(label: "iqualize.m3.publication", attributes: .concurrent)
        let group = DispatchGroup()
        let failure = FailureBox()

        group.enter()
        queue.async {
            for iteration in 0..<400 {
                let count = iteration.isMultiple(of: 2) ? 1 : 96
                chain.updateCoefficients(
                    bands: (0..<count).map {
                        EQBand(frequency: Float(40 + $0 * 90), gain: 3, bandwidth: 1, filterType: .parametric)
                    },
                    sampleRate: 48000
                )
            }
            group.leave()
        }

        group.enter()
        queue.async {
            for _ in 0..<2_000 {
                let counts = chain.currentSnapshotCounts()
                if counts.coefficients != counts.state || counts.state != counts.bands {
                    failure.lock.lock()
                    failure.value = true
                    failure.lock.unlock()
                    break
                }

                var buffer = [Float](repeating: 0, count: 64)
                buffer[0] = 1
                buffer.withUnsafeMutableBufferPointer { pointer in
                    chain.process(pointer.baseAddress!, frameCount: pointer.count)
                }
                if !buffer.allSatisfy(\.isFinite) {
                    failure.lock.lock()
                    failure.value = true
                    failure.lock.unlock()
                    break
                }
            }
            group.leave()
        }

        group.wait()
        failure.lock.lock()
        let failed = failure.value
        failure.lock.unlock()
        XCTAssertFalse(failed)
    }
}
