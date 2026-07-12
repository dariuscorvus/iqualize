import AppKit
import SwiftUI

/// Hosts the OPRA Preset Browser (see `PresetBrowserView`) in its own resizable window,
/// following the same plain-`NSWindowController` + `NSHostingView` bridging pattern as
/// `HelpWindowController` / `DreamHostingView`.
@available(macOS 14.2, *)
@MainActor
final class PresetBrowserWindowController: NSWindowController, NSWindowDelegate {
    init(onImport: @escaping (OPRAProductEntry, OPRACurveEntry) -> Void) {
        let window = HelpAwareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: true
        )
        window.title = "Browse OPRA Presets"
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let host = NSHostingView(rootView: PresetBrowserView(onImport: onImport))
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
