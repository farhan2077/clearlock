import AppKit
import Testing
@testable import Clearlock

@Suite("Identity and menu bar", .serialized)
struct MenuAndIdentityTests {
    @Test("The bundle ID stays com.farhan2077.clearlock, which Accessibility, settings and updates are keyed to")
    func bundleIdentifierIsProtected() {
        #expect(Bundle.main.bundleIdentifier == "com.farhan2077.clearlock")
    }

    @Test("Settings are stored and backed up under the bundle ID")
    func settingsDomainFollowsBundleID() {
        #expect(SettingsBackup.domain == "com.farhan2077.clearlock")
    }

    @Test("Updates come from farhan2077/clearlock")
    func updateRepository() {
        #expect(Updater.repository(from: Bundle.main.object(forInfoDictionaryKey: "AWLUpdateRepository"))
            == "farhan2077/clearlock")
    }

    @Test("The menu holds only Lock Now, Settings, Check for Updates, About and Quit")
    func menuWhileUnlocked() {
        #expect(StatusItemController.menuEntries(isLocked: false, onboardingActive: false, updateReady: false,
                                                 updatesConfigured: true)
            == [.lockNow, .separator, .settings, .checkForUpdates(enabled: true), .separator, .about, .quit(enabled: true)])
    }

    @Test("While locked, Lock Now becomes Unlock… and Quit is disabled")
    func menuWhileLocked() {
        let entries = StatusItemController.menuEntries(isLocked: true, onboardingActive: false, updateReady: false,
                                                       updatesConfigured: true)
        #expect(entries.first == .unlock)
        #expect(!entries.contains(.lockNow))
        #expect(entries.last == .quit(enabled: false))
    }

    @Test("While the welcome guide is open, the menu offers to finish setup instead of locking")
    func menuDuringOnboarding() {
        let entries = StatusItemController.menuEntries(isLocked: false, onboardingActive: true, updateReady: false,
                                                       updatesConfigured: true)
        #expect(entries.first == .finishSetup)
        #expect(!entries.contains(.lockNow))
    }

    @Test("A downloaded update replaces Check for Updates; without a configured repo it's disabled")
    func menuUpdateItem() {
        let ready = StatusItemController.menuEntries(isLocked: false, onboardingActive: false, updateReady: true,
                                                     updatesConfigured: true)
        #expect(ready.contains(.restartToUpdate))
        #expect(!ready.contains(.checkForUpdates(enabled: true)))
        let unconfigured = StatusItemController.menuEntries(isLocked: false, onboardingActive: false, updateReady: false,
                                                            updatesConfigured: false)
        #expect(unconfigured.contains(.checkForUpdates(enabled: false)))
    }

    @Test("Every state keeps the same short menu: one lock row, Settings, one update row, About, Quit",
          arguments: [false, true], [false, true])
    func menuNeverGrows(isLocked: Bool, updateReady: Bool) {
        let entries = StatusItemController.menuEntries(isLocked: isLocked, onboardingActive: false,
                                                       updateReady: updateReady, updatesConfigured: true)
        #expect(entries.filter { $0 != .separator }.count == 5)
        #expect(entries.contains(.settings) && entries.contains(.about))
    }

    @Test("Clicking the menu bar icon always opens the menu")
    func clickOpensMenu() {
        let controller = StatusItemController(statusBar: NSStatusBar())
        defer { controller.removeFromMenuBar() }
        #expect(controller.opensMenuOnClick)
    }
}
