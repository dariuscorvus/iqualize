import XCTest
@testable import iQualize

@available(macOS 14.2, *)
@MainActor
final class PresetStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    // setUp/tearDown are async so the override can stay MainActor-isolated —
    // the synchronous overrides inherit nonisolated from XCTestCase and can't
    // touch this class's isolated stored properties.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.iqualize.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore() -> PresetStore {
        PresetStore(userDefaults: defaults)
    }

    private func makePreset(name: String, isBuiltIn: Bool = false) -> EQPresetData {
        EQPresetData(id: UUID(), name: name, bands: EQPresetData.flat.bands, isBuiltIn: isBuiltIn)
    }

    // MARK: - dedupedName

    func testDedupedNameNoCollision() {
        let store = makeStore()
        XCTAssertEqual(store.dedupedName(base: "My Preset"), "My Preset")
    }

    func testDedupedNameAppendsIncrementingSuffix() {
        let store = makeStore()
        store.saveCustomPreset(makePreset(name: "Flat (Custom)"))
        XCTAssertEqual(store.dedupedName(base: "Flat (Custom)"), "Flat (Custom) 2")
        store.saveCustomPreset(makePreset(name: "Flat (Custom) 2"))
        XCTAssertEqual(store.dedupedName(base: "Flat (Custom)"), "Flat (Custom) 3")
    }

    // MARK: - built-in overrides

    func testSaveBuiltInOverrideAppliesInPlace() {
        let store = makeStore()
        var edited = EQPresetData.flat
        edited.name = "Flat (edited)"
        edited.bands[0].gain = 6

        store.saveBuiltInOverride(edited)

        XCTAssertTrue(store.hasOverride(EQPresetData.flat.id))
        let resolved = store.preset(for: EQPresetData.flat.id)
        XCTAssertEqual(resolved?.id, EQPresetData.flat.id)
        XCTAssertTrue(resolved?.isBuiltIn ?? false)
        XCTAssertEqual(resolved?.name, "Flat (edited)")
        XCTAssertEqual(resolved?.bands.first?.gain, 6)
        // Identity and count in allPresets are unchanged — no fork appended.
        XCTAssertEqual(store.allPresets.filter { $0.id == EQPresetData.flat.id }.count, 1)
    }

    func testSaveBuiltInOverrideNoOpsForCustomPreset() {
        let store = makeStore()
        let custom = makePreset(name: "My Custom")
        store.saveBuiltInOverride(custom)
        XCTAssertFalse(store.hasOverride(custom.id))
    }

    func testResetBuiltInToOriginalRevertsContent() {
        let store = makeStore()
        var edited = EQPresetData.bassBoost
        edited.bands[0].gain = 0
        store.saveBuiltInOverride(edited)
        XCTAssertTrue(store.hasOverride(EQPresetData.bassBoost.id))

        store.resetBuiltInToOriginal(id: EQPresetData.bassBoost.id)

        XCTAssertFalse(store.hasOverride(EQPresetData.bassBoost.id))
        XCTAssertEqual(store.preset(for: EQPresetData.bassBoost.id), EQPresetData.bassBoost)
    }

    func testOverriddenBuiltInPresetsListsOnlyOverriddenOnes() {
        let store = makeStore()
        XCTAssertTrue(store.overriddenBuiltInPresets.isEmpty)

        var edited = EQPresetData.loudness
        edited.name = "Loudness (edited)"
        store.saveBuiltInOverride(edited)

        XCTAssertEqual(store.overriddenBuiltInPresets.map(\.id), [EQPresetData.loudness.id])
        XCTAssertEqual(store.overriddenBuiltInPresets.first?.name, "Loudness (edited)")
    }

    func testHiddenBuiltInPresetReflectsOverride() {
        let store = makeStore()
        var edited = EQPresetData.techno
        edited.name = "Techno (edited)"
        store.saveBuiltInOverride(edited)
        store.hideBuiltInPreset(id: EQPresetData.techno.id)

        XCTAssertEqual(store.hiddenBuiltInPresets.first?.name, "Techno (edited)")
    }

    func testBuiltInOverridePersistsAcrossReload() {
        let store = makeStore()
        var edited = EQPresetData.flat
        edited.name = "Flat (edited)"
        store.saveBuiltInOverride(edited)

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.hasOverride(EQPresetData.flat.id))
        XCTAssertEqual(reloaded.preset(for: EQPresetData.flat.id)?.name, "Flat (edited)")
    }

    // MARK: - saveCustomPreset upsert

    func testSaveCustomPresetInsertsNew() {
        let store = makeStore()
        let preset = makePreset(name: "New One")
        store.saveCustomPreset(preset)
        XCTAssertEqual(store.customPresets.count, 1)
        XCTAssertEqual(store.customPresets.first?.id, preset.id)
    }

    func testSaveCustomPresetReplacesExistingById() {
        let store = makeStore()
        var preset = makePreset(name: "Original Name")
        store.saveCustomPreset(preset)
        preset.name = "Renamed"
        store.saveCustomPreset(preset)
        XCTAssertEqual(store.customPresets.count, 1)
        XCTAssertEqual(store.customPresets.first?.name, "Renamed")
    }

    // MARK: - deleteCustomPreset / hideBuiltInPreset cascades

    func testDeleteCustomPresetCascadesFavoriteAndPin() {
        let store = makeStore()
        let preset = makePreset(name: "Doomed")
        store.saveCustomPreset(preset)
        store.toggleFavorite(preset.id)
        store.pinPreset(preset.id, toDeviceUID: "device-1")
        XCTAssertTrue(store.isFavorite(preset.id))
        XCTAssertEqual(store.pinnedPresetID(forDeviceUID: "device-1"), preset.id)

        store.deleteCustomPreset(id: preset.id)

        XCTAssertNil(store.preset(for: preset.id))
        XCTAssertFalse(store.isFavorite(preset.id))
        XCTAssertNil(store.pinnedPresetID(forDeviceUID: "device-1"))
    }

    func testHideBuiltInPresetCascadesAndRestores() {
        let store = makeStore()
        let target = EQPresetData.bassBoost
        store.toggleFavorite(target.id)
        store.pinPreset(target.id, toDeviceUID: "device-1")

        store.hideBuiltInPreset(id: target.id)

        XCTAssertFalse(store.allPresets.contains { $0.id == target.id })
        XCTAssertTrue(store.hiddenBuiltInPresets.contains { $0.id == target.id })
        XCTAssertFalse(store.isFavorite(target.id))
        XCTAssertNil(store.pinnedPresetID(forDeviceUID: "device-1"))

        store.restoreBuiltInPreset(id: target.id)
        XCTAssertTrue(store.allPresets.contains { $0.id == target.id })
        XCTAssertTrue(store.hiddenBuiltInPresets.isEmpty)
    }

    func testFlatCanNeverBeHidden() {
        let store = makeStore()
        store.hideBuiltInPreset(id: EQPresetData.flat.id)
        XCTAssertTrue(store.allPresets.contains { $0.id == EQPresetData.flat.id })
        XCTAssertTrue(store.hiddenBuiltInPresets.isEmpty)
    }

    // MARK: - favorite / pin

    func testToggleFavorite() {
        let store = makeStore()
        let preset = makePreset(name: "Fav Test")
        store.saveCustomPreset(preset)
        XCTAssertFalse(store.isFavorite(preset.id))
        store.toggleFavorite(preset.id)
        XCTAssertTrue(store.isFavorite(preset.id))
        store.toggleFavorite(preset.id)
        XCTAssertFalse(store.isFavorite(preset.id))
    }

    func testPinAndUnpin() {
        let store = makeStore()
        let preset = makePreset(name: "Pin Test")
        store.saveCustomPreset(preset)
        store.pinPreset(preset.id, toDeviceUID: "dev")
        XCTAssertEqual(store.pinnedPreset(forDeviceUID: "dev")?.id, preset.id)
        store.unpinPreset(fromDeviceUID: "dev")
        XCTAssertNil(store.pinnedPresetID(forDeviceUID: "dev"))
    }

    // MARK: - corrupt persisted data recovery (issue #176)

    /// The five persisted blob keys, matching PresetStore's private constants.
    private static let blobKeys = [
        "com.iqualize.customPresets",
        "com.iqualize.favoritePresetIDs",
        "com.iqualize.hiddenBuiltInPresetIDs",
        "com.iqualize.pinnedPresetsByDevice",
        "com.iqualize.builtInOverrides",
    ]

    private func backupKeys(for key: String) -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(key).corrupt.") }
            .sorted()
    }

    func testGarbageCustomPresetsPreservedUnderBackupKey() {
        let garbage = Data("not json at all".utf8)
        defaults.set(garbage, forKey: "com.iqualize.customPresets")

        let store = makeStore()

        XCTAssertTrue(store.customPresets.isEmpty)
        XCTAssertEqual(store.loadFailures.count, 1)
        let backups = backupKeys(for: "com.iqualize.customPresets")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), garbage)
    }

    func testTruncatedJSONPreservedUnderBackupKey() {
        let truncated = Data("[{\"name\":".utf8)
        defaults.set(truncated, forKey: "com.iqualize.customPresets")

        let store = makeStore()

        XCTAssertTrue(store.customPresets.isEmpty)
        XCTAssertEqual(store.loadFailures.count, 1)
        let backups = backupKeys(for: "com.iqualize.customPresets")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), truncated)
    }

    func testLaterSaveDoesNotTouchBackup() {
        let garbage = Data("garbage".utf8)
        defaults.set(garbage, forKey: "com.iqualize.customPresets")
        let store = makeStore()
        let backups = backupKeys(for: "com.iqualize.customPresets")
        XCTAssertEqual(backups.count, 1)

        store.saveCustomPreset(makePreset(name: "New After Corruption"))

        // Backup bytes untouched, primary key now holds the new valid array.
        XCTAssertEqual(defaults.data(forKey: backups[0]), garbage)
        XCTAssertEqual(backupKeys(for: "com.iqualize.customPresets"), backups)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.customPresets.map(\.name), ["New After Corruption"])
    }

    func testCascadingSaveDoesNotClobberBackupOfOtherKey() {
        // deleteCustomPreset persists favorites and pins too — a corrupt favorites
        // blob must already be backed up before that cascade overwrites the key.
        let garbage = Data("]}[".utf8)
        defaults.set(garbage, forKey: "com.iqualize.favoritePresetIDs")
        let store = makeStore()
        let preset = makePreset(name: "Doomed")
        store.saveCustomPreset(preset)

        store.deleteCustomPreset(id: preset.id)

        let backups = backupKeys(for: "com.iqualize.favoritePresetIDs")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), garbage)
    }

    func testValidDataLoadsUnchangedWithNoFailuresAndNoBackups() throws {
        let preset = makePreset(name: "Valid")
        defaults.set(try JSONEncoder().encode([preset]), forKey: "com.iqualize.customPresets")
        defaults.set(try JSONEncoder().encode([preset.id]), forKey: "com.iqualize.favoritePresetIDs")
        defaults.set(try JSONEncoder().encode([EQPresetData.bassBoost.id]), forKey: "com.iqualize.hiddenBuiltInPresetIDs")
        defaults.set(try JSONEncoder().encode(["dev": preset.id]), forKey: "com.iqualize.pinnedPresetsByDevice")
        var edited = EQPresetData.flat
        edited.name = "Flat (edited)"
        defaults.set(try JSONEncoder().encode([EQPresetData.flat.id: edited]), forKey: "com.iqualize.builtInOverrides")

        let store = makeStore()

        XCTAssertTrue(store.loadFailures.isEmpty)
        XCTAssertEqual(store.customPresets.map(\.name), ["Valid"])
        XCTAssertEqual(store.favoritePresetIDs, [preset.id])
        XCTAssertEqual(store.hiddenBuiltInPresetIDs, [EQPresetData.bassBoost.id])
        XCTAssertEqual(store.pinnedPresetIDByDeviceUID, ["dev": preset.id])
        XCTAssertEqual(store.builtInOverrides[EQPresetData.flat.id]?.name, "Flat (edited)")
        for key in Self.blobKeys {
            XCTAssertTrue(backupKeys(for: key).isEmpty, "unexpected backup for \(key)")
        }
    }

    func testEachBlobBackedUpIndependently() {
        let garbage = Data("\u{FF}\u{FE}broken".utf8)
        for corruptKey in Self.blobKeys {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(garbage, forKey: corruptKey)

            let store = makeStore()

            XCTAssertEqual(store.loadFailures.count, 1, "one failure expected for \(corruptKey)")
            let backups = backupKeys(for: corruptKey)
            XCTAssertEqual(backups.count, 1, "one backup expected for \(corruptKey)")
            XCTAssertEqual(defaults.data(forKey: backups[0]), garbage)
            for other in Self.blobKeys where other != corruptKey {
                XCTAssertTrue(backupKeys(for: other).isEmpty, "no backup expected for \(other)")
            }
        }
    }

    func testAllBlobsCorruptReportsFiveFailures() {
        for key in Self.blobKeys {
            defaults.set(Data("junk-\(key)".utf8), forKey: key)
        }

        let store = makeStore()

        XCTAssertEqual(store.loadFailures.count, 5)
        for key in Self.blobKeys {
            XCTAssertEqual(backupKeys(for: key).count, 1, "backup missing for \(key)")
        }
        // Store still functions on defaults.
        XCTAssertTrue(store.customPresets.isEmpty)
        XCTAssertFalse(store.allPresets.isEmpty)
    }
}
