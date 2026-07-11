import Foundation
import Observation

@available(macOS 14.2, *)
@Observable
@MainActor
final class PresetStore {
    private(set) var customPresets: [EQPresetData] = []
    /// Pinned/favorited preset IDs, in the order they were favorited.
    private(set) var favoritePresetIDs: [UUID] = []

    var allPresets: [EQPresetData] {
        EQPresetData.builtInPresets + customPresets
    }

    /// Favorited presets, in favorite order. Skips IDs that no longer resolve to a preset.
    var favoritePresets: [EQPresetData] {
        favoritePresetIDs.compactMap { preset(for: $0) }
    }

    private static let key = "com.iqualize.customPresets"
    private static let favoritesKey = "com.iqualize.favoritePresetIDs"

    init() {
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
    }

    /// Returns a "(Custom)" fork of `preset` (deduped name against `allPresets`) if it's
    /// built-in; returns `preset` unchanged otherwise. Pure — does not persist and does not
    /// touch AudioEngine; callers decide whether/when to call `saveCustomPreset`.
    func forkIfBuiltIn(_ preset: EQPresetData) -> EQPresetData {
        guard preset.isBuiltIn else { return preset }
        let baseName = "\(preset.name) (Custom)"
        let existing = allPresets.map { $0.name }
        var forkName = baseName
        if existing.contains(forkName) {
            var n = 2
            while existing.contains("\(baseName) \(n)") { n += 1 }
            forkName = "\(baseName) \(n)"
        }
        return EQPresetData(
            id: UUID(),
            name: forkName,
            bands: preset.bands,
            rightBands: preset.rightBands,
            isBuiltIn: false,
            inputGainDB: preset.inputGainDB,
            outputGainDB: preset.outputGainDB
        )
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let presets = try? JSONDecoder().decode([EQPresetData].self, from: data) {
            customPresets = presets
        }
        if let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            favoritePresetIDs = ids
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoritePresetIDs) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
    }
}
