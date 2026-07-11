import AppKit
import SwiftUI

// MARK: - tb-btn (toolbar button)

struct DreamToolbarButton<Label: View>: View {
    let label: Label
    let action: () -> Void
    var dimmed: Bool = false
    var dirty: Bool = false
    var iconOnly: Bool = false
    var isOn: Bool = false

    @Environment(\.dreamTheme) private var theme
    @State private var hover = false
    @State private var pressed = false

    init(action: @escaping () -> Void, dimmed: Bool = false, dirty: Bool = false, iconOnly: Bool = false, isOn: Bool = false, @ViewBuilder label: () -> Label) {
        self.action = action
        self.dimmed = dimmed
        self.dirty = dirty
        self.iconOnly = iconOnly
        self.isOn = isOn
        self.label = label()
    }

    var body: some View {
        Button(action: dimmed ? {} : action) {
            HStack(spacing: 6) {
                label
                if dirty {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: theme.accent, radius: 3)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(dimmed ? theme.textMute : theme.text)
            .frame(height: 28)
            .padding(.horizontal, iconOnly ? 0 : 11)
            .frame(width: iconOnly ? 28 : nil)
            .background(
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
        .onHover { hover = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    private var backgroundFill: Color {
        if isOn { return theme.accent.opacity(0.22) }
        if pressed { return Color.white.opacity(theme.scheme == .dark ? 0.12 : 0.08) }
        if hover && !dimmed { return Color.white.opacity(theme.scheme == .dark ? 0.08 : 0.05) }
        return Color.white.opacity(theme.scheme == .dark ? 0.04 : 0.02)
    }

    private var borderColor: Color {
        if isOn { return theme.accent }
        if hover && !dimmed { return theme.line2 }
        return theme.line
    }
}

// MARK: - check (.check label class)

struct DreamCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        Button(action: { if !disabled { isOn.toggle() } }) {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn && !disabled ? theme.accent : (theme.scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(isOn && !disabled ? theme.accent : theme.line2, lineWidth: 1)
                        )
                        .frame(width: 12, height: 12)
                    if isOn && !disabled {
                        Path { p in
                            p.move(to: CGPoint(x: 2.5, y: 6))
                            p.addLine(to: CGPoint(x: 5, y: 8.5))
                            p.addLine(to: CGPoint(x: 9.5, y: 3.5))
                        }
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                    }
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(disabled ? theme.textMute : theme.textDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .opacity(disabled ? 0.4 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - seg (segmented control)

struct DreamSegment<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    /// Visually dims the control (e.g. to show it's currently overridden) without blocking taps —
    /// tapping an option should still act like a toggle that takes back control.
    var dimmed: Bool = false

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(action: { selection = opt.value }) {
                    Text(opt.label)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(selection == opt.value && !dimmed ? .white : theme.textDim)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection == opt.value && !dimmed ? theme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(theme.scheme == .dark ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.line, lineWidth: 1)
        )
        .opacity(dimmed ? 0.5 : 1.0)
    }
}

// MARK: - slim slider matching `.slider` class

struct DreamSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var width: CGFloat = 90

    @Environment(\.dreamTheme) private var theme

    var body: some View {
        Slider(value: $value, in: range, step: step)
            .controlSize(.mini)
            .tint(theme.accent)
            .frame(width: width)
    }
}

// MARK: - toolbar group separator

struct DreamToolbarGroup<Content: View>: View {
    let content: Content
    var trailingDivider: Bool = true

    @Environment(\.dreamTheme) private var theme

    init(trailingDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.trailingDivider = trailingDivider
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.trailing, trailingDivider ? 8 : 0)
        .overlay(alignment: .trailing) {
            if trailingDivider {
                theme.line
                    .frame(width: 1)
                    .padding(.vertical, 4)
            }
        }
        .padding(.trailing, trailingDivider ? 4 : 0)
    }
}

// MARK: - Magnet icon

/// Tabler's `magnet` glyph (SF Symbols has no `magnet` on macOS), rendered straight from its SVG
/// as a template image so it tints with the control's foreground/accent color — the Snap toggle
/// shows it in the text color when off and white when on.
struct MagnetIcon: View {
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private static let image: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 13V5a2 2 0 0 1 2-2h1a2 2 0 0 1 2 2v8a2 2 0 0 0 6 0V5a2 2 0 0 1 2-2h1a2 2 0 0 1 2 2v8a8 8 0 0 1-16 0m0-5h5m6 0h4"/></svg>"#
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

// MARK: - Filter type icon (mirrors FilterIcon paths in the JSX)

struct FilterTypeIcon: View {
    let type: FilterType
    var size: CGSize = CGSize(width: 16, height: 14)
    var lineWidth: CGFloat = 1.4

    var body: some View {
        FilterTypeShape(type: type)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size.width, height: size.height)
    }
}

private struct FilterTypeShape: Shape {
    let type: FilterType

    func path(in rect: CGRect) -> Path {
        // The original geometry is laid out in a 16x14 box; scale to whatever frame we're given.
        let sx = rect.width / 16
        let sy = rect.height / 14
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        switch type {
        case .parametric:
            p.move(to: pt(2, 8))
            p.addQuadCurve(to: pt(8, 2), control: pt(5, 8))
            p.addQuadCurve(to: pt(14, 8), control: pt(11, 8))
        case .lowShelf:
            p.move(to: pt(2, 4))
            p.addQuadCurve(to: pt(7, 8), control: pt(5, 4))
            p.addLine(to: pt(14, 8))
        case .highShelf:
            p.move(to: pt(2, 8))
            p.addLine(to: pt(7, 8))
            p.addQuadCurve(to: pt(14, 4), control: pt(9, 8))
        case .lowPass:
            p.move(to: pt(2, 6))
            p.addLine(to: pt(8, 6))
            p.addQuadCurve(to: pt(14, 12), control: pt(10, 6))
        case .highPass:
            p.move(to: pt(2, 12))
            p.addQuadCurve(to: pt(6, 6), control: pt(4, 12))
            p.addLine(to: pt(14, 6))
        case .bandPass:
            p.move(to: pt(2, 12))
            p.addQuadCurve(to: pt(7, 4), control: pt(5, 12))
            p.addQuadCurve(to: pt(11, 4), control: pt(9, 4))
            p.addQuadCurve(to: pt(14, 12), control: pt(14, 4))
        case .notch:
            p.move(to: pt(2, 4))
            p.addQuadCurve(to: pt(7, 11), control: pt(6, 4))
            p.addQuadCurve(to: pt(14, 4), control: pt(8, 4))
        }
        return p
    }
}
