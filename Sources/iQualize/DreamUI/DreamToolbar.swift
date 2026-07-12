import AppKit
import SwiftUI

@available(macOS 14.2, *)
struct DreamToolbar: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            DreamToolbarGroup {
                undoRedoGroup
            }
            DreamToolbarGroup {
                presetGroup
            }
            Spacer()
            DreamToolbarGroup(trailingDivider: false) {
                rightGroup
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.bgToolbar)
    }

    @ViewBuilder
    private var undoRedoGroup: some View {
        Button(action: { vm.undo() }) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .medium))
        }
        .controlSize(.regular)
        .disabled(!vm.canUndo)
        .keyboardShortcut("z", modifiers: .command)

        Button(action: { vm.redo() }) {
            Image(systemName: "arrow.uturn.forward").font(.system(size: 12, weight: .medium))
        }
        .controlSize(.regular)
        .disabled(!vm.canRedo)
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var presetGroup: some View {
        Menu {
            let favorites = vm.presetStore.favoritePresets
            if !favorites.isEmpty {
                ForEach(favorites, id: \.id) { preset in
                    presetButton(for: preset)
                }
                Divider()
            }
            ForEach(vm.presetStore.allPresets, id: \.id) { preset in
                presetButton(for: preset)
            }
            Divider()
            Text("⌥-click a preset to pin/unpin")
        } label: {
            HStack(spacing: 4) {
                Text(presetButtonLabel)
                if vm.isModified {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                }
            }
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .fixedSize()

        Button("New") { vm.newPreset() }

        Menu {
            Button("Save") {
                if vm.isBuiltIn { vm.presentSaveAsDialog() } else { vm.savePreset() }
            }
            .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { vm.presentSaveAsDialog() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Preset…") { vm.importPresets() }
            Button("Preset Browser…") { vm.showPresetBrowser() }
            Button("Export Preset…") { vm.exportActivePreset() }
        } label: {
            Text("Save")
        } primaryAction: {
            if vm.isBuiltIn { vm.presentSaveAsDialog() } else { vm.savePreset() }
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .fixedSize()

        Button("Reset") { vm.resetToSnapshot() }
            .disabled(!vm.isModified)
        Button("Delete") { vm.deleteCurrentPreset() }
            .disabled(vm.activePresetID == EQPresetData.flat.id)
    }

    @ViewBuilder
    private var rightGroup: some View {
        Toggle(isOn: Binding(
            get: { vm.snapToSemitone },
            set: { vm.snapToSemitone = $0; vm.persistSnap() }
        )) {
            MagnetIcon(size: 15)
        }
        .toggleStyle(.button)
        .controlSize(.regular)
        .help("Snap band frequencies to semitones")

        Button(action: { vm.onOpenSettings?() }) {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
        }
        .controlSize(.regular)
        .help("Settings")
    }

    private var presetButtonLabel: String {
        let suffix = vm.isBuiltIn ? " (Built-in)" : ""
        return "\(vm.presetName)\(suffix)"
    }

    @ViewBuilder
    private func presetButton(for preset: EQPresetData) -> some View {
        Button(action: {
            if NSEvent.modifierFlags.contains(.option) {
                vm.presetStore.toggleFavorite(preset.id)
            } else {
                vm.loadPreset(id: preset.id)
            }
        }) {
            if preset.id == vm.activePresetID {
                Label(preset.name, systemImage: "checkmark")
            } else if vm.presetStore.isFavorite(preset.id) {
                Label(preset.name, systemImage: "pin.fill")
            } else {
                Text(preset.name)
            }
        }
    }
}
