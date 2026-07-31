import AppKit
import SwiftUI

@available(macOS 14.2, *)
@MainActor
enum DreamHostingView {
    /// Build an `EQWindow` configured with the SwiftUI Dream UI as its content view, along with
    /// the `NSToolbar` delegate that drives the window's native title-bar toolbar. The caller
    /// must retain the returned controller for the lifetime of the window — `NSToolbar` only
    /// holds its delegate weakly.
    static func makeWindow(viewModel: DreamViewModel) -> (window: EQWindow, toolbarController: DreamToolbarController) {
        // Default size matches the smallest comfortable layout for the toolbar + 10-band readouts.
        // Min is just below that so you can still nudge tighter; the band cells stretch to fill
        // whatever width is available.
        let window = EQWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "iQualize"
        // Hidden, not just empty: with a visible title, AppKit reserves space for it before the
        // leading toolbar items, pushing the sidebar toggle in from the true left edge. Hiding it
        // lets the toolbar start flush against the traffic lights, matching Xcode/Notes/Mail.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // .fullSizeContentView + transparent titlebar let the sidebar's material extend up behind
        // the traffic lights/toolbar, Safari-style, instead of stopping at an opaque toolbar strip.
        window.titlebarAppearsTransparent = true
        // Match the raw NSWindow background (visible behind the sidebar's translucent material)
        // to the standard system color — otherwise it defaults to plain white/light and shows as
        // a mismatched seam once the sidebar's vibrancy exposes it.
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)

        // Wire window's UndoManager into the view model
        viewModel.undoManager = window.undoManager
        viewModel.window = window

        let host = NSHostingView(rootView: DreamRootView(vm: viewModel))
        let sidebarHost = NSHostingView(rootView: PresetSidebarView(vm: viewModel))
        let splitVC = DreamSplitViewController(sidebarView: sidebarHost, contentView: host)
        window.contentViewController = splitVC
        // Installing contentViewController re-sizes the window to the split view's fitting
        // size, which collapses to contentItem.minimumThickness (820) with the sidebar
        // collapsed — overriding the 880pt default set above. Reassert it.
        window.setContentSize(NSSize(width: 880, height: 600))
        window.center()

        // The toolbar controller needs the split view to build a tracking-separator item —
        // built after the split VC so the sidebar-toggle button hugs the sidebar's right edge
        // (Safari/Mail convention) instead of sitting in the fixed leading toolbar group.
        let toolbarController = DreamToolbarController(vm: viewModel, splitView: splitVC.splitView)
        let toolbar = NSToolbar(identifier: "DreamToolbar")
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        return (window, toolbarController)
    }
}
