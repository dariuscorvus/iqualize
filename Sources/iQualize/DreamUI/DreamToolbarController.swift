import AppKit
import SwiftUI

/// Native `NSToolbar` replacement for the old in-content `DreamToolbar` SwiftUI row.
/// Builds one `NSToolbarItem` per control and keeps their enabled/image/title state in sync
/// with `DreamViewModel` via `refresh()`, called from the same hooks that used to drive
/// `EQWindowController.refreshWindowTitle()`.
@available(macOS 14.2, *)
@MainActor
final class DreamToolbarController: NSObject, NSToolbarDelegate {
    private let vm: DreamViewModel

    private let undoItem: NSToolbarItem
    private let redoItem: NSToolbarItem
    private let presetPickerItem: NSToolbarItem
    private let newItem: NSToolbarItem
    private let saveItem: NSMenuToolbarItem
    private let resetItem: NSToolbarItem
    private let deleteItem: NSToolbarItem
    private let snapItem: NSToolbarItem
    private let pinItem: NSToolbarItem
    private let settingsItem: NSToolbarItem

    private let presetPickerButton: NSButton
    private let snapButton: NSButton

    init(vm: DreamViewModel) {
        self.vm = vm

        undoItem = NSToolbarItem(itemIdentifier: .dreamUndo)
        undoItem.label = "Undo"
        undoItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        undoItem.toolTip = "Undo"

        redoItem = NSToolbarItem(itemIdentifier: .dreamRedo)
        redoItem.label = "Redo"
        redoItem.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")
        redoItem.toolTip = "Redo"

        let pickerButton = NSButton()
        pickerButton.bezelStyle = .rounded
        pickerButton.controlSize = .regular
        pickerButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        pickerButton.lineBreakMode = .byTruncatingTail
        pickerButton.imageHugsTitle = true
        pickerButton.toolTip = "Preset"
        presetPickerButton = pickerButton
        presetPickerItem = NSToolbarItem(itemIdentifier: .dreamPresetPicker)
        presetPickerItem.label = "Preset"
        presetPickerItem.view = pickerButton
        presetPickerItem.visibilityPriority = .high

        newItem = NSToolbarItem(itemIdentifier: .dreamNew)
        newItem.label = "New"
        newItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Preset")
        newItem.toolTip = "New Preset"

        saveItem = NSMenuToolbarItem(itemIdentifier: .dreamSave)
        saveItem.label = "Save"
        saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Preset")
        saveItem.showsIndicator = true
        saveItem.toolTip = "Save Preset"

        resetItem = NSToolbarItem(itemIdentifier: .dreamReset)
        resetItem.label = "Reset"
        resetItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Preset")
        resetItem.toolTip = "Reset Preset"

        deleteItem = NSToolbarItem(itemIdentifier: .dreamDelete)
        deleteItem.label = "Delete"
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete Preset")
        deleteItem.toolTip = "Delete Preset"

        let snapBtn = NSButton()
        snapBtn.bezelStyle = .texturedRounded
        snapBtn.setButtonType(.pushOnPushOff)
        snapBtn.image = MagnetIcon.image
        snapBtn.imagePosition = .imageOnly
        snapButton = snapBtn
        snapItem = NSToolbarItem(itemIdentifier: .dreamSnap)
        snapItem.label = "Snap"
        snapItem.view = snapBtn
        snapItem.toolTip = "Snap band frequencies to semitones"

        pinItem = NSToolbarItem(itemIdentifier: .dreamPin)
        pinItem.label = "Pin"
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin to Device")

        settingsItem = NSToolbarItem(itemIdentifier: .dreamSettings)
        settingsItem.label = "Settings"
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsItem.toolTip = "Settings"

        super.init()

        undoItem.target = self
        undoItem.action = #selector(undoTapped)
        redoItem.target = self
        redoItem.action = #selector(redoTapped)
        pickerButton.target = self
        pickerButton.action = #selector(showPresetMenu(_:))
        newItem.target = self
        newItem.action = #selector(newTapped)
        saveItem.target = self
        saveItem.action = #selector(saveTapped)
        resetItem.target = self
        resetItem.action = #selector(resetTapped)
        deleteItem.target = self
        deleteItem.action = #selector(deleteTapped)
        snapBtn.target = self
        snapBtn.action = #selector(snapToggled(_:))
        pinItem.target = self
        pinItem.action = #selector(pinTapped)
        settingsItem.target = self
        settingsItem.action = #selector(settingsTapped)

        rebuildSaveMenu()
        refresh()
    }

