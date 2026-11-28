import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// The lock screen's Liquid Glass pill: the Touch ID fingerprint on the left, "Locked by
/// Clearlock" and a helper line on the right. Touch ID runs inside the pill
/// (LAAuthenticationView) instead of a system sheet, so it can never be hidden behind the
/// lock windows. Double-clicking the pill (never typing) swaps the helper line for the
/// password field, which closes again after a while unused; the pill itself never changes size.
final class UnlockPanel: NSPanel {
    private weak var controller: LockController?

    /// The default pill size (Regular). A pill's own size is `metrics.size`.
    static let pillSize = PillSize.defaultSize.metrics.size

    private var metrics: PillSize.Metrics { options.size.metrics }

    private static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let glass = NSGlassEffectView()
    /// The visible pill. The window around it is transparent and exactly its size.
    private let card = NSView()
    private let touchIDContainer = NSView()
    private let lockSymbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let helperLabel = NSTextField(labelWithString: "")
    private let passwordRow = NSStackView()
    private let passwordField = NSSecureTextField()
    private let submitButton = NSButton()
    private var authView: LAAuthenticationView?
    private var authContext: LAContext?
    private var isEvaluating = false
    private var touchIDLockedOut = false
    private var isVerifying = false
    private var throttleTimer: Timer?
    private var throttleUntil = Date.distantPast
    private var feedbackTimer: Timer?
    private var idleTimer: Timer?

    /// How long the open password field waits for a key press or click before it closes
    /// and Touch ID shows again (the owner's choice).
    static let defaultPasswordIdleTimeout: TimeInterval = 15
    /// The idle wait for this pill. Tests shorten or lengthen it.
    var passwordIdleTimeout = defaultPasswordIdleTimeout

    /// When the open field will close if nothing happens, or nil while no countdown runs.
    var idleDeadline: Date? {
        guard let idleTimer, idleTimer.isValid else { return nil }
        return idleTimer.fireDate
    }

    /// What the card shows. Tests pass explicit values instead of the user's settings.
    struct Options {
        /// Touch ID is always used when the Mac has it; there's no setting to turn it off.
        var touchIDAvailable: Bool
        var position: CardPosition = .center
        var size: PillSize = .defaultSize

        /// What a lock shows: the user's settings. `from(_:touchIDAvailable:)` is the same, for tests.
        static var current: Options {
            from(.shared, touchIDAvailable: Authenticator.isTouchIDAvailable)
        }

        static func from(_ prefs: Preferences, touchIDAvailable: Bool) -> Options {
            Options(touchIDAvailable: touchIDAvailable, position: prefs.cardPosition, size: prefs.pillSize)
        }
    }

    private let options: Options

    private var touchIDEnabled: Bool {
        options.touchIDAvailable && !touchIDLockedOut
    }

    var isPasswordVisible: Bool { !passwordRow.isHidden }
    /// The pill's opacity. It's always fully shown while locked; there's no hidden mode.
    var cardOpacity: CGFloat { card.alphaValue }
    /// True on Macs without Touch ID (or after a lockout): a lock symbol takes the fingerprint's place.
    var showsLockSymbol: Bool { !lockSymbol.isHidden }

