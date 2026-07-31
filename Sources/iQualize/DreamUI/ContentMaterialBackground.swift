import AppKit
import SwiftUI

/// The native opaque content-pane material (`NSVisualEffectView` with `.contentBackground` and
/// `.withinWindow` blending) — the same class of background Finder/Mail/Xcode give the pane next
/// to a vibrant `.sidebar`-material sidebar. Content panes are solid, not translucent; only the
/// sidebar itself blurs what's behind the window. A flat `Color(nsColor: .windowBackgroundColor)`
/// fill looks right in light mode but visibly diverges from the sidebar's tone in dark mode —
/// using a real native material sidesteps that resolution mismatch entirely, without making this
/// pane vibrant/see-through the way `.sidebar` material would.
@available(macOS 14.2, *)
struct ContentMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
