import XCTest
@testable import iQualize

@available(macOS 14.2, *)
@MainActor
final class PresetStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.iqualize.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
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

    // MARK: - forkIfBuiltIn

    func testForkIfBuiltInUsesDedupedName() {
        let store = makeStore()
        let fork1 = store.forkIfBuiltIn(EQPresetData.flat)
        XCTAssertEqual(fork1.name, "Flat (Custom)")
        XCTAssertFalse(fork1.isBuiltIn)
        store.saveCustomPreset(fork1)
        let fork2 = store.forkIfBuiltIn(EQPresetData.flat)
        XCTAssertEqual(fork2.name, "Flat (Custom) 2")
        XCTAssertNotEqual(fork1.id, fork2.id)
    }

    func testForkIfBuiltInReturnsUnchangedForCustomPreset() {
        let store = makeStore()
        let custom = makePreset(name: "My Custom")
        let forked = store.forkIfBuiltIn(custom)
        XCTAssertEqual(forked.id, custom.id)
        XCTAssertEqual(forked.name, custom.name)
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
