import AppKit

/// A preset row rendered as a custom NSMenuItem view so ⌥-click-to-favorite can keep
/// the menu open — a plain title/action NSMenuItem always closes the menu on any click,
/// with no way to distinguish "favorite" from "select" without closing either way.
/// Shared by MenuBarController (status-item dropdown) and PresetPickerButton (in-app
/// toolbar) so both surfaces render and behave identically from one source of truth.
final class PresetRowView: NSView {
    var presetID: UUID!
    var onSelect: (() -> Void)?
    var onToggleFavorite: (() -> Void)?

    weak var labelView: NSTextField?
    weak var checkmarkView: NSImageView?
    weak var starView: NSImageView?

    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            let tint: NSColor? = isHighlighted ? .white : nil
            labelView?.textColor = isHighlighted ? .white : .labelColor
            checkmarkView?.contentTintColor = tint
            starView?.contentTintColor = tint
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onToggleFavorite?()
        } else {
            onSelect?()
        }
    }
}

@MainActor
enum PresetMenuBuilder {
    static func makeRowItem(
        for preset: EQPresetData,
        isActive: Bool,
        isFavorite: Bool,
        onSelect: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Bool
    ) -> NSMenuItem {
        let item = NSMenuItem()
        // Where the checkmark sits, measured from the row's leading edge — matches the
        // ~14pt left margin plain NSMenuItems use, so header rows and preset rows line up.
        let checkmarkLeading: CGFloat = 14

        // Initial frame only seeds a starting size. AppKit resizes a custom NSMenuItem
        // view's frame to the menu's computed width, but only applies that resize if the
        // view's autoresizingMask allows flexible width — without it the row stays stuck
        // at its intrinsic size, leaving a highlight/star that fall short of the real edge.
        // The Auto Layout constraints below then keep the star pinned to that resized
        // trailing edge and the label filling the space in between.
        let row = PresetRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        row.autoresizingMask = [.width, .height]
        row.presetID = preset.id
        row.onSelect = onSelect
        row.onToggleFavorite = { [weak row] in
            let isFavoriteNow = onToggleFavorite()
            (row?.viewWithTag(1) as? NSImageView)?.alphaValue = isFavoriteNow ? 1 : 0
        }

        let checkmark = NSImageView()
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmark.image?.isTemplate = true
        checkmark.alphaValue = isActive ? 1 : 0
        row.addSubview(checkmark)
        row.checkmarkView = checkmark

        let label = NSTextField(labelWithString: preset.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.drawsBackground = false
        row.addSubview(label)
        row.labelView = label

        let star = NSImageView()
        star.translatesAutoresizingMaskIntoConstraints = false
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorited")
        star.image?.isTemplate = true
        star.alphaValue = isFavorite ? 1 : 0
        star.tag = 1
        row.addSubview(star)
        row.starView = star

        NSLayoutConstraint.activate([
            checkmark.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: checkmarkLeading),
            checkmark.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            star.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            star.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 14),
            star.heightAnchor.constraint(equalToConstant: 16),
        ])

        item.view = row
        return item
    }

    /// Appends a "Favorites" header + rows + a trailing separator — only if `presets` is non-empty.
    static func addFavorites(
        to menu: NSMenu,
        presets: [EQPresetData],
        activePresetID: UUID,
        onSelect: @escaping (UUID) -> Void,
        onToggleFavorite: @escaping (UUID) -> Bool
    ) {
        guard !presets.isEmpty else { return }
        let favoritesHeader = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        favoritesHeader.isEnabled = false
        menu.addItem(favoritesHeader)
        for preset in presets {
            menu.addItem(makeRowItem(
                for: preset, isActive: preset.id == activePresetID, isFavorite: true,
                onSelect: { onSelect(preset.id) }, onToggleFavorite: { onToggleFavorite(preset.id) }
            ))
        }
        menu.addItem(.separator())
    }

    /// Appends a "Built-in" header + rows, an optional "Custom" header + rows, then a
    /// trailing separator and a hint row explaining ⌥-click.
    static func addPresetSections(
        to menu: NSMenu,
        builtIn: [EQPresetData],
        custom: [EQPresetData],
        favoriteIDs: Set<UUID>,
        activePresetID: UUID,
        onSelect: @escaping (UUID) -> Void,
        onToggleFavorite: @escaping (UUID) -> Bool
    ) {
        let builtInHeader = NSMenuItem(title: "Built-in", action: nil, keyEquivalent: "")
        builtInHeader.isEnabled = false
        menu.addItem(builtInHeader)
        for preset in builtIn {
            menu.addItem(makeRowItem(
                for: preset, isActive: preset.id == activePresetID, isFavorite: favoriteIDs.contains(preset.id),
                onSelect: { onSelect(preset.id) }, onToggleFavorite: { onToggleFavorite(preset.id) }
            ))
        }

        if !custom.isEmpty {
            menu.addItem(.separator())
            let customHeader = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
            customHeader.isEnabled = false
            menu.addItem(customHeader)
            for preset in custom {
                menu.addItem(makeRowItem(
                    for: preset, isActive: preset.id == activePresetID, isFavorite: favoriteIDs.contains(preset.id),
                    onSelect: { onSelect(preset.id) }, onToggleFavorite: { onToggleFavorite(preset.id) }
                ))
            }
        }

        menu.addItem(.separator())
        let favoriteHint = NSMenuItem(title: "⌥-click a preset to favorite/unfavorite", action: nil, keyEquivalent: "")
        favoriteHint.isEnabled = false
        menu.addItem(favoriteHint)
    }
}
