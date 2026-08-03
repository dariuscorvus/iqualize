import XCTest
@testable import iQualize

/// Tests for the owned settings store (#177): per-field isolation, interleaved
/// (modal-style) writes, persisted-format compatibility, and decode fallbacks.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    // setUp/tearDown are async so the override can stay MainActor-isolated —
    // the synchronous overrides inherit nonisolated from XCTestCase and can't
    // touch this class's isolated stored properties.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private static let key = "com.iqualize.state"

    private func persistedState() throws -> iQualizeState {
        let data = try XCTUnwrap(defaults.data(forKey: Self.key))
        return try JSONDecoder().decode(iQualizeState.self, from: data)
    }

    private func persistedJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: Self.key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func seed(_ state: iQualizeState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: Self.key)
    }

    // MARK: - Defaults and decode fallbacks

    func testMissingBlobYieldsDefaults() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.state, iQualizeState.defaultState)
    }

    func testEmptyJSONObjectYieldsDefaults() {
        defaults.set(Data("{}".utf8), forKey: Self.key)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.state, iQualizeState.defaultState)
    }

    func testGarbageBlobYieldsDefaults() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: Self.key)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.state, iQualizeState.defaultState)
    }

    func testPartialBlobDecodesWithPerFieldFallbacks() {
        // Only two fields present — everything else must fall back per field,
        // not fail the whole decode.
        let json = """
        {"bypassed": true, "maxGainDB": 6}
        """
        defaults.set(Data(json.utf8), forKey: Self.key)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.state.bypassed)
        XCTAssertEqual(store.state.maxGainDB, 6)
        XCTAssertTrue(store.state.captureEnabled)
        XCTAssertTrue(store.state.peakLimiter)
        XCTAssertEqual(store.state.selectedPresetID, EQPresetData.flat.id)
    }

    /// The documented `captureEnabled` naming rationale: legacy blobs carry an
    /// explicit `"isEnabled": false` from before the flag was consulted. Because
    /// the field is named `captureEnabled` (not a repurposed `isEnabled`), the
    /// legacy key is ignored and the fallback `true` applies.
    func testLegacyIsEnabledKeyDoesNotDisableCapture() {
        let json = """
        {"isEnabled": false, "peakLimiter": true}
        """
        defaults.set(Data(json.utf8), forKey: Self.key)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.state.captureEnabled)
    }

    // MARK: - Per-field isolation

    func testSetterPersistsOnlyItsOwnFieldEffect() throws {
        var seeded = iQualizeState.defaultState
        seeded.balance = 0.25
        seeded.maxGainDB = 9
        seeded.preEqLineColorHex = "#112233"
        seeded.snapToSemitone = true
        try seed(seeded)

        let store = SettingsStore(userDefaults: defaults)
        store.set(\.bypassed, true)

        let reloaded = try persistedState()
        XCTAssertTrue(reloaded.bypassed)
        XCTAssertEqual(reloaded.balance, 0.25)
        XCTAssertEqual(reloaded.maxGainDB, 9)
        XCTAssertEqual(reloaded.preEqLineColorHex, "#112233")
        XCTAssertTrue(reloaded.snapToSemitone)
    }

    func testOptionalFieldCanBeSetAndCleared() throws {
        let store = SettingsStore(userDefaults: defaults)
        store.set(\.dreamTheme, "dark")
        XCTAssertEqual(try persistedState().dreamTheme, "dark")
        store.set(\.dreamTheme, nil)
        XCTAssertNil(try persistedState().dreamTheme)
    }

    // MARK: - Interleaved / modal-style writes

    /// The bug #177 fixes: with the old load-modify-save pattern, a write made
    /// while a modal spins the run loop was clobbered when the enclosing code
    /// saved its stale snapshot. With one owned instance, both writes land.
    func testWriteDuringModalSurvivesEnclosingWrite() throws {
        let store = SettingsStore(userDefaults: defaults)

        // Enclosing operation reads state, then a "modal" runs and another
        // writer mutates a different field, then the enclosing operation
        // completes its own write.
        XCTAssertFalse(store.state.bypassed)
        // Simulated modal-interleaved write (e.g. CLI handler on the main actor):
        store.set(\.balance, 0.5)
        // Enclosing operation resumes and writes its field:
        store.set(\.bypassed, true)

        let reloaded = try persistedState()
        XCTAssertTrue(reloaded.bypassed)
        XCTAssertEqual(reloaded.balance, 0.5)
    }

    func testWriteInsideUpdateTransactionSeesLiveState() throws {
        let store = SettingsStore(userDefaults: defaults)
        store.set(\.inputGainDB, -3)
        store.update {
            // Transaction sees the earlier write and adds to the same instance.
            XCTAssertEqual($0.inputGainDB, -3)
            $0.outputGainDB = 2
            $0.linkGainGlobally = true
        }
        let reloaded = try persistedState()
        XCTAssertEqual(reloaded.inputGainDB, -3)
        XCTAssertEqual(reloaded.outputGainDB, 2)
        XCTAssertTrue(reloaded.linkGainGlobally)
    }

    // MARK: - Round-trip compatibility

    func testExistingBlobDecodesIdenticallyThroughStore() throws {
        var state = iQualizeState.defaultState
        state.captureEnabled = false
        state.selectedPresetID = EQPresetData.bassBoost.id
        state.peakLimiter = false
        state.windowOpen = true
        state.maxGainDB = 18
        state.bypassed = true
        state.autoScale = false
        state.preEqSpectrumEnabled = true
        state.postEqSpectrumEnabled = true
        state.hideFromDock = true
        state.startAtLogin = true
        state.balance = -0.5
        state.splitChannelEnabled = true
        state.activeChannel = "right"
        state.inputGainDB = -6
        state.outputGainDB = 3
        state.linkGainGlobally = true
        state.showBandwidthAsQ = false
        state.preEqLineColorHex = "#AABBCC"
        state.postEqLineColorHex = "#DDEEFF"
        state.preEqFillColorHex = "#001122"
        state.postEqFillColorHex = "#334455"
        state.preEqFillEnabled = true
        state.postEqFillEnabled = false
        state.dreamTheme = "light"
        state.snapToSemitone = true
        state.zoomRange = "bass"
        try seed(state)

        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.state, state)
    }

    func testAllFieldsRoundTripThroughSetters() throws {
        let store = SettingsStore(userDefaults: defaults)
        let presetID = UUID()
        store.set(\.captureEnabled, false)
        store.set(\.selectedPresetID, presetID)
        store.set(\.peakLimiter, false)
        store.set(\.windowOpen, true)
        store.set(\.maxGainDB, 24)
        store.set(\.bypassed, true)
        store.set(\.autoScale, false)
        store.set(\.preEqSpectrumEnabled, true)
        store.set(\.postEqSpectrumEnabled, true)
        store.set(\.hideFromDock, true)
        store.set(\.startAtLogin, true)
        store.set(\.balance, 0.75)
        store.set(\.splitChannelEnabled, true)
        store.set(\.activeChannel, "left")
        store.set(\.inputGainDB, -12)
        store.set(\.outputGainDB, 6)
        store.set(\.linkGainGlobally, true)
        store.set(\.showBandwidthAsQ, false)
        store.set(\.preEqLineColorHex, "#010203")
        store.set(\.postEqLineColorHex, "#040506")
        store.set(\.preEqFillColorHex, "#070809")
        store.set(\.postEqFillColorHex, "#0A0B0C")
        store.set(\.preEqFillEnabled, true)
        store.set(\.postEqFillEnabled, false)
        store.set(\.dreamTheme, "dark")
        store.set(\.snapToSemitone, true)
        store.set(\.zoomRange, "treble")

        // A fresh store over the same defaults sees the identical state.
        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.state, store.state)
        XCTAssertEqual(reloaded.state.selectedPresetID, presetID)
    }

    /// The persisted keys are the property names — no renames, no key mapping.
    func testPersistedKeysUnchanged() throws {
        let store = SettingsStore(userDefaults: defaults)
        store.set(\.bypassed, true)
        let json = try persistedJSON()
        let expectedKeys: Set<String> = [
            "captureEnabled", "selectedPresetID", "peakLimiter", "windowOpen",
            "maxGainDB", "bypassed", "autoScale", "preEqSpectrumEnabled",
            "postEqSpectrumEnabled", "hideFromDock", "startAtLogin", "balance",
            "splitChannelEnabled", "inputGainDB", "outputGainDB",
            "linkGainGlobally", "showBandwidthAsQ", "preEqFillEnabled",
            "postEqFillEnabled", "snapToSemitone",
        ]
        // Optional nil fields are omitted by JSONEncoder; assert the
        // non-optional keys are all present under their exact names.
        XCTAssertTrue(expectedKeys.isSubset(of: Set(json.keys)),
                      "missing keys: \(expectedKeys.subtracting(json.keys))")
    }
}

