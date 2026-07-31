import SwiftUI

/// Native sidebar preset list — an additional way to browse/select presets alongside the
/// toolbar's preset-picker popup menu (`DreamToolbarController.showPresetMenu`). Selection
/// routes through `vm.loadPreset(id:)` so the unsaved-changes confirmation gate
/// (`confirmDiscardIfNeeded`) applies exactly as it does for the toolbar menu.
@available(macOS 14.2, *)
@MainActor
struct PresetSidebarView: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let resolvedScheme: ColorScheme = vm.theme.colorScheme ?? systemScheme
        let theme = DreamTheme(scheme: resolvedScheme)

        List(selection: Binding(
            get: { vm.activePresetID },
            set: { newID in if let newID { vm.loadPreset(id: newID) } }
        )) {
            if !vm.presetStore.favoritePresets.isEmpty {
                Section("Favorites") {
                    ForEach(vm.presetStore.favoritePresets) { preset in
                        presetRow(preset, isFavorite: true)
                    }
                }
            }
            Section("Built-in") {
                ForEach(vm.presetStore.allPresets.filter(\.isBuiltIn)) { preset in
                    presetRow(preset, isFavorite: vm.presetStore.isFavorite(preset.id))
                }
            }
            if !vm.presetStore.customPresets.isEmpty {
                Section("Custom") {
                    ForEach(vm.presetStore.customPresets) { preset in
                        presetRow(preset, isFavorite: vm.presetStore.isFavorite(preset.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.dreamTheme, theme)
        .preferredColorScheme(vm.theme.colorScheme)
    }

    @ViewBuilder
    private func presetRow(_ preset: EQPresetData, isFavorite: Bool) -> some View {
        HStack {
            Text(preset.name)
            Spacer()
            Button {
                vm.presetStore.toggleFavorite(preset.id)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color(nsColor: .controlAccentColor) : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isFavorite ? 1 : 0.35)
        }
        .tag(preset.id)
    }
}
