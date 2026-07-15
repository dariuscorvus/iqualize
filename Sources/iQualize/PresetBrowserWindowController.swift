import AppKit
import SwiftUI

/// Hosts the Preset Browser (see `PresetBrowserView`) in its own resizable window — an OPRA
/// tab plus an iQualize tab for built-in presets the user has hidden — following the same
/// plain-`NSWindowController` + `NSHostingView` bridging pattern as `HelpWindowController` /
/// `DreamHostingView`.
@available(macOS 14.2, *)
@MainActor
final class PresetBrowserWindowController: NSWindowController, NSWindowDelegate {
    init(presetStore: PresetStore, onImportOPRA: @escaping (OPRAProductEntry, OPRACurveEntry) -> Void) {
        let window = HelpAwareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: true
        )
        window.title = "Preset Browser"
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let host = NSHostingView(rootView: PresetBrowserView(presetStore: presetStore, onImportOPRA: onImportOPRA))
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
