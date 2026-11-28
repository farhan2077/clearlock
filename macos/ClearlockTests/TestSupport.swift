import Foundation
@testable import Clearlock

/// A throwaway UserDefaults suite, so tests never read or write the user's real settings.
nonisolated final class IsolatedDefaults {
    let name = "ClearlockTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    /// Writes stored values the way the app persists them.
    var stored: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }

    deinit {
        // Emptying the domain leaves an empty plist in ~/Library/Preferences, so delete it too.
        // cfprefsd writes that empty file lazily, after a plain delete, so make it write now
        // and only then remove the file; nothing writes to the domain afterwards.
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        CFPreferencesAppSynchronize(name as CFString)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }
}

/// A unique file location in the temporary directory, removed when released.
nonisolated final class TemporaryFile {
    let url: URL

    init(_ name: String = "settings.plist") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearlockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
