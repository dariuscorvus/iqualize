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
}
