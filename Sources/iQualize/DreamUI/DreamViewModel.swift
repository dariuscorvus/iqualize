import AppKit
import Combine
import Foundation
import Observation
import SwiftUI

@available(macOS 14.2, *)
@MainActor
@Observable
final class DreamViewModel {
    // MARK: - Wired-in dependencies

    let audioEngine: AudioEngine
    let presetStore: PresetStore

    /// Window's undo manager — set by EQWindowController once the window exists.
    @ObservationIgnored
    weak var undoManager: UndoManager?

    /// Callback fired when the toolbar's Settings gear is tapped.
    @ObservationIgnored
    var onOpenSettings: (() -> Void)?

    /// Callback fired when the user toggles bypass from the footer (so the menu bar can refresh).
    @ObservationIgnored
    var onBypassChanged: (() -> Void)?

    /// Callback fired when something that affects the window title changed (preset name, dirty flag).
    @ObservationIgnored
    var onTitleShouldUpdate: (() -> Void)?

    // MARK: - Editing state

    var selectedBandID: UUID?
    var hoverBandID: UUID?
    var altPressed: Bool = false
    var bandwidthDisplay: BandwidthDisplay = .oct
    var snapToSemitone: Bool = false
    var theme: DreamThemePreference = .auto
    var editing: EditingTarget?

    // MARK: - Audio mirror (rebuilt from audioEngine on change)

    var bands: [EQBand] = []
    var rightBands: [EQBand]?
    var presetName: String = ""
    var activePresetID: UUID = EQPresetData.flat.id
    var isBuiltIn: Bool = false
    var savedSnapshot: EQPresetData?
    var isModified: Bool = false

    var channel: ChannelMode = .linked
    var bypass: Bool = false
    var peakLimiter: Bool = true
    var preEqEnabled: Bool = false
    var postEqEnabled: Bool = false
    var inGainDB: Float = 0
    var outGainDB: Float = 0
    var balance: Float = 0
    var autoScale: Bool = true
    var maxGainDB: Float = 12

    var outputDeviceName: String { audioEngine.outputDeviceName }

    // Computed
    var canUndo: Bool { undoManager?.canUndo ?? false }
    var canRedo: Bool { undoManager?.canRedo ?? false }

    /// Bands for the active channel sorted by frequency — what the canvas/readouts show.
    var displayBands: [EQBand] {
        let raw = (channel == .r ? (rightBands ?? bands) : bands)
        return raw.sorted { $0.frequency < $1.frequency }
    }

    var displayBandCount: Int { displayBands.count }

    // MARK: - Init

    init(audioEngine: AudioEngine, presetStore: PresetStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore
        loadPersistedState()
        syncFromAudioEngine(initial: true)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let s = iQualizeState.load()
        if let raw = s.dreamTheme, let t = DreamThemePreference(rawValue: raw) { theme = t }
        snapToSemitone = s.snapToSemitone
        bandwidthDisplay = s.showBandwidthAsQ ? .q : .oct
        peakLimiter = s.peakLimiter
        bypass = s.bypassed
        autoScale = s.autoScale
        preEqEnabled = s.preEqSpectrumEnabled
        postEqEnabled = s.postEqSpectrumEnabled
        balance = s.balance
        inGainDB = s.inputGainDB
        outGainDB = s.outputGainDB
        maxGainDB = s.maxGainDB
        if s.splitChannelEnabled, let chRaw = s.activeChannel {
            channel = chRaw == "right" ? .r : .l
        } else {
            channel = .linked
        }
    }

    func persistTheme() {
        var s = iQualizeState.load()
        s.dreamTheme = theme.rawValue
        s.save()
    }

    func persistSnap() {
        var s = iQualizeState.load()
        s.snapToSemitone = snapToSemitone
        s.save()
    }

    func persistBandwidthDisplay() {
        var s = iQualizeState.load()
        s.showBandwidthAsQ = (bandwidthDisplay == .q)
        s.save()
    }

