import Darwin
import XCTest
import IQCaptureProtocol
@testable import iQualize

final class CaptureClientHandshakeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iqualize-handshake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                 withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeHelper(body: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try "#!/bin/sh\nset -e\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func ringHelper(
        layoutVersion: Int? = Int(CaptureLayout.version),
        totalSize: Int = 4160,
        headerSize: Int = CaptureLayout.alignedHeaderSize,
        sampleRate: Double = 48000,
        channels: Int = 2,
        ringCapacityFloats: Int = 1024,
        headerLayoutVersion: Int? = Int(CaptureLayout.version),
        headerSampleRate: Double? = nil,
        headerChannels: Int? = nil,
        headerCapacityFloats: Int? = nil,
        fileSize: Int? = nil
    ) throws -> (helper: URL, shmPath: URL) {
        let shmPath = temporaryDirectory.appendingPathComponent("ring-\(UUID().uuidString).bin")
        var fields = [
            "shmPath": shmPath.path,
            "totalSize": totalSize,
            "headerSize": headerSize,
            "sampleRate": sampleRate,
            "channels": channels,
            "ringCapacityFloats": ringCapacityFloats,
        ] as [String: Any]
        if let layoutVersion {
            fields["layoutVersion"] = layoutVersion
        }
        let handshakeData = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let handshake = String(data: handshakeData, encoding: .utf8)!

        let hVersion = headerLayoutVersion ?? 0
        let hSampleRate = headerSampleRate ?? sampleRate
        let hChannels = headerChannels ?? channels
        let hCapacityFloats = headerCapacityFloats ?? ringCapacityFloats
        let actualFileSize = fileSize ?? totalSize
        let body = #"""
            path='__PATH__'
            cleanup() { rm -f "$path"; }
            trap cleanup EXIT HUP INT TERM
            /usr/bin/python3 - <<'PY'
            import struct
            path = '__PATH__'
            total_size = __TOTAL_SIZE__
            header_size = __HEADER_SIZE__
            capacity = max(__HEADER_CAPACITY__, 0)
            header = struct.pack('<QQdIIIIQQ', 0, 0, __HEADER_SAMPLE_RATE__, __HEADER_CHANNELS__, capacity, __HEADER_VERSION__, 0, 0, 0)
            header = header + bytes(max(header_size - len(header), 0))
            data_size = max(total_size - len(header), 0)
            with open(path, 'wb') as f:
                f.write(header[:total_size])
                if data_size:
                    f.write(bytes(data_size))
            PY
            printf '__HANDSHAKE__\n'
            while read line; do :; done
            """#
            .replacingOccurrences(of: "__PATH__", with: shmPath.path.replacingOccurrences(of: "'", with: "'\\''"))
            .replacingOccurrences(of: "__TOTAL_SIZE__", with: String(actualFileSize))
            .replacingOccurrences(of: "__HEADER_SIZE__", with: String(headerSize))
            .replacingOccurrences(of: "__HEADER_SAMPLE_RATE__", with: String(hSampleRate))
            .replacingOccurrences(of: "__HEADER_CHANNELS__", with: String(hChannels))
            .replacingOccurrences(of: "__HEADER_CAPACITY__", with: String(hCapacityFloats))
            .replacingOccurrences(of: "__HEADER_VERSION__", with: String(hVersion))
            .replacingOccurrences(of: "__HANDSHAKE__", with: handshake.replacingOccurrences(of: "'", with: "'\\''"))
        return (try makeHelper(body: body), shmPath)
    }

    private func assertStartFails(
        helper: URL,
        shmPath: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        verify: (Error) -> Void
    ) {
        let client = CaptureClient(handshakeTimeoutNanoseconds: 5_000_000_000)
        XCTAssertThrowsError(try client.start(helperURL: helper), file: file, line: line) { error in
            verify(error)
        }
        XCTAssertEqual(client.sampleRate, 0, file: file, line: line)
        XCTAssertEqual(client.channels, 0, file: file, line: line)
        if let shmPath {
            // Give the helper's EXIT trap time to remove the file after the
            // client closes stdin / terminates it on failed start. The helper
            // may still be unwinding CoreAudio cleanup when stop() returns.
            for _ in 0..<200 where FileManager.default.fileExists(atPath: shmPath.path) {
                usleep(10_000)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: shmPath.path), file: file, line: line)
        }
    }

    func testHandshakeTimeoutTerminatesAHelperThatNeverWrites() throws {
        let helper = try makeHelper(body: "sleep 30")
        let client = CaptureClient(handshakeTimeoutNanoseconds: 50_000_000)
        let started = DispatchTime.now().uptimeNanoseconds

        XCTAssertThrowsError(try client.start(helperURL: helper)) { error in
            guard case .handshakeTimeout = error as? CaptureClientError else {
                return XCTFail("expected a handshake timeout, got \(error)")
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        XCTAssertLessThan(elapsed, 2_000_000_000)
    }

    func testPartialHandshakeTimesOutAndCleansUpTheHelper() throws {
        let helper = try makeHelper(body: "printf '{\"partial\":'; sleep 30")
        let client = CaptureClient(handshakeTimeoutNanoseconds: 50_000_000)

        XCTAssertThrowsError(try client.start(helperURL: helper)) { error in
            guard case .handshakeTimeout = error as? CaptureClientError else {
                return XCTFail("expected a handshake timeout, got \(error)")
            }
        }
    }

    func testStartupFailureLineDecodesWithStageExitCodeAndOSStatus() throws {
        let failure = CaptureStartupFailure(stage: .processTap, exitCode: 10, osStatus: -1)
        let line = try failure.encodedLine()
        XCTAssertEqual(
            try CaptureStartupFailure.decodeIfPresent(from: Data(line.dropLast())),
            failure
        )
        XCTAssertNil(try CaptureStartupFailure.decodeIfPresent(
            from: Data(#"{"shmPath":"/tmp/legacy"}"#.utf8)
        ))
    }

    func testStructuredHelperFailureIsTypedAndLeavesNoOrphan() throws {
        let shmPath = temporaryDirectory.appendingPathComponent("structured-failure.bin")
        let failure = CaptureStartupFailure(stage: .processTap, exitCode: 10, osStatus: -1)
        let wire = String(data: try failure.encodedLine(), encoding: .utf8)!
            .trimmingCharacters(in: .newlines)
        let body = #"""
            path='__PATH__'
            trap 'rm -f "$path"' EXIT HUP INT TERM
            touch "$path"
            printf '%s\n' '__WIRE__'
            while read line; do :; done
            """#
            .replacingOccurrences(of: "__PATH__", with: shmPath.path)
            .replacingOccurrences(of: "__WIRE__", with: wire)

        assertStartFails(helper: try makeHelper(body: body), shmPath: shmPath) { error in
            guard case .helperStartupFailed(let received) = error as? CaptureClientError else {
                return XCTFail("expected a structured helper failure, got \(error)")
            }
            XCTAssertEqual(received, failure)
        }
    }

    func testMissingMalformedAndUnexpectedHelperExitsRemainDistinct() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing-helper")
        XCTAssertThrowsError(try CaptureClient(handshakeTimeoutNanoseconds: 50_000_000)
            .start(helperURL: missing)) { error in
            guard case .helperMissing = error as? CaptureClientError else {
                return XCTFail("expected missing helper, got \(error)")
            }
        }

        let malformed = try makeHelper(body: "echo '{\"messageType\":\"failure\"}'; sleep 30")
        XCTAssertThrowsError(try CaptureClient(handshakeTimeoutNanoseconds: 5_000_000_000)
            .start(helperURL: malformed)) { error in
            guard case .malformedHandshake = error as? CaptureClientError else {
                return XCTFail("expected malformed handshake, got \(error)")
            }
        }

        let unexpected = try makeHelper(body: "exit 37")
        XCTAssertThrowsError(try CaptureClient(handshakeTimeoutNanoseconds: 5_000_000_000)
            .start(helperURL: unexpected)) { error in
            guard case .unexpectedExit(let status, let signaled) = error as? CaptureClientError else {
                return XCTFail("expected unexpected exit, got \(error)")
            }
            XCTAssertEqual(status, 37)
            XCTAssertFalse(signaled)
        }
    }

    func testCompleteHandshakeWithinTheDeadlineMapsAndStopsCleanly() throws {
        let fixture = try ringHelper()
        let client = CaptureClient(handshakeTimeoutNanoseconds: 5_000_000_000)

        try client.start(helperURL: fixture.helper)
        XCTAssertEqual(client.sampleRate, 48000)
        XCTAssertEqual(client.channels, 2)
        XCTAssertEqual(client.capacityFloats, 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shmPath.path))
        client.stop()
    }

    func testAbsentLayoutVersionIsAcceptedAsLegacyVersionOne() throws {
        let fixture = try ringHelper(layoutVersion: nil, headerLayoutVersion: 0)
        let client = CaptureClient(handshakeTimeoutNanoseconds: 5_000_000_000)

        try client.start(helperURL: fixture.helper)
        XCTAssertEqual(client.sampleRate, 48000)
        XCTAssertEqual(client.channels, 2)
        client.stop()
    }

    func testChannelsZeroFailsBeforeMappingAndLeavesNoOrphan() throws {
        let fixture = try ringHelper(channels: 0, headerChannels: 0)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("channels=0"))
        }
    }

    func testNonPowerOfTwoCapacityFailsBeforeMappingAndLeavesNoOrphan() throws {
        let fixture = try ringHelper(totalSize: 4164, ringCapacityFloats: 1025, headerCapacityFloats: 1025)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("not a power of two"))
        }
    }

    func testInconsistentHandshakeGeometryFailsBeforeMappingAndLeavesNoOrphan() throws {
        let fixture = try ringHelper(totalSize: 4096)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("totalSize=4096"))
        }
    }

    func testUnsupportedLayoutVersionFailsBeforeMappingAndLeavesNoOrphan() throws {
        let fixture = try ringHelper(layoutVersion: 2, headerLayoutVersion: 2)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.unsupportedLayoutVersion(let received, let supported) = error else {
                return XCTFail("expected unsupported version, got \(error)")
            }
            XCTAssertEqual(received, 2)
            XCTAssertEqual(supported, CaptureLayout.version)
        }
    }

    func testBackingFileSizeMismatchFailsBeforeMappingAndLeavesNoOrphan() throws {
        let fixture = try ringHelper(fileSize: 4096)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("fileSize=4096"))
        }
    }

    func testMappedHeaderMismatchFailsAndUnlinksMappingFile() throws {
        let fixture = try ringHelper(headerChannels: 1)
        assertStartFails(helper: fixture.helper, shmPath: fixture.shmPath) { error in
            guard case CaptureProtocolError.mappedHeaderMismatch(let detail) = error else {
                return XCTFail("expected mapped header mismatch, got \(error)")
            }
            XCTAssertTrue(detail.contains("channels"))
        }
    }

    func testRejectsInvalidSampleRate() {
        XCTAssertThrowsError(try CaptureGeometry(layoutVersion: CaptureLayout.version,
                                                totalSize: 4160,
                                                headerSize: CaptureLayout.alignedHeaderSize,
                                                sampleRate: .infinity,
                                                channels: 2,
                                                capacityFloats: 1024).validate()) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("sampleRate"))
        }
    }

    func testRejectsCapacityNotDivisibleByChannels() {
        XCTAssertThrowsError(try CaptureGeometry(layoutVersion: CaptureLayout.version,
                                                totalSize: 4160,
                                                headerSize: CaptureLayout.alignedHeaderSize,
                                                sampleRate: 48000,
                                                channels: 3,
                                                capacityFloats: 1024).validate()) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("not divisible"))
        }
    }

    func testRejectsUnalignedHeaderSize() {
        XCTAssertThrowsError(try CaptureGeometry(layoutVersion: CaptureLayout.version,
                                                totalSize: 4156,
                                                headerSize: 60,
                                                sampleRate: 48000,
                                                channels: 2,
                                                capacityFloats: 1024).validate()) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("headerSize=60"))
        }
    }

    func testRejectsOverflowingTotalSize() {
        let overflowingCapacity = Int(1) << (Int.bitWidth - 2)
        XCTAssertThrowsError(try CaptureGeometry(layoutVersion: CaptureLayout.version,
                                                totalSize: Int.max,
                                                headerSize: CaptureLayout.alignedHeaderSize,
                                                sampleRate: 48000,
                                                channels: 1,
                                                capacityFloats: overflowingCapacity).validate()) { error in
            guard case CaptureProtocolError.invalidGeometry(let detail) = error else {
                return XCTFail("expected invalid geometry, got \(error)")
            }
            XCTAssertTrue(detail.contains("overflow"))
        }
    }

    func testSharedHeaderLayoutOffsetsRemainStable() {
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.writeHead), 0)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.readHead), 8)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.sampleRate), 16)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.channels), 24)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.capacityFloats), 28)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.layoutVersion), 32)
        XCTAssertEqual(MemoryLayout<SharedHeader>.stride, 56)
        XCTAssertEqual(CaptureLayout.alignedHeaderSize, 64)
    }
}
