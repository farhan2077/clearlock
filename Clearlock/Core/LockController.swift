import AppKit
import Observation

/// Engages and releases the lock: overlay windows, the unlock prompt, kiosk
/// presentation options, the input shield, power assertions and lid sleep.
@Observable
final class LockController {
    static let shared = LockController()

    enum Mode {
        /// No Accessibility: full-screen windows catch all input, kiosk mode blocks app switching.
        case standard
        /// Accessibility: only physical input is blocked, including system shortcuts, media
        /// keys and gestures. Agents always keep working; there's no setting to stop them.
        case passthrough

        var title: String {
            switch self {
            case .standard: "Standard"
            case .passthrough: "Shield"
            }
        }
    }

    struct Session {
        let start: Date
        let end: Date
        let unlockMethod: String
        let failedAttempts: [Date]
        let blockedInputs: Int
        let allowedAutomation: Int
    }

    private(set) var isLocked = false
    private(set) var lockedSince: Date?
    private(set) var mode = Mode.standard
    private(set) var failedAttempts: [Date] = []
    private(set) var throttledUntil: Date?
    private(set) var lastSession: Session?
    private(set) var isPromptFocused = false
    private(set) var overlayCount = 0

    let shield = InputShield()

    /// Brings the welcome guide forward when a lock is held back during setup. Replaceable in tests.
    @ObservationIgnored var presentOnboarding: () -> Void = { WindowCoordinator.shared.showOnboarding() }

    @ObservationIgnored private var overlays: [LockOverlayWindow] = []
    @ObservationIgnored private var panel: UnlockPanel?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {}

    // MARK: Lock

    func toggle(source: String) {
        if isLocked { focusPrompt() } else { lock(source: source) }
    }

    func lock(source: String) {
        guard !isLocked else {
            focusPrompt()
            return
        }
        if OnboardingSession.shared.isActive {
            OnboardingSession.shared.noteBlockedLock(source: source)
            presentOnboarding()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        failedAttempts = []
        throttledUntil = nil
        lockedSince = Date()
        isLocked = true

        // The shield runs whenever Accessibility is allowed; there is no separate switch.
        let shieldStarted = shield.start()
        mode = Self.mode(shieldStarted: shieldStarted)
        if shieldStarted {
            shield.isPromptFocused = { [weak self] in self?.panel?.isKeyWindow ?? false }
            shield.onBlockedPhysicalPress = { [weak self] in self?.focusPrompt() }
            shield.automationKeyTarget = { [weak self] in self?.agentAppPID() }
        }

        PowerAssertions.shared.refresh()
        LidSleepManager.shared.engageIfConfigured()
        buildOverlays()

        let panel = UnlockPanel(controller: self)
        self.panel = panel
        panel.present(on: screenUnderMouse())
        updateInteractiveRects()
        installObservers()

        focusPrompt()
        ActivityLog.shared.add("lock.fill", "Locked via \(source) · \(mode.title) mode")
    }

    /// Brings the unlock card forward and gives it keyboard focus. The card keeps focus
    /// for as long as the Mac is locked.
    func focusPrompt() {
        guard let panel else { return }
        switch Self.focusAction(isLocked: isLocked, cardIsKey: panel.isKeyWindow, appIsActive: NSApp.isActive,
                                mode: mode, isRetry: false) {
        case .none:
            return
        case .makeKey:
            // The card is a non-activating panel: it takes keyboard focus while the app the
            // agents are driving stays frontmost. Their keystrokes are forwarded to that app.
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    let controller = LockController.shared
                    guard let panel = controller.panel,
                          Self.focusAction(isLocked: controller.isLocked, cardIsKey: panel.isKeyWindow,
                                           appIsActive: NSApp.isActive, mode: controller.mode,
                                           isRetry: true) == .activateAndMakeKey else { return }
                    NSApp.activate()
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        case .activateAndMakeKey:
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            applyKioskOptions()
        }
    }

    enum FocusAction: Equatable { case none, makeKey, activateAndMakeKey }

    /// How the card gets keyboard focus back. While locked it always ends up key; with
    /// agents allowed it first tries without activating Clearlock, so the agents' app stays
    /// frontmost, and only activates if that didn't work. Unlocked, it does nothing.
    static func focusAction(isLocked: Bool, cardIsKey: Bool, appIsActive: Bool, mode: Mode,
                            isRetry: Bool) -> FocusAction {
        guard isLocked else { return .none }
        if mode == .passthrough {
            if cardIsKey { return .none }
            return isRetry ? .activateAndMakeKey : .makeKey
        }
        return cardIsKey && appIsActive ? .none : .activateAndMakeKey
    }

    /// Whatever takes focus from the card, it's taken back after this delay.
    static let refocusDelay: TimeInterval = 0.2

    /// The app agents are working in: whatever is frontmost, or what was frontmost at lock time.
    private func agentAppPID() -> pid_t? {
        Self.agentTarget(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, own: getpid(),
                         previous: previousApp?.isTerminated == false ? previousApp?.processIdentifier : nil)
    }

    // MARK: Decisions (pure, so they can be unit tested)

    /// Without the shield, windows catch everything; with it, only hands are blocked.
    static func mode(shieldStarted: Bool) -> Mode {
        shieldStarted ? .passthrough : .standard
    }

    /// Agents' keystrokes go to the frontmost app, or the app that was in front at lock time,
    /// never to Clearlock itself.
    static func agentTarget(frontmost: pid_t?, own: pid_t, previous: pid_t?) -> pid_t? {
        if let frontmost, frontmost != own { return frontmost }
        return previous == own ? nil : previous
    }

    /// Converts a window frame (bottom-left origin) to event-tap coordinates (top-left origin
    /// of the primary display), so the shield knows where the card is.
    static func eventRect(fromScreenFrame f: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: primaryScreenMaxY - f.maxY, width: f.width, height: f.height)
    }

