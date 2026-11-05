import CoreGraphics
import Testing
@testable import Clearlock

/// The shield's rules: your hands are blocked, agents keep working, and only the unlock
/// card accepts your input.
@Suite("Input shield decisions")
struct InputShieldTests {
    private let card = CGRect(x: 500, y: 300, width: 340, height: 300)
    private let insideCard = CGPoint(x: 600, y: 400)
    private let outsideCard = CGPoint(x: 10, y: 10)

    private func decide(_ type: CGEventType, automation: Bool = false,
                        focused: Bool = false, flags: CGEventFlags = [], keyCode: Int64 = 37,
                        at location: CGPoint = CGPoint(x: 10, y: 10)) -> InputShield.Decision {
        InputShield.decide(type: type, isAutomation: automation, flags: flags, keyCode: keyCode, location: location,
                           context: .init(promptFocused: focused, interactiveRects: [card]))
    }

    @Test("Hardware input comes from the kernel or WindowServer; anything else is automation")
    func classifiesEventSources() {
        #expect(!InputShield.isAutomation(sourcePID: 0, ownPID: 50, windowServerPID: 100))
        #expect(!InputShield.isAutomation(sourcePID: 100, ownPID: 50, windowServerPID: 100))
        #expect(!InputShield.isAutomation(sourcePID: 50, ownPID: 50, windowServerPID: 100))
        #expect(InputShield.isAutomation(sourcePID: 4242, ownPID: 50, windowServerPID: 100))
    }

    @Test("Physical typing is blocked until the unlock card has focus")
    func physicalKeysNeedFocusedCard() {
        #expect(decide(.keyDown) == .block)
        #expect(decide(.keyUp) == .block)
        #expect(decide(.flagsChanged) == .block)
        #expect(decide(.keyDown, focused: true) == .pass)
        #expect(decide(.flagsChanged, focused: true) == .pass)
    }

    @Test("Only the password field's editing shortcuts get through, never app or system shortcuts")
    func shortcutsAreLimitedToEditing() {
        for key: Int64 in [0, 6, 7, 8, 9] { // A Z X C V
            #expect(decide(.keyDown, focused: true, flags: .maskCommand, keyCode: key) == .pass)
        }
        #expect(decide(.keyDown, focused: true, flags: .maskCommand, keyCode: 12) == .block) // ⌘Q
        #expect(decide(.keyDown, focused: true, flags: .maskCommand, keyCode: 48) == .block) // ⌘Tab
        #expect(decide(.keyDown, focused: true, flags: .maskCommand, keyCode: 49) == .block) // ⌘Space
        #expect(decide(.keyDown, focused: true, flags: .maskControl, keyCode: 0) == .block)
    }

    @Test("Physical clicks only reach the unlock card")
    func physicalClicksOnlyInsideCard() {
        for type: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .leftMouseDragged] {
            #expect(decide(type, at: insideCard) == .pass)
            #expect(decide(type, at: outsideCard) == .block)
        }
    }

    @Test("Scrolling and tablet input are always blocked for hands")
    func scrollingIsBlocked() {
        #expect(decide(.scrollWheel, focused: true, at: insideCard) == .block)
        #expect(decide(.tabletPointer, focused: true, at: insideCard) == .block)
    }

    @Test("Agents' clicks, scrolls and typing keep working anywhere")
    func automationPassesThrough() {
        #expect(decide(.leftMouseDown, automation: true, at: outsideCard) == .pass)
        #expect(decide(.scrollWheel, automation: true) == .pass)
        #expect(decide(.keyDown, automation: true, focused: false) == .pass)
    }

    @Test("While the card has focus, agents' keystrokes go to their own app, not the password field")
    func automationKeysAreForwardedWhileCardFocused() {
        #expect(decide(.keyDown, automation: true, focused: true) == .forwardToAgentApp)
        #expect(decide(.keyUp, automation: true, focused: true) == .forwardToAgentApp)
        #expect(decide(.flagsChanged, automation: true, focused: true) == .forwardToAgentApp)
        #expect(decide(.leftMouseDown, automation: true, focused: true, at: outsideCard) == .pass)
    }

    @Test("Agents always keep working: every kind of agent input passes, wherever it lands")
    func agentsAlwaysAllowed() {
        for type: CGEventType in [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .flagsChanged] {
            #expect(decide(type, automation: true, at: outsideCard) == .pass)
            #expect(decide(type, automation: true, at: insideCard) == .pass)
        }
    }
}
