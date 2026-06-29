import AppKit
import ServiceManagement

@available(macOS 14.2, *)
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let audioEngine: AudioEngine
    private weak var eqWindowController: EQWindowController?

    private var peakLimiterCheckbox: NSButton!
    private var maxGainPicker: NSPopUpButton!
    private var autoScaleCheckbox: NSButton!
    private var preEqCheckbox: NSButton!
    private var postEqCheckbox: NSButton!
    private var preEqLineColorWell: NSColorWell!
    private var postEqLineColorWell: NSColorWell!
    private var preEqLineResetButton: NSButton!
    private var postEqLineResetButton: NSButton!
    private var preEqFillCheckbox: NSButton!
    private var postEqFillCheckbox: NSButton!
    private var preEqFillColorWell: NSColorWell!
    private var postEqFillColorWell: NSColorWell!
    private var preEqFillResetButton: NSButton!
    private var postEqFillResetButton: NSButton!
    private var bandwidthModeSegment: NSSegmentedControl!
    private var themeSegment: NSSegmentedControl!
    private var hideFromDockCheckbox: NSButton!
    private var startAtLoginCheckbox: NSButton!

    init(audioEngine: AudioEngine, eqWindowController: EQWindowController?) {
        self.audioEngine = audioEngine
        self.eqWindowController = eqWindowController

        let window = HelpAwareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: true
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        let contentView = buildContent()
        window.contentView = contentView
        let fitting = contentView.fittingSize
        window.setContentSize(NSSize(width: max(fitting.width, 320), height: fitting.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateEQWindowController(_ controller: EQWindowController?) {
        eqWindowController = controller
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let state = iQualizeState.load()
        peakLimiterCheckbox.state = audioEngine.peakLimiter ? .on : .off
        maxGainPicker.selectItem(withTag: Int(audioEngine.maxGainDB))
        autoScaleCheckbox.state = state.autoScale ? .on : .off
        maxGainPicker.isEnabled = !state.autoScale
        preEqCheckbox.state = state.preEqSpectrumEnabled ? .on : .off
        postEqCheckbox.state = state.postEqSpectrumEnabled ? .on : .off
        preEqLineColorWell.color = (state.preEqLineColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemCyan
        postEqLineColorWell.color = (state.postEqLineColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemOrange
        preEqFillCheckbox.state = state.preEqFillEnabled ? .on : .off
        postEqFillCheckbox.state = state.postEqFillEnabled ? .on : .off
        preEqFillColorWell.color = (state.preEqFillColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemCyan
        postEqFillColorWell.color = (state.postEqFillColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemOrange
        applyPostEqEnabled(!audioEngine.bypassed)
        bandwidthModeSegment.selectedSegment = state.showBandwidthAsQ ? 0 : 1
        themeSegment.selectedSegment = Self.themeIndex(for: state.dreamTheme)
    }

    func syncBypass(_ on: Bool) {
        applyPostEqEnabled(!on)
    }

    private func applyPostEqEnabled(_ enabled: Bool) {
        for control in [postEqCheckbox, postEqLineColorWell, postEqLineResetButton,
                        postEqFillCheckbox, postEqFillColorWell, postEqFillResetButton] as [NSControl] {
            control.isEnabled = enabled
        }
    }

    private func buildContent() -> NSView {
        let state = iQualizeState.load()

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Audio ──
        let audioHeader = makeSectionHeader("Audio")
        mainStack.addArrangedSubview(audioHeader)

        peakLimiterCheckbox = NSButton(checkboxWithTitle: "Peak Limiter",
                                        target: self, action: #selector(togglePeakLimiter(_:)))
        peakLimiterCheckbox.state = audioEngine.peakLimiter ? .on : .off
        mainStack.addArrangedSubview(peakLimiterCheckbox)

        let maxGainRow = NSStackView()
        maxGainRow.orientation = .horizontal
        maxGainRow.spacing = 6

        let maxGainLabel = NSTextField(labelWithString: "Max Gain:")
        maxGainLabel.font = .systemFont(ofSize: 13)
        maxGainRow.addArrangedSubview(maxGainLabel)

        maxGainPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        maxGainPicker.font = .systemFont(ofSize: 13)
        for db: Float in [6, 12, 18, 24] {
            maxGainPicker.addItem(withTitle: "±\(Int(db)) dB")
            maxGainPicker.lastItem?.tag = Int(db)
        }
        maxGainPicker.selectItem(withTag: Int(audioEngine.maxGainDB))
        maxGainPicker.target = self
        maxGainPicker.action = #selector(maxGainChanged(_:))
        maxGainPicker.isEnabled = !state.autoScale
        maxGainRow.addArrangedSubview(maxGainPicker)

        autoScaleCheckbox = NSButton(checkboxWithTitle: "Auto Scale",
                                       target: self, action: #selector(toggleAutoScale(_:)))
        autoScaleCheckbox.state = state.autoScale ? .on : .off
        maxGainRow.addArrangedSubview(autoScaleCheckbox)

        mainStack.addArrangedSubview(maxGainRow)

        // ── Display ──
        let displayHeader = makeSectionHeader("Display")
        mainStack.addArrangedSubview(displayHeader)

        preEqCheckbox = NSButton(checkboxWithTitle: "Pre-EQ Spectrum",
                                   target: self, action: #selector(togglePreEqSpectrum(_:)))
        preEqCheckbox.state = state.preEqSpectrumEnabled ? .on : .off
        preEqLineColorWell = makeColorWell(action: #selector(preEqLineColorChanged(_:)))
        preEqLineColorWell.color = (state.preEqLineColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemCyan
        preEqLineResetButton = makeResetButton(action: #selector(resetPreEqLineColor(_:)))
        preEqFillCheckbox = NSButton(checkboxWithTitle: "Fill",
                                      target: self, action: #selector(togglePreEqFill(_:)))
        preEqFillCheckbox.state = state.preEqFillEnabled ? .on : .off
        preEqFillColorWell = makeColorWell(action: #selector(preEqFillColorChanged(_:)))
        preEqFillColorWell.color = (state.preEqFillColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemCyan
        preEqFillResetButton = makeResetButton(action: #selector(resetPreEqFillColor(_:)))
        mainStack.addArrangedSubview(makeSpectrumGroup(
            checkbox: preEqCheckbox,
            lineWell: preEqLineColorWell, lineReset: preEqLineResetButton,
            fillCheckbox: preEqFillCheckbox,
            fillWell: preEqFillColorWell, fillReset: preEqFillResetButton
        ))

        postEqCheckbox = NSButton(checkboxWithTitle: "Post-EQ Spectrum",
                                    target: self, action: #selector(togglePostEqSpectrum(_:)))
        postEqCheckbox.state = state.postEqSpectrumEnabled ? .on : .off
        postEqLineColorWell = makeColorWell(action: #selector(postEqLineColorChanged(_:)))
        postEqLineColorWell.color = (state.postEqLineColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemOrange
        postEqLineResetButton = makeResetButton(action: #selector(resetPostEqLineColor(_:)))
        postEqFillCheckbox = NSButton(checkboxWithTitle: "Fill",
                                       target: self, action: #selector(togglePostEqFill(_:)))
        postEqFillCheckbox.state = state.postEqFillEnabled ? .on : .off
        postEqFillColorWell = makeColorWell(action: #selector(postEqFillColorChanged(_:)))
        postEqFillColorWell.color = (state.postEqFillColorHex.flatMap(NSColor.init(srgbHexRGB:))) ?? .systemOrange
        postEqFillResetButton = makeResetButton(action: #selector(resetPostEqFillColor(_:)))
        let postEqEnabled = !audioEngine.bypassed
        for control in [postEqCheckbox, postEqLineColorWell, postEqLineResetButton,
                        postEqFillCheckbox, postEqFillColorWell, postEqFillResetButton] as [NSControl] {
            control.isEnabled = postEqEnabled
        }
        mainStack.addArrangedSubview(makeSpectrumGroup(
            checkbox: postEqCheckbox,
            lineWell: postEqLineColorWell, lineReset: postEqLineResetButton,
            fillCheckbox: postEqFillCheckbox,
            fillWell: postEqFillColorWell, fillReset: postEqFillResetButton
        ))

        let bwRow = NSStackView()
        bwRow.orientation = .horizontal
        bwRow.spacing = 6

        let bwLabel = NSTextField(labelWithString: "Bandwidth:")
        bwLabel.font = .systemFont(ofSize: 13)
        bwRow.addArrangedSubview(bwLabel)

        bandwidthModeSegment = NSSegmentedControl(labels: ["Q", "Oct"], trackingMode: .selectOne,
                                                    target: self, action: #selector(bandwidthModeChanged(_:)))
        bandwidthModeSegment.selectedSegment = state.showBandwidthAsQ ? 0 : 1
        bwRow.addArrangedSubview(bandwidthModeSegment)

        mainStack.addArrangedSubview(bwRow)

        // ── General ──
        let generalHeader = makeSectionHeader("General")
        mainStack.addArrangedSubview(generalHeader)

        let themeRow = NSStackView()
        themeRow.orientation = .horizontal
        themeRow.spacing = 6

        let themeLabel = NSTextField(labelWithString: "Theme:")
        themeLabel.font = .systemFont(ofSize: 13)
        themeRow.addArrangedSubview(themeLabel)

        themeSegment = NSSegmentedControl(labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne,
                                          target: self, action: #selector(themeChanged(_:)))
        themeSegment.selectedSegment = Self.themeIndex(for: state.dreamTheme)
        themeRow.addArrangedSubview(themeSegment)

        mainStack.addArrangedSubview(themeRow)

        hideFromDockCheckbox = NSButton(checkboxWithTitle: "Hide from Dock",
                                          target: self, action: #selector(toggleHideFromDock(_:)))
        hideFromDockCheckbox.state = state.hideFromDock ? .on : .off
        mainStack.addArrangedSubview(hideFromDockCheckbox)

        startAtLoginCheckbox = NSButton(checkboxWithTitle: "Start at Login",
                                          target: self, action: #selector(toggleStartAtLogin(_:)))
        startAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        mainStack.addArrangedSubview(startAtLoginCheckbox)

        return mainStack
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func makeColorWell(action: Selector) -> NSColorWell {
        let well = NSColorWell(style: .minimal)
        well.target = self
        well.action = action
        well.widthAnchor.constraint(equalToConstant: 24).isActive = true
        well.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return well
    }

    private func makeResetButton(action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: "arrow.counterclockwise",
                            accessibilityDescription: "Reset to default")
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = "Reset to default"
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return button
    }

    private func makeSpectrumRow(checkbox: NSButton, colorWell: NSColorWell, resetButton: NSButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.addArrangedSubview(checkbox)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(colorWell)
        row.addArrangedSubview(resetButton)
        return row
    }

    private func makeSpectrumGroup(checkbox: NSButton,
                                   lineWell: NSColorWell, lineReset: NSButton,
                                   fillCheckbox: NSButton,
                                   fillWell: NSColorWell, fillReset: NSButton) -> NSStackView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        group.addArrangedSubview(makeSpectrumRow(checkbox: checkbox,
                                                  colorWell: lineWell,
                                                  resetButton: lineReset))
        let fillRow = makeSpectrumRow(checkbox: fillCheckbox,
                                       colorWell: fillWell,
                                       resetButton: fillReset)
        fillRow.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        group.addArrangedSubview(fillRow)
        return group
    }

    // MARK: - Actions

    @objc private func togglePeakLimiter(_ sender: NSButton) {
        audioEngine.peakLimiter = sender.state == .on
        var state = iQualizeState.load()
        state.peakLimiter = audioEngine.peakLimiter
        state.save()
        eqWindowController?.syncPeakLimiter(audioEngine.peakLimiter)
    }

    @objc private func maxGainChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        audioEngine.maxGainDB = Float(item.tag)
        var state = iQualizeState.load()
        state.maxGainDB = audioEngine.maxGainDB
        state.save()
        eqWindowController?.syncMaxGain(audioEngine.maxGainDB)
    }

    @objc private func toggleAutoScale(_ sender: NSButton) {
        let on = sender.state == .on
        maxGainPicker.isEnabled = !on
        var state = iQualizeState.load()
        state.autoScale = on
        state.save()
        eqWindowController?.syncAutoScale(on)
    }

    @objc private func togglePreEqSpectrum(_ sender: NSButton) {
        let on = sender.state == .on
        var state = iQualizeState.load()
        state.preEqSpectrumEnabled = on
        state.save()
        eqWindowController?.syncPreEqSpectrum(on)
    }

    @objc private func togglePostEqSpectrum(_ sender: NSButton) {
        let on = sender.state == .on
        var state = iQualizeState.load()
        state.postEqSpectrumEnabled = on
        state.save()
        eqWindowController?.syncPostEqSpectrum(on)
    }

    @objc private func preEqLineColorChanged(_ sender: NSColorWell) {
        let srgb = sender.color.usingColorSpace(.sRGB) ?? sender.color
        var state = iQualizeState.load()
        state.preEqLineColorHex = srgb.srgbHexRGB
        state.save()
        eqWindowController?.syncPreEqLineColor(srgb)
    }

    @objc private func postEqLineColorChanged(_ sender: NSColorWell) {
        let srgb = sender.color.usingColorSpace(.sRGB) ?? sender.color
        var state = iQualizeState.load()
        state.postEqLineColorHex = srgb.srgbHexRGB
        state.save()
        eqWindowController?.syncPostEqLineColor(srgb)
    }

    @objc private func resetPreEqLineColor(_ sender: NSButton) {
        var state = iQualizeState.load()
        state.preEqLineColorHex = nil
        state.save()
        preEqLineColorWell.color = .systemCyan
        eqWindowController?.syncPreEqLineColor(.systemCyan)
    }

    @objc private func resetPostEqLineColor(_ sender: NSButton) {
        var state = iQualizeState.load()
        state.postEqLineColorHex = nil
        state.save()
        postEqLineColorWell.color = .systemOrange
        eqWindowController?.syncPostEqLineColor(.systemOrange)
    }

    @objc private func togglePreEqFill(_ sender: NSButton) {
        let on = sender.state == .on
        var state = iQualizeState.load()
        state.preEqFillEnabled = on
        state.save()
        eqWindowController?.syncPreEqFillEnabled(on)
    }

    @objc private func togglePostEqFill(_ sender: NSButton) {
        let on = sender.state == .on
        var state = iQualizeState.load()
        state.postEqFillEnabled = on
        state.save()
        eqWindowController?.syncPostEqFillEnabled(on)
    }

    @objc private func preEqFillColorChanged(_ sender: NSColorWell) {
        let srgb = sender.color.usingColorSpace(.sRGB) ?? sender.color
        var state = iQualizeState.load()
        state.preEqFillColorHex = srgb.srgbHexRGB
        state.save()
        eqWindowController?.syncPreEqFillColor(srgb)
    }

    @objc private func postEqFillColorChanged(_ sender: NSColorWell) {
        let srgb = sender.color.usingColorSpace(.sRGB) ?? sender.color
        var state = iQualizeState.load()
        state.postEqFillColorHex = srgb.srgbHexRGB
        state.save()
        eqWindowController?.syncPostEqFillColor(srgb)
    }

    @objc private func resetPreEqFillColor(_ sender: NSButton) {
        var state = iQualizeState.load()
        state.preEqFillColorHex = nil
        state.save()
        preEqFillColorWell.color = .systemCyan
        eqWindowController?.syncPreEqFillColor(.systemCyan)
    }

    @objc private func resetPostEqFillColor(_ sender: NSButton) {
        var state = iQualizeState.load()
        state.postEqFillColorHex = nil
        state.save()
        postEqFillColorWell.color = .systemOrange
        eqWindowController?.syncPostEqFillColor(.systemOrange)
    }

    @objc private func bandwidthModeChanged(_ sender: NSSegmentedControl) {
        let asQ = sender.selectedSegment == 0
        var state = iQualizeState.load()
        state.showBandwidthAsQ = asQ
        state.save()
        eqWindowController?.syncBandwidthMode(asQ: asQ)
    }

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        let preference = Self.themePreference(for: sender.selectedSegment)
        var state = iQualizeState.load()
        state.dreamTheme = preference.rawValue
        state.save()
        eqWindowController?.syncTheme(preference)
    }

    /// Map a persisted `dreamTheme` raw value to a segment index (0 = Auto, 1 = Light, 2 = Dark).
    private static func themeIndex(for raw: String?) -> Int {
        switch DreamThemePreference(rawValue: raw ?? "") {
        case .light: return 1
        case .dark:  return 2
        default:     return 0
        }
    }

    private static func themePreference(for index: Int) -> DreamThemePreference {
        switch index {
        case 1:  return .light
        case 2:  return .dark
        default: return .auto
        }
    }

    @objc private func toggleHideFromDock(_ sender: NSButton) {
        var state = iQualizeState.load()
        state.hideFromDock = sender.state == .on
        state.save()
        NSApp.setActivationPolicy(state.hideFromDock ? .accessory : .regular)
        if !state.hideFromDock {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func toggleStartAtLogin(_ sender: NSButton) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to update login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        var state = iQualizeState.load()
        state.startAtLogin = SMAppService.mainApp.status == .enabled
        state.save()
    }
}
