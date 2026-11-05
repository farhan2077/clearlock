import AppKit
import ApplicationServices
import Observation
import Security
import ServiceManagement

/// Live view of everything the user can change in System Settings. Updates
/// immediately when the user flips a switch there, without polling while idle.
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    private(set) var loginItemStatus = SMAppService.mainApp.status
    /// Set once the user has asked for Accessibility, to offer troubleshooting if it doesn't take.
    private(set) var hasRequestedAccessibility = false

    var opensAtLogin: Bool { loginItemStatus == .enabled }
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var watchers = 0

    private init() {}

    func start() {
        // Posted by the system whenever the Accessibility list changes. TCC writes
        // the change slightly after posting, so check again a moment later.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PermissionCenter.shared.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
            ActivityLog.shared.add(trusted ? "checkmark.shield" : "exclamationmark.shield",
                                   "Accessibility permission \(trusted ? "granted" : "removed")")
            LockController.shared.permissionsChanged()
        }
        let defaults = UserDefaults.standard
        if let signature = Self.signatureToRemember(trusted: trusted, signature: Self.ownSignature,
                                                    remembered: defaults.string(forKey: Self.askedForSignatureKey)) {
            defaults.set(signature, forKey: Self.askedForSignatureKey)
        }
        let status = SMAppService.mainApp.status
        if status != loginItemStatus {
            loginItemStatus = status
            // Remembered so a reinstall can turn it back on (see SettingsBackup).
            UserDefaults.standard.set(status == .enabled || status == .requiresApproval, forKey: "opensAtLogin")
        }
    }

    /// While a settings or onboarding window is open, check every second as a fallback
    /// for changes that post no notification (e.g. Login Items). Stops when they close.
    func beginWatching() {
        watchers += 1
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    /// True while the one-second fallback check runs (only while Settings or onboarding is open).
    var isPolling: Bool { pollTimer != nil }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Actions

    /// The `tccutil` arguments that clear Clearlock's own Accessibility entry before asking
    /// again, or nil when there's nothing to repair (already allowed, or no bundle ID).
    /// Only ever this app's entry for this one service; never another app's, never "All".
    static func staleAccessibilityReset(trusted: Bool, bundleID: String?) -> [String]? {
        guard !trusted, let bundleID, !bundleID.isEmpty else { return nil }
        return ["reset", "Accessibility", bundleID]
    }

    /// Clearlock's own earlier bundle IDs, from before the first release. Their leftover
    /// entries show up as a second "Clearlock" in the list, so they're cleared too.
    static let formerBundleIDs = ["com.clearlock.ClearLock"]

    /// Runs `/usr/bin/tccutil`. Resetting an app's own entry needs no administrator rights.
    @ObservationIgnored var runTCCUtil: ([String]) -> Void = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }

    /// Shows the system prompt (which also adds Clearlock to the list) the first time,
    /// and opens the right System Settings pane.
    func requestAccessibility() {
        hasRequestedAccessibility = true
        let signature = Self.ownSignature
        let request = Self.accessibilityRequest(
            trusted: AXIsProcessTrusted(), signature: signature,
            askedForSignature: UserDefaults.standard.string(forKey: Self.askedForSignatureKey),
            openedSettingsLastTime: openedSettingsLastTime)
        switch request {
        case .none:
            break
        case .openSettings:
            // Clearlock is already in the list for this exact build signature: go straight
            // there, without macOS's dialog.
            openedSettingsLastTime = true
            openAccessibilitySettings()
        case .repairAndPrompt:
            // A permission left over from an earlier install or signature still shows in
            // System Settings, can even be switched on, but no longer applies to this copy.
            // Clear Clearlock's own entries first. macOS's dialog then adds a fresh entry and
            // its button opens System Settings, so Clearlock doesn't open it a second time.
            for bundleID in [Bundle.main.bundleIdentifier] + Self.formerBundleIDs {
                if let arguments = Self.staleAccessibilityReset(trusted: false, bundleID: bundleID) {
                    runTCCUtil(arguments)
                }
            }
            openedSettingsLastTime = false
            UserDefaults.standard.set(signature, forKey: Self.askedForSignatureKey)
            // The literal value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        refresh()
    }

    enum AccessibilityRequest: Equatable {
        /// Already allowed.
        case none
        /// Already listed for this signature: open System Settings directly, no dialog.
        case openSettings
        /// First request from this signature, or opening System Settings didn't help last
        /// time: clear stale entries and let macOS's dialog add Clearlock to the list.
        case repairAndPrompt
    }

    /// What "Allow…" does. macOS's dialog is shown at most once per build signature, since
    /// it's the only thing that adds Clearlock to the Accessibility list. After that, Allow…
    /// goes straight to System Settings. If that didn't work (the entry was removed by hand,
    /// say), the next Allow… repairs and asks again.
    static func accessibilityRequest(trusted: Bool, signature: String?, askedForSignature: String?,
                                     openedSettingsLastTime: Bool) -> AccessibilityRequest {
        guard !trusted else { return .none }
        if let signature, signature == askedForSignature, !openedSettingsLastTime { return .openSettings }
        return .repairAndPrompt
    }

    /// Having permission proves Clearlock is in the list for this signature, so a later Allow…
    /// (after it was switched off, say) goes straight to System Settings without the dialog.
    /// Returns the signature to save, or nil when there's nothing new to remember.
    static func signatureToRemember(trusted: Bool, signature: String?, remembered: String?) -> String? {
        guard trusted, let signature, signature != remembered else { return nil }
        return signature
    }

    /// Whether the last Allow… only opened System Settings (reset on each launch).
    @ObservationIgnored private var openedSettingsLastTime = false
    /// The build signature Clearlock last asked macOS about.
    static let askedForSignatureKey = "accessibilityAskedForSignature"

    /// This copy's designated requirement: its bundle ID and signing certificate, which is
    /// what macOS ties the Accessibility entry to.
    static let ownSignature: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }()

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "opensAtLogin")
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if enabled { SMAppService.openSystemSettingsLoginItems() }
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
