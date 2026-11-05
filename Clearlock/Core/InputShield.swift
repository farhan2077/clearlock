import AppKit
import CoreGraphics
import Observation

/// A session event tap that drops physical keyboard, mouse and trackpad input
/// while the Mac is locked. Input posted by other processes (AI agents,
/// automation scripts) carries their process ID and always goes through.
/// Requires Accessibility permission; the tap only exists while locked.
@Observable
final class InputShield {
    struct Counters {
        var blockedPhysical = 0
        var allowedPhysical = 0
        var allowedAutomation = 0
        var blockedAutomation = 0
        var automationSources: [pid_t: Int] = [:]
    }

    private(set) var isRunning = false
    private(set) var counters = Counters()

    /// True while the unlock prompt owns keyboard focus.
    @ObservationIgnored var isPromptFocused: () -> Bool = { false }
    /// Screen areas (global CG coordinates, top-left origin) where physical clicks reach Clearlock.
    @ObservationIgnored var interactiveRects: [CGRect] = []
    /// Called on physical key or click presses that were blocked, so the prompt can take focus.
    @ObservationIgnored var onBlockedPhysicalPress: () -> Void = {}
    /// The app that agents' keystrokes belong to while the prompt holds keyboard focus.
    @ObservationIgnored var automationKeyTarget: () -> pid_t? = { nil }

    /// Marks keystrokes the shield re-posted itself, so they pass straight through.
    static let forwardedMarker: Int64 = 0x4157_4C4B

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private let ownPID = getpid()
    @ObservationIgnored private lazy var windowServerPID = Self.pid(named: "WindowServer")

    // Counter updates are batched so a fast typist doesn't trigger a UI refresh per key.
    @ObservationIgnored private var pending = Counters()
    @ObservationIgnored private var flushScheduled = false

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        var mask: CGEventMask = 0
        for type in Self.blockedTypes { mask |= CGEventMask(1) << CGEventMask(type) }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: shieldCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        counters = Counters()
        pending = Counters()
        isRunning = true
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        isRunning = false
        flush()
    }

    // MARK: Event filtering (runs on the main thread for every input event while locked)

    /// Returns true to let the event through.
    func shouldPass(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.forwardedMarker { return true }

        let sourcePID = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        let isAutomation = Self.isAutomation(sourcePID: sourcePID, ownPID: ownPID, windowServerPID: windowServerPID)
        let context = Context(promptFocused: isPromptFocused(), interactiveRects: interactiveRects)
        let decision = Self.decide(type: type, isAutomation: isAutomation, flags: event.flags,
                                   keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                   location: event.location, context: context)
        switch decision {
        case .pass:
            record {
                if isAutomation {
                    $0.allowedAutomation += 1
                    $0.automationSources[sourcePID, default: 0] += 1
                } else {
                    $0.allowedPhysical += 1
                }
            }
            return true
        case .forwardToAgentApp:
            guard let target = automationKeyTarget(), let copy = event.copy() else {
                record { $0.blockedAutomation += 1 }
                return false
            }
            copy.setIntegerValueField(.eventSourceUserData, value: Self.forwardedMarker)
            copy.postToPid(target)
            record {
                $0.allowedAutomation += 1
                $0.automationSources[sourcePID, default: 0] += 1
            }
            return false
        case .block:
            if !isAutomation && Self.isPress(type) { onBlockedPhysicalPress() }
            record { isAutomation ? ($0.blockedAutomation += 1) : ($0.blockedPhysical += 1) }
            return false
        }
    }

    // MARK: Decisions (pure, so they can be unit tested)

    enum Decision: Equatable {
        case pass
        case block
        /// An agent's keystroke while the unlock card has focus: deliver it to the agent's app.
        case forwardToAgentApp
    }

    struct Context {
        var promptFocused: Bool
        var interactiveRects: [CGRect]
    }

    /// Hardware input arrives from the kernel (PID 0) or WindowServer; anything posted
    /// by another process carries that process's ID.
    static func isAutomation(sourcePID: pid_t, ownPID: pid_t, windowServerPID: pid_t) -> Bool {
        sourcePID != 0 && sourcePID != ownPID && sourcePID != windowServerPID
    }

    static func decide(type: CGEventType, isAutomation: Bool, flags: CGEventFlags, keyCode: Int64,
                       location: CGPoint, context: Context) -> Decision {
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        if isAutomation {
            // While the card holds focus, an agent's keystrokes would land in the password field.
            return isKeyboard && context.promptFocused ? .forwardToAgentApp : .pass
        }
        if isKeyboard {
            guard context.promptFocused else { return .block }
            guard type == .keyDown || type == .keyUp else { return .pass }
            if flags.contains(.maskControl) { return .block }
            if flags.contains(.maskCommand) {
                // Only the editing shortcuts the password field needs (⌘A ⌘X ⌘C ⌘V ⌘Z).
                return [0, 7, 8, 9, 6].contains(keyCode) ? .pass : .block
            }
            return .pass
        }
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return context.interactiveRects.contains { $0.contains(location) } ? .pass : .block
        default:
            // Scrolling, gestures, media and system keys are always blocked.
            return .block
        }
    }

    private static func isPress(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private func record(_ change: (inout Counters) -> Void) {
        change(&pending)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        var c = counters
        c.blockedPhysical += pending.blockedPhysical
        c.allowedPhysical += pending.allowedPhysical
        c.allowedAutomation += pending.allowedAutomation
        c.blockedAutomation += pending.blockedAutomation
        c.automationSources.merge(pending.automationSources, uniquingKeysWith: +)
        counters = c
        pending = Counters()
    }

    // MARK: Helpers

    private static let blockedTypes: [UInt32] = [
        CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
        CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue, CGEventType.leftMouseDragged.rawValue,
        CGEventType.rightMouseDown.rawValue, CGEventType.rightMouseUp.rawValue, CGEventType.rightMouseDragged.rawValue,
        CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue, CGEventType.otherMouseDragged.rawValue,
        CGEventType.scrollWheel.rawValue, CGEventType.tabletPointer.rawValue, CGEventType.tabletProximity.rawValue,
        14,                 // NSEventTypeSystemDefined: media, brightness, Mission Control keys
        18, 19, 20,         // rotate, begin/end gesture
        29, 30, 31, 32, 34, // gesture, magnify, swipe, smart magnify, pressure
    ]

    static func pid(named name: String) -> pid_t {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return -1 }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0,
               String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == name {
                return pid
            }
        }
        return -1
    }
}

private nonisolated func shieldCallback(_: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                        _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let address = UInt(bitPattern: userInfo)
    // The tap's run loop source is attached to the main run loop, so this is already
    // on the main thread; the event never leaves it.
    nonisolated(unsafe) let mainThreadEvent = event
    let pass = MainActor.assumeIsolated {
        Unmanaged<InputShield>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
            .shouldPass(type, mainThreadEvent)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
