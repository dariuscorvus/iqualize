import XCTest
@testable import iQualize

final class EQBandTests: XCTestCase {

    func testFrequencyLabel() {
        XCTAssertEqual(EQBand(frequency: 32, gain: 0).frequencyLabel, "32 Hz")
        XCTAssertEqual(EQBand(frequency: 250, gain: 0).frequencyLabel, "250 Hz")
        XCTAssertEqual(EQBand(frequency: 1000, gain: 0).frequencyLabel, "1 kHz")
        XCTAssertEqual(EQBand(frequency: 2500, gain: 0).frequencyLabel, "2.5 kHz")
        XCTAssertEqual(EQBand(frequency: 16000, gain: 0).frequencyLabel, "16 kHz")
    }

    func testGainLabel() {
        XCTAssertEqual(EQBand(frequency: 1000, gain: 0).gainLabel, "0 dB")
        XCTAssertEqual(EQBand(frequency: 1000, gain: 6).gainLabel, "+6 dB")
        XCTAssertEqual(EQBand(frequency: 1000, gain: -3).gainLabel, "-3 dB")
        XCTAssertEqual(EQBand(frequency: 1000, gain: 1.5).gainLabel, "+1.5 dB")
    }

    func testDefaultBandwidth() {
        let band = EQBand(frequency: 1000, gain: 0)
        XCTAssertEqual(band.bandwidth, 1.0)
    }

    func testCodableRoundTrip() throws {
        let band = EQBand(frequency: 440, gain: 3.5, bandwidth: 0.8)
        let data = try JSONEncoder().encode(band)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)
        XCTAssertEqual(band, decoded)
    }
}

final class EQPresetDataTests: XCTestCase {

    func testBuiltInPresetsExist() {
        XCTAssertEqual(EQPresetData.builtInPresets.count, 15)
        for preset in EQPresetData.builtInPresets {
            XCTAssertTrue(preset.isBuiltIn, "\(preset.name) must be marked built-in")
        }
    }

    func testFlatIsFlat() {
        XCTAssertTrue(EQPresetData.flat.isFlat)
        XCTAssertFalse(EQPresetData.bassBoost.isFlat)
    }

    func testBuiltInPresetBandCountsWithinLimits() {
        // The classic 10-band presets keep 10 bands; the newer ones vary
        // (Luzifer's Void 16, 0xDEADBEEF 20) — there's no upper cap to fit.
        XCTAssertEqual(EQPresetData.flat.bands.count, 10)
        XCTAssertEqual(EQPresetData.bassBoost.bands.count, 10)
        XCTAssertEqual(EQPresetData.vocalClarity.bands.count, 10)
        for preset in EQPresetData.builtInPresets {
            XCTAssertGreaterThanOrEqual(preset.bands.count, EQPresetData.minBandCount)
        }
    }

    func testBassBoostOnlyBoostsLows() {
        let bands = EQPresetData.bassBoost.bands
        XCTAssertGreaterThan(bands[0].gain, 0) // 64 Hz
        XCTAssertGreaterThan(bands[1].gain, 0) // 125 Hz
        XCTAssertGreaterThan(bands[2].gain, 0) // 250 Hz
        for i in 4..<10 {
            XCTAssertEqual(bands[i].gain, 0)
        }
    }

    func testVocalClarityCutsLowsBoostsMids() {
        let bands = EQPresetData.vocalClarity.bands
        XCTAssertLessThan(bands[0].gain, 0)  // 64 Hz cut
        XCTAssertLessThan(bands[1].gain, 0)  // 125 Hz cut
        XCTAssertGreaterThan(bands[5].gain, 0) // 1k boost
        XCTAssertGreaterThan(bands[6].gain, 0) // 2k boost
    }

    func testGainsWithinRange() {
        for preset in EQPresetData.builtInPresets {
            for band in preset.bands {
                XCTAssertGreaterThanOrEqual(band.gain, -12.0)
                XCTAssertLessThanOrEqual(band.gain, 12.0)
            }
        }
    }

    func testDeterministicUUIDs() {
        // Built-in presets must have stable UUIDs for state persistence
        XCTAssertEqual(EQPresetData.flat.id.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(EQPresetData.bassBoost.id.uuidString, "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(EQPresetData.vocalClarity.id.uuidString, "00000000-0000-0000-0000-000000000003")
    }

    func testSuggestNewBandFrequency() {
        let preset = EQPresetData.flat
        let suggested = preset.suggestNewBandFrequency()
        // Should be between 20 and 20000
        XCTAssertGreaterThanOrEqual(suggested, 20)
        XCTAssertLessThanOrEqual(suggested, 20000)
    }

    func testCodableRoundTrip() throws {
        let preset = EQPresetData.bassBoost
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EQPresetData.self, from: data)
        XCTAssertEqual(preset, decoded)
    }
}

final class iQualizeStateTests: XCTestCase {

    func testDefaultState() {
        let state = iQualizeState.defaultState
        XCTAssertTrue(state.captureEnabled)
        XCTAssertEqual(state.selectedPresetID, EQPresetData.flat.id)
        XCTAssertTrue(state.peakLimiter)
    }

    func testCodableRoundTrip() throws {
        let original = iQualizeState(captureEnabled: true, selectedPresetID: EQPresetData.bassBoost.id, peakLimiter: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(iQualizeState.self, from: data)
        XCTAssertEqual(decoded.captureEnabled, original.captureEnabled)
        XCTAssertEqual(decoded.selectedPresetID, original.selectedPresetID)
        XCTAssertEqual(decoded.peakLimiter, original.peakLimiter)
    }
}
