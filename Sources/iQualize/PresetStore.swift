import Foundation
import Observation
import os.log

private let storeLog = OSLog(subsystem: "com.iqualize", category: "presets")

@available(macOS 14.2, *)
@Observable
@MainActor
final class PresetStore {
    private(set) var customPresets: [EQPresetData] = []
    /// Pinned/favorited preset IDs, in the order they were favorited.
    private(set) var favoritePresetIDs: [UUID] = []
    /// Built-in presets the user has deleted from their picker. Flat can never appear here.
    private(set) var hiddenBuiltInPresetIDs: [UUID] = []
    /// Preset pinned per output device, keyed by the device's stable CoreAudio UID.
    private(set) var pinnedPresetIDByDeviceUID: [String: UUID] = [:]
    /// Built-in presets the user has edited and saved in place, keyed by the built-in's own
    /// (stable) id. A built-in with no entry here is still exactly what shipped. Independent
    /// of `hiddenBuiltInPresetIDs` — a built-in can be hidden, overridden, both, or neither.
    private(set) var builtInOverrides: [UUID: EQPresetData] = [:]

    /// Human-readable descriptions of persisted blobs that failed to decode at load time.
    /// Empty when everything loaded cleanly. The corrupt raw data is preserved under a
    /// timestamped backup key (see `backUpCorruptBlob`) — never silently discarded.
    private(set) var loadFailures: [String] = []

    var allPresets: [EQPresetData] {
        EQPresetData.builtInPresets
            .filter { !hiddenBuiltInPresetIDs.contains($0.id) }
            .map(resolved) + customPresets
    }

    /// Favorited presets, in favorite order. Skips IDs that no longer resolve to a preset.
    var favoritePresets: [EQPresetData] {
        favoritePresetIDs.compactMap { preset(for: $0) }
    }

    /// Built-in presets currently hidden from the picker — shown in the Preset Browser's
    /// iQualize tab so they can be brought back. Reflects any saved edits, not the pristine
    /// original, so "Restore" brings back what the user last saved.
    var hiddenBuiltInPresets: [EQPresetData] {
        EQPresetData.builtInPresets.filter { hiddenBuiltInPresetIDs.contains($0.id) }.map(resolved)
    }

    /// Built-in presets the user has edited and saved in place, in catalog order — shown in
    /// the Preset Browser's iQualize tab so they can be reset back to their original values.
    var overriddenBuiltInPresets: [EQPresetData] {
        EQPresetData.builtInPresets.compactMap { builtInOverrides[$0.id] }
    }

    /// Resolves a built-in to its saved override, or itself if untouched.
    private func resolved(_ builtIn: EQPresetData) -> EQPresetData {
        builtInOverrides[builtIn.id] ?? builtIn
    }

    private static let key = "com.iqualize.customPresets"
    private static let favoritesKey = "com.iqualize.favoritePresetIDs"
    private static let hiddenBuiltInsKey = "com.iqualize.hiddenBuiltInPresetIDs"
    private static let devicePinsKey = "com.iqualize.pinnedPresetsByDevice"
    private static let builtInOverridesKey = "com.iqualize.builtInOverrides"

