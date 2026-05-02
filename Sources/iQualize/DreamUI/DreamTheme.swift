import AppKit
import SwiftUI

/// Color tokens that mirror the Dream UI HTML's CSS custom properties
/// (`--bg-page`, `--bg-window`, `--accent`, etc.). Indexed by `ColorScheme`
/// so the same call sites work in both light and dark.
struct DreamTheme {
    let scheme: ColorScheme

    // Surfaces
    var bgPage: Color           { scheme == .dark ? Color(rgb: 0x0a0c10) : Color(rgb: 0xf1f3f7) }
    var bgWindow: Color         { Color(nsColor: .windowBackgroundColor) }
    var bgTitlebar: Color       { Color(nsColor: .windowBackgroundColor) }
    var bgToolbar: Color        { Color(nsColor: .windowBackgroundColor) }
    var bgCanvas: Color         { Color(nsColor: .controlBackgroundColor) }
    var bgReadout: Color        { scheme == .dark ? Color.white.opacity(0.025) : Color.black.opacity(0.025) }
    var bgReadoutHover: Color   { scheme == .dark ? Color.white.opacity(0.05)  : Color.black.opacity(0.05) }
    var bgReadoutSel: Color     { Color(rgba: 0x3b82f6, a: scheme == .dark ? 0.15 : 0.12) }
    var bgPopover: Color        { scheme == .dark ? Color(rgba: 0x1c202a, a: 0.96) : Color(rgba: 0xfcfdff, a: 0.96) }
    var bgControl: Color        { scheme == .dark ? Color(rgba: 0x141820, a: 0.80) : Color(rgba: 0xffffff, a: 0.86) }
    var bgHint: Color           { scheme == .dark ? Color(rgba: 0x141820, a: 0.55) : Color(rgba: 0xffffff, a: 0.70) }

    // Lines
    var line: Color             { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    var line2: Color            { scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14) }
    var lineStrong: Color       { scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.22) }

    // Text
    var text: Color             { scheme == .dark ? Color(rgb: 0xe8ebf0) : Color(rgb: 0x1a1d23) }
    var textDim: Color          { scheme == .dark ? Color(rgb: 0x9aa3b2) : Color(rgb: 0x5e6675) }
    var textMute: Color         { scheme == .dark ? Color(rgb: 0x5e6675) : Color(rgb: 0x9aa3b2) }

    // Accents
    var accent: Color           { Color(rgb: 0x3b82f6) }
    var accent2: Color          { Color(rgb: 0x60a5fa) }
    var accentDeep: Color       { Color(rgb: 0x1d4ed8) }
    var pre: Color              { Color(rgb: 0xf59e0b) }
    var post: Color             { Color(rgb: 0x22d3ee) }
    var warn: Color             { Color(rgb: 0xf87171) }
    var good: Color             { Color(rgb: 0x34d399) }

    // Gain colour pairs (pos / neg) used in readouts and band labels
    var gainPos: Color          { scheme == .dark ? Color(rgb: 0x93c5fd) : Color(rgb: 0x1d4ed8) }
    var gainNeg: Color          { scheme == .dark ? Color(rgb: 0xfca5a5) : Color(rgb: 0xb91c1c) }

    // Knob fills
    var knobFillBase: Color     { .white }
    var knobFillMuted: Color    { scheme == .dark ? Color(rgba: 0x141820, a: 0.92) : Color(rgb: 0xe7eaf0) }

    // Accent for the bandwidth oct/Q text rendered on the canvas during drag
    var bandwidthAccent: Color  { scheme == .dark ? Color(rgba: 0x60a5fa, a: 0.92) : Color(rgba: 0x1d4ed8, a: 0.92) }

    // Numeric "ink" for grid lines and labels — white in dark, black in light
    var inkRGB: (Double, Double, Double) { scheme == .dark ? (1, 1, 1) : (0, 0, 0) }

    // Radii
    var windowRadius: CGFloat   { 12 }
    var controlRadius: CGFloat  { 6 }
}

// MARK: - Environment plumbing

private struct DreamThemeKey: EnvironmentKey {
    static let defaultValue = DreamTheme(scheme: .dark)
}

extension EnvironmentValues {
    var dreamTheme: DreamTheme {
        get { self[DreamThemeKey.self] }
        set { self[DreamThemeKey.self] = newValue }
    }
}

// MARK: - Color hex helpers

extension Color {
    init(rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xff) / 255.0
        let g = Double((rgb >>  8) & 0xff) / 255.0
        let b = Double( rgb        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    init(rgba: UInt32, a: Double) {
        let r = Double((rgba >> 16) & 0xff) / 255.0
        let g = Double((rgba >>  8) & 0xff) / 255.0
        let b = Double( rgba        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Theme preference for explicit light/dark/auto

enum DreamThemePreference: String, CaseIterable, Sendable {
    case auto, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }

    var systemImage: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark:  return "moon"
        }
    }
}
