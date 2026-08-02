import AppKit
import IQControlProtocol

@available(macOS 14.2, *)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, CLICommandHandling {
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

        // Restore saved state — a device pin for the current output takes priority over
        // the last-selected preset, since it's an explicit user choice. Capture starts per
        // the persisted captureEnabled flag (defaults true, so fresh/existing installs
        // still always start; only an explicit `iqualize capture off` persists false).
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
        let captureEnabled = state.captureEnabled
        Task { @MainActor in
            await audioEngine.setEnabled(captureEnabled)
        }
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
    /// Guarded behind the EQ window's unsaved-changes confirmation, if it's open — the alert
    /// runs modally, so `didApply` is settled before this returns.
    @discardableResult
    func applyPreset(id: UUID) -> Bool {
        (try? applyPreset(id: id, policy: .prompt)) ?? false
    }

    /// Switch the active preset using an explicit interaction policy. GUI callers use `.prompt`;
    /// programmatic callers must choose whether dirty state is an error or should be discarded.
    @discardableResult
    func applyPreset(id: UUID, policy: PresetSwitchPolicy) throws -> Bool {
        guard presetStore.preset(for: id) != nil else { return false }
        var didApply = false
        let proceed = { [weak self] in
            guard let self, let preset = self.presetStore.preset(for: id) else { return }
            self.audioEngine.activePreset = preset
            var s = iQualizeState.load()
            s.selectedPresetID = preset.id
            s.save()
            self.eqWindowController?.syncUIToPreset()
            didApply = true
        }

        switch policy.decision(isDirty: eqWindowController?.hasUnsavedChanges ?? false) {
        case .fail:
            throw CLIHandlerError(
                message: "active preset \"\(audioEngine.activePreset.name)\" has unsaved changes; "
                    + "save it with `iqualize presets save` or use `--force` to discard them")
        case .proceed:
            proceed()
        case .prompt:
            if let eqWindowController {
                eqWindowController.confirmDiscardIfNeeded(then: proceed)
            } else {
                proceed()
            }
        }
        return didApply
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

    /// Sets input gain in dB, saving it into the active preset in place when gain isn't
    /// shared globally — mirrors `DreamViewModel.applyInputGain`
    /// (Sources/iQualize/DreamUI/DreamViewModel.swift), plus persisting `selectedPresetID`
    /// so the edit survives a relaunch.
    func setInputGain(_ db: Float) {
        if audioEngine.gainIsGlobal {
            audioEngine.inputGainDB = db
            var s = iQualizeState.load()
            s.inputGainDB = db
            s.save()
        } else {
            var preset = audioEngine.activePreset
            preset.inputGainDB = db
            audioEngine.activePreset = preset
            persistPreset(preset)
            var s = iQualizeState.load()
            s.selectedPresetID = preset.id
            s.save()
        }
        eqWindowController?.syncUIToPreset()
    }

    /// Sets output gain in dB — same in-place save rule as `setInputGain`.
    func setOutputGain(_ db: Float) {
        if audioEngine.gainIsGlobal {
            audioEngine.outputGainDB = db
            var s = iQualizeState.load()
            s.outputGainDB = db
            s.save()
        } else {
            var preset = audioEngine.activePreset
            preset.outputGainDB = db
            audioEngine.activePreset = preset
            persistPreset(preset)
            var s = iQualizeState.load()
            s.selectedPresetID = preset.id
            s.save()
        }
        eqWindowController?.syncUIToPreset()
    }

    /// Sets stereo balance (-1 = hard left, +1 = hard right) — global, not per-preset,
    /// mirroring the DreamUI footer slider's own clamp range.
    func setBalance(_ value: Float) {
        let clamped = min(max(value, -1), 1)
        audioEngine.balance = clamped
        var s = iQualizeState.load()
        s.balance = clamped
        s.save()
        eqWindowController?.syncBalance(clamped)
    }

    func setPeakLimiter(_ enabled: Bool) {
        audioEngine.peakLimiter = enabled
        var s = iQualizeState.load()
        s.peakLimiter = enabled
        s.save()
        eqWindowController?.syncPeakLimiter(enabled)
    }

    @discardableResult
    func togglePeakLimiter() -> Bool {
        let newValue = !audioEngine.peakLimiter
        setPeakLimiter(newValue)
        return newValue
    }

    /// Mirrors SettingsWindowController.toggleLinkGainGlobally(_:) verbatim — saves the
    /// active preset's gain in place on the global -> per-preset transition so it survives
    /// a relaunch.
    func setGainIsGlobal(_ global: Bool) {
        var s = iQualizeState.load()
        if global {
            s.inputGainDB = audioEngine.inputGainDB
            s.outputGainDB = audioEngine.outputGainDB
            s.linkGainGlobally = true
            s.save()
            audioEngine.gainIsGlobal = true
        } else {
            audioEngine.gainIsGlobal = false
            var preset = audioEngine.activePreset
            preset.inputGainDB = audioEngine.inputGainDB
            preset.outputGainDB = audioEngine.outputGainDB
            persistPreset(preset)
            audioEngine.activePreset = preset
            s.linkGainGlobally = false
            s.save()
        }
        eqWindowController?.syncGainIsGlobal(audioEngine.gainIsGlobal)
        eqWindowController?.syncUIToPreset()
    }

    @discardableResult
    func toggleGainIsGlobal() -> Bool {
        let newValue = !audioEngine.gainIsGlobal
        setGainIsGlobal(newValue)
        return newValue
    }

    // preEqSpectrumEnabled/postEqSpectrumEnabled live only in iQualizeState, not on
    // AudioEngine — the toggle variants read the current value from persisted state
    // rather than from audioEngine, unlike peakLimiter/gainIsGlobal/capture.
    func setPreEqSpectrum(_ enabled: Bool) {
        var s = iQualizeState.load()
        s.preEqSpectrumEnabled = enabled
        s.save()
        eqWindowController?.syncPreEqSpectrum(enabled)
    }

    @discardableResult
    func togglePreEqSpectrum() -> Bool {
        let newValue = !iQualizeState.load().preEqSpectrumEnabled
        setPreEqSpectrum(newValue)
        return newValue
    }

    func setPostEqSpectrum(_ enabled: Bool) {
        var s = iQualizeState.load()
        s.postEqSpectrumEnabled = enabled
        s.save()
        eqWindowController?.syncPostEqSpectrum(enabled)
    }

    @discardableResult
    func togglePostEqSpectrum() -> Bool {
        let newValue = !iQualizeState.load().postEqSpectrumEnabled
        setPostEqSpectrum(newValue)
        return newValue
    }

    func setCapture(_ enabled: Bool) async {
        await audioEngine.setEnabled(enabled)
        var s = iQualizeState.load()
        s.captureEnabled = enabled
        s.save()
        updateIcon()
    }

    @discardableResult
    func toggleCapture() async -> Bool {
        let newValue = !audioEngine.userEnabled
        await setCapture(newValue)
        return newValue
    }

    // MARK: - CLI Support: Band editing

    /// Resolves --index (1-based, sorted-by-frequency) or --near (nearest-frequency match)
    /// against `preset`'s live bands. Exactly one must be non-nil (also validated client-side
    /// in the CLI). Ties in --near resolve to the lower-frequency band via `min`'s stable
    /// first-match behavior — no separate "ambiguous" error needed.
    private func resolveBandID(index: Int?, matchFrequency: Float?, in preset: EQPresetData) throws -> UUID {
        guard index != nil || matchFrequency != nil else {
            throw CLIHandlerError(message: "specify --index or --near")
        }
        guard index == nil || matchFrequency == nil else {
            throw CLIHandlerError(message: "specify only one of --index or --near")
        }
        let sorted = preset.bands.sorted { $0.frequency < $1.frequency }
        guard !sorted.isEmpty else { throw CLIHandlerError(message: "preset has no bands") }
        if let index {
            guard index >= 1, index <= sorted.count else {
                throw CLIHandlerError(message: "--index must be between 1 and \(sorted.count)")
            }
            return sorted[index - 1].id
        }
        return sorted.min { abs($0.frequency - matchFrequency!) < abs($1.frequency - matchFrequency!) }!.id
    }

    private func bandSummary(for band: EQBand, in preset: EQPresetData) -> CLIBandSummary {
        let sorted = preset.bands.sorted { $0.frequency < $1.frequency }
        let idx = (sorted.firstIndex { $0.id == band.id } ?? 0) + 1
        return CLIBandSummary(index: idx, frequency: band.frequency, gain: band.gain,
                               bandwidth: band.bandwidth, filterType: band.filterType.rawValue, muted: band.muted)
    }

    /// Persists `preset` to whichever store it belongs in — the built-in override table if
    /// it's a built-in, `customPresets` otherwise. Nothing forks: a built-in stays a built-in,
    /// edited and saved in place.
    private func persistPreset(_ preset: EQPresetData) {
        if preset.isBuiltIn {
            presetStore.saveBuiltInOverride(preset)
        } else {
            presetStore.saveCustomPreset(preset)
        }
    }

    /// Same mutate -> push -> persist -> sync shape as setInputGain/setPeakLimiter.
    private func persistBandMutation(_ preset: EQPresetData) {
        audioEngine.activePreset = preset
        persistPreset(preset)
        var s = iQualizeState.load()
        s.selectedPresetID = preset.id
        s.save()
        eqWindowController?.syncUIToPreset()
    }

    func listBands() -> [CLIBandSummary] {
        let preset = audioEngine.activePreset
        return preset.bands.sorted { $0.frequency < $1.frequency }.map { bandSummary(for: $0, in: preset) }
    }

    func addBand(frequency: Float?, gain: Float?, bandwidth: Float?, filterType: String?) throws -> CLIBandSummary {
        var preset = audioEngine.activePreset
        let type: FilterType
        if let filterType {
            guard let parsed = FilterType(rawValue: filterType) else {
                throw CLIHandlerError(message: "unrecognized filter type '\(filterType)'")
            }
            type = parsed
        } else {
            type = .parametric
        }
        let freq = frequency.map { $0.clamped(to: EQBand.frequencyRange) } ?? preset.suggestNewBandFrequency()
        let newBand = EQBand(frequency: freq, gain: (gain ?? 0).clamped(to: EQBand.gainRange),
                              bandwidth: (bandwidth ?? 1.0).clamped(to: EQBand.bandwidthRange), filterType: type)
        preset.bands.append(newBand)
        persistBandMutation(preset)
        return bandSummary(for: newBand, in: preset)
    }

    func deleteBand(index: Int?, matchFrequency: Float?) throws {
        var preset = audioEngine.activePreset
        let id = try resolveBandID(index: index, matchFrequency: matchFrequency, in: preset)
        guard preset.bands.count > EQPresetData.minBandCount else {
            throw CLIHandlerError(message: "preset must keep at least \(EQPresetData.minBandCount) band")
        }
        preset.bands.removeAll { $0.id == id }
        persistBandMutation(preset)
    }

    func setBand(index: Int?, matchFrequency: Float?, frequency: Float?, gain: Float?, bandwidth: Float?, filterType: String?) throws -> CLIBandSummary {
        var preset = audioEngine.activePreset
        let id = try resolveBandID(index: index, matchFrequency: matchFrequency, in: preset)
        guard let i = preset.bands.firstIndex(where: { $0.id == id }) else {
            throw CLIHandlerError(message: "band not found")
        }
        if let f = frequency { preset.bands[i].frequency = f.clamped(to: EQBand.frequencyRange) }
        if let g = gain { preset.bands[i].gain = g.clamped(to: EQBand.gainRange) }
        if let b = bandwidth { preset.bands[i].bandwidth = b.clamped(to: EQBand.bandwidthRange) }
        if let t = filterType {
            guard let parsed = FilterType(rawValue: t) else {
                throw CLIHandlerError(message: "unrecognized filter type '\(t)'")
            }
            preset.bands[i].filterType = parsed
        }
        persistBandMutation(preset)
        return bandSummary(for: preset.bands[i], in: preset)
    }

    /// Mirrors DreamViewModel.moveBandHorizontally(id:dir:) exactly: swaps FREQUENCY VALUES
    /// with the adjacent band in sorted order — not an array reorder.
    func moveBand(index: Int?, matchFrequency: Float?, direction: String) throws -> CLIBandSummary {
        var preset = audioEngine.activePreset
        let id = try resolveBandID(index: index, matchFrequency: matchFrequency, in: preset)
        let sorted = preset.bands.sorted { $0.frequency < $1.frequency }
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else {
            throw CLIHandlerError(message: "band not found")
        }
        let dir: Int
        switch direction {
        case "left": dir = -1
        case "right": dir = 1
        default: throw CLIHandlerError(message: "direction must be 'left' or 'right'")
        }
        let newIdx = idx + dir
        guard newIdx >= 0, newIdx < sorted.count else {
            throw CLIHandlerError(message: "band is already at the \(direction) edge")
        }
        let a = sorted[idx], b = sorted[newIdx]
        for i in preset.bands.indices {
            if preset.bands[i].id == a.id { preset.bands[i].frequency = b.frequency }
            else if preset.bands[i].id == b.id { preset.bands[i].frequency = a.frequency }
        }
        persistBandMutation(preset)
        guard let moved = preset.bands.first(where: { $0.id == id }) else {
            throw CLIHandlerError(message: "band not found after move")
        }
        return bandSummary(for: moved, in: preset)
    }

    /// Only `.muted` is set — `.gain` is never touched, unlike the GUI's own mute path
    /// (DreamViewModel.pushBandsToEngine zeroes gain in a transient copy while keeping the
    /// real value in DreamViewModel.bands). The CLI has no such second copy, so zeroing the
    /// stored gain here would lose it permanently; AudioEngine.applyBands' effectiveGain(_:)
    /// respects `.muted` at the DSP layer instead.
    func setBandMute(index: Int?, matchFrequency: Float?, muted: Bool) throws -> CLIBandSummary {
        var preset = audioEngine.activePreset
        let id = try resolveBandID(index: index, matchFrequency: matchFrequency, in: preset)
        guard let i = preset.bands.firstIndex(where: { $0.id == id }) else {
            throw CLIHandlerError(message: "band not found")
        }
        preset.bands[i].muted = muted
        persistBandMutation(preset)
        return bandSummary(for: preset.bands[i], in: preset)
    }

    @discardableResult
    func toggleBandMute(index: Int?, matchFrequency: Float?) throws -> CLIBandSummary {
        let preset = audioEngine.activePreset
        let id = try resolveBandID(index: index, matchFrequency: matchFrequency, in: preset)
        guard let current = preset.bands.first(where: { $0.id == id })?.muted else {
            throw CLIHandlerError(message: "band not found")
        }
        return try setBandMute(index: index, matchFrequency: matchFrequency, muted: !current)
    }

    // MARK: - CLI Support: Presets

    /// Resolves a preset by UUID string or case-insensitive exact name match.
    func resolvePreset(idOrName: String) -> EQPresetData? {
        if let id = UUID(uuidString: idOrName), let preset = presetStore.preset(for: id) {
            return preset
        }
        return presetStore.allPresets.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
    }

    /// Persists the active preset as-is. A no-op in the common case (every CLI mutation
    /// already persists immediately) — matters only for a freshly-selected, never-touched
    /// built-in, which this saves back to itself as a (no-op) override.
    @discardableResult
    func saveActivePreset() -> CLIPresetSummary {
        let preset = audioEngine.activePreset
        persistBandMutation(preset)
        return CLIPresetSummary(id: preset.id, name: preset.name, isBuiltIn: preset.isBuiltIn,
                                 isFavorite: presetStore.isFavorite(preset.id), isActive: true)
    }

    /// There's no "unsaved edit" concept in the CLI model (every mutation persists
    /// immediately), so DreamViewModel.resetToSnapshot()'s GUI meaning ("revert to last
    /// save") has no CLI analog. Instead this switches back to Flat — the same terminal
    /// state deleteCurrentPreset already falls back to.
    func resetActivePreset() {
        _ = try? applyPreset(id: EQPresetData.flat.id, policy: .discard)
    }

    func deletePreset(idOrName: String) throws {
        guard let preset = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        guard preset.id != EQPresetData.flat.id else {
            throw CLIHandlerError(message: "Flat can't be deleted")
        }
        if preset.isBuiltIn {
            presetStore.hideBuiltInPreset(id: preset.id)
        } else {
            presetStore.deleteCustomPreset(id: preset.id)
        }
        if audioEngine.activePreset.id == preset.id {
            _ = try? applyPreset(id: EQPresetData.flat.id, policy: .discard)
        }
    }

    func newPreset(name: String?) throws -> CLIPresetSummary {
        let resolvedName: String
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw CLIHandlerError(message: "name can't be empty") }
            guard !presetStore.allPresets.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw CLIHandlerError(message: "a preset named '\(trimmed)' already exists")
            }
            resolvedName = trimmed
        } else {
            let existing = presetStore.allPresets.map(\.name)
            var n = 1
            while existing.contains("Custom EQ \(n)") { n += 1 }
            resolvedName = "Custom EQ \(n)"
        }
        let preset = EQPresetData(id: UUID(), name: resolvedName, bands: EQPresetData.flat.bands, isBuiltIn: false)
        persistBandMutation(preset)
        return CLIPresetSummary(id: preset.id, name: preset.name, isBuiltIn: false, isFavorite: false, isActive: true)
    }

    /// Renaming a built-in now renames it in place — an override, name included — consistent
    /// with every other CLI mutation. Renaming "Flat" itself is still not blocked (unlike
    /// delete): it only ever changes the display name, not Flat's protected id.
    func renamePreset(idOrName: String, newName: String) throws -> CLIPresetSummary {
        guard let source = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CLIHandlerError(message: "new name can't be empty") }
        guard !presetStore.allPresets.contains(where: { $0.id != source.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw CLIHandlerError(message: "a preset named '\(trimmed)' already exists")
        }
        var renamed = source
        renamed.name = trimmed
        persistPreset(renamed)
        if audioEngine.activePreset.id == source.id {
            persistBandMutation(renamed)
        }
        return CLIPresetSummary(id: renamed.id, name: renamed.name, isBuiltIn: renamed.isBuiltIn,
                                 isFavorite: presetStore.isFavorite(renamed.id), isActive: audioEngine.activePreset.id == renamed.id)
    }

    /// Never switches the active preset — creates an inactive copy in the picker.
    func duplicatePreset(idOrName: String, newName: String?) throws -> CLIPresetSummary {
        guard let source = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        let resolvedName: String
        if let newName {
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw CLIHandlerError(message: "new name can't be empty") }
            guard !presetStore.allPresets.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw CLIHandlerError(message: "a preset named '\(trimmed)' already exists")
            }
            resolvedName = trimmed
        } else {
            resolvedName = presetStore.dedupedName(base: "\(source.name) copy")
        }
        let copy = EQPresetData(id: UUID(), name: resolvedName, bands: source.bands, rightBands: source.rightBands,
                                 isBuiltIn: false, inputGainDB: source.inputGainDB, outputGainDB: source.outputGainDB)
        presetStore.saveCustomPreset(copy)
        return CLIPresetSummary(id: copy.id, name: copy.name, isBuiltIn: false, isFavorite: false, isActive: false)
    }

    func setFavoritePreset(idOrName: String, favorite: Bool) throws -> Bool {
        guard let preset = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        if presetStore.isFavorite(preset.id) != favorite {
            presetStore.toggleFavorite(preset.id)
        }
        return presetStore.isFavorite(preset.id)
    }

    func toggleFavoritePreset(idOrName: String) throws -> Bool {
        guard let preset = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        presetStore.toggleFavorite(preset.id)
        return presetStore.isFavorite(preset.id)
    }

    /// Closes PresetStore.pinPreset's existing lack of an id-existence check at this call
    /// site, since it's the new caller introducing this path from the CLI.
    func pinPreset(idOrName: String) throws {
        guard let preset = resolvePreset(idOrName: idOrName) else {
            throw CLIHandlerError(message: "no preset named '\(idOrName)'")
        }
        guard let uid = audioEngine.outputDeviceUID else {
            throw CLIHandlerError(message: "no output device to pin to")
        }
        presetStore.pinPreset(preset.id, toDeviceUID: uid)
    }

    func unpinPreset() throws {
        guard let uid = audioEngine.outputDeviceUID else {
            throw CLIHandlerError(message: "no output device to unpin")
        }
        presetStore.unpinPreset(fromDeviceUID: uid)
    }

    func listHiddenPresets() -> [CLIPresetSummary] {
        presetStore.hiddenBuiltInPresets.map {
            CLIPresetSummary(id: $0.id, name: $0.name, isBuiltIn: true, isFavorite: false, isActive: false)
        }
    }

    func restoreBuiltInPreset(idOrName: String) throws {
        let match = UUID(uuidString: idOrName).flatMap { id in presetStore.hiddenBuiltInPresets.first { $0.id == id } }
            ?? presetStore.hiddenBuiltInPresets.first { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }
        guard let preset = match else {
            throw CLIHandlerError(message: "no hidden built-in preset named '\(idOrName)'")
        }
        presetStore.restoreBuiltInPreset(id: preset.id)
    }

    // MARK: - CLI Support: Import/Export

    func importPresetFile(path: String, overwrite: Bool) throws -> CLIPresetSummary {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIHandlerError(message: "couldn't read '\(path)': \(error.localizedDescription)")
        }
        let parsed: ParsedPreset
        do {
            parsed = try PresetImporter.parse(data: data, filename: url.lastPathComponent)
        } catch {
            throw CLIHandlerError(message: error.localizedDescription)
        }
        let suggestedName = parsed.name ?? PresetImporter.defaultImportName(for: url)
        if let existing = presetStore.customPresets.first(where: { $0.name.caseInsensitiveCompare(suggestedName) == .orderedSame }) {
            guard overwrite else {
                throw CLIHandlerError(message: "a preset named '\(suggestedName)' already exists — pass --overwrite to replace it")
            }
            presetStore.deleteCustomPreset(id: existing.id)
        }
        let preset = PresetImporter.makePreset(from: parsed, name: suggestedName)
        presetStore.saveCustomPreset(preset)
        persistBandMutation(preset)
        return CLIPresetSummary(id: preset.id, name: preset.name, isBuiltIn: false, isFavorite: false, isActive: true)
    }

    func exportPreset(idOrName: String?, outputPath: String) throws {
        let preset: EQPresetData
        if let idOrName {
            guard let resolved = resolvePreset(idOrName: idOrName) else {
                throw CLIHandlerError(message: "no preset named '\(idOrName)'")
            }
            preset = resolved
        } else {
            preset = audioEngine.activePreset
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(preset)
            try data.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            throw CLIHandlerError(message: "couldn't write '\(outputPath)': \(error.localizedDescription)")
        }
    }

    // MARK: - CLI Support: OPRA catalog

    /// Matches against vendor, product, AND the combined "vendor product" string — vendor
    /// and product name are stored as separate fields, but users naturally search for both
    /// together (e.g. "Sennheiser HD 600"), which matches neither field alone.
    private func matchingOPRAProducts(_ products: [OPRAProductEntry], query: String) -> [OPRAProductEntry] {
        let q = query.lowercased()
        return products.filter {
            $0.vendorName.lowercased().contains(q)
                || $0.productName.lowercased().contains(q)
                || "\($0.vendorName) \($0.productName)".lowercased().contains(q)
        }
    }

    func searchOPRA(query: String) async throws -> [CLIOPRAProductSummary] {
        let products: [OPRAProductEntry]
        do {
            products = try await OPRACatalog.shared.loadIfNeeded()
        } catch {
            throw CLIHandlerError(message: error.localizedDescription)
        }
        return matchingOPRAProducts(products, query: query).map {
            CLIOPRAProductSummary(id: $0.id, vendorName: $0.vendorName, productName: $0.productName,
                                   curveAuthors: $0.curves.map(\.author))
        }
    }

    func importOPRA(query: String, curveAuthor: String?, overwrite: Bool) async throws -> CLIPresetSummary {
        let products: [OPRAProductEntry]
        do {
            products = try await OPRACatalog.shared.loadIfNeeded()
        } catch {
            throw CLIHandlerError(message: error.localizedDescription)
        }
        let matches = matchingOPRAProducts(products, query: query)
        guard !matches.isEmpty else {
            throw CLIHandlerError(message: "no OPRA product matches '\(query)'")
        }
        guard matches.count == 1 else {
            let names = matches.prefix(10).map { "\($0.vendorName) \($0.productName)" }.joined(separator: ", ")
            throw CLIHandlerError(message: "'\(query)' matches multiple products (\(names)) — narrow your query")
        }
        let product = matches[0]

        let curve: OPRACurveEntry
        if product.curves.count == 1 {
            curve = product.curves[0]
        } else if let curveAuthor {
            let curveMatches = product.curves.filter { $0.author.localizedCaseInsensitiveContains(curveAuthor) }
            guard curveMatches.count == 1 else {
                let authors = product.curves.map(\.author).joined(separator: ", ")
                throw CLIHandlerError(message: "--curve '\(curveAuthor)' didn't match exactly one curve (available: \(authors))")
            }
            curve = curveMatches[0]
        } else {
            let authors = product.curves.map(\.author).joined(separator: ", ")
            throw CLIHandlerError(message: "\(product.vendorName) \(product.productName) has multiple curves — pass --curve (available: \(authors))")
        }

        let parsed: ParsedPreset
        do {
            parsed = try PresetImporter.parse(data: curve.data, filename: product.productName)
        } catch {
            throw CLIHandlerError(message: error.localizedDescription)
        }
        let suggestedName = "\(product.vendorName) \(product.productName)"
        if let existing = presetStore.customPresets.first(where: { $0.name.caseInsensitiveCompare(suggestedName) == .orderedSame }) {
            guard overwrite else {
                throw CLIHandlerError(message: "a preset named '\(suggestedName)' already exists — pass --overwrite to replace it")
            }
            presetStore.deleteCustomPreset(id: existing.id)
        }
        let preset = PresetImporter.makePreset(from: parsed, name: suggestedName)
        presetStore.saveCustomPreset(preset)
        persistBandMutation(preset)
        return CLIPresetSummary(id: preset.id, name: preset.name, isBuiltIn: false, isFavorite: false, isActive: true)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Git commit stamped into the installed Info.plist by install.sh; nil for
    /// unstamped builds.
    var appGitCommit: String? {
        Bundle.main.infoDictionary?["IQGitCommit"] as? String
    }

    func statusSnapshot() -> CLIStatusPayload {
        let capture = audioEngine.captureTelemetry()
        return CLIStatusPayload(
            bypassed: audioEngine.bypassed,
            activePresetID: audioEngine.activePreset.id,
            activePresetName: audioEngine.activePreset.name,
            inputGainDB: audioEngine.inputGainDB,
            outputGainDB: audioEngine.outputGainDB,
            balance: audioEngine.balance,
            gainIsGlobal: audioEngine.gainIsGlobal,
            outputDeviceName: audioEngine.outputDeviceName,
            isRunning: audioEngine.isRunning,
            peakLimiter: audioEngine.peakLimiter,
            preEqSpectrumEnabled: iQualizeState.load().preEqSpectrumEnabled,
            postEqSpectrumEnabled: iQualizeState.load().postEqSpectrumEnabled,
            appVersion: appVersion,
            gitCommit: appGitCommit,
            captureFillFrames: capture?.fillFrames,
            captureDriftPpm: capture?.driftPpm,
            captureUnderruns: capture?.underruns,
            captureOverrunResyncs: capture?.overrunResyncs,
            captureHelperRestarts: audioEngine.captureHelperRestartCount
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

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "iQualize"
        alert.informativeText = """
        System-wide audio equalizer for macOS.
        Version \(appVersion)\(appGitCommit.map { " (\($0))" } ?? "")

        Headphone EQ profiles come from the OPRA project, licensed CC BY-SA 4.0.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "OPRA Project")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/DariusCorvus/iqualize")!)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(OPRAAttribution.projectURL)
        default:
            break
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
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
