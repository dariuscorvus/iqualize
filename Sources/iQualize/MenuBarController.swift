import AppKit
import IQControlProtocol

@available(macOS 14.2, *)
@MainActor
final class MenuBarController: NSObject, @preconcurrency NSMenuDelegate, CLICommandHandling {
    private var statusItem: NSStatusItem!
    private let audioEngine: AudioEngine
    private let presetStore: PresetStore
    private var eqWindowController: EQWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var helpWindowController: HelpWindowController?

    init(audioEngine: AudioEngine, presetStore: PresetStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore
        super.init()
        var state = iQualizeState.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // Rebuild menu on device changes
        audioEngine.onStateChange = { [weak self] in
            self?.updateIcon()
        }

        // Recall the preset pinned to a device the moment we switch to it.
        audioEngine.pinnedPresetProvider = { [weak presetStore] uid in
            presetStore?.pinnedPreset(forDeviceUID: uid)
        }

        // Restore saved state and always start EQ — a device pin for the current output
        // takes priority over the last-selected preset, since it's an explicit user choice.
        audioEngine.gainIsGlobal = state.linkGainGlobally
        let startupPreset = audioEngine.outputDeviceUID
            .flatMap { presetStore.pinnedPreset(forDeviceUID: $0) }
            ?? presetStore.preset(for: state.selectedPresetID)
        if let preset = startupPreset {
            audioEngine.activePreset = preset
            state.selectedPresetID = preset.id
            state.save()
        } else {
            audioEngine.activePreset = .flat
            state.selectedPresetID = EQPresetData.flat.id
            state.save()
        }
        audioEngine.peakLimiter = state.peakLimiter
        audioEngine.maxGainDB = state.maxGainDB
        audioEngine.bypassed = state.bypassed
        audioEngine.balance = state.balance
        if state.linkGainGlobally {
            audioEngine.inputGainDB = state.inputGainDB
            audioEngine.outputGainDB = state.outputGainDB
        }
        audioEngine.setEnabled(true)
        updateIcon()

        // Restore EQ window if it was open when the app last quit
        if state.windowOpen {
            openEQWindow()
        }
    }

    // MARK: - NSMenuDelegate — build menu fresh each time it opens

