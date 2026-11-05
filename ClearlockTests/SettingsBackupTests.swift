import Foundation
import Testing
@testable import Clearlock

@Suite("Settings survive uninstalling and reinstalling")
struct SettingsBackupTests {
    @Test("Settings removed by an uninstaller come back from the backup")
    func restoresAfterCleanerUninstall() {
        let file = TemporaryFile()
        let installed = IsolatedDefaults()
        let prefs = Preferences(store: installed.defaults)
        prefs.tint = .green
        prefs.cardPosition = .topRight
        prefs.hasCompletedOnboarding = true
        SettingsBackup.save(defaults: installed.defaults, domain: installed.name, file: file.url)

        // A reinstall after a cleaner app: the settings domain is empty again.
        let reinstalled = IsolatedDefaults()
        let restored = SettingsBackup.restoreIfNeeded(defaults: reinstalled.defaults, domain: reinstalled.name, file: file.url)

        #expect(restored)
        let after = Preferences(store: reinstalled.defaults)
        #expect(after.tint == .green)
        #expect(after.cardPosition == .topRight)
        #expect(after.hasCompletedOnboarding)
    }

    @Test("Existing settings are never overwritten by an older backup")
    func doesNotOverwriteExistingSettings() {
        let file = TemporaryFile()
        let old = IsolatedDefaults()
        Preferences(store: old.defaults).tint = .green
        SettingsBackup.save(defaults: old.defaults, domain: old.name, file: file.url)

        let current = IsolatedDefaults()
        Preferences(store: current.defaults).tint = .blue
        let restored = SettingsBackup.restoreIfNeeded(defaults: current.defaults, domain: current.name, file: file.url)

        #expect(!restored)
        #expect(Preferences(store: current.defaults).tint == .blue)
    }

    @Test("Without a backup a fresh install simply starts with defaults")
    func freshInstallWithoutBackup() {
        let file = TemporaryFile()
        let fresh = IsolatedDefaults()
        #expect(!SettingsBackup.restoreIfNeeded(defaults: fresh.defaults, domain: fresh.name, file: file.url))
        #expect(fresh.stored.isEmpty)
    }

    @Test("Empty settings never replace an existing backup")
    func emptySettingsDoNotClobberBackup() throws {
        let file = TemporaryFile()
        let installed = IsolatedDefaults()
        Preferences(store: installed.defaults).tint = .pink
        SettingsBackup.save(defaults: installed.defaults, domain: installed.name, file: file.url)

        let empty = IsolatedDefaults()
        SettingsBackup.save(defaults: empty.defaults, domain: empty.name, file: file.url)

        let check = IsolatedDefaults()
        #expect(SettingsBackup.restoreIfNeeded(defaults: check.defaults, domain: check.name, file: file.url))
        #expect(Preferences(store: check.defaults).tint == .pink)
    }
}
