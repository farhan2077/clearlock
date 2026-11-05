import Foundation
import Testing
@testable import Clearlock

@Suite("Onboarding and lid-closed recovery")
struct OnboardingAndLidTests {
    @Test("The guide's only button is Done once Accessibility is allowed, Skip for Now before that")
    func onboardingButton() {
        #expect(OnboardingView.finishButton(accessibilityAllowed: true) == .done)
        #expect(OnboardingView.finishButton(accessibilityAllowed: false) == .skipForNow)
    }

    @Test("Before asking for Accessibility, a stale permission for this app is cleared, and only this app's")
    func staleAccessibilityIsCleared() {
        #expect(PermissionCenter.staleAccessibilityReset(trusted: false, bundleID: "com.farhan2077.clearlock")
            == ["reset", "Accessibility", "com.farhan2077.clearlock"])
        #expect(PermissionCenter.staleAccessibilityReset(trusted: false, bundleID: Bundle.main.bundleIdentifier)?.last
            == Bundle.main.bundleIdentifier)
    }

    @Test("Leftover entries from Clearlock's own earlier ID are cleared too, and nothing else")
    func formerIDsAreOnlyClearlocks() {
        #expect(PermissionCenter.formerBundleIDs == ["com.clearlock.ClearLock"])
        #expect(!PermissionCenter.formerBundleIDs.contains(Bundle.main.bundleIdentifier ?? ""))
    }

    @Test("A working permission is never touched, and nothing is reset without a bundle ID")
    func workingAccessibilityIsKept() {
        #expect(PermissionCenter.staleAccessibilityReset(trusted: true, bundleID: "com.farhan2077.clearlock") == nil)
        #expect(PermissionCenter.staleAccessibilityReset(trusted: false, bundleID: nil) == nil)
        #expect(PermissionCenter.staleAccessibilityReset(trusted: false, bundleID: "") == nil)
    }

    @Test("Once Clearlock is in the list for this build, Allow… opens System Settings without macOS's dialog")
    func noRedundantDialog() {
        #expect(PermissionCenter.accessibilityRequest(trusted: false, signature: "sig", askedForSignature: "sig",
                                                      openedSettingsLastTime: false) == .openSettings)
    }

    @Test("The dialog is used only when Clearlock may not be listed yet: first ask, a new signature, or a failed retry")
    func dialogOnlyWhenNeeded() {
        #expect(PermissionCenter.accessibilityRequest(trusted: false, signature: "sig", askedForSignature: nil,
                                                      openedSettingsLastTime: false) == .repairAndPrompt)
        #expect(PermissionCenter.accessibilityRequest(trusted: false, signature: "new", askedForSignature: "old",
                                                      openedSettingsLastTime: false) == .repairAndPrompt)
        #expect(PermissionCenter.accessibilityRequest(trusted: false, signature: "sig", askedForSignature: "sig",
                                                      openedSettingsLastTime: true) == .repairAndPrompt)
        #expect(PermissionCenter.accessibilityRequest(trusted: false, signature: nil, askedForSignature: nil,
                                                      openedSettingsLastTime: false) == .repairAndPrompt)
    }

    @Test("Nothing happens when Accessibility already works")
    func nothingWhenAllowed() {
        for opened in [false, true] {
            #expect(PermissionCenter.accessibilityRequest(trusted: true, signature: "sig", askedForSignature: nil,
                                                          openedSettingsLastTime: opened) == .none)
        }
    }

    @Test("Having permission proves Clearlock is listed, so that signature is remembered, once")
    func permissionRemembersSignature() {
        #expect(PermissionCenter.signatureToRemember(trusted: true, signature: "sig", remembered: nil) == "sig")
        #expect(PermissionCenter.signatureToRemember(trusted: true, signature: "new", remembered: "old") == "new")
        #expect(PermissionCenter.signatureToRemember(trusted: true, signature: "sig", remembered: "sig") == nil)
        #expect(PermissionCenter.signatureToRemember(trusted: false, signature: "sig", remembered: nil) == nil)
    }

    @Test("This build has a signature to remember")
    func ownSignatureExists() {
        #expect(PermissionCenter.ownSignature?.isEmpty == false)
    }

    @Test("The guide welcomes first, then asks for Accessibility; only the second page finishes or goes back")
    func twoPageGuide() {
        #expect(OnboardingView.Page.allCases == [.welcome, .accessibility])
        for allowed in [false, true] {
            #expect(OnboardingView.primaryButton(on: .welcome, accessibilityAllowed: allowed) == .continue)
        }
        #expect(OnboardingView.primaryButton(on: .accessibility, accessibilityAllowed: true) == .done)
        #expect(OnboardingView.primaryButton(on: .accessibility, accessibilityAllowed: false) == .skipForNow)
        #expect(!OnboardingView.showsBack(on: .welcome))
        #expect(OnboardingView.showsBack(on: .accessibility))
    }

    /// Records each pmset call instead of running it.
    private final class FakePmset {
        var calls: [Bool] = []
        var succeeds = true
        func run(_ disable: Bool) -> Bool {
            calls.append(disable)
            return succeeds
        }
    }

    @Test("If Clearlock quit while lid sleep was disabled, the next launch turns it back on")
    func restoresAfterUnexpectedExit() {
        let suite = IsolatedDefaults()
        suite.defaults.set(true, forKey: LidSleepManager.engagedKey)
        let pmset = FakePmset()
        let manager = LidSleepManager(store: suite.defaults, pmset: pmset.run)
        #expect(manager.isEngaged)

        manager.restoreAfterUnexpectedExit()

        #expect(pmset.calls == [false])
        #expect(!manager.isEngaged)
        #expect(!suite.defaults.bool(forKey: LidSleepManager.engagedKey))
    }

    @Test("A normal launch never touches lid sleep")
    func normalLaunchLeavesLidSleepAlone() {
        let suite = IsolatedDefaults()
        let pmset = FakePmset()
        LidSleepManager(store: suite.defaults, pmset: pmset.run).restoreAfterUnexpectedExit()
        #expect(pmset.calls.isEmpty)
    }

    @Test("If restoring fails, it's remembered and tried again at the following launch")
    func failedRestoreIsRetried() {
        let suite = IsolatedDefaults()
        suite.defaults.set(true, forKey: LidSleepManager.engagedKey)
        let pmset = FakePmset()
        pmset.succeeds = false
        LidSleepManager(store: suite.defaults, pmset: pmset.run).restoreAfterUnexpectedExit()
        #expect(suite.defaults.bool(forKey: LidSleepManager.engagedKey))

        pmset.succeeds = true
        LidSleepManager(store: suite.defaults, pmset: pmset.run).restoreAfterUnexpectedExit()
        #expect(pmset.calls == [false, false])
        #expect(!suite.defaults.bool(forKey: LidSleepManager.engagedKey))
    }

    @Test("With lid-closed mode off, 'Only when connected to power' shows off and can't be changed")
    func lidPowerToggleFollowsLidMode() {
        for saved in [true, false] {
            let off = SettingsView.lidPowerToggle(lidEnabled: false, onlyOnPower: saved)
            #expect(!off.isOn)
            #expect(!off.isEnabled)
            let on = SettingsView.lidPowerToggle(lidEnabled: true, onlyOnPower: saved)
            #expect(on.isOn == saved)
            #expect(on.isEnabled)
        }
    }

    @Test("Turning lid-closed mode off keeps the saved power choice for next time")
    func lidPowerChoiceIsKept() {
        let suite = IsolatedDefaults()
        let prefs = Preferences(store: suite.defaults)
        prefs.keepAwakeWithLidClosed = true
        prefs.keepAwakeWithLidClosed = false
        #expect(Preferences(store: suite.defaults).lidOnlyOnPower)
        #expect(SettingsView.lidPowerToggle(lidEnabled: true, onlyOnPower: prefs.lidOnlyOnPower).isOn)
    }

}
