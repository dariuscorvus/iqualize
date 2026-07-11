import AVFAudio
import Foundation

// MARK: - Filter Type

enum FilterType: String, Codable, CaseIterable, Equatable, Sendable {
    case parametric
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch

    var displayName: String {
        switch self {
        case .parametric: return "Bell"
        case .lowShelf:   return "Lo Shelf"
        case .highShelf:  return "Hi Shelf"
        case .lowPass:    return "Lo Pass"
        case .highPass:   return "Hi Pass"
        case .bandPass:   return "Band Pass"
        case .notch:      return "Notch"
        }
    }

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: return .parametric
        case .lowShelf:   return .lowShelf
        case .highShelf:  return .highShelf
        case .lowPass:    return .lowPass
        case .highPass:   return .highPass
        case .bandPass:   return .bandPass
        case .notch:      return .bandStop
        }
    }
}

// MARK: - EQ Channel

enum EQChannel: String, Codable, Sendable {
    case left
    case right
}

// MARK: - EQ Band

struct EQBand: Codable, Equatable, Sendable, Identifiable {
    var frequency: Float   // Hz (20...20000)
    var gain: Float        // dB (-12...+12)
    var bandwidth: Float   // octaves, default 1.0
    var filterType: FilterType
    var muted: Bool
    /// In-memory identity for SwiftUI / animation. Not persisted; freshly minted on decode and copy.
    var id: UUID

    enum CodingKeys: String, CodingKey {
        case frequency, gain, bandwidth, filterType
    }

    init(frequency: Float, gain: Float, bandwidth: Float = 1.0, filterType: FilterType = .parametric, muted: Bool = false, id: UUID = UUID()) {
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.muted = muted
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Float.self, forKey: .frequency)
        gain = try container.decode(Float.self, forKey: .gain)
        bandwidth = try container.decode(Float.self, forKey: .bandwidth)
        filterType = try container.decodeIfPresent(FilterType.self, forKey: .filterType) ?? .parametric
        muted = false
        id = UUID()
    }

    /// Equality ignores `id` and `muted` — they are runtime-only state, not part of preset value identity.
    static func == (lhs: EQBand, rhs: EQBand) -> Bool {
        lhs.frequency == rhs.frequency &&
        lhs.gain == rhs.gain &&
        lhs.bandwidth == rhs.bandwidth &&
        lhs.filterType == rhs.filterType
    }
}

// MARK: - EQ Preset Data

struct EQPresetData: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var bands: [EQBand]
    /// Right channel bands. When nil, the preset is in linked (stereo) mode.
    /// When non-nil, `bands` represents the left channel and `rightBands` the right.
    var rightBands: [EQBand]?
    let isBuiltIn: Bool
    /// Per-preset input gain override, in dB. Nil = 0 dB / not customized.
    /// Only applied when In/Out dB is in per-preset mode (see AudioEngine.gainIsGlobal).
    var inputGainDB: Float?
    /// Per-preset output gain override, in dB. Nil = 0 dB / not customized.
    var outputGainDB: Float?

    var isFlat: Bool {
        let bandsFlat = bands.allSatisfy { $0.gain == 0 && $0.filterType == .parametric }
        guard let right = rightBands else { return bandsFlat }
        return bandsFlat && right.allSatisfy { $0.gain == 0 && $0.filterType == .parametric }
    }

    var isSplitChannel: Bool { rightBands != nil }

    func bands(for channel: EQChannel) -> [EQBand] {
        switch channel {
        case .left: return bands
        case .right: return rightBands ?? bands
        }
    }

    mutating func setBands(_ newBands: [EQBand], for channel: EQChannel) {
        switch channel {
        case .left: bands = newBands
        case .right: rightBands = newBands
        }
    }

    /// Enable split channel mode by copying current bands to right channel.
    mutating func enableSplitChannel() {
        guard rightBands == nil else { return }
        rightBands = bands
    }

    /// Disable split channel mode, keeping left channel bands.
    mutating func disableSplitChannel() {
        rightBands = nil
    }
}

// MARK: - Constants

extension EQPresetData {
    static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let maxBandCount = 31
    static let minBandCount = 1
}

// MARK: - Built-in Presets