    func persistFooterToggles() {
        var s = iQualizeState.load()
        s.peakLimiter = peakLimiter
        s.bypassed = bypass
        s.autoScale = autoScale
        s.preEqSpectrumEnabled = preEqEnabled
        s.postEqSpectrumEnabled = postEqEnabled
        s.balance = balance
        s.inputGainDB = inGainDB
        s.outputGainDB = outGainDB
        s.maxGainDB = maxGainDB
        s.splitChannelEnabled = channel != .linked
        s.activeChannel = channel == .r ? "right" : (channel == .l ? "left" : nil)
        s.save()
    }

    // MARK: - Audio engine sync

    func syncFromAudioEngine(initial: Bool = false) {
        let preset = audioEngine.activePreset
        bands = preset.bands.map { ensureID($0) }
        rightBands = preset.rightBands?.map { ensureID($0) }
        presetName = preset.name
        activePresetID = preset.id
        isBuiltIn = preset.isBuiltIn
        if initial {
            savedSnapshot = preset
            isModified = false
        }
        onTitleShouldUpdate?()
    }

    /// Ensure the band has a UUID — preserves existing IDs, mints new ones for freshly-decoded bands.
    private func ensureID(_ band: EQBand) -> EQBand {
        var b = band
        if b.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000") { b.id = UUID() }
        return b
    }

    /// Push the local bands array back into the audioEngine's active preset.
    private func pushBandsToEngine() {
        var preset = audioEngine.activePreset
        let unmuted = bands.map { b -> EQBand in
            var copy = b
            // Muted bands send 0 dB gain to the engine while keeping the local muted flag for UI.
            if copy.muted { copy.gain = 0 }
            return copy
        }
        preset.bands = unmuted
        if let r = rightBands {
            preset.rightBands = r.map { b -> EQBand in
                var copy = b
                if copy.muted { copy.gain = 0 }
                return copy
            }
        } else {
            preset.rightBands = nil
        }
        audioEngine.activePreset = preset
        let wasModified = isModified
        if savedSnapshot != preset {
            isModified = true
        } else {
            isModified = false
        }
        if wasModified != isModified { onTitleShouldUpdate?() }
    }

    // MARK: - Mutation helpers

    /// Snapshot before mutation, mutate, then register undo. `actionName` is shown in Edit > Undo.
    private func mutate(_ actionName: String, _ transform: () -> Void) {
        let oldPreset = audioEngine.activePreset
        forkIfBuiltIn()
        transform()
        pushBandsToEngine()
        registerUndo(actionName: actionName, oldPreset: oldPreset)
    }

    /// Same as `mutate` but does not register undo — for in-progress drag operations
    /// where undo registers on drag end via `commitDrag`.
    private func liveMutate(_ transform: () -> Void) {
        forkIfBuiltIn()
        transform()
        pushBandsToEngine()
    }

    /// Coalesced drag undo: snapshot at start, register at end.
    @ObservationIgnored
    private var dragSnapshot: EQPresetData?

    /// Wheel lock — once a scroll gesture starts on a band's cell, subsequent ticks within 180 ms
    /// keep editing that same band even if it has re-sorted to a different cell position. Mirrors
    /// the prototype's `window.__iqWheelLock`.
    @ObservationIgnored
    private var scrollWheelLock: (id: UUID, field: ReadoutField, time: Date)?

    /// Returns the band ID a scroll tick should adjust. If the gesture is still active for the
    /// same field, returns the locked band (so it doesn't drift across re-sorted cells).
    func scrollWheelTarget(field: ReadoutField, currentBandID: UUID) -> UUID {
        if let lock = scrollWheelLock,
           lock.field == field,
           Date().timeIntervalSince(lock.time) < 0.18,
           band(id: lock.id) != nil {
            return lock.id
        }
        return currentBandID
    }

    func recordScrollWheelTick(target: UUID, field: ReadoutField) {
        scrollWheelLock = (target, field, Date())
    }

    @ObservationIgnored
    private var keyboardCommitTask: Task<Void, Never>?

