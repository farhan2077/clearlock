import AppKit
import Testing
@testable import Clearlock

@Suite("Settings defaults and persistence")
struct PreferencesTests {
    @Test("A fresh install uses the agreed defaults")
    func freshInstallDefaults() {
        let suite = IsolatedDefaults()
        let prefs = Preferences(store: suite.defaults)

        #expect(prefs.lockShortcut == .defaultLock)
        #expect(prefs.cardPosition == .center)
        #expect(prefs.dimLevel == 0.3)
        #expect(!prefs.keepAwakeWithLidClosed)
        #expect(prefs.lidOnlyOnPower)
        #expect(prefs.autoCheckForUpdates)
        #expect(prefs.tint == .orange)
        #expect(!prefs.hasCompletedOnboarding)
    }

    @Test("Every setting survives a relaunch")
    func settingsPersistAcrossLaunches() {
        let suite = IsolatedDefaults()
        let first = Preferences(store: suite.defaults)
        let custom = Shortcut(keyCode: 40, modifiers: [.control, .option], key: "K")
        first.lockShortcut = custom
        first.cardPosition = .bottomRight
        first.dimLevel = 0.2
        first.tint = .purple
        first.keepAwakeWithLidClosed = true
        first.lidOnlyOnPower = false
        first.autoCheckForUpdates = false
        first.hasCompletedOnboarding = true

        let relaunched = Preferences(store: suite.defaults)
        #expect(relaunched.lockShortcut == custom)
        #expect(relaunched.cardPosition == .bottomRight)
        #expect(relaunched.dimLevel == 0.2)
        #expect(relaunched.tint == .purple)
        #expect(relaunched.keepAwakeWithLidClosed)
        #expect(!relaunched.lidOnlyOnPower)
        #expect(!relaunched.autoCheckForUpdates)
        #expect(relaunched.hasCompletedOnboarding)
    }

    @Test("An unknown saved card position falls back to the center")
    func unknownCardPositionIsCenter() {
        let suite = IsolatedDefaults()
        suite.defaults.set("upsideDown", forKey: "cardPosition")
        #expect(Preferences(store: suite.defaults).cardPosition == .center)
    }

    @Test("A cleared lock shortcut stays cleared instead of reverting to the default")
    func clearedShortcutStaysCleared() {
        let suite = IsolatedDefaults()
        Preferences(store: suite.defaults).lockShortcut = nil
        #expect(Preferences(store: suite.defaults).lockShortcut == nil)
    }

    @Test("Out-of-range dim levels are clamped so the screen never goes fully black")
    func dimLevelIsClamped() {
        let suite = IsolatedDefaults()
        suite.defaults.set(1.0, forKey: "dimLevel")
        #expect(Preferences(store: suite.defaults).dimLevel == 0.9)
        suite.defaults.set(-0.5, forKey: "dimLevel")
        #expect(Preferences(store: suite.defaults).dimLevel == 0)
    }
}
