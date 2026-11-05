import AppKit
import Testing
@testable import Clearlock

/// Windows here are never shown on screen; they're created, adopted and closed off-screen.
@Suite("Nothing runs while idle", .serialized)
struct IdleResourceTests {
    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = NSView()
        return window
    }

    @Test("At rest, nothing polls permissions and Diagnostics samples nothing")
    func idleHasNoTimers() {
        #expect(!PermissionCenter.shared.isPolling)
        #expect(!ResourceMonitor.shared.isSampling)
    }

    @Test("Permission checks run only while Settings is open, and the window is freed when it closes")
    func settingsWindowLifecycle() async {
        let coordinator = WindowCoordinator()
        let window = offscreenWindow()
        coordinator.adopt(window, as: .settings)
        #expect(coordinator.isOpen(.settings))
        #expect(PermissionCenter.shared.isPolling)

        window.close()
        #expect(!coordinator.isOpen(.settings))
        #expect(!PermissionCenter.shared.isPolling)

        let deadline = Date().addingTimeInterval(3)
        while window.contentViewController != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(window.contentViewController == nil)
    }

    @Test("Diagnostics samples only while its window is open, and the window is freed when it closes")
    func diagnosticsWindowLifecycle() async {
        let coordinator = WindowCoordinator()
        let window = offscreenWindow()
        coordinator.adopt(window, as: .diagnostics)
        #expect(coordinator.isOpen(.diagnostics))
        #expect(ResourceMonitor.shared.isSampling)

        window.close()
        #expect(!coordinator.isOpen(.diagnostics))
        #expect(!ResourceMonitor.shared.isSampling)

        let deadline = Date().addingTimeInterval(3)
        while window.contentViewController != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(window.contentViewController == nil)
    }

    @Test("Permission checks keep running until the last window that needs them closes")
    func pollingCountsWindows() {
        let center = PermissionCenter.shared
        center.beginWatching()
        center.beginWatching()
        defer { for _ in 0..<4 where center.isPolling { center.endWatching() } }
        center.endWatching()
        #expect(center.isPolling)
        center.endWatching()
        #expect(!center.isPolling)
        center.endWatching() // an extra close never leaves it in a bad state
        center.beginWatching()
        #expect(center.isPolling)
        center.endWatching()
        #expect(!center.isPolling)
    }
}
