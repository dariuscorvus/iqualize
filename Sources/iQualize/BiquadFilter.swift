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

    /// Linear coefficient interpolation used by the render callback. The
    /// initializer remains private so every coefficient set is either a
    /// cookbook result or an interpolation of two validated sets.
    @inline(__always)
    static func interpolate(_ from: Self, _ to: Self, amount: Float) -> Self {
        let inverse = 1 - amount
        return Self(
            b0: from.b0 * inverse + to.b0 * amount,
            b1: from.b1 * inverse + to.b1 * amount,
            b2: from.b2 * inverse + to.b2 * amount,
            a1: from.a1 * inverse + to.a1 * amount,
            a2: from.a2 * inverse + to.a2 * amount
        )
    }

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
}

/// State storage is manually retained by each published snapshot. The render
/// callback sees only the raw z1/z2 pointers; the owner is retained and
/// released during off-render reclamation.
private final class BiquadStateStorage: @unchecked Sendable {
    let z1: UnsafeMutablePointer<Float>
    let z2: UnsafeMutablePointer<Float>

    init(bandCount: Int) {
        let capacity = max(1, bandCount)
        z1 = .allocate(capacity: capacity)
        z2 = .allocate(capacity: capacity)
        if bandCount > 0 {
            z1.initialize(repeating: 0, count: bandCount)
            z2.initialize(repeating: 0, count: bandCount)
        }
    }

    deinit {
        z1.deallocate()
        z2.deallocate()
    }
}

private struct BiquadSnapshot {
    /// `coeffs` and `targetCoeffs` are immutable after publication. The
    /// callback interpolates between them without allocating or mutating the
    /// coefficient arrays.
    let coeffs: UnsafeMutablePointer<NormalizedBiquadCoeffs>
    let targetCoeffs: UnsafeMutablePointer<NormalizedBiquadCoeffs>
    let z1: UnsafeMutablePointer<Float>
    let z2: UnsafeMutablePointer<Float>
    /// Manually retained off the render path. This raw pointer is never read
    /// by the callback and is released when the snapshot is reclaimed.
    let stateOwner: UnsafeMutableRawPointer
    let bandCount: Int
    let rampFrames: UInt32
    let rampPosition: UnsafeMutablePointer<UInt32>
}

/// Real-time biquad chain with complete coefficient/state snapshots.
///
/// Parameter updates preserve delay state when the band count is unchanged and
/// linearly ramp coefficients over 64 frames. A band-count/topology change or
/// an explicit reset publishes fresh zeroed state. This avoids mutating state
/// that an in-flight callback may be using, while keeping ordinary drag edits
/// continuous. All snapshot allocation, ownership, and reclamation happens
/// off the render path.
final class BiquadFilterChain: @unchecked Sendable {
    static let coefficientRampFrames: UInt32 = 64

    private let publication: UnsafeMutablePointer<RTSnapshotPublication>
    private var retiredSnapshots: [UnsafeMutableRawPointer] = []
    private(set) var retiredSnapshotCount = 0
    private(set) var lastRetirementWasOnMainThread = false

    init(bands: [EQBand], sampleRate: Double) {
        publication = .allocate(capacity: 1)
        publication.initialize(to: RTSnapshotPublication())
        let coefficients = Self.coefficients(for: bands, sampleRate: sampleRate)
        let snapshot = Self.makeSnapshot(
            targetCoefficients: coefficients,
            startingCoefficients: nil,
            stateOwner: nil,
            rampFrames: 0
        )
        _ = publishSnapshot(publication, UnsafeMutableRawPointer(snapshot))
    }

    deinit {
        if let retired = publishSnapshot(publication, nil) {
            retiredSnapshots.append(retired)
        }
        waitForSnapshotQuiescence(publication)
        reclaimQuiescentSnapshots()
        publication.deinitialize(count: 1)
        publication.deallocate()
    }

