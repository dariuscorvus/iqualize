import Darwin
import Foundation

/// Small raw-socket helpers shared by the app's `CLIControlServer` and the CLI's
/// `IQClient` — both sides speak the same newline-delimited-JSON-over-AF_UNIX protocol.
public enum UnixSocketIO {
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

    /// Reads bytes from `fd` until a newline (exclusive) or EOF/error. `nil` if nothing
    /// was read before EOF/error.
    public static func readLine(fd: Int32, maxBytes: Int = 64 * 1024) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maxBytes {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    /// Writes `payload` followed by a newline delimiter. Returns whether the full frame
    /// was written.
    @discardableResult
    public static func writeFrame(_ payload: Data, fd: Int32) -> Bool {
        var data = payload
        data.append(0x0A)
        let written = data.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, raw.count)
        }
        return written == data.count
    }
}
