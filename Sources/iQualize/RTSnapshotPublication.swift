import Darwin
import IQRingAtomics

/// Lock-free publication state for an opaque, manually managed snapshot.
///
/// The render thread enters before loading `current` and leaves only after the
/// snapshot is no longer referenced. The main actor exchanges a fully
/// initialized snapshot, waits for `readers == 0`, and only then destroys the
/// retired storage. This is a quiescence protocol, not reference counting:
/// the callback never retains, releases, allocates, locks, or deallocates a
/// Swift object.
///
/// Publication has one writer. `AudioEngine` performs outer publication on the
/// main actor, and `BiquadFilterChain` updates are likewise serialized by its
/// owning main-actor path. Reader entry and processing remain safe while a
/// publication is in flight; concurrent publishers would need a separate
/// writer-side serialization boundary.
struct RTSnapshotPublication {
    var current: UnsafeMutableRawPointer?
    var readers: UInt32

    init() {
        current = nil
        readers = 0
    }
}

@inline(__always)
func rtEnter(_ publication: UnsafeMutablePointer<RTSnapshotPublication>) -> UnsafeMutableRawPointer? {
    withUnsafeMutablePointer(to: &publication.pointee.readers) { readers in
        _ = iq_enter_snapshot_reader(readers)
    }
    return withUnsafePointer(to: &publication.pointee.current) { current in
        iq_load_snapshot_ptr(current)
    }
}

@inline(__always)
func rtLeave(_ publication: UnsafeMutablePointer<RTSnapshotPublication>) {
    withUnsafeMutablePointer(to: &publication.pointee.readers) { readers in
        _ = iq_leave_snapshot_reader(readers)
    }
}

@inline(__always)
func publishSnapshot(
    _ publication: UnsafeMutablePointer<RTSnapshotPublication>,
    _ replacement: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    withUnsafeMutablePointer(to: &publication.pointee.current) { current in
        iq_exchange_snapshot_ptr(current, replacement)
    }
}

/// Wait on the publishing thread only. The audio callback never waits.
func waitForSnapshotQuiescence(_ publication: UnsafeMutablePointer<RTSnapshotPublication>) {
    while true {
        let readers = withUnsafePointer(to: &publication.pointee.readers) { pointer in
            iq_load_snapshot_readers(pointer)
        }
        if readers == 0 { return }
        usleep(100)
    }
}