    /// Kiosk mode while locked: no app switching, Force Quit, logging out or hiding.
    /// `hideDock` is required by AppKit for the others.
    static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication,
    ]

    // MARK: Unlock

    enum PasswordResult { case success, failure, throttled(Date) }

    func submitPassword(_ password: String) async -> PasswordResult {
        if let until = throttledUntil, until > Date() { return .throttled(until) }
        if await Authenticator.verifyPassword(password) {
            unlock(method: "password")
            return .success
        }
        registerFailure(kind: "password")
        if let until = throttledUntil, until > Date() { return .throttled(until) }
        return .failure
    }

    func touchIDSucceeded() {
        unlock(method: "Touch ID")
    }

    func touchIDFailed() {
        guard isLocked else { return }
        registerFailure(kind: "Touch ID")
    }

    private func registerFailure(kind: String) {
        failedAttempts.append(Date())
        ActivityLog.shared.add("xmark.octagon", "Failed \(kind) attempt")
        if let delay = Self.throttleDelay(afterFailures: failedAttempts.count) {
            throttledUntil = Date().addingTimeInterval(delay)
        }
    }

    /// Escalating wait after every third failure: 30 s, 60 s, 120 s … capped at 5 minutes.
    static func throttleDelay(afterFailures count: Int) -> TimeInterval? {
        guard count > 0, count % 3 == 0 else { return nil }
        return min(30 * pow(2, Double(count / 3 - 1)), 300)
    }

    private func unlock(method: String) {
        guard isLocked else { return }
        let counters = shield.counters
        shield.stop()
        removeObservers()

        NSApp.presentationOptions = []
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        overlayCount = 0
        panel?.tearDown()
        panel?.orderOut(nil)
        panel = nil

        let start = lockedSince ?? Date()
        lastSession = Session(start: start, end: Date(), unlockMethod: method, failedAttempts: failedAttempts,
                              blockedInputs: counters.blockedPhysical + counters.blockedAutomation,
                              allowedAutomation: counters.allowedAutomation)
        isLocked = false
        isPromptFocused = false
        lockedSince = nil
        mode = .standard

        PowerAssertions.shared.refresh()
        LidSleepManager.shared.release()
        ActivityLog.shared.add("lock.open.fill", "Unlocked with \(method) after \(Self.durationString(since: start))")

        if let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current)
        }
        previousApp = nil
        if let lastSession, Self.reportsFailures(lastSession) { showFailedAttemptsAlert(lastSession) }
    }

    #if DEBUG
    func debugUnlock() { unlock(method: "debug hook") }
    func debugShowPassword() { panel?.debugShowPassword() }

    var debugStatus: String {
        "locked=\(isLocked) mode=\(mode.title) cardKey=\(panel?.isKeyWindow ?? false) appActive=\(NSApp.isActive) "
            + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") shield=\(shield.isRunning) "
            + "cardTop=\(Int(panel?.frame.maxY ?? 0)) cardBottom=\(Int(panel?.frame.minY ?? 0))\n"
            + ActivityLog.shared.entries.prefix(6).map { "  \($0.date.formatted(date: .omitted, time: .standard)) \($0.text)" }
                .joined(separator: "\n")
    }
    #endif

    // MARK: Permission changes

    func permissionsChanged() {
        guard isLocked, mode != .standard, !AXIsProcessTrusted() else { return }
        // The shield can't run without Accessibility; fall back to catching input with the windows.
        shield.stop()
        mode = .standard
        overlays.forEach { $0.ignoresMouseEvents = false }
        focusPrompt()
        ActivityLog.shared.add("exclamationmark.shield", "Shield stopped: Accessibility was turned off")
    }

    // MARK: Windows

    private func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        let prefs = Preferences.shared
        overlays = NSScreen.screens.map {
            LockOverlayWindow(screen: $0, dim: prefs.dimLevel, passthrough: mode == .passthrough)
        }
        overlays.forEach { $0.show() }
        overlayCount = overlays.count
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func unlockPanelDidChangeFrame() {
        updateInteractiveRects()
    }

    /// The shield lets physical clicks through only inside the prompt.
    private func updateInteractiveRects() {
        guard let panel, let primary = NSScreen.screens.first else { return }
        shield.interactiveRects = [Self.eventRect(fromScreenFrame: panel.cardScreenFrame, primaryScreenMaxY: primary.frame.maxY)]
    }

    private func applyKioskOptions() {
        guard isLocked, NSApp.isActive else { return }
        NSApp.presentationOptions = Self.kioskOptions
    }

    private func installObservers() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ object: Any? = nil,
                _ action: @escaping @MainActor (LockController) -> Void) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { action(LockController.shared) }
            }
            observers.append((center, token))
        }

        on(app, NSApplication.didBecomeActiveNotification) { $0.applyKioskOptions() }
        on(app, NSApplication.didResignActiveNotification) { c in
            // Without the automation exception nothing else may take focus while locked.
            guard c.mode != .passthrough else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { LockController.shared.focusPrompt() }
            }
        }
        on(app, NSApplication.didChangeScreenParametersNotification) { c in
            c.buildOverlays()
            c.panel?.present(on: c.screenUnderMouse())
            c.updateInteractiveRects()
        }
        on(workspace, NSWorkspace.activeSpaceDidChangeNotification) { c in
            c.overlays.forEach { $0.orderFrontRegardless() }
            c.panel?.orderFrontRegardless()
        }
        on(app, NSWindow.didBecomeKeyNotification, panel) { $0.isPromptFocused = true }
        on(app, NSWindow.didResignKeyNotification, panel) { c in
            c.isPromptFocused = false
            // Whatever took focus, the card takes it back.
            DispatchQueue.main.asyncAfter(deadline: .now() + LockController.refocusDelay) {
                MainActor.assumeIsolated { LockController.shared.focusPrompt() }
            }
        }
        on(app, NSWindow.didMoveNotification, panel) { $0.updateInteractiveRects() }
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// After unlocking, the owner is told about every failed attempt made while locked.
    static func reportsFailures(_ session: Session) -> Bool {
        !session.failedAttempts.isEmpty
    }

    private func showFailedAttemptsAlert(_ session: Session) {
        let times = session.failedAttempts.map { $0.formatted(date: .omitted, time: .shortened) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = session.failedAttempts.count == 1
            ? "Someone tried to unlock your Mac"
            : "\(session.failedAttempts.count) failed unlock attempts"
        alert.informativeText = "While your Mac was locked, unlocking failed at \(ListFormatter.localizedString(byJoining: times))."
        NSApp.activate()
        alert.runModal()
    }

    static func durationString(since date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: Date().timeIntervalSince(date)) ?? ""
    }
}