    /// Re-reads view model state into the toolbar items. Call after any action that can
    /// change undo/redo availability, preset identity, modified state, pin state, or snap state.
    func refresh() {
        undoItem.isEnabled = vm.canUndo
        redoItem.isEnabled = vm.canRedo

        let suffix = vm.isBuiltIn ? " (Built-in)" : ""
        presetPickerButton.title = "\(vm.presetName)\(suffix)"
        presetPickerButton.image = vm.isModified ? DreamToolbarController.modifiedDotImage : nil
        presetPickerButton.imagePosition = vm.isModified ? .imageRight : .noImage

        resetItem.isEnabled = vm.isModified
        deleteItem.isEnabled = vm.activePresetID != EQPresetData.flat.id
        rebuildSaveMenu()

        snapButton.state = vm.snapToSemitone ? .on : .off

        let isPinned = vm.isCurrentDevicePinnedToActivePreset
        pinItem.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: "Pin to Device"
        )
        pinItem.isEnabled = !(vm.isModified && !isPinned)
        pinItem.toolTip = isPinned
            ? "Unpin from \(vm.outputDeviceName)"
            : vm.isModified
                ? "Save this preset before pinning it"
                : "Pin to \(vm.outputDeviceName)"
    }

    private func rebuildSaveMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Save As…", action: #selector(saveAsTapped), keyEquivalent: "S").target = self
        if vm.isBuiltIn && vm.presetStore.hasOverride(vm.activePresetID) {
            menu.addItem(withTitle: "Reset to Original", action: #selector(resetToOriginalTapped), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Import Preset…", action: #selector(importTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preset Browser…", action: #selector(presetBrowserTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Export Preset…", action: #selector(exportTapped), keyEquivalent: "").target = self
        saveItem.menu = menu
    }

    private static let modifiedDotImage: NSImage = {
        let size = NSSize(width: 6, height: 6)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    // MARK: - Actions

    @objc private func undoTapped() { vm.undo() }
    @objc private func redoTapped() { vm.redo() }
    @objc private func newTapped() { vm.newPreset() }
    @objc private func saveTapped() { vm.savePreset() }
    @objc private func resetTapped() { vm.resetToSnapshot() }
    @objc private func deleteTapped() { vm.deleteCurrentPreset() }
    @objc private func pinTapped() { vm.toggleDevicePin() }
    @objc private func settingsTapped() { vm.onOpenSettings?() }

    @objc private func saveAsTapped() { vm.presentSaveAsDialog() }
    @objc private func resetToOriginalTapped() { vm.resetActiveBuiltInToOriginal() }
    @objc private func importTapped() { vm.importPresets() }
    @objc private func presetBrowserTapped() { vm.showPresetBrowser() }
    @objc private func exportTapped() { vm.exportActivePreset() }

    @objc private func snapToggled(_ sender: NSButton) {
        vm.snapToSemitone = sender.state == .on
        vm.persistSnap()
    }

    @objc private func showPresetMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        PresetMenuBuilder.addFavorites(
            to: menu, presets: vm.presetStore.favoritePresets, activePresetID: vm.activePresetID,
            onSelect: { [weak self] id in self?.selectPreset(id); menu.cancelTracking() },
            onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
        )
        PresetMenuBuilder.addPresetSections(
            to: menu, builtIn: vm.presetStore.allPresets.filter(\.isBuiltIn), custom: vm.presetStore.customPresets,
            favoriteIDs: Set(vm.presetStore.favoritePresetIDs), activePresetID: vm.activePresetID,
            onSelect: { [weak self] id in self?.selectPreset(id); menu.cancelTracking() },
            onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
        )

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func selectPreset(_ id: UUID) {
        vm.loadPreset(id: id)
    }

    private func toggleFavorite(_ id: UUID) -> Bool {
        vm.presetStore.toggleFavorite(id)
        return vm.presetStore.isFavorite(id)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .dreamUndo: return undoItem
        case .dreamRedo: return redoItem
        case .dreamPresetPicker: return presetPickerItem
        case .dreamNew: return newItem
        case .dreamSave: return saveItem
        case .dreamReset: return resetItem
        case .dreamDelete: return deleteItem
        case .dreamSnap: return snapItem
        case .dreamPin: return pinItem
        case .dreamSettings: return settingsItem
        default: return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .dreamUndo, .dreamRedo, .dreamPresetPicker, .dreamNew, .dreamSave, .dreamReset, .dreamDelete,
            .flexibleSpace,
            .dreamSnap, .dreamPin, .dreamSettings,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }
}

@available(macOS 14.2, *)
extension NSToolbarItem.Identifier {
    static let dreamUndo = NSToolbarItem.Identifier("dreamUndo")
    static let dreamRedo = NSToolbarItem.Identifier("dreamRedo")
    static let dreamPresetPicker = NSToolbarItem.Identifier("dreamPresetPicker")
    static let dreamNew = NSToolbarItem.Identifier("dreamNew")
    static let dreamSave = NSToolbarItem.Identifier("dreamSave")
    static let dreamReset = NSToolbarItem.Identifier("dreamReset")
    static let dreamDelete = NSToolbarItem.Identifier("dreamDelete")
    static let dreamSnap = NSToolbarItem.Identifier("dreamSnap")
    static let dreamPin = NSToolbarItem.Identifier("dreamPin")
    static let dreamSettings = NSToolbarItem.Identifier("dreamSettings")
}
