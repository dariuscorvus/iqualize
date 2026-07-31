import SwiftUI

@available(macOS 14.2, *)
struct DreamRootView: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let resolvedScheme: ColorScheme = vm.theme.colorScheme ?? systemScheme
        // Must run synchronously here, not in a .onChange/.onAppear side effect: the window's
        // real NSAppearance drives native materials (traffic lights, the sidebar's vibrant
        // NSVisualEffectView) that don't go through this view's `scheme`/environment at all.
        // A side effect fires one render late — SwiftUI had already resolved this render's
        // scheme-driven (hardcoded RGB) colors against the *new* scheme by the time the side
        // effect landed, so native surfaces lagged a frame behind the SwiftUI-drawn ones (#144).
        let _ = applyWindowAppearance()
        let theme = DreamTheme(scheme: resolvedScheme)

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                EQCanvasView(vm: vm)
                EQReadoutGrid(vm: vm)
            }
            .overlay(alignment: .top)    { theme.line.frame(height: 1) }
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
            .padding(.vertical, 6)
            DreamFooter(vm: vm)
                .padding(.bottom, 14)
        }
        .background(SidebarMaterialBackground())
        .environment(\.dreamTheme, theme)
        .preferredColorScheme(vm.theme.colorScheme)
        .background(
            KeyEventHandler(vm: vm)
        )
    }

    // Force the NSWindow's traffic-light/chrome/system-color appearance to match the
    // chosen theme. Uses the window set directly by DreamHostingView rather than
    // searching NSApp.windows — that search matched any window titled "iQualize ..."
    // (e.g. Help) or with an empty title (e.g. a status-item window), and could
    // silently restyle the wrong one (#144).
    private func applyWindowAppearance() {
        guard let window = vm.window else { return }
        switch vm.theme {
        case .auto:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Keyboard handling

@available(macOS 14.2, *)
private struct KeyEventHandler: NSViewRepresentable {
    let vm: DreamViewModel

    func makeNSView(context: Context) -> KeyEventHandlerView {
        let v = KeyEventHandlerView()
        v.vm = vm
        return v
    }
    func updateNSView(_ nsView: KeyEventHandlerView, context: Context) {
        nsView.vm = vm
    }
}

@available(macOS 14.2, *)
final class KeyEventHandlerView: NSView {
    weak var vm: DreamViewModel?
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if let m = monitor { NSEvent.removeMonitor(m) }
            self.monitor = nil
            return
        }
        if monitor == nil {
            // Backup path — EQWindow.onKeyDown is the primary handler, but the local monitor
            // also picks up events when SwiftUI focus shifts to a child view that would otherwise
            // consume them.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, let vm = self.vm else { return event }
                return MainActor.assumeIsolated { vm.handleKey(event) } ? nil : event
            }
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
