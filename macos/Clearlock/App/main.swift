import AppKit

/// When the app is launched as the host for unit tests, nothing starts: no menu bar item,
/// no hotkeys, no welcome guide, and the user's real settings are never touched.
let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

// Before anything reads settings: bring them back if an uninstaller removed them.
let restoredSettings = isUnitTesting ? false : SettingsBackup.restoreIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
if !isUnitTesting { app.delegate = delegate }
app.setActivationPolicy(isUnitTesting ? .prohibited : .accessory)
app.run()
