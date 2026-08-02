import AppKit
import Foundation
import ServiceManagement

@available(macOS 14.2, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var menuBarController: MenuBarController!
    private var audioEngine: AudioEngine!
    private var presetStore: PresetStore!
    private var cliControlServer: CLIControlServer!
    private var terminationInProgress = false
    var isRealQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No explicit permission preflight here — AudioHardwareCreateProcessTap
        // (in AudioEngine.start()) triggers its own audio-only TCC prompt via
        // NSAudioCaptureUsageDescription, scoped to system audio capture rather
        // than the combined Screen & System Audio Recording permission.
        setupMainMenu()

        audioEngine = AudioEngine()
        presetStore = PresetStore()
        menuBarController = MenuBarController(audioEngine: audioEngine, presetStore: presetStore)

        cliControlServer = CLIControlServer(handler: menuBarController)
        cliControlServer.start()

        // Sync login item state (user may have changed it in System Settings)
        var launchState = iQualizeState.load()
        let systemEnabled = SMAppService.mainApp.status == .enabled
        if launchState.startAtLogin != systemEnabled {
            launchState.startAtLogin = systemEnabled
            launchState.save()
        }

        // Sleep/wake handling
        // System shutdown/restart — allow real termination
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isRealQuit = true
            }
        }

        // Sleep/wake handling
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSleep()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRealQuit {
            guard !terminationInProgress else { return .terminateNow }
            terminationInProgress = true
            Task { @MainActor [weak self] in
                await self?.audioEngine.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // Dock quit: hide to menu bar instead of terminating
        // Only close titled windows (EQ, Settings) — not internal status item windows
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        var state = iQualizeState.load()
        state.hideFromDock = true
        state.windowOpen = false
        state.save()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController?.openEQWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cliControlServer.stop()
        audioEngine.requestShutdown()
    }

    @objc func realQuit(_ sender: Any?) {
        isRealQuit = true
        NSApp.terminate(nil)
    }

    @objc func openSettings(_ sender: Any?) {
        menuBarController?.showSettings()
    }

    @objc func toggleBypass(_ sender: Any?) {
        menuBarController?.toggleBypassFromMenu()
    }

    @objc func openHelp(_ sender: Any?) {
        menuBarController?.openHelp(sender)
    }

    @objc func showAbout(_ sender: Any?) {
        menuBarController?.showAbout(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleBypass(_:)) {
            menuItem.state = audioEngine?.bypassed == true ? .on : .off
        }
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iQualize", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit iQualize", action: #selector(realQuit(_:)), keyEquivalent: "q")
        quitItem.target = NSApp.delegate as? AppDelegate
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (Undo/Redo)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Controls menu (Bypass EQ)
        let controlsMenuItem = NSMenuItem()
        let controlsMenu = NSMenu(title: "Controls")
        let bypassItem = NSMenuItem(title: "Bypass EQ", action: #selector(toggleBypass(_:)), keyEquivalent: "b")
        bypassItem.target = self
        controlsMenu.addItem(bypassItem)
        controlsMenuItem.submenu = controlsMenu
        mainMenu.addItem(controlsMenuItem)

        // Window menu — standard macOS pattern. NSApp.windowsMenu auto-appends
        // the names of open titled windows below the standard items.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeItem = windowMenu.addItem(withTitle: "Close Window",
                                            action: #selector(NSWindow.performClose(_:)),
                                            keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        let minimizeItem = windowMenu.addItem(withTitle: "Minimize",
                                               action: #selector(NSWindow.miniaturize(_:)),
                                               keyEquivalent: "m")
        minimizeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu — standard macOS pattern. Not registered as NSApp.helpMenu so
        // macOS doesn't add the Help search popover (we ship our own help window).
        // Cmd+? itself is handled by ShortcutAwareWindow.performKeyEquivalent so the
        // shortcut works regardless of activation policy.
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpEntry = NSMenuItem(title: "iQualize Help",
                                    action: #selector(openHelp(_:)),
                                    keyEquivalent: "?")
        helpEntry.keyEquivalentModifierMask = [.command]
        helpEntry.target = self
        helpMenu.addItem(helpEntry)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func handleSleep() {
        Task { @MainActor [weak self] in
            await self?.audioEngine.handleSleep()
        }
    }

    private func handleWake() {
        Task { @MainActor [weak self] in
            await self?.audioEngine.handleWake()
        }
    }
}

// MARK: - Entry Point

@main
struct iQualizeMain {
    // Strong reference — NSApplication.delegate is weak, so without this
    // Swift can deallocate the AppDelegate (and the entire menu bar icon).
    nonisolated(unsafe) static var appDelegate: AnyObject?

    static func main() {
        if #available(macOS 14.2, *) {
            let app = NSApplication.shared
            let launchState = iQualizeState.load()
            app.setActivationPolicy(launchState.hideFromDock ? .accessory : .regular)
            let delegate = AppDelegate()
            appDelegate = delegate
            app.delegate = delegate
            app.run()
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let alert = NSAlert()
            alert.messageText = "iQualize requires macOS 14.2 or newer"
            alert.informativeText = "Core Audio Taps are only available on macOS 14.2+."
            alert.runModal()
        }
    }
}
