import AppKit
import Testing
@testable import Clearlock

/// Activation is faked, so the test host never takes focus, and windows sit far off-screen.
@Suite("Opening windows from the menu bar", .serialized)
struct WindowPresentationTests {
    /// Counts activation requests; `grants` decides whether macOS "lets" Clearlock come forward.
    private final class FakeActivation {
        var requests = 0
        var active = false
        var grants = false
    }

    private func makeCoordinator(_ fake: FakeActivation) -> WindowCoordinator {
        let coordinator = WindowCoordinator()
        coordinator.activateApp = {
            fake.requests += 1
            if fake.grants { fake.active = true }
        }
        coordinator.isAppActive = { fake.active }
        return coordinator
    }

    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("A window shows on the first try even when macOS doesn't let Clearlock come forward")
    func showsEvenWhenActivationIsRefused() {
        let fake = FakeActivation()
        let coordinator = makeCoordinator(fake)
        let window = offscreenWindow()
        defer { window.orderOut(nil) }

        coordinator.present(window)

        #expect(window.isVisible)
        #expect(fake.requests >= 1)
    }

    @Test("If Clearlock still isn't in front once the window is up, it asks macOS again")
    func asksAgainAfterShowing() async {
        let fake = FakeActivation()
        let coordinator = makeCoordinator(fake)
        let window = offscreenWindow()
        defer { window.orderOut(nil) }

        coordinator.present(window)
        let deadline = Date().addingTimeInterval(3)
        while fake.requests < 2 && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(fake.requests == 2)
    }

    @Test("Once Clearlock is in front, it never keeps asking")
    func stopsAskingOnceActive() async {
        let fake = FakeActivation()
        fake.grants = true
        let coordinator = makeCoordinator(fake)
        let window = offscreenWindow()
        defer { window.orderOut(nil) }

        coordinator.present(window)
        let until = Date().addingTimeInterval(0.4)
        while Date() < until {
            #expect(fake.requests == 1)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    @Test("Clearlock asks to come forward before building a window, and not when it already is in front")
    func requestsActivationUpFront() {
        let fake = FakeActivation()
        let coordinator = makeCoordinator(fake)
        coordinator.requestActivation()
        #expect(fake.requests == 1)

        fake.active = true
        coordinator.requestActivation()
        #expect(fake.requests == 1)
    }
}
