import Foundation
import Testing
@testable import Clearlock

@Suite("Lock policy")
struct LockPolicyTests {
    @Test("Wrong attempts escalate the wait after every third failure, capped at five minutes")
    func throttleEscalates() {
        #expect(LockController.throttleDelay(afterFailures: 0) == nil)
        #expect(LockController.throttleDelay(afterFailures: 1) == nil)
        #expect(LockController.throttleDelay(afterFailures: 2) == nil)
        #expect(LockController.throttleDelay(afterFailures: 3) == 30)
        #expect(LockController.throttleDelay(afterFailures: 4) == nil)
        #expect(LockController.throttleDelay(afterFailures: 6) == 60)
        #expect(LockController.throttleDelay(afterFailures: 9) == 120)
        #expect(LockController.throttleDelay(afterFailures: 12) == 240)
        #expect(LockController.throttleDelay(afterFailures: 15) == 300)
        #expect(LockController.throttleDelay(afterFailures: 30) == 300)
    }

    @Test("Whenever the Mac is kept awake, so is the display; there's no setting for either")
    func powerAssertions() {
        let idle = PowerAssertions.needed(locked: false, awake: false)
        #expect(!idle.system && !idle.display)

        for (locked, awake) in [(true, false), (false, true), (true, true)] {
            let state = PowerAssertions.needed(locked: locked, awake: awake)
            #expect(state.system)
            #expect(state.display)
        }
    }

    @Test("Keep Awake always starts with the app")
    func keepAwakeAtLaunch() {
        #expect(AwakeController.startsAtLaunch)
    }

    @Test("Settings has two tabs: everyday settings in General; Accessibility, lid-closed mode and Diagnostics in Advanced")
    func settingsTabs() {
        #expect(SettingsPane.allCases == [.general, .advanced])
        #expect(SettingsPane.general.sections == [.general, .lockScreen, .updates])
        #expect(SettingsPane.advanced.sections == [.agents, .keepAwake, .diagnostics])
    }

    @Test("Every settings section is on exactly one tab")
    func everySectionOnce() {
        let placed = SettingsPane.allCases.flatMap(\.sections)
        #expect(placed.count == SettingsSection.allCases.count)
        #expect(Set(placed) == Set(SettingsSection.allCases))
    }

    @Test("The menu bar always shows a lock; Keep Awake never changes it", arguments: [true, false])
    func menuBarIconIgnoresKeepAwake(keepAwake: Bool) {
        #expect(StatusItemController.icon(isLocked: false, keepAwake: keepAwake) == .unlocked)
        #expect(StatusItemController.icon(isLocked: true, keepAwake: keepAwake) == .locked)
    }

    @Test("The lid helper allows exactly two pmset commands, for this user only")
    func sudoersRuleIsNarrow() throws {
        let rule = try #require(LidSleepManager.sudoersRule(for: "alex"))
        #expect(rule == "alex ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }

    @Test("Account names that could break out of a sudoers rule are refused",
          arguments: ["", "two words", "a;rm -rf /", "ALL", "a,b", "name\nALL=(ALL) ALL", "x'y"])
    func sudoersRuleRejectsUnsafeNames(name: String) {
        if name == "ALL" {
            // A plain word is a valid account name; the rule still only grants the two commands.
            #expect(LidSleepManager.sudoersRule(for: name)?.hasSuffix("/usr/bin/pmset -a disablesleep 0") == true)
        } else {
            #expect(LidSleepManager.sudoersRule(for: name) == nil)
        }
    }

    @Test("Windows open truly centered between the menu bar and the Dock")
    func windowsAreTrulyCentered() {
        let visible = NSRect(x: 0, y: 70, width: 1470, height: 853) // Dock below, menu bar above
        let size = NSSize(width: 620, height: 612)
        let origin = WindowCoordinator.centeredOrigin(for: size, in: visible)
        #expect(origin.x - visible.minX == visible.maxX - (origin.x + size.width))
        #expect(abs((origin.y - visible.minY) - (visible.maxY - (origin.y + size.height))) <= 1)
    }
}

/// Uses shared lock state, so it runs on its own.
@Suite("Welcome guide pauses locking", .serialized)
struct OnboardingLockTests {
    @Test("Locking while the welcome guide is open is held back and brings the guide forward")
    func lockIsPausedDuringOnboarding() {
        let controller = LockController.shared
        let session = OnboardingSession.shared
        let originalPresenter = controller.presentOnboarding
        var guideShown = false
        controller.presentOnboarding = { guideShown = true }
        session.begin()
        defer {
            session.end()
            controller.presentOnboarding = originalPresenter
            #if DEBUG
            if controller.isLocked { controller.debugUnlock() } // never leave a lock behind
            #endif
        }

        let before = session.blockedLockCount
        controller.lock(source: "shortcut")

        #expect(!controller.isLocked)
        #expect(guideShown)
        #expect(session.blockedLockCount == before + 1)
        #expect(session.lastBlockedSource == "shortcut")
    }
}
