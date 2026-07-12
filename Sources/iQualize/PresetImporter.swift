import Foundation

// MARK: - Errors

enum PresetImportError: LocalizedError {
    case unrecognizedFormat
    case noBandsFound

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "This file isn't a recognized preset format (iQualize, AutoEQ ParametricEQ/GraphicEQ, or OPRA)."
        case .noBandsFound:
            return "No EQ bands could be parsed from this file."
        }
    }
}

// MARK: - Parsed Preset

/// Format-agnostic result of importing a preset file, before it's assigned an id/name
/// and turned into a full `EQPresetData` by the caller.
struct ParsedPreset {
    var name: String?
    var bands: [EQBand]
    var rightBands: [EQBand]?
    var inputGainDB: Float?
    var outputGainDB: Float?
}

// MARK: - Importer

enum PresetImporter {

    static func parse(data: Data, filename: String) throws -> ParsedPreset {
        if let decoded = try? JSONDecoder().decode(EQPresetData.self, from: data), !decoded.bands.isEmpty {
            return ParsedPreset(
                name: decoded.name.isEmpty ? nil : decoded.name,
                bands: decoded.bands,
                rightBands: decoded.rightBands,
                inputGainDB: decoded.inputGainDB,
                outputGainDB: decoded.outputGainDB
            )
        }

        if let opra = try? JSONDecoder().decode(OPRAEqInfo.self, from: data) {
            return try parseOPRA(opra)
        }

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("GraphicEQ:") {
                return try parseGraphicEQ(trimmed)
            }
            if trimmed.hasPrefix("Preamp:") || trimmed.contains("Filter 1:") {
                return try parseParametricEQ(trimmed)
            }
        }

        throw PresetImportError.unrecognizedFormat
    }

    // MARK: AutoEQ ParametricEQ.txt

    private static func parseParametricEQ(_ text: String) throws -> ParsedPreset {
        var preamp: Float?
        var bands: [EQBand] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(separator: " ").map(String.init)
            guard let first = tokens.first else { continue }

            if first == "Preamp:", tokens.count >= 2 {
                preamp = Float(tokens[1])
            } else if first.hasPrefix("Filter") {
                guard let stateIndex = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
                      tokens[stateIndex] == "ON",
                      stateIndex + 1 < tokens.count else { continue }

                guard let filterType = autoEQFilterType(tokens[stateIndex + 1]) else { continue }
                guard let fc = number(after: "Fc", in: tokens),
                      let gain = number(after: "Gain", in: tokens) else { continue }
                let q = number(after: "Q", in: tokens) ?? 0.707

                bands.append(EQBand(frequency: fc, gain: gain, bandwidth: EQBand.qToOctaves(q), filterType: filterType))
            }
        }

        guard !bands.isEmpty else { throw PresetImportError.noBandsFound }
        if bands.count > EQPresetData.maxBandCount {
            bands = Array(bands.prefix(EQPresetData.maxBandCount))
        }

        return ParsedPreset(name: nil, bands: bands, rightBands: nil, inputGainDB: preamp, outputGainDB: nil)
    }

    private static func number(after keyword: String, in tokens: [String]) -> Float? {
        guard let index = tokens.firstIndex(of: keyword), index + 1 < tokens.count else { return nil }
        return Float(tokens[index + 1])
    }

    private static func autoEQFilterType(_ token: String) -> FilterType? {
        switch token {
        case "PK": return .parametric
        case "LSC", "LS": return .lowShelf
        case "HSC", "HS": return .highShelf
        case "LP": return .lowPass
        case "HP": return .highPass
        case "BP": return .bandPass
        case "NO", "BS": return .notch
        default: return nil
        }
    }

    // MARK: AutoEQ GraphicEQ.txt

    /// Standard 31-band ISO 1/3-octave center frequencies (20 Hz - 20 kHz).
    /// Conveniently exactly `EQPresetData.maxBandCount`.
    private static let iso31BandFrequencies: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    ]

    private static func parseGraphicEQ(_ text: String) throws -> ParsedPreset {
        let body = String(text.dropFirst("GraphicEQ:".count))
        let points: [(freq: Float, gain: Float)] = body.split(separator: ";").compactMap { entry in
            let numbers = entry.split(separator: " ").compactMap { Float($0) }
            guard numbers.count >= 2 else { return nil }
            return (numbers[0], numbers[1])
        }.sorted { $0.freq < $1.freq }

        guard !points.isEmpty else { throw PresetImportError.noBandsFound }

        let bands = iso31BandFrequencies.map { freq in
            EQBand(frequency: freq, gain: interpolatedGain(points: points, atFrequency: freq), bandwidth: 0.5, filterType: .parametric)
        }

        return ParsedPreset(name: nil, bands: bands, rightBands: nil, inputGainDB: nil, outputGainDB: nil)
    }

    private static func interpolatedGain(points: [(freq: Float, gain: Float)], atFrequency freq: Float) -> Float {
        if freq <= points.first!.freq { return points.first!.gain }
        if freq >= points.last!.freq { return points.last!.gain }

        for i in 1..<points.count {
            guard points[i].freq >= freq else { continue }
            let p0 = points[i - 1], p1 = points[i]
            guard p1.freq > p0.freq else { return p0.gain }
            let t = (log2(freq) - log2(p0.freq)) / (log2(p1.freq) - log2(p0.freq))
            return p0.gain + t * (p1.gain - p0.gain)
        }
        return points.last!.gain
    }

    // MARK: OPRA eq_info.json

    private static func parseOPRA(_ opra: OPRAEqInfo) throws -> ParsedPreset {
        guard opra.type == "parametric_eq" else { throw PresetImportError.unrecognizedFormat }

        var bands = opra.parameters.bands.compactMap { band -> EQBand? in
            guard let filterType = opraFilterType(band.type) else { return nil }
            let bandwidth = band.q.map { EQBand.qToOctaves($0) } ?? 1.0
            return EQBand(frequency: band.frequency, gain: band.gain_db ?? 0, bandwidth: bandwidth, filterType: filterType)
        }

        guard !bands.isEmpty else { throw PresetImportError.noBandsFound }
        // Schema states bands are "sorted by priority" and software with fewer bands should truncate.
        if bands.count > EQPresetData.maxBandCount {
            bands = Array(bands.prefix(EQPresetData.maxBandCount))
        }

        return ParsedPreset(name: nil, bands: bands, rightBands: nil, inputGainDB: opra.parameters.gain_db, outputGainDB: nil)
    }

    private static func opraFilterType(_ raw: String) -> FilterType? {
        switch raw {
        case "peak_dip": return .parametric
        case "low_shelf": return .lowShelf
        case "high_shelf": return .highShelf
        case "low_pass": return .lowPass
        case "high_pass": return .highPass
        case "band_pass": return .bandPass
        case "band_stop": return .notch
        default: return nil
        }
    }
}

// MARK: - OPRA Schema

private struct OPRAEqInfo: Decodable {
    struct Parameters: Decodable {
        struct Band: Decodable {
            let type: String
            let frequency: Float
            let gain_db: Float?
            let q: Float?
        }
        let gain_db: Float
        let bands: [Band]
    }

    let type: String
    let parameters: Parameters
}
