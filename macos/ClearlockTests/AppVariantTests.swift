import AppKit
import Testing
@testable import Clearlock

/// Debug builds are Clearlock Dev, a separate app that runs next to the installed release
/// and shares nothing with it. The test host is a Debug build, so it is Clearlock Dev.
@Suite("Clearlock and Clearlock Dev")
struct AppVariantTests {
    @Test("The release keeps its protected bundle ID; Dev has its own")
    func bundleIDs() {
        #expect(AppVariant.release.bundleID == "com.farhan2077.clearlock")
        #expect(AppVariant.dev.bundleID == "com.farhan2077.clearlock.dev")
        #expect(AppVariant(bundleID: "com.farhan2077.clearlock") == .release)
        #expect(AppVariant(bundleID: "com.farhan2077.clearlock.dev") == .dev)
        // Anything else (no bundle, a renamed copy) behaves as the release, never as Dev.
        #expect(AppVariant(bundleID: nil) == .release)
        #expect(AppVariant(bundleID: "com.farhan2077.clearlock.tests") == .release)
    }

    #if DEBUG
    @Test("A Debug build is Clearlock Dev, with settings stored under its own bundle ID")
    func debugBuildIsDev() {
        #expect(Bundle.main.bundleIdentifier == AppVariant.devBundleID)
        #expect(AppVariant.current == .dev)
        #expect(SettingsBackup.domain == AppVariant.devBundleID)
    }
    #endif

    @Test("The running copy uses its own backup file and lid helper")
    func runningCopyUsesItsOwnFiles() {
        #expect(SettingsBackup.fileURL.path.hasSuffix(AppVariant.current.settingsBackupPath))
        #expect(LidSleepManager.rulePath == AppVariant.current.lidHelperPath)
    }

    @Test("Nothing is shared: settings backup, lid helper, name and debug hooks all differ")
    func nothingShared() {
        let release = AppVariant.release, dev = AppVariant.dev
        #expect(release.displayName != dev.displayName)
        #expect(release.settingsBackupPath != dev.settingsBackupPath)
        #expect((release.settingsBackupPath as NSString).deletingLastPathComponent
            != (dev.settingsBackupPath as NSString).deletingLastPathComponent)
        #expect(release.lidHelperPath != dev.lidHelperPath)
        #expect(!release.debugNotificationPrefix.hasPrefix(dev.debugNotificationPrefix))
        #expect(dev.debugNotificationPrefix.hasPrefix(dev.bundleID + "."))
    }

    @Test("The release's paths are unchanged")
    func releaseUnchanged() {
        #expect(AppVariant.release.settingsBackupPath == ".config/clearlock/settings.plist")
        #expect(AppVariant.release.lidHelperPath == "/etc/sudoers.d/clearlock")
        #expect(AppVariant.release.debugNotificationPrefix == "com.farhan2077.clearlock.debug.")
    }

    @Test("Clearlock and Clearlock Dev both lock with ⇧⌘L by default")
    func sameDefaultShortcut() {
        // The test host is Clearlock Dev, so a fresh install here is a fresh Dev install.
        #expect(AppVariant.current == .dev)
        let suite = IsolatedDefaults()
        #expect(Preferences(store: suite.defaults).lockShortcut == .defaultLock)
        #expect(Shortcut.defaultLock.modifierFlags == [.command, .shift])
    }

    @Test("Clearlock Dev never checks for or installs releases")
    func devHasNoUpdates() {
        #expect(Updater.repository(from: "farhan2077/clearlock", variant: .release) == "farhan2077/clearlock")
        #expect(Updater.repository(from: "farhan2077/clearlock", variant: .dev) == nil)
        #if DEBUG
        #expect(!Updater.shared.isConfigured)
        #endif
    }

    @Test("Clearlock Dev's menu bar icon is badged, locked and unlocked; the release's isn't")
    func devIconIsBadged() {
        for icon in [StatusItemController.Icon.unlocked, .locked] {
            let release = StatusItemController.image(for: icon, tint: .systemOrange, variant: .release)
            let dev = StatusItemController.image(for: icon, tint: .systemOrange, variant: .dev)
            #expect(dev.size.width > release.size.width)
            #expect(dev.size.height == release.size.height)
            #expect(dev.isTemplate == release.isTemplate)
        }
        #expect(StatusItemController.image(for: .locked, tint: .systemOrange, variant: .release).size
            == NSSize(width: 30, height: 18))
    }

    @Test("Each copy knows the other, which may run at the same time")
    func otherCopy() {
        #expect(AppVariant.release.other == .dev)
        #expect(AppVariant.dev.other == .release)
    }

    @Test("A copy doesn't lock while the other copy's lock overlay or card is on screen")
    func neverTwoLocksAtOnce() {
        let overlay = NSWindow.Level.screenSaver.rawValue
        #expect(LockController.isLockedByOtherCopy(windowLevels: [0, overlay]))
        #expect(LockController.isLockedByOtherCopy(windowLevels: [overlay + 1]))
        // Not running, or only its menu bar icon, menus and Settings window on screen.
        #expect(!LockController.isLockedByOtherCopy(windowLevels: []))
        #expect(!LockController.isLockedByOtherCopy(windowLevels: [0, NSWindow.Level.statusBar.rawValue,
                                                                   NSWindow.Level.popUpMenu.rawValue]))
    }

    @Test("Repairing a stale permission only ever resets the running copy's own entry")
    func permissionRepairStaysInItsOwnCopy() {
        #expect(PermissionCenter.staleAccessibilityReset(trusted: false, bundleID: AppVariant.devBundleID)
            == ["reset", "Accessibility", AppVariant.devBundleID])
        #expect(!PermissionCenter.formerBundleIDs.contains(AppVariant.releaseBundleID))
        #expect(!PermissionCenter.formerBundleIDs.contains(AppVariant.devBundleID))
    }
}
