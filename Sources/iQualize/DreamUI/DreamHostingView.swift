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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iQualize"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)

        let toolbarController = DreamToolbarController(vm: viewModel)
        let toolbar = NSToolbar(identifier: "DreamToolbar")
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // Wire window's UndoManager into the view model
        viewModel.undoManager = window.undoManager
        viewModel.window = window

        let host = NSHostingView(rootView: DreamRootView(vm: viewModel))
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

        return (window, toolbarController)
    }
}
