import SwiftUI

@available(macOS 14.2, *)
struct DreamFooter: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            // Row 1: Bypass · In · Out · Balance · Channel
            HStack(spacing: 12) {
                bypassToggle
                gainSlider(label: "In", value: $vm.inGainDB, onChange: vm.applyInputGain)
                gainSlider(label: "Out", value: $vm.outGainDB, onChange: vm.applyOutputGain)
                balanceSlider
                channelSegment
                Spacer()
                outputLabel
            }

            // Row 2: Pre-EQ · Post-EQ · Q/Oct · Peak Limiter · Auto-scale · Max gain
            HStack(spacing: 12) {
                preEqToggle
                postEqToggle
                bandwidthDisplaySegment
                peakLimiterToggle
                autoScaleToggle
                maxGainSegment
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.bgToolbar)
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
                .frame(minWidth: 22, alignment: .trailing)
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
                .frame(minWidth: 50, alignment: .leading)
        }
    }

    @ViewBuilder
    private var balanceSlider: some View {
        HStack(spacing: 8) {
            Text("Bal:")
                .font(.system(size: 11))
                .foregroundStyle(theme.textMute)
                .frame(minWidth: 22, alignment: .trailing)
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
                .frame(minWidth: 30, alignment: .leading)
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
                set: { vm.maxGainDB = Float($0); vm.applyMaxGain() }
            ),
            options: [(12, "±12"), (18, "±18"), (24, "±24")]
        )
    }

    // MARK: - Output label

    @ViewBuilder
    private var outputLabel: some View {
        HStack(spacing: 4) {
            Text("Output:")
                .foregroundStyle(theme.textMute)
            Text(vm.outputDeviceName)
                .foregroundStyle(theme.textDim)
        }
        .font(.system(size: 12))
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
