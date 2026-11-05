import Foundation
import IOKit.ps
import Observation

/// Keeps the Mac running with the lid closed while locked.
///
/// Only root can change `pmset disablesleep`, so a one-time setup installs a
/// sudoers rule that allows exactly two commands for this user:
/// `pmset -a disablesleep 1` and `pmset -a disablesleep 0`. Nothing else runs as root.
@Observable
final class LidSleepManager {
    static let shared = LidSleepManager()

    static let rulePath = "/etc/sudoers.d/clearlock"
    /// Saved while lid sleep is disabled, so a crash or quit can be undone at the next launch.
    static let engagedKey = "lidSleepEngaged"

    private(set) var isHelperInstalled = FileManager.default.fileExists(atPath: rulePath)
    private(set) var isEngaged: Bool
    private(set) var isBusy = false
    private(set) var lastError: String?

    @ObservationIgnored private let store: UserDefaults
    /// Replaces running `sudo pmset` in tests, which must never change the Mac.
    @ObservationIgnored private let pmsetOverride: ((_ disable: Bool) -> Bool)?

    init(store: UserDefaults = .standard, pmset: ((_ disable: Bool) -> Bool)? = nil) {
        self.store = store
        pmsetOverride = pmset
        isEngaged = store.bool(forKey: Self.engagedKey)
    }

    func refreshInstalled() {
        isHelperInstalled = FileManager.default.fileExists(atPath: Self.rulePath)
    }

    /// Engages if enabled in settings and allowed by the power-source rule.
    func engageIfConfigured() {
        let prefs = Preferences.shared
        guard prefs.keepAwakeWithLidClosed, isHelperInstalled else { return }
        guard Self.shouldEngage(enabled: true, helperInstalled: true, onlyOnPower: prefs.lidOnlyOnPower,
                                onACPower: Self.isOnACPower) else {
            ActivityLog.shared.add("powerplug", "Lid-closed mode skipped: on battery")
            return
        }
        if runPmset(disable: true) {
            setEngaged(true)
            ActivityLog.shared.add("laptopcomputer", "Lid sleep disabled while locked")
        }
    }

    func release() {
        guard isEngaged else { return }
        if runPmset(disable: false) {
            setEngaged(false)
            ActivityLog.shared.add("laptopcomputer", "Lid sleep restored")
        }
    }

    /// Restores lid sleep if the app quit or crashed while it was disabled.
    func restoreAfterUnexpectedExit() {
        if isEngaged { release() }
    }

    func installHelper() async -> Bool {
        guard let rule = Self.sudoersRule(for: NSUserName()) else {
            lastError = "Your account name contains characters that can’t be used in a sudoers rule."
            return false
        }
        let script = """
        T=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > "$T" && \
        /usr/sbin/visudo -cf "$T" >/dev/null && /bin/mkdir -p /etc/sudoers.d && \
        /usr/bin/install -m 0440 -o root -g wheel "$T" \(Self.rulePath); R=$?; /bin/rm -f "$T"; exit $R
        """
        let ok = await runAsAdmin(script, prompt: "Clearlock wants to allow keeping your Mac awake with the lid closed.")
        refreshInstalled()
        return ok && isHelperInstalled
    }

    /// Lid-closed mode needs the setting and the helper, and respects "Only when connected to power".
    static func shouldEngage(enabled: Bool, helperInstalled: Bool, onlyOnPower: Bool, onACPower: Bool) -> Bool {
        enabled && helperInstalled && (!onlyOnPower || onACPower)
    }

    /// The only thing the helper allows as root: these two exact pmset commands, for this user.
    /// Nil for account names that can't be placed safely in a sudoers file.
    static func sudoersRule(for user: String) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type == kIOPMACPowerKey
    }

    // MARK: Private

    private func setEngaged(_ value: Bool) {
        isEngaged = value
        store.set(value, forKey: Self.engagedKey)
    }

    private func runPmset(disable: Bool) -> Bool {
        if let pmsetOverride { return pmsetOverride(disable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disable ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        if process.terminationStatus != 0 {
            lastError = "The lid-closed helper isn’t working. Remove and set it up again in Settings."
            return false
        }
        lastError = nil
        return true
    }

    /// Runs a shell script as root through the standard macOS administrator prompt.
    private func runAsAdmin(_ script: String, prompt: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        let escaped = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(escaped(script))\" with prompt \"\(escaped(prompt))\" with administrator privileges"

        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        lastError = status == 0 ? nil : "Setup was cancelled or failed."
        return status == 0
    }
}
