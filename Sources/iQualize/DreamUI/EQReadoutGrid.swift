import AppKit
import SwiftUI

@available(macOS 14.2, *)
struct EQReadoutGrid: View {
    let vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        let bands = vm.displayBands
        VStack(spacing: 3) {
            row(for: .gain, bands: bands)
            row(for: .frequency, bands: bands)
            row(for: .bandwidth, bands: bands)
            typeRow(bands: bands)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.bgCanvas)
    }

    @ViewBuilder
    private func row(for field: ReadoutField, bands: [EQBand]) -> some View {
        HStack(spacing: 4) {
            ForEach(bands, id: \.id) { b in
                ReadoutCell(vm: vm, band: b, field: field)
            }
        }
    }

    @ViewBuilder
    private func typeRow(bands: [EQBand]) -> some View {
        HStack(spacing: 4) {
            ForEach(bands, id: \.id) { b in
                TypeCell(vm: vm, band: b)
            }
        }
    }
}

// MARK: - Readout cell

@available(macOS 14.2, *)
struct ReadoutCell: View {
    let vm: DreamViewModel
    let band: EQBand
    let field: ReadoutField

    @Environment(\.dreamTheme) private var theme
    @FocusState private var focused: Bool
    @State private var editingText: String = ""
    @State private var hover = false

    private var isSelected: Bool { vm.selectedBandID == band.id }
    private var isEditing: Bool { vm.editing == EditingTarget(bandID: band.id, field: field) }

