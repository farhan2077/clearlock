import AppKit
import Carbon.HIToolbox
import Observation

/// A global keyboard shortcut (virtual key code + modifiers).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt          // NSEvent.ModifierFlags raw value (device-independent bits only)
    var key: String              // Display name of the key, e.g. "L" or "F5"

    static let defaultLock = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command, .shift], key: "L")

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // Require at least one non-shift modifier so plain typing can never trigger it.
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let name = Self.specialKeys[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags, key: name)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        let f = modifierFlags
        return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "")
            + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + key
    }

    var carbonModifiers: UInt32 {
        let f = modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Key equivalent for showing the shortcut next to a menu item (letters/digits only).
    var menuKeyEquivalent: String { key.count == 1 ? key.lowercased() : "" }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
    ]
}

/// Registers system-wide hotkeys through Carbon's RegisterEventHotKey, which needs
/// no permissions and costs nothing until a key is pressed.
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Action: UInt32 { case lock = 1 }

    @ObservationIgnored private var refs: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlers: [Action: () -> Void] = [:]
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    private(set) var failures: Set<Action> = []

    private init() {}

    /// Returns false if another app already owns this shortcut.
    @discardableResult
    func register(_ action: Action, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(action)
        handlers[action] = handler
        failures.remove(action)
        guard let shortcut else { return true }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4157_4C4B), id: action.rawValue) // 'AWLK'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failures.insert(action)
            return false
        }
        refs[action] = ref
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    /// Temporarily releases all hotkeys, e.g. while the user records a new shortcut.
    func suspend() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        handlers[action]?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handlerRef)
    }
}

private nonisolated func hotKeyCallback(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    // Carbon delivers application events on the main thread.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(id.id) }
    return noErr
}