    /// Update coefficients without touching the live callback state. When
    /// `resetState` is true, the replacement starts with zero delay state,
    /// which is the policy used for a preset switch. Ordinary live edits keep
    /// the existing state storage when the topology is unchanged.
    func updateCoefficients(bands: [EQBand], sampleRate: Double, resetState: Bool = false) {
        let targetCoefficients = Self.coefficients(for: bands, sampleRate: sampleRate)
        var startingCoefficients: [NormalizedBiquadCoeffs]?
        var stateOwner: BiquadStateStorage?

        let raw = rtEnter(publication)
        if let raw {
            let current = raw.assumingMemoryBound(to: BiquadSnapshot.self)
            startingCoefficients = Self.effectiveCoefficients(current)
            if !resetState && current.pointee.bandCount == targetCoefficients.count {
                stateOwner = Unmanaged<BiquadStateStorage>
                    .fromOpaque(current.pointee.stateOwner)
                    .takeUnretainedValue()
            }
            rtLeave(publication)
        } else {
            // rtEnter increments before loading the pointer, so a nil result
            // still needs the matching leave.
            rtLeave(publication)
        }

        let snapshot = Self.makeSnapshot(
            targetCoefficients: targetCoefficients,
            startingCoefficients: startingCoefficients,
            stateOwner: stateOwner,
            rampFrames: startingCoefficients?.count == targetCoefficients.count
                ? Self.coefficientRampFrames : 0
        )
        if let retired = publishSnapshot(publication, UnsafeMutableRawPointer(snapshot)) {
            retiredSnapshots.append(retired)
        }
        reclaimQuiescentSnapshots()
    }

