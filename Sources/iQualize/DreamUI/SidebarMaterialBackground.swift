import AppKit
import SwiftUI

/// The same native vibrant material `.listStyle(.sidebar)` uses for the preset sidebar
/// (`NSVisualEffectView` with `.sidebar` material), so the rest of the window's chrome matches
/// it exactly in both light and dark appearance. A flat `Color(nsColor: .windowBackgroundColor)`
/// fill looks right in light mode but visibly diverges from the vibrant material in dark mode —
/// using the identical native material sidesteps that resolution mismatch entirely.
@available(macOS 14.2, *)
struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Not .active: native sidebars (Finder, Mail, Xcode) dim their vibrancy when the window
        // isn't key. Forcing .active would keep this pane looking "focused" even when the app
        // isn't, mismatching the real sidebar list right next to it.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
