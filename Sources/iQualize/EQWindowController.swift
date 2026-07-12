import AppKit
import SwiftUI

// MARK: - Custom window for keyboard event interception

@available(macOS 14.2, *)
@MainActor
final class EQWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if HelpShortcut.handles(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - EQ Window Controller (Dream UI bridge)

@available(macOS 14.2, *)
@MainActor
final class EQWindowController: NSWindowController {
    private let audioEngine: AudioEngine
    private let presetStore: PresetStore
    private let viewModel: DreamViewModel

    /// Callback to open the settings window.
    var onOpenSettings: (() -> Void)? {
        didSet { viewModel.onOpenSettings = onOpenSettings }
    }
    /// Callback fired when the user toggles bypass from this window.
    var onBypassChanged: (() -> Void)? {
        didSet { viewModel.onBypassChanged = onBypassChanged }
    }

    init(audioEngine: AudioEngine, presetStore: PresetStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore
        self.viewModel = DreamViewModel(audioEngine: audioEngine, presetStore: presetStore)

        let window = DreamHostingView.makeWindow(viewModel: viewModel)
        super.init(window: window)

        // Ensure the view model picks up the latest output device name from the engine.
        let previousCallback = audioEngine.onStateChange
        audioEngine.onStateChange = { [weak self] in
            previousCallback?()
            self?.viewModel.syncFromAudioEngine()
            self?.refreshWindowTitle()
        }

        // Restore active preset. Falls back to Flat if the persisted ID no longer resolves
        // (e.g. it pointed at a built-in that's since been hidden), correcting persisted state
        // so this doesn't repeat on next launch.
        var state = iQualizeState.load()
        if let preset = presetStore.preset(for: state.selectedPresetID) {
            audioEngine.activePreset = preset
        } else {
            audioEngine.activePreset = .flat
            state.selectedPresetID = EQPresetData.flat.id
            state.save()
        }
        viewModel.syncFromAudioEngine(initial: true)

        viewModel.onTitleShouldUpdate = { [weak self] in self?.refreshWindowTitle() }
        refreshWindowTitle()

        // Keyboard shortcuts (arrow keys, Esc, ⌘Z/⇧⌘Z, ⌘B, M, Tab, ⌫). Routed through the
        // window's keyDown so they fire even when SwiftUI's local-event monitor is somehow bypassed.
        window.onKeyDown = { [weak self] event in
            self?.viewModel.handleKey(event) ?? false
        }
    }

    private func refreshWindowTitle() {
        let name = viewModel.presetName
        window?.title = viewModel.isModified ? "iQualize — \(name) ●" : "iQualize — \(name)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - External sync methods (called by Settings / MenuBar)

    /// Re-read the active preset from the audio engine — used after Settings changes presets externally.
    func syncUIToPreset() {
        viewModel.syncFromAudioEngine(initial: true)
    }

    func syncBypass(_ on: Bool) {
        viewModel.bypass = on
    }

    func syncPeakLimiter(_ on: Bool) {
        viewModel.peakLimiter = on
    }

    func syncGainIsGlobal(_ on: Bool) {
        viewModel.gainIsGlobal = on
    }

    func syncMaxGain(_ db: Float) {
        viewModel.maxGainDB = db
    }

    func syncAutoScale(_ on: Bool) {
        viewModel.autoScale = on
    }

    func syncPreEqSpectrum(_ on: Bool) {
        viewModel.preEqEnabled = on
    }

    func syncPostEqSpectrum(_ on: Bool) {
        viewModel.postEqEnabled = on
    }

    func syncBandwidthMode(asQ: Bool) {
        viewModel.bandwidthDisplay = asQ ? .q : .oct
    }

    func syncTheme(_ preference: DreamThemePreference) {
        viewModel.theme = preference
    }

    func syncPreEqLineColor(_ color: NSColor) {
        viewModel.preEqLineColor = Color(nsColor: color)
    }

    func syncPostEqLineColor(_ color: NSColor) {
        viewModel.postEqLineColor = Color(nsColor: color)
    }

    func syncPreEqFillEnabled(_ on: Bool) {
        viewModel.preEqFillEnabled = on
    }

    func syncPostEqFillEnabled(_ on: Bool) {
        viewModel.postEqFillEnabled = on
    }

    func syncPreEqFillColor(_ color: NSColor) {
        viewModel.preEqFillColor = Color(nsColor: color)
    }

    func syncPostEqFillColor(_ color: NSColor) {
        viewModel.postEqFillColor = Color(nsColor: color)
    }
}