    /// Process one mono channel. The reader is released explicitly so the
    /// callback has no deferred cleanup path or hidden ownership operation.
    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let raw = rtEnter(publication)
        guard let raw else {
            rtLeave(publication)
            return
        }
        Self.processSnapshot(
            raw.assumingMemoryBound(to: BiquadSnapshot.self),
            buffer: buffer,
            frameCount: frameCount
        )
        rtLeave(publication)
    }

    static func processRT(
        _ opaque: UnsafeMutableRawPointer,
        buffer: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let chain = Unmanaged<BiquadFilterChain>.fromOpaque(opaque).takeUnretainedValue()
        chain.process(buffer, frameCount: frameCount)
    }

    /// Publish a zero-state snapshot with the current target coefficients.
    /// This is safe even if the callback is active because the old state is
    /// reclaimed only after the old snapshot has quiesced.
    func reset() {
        let raw = rtEnter(publication)
        guard let raw else {
            rtLeave(publication)
            return
        }
        let current = raw.assumingMemoryBound(to: BiquadSnapshot.self)
        let target = Self.targetCoefficients(current)
        rtLeave(publication)

        let snapshot = Self.makeSnapshot(
            targetCoefficients: target,
            startingCoefficients: nil,
            stateOwner: nil,
            rampFrames: 0
        )
        if let retired = publishSnapshot(publication, UnsafeMutableRawPointer(snapshot)) {
            retiredSnapshots.append(retired)
        }
        reclaimQuiescentSnapshots()
    }

    func currentSnapshotCounts() -> (coefficients: Int, state: Int, bands: Int) {
        let raw = rtEnter(publication)
        guard let raw else {
            rtLeave(publication)
            return (0, 0, 0)
        }
        let count = raw.assumingMemoryBound(to: BiquadSnapshot.self).pointee.bandCount
        rtLeave(publication)
        return (count, count, count)
    }

    /// Test-only visibility into the callback-owned ramp progress. The values
    /// are loaded atomically and the snapshot remains protected for the read.
    func rampStateForTesting() -> (position: UInt32, frames: UInt32) {
        let raw = rtEnter(publication)
        guard let raw else {
            rtLeave(publication)
            return (0, 0)
        }
        let snapshot = raw.assumingMemoryBound(to: BiquadSnapshot.self)
        let position = min(
            iq_load_snapshot_u32(snapshot.pointee.rampPosition),
            snapshot.pointee.rampFrames
        )
        let frames = snapshot.pointee.rampFrames
        rtLeave(publication)
        return (position, frames)
    }

    private static func coefficients(for bands: [EQBand], sampleRate: Double)
        -> [NormalizedBiquadCoeffs] {
        bands.map {
            NormalizedBiquadCoeffs(
                from: BiquadResponse.coefficients(for: $0, sampleRate: sampleRate)
            )
        }
    }

    private static func makeSnapshot(
        targetCoefficients: [NormalizedBiquadCoeffs],
        startingCoefficients: [NormalizedBiquadCoeffs]?,
        stateOwner: BiquadStateStorage?,
        rampFrames: UInt32
    ) -> UnsafeMutablePointer<BiquadSnapshot> {
        let count = targetCoefficients.count
        let capacity = max(1, count)
        let coeffs = UnsafeMutablePointer<NormalizedBiquadCoeffs>.allocate(capacity: capacity)
        let targets = UnsafeMutablePointer<NormalizedBiquadCoeffs>.allocate(capacity: capacity)
        let from = startingCoefficients?.count == count ? startingCoefficients! : targetCoefficients

        if count > 0 {
            for index in 0..<count {
                coeffs[index] = from[index]
                targets[index] = targetCoefficients[index]
            }
        }

        let state = stateOwner ?? BiquadStateStorage(bandCount: count)
        let retainedState = Unmanaged.passRetained(state).toOpaque()
        let rampPosition = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        rampPosition.initialize(to: 0)
        let snapshot = UnsafeMutablePointer<BiquadSnapshot>.allocate(capacity: 1)
        snapshot.initialize(to: BiquadSnapshot(
            coeffs: coeffs,
            targetCoeffs: targets,
            z1: state.z1,
            z2: state.z2,
            stateOwner: retainedState,
            bandCount: count,
            rampFrames: rampFrames,
            rampPosition: rampPosition
        ))
        return snapshot
    }

    private static func targetCoefficients(
        _ snapshot: UnsafeMutablePointer<BiquadSnapshot>
    ) -> [NormalizedBiquadCoeffs] {
        let count = snapshot.pointee.bandCount
        guard count > 0 else { return [] }
        return (0..<count).map { snapshot.pointee.targetCoeffs[$0] }
    }

    private static func effectiveCoefficients(
        _ snapshot: UnsafeMutablePointer<BiquadSnapshot>
    ) -> [NormalizedBiquadCoeffs] {
        let count = snapshot.pointee.bandCount
        guard count > 0 else { return [] }

        let frames = snapshot.pointee.rampFrames
        let position = min(
            iq_load_snapshot_u32(snapshot.pointee.rampPosition),
            frames
        )
        let amount = frames == 0 ? Float(1) : Float(position) / Float(frames)
        return (0..<count).map {
            NormalizedBiquadCoeffs.interpolate(
                snapshot.pointee.coeffs[$0],
                snapshot.pointee.targetCoeffs[$0],
                amount: amount
            )
        }
    }

    private static func destroySnapshot(_ snapshot: UnsafeMutablePointer<BiquadSnapshot>) {
        let stateOwner = snapshot.pointee.stateOwner
        snapshot.pointee.coeffs.deallocate()
        snapshot.pointee.targetCoeffs.deallocate()
        snapshot.pointee.rampPosition.deallocate()
        snapshot.deinitialize(count: 1)
        snapshot.deallocate()
        Unmanaged<BiquadStateStorage>.fromOpaque(stateOwner).release()
    }

    private func reclaimQuiescentSnapshots() {
        guard iq_load_snapshot_readers(&publication.pointee.readers) == 0 else { return }
        let retired = retiredSnapshots
        retiredSnapshots.removeAll(keepingCapacity: true)
        for pointer in retired {
            Self.destroySnapshot(pointer.assumingMemoryBound(to: BiquadSnapshot.self))
            retiredSnapshotCount += 1
            lastRetirementWasOnMainThread = Thread.isMainThread
        }
    }

    @inline(__always)
    private static func processSnapshot(
        _ snapshot: UnsafeMutablePointer<BiquadSnapshot>,
        buffer: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let bandCount = snapshot.pointee.bandCount
        guard bandCount > 0 else { return }

        let rampFrames = snapshot.pointee.rampFrames
        let initialPosition = min(
            iq_load_snapshot_u32(snapshot.pointee.rampPosition),
            rampFrames
        )

        // The chain is cascaded band-by-band. Each band gets the same
        // coefficient for a given frame, so the frame position is restarted
        // for every band rather than advanced once per band.
        for band in 0..<bandCount {
            var position = initialPosition
            var s1 = snapshot.pointee.z1[band]
            var s2 = snapshot.pointee.z2[band]
            let from = snapshot.pointee.coeffs[band]
            let target = snapshot.pointee.targetCoeffs[band]

            for frame in 0..<frameCount {
                let coefficients: NormalizedBiquadCoeffs
                if rampFrames == 0 || position >= rampFrames {
                    coefficients = target
                } else {
                    coefficients = NormalizedBiquadCoeffs.interpolate(
                        from,
                        target,
                        amount: Float(position) / Float(rampFrames)
                    )
                }

                let x = buffer[frame]
                let y = coefficients.b0 * x + s1
                s1 = coefficients.b1 * x - coefficients.a1 * y + s2
                s2 = coefficients.b2 * x - coefficients.a2 * y
                buffer[frame] = y

                if position < rampFrames {
                    position += 1
                }
            }

            if abs(s1) < 1e-15 { s1 = 0 }
            if abs(s2) < 1e-15 { s2 = 0 }
            snapshot.pointee.z1[band] = s1
            snapshot.pointee.z2[band] = s2
        }

        let frameDelta = UInt32(clamping: frameCount)
        let remaining = rampFrames - initialPosition
        let finalPosition = initialPosition + min(frameDelta, remaining)
        iq_store_snapshot_u32(snapshot.pointee.rampPosition, finalPosition)
    }
}
