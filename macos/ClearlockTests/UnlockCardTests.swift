import AppKit
import LocalAuthentication
import Testing
@testable import Clearlock

/// The unlock card is built off-screen (fully transparent), so nothing is locked and
/// nothing appears on the user's screen.
@Suite("Unlock card", .serialized)
struct UnlockCardTests {
    private func makeCard(touchID: Bool = true, position: CardPosition = .center,
                          size: PillSize = .defaultSize) -> UnlockPanel {
        let card = UnlockPanel(controller: LockController.shared,
                               options: .init(touchIDAvailable: touchID, position: position, size: size))
        card.alphaValue = 0
        card.present(on: NSScreen.main ?? NSScreen.screens[0])
        card.orderFrontRegardless()
        return card
    }

    private func close(_ card: UnlockPanel) {
        card.tearDown()
        card.orderOut(nil)
    }

    @Test("A physical click anywhere on the pill gets through the shield at every size, measured the way locking does it: before the pill is shown",
          arguments: PillSize.allCases)
    func shieldLetsClicksOnThePillThrough(size: PillSize) throws {
        // Locking places the pill and hands its area to the shield before the pill is on screen.
        let card = UnlockPanel(controller: LockController.shared, options: .init(touchIDAvailable: true, size: size))
        defer { close(card) }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        card.present(on: screen)
        let primary = try #require(NSScreen.screens.first)
        let pill = card.cardScreenFrame
        #expect(pill.size == size.metrics.size)

        let rect = LockController.eventRect(fromScreenFrame: pill, primaryScreenMaxY: primary.frame.maxY)
        let context = InputShield.Context(promptFocused: true, interactiveRects: [rect])
        let windowFrame = card.frame
        // The text, the fingerprint and the empty glass at the right end, in event-tap coordinates.
        for fraction in [0.65, 0.1, 0.92] {
            let point = CGPoint(x: windowFrame.minX + windowFrame.width * fraction,
                                y: primary.frame.maxY - windowFrame.midY)
            #expect(InputShield.decide(type: .leftMouseDown, isAutomation: false, flags: [], keyCode: 0,
                                       location: point, context: context) == .pass)
        }
    }

    @Test("Every pill size being tried is a pill of exactly that size, fingerprint on the left, everything fitting",
          arguments: PillSize.allCases)
    func everyPillSizeFits(size: PillSize) {
        for touchID in [true, false] {
            let card = makeCard(touchID: touchID, size: size)
            defer { close(card) }
            let pill = card.cardScreenFrame
            #expect(pill.size == size.metrics.size)
            #expect(pill.width >= pill.height * 3)
            let fingerprint = card.touchIDScreenFrame
            #expect(pill.contains(fingerprint))
            #expect(fingerprint.midX < pill.minX + pill.width * 0.25)
            #expect(abs(fingerprint.midY - pill.midY) <= 1)
            for frame in card.textScreenFrames {
                #expect(frame.width > 0)
                #expect(frame.maxX <= pill.maxX - pill.height / 4)
                #expect(frame.minY >= pill.minY && frame.maxY <= pill.maxY)
            }
        }
    }

    @Test("At every pill size, opening the password field never moves the pill or the fingerprint",
          arguments: PillSize.allCases)
    func everyPillSizeStaysPut(size: PillSize) {
        let card = makeCard(size: size)
        defer { close(card) }
        let pill = card.cardScreenFrame, fingerprint = card.touchIDScreenFrame
        card.revealPassword()
        #expect(card.isPasswordVisible)
        #expect(card.cardScreenFrame == pill)
        #expect(card.touchIDScreenFrame == fingerprint)
    }

    @Test("Pill sizes go from largest to smallest, Regular is the default, and only Tiny is one line")
    func pillSizesOrder() {
        let sizes = PillSize.allCases.map(\.metrics.size)
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) {
            #expect(larger.width > smaller.width && larger.height > smaller.height)
        }
        #expect(PillSize.allCases == [.regular, .small, .tiny])
        #expect(PillSize.defaultSize == .regular)
        #expect(UnlockPanel.pillSize == PillSize.regular.metrics.size)
        #expect(UnlockPanel.pillSize == NSSize(width: 330, height: 64))
        #expect(PillSize.allCases.filter(\.metrics.oneLine) == [.tiny])
    }

    @Test("A one-line pill swaps its title for the password field in place, and Escape brings the title back")
    func oneLineSwapsTitle() {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        let pill = card.cardScreenFrame, fingerprint = card.touchIDScreenFrame
        #expect(card.showsTitle && !card.isPasswordVisible)
        card.revealPassword()
        #expect(card.isPasswordVisible && !card.showsTitle)
        #expect(card.cardScreenFrame == pill && card.touchIDScreenFrame == fingerprint)
        card.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: card.windowNumber, context: nil, characters: "\u{1B}",
                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        #expect(card.showsTitle && !card.isPasswordVisible)
    }

    @Test("Without Touch ID, a one-line pill shows the password field from the start")
    func oneLineWithoutTouchID() {
        let card = makeCard(touchID: false, size: .tiny)
        defer { close(card) }
        #expect(card.isPasswordVisible && !card.showsTitle)
    }

    @Test("On a one-line pill, feedback shows inside the open field, and on the title while the field is closed")
    func oneLineFeedback() {
        let open = makeCard(size: .tiny)
        defer { close(open) }
        open.revealPassword()
        open.handlePasswordResult(.failure)
        #expect(open.isShowingFeedback && open.isFeedbackInField)
        #expect(open.isPasswordVisible && !open.showsTitle)

        let closed = makeCard(size: .tiny)
        defer { close(closed) }
        closed.handleTouchIDError(LAError(.authenticationFailed))
        #expect(closed.isShowingFeedback && !closed.isFeedbackInField && closed.showsTitle)

        // Closing the field takes feedback in it away, so it can't show up the next time it opens.
        open.revealPassword()
        open.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: open.windowNumber, context: nil, characters: "\u{1B}",
                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        #expect(!open.isFeedbackInField)
    }

    @Test("The one-line pill leaves no empty glass after its text, with the title or the password field showing")
    func oneLineHasNoGap() {
        for touchID in [true, false] {
            let card = makeCard(touchID: touchID, size: .tiny)
            defer { close(card) }
            let pill = card.cardScreenFrame
            let end = pill.maxX - PillSize.tiny.metrics.rightInset
            let title = card.textScreenFrames[0]
            if card.showsTitle { #expect(abs(title.maxX - end) <= 1.5) }
            card.revealPassword()
            let field = card.textScreenFrames[1]
            #expect(abs(field.maxX - end) <= 1.5)
            #expect(abs(field.minX - title.minX) <= 1)       // the field starts where the title did
        }
    }

    @Test("Every piece of feedback fits where it's shown, at every pill size, at its longest")
    func feedbackFits() {
        for size in PillSize.allCases {
            let card = makeCard(size: size)
            defer { close(card) }
            card.revealPassword()
            // One-line pills show feedback on the title or inside the empty field; the others on the title.
            for inField in size.metrics.oneLine ? [false, true] : [false] {
                for feedback in UnlockPanel.Feedback.longest {
                    #expect(card.feedbackWidth(feedback, inField: inField) <= card.feedbackSpace(inField: inField),
                            "\(size) \(feedback) inField=\(inField)")
                }
            }
        }
    }

    private func escape(_ card: UnlockPanel) {
        card.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: card.windowNumber, context: nil, characters: "\u{1B}",
                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
    }

    @Test("Hovering the Tiny pill swaps the title for a hint, and leaving brings the title back, with nothing moving")
    func tinyHoverHint() {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        let pill = card.cardScreenFrame, fingerprint = card.touchIDScreenFrame
        #expect(!card.showsHoverHint)
        card.pointerEntered()
        #expect(card.showsHoverHint && card.showsTitle && !card.isPasswordVisible)
        #expect(card.cardScreenFrame == pill && card.touchIDScreenFrame == fingerprint)
        card.pointerExited()
        #expect(!card.showsHoverHint && card.showsTitle)
        #expect(card.cardScreenFrame == pill && card.touchIDScreenFrame == fingerprint)
    }

    @Test("Hovering never opens the password field or lets typing in; a double-click still does, and the hint goes")
    func hoverNeverOpensField() {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        card.pointerEntered()
        card.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: card.windowNumber, context: nil, characters: "a",
                                        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
        #expect(!card.isPasswordVisible && card.typedCharacterCount == 0)

        let point = NSPoint(x: card.frame.width * 0.65, y: card.frame.height / 2)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: card.windowNumber, context: nil, eventNumber: 0, clickCount: 2,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        card.sendEvent(mouse(.leftMouseDown))
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        #expect(card.isPasswordVisible && !card.showsHoverHint)
    }

    @Test("Closing the field while the pointer is still over Tiny brings the hint back, not the title")
    func escapeWhileHovering() {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        card.revealPassword()
        card.pointerEntered()
        #expect(!card.showsHoverHint)                  // no hint while the field is open
        escape(card)
        #expect(!card.isPasswordVisible && card.showsHoverHint)
    }

    @Test("Feedback wins over the hint, and the hint comes back when the feedback ends while still hovering")
    func feedbackOverHint() async {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        card.feedbackDuration = 0.2
        card.pointerEntered()
        card.handleTouchIDError(LAError(.authenticationFailed))
        #expect(card.isShowingFeedback && !card.showsHoverHint)
        let deadline = Date().addingTimeInterval(3)
        while card.isShowingFeedback && Date() < deadline {
            #expect(!card.showsHoverHint)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isShowingFeedback && card.showsHoverHint)
    }

    @Test("The system's own enter and exit events reach the hint, through a tracking area covering the whole pill")
    func realHoverEvents() throws {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        let area = try #require(card.hoverTrackingAreas.first { $0.owner === card })
        #expect(area.options.contains(.inVisibleRect))     // follows the pill's bounds, whatever its size
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: NSPoint(x: 40, y: 18), modifierFlags: [], timestamp: 0,
                                   windowNumber: card.windowNumber, context: nil, eventNumber: 0,
                                   trackingNumber: 0, userData: nil)!
        }
        card.mouseEntered(with: event(.mouseEntered))
        #expect(card.showsHoverHint)
        card.mouseExited(with: event(.mouseExited))
        #expect(!card.showsHoverHint)
    }

    @Test("After a Touch ID lockout, Tiny opens the field and shows the message inside it")
    func tinyLockoutFeedback() {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        card.handleTouchIDError(LAError(.biometryLockout))
        #expect(card.isPasswordVisible && !card.showsTitle)
        #expect(card.isShowingFeedback && card.isFeedbackInField)
        #expect(card.showsLockSymbol)
    }

    @Test("During a wait after wrong attempts, Tiny shows the countdown inside the field until the wait ends")
    func tinyWaitFeedback() async {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        card.passwordIdleTimeout = 30
        card.revealPassword()
        card.handlePasswordResult(.throttled(Date().addingTimeInterval(0.1)))
        #expect(card.isWaitingAfterWrongAttempts)
        #expect(card.isShowingFeedback && card.isFeedbackInField && card.isPasswordVisible)
        let deadline = Date().addingTimeInterval(5)
        while card.isWaitingAfterWrongAttempts && Date() < deadline {
            #expect(card.isFeedbackInField && !card.showsTitle)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isWaitingAfterWrongAttempts && !card.isFeedbackInField && card.isPasswordVisible)
    }

    @Test("Only Tiny tracks the pointer and shows a hint; the larger sizes have their helper line instead")
    func hoverOnlyOnTiny() {
        for size in PillSize.allCases {
            let card = makeCard(size: size)
            defer { close(card) }
            card.pointerEntered()
            #expect(card.showsHoverHint == size.metrics.oneLine)
            let tracking = card.hoverTrackingAreas.filter { $0.owner === card }
            #expect(tracking.isEmpty == !size.metrics.oneLine)
        }
    }

    @Test("Tiny tracks the pointer even while Clearlock isn't the active app, and the hint fits the title's space")
    func hoverWorksInactiveAndFits() throws {
        let card = makeCard(size: .tiny)
        defer { close(card) }
        let area = try #require(card.hoverTrackingAreas.first { $0.owner === card })
        #expect(area.options.contains(.activeAlways) && area.options.contains(.mouseEnteredAndExited))
        #expect(card.hoverHintWidth <= card.feedbackSpace(inField: false))
    }

    @Test("Pills with a helper line never put feedback in the field")
    func feedbackOnTitleWithHelperLine() {
        for size in PillSize.allCases where !size.metrics.oneLine {
            let card = makeCard(size: size)
            defer { close(card) }
            card.revealPassword()
            card.handlePasswordResult(.failure)
            #expect(card.isShowingFeedback && !card.isFeedbackInField && card.showsTitle)
        }
    }

    @Test("A lock's pill uses the size and position from Settings", arguments: PillSize.allCases)
    func lockUsesSettings(size: PillSize) {
        let suite = IsolatedDefaults()
        let prefs = Preferences(store: suite.defaults)
        prefs.pillSize = size
        prefs.cardPosition = .bottomLeft
        let options = UnlockPanel.Options.from(prefs, touchIDAvailable: true)
        #expect(options.size == size && options.position == .bottomLeft)

        let card = UnlockPanel(controller: LockController.shared, options: options)
        defer { close(card) }
        card.alphaValue = 0
        let screen = NSScreen.main ?? NSScreen.screens[0]
        card.present(on: screen)
        card.orderFrontRegardless()
        let pill = card.cardScreenFrame
        #expect(pill.size == size.metrics.size)
        #expect(pill.minX == screen.frame.minX + UnlockPanel.edgeMargin)
        #expect(pill.minY == screen.frame.minY + UnlockPanel.edgeMargin)
    }

    @Test("A lock with untouched settings gets the default size and position")
    func lockUsesDefaults() {
        let suite = IsolatedDefaults()
        let options = UnlockPanel.Options.from(Preferences(store: suite.defaults), touchIDAvailable: true)
        #expect(options.size == .regular && options.position == .center)
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

    @Test("A single click on the pill leaves Touch ID showing; a double-click opens the password field")
    func doubleClickOpensPassword() {
        let card = makeCard()
        defer { close(card) }
        let point = NSPoint(x: UnlockPanel.pillSize.width * 0.65, y: UnlockPanel.pillSize.height / 2)
        func mouse(_ type: NSEvent.EventType, clickCount: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: card.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // A whole click: a press that opens the password field lands in it, and the field then
        // tracks the mouse until the button is released. Without the release queued, that
        // tracking waits forever (it hung the test on GitHub's runner).
        func click(_ clickCount: Int) {
            NSApp.postEvent(mouse(.leftMouseUp, clickCount: clickCount), atStart: false)
            card.sendEvent(mouse(.leftMouseDown, clickCount: clickCount))
            // Drop the release if nothing tracked it, so it can't reach a later test.
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        }

        click(1)
        #expect(!card.isPasswordVisible)
        click(2)
        #expect(card.isPasswordVisible)
    }

    @Test("Only a double-click (or more) counts as asking for the password field")
    func clickCounts() {
        #expect(!UnlockPanel.opensPassword(clickCount: 1))
        #expect(UnlockPanel.opensPassword(clickCount: 2))
        #expect(UnlockPanel.opensPassword(clickCount: 3))
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
