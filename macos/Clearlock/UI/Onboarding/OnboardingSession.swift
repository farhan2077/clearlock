import Observation

/// Tracks whether the welcome guide is open. Locking is paused meanwhile, so a
/// shortcut pressed while trying things out can't lock someone out mid-setup.
@Observable
final class OnboardingSession {
    static let shared = OnboardingSession()

    private(set) var isActive = false
    /// Increments on every lock that was held back, so the guide can react to it.
    private(set) var blockedLockCount = 0
    private(set) var lastBlockedSource = ""

    private init() {}

    func begin() { isActive = true }
    func end() { isActive = false }

    func noteBlockedLock(source: String) {
        lastBlockedSource = source
        blockedLockCount += 1
    }
}