extension EQPresetData {
    static let flat = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Flat",
        bands: defaultFrequencies.map { EQBand(frequency: $0, gain: 0) },
        isBuiltIn: true
    )

    static let bassBoost = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Bass Boost",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([10, 10,  8,  4,  0,  0,  0,  0,  0,  0]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let vocalClarity = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Vocal Clarity",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([-6, -6, -4,  0,  0,  6,  6,  4,  0,  0]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let loudness = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "Loudness",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 8,  6,  0, -2, -4, -2,  0,  2,  4,  6]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let trebleBoost = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Treble Boost",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 0,  0,  0,  0,  0,  2,  4,  6,  8, 10]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let podcast = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        name: "Podcast",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([-8, -4, -2,  0,  2,  4,  6,  4,  2,  0]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let techno = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
        name: "Techno",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 8,  8,  4, -2, -4, -2,  0,  4,  6,  8]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let deepHouse = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
        name: "Deep House",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 6, 10,  8,  2, -2, -4, -2,  0,  2,  4]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let hardTechno = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
        name: "Hard Techno",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([10, 10,  6,  0, -4, -2,  2,  6,  8, 10]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let minimal = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
        name: "Minimal",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 4,  6,  4,  0, -2, -2,  0,  2,  4,  2]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let americanRap = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
        name: "American Rap",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([10,  8,  4,  0, -2, -2,  2,  4,  6,  4]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let germanRap = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
        name: "German Rap",
        //                                        32  64 125 250 500  1k  2k  4k  8k 16k
        bands: zip(defaultFrequencies, [Float]([ 6,  8,  6,  2, -2,  0,  4,  4,  2,  2]))
            .map { EQBand(frequency: $0.0, gain: $0.1) },
        isBuiltIn: true
    )

    static let luzifersVoid = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!,
        name: "Luzifer's Void",
        bands: [
            //  Hz    gain   bw   — sub mass (18–130 Hz)
            EQBand(frequency:    18, gain:  4, bandwidth: 2.0),
            EQBand(frequency:    32, gain:  7, bandwidth: 1.8),
            EQBand(frequency:    55, gain:  8, bandwidth: 1.6),
            EQBand(frequency:    85, gain:  6, bandwidth: 1.4),
            EQBand(frequency:   130, gain:  2, bandwidth: 1.2),
            //  Hz    gain   bw   — mid vacuum (220–2000 Hz)
            EQBand(frequency:   220, gain: -5, bandwidth: 1.2),
            EQBand(frequency:   500, gain: -5, bandwidth: 1.1),
            EQBand(frequency:  1000, gain: -4, bandwidth: 1.0),
            EQBand(frequency:  2000, gain: -2, bandwidth: 0.9),
            //  Hz    gain   bw   — high staircase (3.5k–19k)
            EQBand(frequency:  3500, gain:  1, bandwidth: 0.8),
            EQBand(frequency:  5000, gain:  4, bandwidth: 0.8),
            EQBand(frequency:  7000, gain:  5, bandwidth: 0.6),
            EQBand(frequency:  9500, gain:  6, bandwidth: 0.5),
            EQBand(frequency: 12000, gain:  5, bandwidth: 0.6),
            EQBand(frequency: 15500, gain:  4, bandwidth: 0.8),
            EQBand(frequency: 19000, gain:  3, bandwidth: 1.0),
        ],
        isBuiltIn: true
    )

    static let deadbeef = EQPresetData(
        id: UUID(uuidString: "DEAD0003-BEEF-4E87-A591-0000DEADBEEF")!,
        name: "DEADBEEF",
        bands: [
            //  Hz     gain   bw   — 0xDEAD shifts: sub (dead weight)
            EQBand(frequency:    27, gain:  7, bandwidth: 1.8),
            EQBand(frequency:    55, gain:  8, bandwidth: 1.6),
            EQBand(frequency:   111, gain:  5, bandwidth: 1.4),
            //  Hz     gain   bw   — mid scoop (the void between)
            EQBand(frequency:   222, gain: -6, bandwidth: 1.2),
            EQBand(frequency:   445, gain: -8, bandwidth: 1.4),
            EQBand(frequency:   890, gain: -6, bandwidth: 1.2),
            //  Hz     gain   bw   — 0xBEEF shifts: presence (beef)
            EQBand(frequency:  1781, gain:  5, bandwidth: 0.5),
            EQBand(frequency:  3562, gain:  7, bandwidth: 0.4),
            EQBand(frequency:  7125, gain:  6, bandwidth: 0.5),
            EQBand(frequency: 14251, gain:  4, bandwidth: 0.7),
        ],
        isBuiltIn: true
    )

    static let oxDeadbeef = EQPresetData(
        id: UUID(uuidString: "DEAD0004-BEEF-4E87-A591-0000DEADBEEF")!,
        name: "0xDEADBEEF",
        bands: [
            //  0xDEAD >> 11 boost / 0xBEEF >> 11 notch
            EQBand(frequency:    27, gain:  6, bandwidth: 1.4),
            EQBand(frequency:    23, gain: -5, bandwidth: 0.4),
            //  0xDEAD >> 10 / 0xBEEF >> 10
            EQBand(frequency:    55, gain:  7, bandwidth: 1.2),
            EQBand(frequency:    47, gain: -6, bandwidth: 0.3),
            //  0xDEAD >> 9 / 0xBEEF >> 9
            EQBand(frequency:   111, gain:  4, bandwidth: 1.0),
            EQBand(frequency:    95, gain: -5, bandwidth: 0.3),
            //  0xDEAD >> 8 / 0xBEEF >> 8
            EQBand(frequency:   222, gain: -4, bandwidth: 0.8),
            EQBand(frequency:   190, gain: -6, bandwidth: 0.3),
            //  0xDEAD >> 7 / 0xBEEF >> 7
            EQBand(frequency:   445, gain: -5, bandwidth: 0.8),
            EQBand(frequency:   381, gain: -7, bandwidth: 0.3),
            //  0xDEAD >> 6 / 0xBEEF >> 6
            EQBand(frequency:   890, gain: -3, bandwidth: 0.7),
            EQBand(frequency:   763, gain: -6, bandwidth: 0.3),
            //  0xDEAD >> 5 / 0xBEEF >> 5
            EQBand(frequency:  1781, gain:  3, bandwidth: 0.5),
            EQBand(frequency:  1527, gain: -5, bandwidth: 0.3),
            //  0xDEAD >> 4 / 0xBEEF >> 4
            EQBand(frequency:  3562, gain:  5, bandwidth: 0.4),
            EQBand(frequency:  3054, gain: -4, bandwidth: 0.3),
            //  0xDEAD >> 3 / 0xBEEF >> 3
            EQBand(frequency:  7125, gain:  4, bandwidth: 0.4),
            EQBand(frequency:  6109, gain: -5, bandwidth: 0.3),
            //  0xDEAD >> 2 / 0xBEEF >> 2
            EQBand(frequency: 14251, gain:  3, bandwidth: 0.6),
            EQBand(frequency: 12219, gain: -4, bandwidth: 0.3),
        ],
        isBuiltIn: true
    )

    static let builtInPresets: [EQPresetData] = [
        .flat, .bassBoost, .vocalClarity, .loudness, .trebleBoost,
        .podcast, .techno, .deepHouse, .hardTechno, .minimal,
        .americanRap, .germanRap, .luzifersVoid, .deadbeef, .oxDeadbeef
    ]

    /// Suggest a frequency for a new band inserted into the current set.
    /// Finds the largest gap (in octaves) between existing bands and returns
    /// the geometric midpoint.
    func suggestNewBandFrequency() -> Float {
        guard !bands.isEmpty else { return 1000 }
        let sorted = bands.map(\.frequency).sorted()

        // Check gap below lowest
        var bestFreq: Float = sorted[0] / 2
        var bestGap: Float = log2(sorted[0] / 20) // gap from 20 Hz

        // Check gaps between bands
        for i in 1..<sorted.count {
            let gap = log2(sorted[i] / sorted[i - 1])
            if gap > bestGap {
                bestGap = gap
                bestFreq = sqrt(sorted[i] * sorted[i - 1]) // geometric midpoint
            }
        }

        // Check gap above highest
        let topGap = log2(20000 / sorted.last!)
        if topGap > bestGap {
            bestFreq = sorted.last! * 2
        }

        return min(max(bestFreq, 20), 20000)
    }
}

