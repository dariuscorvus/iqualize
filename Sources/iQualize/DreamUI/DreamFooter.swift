import SwiftUI

@available(macOS 14.2, *)
struct DreamFooter: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            // Row 1 — levels & routing.
            HStack(spacing: 10) {
                gainSlider(label: "In", value: $vm.inGainDB, onChange: vm.applyInputGain)
                gainSlider(label: "Out", value: $vm.outGainDB, onChange: vm.applyOutputGain)
                balanceSlider
                divider
                channelSegment
                Spacer()
            }

            // Row 2 — spectrum, scale, and processing.
            HStack(spacing: 10) {
                bypassToggle
                divider
                preEqToggle
                postEqToggle
                divider
                maxGainSegment
                autoScaleToggle
                divider
                peakLimiterToggle
                divider
                bandwidthDisplaySegment
                Spacer()
            }

            // Row 3 — output device, centered beneath the controls.
            outputLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.bgToolbar)
    }

    /// Thin vertical separator between footer groups, matching the toolbar's
    /// `DreamToolbarGroup` divider language.
    @ViewBuilder
    private var divider: some View {
        theme.line
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    // MARK: - Toggles

    @ViewBuilder
    private var bypassToggle: some View {
        DreamCheckbox(title: "Bypass", isOn: Binding(
            get: { vm.bypass },
            set: { vm.bypass = $0; vm.applyBypass() }
        ))
    }

    @ViewBuilder
    private var preEqToggle: some View {
        DreamCheckbox(title: "Pre-EQ", isOn: Binding(
            get: { vm.preEqEnabled },
            set: { vm.preEqEnabled = $0; vm.persistFooterToggles() }
        ))
    }

    @ViewBuilder
    private var postEqToggle: some View {
        DreamCheckbox(title: "Post-EQ", isOn: Binding(
            get: { vm.postEqEnabled && !vm.bypass },
            set: { if !vm.bypass { vm.postEqEnabled = $0; vm.persistFooterToggles() } }
        ), disabled: vm.bypass)
    }

    @ViewBuilder
    private var peakLimiterToggle: some View {
        DreamCheckbox(title: "Peak Limiter", isOn: Binding(
            get: { vm.peakLimiter },
            set: { vm.peakLimiter = $0; vm.applyPeakLimiter() }
        ))
    }

    @ViewBuilder
    private var autoScaleToggle: some View {
        DreamCheckbox(title: "Auto-scale", isOn: Binding(
            get: { vm.autoScale },
            set: { vm.autoScale = $0; vm.persistFooterToggles() }
        ))
    }

    // MARK: - Sliders

    @ViewBuilder
    private func gainSlider(label: String, value: Binding<Float>, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundStyle(theme.textMute)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 28, alignment: .trailing)
            DreamSlider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0); onChange() }
                ),
                range: -24...24,
                step: 0.5
            )
            Text(formatSigned(value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 52, alignment: .leading)
        }
    }

    @ViewBuilder
    private var balanceSlider: some View {
        HStack(spacing: 8) {
            Text("Bal:")
                .font(.system(size: 11))
                .foregroundStyle(theme.textMute)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 28, alignment: .trailing)
            DreamSlider(
                value: Binding(
                    get: { Double(vm.balance) },
                    set: { vm.balance = Float($0); vm.applyBalance() }
                ),
                range: -1...1,
                step: 0.05,
                width: 70
            )
            Text(formatBalance(vm.balance))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 34, alignment: .leading)
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private var channelSegment: some View {
        DreamSegment(
            selection: Binding(
                get: { vm.channel },
                set: { vm.channel = $0; vm.applyChannelChange() }
            ),
            options: [
                (.linked, "Linked"), (.l, "L"), (.r, "R")
            ]
        )
    }

    @ViewBuilder
    private var bandwidthDisplaySegment: some View {
        DreamSegment(
            selection: Binding(
                get: { vm.bandwidthDisplay },
                set: { vm.bandwidthDisplay = $0; vm.persistBandwidthDisplay() }
            ),
            options: [(.q, "Q"), (.oct, "Oct")]
        )
    }

    @ViewBuilder
    private var maxGainSegment: some View {
        DreamSegment(
            selection: Binding(
                get: { Int(vm.maxGainDB) },
                set: { vm.maxGainDB = Float($0); vm.autoScale = false; vm.applyMaxGain() }
            ),
            options: [(12, "±12"), (18, "±18"), (24, "±24")],
            dimmed: vm.autoScale
        )
        .help(vm.autoScale
            ? "Auto-scale is on, so the graph's axis grows to fit the curve. Click a range to switch to that fixed range."
            : "Graph axis range")
    }

    // MARK: - Output label

    private var outputLabelText: String {
        if let pinned = vm.pinnedPresetNameForCurrentDevice {
            return "\(vm.outputDeviceName) · Pinned: \(pinned)"
        }
        return vm.outputDeviceName
    }

    @ViewBuilder
    private var outputLabel: some View {
        Text(outputLabelText)
            .font(.system(size: 11))
            .foregroundStyle(theme.textMute)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 320)
            .help(outputLabelText)
    }

    // MARK: - Format

    private func formatSigned(_ v: Float) -> String {
        String(format: "%@%.1f dB", v >= 0 ? "+" : "", v)
    }

    private func formatBalance(_ v: Float) -> String {
        if abs(v) < 0.01 { return "0" }
        let pct = Int(round(abs(v) * 100))
        return v < 0 ? "L\(pct)" : "R\(pct)"
    }
}
