import XCTest
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
        let url = temporaryDirectory.appendingPathComponent("helper.sh")
        try "#!/bin/sh\nset -e\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
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

    func testCompleteHandshakeWithinTheDeadlineMapsAndStopsCleanly() throws {
        let helper = try makeHelper(body: #"""
            path="${TMPDIR:-/tmp}/iqualize-test-shm-$$"
            dd if=/dev/zero of="$path" bs=4096 count=1 2>/dev/null
            sleep 0.05
            printf '{"shmPath":"%s","totalSize":4096,"headerSize":64,"sampleRate":48000,"channels":2,"ringCapacityFloats":1024}\n' "$path"
            while read line; do :; done
            """#)
        let client = CaptureClient(handshakeTimeoutNanoseconds: 500_000_000)

        try client.start(helperURL: helper)
        XCTAssertEqual(client.sampleRate, 48000)
        XCTAssertEqual(client.channels, 2)
        client.stop()
    }
}
