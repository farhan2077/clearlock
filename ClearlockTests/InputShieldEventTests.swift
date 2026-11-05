import CoreGraphics
import Foundation
import Testing
@testable import Clearlock

/// Real input events through the shield's handler. The event tap itself is never
/// started, so nothing is blocked on the machine running the tests.
@Suite("Input shield with real events", .serialized)
struct InputShieldEventTests {
    private let agentPID: Int64 = 4242
    private let card = CGRect(x: 500, y: 300, width: 340, height: 300)

    private func key(down: Bool = true, from pid: Int64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        return event
    }

    private func click(at point: CGPoint, from pid: Int64) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        return event
    }

    private func makeShield(focused: Bool = false) -> InputShield {
        let shield = InputShield()
        shield.isPromptFocused = { focused }
        shield.interactiveRects = [card]
        shield.automationKeyTarget = { nil }
        return shield
    }

    /// Counters are batched and published about a second later; wait for them.
    private func settledCounters(_ shield: InputShield, until done: (InputShield.Counters) -> Bool) async -> InputShield.Counters {
        let deadline = Date().addingTimeInterval(3)
        while !done(shield.counters) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return shield.counters
    }

    @Test("A physical key press while the card isn't focused is blocked and brings up the card")
    func physicalPressSummonsCard() async {
        let shield = makeShield()
        var summoned = 0
        shield.onBlockedPhysicalPress = { summoned += 1 }

        #expect(!shield.shouldPass(.keyDown, key(from: 0)))
        #expect(!shield.shouldPass(.keyUp, key(down: false, from: 0)))
        #expect(summoned == 1) // the press, not the release

        let counters = await settledCounters(shield) { $0.blockedPhysical == 2 }
        #expect(counters.blockedPhysical == 2)
        #expect(counters.allowedPhysical == 0)
    }

    @Test("A physical click on the card reaches it; anywhere else it's blocked")
    func physicalClickOnCard() async {
        let shield = makeShield()
        #expect(shield.shouldPass(.leftMouseDown, click(at: CGPoint(x: 600, y: 400), from: 0)))
        #expect(!shield.shouldPass(.leftMouseDown, click(at: CGPoint(x: 5, y: 5), from: 0)))

        let counters = await settledCounters(shield) { $0.allowedPhysical == 1 && $0.blockedPhysical == 1 }
        #expect(counters.allowedPhysical == 1)
        #expect(counters.blockedPhysical == 1)
    }

    @Test("An agent's click goes through and is credited to the agent's process")
    func agentClickIsCountedBySource() async {
        let shield = makeShield()
        #expect(shield.shouldPass(.leftMouseDown, click(at: CGPoint(x: 5, y: 5), from: agentPID)))

        let counters = await settledCounters(shield) { $0.allowedAutomation == 1 }
        #expect(counters.allowedAutomation == 1)
        #expect(counters.automationSources[pid_t(agentPID)] == 1)
    }

    @Test("An agent's keystroke never lands in the password field, even with no app to forward it to")
    func agentKeystrokeNeverReachesCard() async {
        let shield = makeShield(focused: true)
        #expect(!shield.shouldPass(.keyDown, key(from: agentPID)))

        let counters = await settledCounters(shield) { $0.blockedAutomation == 1 }
        #expect(counters.blockedAutomation == 1)
    }

    @Test("Agents' input never brings up the card")
    func agentPressesDoNotSummonCard() {
        let shield = makeShield()
        var summoned = 0
        shield.onBlockedPhysicalPress = { summoned += 1 }
        #expect(shield.shouldPass(.keyDown, key(from: agentPID)))
        #expect(shield.shouldPass(.leftMouseDown, click(at: CGPoint(x: 5, y: 5), from: agentPID)))
        #expect(summoned == 0)
    }
    @Test("Keystrokes the shield re-posted to an agent's app pass straight through")
    func forwardedKeystrokesPass() {
        let shield = makeShield()
        let forwarded = key(from: 0)
        forwarded.setIntegerValueField(.eventSourceUserData, value: InputShield.forwardedMarker)
        #expect(shield.shouldPass(.keyDown, forwarded))
    }

    @Test("Both a blocked key press and a blocked click bring the card's focus back")
    func blockedPressesSummonCard() {
        let shield = makeShield()
        var summoned = 0
        shield.onBlockedPhysicalPress = { summoned += 1 }
        _ = shield.shouldPass(.keyDown, key(from: 0))
        _ = shield.shouldPass(.leftMouseDown, click(at: CGPoint(x: 5, y: 5), from: 0))
        #expect(summoned == 2)
    }
    @Test("A shield that isn't running blocks nothing on this Mac")
    func notRunningUntilStarted() {
        #expect(!InputShield().isRunning)
    }
}