    var body: some View {
        ZStack {
            if isEditing {
                TextField("", text: $editingText, onCommit: commitEdit)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focused)
                    .onAppear {
                        editingText = initialEditText
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { _, newValue in
                        if !newValue { commitEdit() }
                    }
                    .onExitCommand { vm.editing = nil }
            } else {
                Text(displayText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if band.muted {
                            Rectangle().fill(theme.textMute).frame(height: 1)
                                .padding(.horizontal, 4)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(
            // Scroll-wheel adjustment — same gesture as the original AppKit UnitTextField.
            ScrollWheelOverlay(onScroll: { _, dy, shift in
                applyScroll(dy: dy, shift: shift)
            })
        )
        .shadow(color: isSelected ? theme.accent.opacity(0.25) : .clear, radius: isSelected ? 5 : 0)
        .opacity(band.muted ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .onHover { hover = $0; if hover { vm.hoverBandID = band.id } else if vm.hoverBandID == band.id { vm.hoverBandID = nil } }
        .onTapGesture {
            // Single click = select + activate edit. Matches a typical macOS NSTextField click-to-edit.
            vm.selectedBandID = band.id
            vm.editing = EditingTarget(bandID: band.id, field: field)
        }
    }

    private func applyScroll(dy: CGFloat, shift: Bool) {
        guard !isEditing else { return }
        // Lock the scroll target so a long scroll burst keeps editing the same band even after the
        // cells re-sort by frequency.
        let targetID = vm.scrollWheelTarget(field: field, currentBandID: band.id)
        guard let current = vm.band(id: targetID) else { return }
        vm.selectedBandID = targetID
        vm.beginDrag()
        let dir: Float = dy > 0 ? 1 : -1
        switch field {
        case .gain:
            let step: Float = shift ? 0.1 : 0.5
            let newG = max(-vm.gainClamp, min(vm.gainClamp, current.gain + dir * step))
            vm.updateBand(id: targetID, gain: newG)
        case .frequency:
            let factor = pow(2.0, dir * (shift ? (1.0 / 24.0) : (1.0 / 12.0)))
            let newF = max(20, min(20000, current.frequency * Float(factor)))
            vm.updateBand(id: targetID, frequency: newF)
        case .bandwidth:
            if vm.bandwidthDisplay == .oct {
                let step: Float = shift ? 0.02 : 0.1
                let newB = max(0.05, min(8, current.bandwidth + dir * step))
                vm.updateBand(id: targetID, bandwidth: newB)
            } else {
                let step: Float = shift ? 0.01 : 0.05
                let curQ = Float(octavesToQ(Double(current.bandwidth)))
                let newQ = max(0.05, min(20, curQ + dir * step))
                let newB = max(0.05, min(8, Float(qToOctaves(Double(newQ)))))
                vm.updateBand(id: targetID, bandwidth: newB)
            }
        }
        vm.recordScrollWheelTick(target: targetID, field: field)
        scheduleScrollCommit()
    }

    @MainActor
    private static var scrollCommitTask: Task<Void, Never>?

    private func scheduleScrollCommit() {
        Self.scrollCommitTask?.cancel()
        Self.scrollCommitTask = Task { @MainActor [vm] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { vm.commitDrag("Adjust Band") }
        }
    }

    private var displayText: String {
        switch field {
        case .gain:
            return formatDB(band.gain)
        case .frequency:
            return formatHz(band.frequency)
        case .bandwidth:
            if vm.bandwidthDisplay == .q {
                let q = octavesToQ(Double(band.bandwidth))
                return q < 1 ? String(format: "Q %.2f", q) : String(format: "Q %.1f", q)
            }
            return String(format: "%.2f oct", band.bandwidth)
        }
    }

    private var initialEditText: String {
        switch field {
        case .gain:      return String(format: "%.1f", band.gain)
        case .frequency: return band.frequency >= 1000 ? String(format: "%.2f", band.frequency / 1000) : String(format: "%.0f", band.frequency)
        case .bandwidth: return vm.bandwidthDisplay == .oct ? String(format: "%.2f", band.bandwidth) : String(format: "%.2f", octavesToQ(Double(band.bandwidth)))
        }
    }

    private func commitEdit() {
        defer { vm.editing = nil }
        guard let raw = Double(editingText.trimmingCharacters(in: .whitespaces)) else { return }
        switch field {
        case .gain:
            vm.updateBand(id: band.id, gain: Float(max(-Double(vm.gainClamp), min(Double(vm.gainClamp), raw))), registerUndo: true)
        case .frequency:
            // "1.5" → 1.5 kHz when small
            let v = raw < 100 ? raw * 1000 : raw
            vm.updateBand(id: band.id, frequency: Float(max(20, min(20000, v))), registerUndo: true)
        case .bandwidth:
            if vm.bandwidthDisplay == .oct {
                vm.updateBand(id: band.id, bandwidth: Float(max(0.05, min(8, raw))), registerUndo: true)
            } else {
                let oct = qToOctaves(raw)
                vm.updateBand(id: band.id, bandwidth: Float(max(0.05, min(8, oct))), registerUndo: true)
            }
        }
    }

    private var textColor: Color {
        if isSelected { return theme.scheme == .light ? theme.text : .white }
        if field == .gain {
            if band.gain > 0 { return theme.gainPos }
            if band.gain < 0 { return theme.gainNeg }
        }
        if field == .bandwidth { return theme.textDim }
        return theme.text
    }

    private var backgroundFill: Color {
        if isSelected { return theme.bgReadoutSel }
        if hover { return theme.bgReadoutHover }
        return theme.bgReadout
    }

    private var borderColor: Color {
        if isSelected { return theme.accent }
        if hover { return theme.line2 }
        return theme.line
    }
}

// MARK: - Type cell

@available(macOS 14.2, *)
struct TypeCell: View {
    let vm: DreamViewModel
    let band: EQBand

    @Environment(\.dreamTheme) private var theme
    @State private var hover = false

    private var isSelected: Bool { vm.selectedBandID == band.id }

    private static let allTypes: [(FilterType, String)] = [
        (.parametric, "Bell"),
        (.lowShelf,   "Low Shelf"),
        (.highShelf,  "High Shelf"),
        (.lowPass,    "Low Pass"),
        (.highPass,   "High Pass"),
        (.bandPass,   "Band Pass"),
        (.notch,      "Notch"),
    ]

    var body: some View {
        FilterTypePopUpButton(
            selection: Binding(
                get: { band.filterType },
                set: { newType in
                    vm.selectedBandID = band.id
                    vm.updateBand(id: band.id, filterType: newType, registerUndo: true)
                }
            ),
            isSelected: isSelected,
            onMouseDown: { vm.selectedBandID = band.id }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.bgReadoutSel : (hover ? theme.bgReadoutHover : theme.bgReadout))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? theme.accent : (hover ? theme.line2 : theme.line), lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: isSelected ? theme.accent.opacity(0.25) : .clear, radius: isSelected ? 5 : 0)
        .opacity(band.muted ? 0.45 : 1.0)
        .onHover { hover = $0 }
    }

    private var label: String {
        switch band.filterType {
        case .parametric: return "Bell"
        case .lowShelf:   return "Low Shelf"
        case .highShelf:  return "High Shelf"
        case .lowPass:    return "Low Pass"
        case .highPass:   return "High Pass"
        case .bandPass:   return "Band Pass"
        case .notch:      return "Notch"
        }
    }
}

// MARK: - Format helpers (shared with canvas)

func formatDB(_ g: Float) -> String {
    String(format: "%@%.1f dB", g >= 0 ? "+" : "", g)
}

func formatHz(_ f: Float) -> String {
    if f >= 1000 {
        let k = f / 1000
        if k >= 10 { return String(format: "%.1f kHz", k) }
        let s = String(format: "%.2f", k)
        let trimmed = s.contains(".") ? s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : s
        return "\(trimmed) kHz"
    }
    return "\(Int(f.rounded())) Hz"
}

func octavesToQ(_ oct: Double) -> Double {
    1.0 / (2.0 * sinh(log(2.0) / 2.0 * max(0.001, oct)))
}

func qToOctaves(_ q: Double) -> Double {
    (2.0 / log(2.0)) * asinh(1.0 / (2.0 * max(0.001, q)))
}
