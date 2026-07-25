import SwiftUI

/// Native sidebar alternative to the toolbar's menu-based preset picker (issue #104). Lists the
/// same presets the picker shows — favorites, then built-in, then custom — reading straight from
/// the same `DreamViewModel`/`PresetStore` instances the toolbar picker uses, so selecting,
/// favoriting, and deleting here need no separate sync path: `@Observable` propagation keeps the
/// toolbar button, the menu bar dropdown, and this list in lockstep automatically.
@available(macOS 14.2, *)
struct PresetSidebarView: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme
    @State private var searchText = ""

    /// Fixed width of the sidebar column, including its trailing divider — shared with
    /// `DreamRootView`/`DreamHostingView` so the window grows/shrinks by exactly this much
    /// when the sidebar is toggled.
    static let width: CGFloat = 220

    private var favorites: [EQPresetData] { filtered(vm.presetStore.favoritePresets) }
    private var builtIn: [EQPresetData] { filtered(vm.presetStore.builtInPresets) }
    private var custom: [EQPresetData] { filtered(vm.presetStore.customPresets) }

    private func filtered(_ presets: [EQPresetData]) -> [EQPresetData] {
        guard !searchText.isEmpty else { return presets }
        return presets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Two-way: reflects `vm.activePresetID` so the list highlight tracks preset changes made
    /// from the toolbar picker or menu bar, and routes a row click through `vm.loadPreset(id:)`
    /// (unsaved-changes confirmation included) rather than mutating selection directly — if that
    /// confirmation is cancelled, the getter simply resolves back to the unchanged id.
    private var selection: Binding<UUID?> {
        Binding(
            get: { vm.activePresetID },
            set: { newValue in
                guard let id = newValue, id != vm.activePresetID else { return }
                vm.loadPreset(id: id)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PresetSearchField(text: $searchText)
            Divider()
            List(selection: selection) {
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { row($0) }
                    }
                }
                Section("Built-in") {
                    ForEach(builtIn) { row($0) }
                }
                if !custom.isEmpty {
                    Section("Custom") {
                        ForEach(custom) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: Self.width - 1)
        .background(theme.bgToolbar)
    }

    @ViewBuilder
    private func row(_ preset: EQPresetData) -> some View {
        let isFavorite = vm.presetStore.isFavorite(preset.id)
        HStack(spacing: 6) {
            Text(preset.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                vm.presetStore.toggleFavorite(preset.id)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .tag(preset.id)
        .contextMenu {
            Button(isFavorite ? "Remove Favorite" : "Add to Favorites") {
                vm.presetStore.toggleFavorite(preset.id)
            }
            if preset.id != EQPresetData.flat.id {
                Divider()
                Button(preset.isBuiltIn ? "Hide" : "Delete") {
                    vm.deletePreset(id: preset.id)
                }
            }
        }
    }
}
