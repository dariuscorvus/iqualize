import Foundation
import IQRingAtomics

struct NormalizedBiquadCoeffs: Sendable {
    let b0: Float, b1: Float, b2: Float
    let a1: Float, a2: Float

    init(from raw: BiquadCoefficients) {
        let a0 = Float(raw.a0)
        b0 = Float(raw.b0) / a0
        b1 = Float(raw.b1) / a0
        b2 = Float(raw.b2) / a0
        a1 = Float(raw.a1) / a0
        a2 = Float(raw.a2) / a0
    }

    static let passthrough = NormalizedBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }
}

private struct BiquadSnapshot {
    let coeffs: UnsafeMutablePointer<NormalizedBiquadCoeffs>
    let z1: UnsafeMutablePointer<Float>
    let z2: UnsafeMutablePointer<Float>
    let bandCount: Int
}

/// Real-time biquad chain with complete immutable coefficient/state snapshots.
/// Main-actor publication allocates and reclaims snapshots. The callback only
/// enters the raw-pointer quiescence protocol and mutates the selected state.
final class BiquadFilterChain: @unchecked Sendable {
    private let publication: UnsafeMutablePointer<RTSnapshotPublication>
    private var retiredSnapshots: [UnsafeMutableRawPointer] = []
    private(set) var retiredSnapshotCount = 0
    private(set) var lastRetirementWasOnMainThread = false

    init(bands: [EQBand], sampleRate: Double) {
        publication = .allocate(capacity: 1)
        publication.initialize(to: RTSnapshotPublication())
        let snapshot = Self.makeSnapshot(bands: bands, sampleRate: sampleRate)
        _ = publishSnapshot(publication, UnsafeMutableRawPointer(snapshot))
    }

    deinit {
        if let retired = publishSnapshot(publication, nil) { retiredSnapshots.append(retired) }
        waitForSnapshotQuiescence(publication)
        reclaimQuiescentSnapshots()
        publication.deinitialize(count: 1)
        publication.deallocate()
    }

    func updateCoefficients(bands: [EQBand], sampleRate: Double) {
        let replacement = Self.makeSnapshot(bands: bands, sampleRate: sampleRate)
        if let retired = publishSnapshot(publication, UnsafeMutableRawPointer(replacement)) {
            retiredSnapshots.append(retired)
        }
        reclaimQuiescentSnapshots()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let raw = rtEnter(publication) else { return }
        defer { rtLeave(publication) }
        Self.processSnapshot(raw.assumingMemoryBound(to: BiquadSnapshot.self).pointee,
                             buffer: buffer, frameCount: frameCount)
    }

    static func processRT(_ opaque: UnsafeMutableRawPointer,
                          buffer: UnsafeMutablePointer<Float>,
                          frameCount: Int) {
        let chain = Unmanaged<BiquadFilterChain>.fromOpaque(opaque).takeUnretainedValue()
        chain.process(buffer, frameCount: frameCount)
    }

    func reset() {
        guard let raw = rtEnter(publication) else { return }
        defer { rtLeave(publication) }
        let snapshot = raw.assumingMemoryBound(to: BiquadSnapshot.self).pointee
        for i in 0..<snapshot.bandCount {
            snapshot.z1[i] = 0
            snapshot.z2[i] = 0
        }
    }

    func currentSnapshotCounts() -> (coefficients: Int, state: Int, bands: Int) {
        guard let raw = rtEnter(publication) else { return (0, 0, 0) }
        defer { rtLeave(publication) }
        let count = raw.assumingMemoryBound(to: BiquadSnapshot.self).pointee.bandCount
        return (count, count, count)
    }

    private static func makeSnapshot(bands: [EQBand], sampleRate: Double)
        -> UnsafeMutablePointer<BiquadSnapshot> {
        let count = bands.count
        let coeffs = UnsafeMutablePointer<NormalizedBiquadCoeffs>.allocate(capacity: count)
        let z1 = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let z2 = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for (index, band) in bands.enumerated() {
            coeffs[index] = NormalizedBiquadCoeffs(
                from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
            z1[index] = 0
            z2[index] = 0
        }
        let snapshot = UnsafeMutablePointer<BiquadSnapshot>.allocate(capacity: 1)
        snapshot.initialize(to: BiquadSnapshot(coeffs: coeffs, z1: z1, z2: z2, bandCount: count))
        return snapshot
    }

    private static func destroySnapshot(_ snapshot: UnsafeMutablePointer<BiquadSnapshot>) {
        snapshot.pointee.coeffs.deallocate()
        snapshot.pointee.z1.deallocate()
        snapshot.pointee.z2.deallocate()
        snapshot.deinitialize(count: 1)
        snapshot.deallocate()
    }

    private func reclaimQuiescentSnapshots() {
        guard iq_load_acquire_u32(&publication.pointee.readers) == 0 else { return }
        let retired = retiredSnapshots
        retiredSnapshots.removeAll(keepingCapacity: true)
        for pointer in retired {
            Self.destroySnapshot(pointer.assumingMemoryBound(to: BiquadSnapshot.self))
            retiredSnapshotCount += 1
            lastRetirementWasOnMainThread = Thread.isMainThread
        }
    }

    @inline(__always)
    private static func processSnapshot(_ snapshot: BiquadSnapshot,
                                        buffer: UnsafeMutablePointer<Float>,
                                        frameCount: Int) {
        guard frameCount > 0 else { return }
        for b in 0..<snapshot.bandCount {
            let c = snapshot.coeffs[b]
            var s1 = snapshot.z1[b]
            var s2 = snapshot.z2[b]
            for f in 0..<frameCount {
                let x = buffer[f]
                let y = c.b0 * x + s1
                s1 = c.b1 * x - c.a1 * y + s2
                s2 = c.b2 * x - c.a2 * y
                buffer[f] = y
            }
            if abs(s1) < 1e-15 { s1 = 0 }
            if abs(s2) < 1e-15 { s2 = 0 }
            snapshot.z1[b] = s1
            snapshot.z2[b] = s2
        }
    }
}
