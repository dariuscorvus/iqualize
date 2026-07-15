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
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // Host the SwiftUI content as the window's `contentViewController` (via
        // `NSHostingController`) rather than a bare `NSHostingView` subview. This gives the
        // `NavigationSplitView` a real window scene, so its sidebar `.searchable` field pins
        // to a native, opaque toolbar area instead of floating over the scrolling headphone
        // list (issue #108). `sceneBridgingOptions` lets SwiftUI own the window's toolbar and
        // title; `.unified` merges that toolbar into the titlebar.
        let hosting = NSHostingController(
            rootView: PresetBrowserView(presetStore: presetStore, onImportOPRA: onImportOPRA)
        )
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = hosting
        window.toolbarStyle = .unified
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
