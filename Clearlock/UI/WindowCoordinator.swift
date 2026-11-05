import AppKit
import SwiftUI

/// Creates SwiftUI windows on demand and releases them when closed, so the app
/// holds no view hierarchy (and almost no memory) while it sits in the menu bar.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()

    enum Kind { case settings, onboarding, diagnostics }

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    /// Whether a window of this kind is open (held by the coordinator).
    func isOpen(_ kind: Kind) -> Bool {
        switch kind {
        case .settings: settingsWindow != nil
        case .onboarding: onboardingWindow != nil
        case .diagnostics: diagnosticsWindow != nil
        }
    }

    /// Takes charge of a new window: it's released when it closes, and whatever it needs
    /// running (permission checks, Diagnostics sampling) runs only while it's open.
    func adopt(_ window: NSWindow, as kind: Kind) {
        window.isReleasedWhenClosed = false
        window.delegate = self
        switch kind {
        case .settings:
            settingsWindow = window
            PermissionCenter.shared.beginWatching()
            LidSleepManager.shared.refreshInstalled()
        case .onboarding:
            onboardingWindow = window
            OnboardingSession.shared.begin()
            PermissionCenter.shared.beginWatching()
        case .diagnostics:
            diagnosticsWindow = window
            ResourceMonitor.shared.start()
        }
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        requestActivation()
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = true
            for pane in SettingsPane.allCases {
                let host = NSHostingController(rootView: SettingsView(pane: pane))
                host.sizingOptions = [.preferredContentSize]
                host.title = pane.title
                let item = NSTabViewItem(viewController: host)
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            sizeToFitAndCenter(window)
            adopt(window, as: .settings)
        }
        if let pane, let tabs = settingsWindow?.contentViewController as? NSTabViewController,
           let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        requestActivation()
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in
                Preferences.shared.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            })
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            sizeToFitAndCenter(window)
            adopt(window, as: .onboarding)
        }
        present(onboardingWindow)
    }

    func showDiagnostics() {
        requestActivation()
        if diagnosticsWindow == nil {
            let host = NSHostingController(rootView: DiagnosticsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Diagnostics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 720))
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.center()
            adopt(window, as: .diagnostics)
        }
        present(diagnosticsWindow)
    }

    func showAbout() {
        requestActivation()
        let credits = NSAttributedString(
            string: "Keeps your Mac awake and locks out everyone but you while your work keeps running.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// SwiftUI sizes the window after it's created, growing it from its bottom-left corner,
    /// so measure the content first or the window ends up off-center.
    private func sizeToFitAndCenter(_ window: NSWindow) {
        if let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0 && size.height > 0 { window.setContentSize(size) }
        }
        // True center of the usable area (between menu bar and Dock) on the active screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        window.setFrameOrigin(Self.centeredOrigin(for: window.frame.size, in: screen.visibleFrame))
    }

    /// True center of an area, not `NSWindow.center()`'s higher placement.
    static func centeredOrigin(for size: NSSize, in area: NSRect) -> NSPoint {
        NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded())
    }

    /// Asks macOS to bring Clearlock forward. Replaceable in tests, which must never take
    /// focus from the person running them.
    var activateApp: () -> Void = { NSApp.activate() }
    var isAppActive: () -> Bool = { NSApp.isActive }

    /// Asks to come forward right away, before a window is built: the first build of a
    /// SwiftUI window is slow, and macOS can turn down a request that comes late after the
    /// click. Turned down, the window used to open behind the frontmost app or unfocused,
    /// so Settings needed a second click the first time.
    func requestActivation() {
        if !isAppActive() { activateApp() }
    }

    /// Shows the window on top whether or not macOS let Clearlock come forward, and asks
    /// once more after it's on screen if it still isn't active.
    func present(_ window: NSWindow?) {
        guard let window else { return }
        if !isAppActive() { activateApp() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible, !self.isAppActive() else { return }
            self.activateApp()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            PermissionCenter.shared.endWatching()
        } else if window === onboardingWindow {
            onboardingWindow = nil
            OnboardingSession.shared.end()
            PermissionCenter.shared.endWatching()
            Preferences.shared.hasCompletedOnboarding = true
        } else if window === diagnosticsWindow {
            diagnosticsWindow = nil
            ResourceMonitor.shared.stop()
        }
        // Drop the hosted SwiftUI hierarchy right away, then hand the freed pages back to
        // the system so the menu bar footprint returns to its idle size.
        DispatchQueue.main.async {
            window.contentViewController = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
        }
    }
}
