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
