import Foundation
import XCTest
@testable import iQualize

final class SpectrumDataTests: XCTestCase {
    private func read(_ data: SpectrumData) -> (magnitudes: [Float], peaks: [Float]) {
        var magnitudes = [Float](repeating: 0, count: SpectrumData.binCount)
        var peaks = magnitudes
        data.read(&magnitudes, peaks: &peaks)
        return (magnitudes, peaks)
    }

    private func write(_ frame: Float, to data: SpectrumData) {
        var magnitudes = [Float](repeating: frame, count: SpectrumData.binCount)
        var peaks = [Float](repeating: -frame, count: SpectrumData.binCount)
        data.write(&magnitudes, peaks: &peaks)
    }

    func testInitialFrameIsSilent() {
        let frame = read(SpectrumData())
        XCTAssertTrue(frame.magnitudes.allSatisfy { $0 == -90 })
        XCTAssertTrue(frame.peaks.allSatisfy { $0 == -90 })
    }

    func testMultipleWritesDeliverLatestFrameAndRepeatedReadsKeepIt() {
        let data = SpectrumData()
        for frame in 1...10 { write(Float(frame), to: data) }
        for _ in 0..<3 {
            let frame = read(data)
            XCTAssertTrue(frame.magnitudes.allSatisfy { $0 == 10 })
            XCTAssertTrue(frame.peaks.allSatisfy { $0 == -10 })
        }
        write(11, to: data)
        let frame = read(data)
        XCTAssertTrue(frame.magnitudes.allSatisfy { $0 == 11 })
        XCTAssertTrue(frame.peaks.allSatisfy { $0 == -11 })
    }

    func testSingleWriterAndReaderAlwaysObserveCoherentMonotonicSnapshots() {
        let data = SpectrumData()
        let iterations = 100_000
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue(label: "spectrum-data-test-writer").async {
            var magnitudes = [Float](repeating: 0, count: SpectrumData.binCount)
            var peaks = magnitudes
            for frame in 1...iterations {
                let value = Float(frame)
                magnitudes.withUnsafeMutableBufferPointer { $0.update(repeating: value) }
                peaks.withUnsafeMutableBufferPointer { $0.update(repeating: -value) }
                data.write(&magnitudes, peaks: &peaks)
            }
            writer.leave()
        }
        var previous: Float = 0
        var inconsistentSnapshots = 0
        var backwardsSnapshots = 0
        for _ in 0..<iterations {
            let frame = read(data)
            let value = frame.magnitudes[0]
            if value == -90 { continue }
            if !frame.magnitudes.allSatisfy({ $0 == value }) || !frame.peaks.allSatisfy({ $0 == -value }) {
                inconsistentSnapshots += 1
            }
            if value < previous { backwardsSnapshots += 1 }
            previous = value
        }
        writer.wait()
        XCTAssertEqual(inconsistentSnapshots, 0)
        XCTAssertEqual(backwardsSnapshots, 0)
        let latest = read(data)
        XCTAssertTrue(latest.magnitudes.allSatisfy { $0 == Float(iterations) })
        XCTAssertTrue(latest.peaks.allSatisfy { $0 == -Float(iterations) })
    }
}
