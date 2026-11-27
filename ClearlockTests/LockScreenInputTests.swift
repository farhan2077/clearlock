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

    @Test("Typing on the Touch ID card never opens the password field, so stray keys can't use up attempts")
    func typingNeverRevealsPassword() {
        let card = makeCard()
        defer { close(card) }
        #expect(!card.isPasswordVisible)

        let keys: [(String, Int, NSEvent.ModifierFlags)] = [
            ("a", kVK_ANSI_A, []), ("7", kVK_ANSI_7, []), ("A", kVK_ANSI_A, .shift), (" ", kVK_Space, []),
            ("\r", kVK_Return, []), ("\u{3}", kVK_ANSI_KeypadEnter, []), ("\t", kVK_Tab, []),
            ("\u{F702}", kVK_LeftArrow, []), ("v", kVK_ANSI_V, .command),
        ]
        for (characters, keyCode, modifiers) in keys {
            card.sendEvent(keyDown(characters, keyCode: keyCode, modifiers: modifiers, window: card))
            #expect(!card.isPasswordVisible)
        }
        #expect(card.typedCharacterCount == 0)
    }

    @Test("Once the password field is open, typing goes into it")
    func typingAfterOpening() {
        let card = makeCard()
        defer { close(card) }
        card.revealPassword()
        card.sendEvent(keyDown("a", keyCode: kVK_ANSI_A, window: card))
        #expect(card.typedCharacterCount == 1)
    }

    @Test("Escape on an empty password field goes back to Touch ID; with text typed it doesn't")
    func escapeReturnsToTouchID() {
        let card = makeCard()
        defer { close(card) }
        card.revealPassword()
        card.sendEvent(keyDown("a", keyCode: kVK_ANSI_A, window: card))
        card.sendEvent(keyDown("\u{1B}", keyCode: kVK_Escape, window: card))
        #expect(card.isPasswordVisible)          // "a" is still typed

        let empty = makeCard()
        defer { close(empty) }
        empty.revealPassword()
        empty.sendEvent(keyDown("\u{1B}", keyCode: kVK_Escape, window: empty))
        #expect(!empty.isPasswordVisible)
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
