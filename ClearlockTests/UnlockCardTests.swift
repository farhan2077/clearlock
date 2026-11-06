import AppKit
import Testing
@testable import Clearlock

/// The unlock card is built off-screen (fully transparent), so nothing is locked and
/// nothing appears on the user's screen.
@Suite("Unlock card", .serialized)
struct UnlockCardTests {
    private func makeCard(touchID: Bool = true, position: CardPosition = .center) -> UnlockPanel {
        let card = UnlockPanel(controller: LockController.shared,
                               options: .init(touchIDAvailable: touchID, position: position))
        card.alphaValue = 0
        card.present(on: NSScreen.main ?? NSScreen.screens[0])
        card.orderFrontRegardless()
        return card
    }

    private func close(_ card: UnlockPanel) {
        card.tearDown()
        card.orderOut(nil)
    }

    @Test("With Touch ID, the card starts with Touch ID only and no password field")
    func touchIDFirst() {
        let card = makeCard(touchID: true)
        defer { close(card) }
        #expect(!card.isPasswordVisible)
    }

    @Test("Without Touch ID, the password field is there from the start")
    func passwordWithoutTouchID() {
        let card = makeCard(touchID: false)
        defer { close(card) }
        #expect(card.isPasswordVisible)
    }

    @Test("Without Touch ID, a lock symbol takes the fingerprint's place")
    func lockSymbolWithoutTouchID() {
        let withTouchID = makeCard(touchID: true)
        defer { close(withTouchID) }
        let withoutTouchID = makeCard(touchID: false)
        defer { close(withoutTouchID) }
        #expect(!withTouchID.showsLockSymbol)
        #expect(withoutTouchID.showsLockSymbol)
    }

    @Test("The card is a wide pill, centered on the screen, with the fingerprint on its left")
    func pillShapeAndLayout() {
        let card = makeCard()
        defer { close(card) }
        let pill = card.cardScreenFrame
        #expect(pill.size == UnlockPanel.pillSize)
        #expect(pill.width >= pill.height * 3)
        let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
        #expect(abs(pill.midX - screen.midX) <= 1)
        let fingerprint = card.touchIDScreenFrame
        #expect(pill.contains(fingerprint))
        #expect(fingerprint.midX < pill.minX + pill.width * 0.25)
        #expect(abs(fingerprint.midY - pill.midY) <= 1)
    }

    @Test("The title, helper line and password field all fit inside the pill, with or without Touch ID")
    func contentFitsPill() {
        for touchID in [true, false] {
            let card = makeCard(touchID: touchID)
            defer { close(card) }
            let pill = card.cardScreenFrame
            for frame in card.textScreenFrames {
                #expect(frame.width > 0)
                #expect(frame.maxX <= pill.maxX - pill.height / 4)
                #expect(frame.minY >= pill.minY && frame.maxY <= pill.maxY)
            }
        }
    }

    @Test("The pill goes where Settings › Lock › Position says, on the screen it's shown on")
    func cardFollowsPositionSetting() {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
        let topLeft = makeCard(position: .topLeft)
        defer { close(topLeft) }
        let bottomRight = makeCard(position: .bottomRight)
        defer { close(bottomRight) }
        #expect(topLeft.cardScreenFrame.maxX < screen.midX && topLeft.cardScreenFrame.minY > screen.midY)
        #expect(bottomRight.cardScreenFrame.minX > screen.midX && bottomRight.cardScreenFrame.maxY < screen.midY)
        #expect(screen.contains(topLeft.cardScreenFrame) && screen.contains(bottomRight.cardScreenFrame))
    }

    @Test("Opening the password field never resizes or moves the pill, and the fingerprint stays put")
    func passwordFieldKeepsPillStill() {
        let card = makeCard()
        defer { close(card) }
        let pill = card.cardScreenFrame
        let fingerprint = card.touchIDScreenFrame

        card.revealPassword()

        #expect(card.isPasswordVisible)
        #expect(card.cardScreenFrame == pill)
        #expect(card.touchIDScreenFrame == fingerprint)
    }

    @Test("Clicking the pill opens the password field")
    func clickOpensPassword() {
        let card = makeCard()
        defer { close(card) }
        let point = NSPoint(x: UnlockPanel.pillSize.width * 0.65, y: UnlockPanel.pillSize.height / 2)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: card.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // A whole click: the press opens the password field under the pointer, and the field
        // then tracks the mouse until the button is released. Without the release queued, that
        // tracking waits forever (it hung the test on GitHub's runner).
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        card.sendEvent(mouse(.leftMouseDown))
        // Drop the release if nothing tracked it, so it can't reach a later test.
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        #expect(card.isPasswordVisible)
    }

    @Test("The card is always fully shown, with its shadow, and has no hidden state")
    func cardAlwaysShown() {
        let card = makeCard()
        defer { close(card) }
        #expect(card.hasShadow)
        #expect(card.cardOpacity == 1)
    }
    @Test("The card can take keyboard focus without activating the app, so agents' apps stay in front")
    func cardIsNonActivatingAndFocusable() {
        let card = makeCard()
        defer { close(card) }
        #expect(card.canBecomeKey)
        #expect(card.styleMask.contains(.nonactivatingPanel))
    }

    @Test("The card sits above the lock overlay on every display")
    func cardIsAboveOverlay() {
        let card = makeCard()
        defer { close(card) }
        let overlay = LockOverlayWindow(screen: NSScreen.main ?? NSScreen.screens[0], dim: 0.5,
                                        passthrough: true)
        #expect(card.level.rawValue > overlay.level.rawValue)
        #expect(overlay.level == .screenSaver)
        #expect(overlay.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(card.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @Test("With automation allowed, clicks fall through the overlay to the agents' apps")
    func overlayPassthrough() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        #expect(LockOverlayWindow(screen: screen, dim: 0.5, passthrough: true).ignoresMouseEvents)
        #expect(!LockOverlayWindow(screen: screen, dim: 0.5, passthrough: false).ignoresMouseEvents)
    }
}