    /// Try to handle a keyboard event. Returns true when consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        // Don't intercept while editing a text field
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        let meta = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if meta, chars == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        }
        if meta, chars == "y" {
            redo(); return true
        }
        if meta, chars == "b" {
            bypass.toggle(); applyBypass(); return true
        }
        if event.keyCode == 53 { // Esc
            selectedBandID = nil
            return true
        }

        guard let id = selectedBandID, let band = band(id: id) else { return false }
        switch event.keyCode {
        case 126: // Up
            beginDrag()
            updateBand(id: id, gain: min(gainClamp, band.gain + 0.5))
            scheduleKeyCommit()
            return true
        case 125: // Down
            beginDrag()
            updateBand(id: id, gain: max(-gainClamp, band.gain - 0.5))
            scheduleKeyCommit()
            return true
        case 124: // Right
            beginDrag()
            updateBand(id: id, frequency: min(20000, band.frequency * Float(pow(2.0, 1.0 / 12.0))))
            scheduleKeyCommit()
            return true
        case 123: // Left
            beginDrag()
            updateBand(id: id, frequency: max(20, band.frequency / Float(pow(2.0, 1.0 / 12.0))))
            scheduleKeyCommit()
            return true
        case 51, 117: // Backspace, Forward Delete
            deleteBand(id: id)
            return true
        case 46: // M
            if !meta { toggleMute(id: id); return true }
        case 48: // Tab
            cycleSelection(forward: !event.modifierFlags.contains(.shift))
            return true
        default: break
        }
        return false
    }

    private func scheduleKeyCommit() {
        keyboardCommitTask?.cancel()
        keyboardCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { self?.commitDrag("Adjust Band") }
        }
    }

    private func cycleSelection(forward: Bool) {
        let sorted = displayBands
        guard !sorted.isEmpty else { return }
        if let cur = selectedBandID, let idx = sorted.firstIndex(where: { $0.id == cur }) {
            let next = forward ? (idx + 1) % sorted.count : (idx - 1 + sorted.count) % sorted.count
            selectedBandID = sorted[next].id
        } else {
            selectedBandID = sorted.first?.id
        }
    }

    func beginDrag() {
        if dragSnapshot == nil {
            dragSnapshot = audioEngine.activePreset
        }
    }

    func commitDrag(_ actionName: String = "Adjust Band") {
        guard let snap = dragSnapshot else { return }
        dragSnapshot = nil
        if audioEngine.activePreset != snap {
            registerUndo(actionName: actionName, oldPreset: snap)
        }
    }

    private func forkIfBuiltIn() {
        guard audioEngine.activePreset.isBuiltIn else { return }
        let baseName = "\(audioEngine.activePreset.name) (Custom)"
        let existing = presetStore.allPresets.map { $0.name }
        var forkName = baseName
        if existing.contains(forkName) {
            var n = 2
            while existing.contains("\(baseName) \(n)") { n += 1 }
            forkName = "\(baseName) \(n)"
        }
        let custom = audioEngine.activePreset
        let newPreset = EQPresetData(
            id: UUID(),
            name: forkName,
            bands: custom.bands,
            rightBands: custom.rightBands,
            isBuiltIn: false
        )
        audioEngine.activePreset = newPreset
        savedSnapshot = newPreset
        presetName = newPreset.name
        activePresetID = newPreset.id
        isBuiltIn = false
    }

    private func registerUndo(actionName: String, oldPreset: EQPresetData) {
        guard let undoManager else { return }
        let currentPreset = audioEngine.activePreset
        undoManager.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            let redoPreset = self.audioEngine.activePreset
            self.audioEngine.activePreset = oldPreset
            self.syncFromAudioEngine()
            if oldPreset == self.savedSnapshot {
                self.isModified = false
            } else {
                self.isModified = true
            }
            self.registerUndo(actionName: actionName, oldPreset: redoPreset)
        }
        undoManager.setActionName(actionName)
        // Ensure modified flag is correct after redo path.
        isModified = (currentPreset != savedSnapshot)
    }

    // MARK: - Band lookups

    func indexOfBand(id: UUID) -> Int? {
        bands.firstIndex { $0.id == id }
    }

    func band(id: UUID) -> EQBand? {
        bands.first { $0.id == id }
    }

    // MARK: - Mutations: per-band

    func updateBand(id: UUID, frequency: Float? = nil, gain: Float? = nil, bandwidth: Float? = nil, filterType: FilterType? = nil, registerUndo: Bool = false) {
        guard let i = indexOfBand(id: id) else { return }
        let body = {
            if let f = frequency { self.bands[i].frequency = max(20, min(20000, f)) }
            if let g = gain      { self.bands[i].gain      = max(-self.gainClamp, min(self.gainClamp, g)) }
            if let b = bandwidth { self.bands[i].bandwidth = max(0.05, min(8.0, b)) }
            if let t = filterType { self.bands[i].filterType = t }
        }
        if registerUndo {
            mutate(filterType != nil ? "Change Filter Type" : "Edit Band") { body() }
        } else {
            liveMutate { body() }
        }
    }

    /// Hard limit on knob/gain magnitude. With auto-scale on we let knobs go to ±24 dB and the
    /// canvas's dB axis adapts. Without auto-scale, the user's chosen max-gain is the cap.
    var gainClamp: Float { autoScale ? 24 : maxGainDB }

    func toggleMute(id: UUID) {
        mutate("Toggle Mute") {
            guard let i = self.indexOfBand(id: id) else { return }
            self.bands[i].muted.toggle()
        }
    }

    func deleteBand(id: UUID) {
        if selectedBandID == id { selectedBandID = nil }
        mutate("Delete Band") {
            self.bands.removeAll { $0.id == id }
        }
    }

    enum AddMode { case left, right, suggest }

    func addBand(_ mode: AddMode) {
        mutate("Add Band") {
            if self.bands.isEmpty {
                self.bands.append(EQBand(frequency: 1000, gain: 0, bandwidth: 1.0))
                return
            }
            let sorted = self.bands.sorted { $0.frequency < $1.frequency }
            switch mode {
            case .left:
                let template = sorted.first!
                let f = max(20, template.frequency / 1.5)
                self.bands.append(EQBand(frequency: f, gain: template.gain, bandwidth: template.bandwidth, filterType: template.filterType))
            case .right:
                let template = sorted.last!
                let f = min(20000, template.frequency * 1.5)
                self.bands.append(EQBand(frequency: f, gain: template.gain, bandwidth: template.bandwidth, filterType: template.filterType))
            case .suggest:
                let f = self.findLargestGap(in: sorted)
                self.bands.append(EQBand(frequency: f, gain: 0, bandwidth: 1.0))
            }
        }
    }

    private func findLargestGap(in sorted: [EQBand]) -> Float {
        guard sorted.count >= 2 else { return 1000 }
        var bestRatio: Float = 0
        var bestF: Float = 1000
        for i in 0..<(sorted.count - 1) {
            let ratio = sorted[i + 1].frequency / sorted[i].frequency
            if ratio > bestRatio {
                bestRatio = ratio
                bestF = sqrt(sorted[i].frequency * sorted[i + 1].frequency)
            }
        }
        return bestF
    }

    func moveBandHorizontally(id: UUID, dir: Int) {
        let sorted = displayBands
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return }
        let newIdx = idx + dir
        guard newIdx >= 0, newIdx < sorted.count else { return }
        mutate("Move Band") {
            // Swap frequencies between the two bands so display order updates.
            let a = sorted[idx], b = sorted[newIdx]
            for i in self.bands.indices {
                if self.bands[i].id == a.id { self.bands[i].frequency = b.frequency }
                else if self.bands[i].id == b.id { self.bands[i].frequency = a.frequency }
            }
        }
    }

    // MARK: - Mutations: preset

    func loadPreset(id: UUID) {
        guard let preset = presetStore.preset(for: id) else { return }
        let oldPreset = audioEngine.activePreset
        audioEngine.activePreset = preset
        // Sync split channel state to match the loaded preset
        if preset.isSplitChannel {
            audioEngine.splitChannelActive = true
            if channel == .linked { channel = .l }
        } else {
            audioEngine.splitChannelActive = false
            channel = .linked
        }
        savedSnapshot = preset
        isModified = false
        syncFromAudioEngine()
        registerUndo(actionName: "Load Preset", oldPreset: oldPreset)
        var s = iQualizeState.load()
        s.selectedPresetID = preset.id
        s.save()
    }

    func resetToSnapshot() {
        guard let snap = savedSnapshot else { return }
        let old = audioEngine.activePreset
        audioEngine.activePreset = snap
        syncFromAudioEngine()
        isModified = false
        registerUndo(actionName: "Reset Preset", oldPreset: old)
    }

    func newPreset() {
        let existing = presetStore.allPresets.map { $0.name }
        var n = 1
        while existing.contains("Custom EQ \(n)") { n += 1 }
        let preset = EQPresetData(
            id: UUID(),
            name: "Custom EQ \(n)",
            bands: EQPresetData.flat.bands,
            isBuiltIn: false
        )
        presetStore.saveCustomPreset(preset)
        let old = audioEngine.activePreset
        audioEngine.activePreset = preset
        savedSnapshot = preset
        isModified = false
        syncFromAudioEngine()
        registerUndo(actionName: "New Preset", oldPreset: old)
    }

    func savePreset() {
        if isBuiltIn {
            // Save-As required for built-in
            saveAsPreset(name: nil)
            return
        }
        var preset = audioEngine.activePreset
        preset.bands = bands
        preset.rightBands = rightBands
        presetStore.saveCustomPreset(preset)
        savedSnapshot = preset
        isModified = false
    }

    func saveAsPreset(name: String?) {
        let baseName = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolvedName: String
        if baseName.isEmpty {
            let existing = presetStore.allPresets.map { $0.name }
            var n = 1
            while existing.contains("Custom EQ \(n)") { n += 1 }
            resolvedName = "Custom EQ \(n)"
        } else {
            resolvedName = baseName
        }
        let newPreset = EQPresetData(
            id: UUID(),
            name: resolvedName,
            bands: bands,
            rightBands: rightBands,
            isBuiltIn: false
        )
        presetStore.saveCustomPreset(newPreset)
        let old = audioEngine.activePreset
        audioEngine.activePreset = newPreset
        savedSnapshot = newPreset
        isModified = false
        syncFromAudioEngine()
        registerUndo(actionName: "Save As", oldPreset: old)
    }

    func deleteCurrentPreset() {
        guard !isBuiltIn else { return }
        presetStore.deleteCustomPreset(id: activePresetID)
        let old = audioEngine.activePreset
        audioEngine.activePreset = .flat
        savedSnapshot = .flat
        isModified = false
        syncFromAudioEngine()
        registerUndo(actionName: "Delete Preset", oldPreset: old)
    }

    // MARK: - Undo / Redo

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    // MARK: - Native dialogs

    /// Show a native save-as dialog (NSAlert with a text field accessory) and persist the result
    /// as a new custom preset.
    func presentSaveAsDialog() {
        let alert = NSAlert()
        alert.messageText = "Save Preset As"
        alert.informativeText = "Enter a name for this preset:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = isBuiltIn ? "" : presetName
        nameField.placeholderString = "My Custom EQ"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveAsPreset(name: nameField.stringValue)
    }

    // MARK: - Import / export

    /// Export the active preset to a JSON file. Uses an osascript-driven native save dialog —
    /// the original AppKit version found this more reliable than NSSavePanel under our menu-bar
    /// app's activation policy.
    func exportActivePreset() {
        let preset = audioEngine.activePreset
        let escapedName = preset.name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set f to POSIX path of (choose file name with prompt "Export Preset" default name "\(escapedName).iqpreset")
        return f
        """
        guard let path = Self.runAppleScript(script), !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Import one or more preset files via an osascript-driven open dialog (multi-select).
    /// For each imported preset shows a rename/overwrite dialog matching the AppKit version.
    func importPresets() {
        let script = """
        set fileList to choose file of type {"json", "iqpreset"} with prompt "Import Presets" with multiple selections allowed
        set output to ""
        repeat with f in fileList
            set output to output & POSIX path of f & linefeed
        end repeat
        return output
        """
        guard let output = Self.runAppleScript(script), !output.isEmpty else { return }
        let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        var lastImported: EQPresetData?

        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(EQPresetData.self, from: data)
                var importName = decoded.name.isEmpty
                    ? url.deletingPathExtension().lastPathComponent
                    : decoded.name

                let customNames = Set(presetStore.customPresets.map(\.name))
                let nameExists = customNames.contains(importName)

                let alert = NSAlert()
                alert.messageText = nameExists
                    ? "A preset named \"\(importName)\" already exists."
                    : "Import \"\(importName)\""
                alert.informativeText = "You can change the preset name before importing."
                alert.addButton(withTitle: nameExists ? "Overwrite" : "Import")
                alert.addButton(withTitle: "Skip")

                let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
                nameField.stringValue = importName
                alert.accessoryView = nameField
                alert.window.initialFirstResponder = nameField

                // Live-update the action button label as the user types so it always reflects
                // whether saving will overwrite an existing preset.
                let actionButton = alert.buttons[0]
                let observer = NotificationCenter.default.addObserver(
                    forName: NSControl.textDidChangeNotification,
                    object: nameField, queue: .main
                ) { _ in
                    let current = nameField.stringValue.trimmingCharacters(in: .whitespaces)
                    actionButton.title = customNames.contains(current) ? "Overwrite" : "Import"
                }

                let response = alert.runModal()
                NotificationCenter.default.removeObserver(observer)
                if response == .alertSecondButtonReturn { continue }

                let finalName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
                if finalName.isEmpty { continue }
                importName = finalName

                if let existing = presetStore.customPresets.first(where: { $0.name == importName }) {
                    let confirm = NSAlert()
                    confirm.messageText = "Overwrite \"\(importName)\"?"
                    confirm.informativeText = "This will replace the existing preset with the imported one."
                    confirm.addButton(withTitle: "Overwrite")
                    confirm.addButton(withTitle: "Cancel")
                    confirm.alertStyle = .warning
                    if confirm.runModal() != .alertFirstButtonReturn { continue }
                    presetStore.deleteCustomPreset(id: existing.id)
                }

                let preset = EQPresetData(
                    id: UUID(),
                    name: importName,
                    bands: decoded.bands,
                    rightBands: decoded.rightBands,
                    isBuiltIn: false
                )
                presetStore.saveCustomPreset(preset)
                lastImported = preset
            } catch {
                let alert = NSAlert(error: error)
                alert.informativeText = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                alert.runModal()
            }
        }

        if let preset = lastImported {
            let old = audioEngine.activePreset
            audioEngine.activePreset = preset
            savedSnapshot = preset
            isModified = false
            syncFromAudioEngine()
            registerUndo(actionName: "Import Preset", oldPreset: old)
        }
    }

    /// Runs an AppleScript snippet via /usr/bin/osascript, returns trimmed stdout or nil.
    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Footer wiring (apply changes to AudioEngine)

    func applyBypass() {
        audioEngine.bypassed = bypass
        persistFooterToggles()
        onBypassChanged?()
    }

    func applyPeakLimiter() {
        audioEngine.peakLimiter = peakLimiter
        persistFooterToggles()
    }

    func applyInputGain() {
        audioEngine.inputGainDB = inGainDB
        persistFooterToggles()
    }

    func applyOutputGain() {
        audioEngine.outputGainDB = outGainDB
        persistFooterToggles()
    }

    func applyBalance() {
        audioEngine.balance = balance
        persistFooterToggles()
    }

    func applyChannelChange() {
        if channel == .linked {
            // Disable split channel mode
            if audioEngine.activePreset.isSplitChannel {
                var preset = audioEngine.activePreset
                preset.disableSplitChannel()
                audioEngine.activePreset = preset
            }
            audioEngine.splitChannelActive = false
            rightBands = nil
        } else {
            // Enable split channel mode
            if !audioEngine.activePreset.isSplitChannel {
                var preset = audioEngine.activePreset
                preset.enableSplitChannel()
                audioEngine.activePreset = preset
            }
            audioEngine.splitChannelActive = true
        }
        syncFromAudioEngine()
        persistFooterToggles()
    }

    func applyMaxGain() {
        audioEngine.maxGainDB = maxGainDB
        persistFooterToggles()
    }
}

// MARK: - Sub-types

enum BandwidthDisplay: String, Sendable {
    case q, oct
}

enum ChannelMode: String, Sendable {
    case linked, l, r
}

struct EditingTarget: Equatable {
    let bandID: UUID
    let field: ReadoutField
}

enum ReadoutField: Equatable {
    case gain, frequency, bandwidth
}
