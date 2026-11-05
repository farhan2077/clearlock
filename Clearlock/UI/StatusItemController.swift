import AppKit

/// The menu bar extra. Unlocked: an open lock, with or without Keep Awake. Locked: a white
/// lock on a capsule in the chosen tint, so the state is visible at a glance.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()

    /// Tests pass a status bar of their own, so nothing appears in the real menu bar.
    init(statusBar: NSStatusBar = .system) {
        item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        Self.attach(menu, to: item)
        observeChanges { [weak self] in self?.refreshButton() }
    }

    /// Clicking the icon always opens the menu: the menu is attached and the button has
    /// no action of its own.
    static func attach(_ menu: NSMenu, to item: NSStatusItem) {
        item.menu = menu
        item.behavior = []
        item.button?.action = nil
        item.button?.target = nil
    }

    /// For tests: what a click on the icon does.
    var opensMenuOnClick: Bool { item.menu === menu && item.button?.action == nil }

    func removeFromMenuBar() { item.statusBar?.removeStatusItem(item) }

    #if DEBUG
    /// Where the menu bar icon is on screen, so a debug hook can click it like a person.
    var debugButtonScreenFrame: NSRect? { item.button?.window?.frame }
    private(set) var debugMenuOpens = 0
    private(set) var debugMenuCloses = 0
    func menuWillOpen(_ menu: NSMenu) { debugMenuOpens += 1; DebugTrace.note("menu will open") }

    /// Opens the real menu the way a click does, then, while it's open, closes it and
    /// chooses the item with this title, the order AppKit uses for a real selection.
    func debugChooseFromMenu(_ title: String) {
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = Optional(self.menu), let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
                menu.cancelTracking()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.menu.performActionForItem(at: index) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        item.button?.performClick(nil)
    }
    func menuDidClose(_ menu: NSMenu) { debugMenuCloses += 1; DebugTrace.note("menu did close") }
    #endif

    // MARK: Icon

    private func refreshButton() {
        let lock = LockController.shared
        let awake = AwakeController.shared
        let prefs = Preferences.shared
        guard let button = item.button else { return }

        switch Self.icon(isLocked: lock.isLocked, keepAwake: awake.isActive) {
        case .locked:
            button.image = Self.lockedImage(tint: prefs.tint.color)
            button.setAccessibilityLabel("Clearlock, locked")
            button.toolTip = "Clearlock: Locked"
        case .unlocked:
            button.image = Self.symbol("lock.open")
            // Keep Awake doesn't change the icon; it's still spoken and shown in the tooltip.
            button.setAccessibilityLabel(awake.isActive ? "Clearlock, keeping awake" : "Clearlock")
            button.toolTip = awake.isActive
                ? "Keeping awake"
                : "Clearlock"
        }
    }

    enum Icon: Equatable { case unlocked, locked }

    /// The menu bar always shows a lock: open while unlocked, a tinted pill while locked.
    /// Keep Awake never changes it.
    static func icon(isLocked: Bool, keepAwake: Bool) -> Icon {
        isLocked ? .locked : .unlocked
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func lockedImage(tint: NSColor) -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = lock.size
                lock.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Menu

    /// One row of the menu. The menu only ever holds these.
    enum MenuEntry: Equatable {
        case lockNow, unlock, finishSetup, settings, checkForUpdates(enabled: Bool), restartToUpdate, about
        case quit(enabled: Bool)
        case separator
    }

    /// The menu, top to bottom: Lock Now (Unlock… while locked, Finish Setup while the welcome
    /// guide is open), Settings…, Check for Updates… (Restart to Update once one is downloaded),
    /// About and Quit. Quit is disabled while locked. No Keep Awake, no Diagnostics.
    static func menuEntries(isLocked: Bool, onboardingActive: Bool, updateReady: Bool,
                            updatesConfigured: Bool) -> [MenuEntry] {
        let first: MenuEntry = isLocked ? .unlock : onboardingActive ? .finishSetup : .lockNow
        return [first, .separator, .settings,
                updateReady ? .restartToUpdate : .checkForUpdates(enabled: updatesConfigured),
                .separator, .about, .quit(enabled: !isLocked)]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let updater = Updater.shared
        var readyRelease: String?
        if case .ready(let release, _) = updater.state { readyRelease = release.version }
        let entries = Self.menuEntries(isLocked: LockController.shared.isLocked,
                                       onboardingActive: OnboardingSession.shared.isActive,
                                       updateReady: readyRelease != nil, updatesConfigured: updater.isConfigured)
        for entry in entries {
            switch entry {
            case .unlock:
                menu.addItem(action("Unlock…", "lock.open") { LockController.shared.focusPrompt() })
            case .finishSetup:
                menu.addItem(action("Finish Setup to Lock…", "lock.fill") { WindowCoordinator.shared.showOnboarding() })
            case .lockNow:
                let lockItem = action("Lock Now", "lock.fill") { LockController.shared.lock(source: "menu") }
                apply(Preferences.shared.lockShortcut, to: lockItem)
                menu.addItem(lockItem)
            case .settings:
                let settings = action("Settings…", "gearshape") { WindowCoordinator.shared.showSettings() }
                settings.keyEquivalent = ","
                menu.addItem(settings)
            case .restartToUpdate:
                menu.addItem(action("Restart to Update to \(readyRelease ?? "")", "arrow.down.circle") { Updater.shared.installAndRelaunch() })
            case .checkForUpdates(let enabled):
                let update = action("Check for Updates…", nil) { Task { await Updater.shared.checkInteractively() } }
                update.isEnabled = enabled
                menu.addItem(update)
            case .about:
                menu.addItem(action("About Clearlock", nil) { WindowCoordinator.shared.showAbout() })
            case .quit(let enabled):
                let quit = action("Quit Clearlock", nil) { NSApp.terminate(nil) }
                quit.keyEquivalent = "q"
                quit.isEnabled = enabled
                menu.addItem(quit)
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    private func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        guard let shortcut, !shortcut.menuKeyEquivalent.isEmpty else { return }
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private func action(_ title: String, _ symbol: String?, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target // menu items hold their target weakly
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
