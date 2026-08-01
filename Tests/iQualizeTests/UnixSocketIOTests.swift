import Darwin
import Foundation
import IQControlProtocol
import XCTest

/// Bumped by the SIGUSR1 handler in the EINTR test. A C function pointer can't capture
/// context, so the counter has to live at file scope.
private nonisolated(unsafe) var interruptCount = 0

/// Regression coverage for #167: a frame larger than the socket's send buffer must be
/// delivered whole, and a frame that isn't must be reported as truncation rather than
/// silently handed back as a prefix.
final class UnixSocketIOTests: XCTestCase {
    /// Cross-thread scratch space. The writer runs on its own thread so it can block while
    /// the test's thread drains the socket; a lock-guarded box is the least ceremony that
    /// satisfies strict concurrency.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ value: T) { storage = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    /// A connected `SOCK_STREAM` pair, closed at the end of the test.
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        try XCTSkipIf(result != 0, "socketpair failed: errno \(errno)")
        let (a, b) = (fds[0], fds[1])
        addTeardownBlock { close(a); close(b) }
        return (a, b)
    }

    /// Writes `payload` on a background thread — with a payload larger than the 8 KiB send
    /// buffer, `writeFrame` blocks until the reader drains it, so it can't run inline.
    private func writeInBackground(
        _ payload: Data, fd: Int32, ignoreSIGPIPE: Bool = false
    ) -> (done: XCTestExpectation, succeeded: Box<Bool>) {
        let done = expectation(description: "write finished")
        let succeeded = Box(false)
        Thread.detachNewThread {
            let previous = ignoreSIGPIPE ? signal(SIGPIPE, SIG_IGN) : nil
            succeeded.value = UnixSocketIO.writeFrame(payload, fd: fd)
            if let previous { signal(SIGPIPE, previous) }
            done.fulfill()
        }
        return (done, succeeded)
    }

    // MARK: - Round-trip

    // The bug: a single write(2) on an 8 KiB socket buffer returns short, and the old code
    // called that a failure. A megabyte has to cross in many writes and come back intact.
    func testRoundTripsPayloadLargerThanOneMegabyte() throws {
        let (a, b) = try makeSocketPair()
        // Byte values avoid 0x0A: the delimiter can't appear inside a frame. JSON
        // encoding never emits a raw newline, so the real protocol never does either.
        let payload = Data((0..<1_500_000).map { UInt8(0x20 &+ ($0 % 200)) })
        let writer = writeInBackground(payload, fd: a)

        let received = try UnixSocketIO.readFrame(fd: b)
        wait(for: [writer.done], timeout: 30)

        XCTAssertTrue(writer.succeeded.value)
        XCTAssertEqual(received.count, payload.count)
        XCTAssertEqual(received, payload)
    }

    // A payload the size of the failing `presets opra search "audio"` response — the exact
    // case that used to be truncated at the old 64 KiB read cap.
    func testRoundTripsPayloadLargerThanTheOldSixtyFourKilobyteCap() throws {
        let (a, b) = try makeSocketPair()
        let payload = Data(repeating: 0x7B, count: 127 * 1024)
        let writer = writeInBackground(payload, fd: a)

        let received = try UnixSocketIO.readFrame(fd: b)
        wait(for: [writer.done], timeout: 30)

        XCTAssertTrue(writer.succeeded.value)
        XCTAssertEqual(received, payload)
    }

    // A payload smaller than the send buffer still round-trips, and the delimiter is stripped.
    func testRoundTripsSmallPayload() throws {
        let (a, b) = try makeSocketPair()
        let payload = Data("{\"ok\":true}".utf8)
        XCTAssertTrue(UnixSocketIO.writeFrame(payload, fd: a))
        XCTAssertEqual(try UnixSocketIO.readFrame(fd: b), payload)
    }

    // An empty payload is a zero-length frame, not EOF.
    func testRoundTripsEmptyPayload() throws {
        let (a, b) = try makeSocketPair()
        XCTAssertTrue(UnixSocketIO.writeFrame(Data(), fd: a))
        XCTAssertEqual(try UnixSocketIO.readFrame(fd: b), Data())
    }

    // MARK: - EINTR

    // A signal delivered mid-write makes write(2) return -1/EINTR. That's not a failure; the
    // loop has to retry. The signal has to be aimed at the writing thread with pthread_kill —
    // kill(2) lets the kernel deliver to any thread with the signal unblocked, and it does not
    // reliably pick the one parked in the write. The handler is installed without SA_RESTART;
    // with it the kernel restarts the syscall transparently and there is nothing to test.
    func testWriteInterruptedBySignalCompletes() throws {
        let (a, b) = try makeSocketPair()
        let payload = Data((0..<800_000).map { UInt8(0x20 &+ ($0 % 200)) })

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in interruptCount &+= 1 }
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        var previous = sigaction()
        XCTAssertEqual(sigaction(SIGUSR1, &action, &previous), 0)
        let saved = Box(previous)
        addTeardownBlock { var p = saved.value; sigaction(SIGUSR1, &p, nil) }
        interruptCount = 0

        let writerThread = Box<pthread_t?>(nil)
        let done = expectation(description: "write finished")
        let succeeded = Box(false)
        Thread.detachNewThread {
            writerThread.value = pthread_self()
            succeeded.value = UnixSocketIO.writeFrame(payload, fd: a)
            writerThread.value = nil
            done.fulfill()
        }

        let stop = Box(false)
        Thread.detachNewThread {
            for _ in 0..<20_000 {
                if stop.value { break }
                if let target = writerThread.value { pthread_kill(target, SIGUSR1) }
                usleep(100)
            }
        }

        let received = try UnixSocketIO.readFrame(fd: b)
        wait(for: [done], timeout: 30)
        stop.value = true

        XCTAssertGreaterThan(interruptCount, 0, "the writer was never actually signalled")
        XCTAssertTrue(succeeded.value, "an EINTR-interrupted write must complete, not fail")
        XCTAssertEqual(received, payload)
    }

    // A real failure is still a failure: writing to a socket whose peer is gone returns
    // false rather than looping forever.
    func testWriteToClosedPeerFails() throws {
        let (a, b) = try makeSocketPair()
        let previous = signal(SIGPIPE, SIG_IGN)
        addTeardownBlock { signal(SIGPIPE, previous) }
        close(b)
        XCTAssertFalse(UnixSocketIO.writeFrame(Data(repeating: 0x41, count: 64 * 1024), fd: a))
    }

    // MARK: - Truncation

    // Bytes then EOF with no delimiter used to come back as a valid-looking partial frame.
    // Now it's an error the caller can act on.
    func testTruncatedFrameThrowsIncomplete() throws {
        let (a, b) = try makeSocketPair()
        let partial = Data("{\"ok\":tr".utf8)
        _ = partial.withUnsafeBytes { write(a, $0.baseAddress, $0.count) }
        close(a)

        XCTAssertThrowsError(try UnixSocketIO.readFrame(fd: b)) { error in
            XCTAssertEqual(error as? FrameReadError, .incomplete(bytesRead: partial.count))
        }
    }

    // EOF with nothing at all is distinct from a truncated frame — it's the only case that
    // should make the CLI conclude the app isn't there.
    func testEmptyStreamThrowsNoData() throws {
        let (a, b) = try makeSocketPair()
        close(a)
        XCTAssertThrowsError(try UnixSocketIO.readFrame(fd: b)) { error in
            XCTAssertEqual(error as? FrameReadError, .noData)
        }
    }

    // The cap is bounded on purpose: a peer that never sends a delimiter must not be able to
    // make the reader allocate without limit.
    func testFrameOverTheCapThrowsTooLarge() throws {
        let (a, b) = try makeSocketPair()
        let limit = 32 * 1024
        let writer = writeInBackground(
            Data(repeating: 0x41, count: limit * 4), fd: a, ignoreSIGPIPE: true)

        XCTAssertThrowsError(try UnixSocketIO.readFrame(fd: b, maxBytes: limit)) { error in
            XCTAssertEqual(error as? FrameReadError, .tooLarge(limit: limit))
        }
        close(b)
        wait(for: [writer.done], timeout: 30)
    }

    // A frame exactly at the cap is legal; the limit is inclusive.
    func testFrameExactlyAtTheCapSucceeds() throws {
        let (a, b) = try makeSocketPair()
        let limit = 32 * 1024
        let payload = Data(repeating: 0x41, count: limit)
        let writer = writeInBackground(payload, fd: a)

        XCTAssertEqual(try UnixSocketIO.readFrame(fd: b, maxBytes: limit), payload)
        wait(for: [writer.done], timeout: 30)
        XCTAssertTrue(writer.succeeded.value)
    }
}
