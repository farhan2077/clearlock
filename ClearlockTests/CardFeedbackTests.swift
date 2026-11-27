import AppKit
import LocalAuthentication
import Testing
@testable import Clearlock

/// Cards are built off-screen (fully transparent); nothing is locked and real Touch ID never runs.
@Suite("Card feedback", .serialized)
struct CardFeedbackTests {
    private func makeCard(touchID: Bool = true) -> UnlockPanel {
        let card = UnlockPanel(controller: LockController.shared, options: .init(touchIDAvailable: touchID))
        card.alphaValue = 0
        card.present(on: NSScreen.main ?? NSScreen.screens[0])
        card.orderFrontRegardless()
        return card
    }

    private func close(_ card: UnlockPanel) {
        card.tearDown()
        card.orderOut(nil)
    }

    @Test("A failed Touch ID shows feedback without moving the pill")
    func failedTouchIDShowsFeedback() {
        let card = makeCard()
        defer { close(card) }
        let pill = card.cardScreenFrame
        #expect(!card.isShowingFeedback)

        card.handleTouchIDError(LAError(.authenticationFailed))

        #expect(card.isShowingFeedback)
        #expect(card.cardScreenFrame == pill)
    }
    private func typeKey(on card: UnlockPanel) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: card.windowNumber, context: nil, characters: "a",
                                     charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        card.sendEvent(event)
    }

    @Test("The open password field closes after a while unused, clears what was typed, and Touch ID shows again")
    func idleFieldCloses() async {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 0.3
        let pill = card.cardScreenFrame
        card.revealPassword()
        typeKey(on: card)
        #expect(card.typedCharacterCount == 1)

        let deadline = Date().addingTimeInterval(5)
        while card.isPasswordVisible && Date() < deadline {
            #expect(card.cardScreenFrame == pill)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isPasswordVisible)
        #expect(card.typedCharacterCount == 0)
    }

    @Test("Typing keeps the password field open; each key press starts the idle wait over")
    func typingKeepsFieldOpen() async {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 1
        card.revealPassword()
        // Typing every 0.1 s for twice the idle wait: the field must stay open at every sample.
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            typeKey(on: card)
            #expect(card.isPasswordVisible)
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(card.isPasswordVisible)
    }

    @Test("Without Touch ID, or after a Touch ID lockout, the password field never closes on its own")
    func fieldStaysWithoutTouchID() async {
        let noTouchID = makeCard(touchID: false)
        defer { close(noTouchID) }
        let lockedOut = makeCard()
        defer { close(lockedOut) }
        lockedOut.handleTouchIDError(LAError(.biometryLockout))
        for card in [noTouchID, lockedOut] {
            card.passwordIdleTimeout = 0.1
            card.revealPassword()
        }
        let end = Date().addingTimeInterval(0.8)
        while Date() < end {
            #expect(noTouchID.isPasswordVisible && lockedOut.isPasswordVisible)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A whole click inside the password field (press and release; a lone press would wait forever).
    private func clickInField(of card: UnlockPanel) {
        let point = NSPoint(x: UnlockPanel.pillSize.width * 0.65, y: UnlockPanel.pillSize.height / 2)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: card.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        card.sendEvent(mouse(.leftMouseDown))
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    }

    @Test("The open field waits 15 s by default before closing")
    func defaultIdleWait() throws {
        #expect(UnlockPanel.defaultPasswordIdleTimeout == 15)
        let card = makeCard()
        defer { close(card) }
        #expect(card.passwordIdleTimeout == UnlockPanel.defaultPasswordIdleTimeout)
        #expect(card.idleDeadline == nil)               // no countdown while only Touch ID shows
        let opened = Date()
        card.revealPassword()
        let deadline = try #require(card.idleDeadline)
        #expect(abs(deadline.timeIntervalSince(opened) - 15) < 1)
    }

    @Test("An idle field closes only with Touch ID, and never while a password is checked or a wait runs")
    func idleCloseDecision() {
        #expect(UnlockPanel.closesWhenIdle(touchIDEnabled: true, isVerifying: false, isWaiting: false))
        #expect(!UnlockPanel.closesWhenIdle(touchIDEnabled: true, isVerifying: true, isWaiting: false))
        #expect(!UnlockPanel.closesWhenIdle(touchIDEnabled: true, isVerifying: false, isWaiting: true))
        #expect(!UnlockPanel.closesWhenIdle(touchIDEnabled: false, isVerifying: false, isWaiting: false))
    }

    @Test("A click inside the open field starts the idle wait over")
    func clickRestartsIdleWait() async throws {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 30
        card.revealPassword()
        let first = try #require(card.idleDeadline)
        try? await Task.sleep(for: .milliseconds(300))
        clickInField(of: card)
        let restarted = try #require(card.idleDeadline)
        #expect(restarted.timeIntervalSince(first) > 0.2)
    }

    @Test("Escape stops the idle wait, and opening the field again starts a fresh one")
    func escapeStopsIdleWait() async throws {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 30
        card.revealPassword()
        let first = try #require(card.idleDeadline)
        card.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: card.windowNumber, context: nil, characters: "\u{1B}",
                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        #expect(!card.isPasswordVisible)
        #expect(card.idleDeadline == nil)

        try? await Task.sleep(for: .milliseconds(300))
        card.revealPassword()
        let fresh = try #require(card.idleDeadline)
        #expect(fresh.timeIntervalSince(first) > 0.2)
    }

    @Test("A wrong password starts the idle wait over and keeps the field open")
    func wrongPasswordRestartsIdleWait() async throws {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 30
        card.revealPassword()
        let first = try #require(card.idleDeadline)
        try? await Task.sleep(for: .milliseconds(300))
        card.handlePasswordResult(.failure)
        #expect(card.isPasswordVisible)
        let restarted = try #require(card.idleDeadline)
        #expect(restarted.timeIntervalSince(first) > 0.2)
    }

    @Test("The field never closes during a wait after wrong attempts, however short the idle wait")
    func neverClosesDuringWait() async {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 0.1
        card.revealPassword()
        card.handlePasswordResult(.throttled(Date().addingTimeInterval(2)))
        #expect(card.isWaitingAfterWrongAttempts)
        let end = Date().addingTimeInterval(1.2)
        while Date() < end {
            #expect(card.isPasswordVisible)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("When a wait after wrong attempts ends, the idle wait starts over")
    func waitEndRestartsIdleWait() async throws {
        let card = makeCard()
        defer { close(card) }
        card.passwordIdleTimeout = 30
        card.revealPassword()
        let first = try #require(card.idleDeadline)
        card.handlePasswordResult(.throttled(Date().addingTimeInterval(0.1)))
        // The wait's countdown ticks once a second, so it ends about a second later.
        let deadline = Date().addingTimeInterval(5)
        while card.isWaitingAfterWrongAttempts && Date() < deadline {
            #expect(card.isPasswordVisible)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isWaitingAfterWrongAttempts)
        let restarted = try #require(card.idleDeadline)
        #expect(restarted.timeIntervalSince(first) > 0.5)
    }

    @Test("Feedback only borrows the title's place briefly, then the title comes back")
    func feedbackGoesAway() async {
        let card = makeCard()
        defer { close(card) }
        card.feedbackDuration = 0.2
        let pill = card.cardScreenFrame
        card.handleTouchIDError(LAError(.authenticationFailed))
        #expect(card.isShowingFeedback)

        let deadline = Date().addingTimeInterval(3)
        while card.isShowingFeedback && Date() < deadline {
            #expect(card.cardScreenFrame == pill)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isShowingFeedback)
    }

    @Test("After a Touch ID lockout, the lock symbol and the password field take over")
    func lockoutSwitchesToPassword() {
        let card = makeCard()
        defer { close(card) }
        #expect(!card.isPasswordVisible)
        card.handleTouchIDError(LAError(.biometryLockout))
        #expect(card.showsLockSymbol)
        #expect(card.isPasswordVisible)
        #expect(card.isShowingFeedback)
    }

    @Test("A cancelled Touch ID (the card lost focus) changes nothing on the card")
    func cancelledTouchIDIsQuiet() {
        let card = makeCard()
        defer { close(card) }
        card.handleTouchIDError(LAError(.systemCancel))
        #expect(!card.isShowingFeedback)
        #expect(!card.isPasswordVisible)
    }
}
