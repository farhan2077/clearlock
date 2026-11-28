import AppKit

/// Which copy of Clearlock is running. Debug builds are **Clearlock Dev**: a separate app
/// with its own bundle ID, so it runs next to the installed release and shares nothing
/// with it: settings, their backup, Accessibility permission, Open at Login, the lid
/// helper and the lock shortcut are all its own.
///
/// The variant follows the bundle ID, which the build configuration sets
/// (`PRODUCT_BUNDLE_IDENTIFIER`: Release is `com.farhan2077.clearlock`, Debug `….dev`).
enum AppVariant: Equatable {
    case release, dev

    /// Protected: Accessibility, settings, Open at Login and updates are keyed to it.
    static let releaseBundleID = "com.farhan2077.clearlock"
    static let devBundleID = "com.farhan2077.clearlock.dev"

    static let current = AppVariant(bundleID: Bundle.main.bundleIdentifier)

    init(bundleID: String?) {
        self = bundleID == Self.devBundleID ? .dev : .release
    }

    var bundleID: String {
        switch self {
        case .release: Self.releaseBundleID
        case .dev: Self.devBundleID
        }
    }

    var displayName: String {
        switch self {
        case .release: "Clearlock"
        case .dev: "Clearlock Dev"
        }
    }

    /// The settings backup, relative to the home folder.
    var settingsBackupPath: String {
        switch self {
        case .release: ".config/clearlock/settings.plist"
        case .dev: ".config/clearlock-dev/settings.plist"
        }
    }

    /// The lid-closed helper's sudoers rule. Each copy installs and uses its own.
    var lidHelperPath: String {
        switch self {
        case .release: "/etc/sudoers.d/clearlock"
        case .dev: "/etc/sudoers.d/clearlock-dev"
        }
    }

    /// Dev never checks for or installs releases; an update would replace it with the release.
    var checksForUpdates: Bool { self == .release }

    /// Dev's menu bar icon carries a small hammer, so the two copies are told apart at a glance.
    var badgesMenuBarIcon: Bool { self == .dev }

    /// The other copy, which may be running at the same time.
    var other: AppVariant { self == .dev ? .release : .dev }

    /// Prefix of the Debug-only Terminal hooks' notification names (`scripts/debug-lock.sh`).
    var debugNotificationPrefix: String { bundleID + ".debug." }
}
