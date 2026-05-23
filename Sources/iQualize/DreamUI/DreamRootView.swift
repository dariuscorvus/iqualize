import SwiftUI

@available(macOS 14.2, *)
struct DreamRootView: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let resolvedScheme: ColorScheme = vm.theme.colorScheme ?? systemScheme
        let theme = DreamTheme(scheme: resolvedScheme)

        VStack(spacing: 0) {
            DreamToolbar(vm: vm)
                .padding(.top, 6)
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
        .background(theme.bgWindow)
        .environment(\.dreamTheme, theme)
        .preferredColorScheme(vm.theme.colorScheme)
        .onAppear { applyWindowAppearance(scheme: resolvedScheme) }
        .onChange(of: vm.theme) { _, _ in applyWindowAppearance(scheme: vm.theme.colorScheme ?? systemScheme) }
        .onChange(of: systemScheme) { _, _ in
            if vm.theme == .auto { applyWindowAppearance(scheme: systemScheme) }
        }
        .background(
            KeyEventHandler(vm: vm)
        )
    }

    private func applyWindowAppearance(scheme: ColorScheme) {
        // Force the NSWindow's traffic-light/chrome appearance to match.
        guard let window = NSApp.windows.first(where: { $0.title.isEmpty || $0.title.contains("iQualize") }) else { return }
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