    init(controller: LockController, options: Options = .current) {
        self.controller = controller
        self.options = options
        super.init(contentRect: NSRect(origin: .zero, size: options.size.metrics.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .alertPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        buildContent()
        setPasswordVisible(!touchIDEnabled)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where passwordRow.isHidden:
            // While only Touch ID is showing, typing does nothing: the password field opens
            // only on a double-click, so stray key presses can never use up unlock attempts.
            return
        case .keyDown where event.keyCode == 53 && !passwordRow.isHidden && passwordField.stringValue.isEmpty && touchIDEnabled:
            // Escape on an empty field goes back to Touch ID.
            setPasswordVisible(false)
            return
        case .leftMouseDown where passwordRow.isHidden:
            // Double-clicking the pill opens the password field; a single click doesn't.
            if Self.opensPassword(clickCount: event.clickCount) { setPasswordVisible(true) }
        case .keyDown, .leftMouseDown:
            // The field is open and in use, so its idle countdown starts over.
            restartIdleTimer()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        armTouchID()
        if !passwordRow.isHidden { focusPasswordField() }
    }

    // MARK: Presentation

    func present(on screen: NSScreen) {
        // Top positions stay clear of the menu bar and the camera housing.
        let topInset = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        setFrame(Self.frame(for: options.position, in: screen.frame, topInset: topInset, size: metrics.size), display: true)
        controller?.unlockPanelDidChangeFrame()
    }

    /// Space between the pill and the screen's edges (below the menu bar at the top).
    static let edgeMargin: CGFloat = 24

    /// Where the pill goes on a screen for a chosen position. The middle row sits slightly
    /// above the middle; the others keep `edgeMargin` from the edges they're against.
    static func frame(for position: CardPosition, in area: NSRect, topInset: CGFloat,
                      size: NSSize = pillSize) -> NSRect {
        let x: CGFloat = switch position.column {
        case -1: area.minX + edgeMargin
        case 1: area.maxX - edgeMargin - size.width
        default: area.midX - size.width / 2
        }
        let y: CGFloat = switch position.row {
        case 1: area.maxY - topInset - edgeMargin - size.height
        case -1: area.minY + edgeMargin
        default: area.midY - size.height / 2 + area.height * 0.04
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The pill's area on screen, for the input shield's clickable region. Locking reads it
    /// before the pill is on screen, when nothing is laid out yet; without the layout pass the
    /// area is empty and the shield blocks every click on the pill.
    var cardScreenFrame: NSRect {
        contentView?.layoutSubtreeIfNeeded()
        return convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// Where the fingerprint is on screen.
    var touchIDScreenFrame: NSRect {
        contentView?.layoutSubtreeIfNeeded()
        return convertToScreen(touchIDContainer.convert(touchIDContainer.bounds, to: nil))
    }

    /// Where the title, helper line and password row are on screen, at their natural
    /// (unclipped) widths, so tests can check they fit inside the pill.
    var textScreenFrames: [NSRect] {
        card.layoutSubtreeIfNeeded()
        let views: [NSView] = metrics.oneLine ? [titleLabel, passwordRow] : [titleLabel, helperLabel, passwordRow]
        // Alignment rects: a text label's frame has a couple of points of padding around the text.
        return views.map { view in
            let aligned = view.alignmentRect(forFrame: view.frame)
            let intrinsic = view.intrinsicContentSize.width
            let width = max(aligned.width, intrinsic > 0 ? intrinsic : view.fittingSize.width)
            let rect = NSRect(origin: aligned.origin, size: NSSize(width: width, height: aligned.height))
            return convertToScreen(view.superview?.convert(rect, to: nil) ?? rect)
        }
    }

    func focusPasswordField() {
        guard !passwordRow.isHidden else { return }
        makeFirstResponder(passwordField)
    }

    func tearDown() {
        authContext?.invalidate()
        authContext = nil
        throttleTimer?.invalidate()
        feedbackTimer?.invalidate()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// The same as double-clicking the pill.
    func revealPassword() { setPasswordVisible(true) }

    /// A double-click opens the password field. A single click, like a stray tap on the
    /// trackpad, doesn't.
    static func opensPassword(clickCount: Int) -> Bool { clickCount >= 2 }

    #if DEBUG
    func debugShowPassword() { revealPassword() }
    #endif

    /// Swaps the helper line for the password field (or back). The pill doesn't change size.
    private func setPasswordVisible(_ visible: Bool) {
        passwordRow.isHidden = !visible
        // The field takes the helper line's place, or the title's in a one-line pill.
        (metrics.oneLine ? titleLabel : helperLabel).isHidden = visible
        if visible {
            focusPasswordField()
            restartIdleTimer()
        } else {
            idleTimer?.invalidate()
            idleTimer = nil
            passwordField.stringValue = ""
            if metrics.oneLine, isFeedbackInField { hideFeedback() }
            makeFirstResponder(nil)
        }
        refreshTitle()
    }

    /// Starts (or restarts) the open field's idle countdown. Only with Touch ID: without it,
    /// or after a lockout, the field is the only way in and stays open.
    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard touchIDEnabled, !passwordRow.isHidden else { return }
        let timer = Timer(timeInterval: passwordIdleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.passwordFieldWentIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Nothing was typed or clicked for a while: the field closes, clearing anything half
    /// typed, and Touch ID shows again. Not while a password is being checked or a wait after
    /// wrong attempts is running; it tries again later.
    private func passwordFieldWentIdle() {
        guard !passwordRow.isHidden else { return }
        if Self.closesWhenIdle(touchIDEnabled: touchIDEnabled, isVerifying: isVerifying,
                               isWaiting: throttleUntil > Date()) {
            setPasswordVisible(false)
        } else {
            restartIdleTimer() // does nothing without Touch ID, where the field stays open
        }
    }

    /// Whether an idle password field closes now. Never while a password is being checked or
    /// a wait after wrong attempts runs, and never without Touch ID, since it's the only way in.
    static func closesWhenIdle(touchIDEnabled: Bool, isVerifying: Bool, isWaiting: Bool) -> Bool {
        touchIDEnabled && !isVerifying && !isWaiting
    }

    /// How many characters are in the password field (never the characters themselves).
    var typedCharacterCount: Int { passwordField.stringValue.count }

    // MARK: Touch ID

    func armTouchID() {
        // Unit tests never start real Touch ID: a pending evaluation keeps the test host
        // from exiting, and it would ask for the person's finger.
        guard touchIDEnabled, !isEvaluating, !Self.isUnitTesting else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        let view = LAAuthenticationView(context: context, controlSize: metrics.authControlSize)
        authView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        touchIDContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: touchIDContainer.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: touchIDContainer.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: metrics.fingerprint),
            view.heightAnchor.constraint(equalToConstant: metrics.fingerprint),
        ])
        authView = view
        authContext = context
        isEvaluating = true

        Task { @MainActor [weak self] in
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                 localizedReason: "unlock this Mac")
                self?.isEvaluating = false
                self?.controller?.touchIDSucceeded()
            } catch {
                guard let self else { return }
                self.isEvaluating = false
                self.handleTouchIDError(error as? LAError)
            }
        }
    }

    /// What happens when Touch ID fails. Internal so tests can feed it errors without a finger.
    func handleTouchIDError(_ error: LAError?) {
        switch error?.code {
        case .authenticationFailed?:
            controller?.touchIDFailed()
            showFeedback(.touchIDFailed)
            shake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.armTouchID() }
            }
        case .biometryLockout?:
            touchIDLockedOut = true
            showLockSymbol()
            // Open the field first: on Tiny it takes the title's place, so the message has to go
            // inside the field, where it can be seen.
            setPasswordVisible(true)
            showFeedback(.touchIDLocked)
        default:
            // Cancelled because the card lost focus, or similar: re-armed when it's focused again.
            break
        }
    }

