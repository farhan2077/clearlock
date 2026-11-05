import Foundation
import ServiceManagement

/// Keeps a copy of Clearlock's settings at ~/.config/clearlock/settings.plist.
///
/// Dragging an app to the Trash leaves its preferences in ~/Library, but uninstaller
/// apps (AppCleaner, CleanMyMac…) delete them. The copy lives outside ~/Library so a
/// reinstall picks up where the user left off, including Open at Login.
enum SettingsBackup {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clearlock/settings.plist")

    static let domain = Bundle.main.bundleIdentifier ?? "com.farhan2077.clearlock"
    private static var saveScheduled = false

    /// Call before anything reads settings. Returns true if settings were restored.
    @discardableResult
    static func restoreIfNeeded(defaults: UserDefaults = .standard, domain: String = domain,
                                file: URL = fileURL) -> Bool {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current.isEmpty,
              let data = try? Data(contentsOf: file),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !saved.isEmpty else { return false }
        defaults.setPersistentDomain(saved, forName: domain)
        return true
    }

    /// Re-enables Open at Login after a restore if it was on before the uninstall.
    static func restoreLoginItem() {
        if shouldReRegisterLoginItem(wasOn: UserDefaults.standard.bool(forKey: "opensAtLogin"),
                                     status: SMAppService.mainApp.status) {
            try? SMAppService.mainApp.register()
        }
    }

    /// Only turn Open at Login back on if it was on, and macOS doesn't already have it
    /// (enabled, or waiting for the user's approval).
    static func shouldReRegisterLoginItem(wasOn: Bool, status: SMAppService.Status) -> Bool {
        wasOn && status != .enabled && status != .requiresApproval
    }

    /// Mirrors every settings change to the backup, batched so a burst of changes is one write.
    static func startMirroring() {
        save()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { scheduleSave() }
        }
    }

    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                saveScheduled = false
                save()
            }
        }
    }

    static func save(defaults: UserDefaults = .standard, domain: String = domain, file: URL = fileURL) {
        guard let settings = defaults.persistentDomain(forName: domain), !settings.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
        else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