extension iQualizeState: Swift.Equatable {
    public static func == (lhs: iQualizeState, rhs: iQualizeState) -> Bool {
        lhs.captureEnabled == rhs.captureEnabled
            && lhs.selectedPresetID == rhs.selectedPresetID
            && lhs.peakLimiter == rhs.peakLimiter
            && lhs.windowOpen == rhs.windowOpen
            && lhs.maxGainDB == rhs.maxGainDB
            && lhs.bypassed == rhs.bypassed
            && lhs.autoScale == rhs.autoScale
            && lhs.preEqSpectrumEnabled == rhs.preEqSpectrumEnabled
            && lhs.postEqSpectrumEnabled == rhs.postEqSpectrumEnabled
            && lhs.hideFromDock == rhs.hideFromDock
            && lhs.startAtLogin == rhs.startAtLogin
            && lhs.balance == rhs.balance
            && lhs.splitChannelEnabled == rhs.splitChannelEnabled
            && lhs.activeChannel == rhs.activeChannel
            && lhs.inputGainDB == rhs.inputGainDB
            && lhs.outputGainDB == rhs.outputGainDB
            && lhs.linkGainGlobally == rhs.linkGainGlobally
            && lhs.showBandwidthAsQ == rhs.showBandwidthAsQ
            && lhs.preEqLineColorHex == rhs.preEqLineColorHex
            && lhs.postEqLineColorHex == rhs.postEqLineColorHex
            && lhs.preEqFillColorHex == rhs.preEqFillColorHex
            && lhs.postEqFillColorHex == rhs.postEqFillColorHex
            && lhs.preEqFillEnabled == rhs.preEqFillEnabled
            && lhs.postEqFillEnabled == rhs.postEqFillEnabled
            && lhs.dreamTheme == rhs.dreamTheme
            && lhs.snapToSemitone == rhs.snapToSemitone
            && lhs.zoomRange == rhs.zoomRange
    }
}
