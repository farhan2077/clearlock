import AppKit

/// A borderless window covering one display while locked. It sits above the menu bar
/// and Dock, joins every Space (including full-screen apps), and either catches all
/// clicks or — in automation mode — lets them fall through to the apps beneath.
final class LockOverlayWindow: NSWindow {
    init(screen: NSScreen, dim: Double, passthrough: Bool) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set explicitly so transparent pixels still catch clicks when not in passthrough.
        ignoresMouseEvents = passthrough
        // Keep the dimming out of screenshots that agents take of the screen.
        if passthrough { sharingType = .none }
        contentView = OverlayView(dim: dim)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 1
        }
    }
}

private final class OverlayView: NSView {
    init(dim: Double) {
        super.init(frame: .zero)
        wantsLayer = true
        // The user's dim level darkens the screen. A sliver of alpha remains at 0 % so the
        // window still catches clicks in standard mode.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(max(dim, 0.01)).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    override func mouseDown(with event: NSEvent) {
        LockController.shared.focusPrompt()
    }

    override func rightMouseDown(with event: NSEvent) {
        LockController.shared.focusPrompt()
    }

    override func scrollWheel(with event: NSEvent) {}
}
