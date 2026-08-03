// IQCaptureProtocol — the shared-memory capture contract between the main
// iQualize app (consumer, Sources/iQualize/CaptureClient.swift) and the
// iQualizeCapture helper (producer, Sources/iQualizeCapture/main.swift).
//
// This target is the single source of truth for the ring layout. Both
// binaries ship in one bundle, but a stale helper left behind by a partial
// install must fail diagnosably instead of corrupting memory (#175), so the
// header and the stdout handshake both carry a layout version and every
// geometry value is validated before it reaches mmap or index arithmetic.

import Foundation

// MARK: - Startup-failure message

/// The bounded line-protocol envelope used when the helper cannot reach its
/// readiness handshake. This deliberately carries only machine-readable
/// fields. Presentation code can classify the stage/code and inspect the raw
/// OSStatus without inheriting a user-facing string from the helper.
public struct CaptureStartupFailure: Codable, Equatable, Sendable {
    public static let messageType = "failure"
    public static let maxEncodedLineBytes = 512
    /// The legacy handshake has more fields than a failure line. Keep its
    /// transport bound separate so adding a longer temporary path does not
    /// turn an otherwise valid handshake into a malformed failure.
    public static let maxLineBytes = 4096

    public enum Stage: String, Codable, Sendable {
        case environment
        case processTap
        case tapFormat
        case sharedMemory
        case aggregateDevice
        case ioProc
    }

    public let stage: Stage
    /// Stable helper exit code. These are the existing helper's pre-handshake
    /// exit codes, kept on the wire so older clients can still identify the
    /// broad failure even when they do not decode this message.
    public let exitCode: Int32
    /// A Core Audio OSStatus when the failing operation returned one.
    public let osStatus: Int32?

    public init(stage: Stage, exitCode: Int32, osStatus: Int32? = nil) {
        self.stage = stage
        self.exitCode = exitCode
        self.osStatus = osStatus
    }

    private enum CodingKeys: String, CodingKey {
        case messageType
        case stage
        case exitCode
        case osStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .messageType) == Self.messageType else {
            throw CaptureStartupFailureDecodeError.invalidEnvelope
        }
        guard let stage = try? container.decode(Stage.self, forKey: .stage) else {
            throw CaptureStartupFailureDecodeError.invalidEnvelope
        }
        self.stage = stage
        self.exitCode = try container.decode(Int32.self, forKey: .exitCode)
        self.osStatus = try container.decodeIfPresent(Int32.self, forKey: .osStatus)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.messageType, forKey: .messageType)
        try container.encode(stage, forKey: .stage)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(osStatus, forKey: .osStatus)
    }

    /// Decodes a startup-failure line when the discriminator is present.
    /// Returns nil for a legacy handshake line, which has no `type` field.
    public static func decodeIfPresent(from data: Data) throws -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureStartupFailureDecodeError.invalidJSON
        }
        guard object["messageType"] != nil else { return nil }
        guard data.count <= Self.maxEncodedLineBytes else {
            throw CaptureStartupFailureDecodeError.lineTooLong
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Encodes a single newline-terminated, size-bounded protocol line.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        guard data.count <= Self.maxEncodedLineBytes else {
            throw CaptureStartupFailureDecodeError.lineTooLong
        }
        return data
    }
}

public enum CaptureStartupFailureDecodeError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidEnvelope
    case lineTooLong
}

// MARK: - Shared-memory header

/// Header at the start of the capture ring's shared-memory region.
///
/// Layout is ABI between two separately compiled binaries: `@frozen`, fixed
/// field order, and covered by CaptureLayoutTests asserting every offset and
/// the stride. The writer publishes `writeHead` with a release store; the
/// reader loads it with acquire (IQRingAtomics) — both sides derive their
/// atomic field pointers from `MemoryLayout.offset(of:)`, so the offsets of
/// `writeHead` and `readHead` must never move.
@frozen
public struct SharedHeader {
    public var writeHead: UInt64
    public var readHead: UInt64
    public var sampleRate: Float64
    public var channels: UInt32
    public var capacityFloats: UInt32
    /// Layout version 1. Occupies the first four bytes of what version-1-era
    /// builds wrote as zero padding, so a legacy header reads as 0 — treated
    /// as version 1 (the padding was always zeroed).
    public var layoutVersion: UInt32
    public var _reserved0: UInt32
    public var _reserved1: UInt64
    public var _reserved2: UInt64

    public init(writeHead: UInt64 = 0,
                readHead: UInt64 = 0,
                sampleRate: Float64 = 0,
                channels: UInt32 = 0,
                capacityFloats: UInt32 = 0,
                layoutVersion: UInt32 = CaptureLayout.version) {
        self.writeHead = writeHead
        self.readHead = readHead
        self.sampleRate = sampleRate
        self.channels = channels
        self.capacityFloats = capacityFloats
        self.layoutVersion = layoutVersion
        self._reserved0 = 0
        self._reserved1 = 0
        self._reserved2 = 0
    }
}

public enum CaptureLayout {
    /// Current shared-memory layout version. An absent version — in the
    /// handshake or as a zeroed header field — means a legacy version-1 peer.
    public static let version: UInt32 = 1

