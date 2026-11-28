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
        #expect(prefs.pillSize == .regular)
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
        first.pillSize = .tiny
        first.dimLevel = 0.2
        first.tint = .purple
        first.keepAwakeWithLidClosed = true
        first.lidOnlyOnPower = false
        first.autoCheckForUpdates = false
        first.hasCompletedOnboarding = true

        let relaunched = Preferences(store: suite.defaults)
        #expect(relaunched.lockShortcut == custom)
        #expect(relaunched.cardPosition == .bottomRight)
        #expect(relaunched.pillSize == .tiny)
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

    @Test("Every pill size survives a relaunch, and an unknown saved size falls back to Regular",
          arguments: PillSize.allCases)
    func pillSizePersists(size: PillSize) {
        let suite = IsolatedDefaults()
        Preferences(store: suite.defaults).pillSize = size
        #expect(Preferences(store: suite.defaults).pillSize == size)
        suite.defaults.set("enormous", forKey: "pillSize")
        #expect(Preferences(store: suite.defaults).pillSize == .regular)
    }

    @Test("A size picked on Clearlock Dev's temporary picker carries over once, then the old key is gone")
    func legacyPillSizeCarriesOver() {
        let picks: [String: PillSize] = ["slight": .regular, "between": .small, "tiny": .small, "oneLine": .tiny]
        for (old, size) in picks {
            #expect(PillSize.fromLegacy(old) == size)
            let suite = IsolatedDefaults()
            suite.defaults.set(old, forKey: PillSize.legacyDefaultsKey)
            #expect(Preferences(store: suite.defaults).pillSize == size)
            #expect(suite.defaults.object(forKey: PillSize.legacyDefaultsKey) == nil)
            #expect(Preferences(store: suite.defaults).pillSize == size)
        }
        #expect(PillSize.fromLegacy(nil) == nil && PillSize.fromLegacy("nano") == nil)

        // A size already picked in Settings wins over the old pick.
        let suite = IsolatedDefaults()
        suite.defaults.set("small", forKey: "pillSize")
        suite.defaults.set("oneLine", forKey: PillSize.legacyDefaultsKey)
        #expect(Preferences(store: suite.defaults).pillSize == .small)
        #expect(suite.defaults.object(forKey: PillSize.legacyDefaultsKey) == nil)
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
