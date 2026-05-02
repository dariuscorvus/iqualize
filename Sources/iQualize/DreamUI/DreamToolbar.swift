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
            ForEach(vm.presetStore.allPresets, id: \.id) { preset in
                Button(action: { vm.loadPreset(id: preset.id) }) {
                    if preset.id == vm.activePresetID {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
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
            .disabled(vm.isBuiltIn)
    }

    @ViewBuilder
    private var rightGroup: some View {
        Toggle(isOn: Binding(
            get: { vm.snapToSemitone },
            set: { vm.snapToSemitone = $0; vm.persistSnap() }
        )) {
            HStack(spacing: 4) {
                Image(systemName: "music.note").font(.system(size: 11))
                Text("Snap")
            }
        }
        .toggleStyle(.button)
        .controlSize(.regular)

        Menu {
            Picker("Theme", selection: Binding(
                get: { vm.theme },
                set: { vm.theme = $0; vm.persistTheme() }
            )) {
                Text("Auto").tag(DreamThemePreference.auto)
                Text("Light").tag(DreamThemePreference.light)
                Text("Dark").tag(DreamThemePreference.dark)
            }
        } label: {
            Image(systemName: vm.theme.systemImage).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.regular)
        .fixedSize()

        Button(action: { vm.onOpenSettings?() }) {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
        }
        .controlSize(.regular)
    }

    private var presetButtonLabel: String {
        let suffix = vm.isBuiltIn ? " (Built-in)" : ""
        return "\(vm.presetName)\(suffix)"
    }
}
