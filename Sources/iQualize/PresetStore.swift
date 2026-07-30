import Foundation
import Observation

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

    var allPresets: [EQPresetData] {
        EQPresetData.builtInPresets.filter { !hiddenBuiltInPresetIDs.contains($0.id) } + customPresets
    }

    /// Favorited presets, in favorite order. Skips IDs that no longer resolve to a preset.
    var favoritePresets: [EQPresetData] {
        favoritePresetIDs.compactMap { preset(for: $0) }
    }

    /// Built-in presets currently hidden from the picker — shown in the Preset Browser's
    /// iQualize tab so they can be brought back.
    var hiddenBuiltInPresets: [EQPresetData] {
        EQPresetData.builtInPresets.filter { hiddenBuiltInPresetIDs.contains($0.id) }
    }

    private static let key = "com.iqualize.customPresets"
    private static let favoritesKey = "com.iqualize.favoritePresetIDs"
    private static let hiddenBuiltInsKey = "com.iqualize.hiddenBuiltInPresetIDs"
    private static let devicePinsKey = "com.iqualize.pinnedPresetsByDevice"

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

    /// Returns a "(Custom)" fork of `preset` (deduped name against `allPresets`) if it's
    /// built-in; returns `preset` unchanged otherwise. Pure — does not persist and does not
    /// touch AudioEngine; callers decide whether/when to call `saveCustomPreset`.
    func forkIfBuiltIn(_ preset: EQPresetData) -> EQPresetData {
        guard preset.isBuiltIn else { return preset }
        return EQPresetData(
            id: UUID(),
            name: dedupedName(base: "\(preset.name) (Custom)"),
            bands: preset.bands,
            rightBands: preset.rightBands,
            isBuiltIn: false,
            inputGainDB: preset.inputGainDB,
            outputGainDB: preset.outputGainDB
        )
    }

    /// Appends " 2", " 3", ... to `base` until it doesn't collide (exact match) with any
    /// current preset name. Shared by `forkIfBuiltIn` and the CLI's `duplicate` command.
    func dedupedName(base: String) -> String {
        let existing = Set(allPresets.map { $0.name })
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func load() {
        if let data = defaults.data(forKey: Self.key),
           let presets = try? JSONDecoder().decode([EQPresetData].self, from: data) {
            customPresets = presets
        }
        if let data = defaults.data(forKey: Self.favoritesKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            favoritePresetIDs = ids
        }
        if let data = defaults.data(forKey: Self.hiddenBuiltInsKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            hiddenBuiltInPresetIDs = ids
        }
        if let data = defaults.data(forKey: Self.devicePinsKey),
           let pins = try? JSONDecoder().decode([String: UUID].self, from: data) {
            pinnedPresetIDByDeviceUID = pins
        }
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
}
