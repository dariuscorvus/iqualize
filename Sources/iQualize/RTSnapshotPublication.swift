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
        _ = iq_fetch_add_acq_rel_u32(readers, 1)
    }
    return withUnsafePointer(to: &publication.pointee.current) { current in
        iq_load_acquire_ptr(current)
    }
}

@inline(__always)
func rtLeave(_ publication: UnsafeMutablePointer<RTSnapshotPublication>) {
    withUnsafeMutablePointer(to: &publication.pointee.readers) { readers in
        _ = iq_fetch_sub_release_u32(readers, 1)
    }
}

@inline(__always)
func publishSnapshot(
    _ publication: UnsafeMutablePointer<RTSnapshotPublication>,
    _ replacement: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    withUnsafeMutablePointer(to: &publication.pointee.current) { current in
        iq_exchange_acq_rel_ptr(current, replacement)
    }
}

/// Wait on the publishing thread only. The audio callback never waits.
func waitForSnapshotQuiescence(_ publication: UnsafeMutablePointer<RTSnapshotPublication>) {
    while true {
        let readers = withUnsafePointer(to: &publication.pointee.readers) { pointer in
            iq_load_acquire_u32(pointer)
        }
        if readers == 0 { return }
        usleep(100)
    }
}
