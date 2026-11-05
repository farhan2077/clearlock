import AppKit
import Carbon.HIToolbox
import Testing
@testable import Clearlock

@Suite("Global shortcuts")
struct ShortcutTests {
    private func keyEvent(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test("The default lock shortcut is ⇧⌘L")
    func defaultLockShortcut() {
        #expect(Shortcut.defaultLock.keyCode == UInt32(kVK_ANSI_L))
        #expect(Shortcut.defaultLock.modifierFlags == [.command, .shift])
        #expect(Shortcut.defaultLock.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("Modifiers map one-to-one onto Carbon hotkey modifiers")
    func carbonModifierMapping() {
        let all = Shortcut(keyCode: 0, modifiers: [.command, .option, .control, .shift], key: "A")
        #expect(all.carbonModifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        let none = Shortcut(keyCode: 0, modifiers: [], key: "A")
        #expect(none.carbonModifiers == 0)
    }

    @Test("Modifier symbols follow Apple's order ⌃⌥⇧⌘")
    func modifierOrder() {
        let shortcut = Shortcut(keyCode: 40, modifiers: [.command, .shift, .option, .control], key: "K")
        #expect(shortcut.displayString == "⌃⌥⇧⌘K")
    }

    @Test("Recording needs ⌘, ⌥ or ⌃ so plain typing can never trigger a lock")
    func recordingRequiresARealModifier() {
        #expect(Shortcut(event: keyEvent("l", keyCode: kVK_ANSI_L, modifiers: [])) == nil)
        #expect(Shortcut(event: keyEvent("L", keyCode: kVK_ANSI_L, modifiers: [.shift])) == nil)
        let recorded = Shortcut(event: keyEvent("l", keyCode: kVK_ANSI_L, modifiers: [.command, .shift]))
        #expect(recorded == .defaultLock)
    }

    @Test("Any of ⌘, ⌥ or ⌃ is enough, with or without ⇧")
    func modifierCombinationsAccepted() {
        let combos: [NSEvent.ModifierFlags] = [[.option], [.control], [.command], [.control, .shift], [.option, .shift, .command]]
        for flags in combos {
            let recorded = Shortcut(event: keyEvent("k", keyCode: kVK_ANSI_K, modifiers: flags))
            #expect(recorded?.modifierFlags == flags)
        }
    }

    @Test("Caps Lock and the Fn key are ignored when recording")
    func lockAndFnKeysIgnored() {
        let recorded = Shortcut(event: keyEvent("l", keyCode: kVK_ANSI_L, modifiers: [.command, .shift, .capsLock, .function]))
        #expect(recorded == .defaultLock)
    }

    @Test("Shortcuts with letters show their key next to the menu item")
    func menuKeyEquivalent() {
        #expect(Shortcut.defaultLock.menuKeyEquivalent == "l")
    }

    @Test("Function keys are recorded by name")
    func functionKeys() {
        let recorded = Shortcut(event: keyEvent("\u{F708}", keyCode: kVK_F5, modifiers: [.control]))
        #expect(recorded?.key == "F5")
        #expect(recorded?.menuKeyEquivalent == "")
    }

    @Test("Shortcuts survive encoding, as they're stored in settings")
    func codableRoundTrip() throws {
        let shortcut = Shortcut(keyCode: 40, modifiers: [.control, .option], key: "K")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
    }

    @Test("A reset to ⇧⌘L is offered once the shortcut is changed or cleared, never while it's the default")
    func resetOffered() {
        let custom = Shortcut(keyCode: 40, modifiers: [.control, .option], key: "K")
        #expect(!ShortcutRecorder.showsReset(current: .defaultLock, default: .defaultLock))
        #expect(ShortcutRecorder.showsReset(current: custom, default: .defaultLock))
        #expect(ShortcutRecorder.showsReset(current: nil, default: .defaultLock))
    }

    @Test("Resetting brings back exactly the default shortcut, and it survives a relaunch")
    func resetRestoresDefault() {
        let suite = IsolatedDefaults()
        let prefs = Preferences(store: suite.defaults)
        prefs.lockShortcut = nil
        #expect(Preferences(store: suite.defaults).lockShortcut == nil)

        prefs.lockShortcut = .defaultLock // what the reset button does
        #expect(Preferences(store: suite.defaults).lockShortcut == .defaultLock)
        #expect(!ShortcutRecorder.showsReset(current: prefs.lockShortcut, default: .defaultLock))
    }

}
