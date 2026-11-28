import AppKit
import ServiceManagement
import Testing
@testable import Clearlock

@Suite("Lock and app decisions")
struct LockDecisionTests {
    @Test("Lock mode: no shield means windows catch everything; with it, automation decides")
    func lockMode() {
        #expect(LockController.mode(shieldStarted: false) == .standard)
        #expect(LockController.mode(shieldStarted: true) == .passthrough)
    }

    @Test("Agents' keystrokes go to the app in front, or the one in front at lock time, never to Clearlock")
    func agentKeystrokeTarget() {
        #expect(LockController.agentTarget(frontmost: 200, own: 100, previous: 300) == 200)
        #expect(LockController.agentTarget(frontmost: 100, own: 100, previous: 300) == 300)
        #expect(LockController.agentTarget(frontmost: nil, own: 100, previous: 300) == 300)
        #expect(LockController.agentTarget(frontmost: 100, own: 100, previous: nil) == nil)
        #expect(LockController.agentTarget(frontmost: 100, own: 100, previous: 100) == nil)
    }

    @Test("The card's clickable area matches where it is on screen, in the shield's coordinates")
    func cardAreaConversion() {
        // A 340×300 card whose bottom-left is at (500, 200) on a 956-point-tall primary display.
        let rect = LockController.eventRect(fromScreenFrame: CGRect(x: 500, y: 200, width: 340, height: 300),
                                            primaryScreenMaxY: 956)
        #expect(rect == CGRect(x: 500, y: 456, width: 340, height: 300))
        // The top-left corner of the card on screen is inside it; just above it isn't.
        #expect(rect.contains(CGPoint(x: 501, y: 457)))
        #expect(!rect.contains(CGPoint(x: 501, y: 455)))
    }

    @Test("While locked, app switching, Force Quit, logging out and hiding are all disabled")
    func kioskOptions() {
        let options = LockController.kioskOptions
        #expect(options.contains(.disableProcessSwitching))
        #expect(options.contains(.disableForceQuit))
        #expect(options.contains(.disableSessionTermination))
        #expect(options.contains(.disableHideApplication))
        // AppKit raises if those are set without hiding the Dock.
        #expect(options.contains(.hideDock))
    }

    @Test("Clearlock can't be quit while locked, and quits normally otherwise")
    func quitIsRefusedWhileLocked() {
        #expect(AppDelegate.terminateReply(isLocked: true) == .terminateCancel)
        #expect(AppDelegate.terminateReply(isLocked: false) == .terminateNow)
    }

    @Test("Lid-closed mode needs the setting and the helper, and honors 'only on power'")
    func lidClosedMode() {
        #expect(LidSleepManager.shouldEngage(enabled: true, helperInstalled: true, onlyOnPower: true, onACPower: true))
        #expect(!LidSleepManager.shouldEngage(enabled: true, helperInstalled: true, onlyOnPower: true, onACPower: false))
        #expect(LidSleepManager.shouldEngage(enabled: true, helperInstalled: true, onlyOnPower: false, onACPower: false))
        #expect(!LidSleepManager.shouldEngage(enabled: false, helperInstalled: true, onlyOnPower: false, onACPower: true))
        #expect(!LidSleepManager.shouldEngage(enabled: true, helperInstalled: false, onlyOnPower: false, onACPower: true))
    }

    @Test("Updates are only checked once a real owner/repo is configured")
    func updateSource() {
        #expect(Updater.repository(from: "farhan2077/clearlock") == "farhan2077/clearlock")
        #expect(Updater.repository(from: " farhan2077/clearlock ") == "farhan2077/clearlock")
        #expect(Updater.repository(from: "OWNER/clearlock") == nil)
        #expect(Updater.repository(from: "clearlock") == nil)
        #expect(Updater.repository(from: "a/b/c") == nil)
        #expect(Updater.repository(from: "") == nil)
        #expect(Updater.repository(from: nil) == nil)
        #expect(Updater.repository(from: 42) == nil)
    }

    @Test("After a reinstall, Open at Login comes back only if it was on and macOS doesn't already have it")
    func loginItemRestore() {
        #expect(SettingsBackup.shouldReRegisterLoginItem(wasOn: true, status: .notRegistered))
        #expect(SettingsBackup.shouldReRegisterLoginItem(wasOn: true, status: .notFound))
        #expect(!SettingsBackup.shouldReRegisterLoginItem(wasOn: true, status: .enabled))
        #expect(!SettingsBackup.shouldReRegisterLoginItem(wasOn: true, status: .requiresApproval))
        #expect(!SettingsBackup.shouldReRegisterLoginItem(wasOn: false, status: .notRegistered))
    }

    @Test("The impact test's verdict follows CPU and wakeups, and gets worse as either rises")
    func impactVerdict() {
        typealias T = ResourceMonitor.TestResult
        #expect(T.verdict(cpuPercent: 0.01, wakeupsPerSecond: 0.2) == .negligible)
        #expect(T.verdict(cpuPercent: 0.01, wakeupsPerSecond: 5) == .veryLow)
        #expect(T.verdict(cpuPercent: 0.5, wakeupsPerSecond: 1) == .veryLow)
        #expect(T.verdict(cpuPercent: 2, wakeupsPerSecond: 1) == .low)
        #expect(T.verdict(cpuPercent: 0.5, wakeupsPerSecond: 50) == .low)
        #expect(T.verdict(cpuPercent: 12, wakeupsPerSecond: 1) == .noticeable)
        // More CPU never gives a better verdict.
        var previous = T.Verdict.negligible
        for cpu in stride(from: 0.0, through: 10, by: 0.05) {
            let verdict = T.verdict(cpuPercent: cpu, wakeupsPerSecond: 1)
            #expect(verdict >= previous)
            previous = verdict
        }
    }
}
