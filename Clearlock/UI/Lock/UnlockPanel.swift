import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// The lock screen's Liquid Glass pill: the Touch ID fingerprint on the left, "Locked by
/// Clearlock" and a helper line on the right. Touch ID runs inside the pill
/// (LAAuthenticationView) instead of a system sheet, so it can never be hidden behind the
/// lock windows. Typing, or clicking the pill, swaps the helper line for the password field;
/// the pill itself never changes size.
final class UnlockPanel: NSPanel {
    private weak var controller: LockController?

    static let pillSize = NSSize(width: 360, height: 72)

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

    /// What the card shows. Tests pass explicit values instead of the user's settings.
    struct Options {
        /// Touch ID is always used when the Mac has it; there's no setting to turn it off.
        var touchIDAvailable: Bool
        var position: CardPosition = .center

        static var current: Options {
            Options(touchIDAvailable: Authenticator.isTouchIDAvailable, position: Preferences.shared.cardPosition)
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
        super.init(contentRect: NSRect(origin: .zero, size: Self.pillSize),
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
        case .keyDown where passwordRow.isHidden && Self.startsTyping(event):
            // Typing while only Touch ID is showing opens the password field and keeps the keystroke.
            setPasswordVisible(true)
        case .keyDown where event.keyCode == 53 && !passwordRow.isHidden && passwordField.stringValue.isEmpty && touchIDEnabled:
            // Escape on an empty field goes back to Touch ID.
            setPasswordVisible(false)
            return
        case .leftMouseDown where passwordRow.isHidden:
            // Clicking the pill is the mouse way to type a password.
            setPasswordVisible(true)
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
        setFrame(Self.frame(for: options.position, in: screen.frame, topInset: topInset), display: true)
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

    /// The pill's area on screen, for the input shield's clickable region.
    var cardScreenFrame: NSRect {
        convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// Where the fingerprint is on screen.
    var touchIDScreenFrame: NSRect {
        convertToScreen(touchIDContainer.convert(touchIDContainer.bounds, to: nil))
    }

    /// Where the title, helper line and password row are on screen, at their natural
    /// (unclipped) widths, so tests can check they fit inside the pill.
    var textScreenFrames: [NSRect] {
        card.layoutSubtreeIfNeeded()
        return [titleLabel, helperLabel, passwordRow].map { view in
            let frame = view.convert(view.bounds, to: nil)
            let natural = NSRect(origin: frame.origin,
                                 size: NSSize(width: max(frame.width, view.fittingSize.width), height: frame.height))
            return convertToScreen(natural)
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
    }

    /// The same as clicking the pill.
    func revealPassword() { setPasswordVisible(true) }

    #if DEBUG
    func debugShowPassword() { revealPassword() }
    #endif

    /// Swaps the helper line for the password field (or back). The pill doesn't change size.
    private func setPasswordVisible(_ visible: Bool) {
        passwordRow.isHidden = !visible
        helperLabel.isHidden = visible
        if visible {
            focusPasswordField()
        } else {
            passwordField.stringValue = ""
            makeFirstResponder(nil)
        }
    }

    /// Whether a key press means someone started typing a password (so the field appears).
    static func startsTyping(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return false }
        if event.keyCode == 36 || event.keyCode == 76 { return true } // Return, Enter
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && scalar.value < 0xF700 // excludes arrows and F-keys
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
        let view = LAAuthenticationView(context: context, controlSize: .large)
        authView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        touchIDContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: touchIDContainer.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: touchIDContainer.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 38),
            view.heightAnchor.constraint(equalToConstant: 38),
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
            showFeedback("Touch ID not recognized")
            shake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.armTouchID() }
            }
        case .biometryLockout?:
            touchIDLockedOut = true
            showLockSymbol()
            showFeedback("Touch ID is locked")
            setPasswordVisible(true)
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
            switch result {
            case .success:
                return
            case .failure:
                passwordField.isEnabled = true
                submitButton.isEnabled = true
                passwordField.stringValue = ""
                showFeedback("Incorrect password")
                shake()
                focusPasswordField()
            case .throttled(let until):
                passwordField.stringValue = ""
                shake()
                startThrottleCountdown(until: until)
            }
        }
    }

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
            showFeedback("Try again in \(remaining) s")
            return
        }
        throttleTimer?.invalidate()
        passwordField.isEnabled = true
        submitButton.isEnabled = true
        hideFeedback()
        focusPasswordField()
    }

    /// Feedback (wrong password, wait time) briefly takes the title's place, in red.
    private func showFeedback(_ text: String, until: Date? = nil) {
        feedbackTimer?.invalidate()
        titleLabel.stringValue = text
        titleLabel.textColor = .systemRed
        isShowingFeedback = true
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
        titleLabel.stringValue = Self.title
        titleLabel.textColor = .labelColor
    }

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
        lockSymbol.symbolConfiguration = .init(pointSize: 21, weight: .semibold)
        lockSymbol.contentTintColor = .secondaryLabelColor
        lockSymbol.translatesAutoresizingMaskIntoConstraints = false
        lockSymbol.isHidden = touchIDEnabled
        touchIDContainer.addSubview(lockSymbol)
        NSLayoutConstraint.activate([
            touchIDContainer.widthAnchor.constraint(equalToConstant: 44),
            touchIDContainer.heightAnchor.constraint(equalToConstant: 44),
            lockSymbol.centerXAnchor.constraint(equalTo: touchIDContainer.centerXAnchor),
            lockSymbol.centerYAnchor.constraint(equalTo: touchIDContainer.centerYAnchor),
        ])

        // Right: title over a helper line, which the password field replaces.
        titleLabel.stringValue = Self.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        helperLabel.stringValue = touchIDEnabled ? "Touch ID or start typing your password" : "Type your password to unlock"
        helperLabel.font = .systemFont(ofSize: 12)
        helperLabel.textColor = .secondaryLabelColor

        passwordField.placeholderString = "Password"
        passwordField.bezelStyle = .roundedBezel
        passwordField.controlSize = .regular
        passwordField.font = .systemFont(ofSize: 12)
        passwordField.target = self
        passwordField.action = #selector(submitPassword)
        passwordField.setAccessibilityLabel("Password")

        submitButton.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Unlock")
        submitButton.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        submitButton.isBordered = false
        submitButton.contentTintColor = .secondaryLabelColor
        submitButton.target = self
        submitButton.action = #selector(submitPassword)

        passwordRow.setViews([passwordField, submitButton], in: .leading)
        passwordRow.spacing = 6

        // The helper line and the password field share one fixed-height slot.
        let detailSlot = NSView()
        detailSlot.translatesAutoresizingMaskIntoConstraints = false
        for view in [helperLabel, passwordRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailSlot.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: detailSlot.leadingAnchor),
                view.trailingAnchor.constraint(lessThanOrEqualTo: detailSlot.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: detailSlot.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            detailSlot.heightAnchor.constraint(equalToConstant: 22),
            passwordField.widthAnchor.constraint(equalToConstant: 200),
        ])

        let text = NSStackView(views: [titleLabel, detailSlot])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [touchIDContainer, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 24)
        row.translatesAutoresizingMaskIntoConstraints = false

        // The window is a transparent canvas exactly the pill's size; the glass is the
        // background and the content sits on top of it (never inside its contentView).
        let canvas = NSView()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.pillSize.height / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(card)
        card.addSubview(glass)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: canvas.topAnchor),
            card.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            card.widthAnchor.constraint(equalToConstant: Self.pillSize.width),
            card.heightAnchor.constraint(equalToConstant: Self.pillSize.height),
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
    }
}