// MARK: - Frequency Formatting

extension EQBand {
    var frequencyLabel: String {
        if frequency >= 1000 {
            let k = frequency / 1000
            if k == Float(Int(k)) {
                return "\(Int(k)) kHz"
            } else {
                return String(format: "%.1f kHz", k)
            }
        } else if frequency == Float(Int(frequency)) {
            return "\(Int(frequency)) Hz"
        } else {
            return String(format: "%.1f Hz", frequency)
        }
    }

    /// Convert bandwidth in octaves to Q factor (frequency-independent approximation).
    static func octavesToQ(_ bw: Float) -> Float {
        let p = powf(2, bw)
        return sqrtf(p) / (p - 1)
    }

    /// Convert Q factor to bandwidth in octaves.
    static func qToOctaves(_ q: Float) -> Float {
        return 2 * asinh(1 / (2 * q)) / logf(2)
    }

    func bandwidthLabel(asQ: Bool) -> String {
        if asQ {
            let q = Self.octavesToQ(bandwidth)
            if q >= 10 {
                return String(format: "Q %.0f", q)
            }
            return String(format: "Q %.2f", q)
        } else {
            if bandwidth == Float(Int(bandwidth)) {
                return "\(Int(bandwidth)) oct"
            }
            return String(format: "%.1f oct", bandwidth)
        }
    }

    var gainLabel: String {
        if gain == 0 { return "0 dB" }
        if gain == Float(Int(gain)) {
            return String(format: "%+d dB", Int(gain))
        }
        return String(format: "%+.1f dB", gain)
    }
}
