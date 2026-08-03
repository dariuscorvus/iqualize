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

    func testGarbagePersistedStateFallsBackAndPreservesBackup() {
        let defaults = makeIsolatedDefaults()
        let garbage = Data([0x00, 0xFF, 0x12, 0x34])
        defaults.set(garbage, forKey: iQualizeState.key)

        let state = iQualizeState.readPersisted(from: defaults)

        XCTAssertEqual(state.selectedPresetID, iQualizeState.defaultState.selectedPresetID)
        XCTAssertEqual(defaults.data(forKey: iQualizeState.key), garbage)
        XCTAssertEqual(corruptBackups(in: defaults).map(\.value), [garbage])
    }

    func testTruncatedPersistedStateFallsBackAndPreservesBackup() throws {
        let defaults = makeIsolatedDefaults()
        let valid = try JSONEncoder().encode(iQualizeState(captureEnabled: false, selectedPresetID: EQPresetData.vocalClarity.id, peakLimiter: false))
        let truncated = valid.prefix(max(1, valid.count / 2))
        defaults.set(Data(truncated), forKey: iQualizeState.key)

        let state = iQualizeState.readPersisted(from: defaults)

        XCTAssertEqual(state.captureEnabled, iQualizeState.defaultState.captureEnabled)
        XCTAssertEqual(defaults.data(forKey: iQualizeState.key), Data(truncated))
        XCTAssertEqual(corruptBackups(in: defaults).map(\.value), [Data(truncated)])
    }

    @MainActor
    func testCorruptBackupSurvivesLaterSettingsStoreWrite() {
        let defaults = makeIsolatedDefaults()
        let garbage = Data("not-json".utf8)
        defaults.set(garbage, forKey: iQualizeState.key)

        let store = SettingsStore(userDefaults: defaults)
        store.set(\.captureEnabled, false)

        XCTAssertEqual(corruptBackups(in: defaults).map(\.value), [garbage])
        let persisted = iQualizeState.readPersisted(from: defaults)
        XCTAssertFalse(persisted.captureEnabled)
    }

    func testValidPersistedStateLoadsWithoutBackup() throws {
        let defaults = makeIsolatedDefaults()
        let original = iQualizeState(captureEnabled: false, selectedPresetID: EQPresetData.bassBoost.id, peakLimiter: false)
        defaults.set(try JSONEncoder().encode(original), forKey: iQualizeState.key)

        let state = iQualizeState.readPersisted(from: defaults)

        XCTAssertFalse(state.captureEnabled)
        XCTAssertEqual(state.selectedPresetID, EQPresetData.bassBoost.id)
        XCTAssertFalse(state.peakLimiter)
        XCTAssertTrue(corruptBackups(in: defaults).isEmpty)
    }

    func testMissingPersistedStateFallsBackWithoutBackup() {
        let defaults = makeIsolatedDefaults()

        let state = iQualizeState.readPersisted(from: defaults)

        XCTAssertEqual(state.selectedPresetID, iQualizeState.defaultState.selectedPresetID)
        XCTAssertNil(defaults.data(forKey: iQualizeState.key))
        XCTAssertTrue(corruptBackups(in: defaults).isEmpty)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "iQualizeStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func corruptBackups(in defaults: UserDefaults) -> [(key: String, value: Data)] {
        defaults.dictionaryRepresentation()
            .compactMap { key, value in
                guard key.hasPrefix(iQualizeState.corruptBackupKeyPrefix), let data = value as? Data else {
                    return nil
                }
                return (key, data)
            }
            .sorted { $0.key < $1.key }
    }
}
