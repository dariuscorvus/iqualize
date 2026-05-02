import AppKit
import SwiftUI

/// Native NSPopUpButton wrapper used for the per-band filter type cell.
/// SwiftUI's `Menu` strips custom HStack labels in `.borderlessButton` style, so we drop down to AppKit
/// to get an icon-and-text trigger plus icon-and-text menu items rendered by the system menu.
@available(macOS 14.2, *)
struct FilterTypePopUpButton: NSViewRepresentable {
    @Binding var selection: FilterType
    var isSelected: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = BorderlessPopUp()
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageLeft
        button.alignment = .center
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        rebuildMenu(on: button)
        syncSelection(button: button)
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuildMenu(on: nsView)
        syncSelection(button: nsView)
    }

    /// `accent2` from DreamTheme — the light blue used for the composite EQ curve line.
    private static let accentBlue = NSColor(srgbRed: 0x60 / 255.0, green: 0xa5 / 255.0, blue: 0xfa / 255.0, alpha: 1)

    private func rebuildMenu(on button: NSPopUpButton) {
        button.removeAllItems()
        for option in Self.allOptions {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            // Smaller icon, light-blue (matches graph line) baked in, with extra left padding so the
            // glyph doesn't kiss the cell edge.
            item.image = FilterTypeNSImage.image(
                for: option.type,
                size: NSSize(width: 12, height: 9),
                leftPadding: 4,
                color: Self.accentBlue
            )
            item.representedObject = option.type
            button.menu?.addItem(item)
        }
    }

    private func syncSelection(button: NSPopUpButton) {
        if let idx = button.itemArray.firstIndex(where: { ($0.representedObject as? FilterType) == selection }) {
            button.selectItem(at: idx)
        }
    }

    private static let allOptions: [(type: FilterType, label: String)] = [
        (.parametric, "Bell"),
        (.lowShelf,   "Low Shelf"),
        (.highShelf,  "High Shelf"),
        (.lowPass,    "Low Pass"),
        (.highPass,   "High Pass"),
        (.bandPass,   "Band Pass"),
        (.notch,      "Notch"),
    ]

    @MainActor
    final class Coordinator: NSObject {
        var parent: FilterTypePopUpButton
        init(_ parent: FilterTypePopUpButton) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem,
                  let type = item.representedObject as? FilterType else { return }
            parent.selection = type
        }
    }
}

/// NSPopUpButton subclass with no bezel — the surrounding SwiftUI cell draws the styling.
@available(macOS 14.2, *)
private final class BorderlessPopUp: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = 22
        return size
    }
}

/// Renders a FilterTypeIcon path as an NSImage so it can sit on NSMenuItems.
@MainActor
enum FilterTypeNSImage {
    /// - Parameters:
    ///   - size: target glyph size (the actual stroke region).
    ///   - leftPadding: transparent space added on the left of the canvas so the glyph isn't
    ///                  flush with the popup button's edge.
    ///   - color: stroke color baked into the image (we don't use template tinting here so
    ///            the title text stays its normal color while only the glyph picks up the accent).
    static func image(for type: FilterType, size: NSSize, leftPadding: CGFloat = 0, color: NSColor = .labelColor) -> NSImage {
        let totalSize = NSSize(width: size.width + leftPadding, height: size.height)
        let image = NSImage(size: totalSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setLineWidth(1.3)
        ctx?.setLineCap(.round)
        ctx?.setLineJoin(.round)
        ctx?.setStrokeColor(color.cgColor)

        let sx = size.width / 16
        let sy = size.height / 14
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            // CG origin is bottom-left; our path coords are top-left → flip y.
            // Offset by leftPadding so the glyph sits to the right of the empty padding strip.
            CGPoint(x: leftPadding + x * sx, y: size.height - y * sy)
        }

        let path = CGMutablePath()
        switch type {
        case .parametric:
            path.move(to: pt(2, 8))
            path.addQuadCurve(to: pt(8, 2), control: pt(5, 8))
            path.addQuadCurve(to: pt(14, 8), control: pt(11, 8))
        case .lowShelf:
            path.move(to: pt(2, 4))
            path.addQuadCurve(to: pt(7, 8), control: pt(5, 4))
            path.addLine(to: pt(14, 8))
        case .highShelf:
            path.move(to: pt(2, 8))
            path.addLine(to: pt(7, 8))
            path.addQuadCurve(to: pt(14, 4), control: pt(9, 8))
        case .lowPass:
            path.move(to: pt(2, 6))
            path.addLine(to: pt(8, 6))
            path.addQuadCurve(to: pt(14, 12), control: pt(10, 6))
        case .highPass:
            path.move(to: pt(2, 12))
            path.addQuadCurve(to: pt(6, 6), control: pt(4, 12))
            path.addLine(to: pt(14, 6))
        case .bandPass:
            path.move(to: pt(2, 12))
            path.addQuadCurve(to: pt(7, 4), control: pt(5, 12))
            path.addQuadCurve(to: pt(11, 4), control: pt(9, 4))
            path.addQuadCurve(to: pt(14, 12), control: pt(14, 4))
        case .notch:
            path.move(to: pt(2, 4))
            path.addQuadCurve(to: pt(7, 11), control: pt(6, 4))
            path.addQuadCurve(to: pt(14, 4), control: pt(8, 4))
        }

        ctx?.addPath(path)
        ctx?.strokePath()

        // Non-template — color is baked in so the surrounding NSPopUpButton title stays neutral.
        return image
    }
}
