import AppKit
import SwiftUI

/// Native NSButton + manually-popped NSMenu wrapper for the in-app preset picker, sharing
/// PresetMenuBuilder with the menu bar dropdown so both surfaces render/behave identically.
/// SwiftUI's `Menu` always closes on any item click, with no way to keep it open for
/// ⌥-click-to-favorite — an `NSPopUpButton`'s automatic pull-down has the same limitation,
/// so the menu here is built fresh and shown via `NSMenu.popUp` instead.
@available(macOS 14.2, *)
struct PresetPickerButton: NSViewRepresentable {
    var vm: DreamViewModel
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.title = label
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.vm = vm
        nsView.title = label
    }

    @MainActor
    final class Coordinator: NSObject {
        var vm: DreamViewModel
        init(vm: DreamViewModel) { self.vm = vm }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            PresetMenuBuilder.addFavorites(
                to: menu, presets: vm.presetStore.favoritePresets, activePresetID: vm.activePresetID,
                onSelect: { [weak self] id in self?.select(id); menu.cancelTracking() },
                onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
            )
            PresetMenuBuilder.addPresetSections(
                to: menu, builtIn: EQPresetData.builtInPresets, custom: vm.presetStore.customPresets,
                favoriteIDs: Set(vm.presetStore.favoritePresetIDs), activePresetID: vm.activePresetID,
                onSelect: { [weak self] id in self?.select(id); menu.cancelTracking() },
                onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
            )

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        private func select(_ id: UUID) {
            vm.loadPreset(id: id)
        }

        private func toggleFavorite(_ id: UUID) -> Bool {
            vm.presetStore.toggleFavorite(id)
            return vm.presetStore.isFavorite(id)
        }
    }
}
