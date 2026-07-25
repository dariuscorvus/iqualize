import AppKit
import SwiftUI

@available(macOS 14.2, *)
@MainActor
enum DreamHostingView {
    /// Build an `EQWindow` configured with the SwiftUI Dream UI as its content view.
    static func makeWindow(viewModel: DreamViewModel) -> EQWindow {
        // Default size matches the smallest comfortable layout for the toolbar + 10-band readouts.
        // Min is just below that so you can still nudge tighter; the band cells stretch to fill
        // whatever width is available. If the preset sidebar (issue #104) was left open last
        // launch, both grow by its width up front so the canvas doesn't open pre-squeezed —
        // toggling it at runtime instead resizes the live window (see `DreamRootView`).
        let sidebarExtra: CGFloat = viewModel.presetSidebarVisible ? PresetSidebarView.width : 0
        let window = EQWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880 + sidebarExtra, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iQualize"
        window.titleVisibility = .visible
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820 + sidebarExtra, height: 560)

        // Wire window's UndoManager into the view model
        viewModel.undoManager = window.undoManager

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

        return window
    }
}