    /// Header size padded to a 64-byte boundary so the sample data starts
    /// cache-line aligned. Both sides must compute the data offset this way.
    public static var alignedHeaderSize: Int {
        (MemoryLayout<SharedHeader>.stride + 63) & ~63
    }
}

// MARK: - Handshake validation

public enum CaptureProtocolError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedLayoutVersion(received: UInt32, supported: UInt32)
    case invalidGeometry(String)
    case mappedHeaderMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLayoutVersion(let received, let supported):
            return "Capture helper speaks layout version \(received); this app supports \(supported). The helper binary is likely stale — reinstall the app."
        case .invalidGeometry(let detail):
            return "Capture helper sent invalid ring geometry: \(detail)"
        case .mappedHeaderMismatch(let detail):
            return "Capture ring header disagrees with the handshake: \(detail)"
        }
    }
}

/// The geometry a helper reports in its handshake line, validated as a unit
/// before any of it is passed to mmap, bindMemory, a mask computation, or a
/// division.
public struct CaptureGeometry: Equatable, Sendable {
    public var layoutVersion: UInt32
    public var totalSize: Int
    public var headerSize: Int
    public var sampleRate: Float64
    public var channels: Int
    public var capacityFloats: Int

    /// `layoutVersion` nil means the field was absent — a legacy version-1
    /// helper from before the field existed.
    public init(layoutVersion: UInt32?, totalSize: Int, headerSize: Int,
                sampleRate: Float64, channels: Int, capacityFloats: Int) {
        self.layoutVersion = layoutVersion ?? 1
        self.totalSize = totalSize
        self.headerSize = headerSize
        self.sampleRate = sampleRate
        self.channels = channels
        self.capacityFloats = capacityFloats
    }

    /// Throws `CaptureProtocolError` on the first violated invariant.
    /// Every check here guards a specific downstream hazard:
    /// - version: struct layout skew between binaries
    /// - channels > 0: divisor in capacityFrames
    /// - capacityFloats power of two: `mask = capacityFloats - 1` ring indexing
    /// - divisibility: whole frames only
    /// - headerSize: data-pointer offset both sides must agree on
    /// - totalSize: the mmap length must cover header + data exactly
    public func validate() throws {
        guard layoutVersion == CaptureLayout.version else {
            throw CaptureProtocolError.unsupportedLayoutVersion(
                received: layoutVersion, supported: CaptureLayout.version)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw CaptureProtocolError.invalidGeometry("sampleRate=\(sampleRate)")
        }
        guard channels > 0 else {
            throw CaptureProtocolError.invalidGeometry("channels=\(channels)")
        }
        guard capacityFloats > 0, capacityFloats & (capacityFloats - 1) == 0 else {
            throw CaptureProtocolError.invalidGeometry(
                "ringCapacityFloats=\(capacityFloats) is not a power of two")
        }
        guard capacityFloats % channels == 0 else {
            throw CaptureProtocolError.invalidGeometry(
                "ringCapacityFloats=\(capacityFloats) not divisible by channels=\(channels)")
        }
        guard headerSize == CaptureLayout.alignedHeaderSize else {
            throw CaptureProtocolError.invalidGeometry(
                "headerSize=\(headerSize), expected \(CaptureLayout.alignedHeaderSize)")
        }
        let dataByteResult = capacityFloats.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !dataByteResult.overflow else {
            throw CaptureProtocolError.invalidGeometry(
                "capacityFloats=\(capacityFloats) overflows the data byte count")
        }
        let totalSizeResult = headerSize.addingReportingOverflow(dataByteResult.partialValue)
        guard !totalSizeResult.overflow, totalSize == totalSizeResult.partialValue else {
            throw CaptureProtocolError.invalidGeometry(
                "totalSize=\(totalSize), expected \(totalSizeResult.partialValue)")
        }
    }

    /// Cross-checks the mapped header against the validated handshake. The
    /// two describe the same region through different channels (shared memory
    /// vs stdout JSON), so any disagreement means the peer is not the binary
    /// that wrote this handshake — refuse rather than guess. A zero
    /// `layoutVersion` in the header is the legacy-padding encoding of 1.
    public func validate(against header: SharedHeader) throws {
        let headerVersion = header.layoutVersion == 0 ? 1 : header.layoutVersion
        guard headerVersion == layoutVersion else {
            throw CaptureProtocolError.mappedHeaderMismatch(
                "header layoutVersion=\(headerVersion), handshake=\(layoutVersion)")
        }
        guard Int(header.channels) == channels else {
            throw CaptureProtocolError.mappedHeaderMismatch(
                "header channels=\(header.channels), handshake=\(channels)")
        }
        guard Int(header.capacityFloats) == capacityFloats else {
            throw CaptureProtocolError.mappedHeaderMismatch(
                "header capacityFloats=\(header.capacityFloats), handshake=\(capacityFloats)")
        }
        guard header.sampleRate == sampleRate else {
            throw CaptureProtocolError.mappedHeaderMismatch(
                "header sampleRate=\(header.sampleRate), handshake=\(sampleRate)")
        }
    }
}
