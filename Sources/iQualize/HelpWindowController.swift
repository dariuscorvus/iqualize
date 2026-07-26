import AppKit
import WebKit

/// Routes Cmd+Shift+? to the in-app Help window. Each app window subclass calls
/// this from `performKeyEquivalent` so the shortcut works regardless of activation
/// policy (accessory mode has no OS menu bar to fire menu shortcuts).
@available(macOS 14.2, *)
@MainActor
enum HelpShortcut {
    static func handles(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "?" else { return false }
        (NSApp.delegate as? AppDelegate)?.openHelp(nil)
        return true
    }
}

/// Routes Cmd+W to close the receiving window — same accessory-mode reasoning
/// as `HelpShortcut`, since Close normally lives on a File menu this app
/// doesn't show (#129).
@available(macOS 14.2, *)
@MainActor
enum CloseShortcut {
    static func handles(_ event: NSEvent, for window: NSWindow) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
              event.charactersIgnoringModifiers == "w" else { return false }
        window.performClose(nil)
        return true
    }
}

/// NSWindow subclass that catches the app-wide shortcuts (Cmd+?, Cmd+W) —
/// base class for every titled window in the app.
@available(macOS 14.2, *)
@MainActor
class ShortcutAwareWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if HelpShortcut.handles(event) { return true }
        if CloseShortcut.handles(event, for: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@available(macOS 14.2, *)
@MainActor
final class HelpWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    init() {
        let window = ShortcutAwareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: true
        )
        window.title = "iQualize Help"
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let webView = WKWebView()
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        webView.loadHTMLString(HelpRenderer.featuresHTML(), baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