    // MARK: Password

    @objc private func submitPassword() {
        let password = passwordField.stringValue
        guard !password.isEmpty, !isVerifying, let controller else { return }
        isVerifying = true
        passwordField.isEnabled = false
        submitButton.isEnabled = false
        Task { @MainActor in
            let result = await controller.submitPassword(password)
            isVerifying = false
            handlePasswordResult(result)
        }
    }

    /// What the pill does with a checked password. Internal so tests can feed it results
    /// without checking a real password.
    func handlePasswordResult(_ result: LockController.PasswordResult) {
        switch result {
        case .success:
            return
        case .failure:
            passwordField.isEnabled = true
            submitButton.isEnabled = true
            passwordField.stringValue = ""
            showFeedback(.wrongPassword)
            shake()
            focusPasswordField()
            restartIdleTimer()
        case .throttled(let until):
            passwordField.stringValue = ""
            shake()
            startThrottleCountdown(until: until)
        }
    }

    /// True while a wait after wrong attempts keeps the password field disabled.
    var isWaitingAfterWrongAttempts: Bool { throttleTimer?.isValid ?? false }

    private func startThrottleCountdown(until: Date) {
        throttleTimer?.invalidate()
        throttleUntil = until
        passwordField.isEnabled = false
        submitButton.isEnabled = false
        throttleTick()
        throttleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.throttleTick() }
        }
    }

    private func throttleTick() {
        let remaining = Int(ceil(throttleUntil.timeIntervalSinceNow))
        guard remaining <= 0 else {
            showFeedback(.wait(seconds: remaining))
            return
        }
        throttleTimer?.invalidate()
        passwordField.isEnabled = true
        submitButton.isEnabled = true
        hideFeedback()
        focusPasswordField()
        restartIdleTimer()
    }

    /// What went wrong, worded to fit the pill: the one-line pill is too narrow for the full wording.
    enum Feedback: Equatable {
        case touchIDFailed, touchIDLocked, wrongPassword
        case wait(seconds: Int)

        func text(oneLine: Bool) -> String {
            switch (self, oneLine) {
            case (.touchIDFailed, false): "Touch ID not recognized"
            case (.touchIDFailed, true): "Not recognized"
            case (.touchIDLocked, false): "Touch ID is locked"
            case (.touchIDLocked, true): "Touch ID locked"
            case (.wrongPassword, false): "Incorrect password"
            case (.wrongPassword, true): "Wrong password"
            case (.wait(let seconds), false): "Try again in \(seconds) s"
            case (.wait(let seconds), true): "Wait \(seconds) s"
            }
        }

        /// The longest each one gets: waits are capped at 5 minutes.
        static let longest: [Feedback] = [.touchIDFailed, .touchIDLocked, .wrongPassword, .wait(seconds: 300)]
    }

    private var titleFeedbackFont: NSFont { .systemFont(ofSize: metrics.titleFont, weight: .semibold) }
    private var fieldFeedbackFont: NSFont { .systemFont(ofSize: metrics.helperFont) }

    /// How wide a piece of feedback is, on the title or inside the empty field, and how much room
    /// that spot has, so tests can check every message fits a one-line pill.
    func feedbackWidth(_ feedback: Feedback, inField: Bool) -> CGFloat {
        let font = inField ? fieldFeedbackFont : titleFeedbackFont
        return ceil((feedback.text(oneLine: metrics.oneLine) as NSString).size(withAttributes: [.font: font]).width)
    }

    func feedbackSpace(inField: Bool) -> CGFloat {
        card.layoutSubtreeIfNeeded()
        if inField, let cell = passwordField.cell {
            return cell.drawingRect(forBounds: passwordField.bounds).width
        }
        // The title can use the whole text column: the pill's width less the fingerprint and insets.
        return metrics.size.width - metrics.leftInset - metrics.fingerprintBox - metrics.spacing - metrics.rightInset
    }

    /// Feedback (wrong password, wait time) briefly takes the title's place, in red.
    private func showFeedback(_ feedback: Feedback, until: Date? = nil) {
        let text = feedback.text(oneLine: metrics.oneLine)
        feedbackTimer?.invalidate()
        if metrics.oneLine && !passwordRow.isHidden {
            // A one-line pill's title is hidden while the field is open; the empty field shows it.
            passwordField.placeholderAttributedString = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.systemRed, .font: fieldFeedbackFont,
            ])
        } else {
            titleFeedback = text
        }
        isShowingFeedback = true
        refreshTitle()
        guard until == nil else { return }
        let timer = Timer(timeInterval: feedbackDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideFeedback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        feedbackTimer = timer
    }

    private func hideFeedback() {
        feedbackTimer?.invalidate()
        isShowingFeedback = false
        titleFeedback = nil
        passwordField.placeholderAttributedString = nil
        passwordField.placeholderString = "Password"
        refreshTitle()
    }

    /// Feedback shown on the title, if any.
    private var titleFeedback: String?
    /// True while the pointer is over the pill.
    private var isPointerInside = false

    /// Tiny has no helper line, so while the pointer is over it the title gives way to a hint
    /// that a double-click opens the password field. Only while the field is closed, and never
    /// over feedback. Hovering never opens anything; the double-click still does.
    static let hoverHint = "Double-click to type"
    private var wantsHoverHint: Bool {
        metrics.oneLine && isPointerInside && passwordRow.isHidden && titleFeedback == nil
    }

    /// What the title line is showing right now.
    enum TitleContent { case title, hint, feedback }
    private(set) var titleContent = TitleContent.title
    var showsHoverHint: Bool { titleContent == .hint }

    /// How wide the hint is in its font, and how much room the title has, so tests can check it fits.
    var hoverHintWidth: CGFloat {
        ceil((Self.hoverHint as NSString).size(withAttributes: [.font: hintFont]).width)
    }

    private var hintFont: NSFont { .systemFont(ofSize: metrics.titleFont) }

    /// Shows feedback, the hover hint or the title, in that order of priority.
    private func refreshTitle() {
        if let titleFeedback {
            titleLabel.stringValue = titleFeedback
            titleLabel.textColor = .systemRed
            titleLabel.font = titleFeedbackFont
            titleContent = .feedback
        } else if wantsHoverHint {
            titleLabel.stringValue = Self.hoverHint
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = hintFont
            titleContent = .hint
        } else {
            titleLabel.stringValue = Self.title
            titleLabel.textColor = .labelColor
            titleLabel.font = titleFeedbackFont
            titleContent = .title
        }
    }

    // MARK: Hover

    /// The pointer moved onto or off the pill. Internal so tests can call them without a mouse.
    func pointerEntered() {
        isPointerInside = true
        refreshTitle()
    }

    func pointerExited() {
        isPointerInside = false
        refreshTitle()
    }

    override func mouseEntered(with event: NSEvent) { pointerEntered() }
    override func mouseExited(with event: NSEvent) { pointerExited() }

    /// Hover is tracked even while Clearlock isn't the active app, which it isn't while locked:
    /// the pill is a non-activating panel so the agents' app stays in front.
    static let hoverTrackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
    var hoverTrackingAreas: [NSTrackingArea] { card.trackingAreas }

    /// True while feedback shows inside the empty password field (one-line pills only).
    var isFeedbackInField: Bool { passwordField.placeholderAttributedString != nil }
    /// False while the password field has taken a one-line pill's title place.
    var showsTitle: Bool { !titleLabel.isHidden }

    /// True while feedback has taken the title's place.
    private(set) var isShowingFeedback = false
    /// How long feedback stays before the title comes back. Tests shorten it.
    var feedbackDuration: TimeInterval = 4

    static let title = "Locked by Clearlock"

    private func shake() {
        guard let layer = card.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -12, 12, -9, 9, -5, 5, 0]
        animation.duration = 0.45
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "shake")
    }

    // MARK: Layout

    private func showLockSymbol() {
        authView?.removeFromSuperview()
        authView = nil
        lockSymbol.isHidden = false
    }

    private func buildContent() {
        // Left: the fingerprint, or a lock symbol on Macs without Touch ID.
        touchIDContainer.translatesAutoresizingMaskIntoConstraints = false
        lockSymbol.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
        lockSymbol.symbolConfiguration = .init(pointSize: metrics.lockSymbol, weight: .semibold)
        lockSymbol.contentTintColor = .secondaryLabelColor
        lockSymbol.translatesAutoresizingMaskIntoConstraints = false
        lockSymbol.isHidden = touchIDEnabled
        touchIDContainer.addSubview(lockSymbol)
        NSLayoutConstraint.activate([
            touchIDContainer.widthAnchor.constraint(equalToConstant: metrics.fingerprintBox),
            touchIDContainer.heightAnchor.constraint(equalToConstant: metrics.fingerprintBox),
            lockSymbol.centerXAnchor.constraint(equalTo: touchIDContainer.centerXAnchor),
            lockSymbol.centerYAnchor.constraint(equalTo: touchIDContainer.centerYAnchor),
        ])

        // Right: title over a helper line, which the password field replaces.
        titleLabel.stringValue = Self.title
        titleLabel.font = .systemFont(ofSize: metrics.titleFont, weight: .semibold)
        titleLabel.textColor = .labelColor

        helperLabel.stringValue = touchIDEnabled ? "Touch ID, or double-click for password" : "Type your password to unlock"
        helperLabel.font = .systemFont(ofSize: metrics.helperFont)
        helperLabel.textColor = .secondaryLabelColor

        passwordField.placeholderString = "Password"
        passwordField.bezelStyle = .roundedBezel
        passwordField.controlSize = metrics.fieldControlSize
        passwordField.font = .systemFont(ofSize: metrics.helperFont)
        passwordField.target = self
        passwordField.action = #selector(submitPassword)
        passwordField.setAccessibilityLabel("Password")

        submitButton.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Unlock")
        submitButton.symbolConfiguration = .init(pointSize: metrics.submitSymbol, weight: .regular)
        submitButton.isBordered = false
        submitButton.contentTintColor = .secondaryLabelColor
        submitButton.target = self
        submitButton.action = #selector(submitPassword)

        passwordRow.setViews([passwordField, submitButton], in: .leading)
        passwordRow.spacing = 6

        // The helper line and the password field share one fixed-height slot. A one-line pill
        // has no helper line: the title and the field share it.
        let detailSlot = NSView()
        detailSlot.translatesAutoresizingMaskIntoConstraints = false
        let slotViews: [NSView] = metrics.oneLine ? [titleLabel, passwordRow] : [helperLabel, passwordRow]
        for view in slotViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailSlot.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: detailSlot.leadingAnchor),
                view.trailingAnchor.constraint(lessThanOrEqualTo: detailSlot.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: detailSlot.centerYAnchor),
            ])
        }
        // On the one-line pill the field and its button fill exactly the title's width, so the
        // pill fits both with no empty glass at the end.
        let fieldWidth = metrics.oneLine
            ? PillSize.oneLineTextWidth - passwordRow.spacing - submitButton.intrinsicContentSize.width
            : metrics.fieldWidth
        NSLayoutConstraint.activate([
            detailSlot.heightAnchor.constraint(equalToConstant: metrics.detailHeight),
            passwordField.widthAnchor.constraint(equalToConstant: fieldWidth),
        ])

        let text = NSStackView(views: metrics.oneLine ? [detailSlot] : [titleLabel, detailSlot])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [touchIDContainer, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = metrics.spacing
        row.edgeInsets = NSEdgeInsets(top: 0, left: metrics.leftInset, bottom: 0, right: metrics.rightInset)
        row.translatesAutoresizingMaskIntoConstraints = false

        // The window is a transparent canvas exactly the pill's size; the glass is the
        // background and the content sits on top of it (never inside its contentView).
        let canvas = NSView()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = metrics.size.height / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(card)
        card.addSubview(glass)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: canvas.topAnchor),
            card.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            card.widthAnchor.constraint(equalToConstant: metrics.size.width),
            card.heightAnchor.constraint(equalToConstant: metrics.size.height),
            glass.topAnchor.constraint(equalTo: card.topAnchor),
            glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor),
        ])
        contentView = canvas
        if metrics.oneLine {
            card.addTrackingArea(NSTrackingArea(rect: .zero, options: Self.hoverTrackingOptions, owner: self, userInfo: nil))
        }
    }
}
