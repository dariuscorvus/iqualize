import Darwin
import Foundation

/// Why a frame couldn't be read whole. The point of the distinction is that a caller must
/// never mistake a truncated response for a connection failure — see `IQClient.send`.
public enum FrameReadError: Error, Equatable, CustomStringConvertible {
    /// EOF or a read error before a single byte arrived. The peer hung up with nothing to say.
    case noData
    /// Bytes arrived but the stream ended before the newline delimiter. The frame is a prefix
    /// of a real frame; decoding it would fail in a way that looks like corruption.
    case incomplete(bytesRead: Int)
    /// `maxBytes` was reached without a delimiter. A bounded cap, not an unbounded read, so a
    /// hostile or wedged writer can't exhaust memory.
    case tooLarge(limit: Int)

    public var description: String {
        switch self {
        case .noData: return "connection closed before any data was received"
        case .incomplete(let n): return "connection closed after \(n) bytes with no frame delimiter"
        case .tooLarge(let limit): return "frame exceeded the \(limit)-byte limit"
        }
    }
}

/// Small raw-socket helpers shared by the app's `CLIControlServer` and the CLI's
/// `IQClient` — both sides speak the same newline-delimited-JSON-over-AF_UNIX protocol.
public enum UnixSocketIO {
    /// Cap on a single frame. Generous — the largest real payload today is the OPRA catalog
    /// search at ~130 KB — but bounded, so a peer that never sends a newline can't make us
    /// allocate without limit.
    public static let maxFrameBytes = 32 * 1024 * 1024

    /// Fills a `sockaddr_un` for `path`, or `nil` if it doesn't fit in `sun_path`
    /// (a fixed 104-byte buffer on Darwin).
    public static func makeSockaddrUn(path: String) -> sockaddr_un? {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            for i in 0..<pathBytes.count { buffer[i] = pathBytes[i] }
            buffer[pathBytes.count] = 0
        }
        return addr
    }

    /// Reads one newline-delimited frame from `fd`, excluding the delimiter.
    ///
    /// Reads in chunks rather than a byte at a time; a 127 KB response would otherwise cost
    /// 127k `read(2)` calls. Any bytes that arrive after the delimiter are discarded, which is
    /// safe because this protocol is one frame per connection on both sides — the server reads
    /// a request and closes, the client reads a response and closes.
    ///
    /// Throws `FrameReadError` rather than returning a prefix, so truncation is never
    /// mistaken for a complete frame.
    public static func readFrame(fd: Int32, maxBytes: Int = maxFrameBytes) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, min(raw.count, maxBytes - data.count + 1))
            }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }

            if let newlineIndex = chunk[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: chunk[0..<newlineIndex])
                guard data.count <= maxBytes else { throw FrameReadError.tooLarge(limit: maxBytes) }
                return data
            }
            data.append(contentsOf: chunk[0..<n])
            if data.count > maxBytes { throw FrameReadError.tooLarge(limit: maxBytes) }
        }

        throw data.isEmpty ? FrameReadError.noData : FrameReadError.incomplete(bytesRead: data.count)
    }

    /// Writes `payload` followed by a newline delimiter. Returns whether the full frame
    /// was written.
    ///
    /// Loops until every byte is out. A single `write(2)` on a `SOCK_STREAM` Unix socket
    /// returns short as soon as the 8 KiB send buffer fills, and `EINTR` is not a failure —
    /// treating either as one was the cause of #167.
    @discardableResult
    public static func writeFrame(_ payload: Data, fd: Int32) -> Bool {
        var data = payload
        data.append(0x0A)
        return data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let n = write(fd, pointer, remaining)
                if n > 0 {
                    remaining -= n
                    pointer = pointer.advanced(by: n)
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
