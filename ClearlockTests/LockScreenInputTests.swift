import AppKit
import Carbon.HIToolbox
import Testing
@testable import Clearlock

/// Keyboard behavior of the unlock card and the overlay. The card is built off-screen
/// (fully transparent) and never takes focus from the person running the tests.
@Suite("Lock screen input and look", .serialized)
struct LockScreenInputTests {
    private func makeCard() -> UnlockPanel {
        let card = UnlockPanel(controller: LockController.shared, options: .init(touchIDAvailable: true))
        card.alphaValue = 0
        card.present(on: NSScreen.main ?? NSScreen.screens[0])
        card.orderFrontRegardless()
        return card
    }

    private func close(_ card: UnlockPanel) {
        card.tearDown()
        card.orderOut(nil)
    }

    private func keyDown(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = [],
                         window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test("Typing on the Touch ID card opens the password field and keeps the first keystroke")
    func typingRevealsPasswordAndKeepsKeystroke() {
        let card = makeCard()
        defer { close(card) }
        #expect(!card.isPasswordVisible)

        card.sendEvent(keyDown("a", keyCode: kVK_ANSI_A, window: card))

        #expect(card.isPasswordVisible)
        #expect(card.typedCharacterCount == 1)
    }

    @Test("Escape on an empty password field goes back to Touch ID; with text typed it doesn't")
    func escapeReturnsToTouchID() {
        let card = makeCard()
        defer { close(card) }
        card.sendEvent(keyDown("a", keyCode: kVK_ANSI_A, window: card))
        card.sendEvent(keyDown("\u{1B}", keyCode: kVK_Escape, window: card))
        #expect(card.isPasswordVisible)          // "a" is still typed

        let empty = makeCard()
        defer { close(empty) }
        empty.revealPassword()
        empty.sendEvent(keyDown("\u{1B}", keyCode: kVK_Escape, window: empty))
        #expect(!empty.isPasswordVisible)
    }

    @Test("Letters, digits and Return count as typing a password")
    func typingKeys() {
        #expect(UnlockPanel.startsTyping(keyDown("a", keyCode: kVK_ANSI_A)))
        #expect(UnlockPanel.startsTyping(keyDown("7", keyCode: kVK_ANSI_7)))
        #expect(UnlockPanel.startsTyping(keyDown("A", keyCode: kVK_ANSI_A, modifiers: .shift)))
        #expect(UnlockPanel.startsTyping(keyDown("\r", keyCode: kVK_Return)))
    }

    @Test("Shortcuts, arrows, Tab and Escape don't open the password field")
    func nonTypingKeys() {
        #expect(!UnlockPanel.startsTyping(keyDown("v", keyCode: kVK_ANSI_V, modifiers: .command)))
        #expect(!UnlockPanel.startsTyping(keyDown("a", keyCode: kVK_ANSI_A, modifiers: .control)))
        #expect(!UnlockPanel.startsTyping(keyDown("\u{F702}", keyCode: kVK_LeftArrow)))
        #expect(!UnlockPanel.startsTyping(keyDown("\t", keyCode: kVK_Tab)))
        #expect(!UnlockPanel.startsTyping(keyDown("\u{1B}", keyCode: kVK_Escape)))
    }

    @Test("The overlay always catches clicks, even at 0% dim, and darkens by the chosen amount")
    func overlayDim() throws {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let clear = LockOverlayWindow(screen: screen, dim: 0, passthrough: false)
        let half = LockOverlayWindow(screen: screen, dim: 0.5, passthrough: false)
        let clearAlpha = try #require(clear.contentView?.layer?.backgroundColor?.alpha)
        let halfAlpha = try #require(half.contentView?.layer?.backgroundColor?.alpha)
        #expect(clearAlpha > 0)          // fully transparent pixels would let clicks through
        #expect(clearAlpha < 0.05)       // but it still looks undimmed
        #expect(abs(halfAlpha - 0.5) < 0.001)
    }

    @Test("With agents allowed, the dimming stays out of agents' screenshots")
    func overlayHiddenFromScreenshotsInPassthrough() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        #expect(LockOverlayWindow(screen: screen, dim: 0.5, passthrough: true).sharingType == .none)
        #expect(LockOverlayWindow(screen: screen, dim: 0.5, passthrough: false).sharingType != .none)
    }

    @Test("The overlay never takes keyboard focus away from the card")
    func overlayNeverKey() {
        let overlay = LockOverlayWindow(screen: NSScreen.main ?? NSScreen.screens[0], dim: 0.5, passthrough: false)
        #expect(!overlay.canBecomeKey)
        #expect(!overlay.canBecomeMain)
    }
}