    /// Injectable so tests can use an isolated suite instead of polluting the real app's
    /// persisted state (or leaking test data between runs).
    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        load()
    }

    func preset(for id: UUID) -> EQPresetData? {
        allPresets.first { $0.id == id }
    }

    func isFavorite(_ id: UUID) -> Bool {
        favoritePresetIDs.contains(id)
    }

    func toggleFavorite(_ id: UUID) {
        if let index = favoritePresetIDs.firstIndex(of: id) {
            favoritePresetIDs.remove(at: index)
        } else {
            favoritePresetIDs.append(id)
        }
        persistFavorites()
    }

    func pinnedPresetID(forDeviceUID uid: String) -> UUID? {
        pinnedPresetIDByDeviceUID[uid]
    }

    func pinnedPreset(forDeviceUID uid: String) -> EQPresetData? {
        pinnedPresetID(forDeviceUID: uid).flatMap { preset(for: $0) }
    }

    func pinPreset(_ id: UUID, toDeviceUID uid: String) {
        pinnedPresetIDByDeviceUID[uid] = id
        persistDevicePins()
    }

    func unpinPreset(fromDeviceUID uid: String) {
        pinnedPresetIDByDeviceUID.removeValue(forKey: uid)
        persistDevicePins()
    }

    func saveCustomPreset(_ preset: EQPresetData) {
        if let index = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[index] = preset
        } else {
            customPresets.append(preset)
        }
        persist()
    }

    func deleteCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
        persist()
        if favoritePresetIDs.contains(id) {
            favoritePresetIDs.removeAll { $0 == id }
            persistFavorites()
        }
        if pinnedPresetIDByDeviceUID.values.contains(id) {
            pinnedPresetIDByDeviceUID = pinnedPresetIDByDeviceUID.filter { $0.value != id }
            persistDevicePins()
        }
    }

    /// Hides a built-in preset from the picker. Flat is protected — several places in the app
    /// assume it always exists as a safe fallback, so it can never be hidden.
    func hideBuiltInPreset(id: UUID) {
        guard id != EQPresetData.flat.id, !hiddenBuiltInPresetIDs.contains(id) else { return }
        hiddenBuiltInPresetIDs.append(id)
        persistHiddenBuiltIns()
        if favoritePresetIDs.contains(id) {
            favoritePresetIDs.removeAll { $0 == id }
            persistFavorites()
        }
        if pinnedPresetIDByDeviceUID.values.contains(id) {
            pinnedPresetIDByDeviceUID = pinnedPresetIDByDeviceUID.filter { $0.value != id }
            persistDevicePins()
        }
    }

    /// Brings a hidden built-in preset back into the picker.
    func restoreBuiltInPreset(id: UUID) {
        hiddenBuiltInPresetIDs.removeAll { $0 == id }
        persistHiddenBuiltIns()
    }

    /// Whether `id` (a built-in's id) currently has a saved override.
    func hasOverride(_ id: UUID) -> Bool {
        builtInOverrides[id] != nil
    }

    /// Saves `preset` as the in-place override for the built-in it belongs to. No-ops for a
    /// non-built-in — use `saveCustomPreset` for those.
    func saveBuiltInOverride(_ preset: EQPresetData) {
        guard preset.isBuiltIn else { return }
        builtInOverrides[preset.id] = preset
        persistBuiltInOverrides()
    }

    /// Discards the saved override for the built-in `id`, reverting it back to whatever
    /// `EQPresetData.builtInPresets` ships. A no-op if there's no override.
    func resetBuiltInToOriginal(id: UUID) {
        guard builtInOverrides.removeValue(forKey: id) != nil else { return }
        persistBuiltInOverrides()
    }

    /// Appends " 2", " 3", ... to `base` until it doesn't collide (exact match) with any
    /// current preset name. Used by the CLI's `duplicate` command.
    func dedupedName(base: String) -> String {
        let existing = Set(allPresets.map { $0.name })
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func load() {
        if let presets = loadBlob([EQPresetData].self, key: Self.key, describedAs: "Custom presets") {
            customPresets = presets
        }
        if let ids = loadBlob([UUID].self, key: Self.favoritesKey, describedAs: "Favorite presets") {
            favoritePresetIDs = ids
        }
        if let ids = loadBlob([UUID].self, key: Self.hiddenBuiltInsKey, describedAs: "Hidden built-in presets") {
            hiddenBuiltInPresetIDs = ids
        }
        if let pins = loadBlob([String: UUID].self, key: Self.devicePinsKey, describedAs: "Per-device preset pins") {
            pinnedPresetIDByDeviceUID = pins
        }
        if let overrides = loadBlob([UUID: EQPresetData].self, key: Self.builtInOverridesKey, describedAs: "Built-in preset edits") {
            builtInOverrides = overrides
        }
    }

    /// Decodes one persisted blob. A missing key is normal (fresh install) and returns nil
    /// silently. A decode failure preserves the raw bytes under a timestamped backup key,
    /// logs, records a user-facing message in `loadFailures`, and returns nil so the caller
    /// keeps its default — the damaged original is never the only copy when a later
    /// `persist*()` overwrites the primary key.
    private func loadBlob<T: Decodable>(_ type: T.Type, key: String, describedAs description: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let backupKey = backUpCorruptBlob(data, key: key)
            os_log(.error, log: storeLog,
                   "failed to decode %{public}@ (%{public}@): %{public}@ — raw data preserved under %{public}@",
                   key, description, String(describing: error), backupKey)
            loadFailures.append("\(description) couldn't be read — original data preserved")
            return nil
        }
    }

    /// Writes the corrupt raw bytes under `<key>.corrupt.<ISO8601 timestamp>`. Backup keys
    /// are disjoint from every `persist*()` key, so later saves can never clobber them.
    /// Returns the backup key used.
    private func backUpCorruptBlob(_ data: Data, key: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var backupKey = "\(key).corrupt.\(timestamp)"
        // A stored object at the candidate key means an earlier corruption was already
        // preserved this second — suffix rather than overwrite an existing backup.
        var n = 2
        while defaults.object(forKey: backupKey) != nil {
            backupKey = "\(key).corrupt.\(timestamp).\(n)"
            n += 1
        }
        defaults.set(data, forKey: backupKey)
        return backupKey
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customPresets) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoritePresetIDs) {
            defaults.set(data, forKey: Self.favoritesKey)
        }
    }

    private func persistHiddenBuiltIns() {
        if let data = try? JSONEncoder().encode(hiddenBuiltInPresetIDs) {
            defaults.set(data, forKey: Self.hiddenBuiltInsKey)
        }
    }

    private func persistDevicePins() {
        if let data = try? JSONEncoder().encode(pinnedPresetIDByDeviceUID) {
            defaults.set(data, forKey: Self.devicePinsKey)
        }
    }

    private func persistBuiltInOverrides() {
        if let data = try? JSONEncoder().encode(builtInOverrides) {
            defaults.set(data, forKey: Self.builtInOverridesKey)
        }
    }
}
