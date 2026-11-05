import AppKit
import Testing
@testable import Clearlock

@Suite("Card focus and failed-attempt report")
struct LockFocusAndReportTests {
    typealias Controller = LockController

    @Test("While locked, a card that lost focus always gets it back, in every mode",
          arguments: [Controller.Mode.standard, .passthrough], [false, true])
    func lockedCardTakesFocusBack(mode: Controller.Mode, appIsActive: Bool) {
        let first = Controller.focusAction(isLocked: true, cardIsKey: false, appIsActive: appIsActive, mode: mode,
                                           isRetry: false)
        let retry = Controller.focusAction(isLocked: true, cardIsKey: false, appIsActive: appIsActive, mode: mode,
                                           isRetry: true)
        #expect(first != .none)
        #expect(retry != .none)
    }

    @Test("With agents allowed, the card first takes focus without activating Clearlock, so the agents' app stays in front")
    func passthroughKeepsAgentsAppFrontmost() {
        #expect(Controller.focusAction(isLocked: true, cardIsKey: false, appIsActive: false, mode: .passthrough,
                                       isRetry: false) == .makeKey)
        #expect(Controller.focusAction(isLocked: true, cardIsKey: false, appIsActive: false, mode: .passthrough,
                                       isRetry: true) == .activateAndMakeKey)
    }

    @Test("Without agents allowed, Clearlock stays the active app while locked")
    func standardKeepsClearlockActive() {
        #expect(Controller.focusAction(isLocked: true, cardIsKey: true, appIsActive: false, mode: .standard,
                                       isRetry: false) == .activateAndMakeKey)
        #expect(Controller.focusAction(isLocked: true, cardIsKey: true, appIsActive: true, mode: .standard,
                                       isRetry: false) == .none)
    }

    @Test("Focus is never touched while unlocked", arguments: [Controller.Mode.standard, .passthrough])
    func unlockedNeverTakesFocus(mode: Controller.Mode) {
        for key in [false, true] {
            for retry in [false, true] {
                #expect(Controller.focusAction(isLocked: false, cardIsKey: key, appIsActive: false, mode: mode,
                                               isRetry: retry) == .none)
            }
        }
    }

    @Test("Focus is taken back quickly, never left with something else")
    func refocusIsQuick() {
        #expect(Controller.refocusDelay > 0 && Controller.refocusDelay <= 0.5)
    }

    private func session(failures: Int) -> Controller.Session {
        let start = Date(timeIntervalSince1970: 1_000)
        return Controller.Session(start: start, end: start.addingTimeInterval(600), unlockMethod: "Touch ID",
                                  failedAttempts: (0..<failures).map { start.addingTimeInterval(Double($0) * 10) },
                                  blockedInputs: 0, allowedAutomation: 0)
    }

    @Test("Failed attempts made while locked are reported after unlocking; a clean unlock reports nothing")
    func failedAttemptsReported() {
        #expect(!Controller.reportsFailures(session(failures: 0)))
        #expect(Controller.reportsFailures(session(failures: 1)))
        #expect(Controller.reportsFailures(session(failures: 7)))
    }

    @Test("A failed Touch ID while unlocked is never counted against the next lock")
    func touchIDFailureWhileUnlockedIgnored() {
        let controller = Controller.shared
        guard !controller.isLocked else { return }
        let before = controller.failedAttempts.count
        controller.touchIDFailed()
        #expect(controller.failedAttempts.count == before)
        #expect(controller.throttledUntil == nil || before > 0)
    }

}
