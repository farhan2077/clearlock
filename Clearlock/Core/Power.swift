import Foundation
import IOKit.pwr_mgt
import Observation

/// Owns the IOKit power assertions. They are kernel-side flags, so holding one
/// costs no CPU time or wakeups — exactly like `caffeinate`.
@Observable
final class PowerAssertions {
    static let shared = PowerAssertions()

    private(set) var systemAssertion: IOPMAssertionID?
    private(set) var displayAssertion: IOPMAssertionID?

    var preventsSystemSleep: Bool { systemAssertion != nil }
    var preventsDisplaySleep: Bool { displayAssertion != nil }

    private init() {}

    /// Recomputes which assertions are needed from the lock and keep-awake state.
    func refresh() {
        let locked = LockController.shared.isLocked
        let awake = AwakeController.shared.isActive
        let (wantSystem, wantDisplay) = Self.needed(locked: locked, awake: awake)
        let reason = locked ? "Clearlock: Mac is locked while work continues" : "Clearlock: Keep Awake is on"

        systemAssertion = update(systemAssertion, want: wantSystem, type: "PreventUserIdleSystemSleep", reason: reason)
        displayAssertion = update(displayAssertion, want: wantDisplay, type: "PreventUserIdleDisplaySleep", reason: reason)
    }

    /// Which assertions to hold: whenever Clearlock keeps the Mac awake (always while it
    /// runs, and while locked), the display stays on too. There are no settings for either.
    static func needed(locked: Bool, awake: Bool) -> (system: Bool, display: Bool) {
        let awakeAtAll = locked || awake
        return (awakeAtAll, awakeAtAll)
    }

    private func update(_ current: IOPMAssertionID?, want: Bool, type: String, reason: String) -> IOPMAssertionID? {
        if want, let current { return current }
        if !want {
            if let current { IOPMAssertionRelease(current) }
            return nil
        }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
}

/// Keep Awake: always on while Clearlock runs. It starts at launch and there's no switch.
@Observable
final class AwakeController {
    static let shared = AwakeController()

    private(set) var isActive = false

    private init() {}

    func start() {
        guard !isActive else { return }
        isActive = true
        PowerAssertions.shared.refresh()
        ActivityLog.shared.add("cup.and.heat.waves.fill", "Keep Awake on")
    }

    /// Keep Awake always starts with Clearlock.
    static let startsAtLaunch = true
}
