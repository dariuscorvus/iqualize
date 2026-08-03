import XCTest
import IQCaptureProtocol

/// Locks the shared-memory ABI (#175). SharedHeader is mapped by two
/// separately compiled binaries, and both derive atomic field pointers from
/// MemoryLayout.offset(of:) — a silent layout change would corrupt memory,
/// so every offset and the stride are pinned here.
final class CaptureLayoutTests: XCTestCase {

    func testSharedHeaderFieldOffsetsAreStable() {
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.writeHead), 0)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.readHead), 8)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.sampleRate), 16)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.channels), 24)
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.capacityFloats), 28)
        // layoutVersion occupies the first four bytes of what legacy builds
        // wrote as zero padding — a legacy header therefore reads version 0.
        XCTAssertEqual(MemoryLayout<SharedHeader>.offset(of: \.layoutVersion), 32)
    }

    func testSharedHeaderStrideMatchesLegacyLayout() {
        // Legacy struct: 2×UInt64 + Float64 + 2×UInt32 + (UInt64, UInt64, UInt32)
        // = 56 bytes payload, 8-byte aligned → stride 56. The data offset is
        // separately padded to 64 bytes by CaptureLayout.alignedHeaderSize.
        XCTAssertEqual(MemoryLayout<SharedHeader>.stride, 56)
        XCTAssertEqual(MemoryLayout<SharedHeader>.alignment, 8)
    }

    func testAlignedHeaderSizeIsCacheLinePadded() {
        XCTAssertEqual(CaptureLayout.alignedHeaderSize, 64)
        XCTAssertEqual(CaptureLayout.alignedHeaderSize % 64, 0)
    }

    func testDefaultInitZeroesReservedFieldsAndSetsCurrentVersion() {
        let header = SharedHeader()
        XCTAssertEqual(header.layoutVersion, CaptureLayout.version)
        XCTAssertEqual(header._reserved0, 0)
        XCTAssertEqual(header._reserved1, 0)
        XCTAssertEqual(header._reserved2, 0)
    }

    // MARK: - CaptureGeometry.validate()

    private func geometry(layoutVersion: UInt32? = 1, totalSize: Int = 4160,
                          headerSize: Int = 64, sampleRate: Float64 = 48000,
                          channels: Int = 2, capacityFloats: Int = 1024) -> CaptureGeometry {
        CaptureGeometry(layoutVersion: layoutVersion, totalSize: totalSize,
                        headerSize: headerSize, sampleRate: sampleRate,
                        channels: channels, capacityFloats: capacityFloats)
    }

    func testValidGeometryPasses() throws {
        try geometry().validate()
    }

    func testAbsentVersionDefaultsToOne() throws {
        try geometry(layoutVersion: nil).validate()
    }

    func testUnknownVersionThrows() {
        XCTAssertThrowsError(try geometry(layoutVersion: 2).validate()) { error in
            XCTAssertEqual(error as? CaptureProtocolError,
                           .unsupportedLayoutVersion(received: 2, supported: 1))
        }
    }

    func testZeroChannelsThrows() {
        XCTAssertThrowsError(try geometry(channels: 0).validate())
    }

    func testNonPowerOfTwoCapacityThrows() {
        XCTAssertThrowsError(try geometry(totalSize: 64 + 1000 * 4,
                                          capacityFloats: 1000).validate())
    }

    func testZeroCapacityThrows() {
        XCTAssertThrowsError(try geometry(totalSize: 64, capacityFloats: 0).validate())
    }

    func testCapacityNotDivisibleByChannelsThrows() {
        // 8 floats, 3 channels: pow2 but not whole frames.
        XCTAssertThrowsError(try geometry(totalSize: 64 + 8 * 4, channels: 3,
                                          capacityFloats: 8).validate())
    }

    func testWrongHeaderSizeThrows() {
        XCTAssertThrowsError(try geometry(totalSize: 128 + 1024 * 4,
                                          headerSize: 128).validate())
    }

    func testInconsistentTotalSizeThrows() {
        XCTAssertThrowsError(try geometry(totalSize: 4096).validate())
    }

    func testNonPositiveSampleRateThrows() {
        XCTAssertThrowsError(try geometry(sampleRate: 0).validate())
        XCTAssertThrowsError(try geometry(sampleRate: -48000).validate())
        XCTAssertThrowsError(try geometry(sampleRate: .nan).validate())
    }

    // MARK: - Mapped-header cross-check

    func testMatchingMappedHeaderPasses() throws {
        let header = SharedHeader(sampleRate: 48000, channels: 2,
                                  capacityFloats: 1024, layoutVersion: 1)
        try geometry().validate(against: header)
    }

    func testLegacyZeroVersionHeaderTreatedAsOne() throws {
        let header = SharedHeader(sampleRate: 48000, channels: 2,
                                  capacityFloats: 1024, layoutVersion: 0)
        try geometry().validate(against: header)
    }

    func testMappedHeaderChannelMismatchThrows() {
        let header = SharedHeader(sampleRate: 48000, channels: 4,
                                  capacityFloats: 1024, layoutVersion: 1)
        XCTAssertThrowsError(try geometry().validate(against: header)) { error in
            guard case .mappedHeaderMismatch = error as? CaptureProtocolError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
