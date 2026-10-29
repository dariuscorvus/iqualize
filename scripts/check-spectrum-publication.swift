// Offline SPSC snapshot stress against the production SpectrumData implementation.
// Compile with SpectrumData.swift and the IQRingAtomics module map. No audio I/O.
import Foundation

@main
struct SpectrumPublicationCheck {
    static func main() {
        let spectrum = SpectrumData()
        let iterations = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1_000_000
        precondition(iterations > 0)
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue(label: "spectrum-publication-writer").async {
            var magnitudes = [Float](repeating: 0, count: SpectrumData.binCount)
            var peaks = magnitudes
            for frame in 1...iterations {
                let value = Float(frame)
                magnitudes.withUnsafeMutableBufferPointer { $0.update(repeating: value) }
                peaks.withUnsafeMutableBufferPointer { $0.update(repeating: -value) }
                spectrum.write(&magnitudes, peaks: &peaks)
            }
            writer.leave()
        }

        var magnitudes = [Float](repeating: 0, count: SpectrumData.binCount)
        var peaks = magnitudes
        var tornFrames = 0
        var backwardsFrames = 0
        var previous: Float = 0
        for _ in 0..<iterations {
            spectrum.read(&magnitudes, peaks: &peaks)
            let frame = magnitudes[0]
            if frame == -90 { continue } // initial silent snapshot
            if !magnitudes.allSatisfy({ $0 == frame }) || !peaks.allSatisfy({ $0 == -frame }) {
                tornFrames += 1
            }
            if frame < previous { backwardsFrames += 1 }
            previous = frame
        }
        writer.wait()
        spectrum.read(&magnitudes, peaks: &peaks)
        let latest = Float(iterations)
        let finalFrameMatches = magnitudes.allSatisfy { $0 == latest }
            && peaks.allSatisfy { $0 == -latest }
        print("SPSC snapshots: \(iterations); torn: \(tornFrames); backwards: \(backwardsFrames); latest: \(finalFrameMatches)")
        guard tornFrames == 0, backwardsFrames == 0, finalFrameMatches else { exit(1) }
        print("PASS coherent magnitude/peak snapshots, monotonic frames, latest publication")
    }
}
