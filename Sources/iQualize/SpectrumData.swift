import Foundation
import IQRingAtomics

/// Lock-free single-writer/single-reader magnitude snapshots for audio→UI transfer.
/// The audio writer, UI reader, and atomic handoff each own one of three slots.
///
/// A second publication must never overwrite the slot the UI is still copying.
/// Acquire/release exchanges transfer slot ownership as well as publishing data;
/// an atomic index alone would not make a two-buffer implementation safe.
final class SpectrumData: @unchecked Sendable {
    static let binCount = 128

    private let buffers: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)
    private let count: Int  // binCount * 2 (magnitudes + peaks)
    private let handoff = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private static let dirty: UInt64 = 4
    private static let indexMask: UInt64 = 3
    private var writerIndex: UInt64 = 2 // audio-thread only
    private var readerIndex: UInt64 = 0 // UI-thread only

    init() {
        count = Self.binCount * 2
        buffers.0 = .allocate(capacity: count)
        buffers.0.initialize(repeating: -90.0, count: count)
        buffers.1 = .allocate(capacity: count)
        buffers.1.initialize(repeating: -90.0, count: count)
        buffers.2 = .allocate(capacity: count)
        buffers.2.initialize(repeating: -90.0, count: count)
        handoff.initialize(to: 1)
    }

    deinit {
        buffers.0.deallocate()
        buffers.1.deallocate()
        buffers.2.deallocate()
        handoff.deallocate()
    }

    private func buffer(at index: UInt64) -> UnsafeMutablePointer<Float> {
        switch index {
        case 0: buffers.0
        case 1: buffers.1
        default: buffers.2
        }
    }

    /// Called from audio thread.
    func write(_ magnitudes: UnsafePointer<Float>, peaks: UnsafePointer<Float>) {
        let dest = buffer(at: writerIndex)
        dest.update(from: magnitudes, count: Self.binCount)
        dest.advanced(by: Self.binCount).update(from: peaks, count: Self.binCount)
        writerIndex = iq_exchange_acq_rel_u64(handoff, writerIndex | Self.dirty) & Self.indexMask
    }

    /// Called from UI thread. Copies current magnitudes and peaks into caller-provided buffers.
    func read(_ magnitudes: UnsafeMutablePointer<Float>, peaks: UnsafeMutablePointer<Float>) {
        if iq_load_relaxed_u64(handoff) & Self.dirty != 0 {
            readerIndex = iq_exchange_acq_rel_u64(handoff, readerIndex) & Self.indexMask
        }
        let src = buffer(at: readerIndex)
        magnitudes.update(from: src, count: Self.binCount)
        peaks.update(from: src.advanced(by: Self.binCount), count: Self.binCount)
    }
}