    func menuNeedsUpdate(_ menu: NSMenu) {
        if NSEvent.modifierFlags.contains(.option) {
            menu.removeAllItems()
            menu.cancelTracking()
            openEQWindow()
            return
        }
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Open standalone window
        let openItem = NSMenuItem(title: "Open iQualize",
                                   action: #selector(openEQSettings(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…",
                                       action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let activePresetID = audioEngine.activePreset.id
        PresetMenuBuilder.addFavorites(
            to: menu, presets: presetStore.favoritePresets, activePresetID: activePresetID,
            onSelect: { [weak self] id in self?.selectPresetAndClose(id: id) },
            onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
        )

        // Presets submenu
        let presetMenuItem = NSMenuItem(title: "Presets (\(audioEngine.activePreset.name))",
                                         action: nil, keyEquivalent: "")
        let presetSubmenu = NSMenu()
        PresetMenuBuilder.addPresetSections(
            to: presetSubmenu,
            builtIn: presetStore.allPresets.filter(\.isBuiltIn),
            custom: presetStore.customPresets,
            favoriteIDs: Set(presetStore.favoritePresetIDs),
            activePresetID: activePresetID,
            onSelect: { [weak self] id in self?.selectPresetAndClose(id: id) },
            onToggleFavorite: { [weak self] id in self?.toggleFavorite(id) ?? false }
        )
        presetMenuItem.submenu = presetSubmenu
        menu.addItem(presetMenuItem)

        menu.addItem(.separator())

        // Bypass EQ toggle
        let bypassItem = NSMenuItem(title: "Bypass EQ",
                                      action: #selector(toggleBypass(_:)), keyEquivalent: "b")
        bypassItem.keyEquivalentModifierMask = [.command]
        bypassItem.target = self
        bypassItem.state = audioEngine.bypassed ? .on : .off
        menu.addItem(bypassItem)

        menu.addItem(.separator())

        // Output device (non-interactive) + device-pin toggle
        let outputItem = NSMenuItem(title: "Output: \(audioEngine.outputDeviceName)",
                                     action: nil, keyEquivalent: "")
        outputItem.isEnabled = false
        menu.addItem(outputItem)

        if let uid = audioEngine.outputDeviceUID {
            let pinnedID = presetStore.pinnedPresetID(forDeviceUID: uid)
            let pinItem: NSMenuItem
            if pinnedID == activePresetID {
                pinItem = NSMenuItem(title: "Unpin \"\(audioEngine.activePreset.name)\" from This Device",
                                      action: #selector(toggleDevicePin(_:)), keyEquivalent: "")
            } else if let pinnedID, let pinnedName = presetStore.preset(for: pinnedID)?.name {
                pinItem = NSMenuItem(title: "Re-pin \"\(audioEngine.activePreset.name)\" to This Device (was \"\(pinnedName)\")",
                                      action: #selector(toggleDevicePin(_:)), keyEquivalent: "")
            } else {
                pinItem = NSMenuItem(title: "Pin \"\(audioEngine.activePreset.name)\" to This Device",
                                      action: #selector(toggleDevicePin(_:)), keyEquivalent: "")
            }
            pinItem.target = self
            menu.addItem(pinItem)
        }

        // Error display
        if let error = audioEngine.error {
            let errorItem = NSMenuItem(title: "⚠ \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        // Help
        let helpItem = NSMenuItem(title: "Help…", action: #selector(openHelp(_:)),
                                   keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = [.command]
        helpItem.target = self
        menu.addItem(helpItem)

        // About
        let aboutItem = NSMenuItem(title: "About iQualize", action: #selector(showAbout(_:)),
                                    keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit iQualize", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Presets

    private func selectPresetAndClose(id: UUID) {
        applyPreset(id: id)
        statusItem.menu?.cancelTracking()
    }

    private func toggleFavorite(_ id: UUID) -> Bool {
        presetStore.toggleFavorite(id)
        return presetStore.isFavorite(id)
    }

    @objc private func toggleDevicePin(_ sender: NSMenuItem) {
        guard let uid = audioEngine.outputDeviceUID else { return }
        let activeID = audioEngine.activePreset.id
        if presetStore.pinnedPresetID(forDeviceUID: uid) == activeID {
            presetStore.unpinPreset(fromDeviceUID: uid)
        } else {
            presetStore.pinPreset(activeID, toDeviceUID: uid)
        }
    }

    // MARK: - Actions

    /// Switches the active preset. Shared by the menu's `selectPreset(_:)` and the CLI.
    @discardableResult
    func applyPreset(id: UUID) -> Bool {
        guard let preset = presetStore.preset(for: id) else { return false }
        audioEngine.activePreset = preset
        var s = iQualizeState.load()
        s.selectedPresetID = preset.id
        s.save()
        eqWindowController?.syncUIToPreset()
        return true
    }

    @objc private func openEQSettings(_ sender: NSMenuItem) {
        openEQWindow()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                audioEngine: audioEngine, presetStore: presetStore, eqWindowController: eqWindowController)
        }
        settingsWindowController?.updateEQWindowController(eqWindowController)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openEQWindow() {
        if eqWindowController == nil {
            eqWindowController = EQWindowController(audioEngine: audioEngine, presetStore: presetStore)
            eqWindowController?.onOpenSettings = { [weak self] in
                self?.openSettings(NSMenuItem())
            }
            eqWindowController?.onBypassChanged = { [weak self] in
                guard let self = self else { return }
                self.updateIcon()
                self.settingsWindowController?.syncBypass(self.audioEngine.bypassed)
            }
            // Track window close to persist state
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidClose(_:)),
                name: NSWindow.willCloseNotification, object: eqWindowController?.window
            )
        }
        eqWindowController?.showWindow(nil)
        settingsWindowController?.updateEQWindowController(eqWindowController)
        NSApp.activate(ignoringOtherApps: true)
        var s = iQualizeState.load()
        s.windowOpen = true
        s.save()
    }

    @objc private func windowDidClose(_ notification: Notification) {
        var s = iQualizeState.load()
        s.windowOpen = false
        s.save()
    }

    @objc private func toggleBypass(_ sender: NSMenuItem) {
        toggleBypassFromMenu()
    }

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                audioEngine: audioEngine, presetStore: presetStore, eqWindowController: eqWindowController)
        }
        settingsWindowController?.updateEQWindowController(eqWindowController)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleBypassFromMenu() {
        setBypassed(!audioEngine.bypassed)
    }

    /// Sets bypass state and syncs the menu icon + any open windows. Shared by the menu
    /// toggle and the CLI.
    func setBypassed(_ bypassed: Bool) {
        audioEngine.bypassed = bypassed
        var s = iQualizeState.load()
        s.bypassed = bypassed
        s.save()
        updateIcon()
        eqWindowController?.syncBypass(bypassed)
        settingsWindowController?.syncBypass(bypassed)
    }

    // MARK: - CLI Support

    /// Toggles bypass and returns the new state, for the CLI's `bypass toggle`.
    @discardableResult
    func toggleBypassed() -> Bool {
        let newValue = !audioEngine.bypassed
        setBypassed(newValue)
        return newValue
    }

    /// Sets input gain in dB, forking the active preset if it's built-in and gain isn't
    /// shared globally — mirrors `DreamViewModel.applyInputGain`
    /// (Sources/iQualize/DreamUI/DreamViewModel.swift), plus persisting `selectedPresetID`
    /// so a fork survives a relaunch instead of reverting to the built-in original.
    func setInputGain(_ db: Float) {
        if audioEngine.gainIsGlobal {
            audioEngine.inputGainDB = db
            var s = iQualizeState.load()
            s.inputGainDB = db
            s.save()
        } else {
            var preset = presetStore.forkIfBuiltIn(audioEngine.activePreset)
            preset.inputGainDB = db
            audioEngine.activePreset = preset
            presetStore.saveCustomPreset(preset)
            var s = iQualizeState.load()
            s.selectedPresetID = preset.id
            s.save()
        }
        eqWindowController?.syncUIToPreset()
    }

    /// Sets output gain in dB — same fork-if-built-in rule as `setInputGain`.
    func setOutputGain(_ db: Float) {
        if audioEngine.gainIsGlobal {
            audioEngine.outputGainDB = db
            var s = iQualizeState.load()
            s.outputGainDB = db
            s.save()
        } else {
            var preset = presetStore.forkIfBuiltIn(audioEngine.activePreset)
            preset.outputGainDB = db
            audioEngine.activePreset = preset
            presetStore.saveCustomPreset(preset)
            var s = iQualizeState.load()
            s.selectedPresetID = preset.id
            s.save()
        }
        eqWindowController?.syncUIToPreset()
    }

    /// Resolves a preset by UUID string or case-insensitive exact name match.
    func resolvePreset(idOrName: String) -> EQPresetData? {
        if let id = UUID(uuidString: idOrName), let preset = presetStore.preset(for: id) {
            return preset
        }
        return presetStore.allPresets.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    func statusSnapshot() -> CLIStatusPayload {
        CLIStatusPayload(
            bypassed: audioEngine.bypassed,
            activePresetID: audioEngine.activePreset.id,
            activePresetName: audioEngine.activePreset.name,
            inputGainDB: audioEngine.inputGainDB,
            outputGainDB: audioEngine.outputGainDB,
            gainIsGlobal: audioEngine.gainIsGlobal,
            outputDeviceName: audioEngine.outputDeviceName,
            isRunning: audioEngine.isRunning
        )
    }

    func listPresetSummaries() -> [CLIPresetSummary] {
        presetStore.allPresets.map { preset in
            CLIPresetSummary(
                id: preset.id,
                name: preset.name,
                isBuiltIn: preset.isBuiltIn,
                isFavorite: presetStore.isFavorite(preset.id),
                isActive: preset.id == audioEngine.activePreset.id
            )
        }
    }

    @objc func openHelp(_ sender: Any?) {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "iQualize"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        alert.informativeText = "System-wide audio equalizer for macOS.\nVersion \(version)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/DariusCorvus/iqualize") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        audioEngine.stop()
        (NSApp.delegate as? AppDelegate)?.isRealQuit = true
        NSApp.terminate(nil)
    }

    // MARK: - Icon

    private func updateIcon() {
        if let button = statusItem.button {
            button.title = ""
            let symbolName = audioEngine.bypassed ? "slider.vertical.3" : "slider.vertical.3"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iQualize") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            }
            button.appearsDisabled = !audioEngine.isRunning || audioEngine.bypassed
        }
    }
}
