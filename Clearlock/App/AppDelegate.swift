import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if restoredSettings { SettingsBackup.restoreLoginItem() }
        SettingsBackup.startMirroring()
        LidSleepManager.shared.restoreAfterUnexpectedExit()
        NSApp.mainMenu = Self.makeMainMenu()
        statusItem = StatusItemController()
        PermissionCenter.shared.start()
        Self.registerHotKeys()
        observePreferences()
        Updater.shared.scheduleBackgroundChecks()
        ActivityLog.shared.add("power", "Clearlock started")
        if AwakeController.startsAtLaunch { AwakeController.shared.start() }

        if !Preferences.shared.hasCompletedOnboarding {
            WindowCoordinator.shared.showOnboarding()
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    /// The same About window as the menu bar's About item, with the credits and links.
    @objc func showAbout(_ sender: Any?) {
        WindowCoordinator.shared.showAbout()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nobody, including a script or agent, can quit Clearlock to get past the lock.
        Self.terminateReply(isLocked: LockController.shared.isLocked)
    }

    static func terminateReply(isLocked: Bool) -> NSApplication.TerminateReply {
        isLocked ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        LidSleepManager.shared.release()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (e.g. from Finder) shows Settings, since there's no Dock icon.
        if !flag { WindowCoordinator.shared.showSettings() }
        return true
    }

    static func registerHotKeys() {
        let prefs = Preferences.shared
        HotKeyCenter.shared.register(.lock, shortcut: prefs.lockShortcut) {
            LockController.shared.toggle(source: "shortcut")
        }
    }

    private func observePreferences() {
        let prefs = Preferences.shared
        observeChanges {
            _ = prefs.lockShortcut
            DispatchQueue.main.async { MainActor.assumeIsolated { Self.registerHotKeys() } }
        }
    }

    /// Accessory apps have no visible menu bar, but the key equivalents still matter:
    /// without an Edit menu, ⌘V and friends don't work in text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clearlock", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clearlock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Clearlock", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        return main
    }

    #if DEBUG
    /// Development-only remote control, so a lock can be tested and released from
    /// Terminal or over SSH: see scripts/debug-lock.sh.
    private func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.lock"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockController.shared.lock(source: "debug") }
        }
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.unlock"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockController.shared.debugUnlock() }
        }
        // Builds an invisible unlock pill, opens the password field and records whether the
        // pill or the fingerprint moved. Nothing is locked.
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.cardtest"), object: nil, queue: .main) { note in
            let path = note.object as? String ?? NSTemporaryDirectory() + "clearlock-cardtest.txt"
            MainActor.assumeIsolated {
                let card = UnlockPanel(controller: LockController.shared)
                card.alphaValue = 0
                card.present(on: NSScreen.main ?? NSScreen.screens[0])
                card.orderFrontRegardless()
                let before = (card.cardScreenFrame, card.touchIDScreenFrame)
                card.debugShowPassword()
                let after = (card.cardScreenFrame, card.touchIDScreenFrame)
                let report = "pill \(before.0) → \(after.0)\nfingerprint \(before.1) → \(after.1)\npassword visible: \(card.isPasswordVisible)"
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
                card.tearDown()
                card.orderOut(nil)
            }
        }
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.status"), object: nil, queue: .main) { note in
            let path = note.object as? String ?? NSTemporaryDirectory() + "clearlock-status.txt"
            MainActor.assumeIsolated {
                try? LockController.shared.debugStatus.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // Renders every visible window into PNGs in the given folder, for layout review.
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.snapshot"), object: nil, queue: .main) { note in
            let folder = note.object as? String ?? NSTemporaryDirectory()
            MainActor.assumeIsolated {
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = "\(index)-\(type(of: window))-\(Int(view.bounds.width))x\(Int(view.bounds.height)).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
                }
            }
        }
        center.addObserver(forName: Notification.Name("com.farhan2077.clearlock.debug.window"), object: nil, queue: .main) { note in
            let target = note.object as? String
            MainActor.assumeIsolated {
                switch target {
                case "settings": WindowCoordinator.shared.showSettings()
                case let name? where name.hasPrefix("settings-"):
                    WindowCoordinator.shared.showSettings(SettingsPane.allCases.first { "settings-\($0.title.lowercased())" == name })
                case "diagnostics": WindowCoordinator.shared.showDiagnostics()
                case "about": WindowCoordinator.shared.showAbout()
                case "password": LockController.shared.debugShowPassword()
                case "close": NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.performClose(nil) }
                default: WindowCoordinator.shared.showOnboarding()
                }
            }
        }
    }
    #endif
}
