import AppKit
import Carbon.HIToolbox
import CoreGraphics
import LocalAuthentication
import Testing
@testable import Clearlock

/// Decisions that had no test of their own: what the updater downloads, which kinds of input
/// the shield handles, the Edit menu behind the password field, and settings fallbacks.
@Suite("Updates: what gets downloaded and when it installs")
struct UpdateAssetTests {
    private func release(tag: String, assets: [String], body: String? = "Notes") -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","size":1000,"browser_download_url":"https://example.com/\#($0)"}"#
        }.joined(separator: ",")
        let notes = body.map { #""body":"\#($0)","# } ?? ""
        return Data(#"{"tag_name":"\#(tag)",\#(notes)"html_url":"https://example.com/r","assets":[\#(list)]}"#.utf8)
    }

    @Test("Every release carries a .dmg and a .zip; the updater always takes the .zip, whatever the order")
    func picksZipOverDMG() throws {
        for assets in [["Clearlock-1.2.0.dmg", "Clearlock-1.2.0.zip"], ["Clearlock-1.2.0.zip", "Clearlock-1.2.0.dmg"]] {
            let check = try Updater.evaluate(release(tag: "v1.2.0", assets: assets), currentVersion: "1.0.0")
            guard case .available(let update) = check else {
                Issue.record("Expected an update, got \(check)")
                continue
            }
            #expect(update.asset.pathExtension == "zip")
        }
    }

    @Test("A newer release with only the .dmg is reported, never downloaded as the update")
    func dmgAloneIsAnError() {
        #expect(throws: Updater.UpdateError.self) {
            try Updater.evaluate(release(tag: "v1.2.0", assets: ["Clearlock-1.2.0.dmg"]), currentVersion: "1.0.0")
        }
    }

    @Test("A capital V tag counts too, and a release without notes still offers the update")
    func tagAndNotesVariants() throws {
        let check = try Updater.evaluate(release(tag: "V1.0.3", assets: ["Clearlock-1.0.3.zip"], body: nil),
                                         currentVersion: "1.0.2")
        guard case .available(let update) = check else {
            Issue.record("Expected an update, got \(check)")
            return
        }
        #expect(update.version == "1.0.3")
        #expect(update.notes.isEmpty)
    }

    @Test("Patch and two-digit versions compare as numbers")
    func patchVersions() {
        #expect(Updater.isVersion("1.0.3", newerThan: "1.0.2"))
        #expect(Updater.isVersion("1.0.10", newerThan: "1.0.9"))
        #expect(Updater.isVersion("10.0.0", newerThan: "9.9.9"))
        #expect(!Updater.isVersion("1.0.9", newerThan: "1.0.10"))
    }

    @Test("A response that isn't a release is an error, not an update")
    func malformedResponse() {
        #expect(throws: (any Error).self) { try Updater.evaluate(Data("{}".utf8), currentVersion: "1.0.0") }
        #expect(throws: (any Error).self) { try Updater.evaluate(Data("not json".utf8), currentVersion: "1.0.0") }
    }

    @Test("An update never installs while locked, since installing quits Clearlock")
    func noInstallWhileLocked() {
        #expect(!Updater.canInstall(isLocked: true))
        #expect(Updater.canInstall(isLocked: false))
    }
}

@Suite("Input shield: every kind of input")
struct InputShieldKindsTests {
    private let card = CGRect(x: 500, y: 300, width: 340, height: 300)

    /// Event types with no Swift case (media keys, gestures) still arrive from the tap.
    private func type(_ raw: UInt32) -> CGEventType {
        CGEventType(rawValue: raw) ?? unsafeBitCast(raw, to: CGEventType.self)
    }

    private func decide(_ type: CGEventType, automation: Bool, focused: Bool = true,
                        at location: CGPoint = CGPoint(x: 600, y: 400)) -> InputShield.Decision {
        InputShield.decide(type: type, isAutomation: automation, flags: [], keyCode: 0, location: location,
                           context: .init(promptFocused: focused, interactiveRects: [card]))
    }

    /// Media and brightness keys (14), rotate and gesture phases (18–20), gestures, magnify,
    /// swipe, smart magnify and pressure (29–32, 34).
    nonisolated static let systemAndGestureTypes: [UInt32] = [14, 18, 19, 20, 29, 30, 31, 32, 34]

    @Test("Media keys, Mission Control keys and trackpad gestures from hands are blocked, even on the card",
          arguments: systemAndGestureTypes)
    func handsGesturesBlocked(raw: UInt32) {
        #expect(decide(type(raw), automation: false) == .block)
    }

    @Test("The same media keys and gestures from agents go through", arguments: systemAndGestureTypes)
    func agentGesturesPass(raw: UInt32) {
        #expect(decide(type(raw), automation: true, focused: false) == .pass)
    }

    @Test("The shield watches every kind of keyboard, mouse, trackpad and tablet input")
    func tapCoversEveryInput() {
        let watched = Set(InputShield.blockedTypes)
        let keyboard: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mouse: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let other: [CGEventType] = [.scrollWheel, .tabletPointer, .tabletProximity]
        for kind in keyboard + mouse + other {
            #expect(watched.contains(kind.rawValue))
        }
        for raw in Self.systemAndGestureTypes {
            #expect(watched.contains(raw))
        }
        // Moving the pointer is never blocked, so the cursor can still reach the card.
        #expect(!watched.contains(CGEventType.mouseMoved.rawValue))
    }

    @Test("Physical right and middle clicks reach only the card, like left clicks")
    func otherButtonsOnlyOnCard() {
        for kind: CGEventType in [.rightMouseUp, .rightMouseDragged, .otherMouseUp, .otherMouseDragged] {
            #expect(decide(kind, automation: false, focused: false, at: CGPoint(x: 600, y: 400)) == .pass)
            #expect(decide(kind, automation: false, focused: false, at: CGPoint(x: 5, y: 5)) == .block)
        }
    }

    @Test("⌘⇧Z (redo) in the password field is allowed; ⌘W, ⌘H and ⌘M are not")
    func editingShortcutsWithShift() {
        func key(_ code: Int64, _ flags: CGEventFlags) -> InputShield.Decision {
            InputShield.decide(type: .keyDown, isAutomation: false, flags: flags, keyCode: code, location: .zero,
                               context: .init(promptFocused: true, interactiveRects: [card]))
        }
        #expect(key(6, [.maskCommand, .maskShift]) == .pass)                   // ⌘⇧Z
        for code: Int64 in [13, 4, 46] { #expect(key(code, .maskCommand) == .block) } // ⌘W ⌘H ⌘M
        #expect(key(0, .maskShift) == .pass)                                    // a capital letter
    }
}

@Suite("Input shield events: presses, releases and the tap itself", .serialized)
struct InputShieldPressTests {
    private func mouse(_ type: CGEventType, at point: CGPoint, from pid: Int64) -> CGEvent {
        let button: CGMouseButton = switch type {
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        default: .left
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        return event
    }

    private func makeShield() -> InputShield {
        let shield = InputShield()
        shield.isPromptFocused = { false }
        shield.interactiveRects = [CGRect(x: 500, y: 300, width: 340, height: 300)]
        shield.automationKeyTarget = { nil }
        return shield
    }

    @Test("Right and middle clicks bring the card back too; releases and drags don't")
    func onlyPressesSummonCard() {
        let shield = makeShield()
        var summoned = 0
        shield.onBlockedPhysicalPress = { summoned += 1 }
        let outside = CGPoint(x: 5, y: 5)
        for type: CGEventType in [.rightMouseDown, .otherMouseDown] {
            #expect(!shield.shouldPass(type, mouse(type, at: outside, from: 0)))
        }
        #expect(summoned == 2)
        for type: CGEventType in [.leftMouseUp, .leftMouseDragged, .rightMouseUp] {
            #expect(!shield.shouldPass(type, mouse(type, at: outside, from: 0)))
        }
        #expect(summoned == 2)
    }

    @Test("If macOS pauses the tap, its notice passes through instead of being swallowed")
    func tapNoticesPass() {
        let shield = makeShield()
        let event = CGEvent(source: nil)!
        #expect(shield.shouldPass(.tapDisabledByTimeout, event))
        #expect(shield.shouldPass(.tapDisabledByUserInput, event))
    }
}

/// Cards are built off-screen (fully transparent); nothing is locked and real Touch ID never runs.
@Suite("Unlock card: levels and keys", .serialized)
struct UnlockCardKeyTests {
    private func makeCard(touchID: Bool = true) -> UnlockPanel {
        let card = UnlockPanel(controller: LockController.shared, options: .init(touchIDAvailable: touchID))
        card.alphaValue = 0
        card.present(on: NSScreen.main ?? NSScreen.screens[0])
        card.orderFrontRegardless()
        return card
    }

    private func close(_ card: UnlockPanel) {
        card.tearDown()
        card.orderOut(nil)
    }

    private func key(_ characters: String, _ keyCode: Int, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test("The card sits exactly one level above the overlay and is never a floating panel")
    func exactLevels() {
        let card = makeCard()
        defer { close(card) }
        #expect(card.level.rawValue == NSWindow.Level.screenSaver.rawValue + 1)
        #expect(!card.isFloatingPanel)
        #expect(!card.hidesOnDeactivate)
        #expect(!card.canBecomeMain)
    }

    @Test("Without Touch ID, Escape keeps the password field, since there's nothing to go back to")
    func escapeWithoutTouchID() {
        let card = makeCard(touchID: false)
        defer { close(card) }
        card.sendEvent(key("\u{1B}", kVK_Escape, in: card))
        #expect(card.isPasswordVisible)
    }

    @Test("After a Touch ID lockout, Escape keeps the password field")
    func escapeAfterLockout() {
        let card = makeCard()
        defer { close(card) }
        card.handleTouchIDError(LAError(.biometryLockout))
        card.sendEvent(key("\u{1B}", kVK_Escape, in: card))
        #expect(card.isPasswordVisible)
        #expect(card.showsLockSymbol)
    }

    @Test("Return on the Touch ID card opens the password field")
    func returnOpensPassword() {
        let card = makeCard()
        defer { close(card) }
        card.sendEvent(key("\r", kVK_Return, in: card))
        #expect(card.isPasswordVisible)
    }

    @Test("After Escape goes back to Touch ID, typing opens the field again and keeps the keystroke")
    func escapeThenTypeAgain() {
        let card = makeCard()
        defer { close(card) }
        card.revealPassword()
        card.sendEvent(key("\u{1B}", kVK_Escape, in: card))
        #expect(!card.isPasswordVisible)
        card.sendEvent(key("b", kVK_ANSI_B, in: card))
        #expect(card.isPasswordVisible)
        #expect(card.typedCharacterCount == 1)
    }
}

@Suite("Lock overlay")
struct LockOverlayTests {
    @Test("Each overlay covers its whole display, above the menu bar and Dock, in every Space and full-screen app",
          arguments: [false, true])
    func coversDisplay(passthrough: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let overlay = LockOverlayWindow(screen: screen, dim: 0.3, passthrough: passthrough)
        #expect(overlay.frame == screen.frame)
        #expect(overlay.level == .screenSaver)
        #expect(overlay.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(overlay.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(overlay.collectionBehavior.contains(.stationary))
        #expect(overlay.collectionBehavior.contains(.ignoresCycle))
    }

    @Test("A darker setting always gives a darker screen, up to the 90% limit")
    func dimIsMonotonic() throws {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var previous: CGFloat = 0
        for dim in stride(from: 0.0, through: 0.9, by: 0.1) {
            let alpha = try #require(LockOverlayWindow(screen: screen, dim: dim, passthrough: false)
                .contentView?.layer?.backgroundColor?.alpha)
            #expect(alpha >= previous)
            #expect(alpha <= 0.9 + 0.001)
            previous = alpha
        }
    }
}

@Suite("Main menu")
struct MainMenuTests {
    private func item(_ action: String, in menu: NSMenu) -> NSMenuItem? {
        for top in menu.items {
            if let found = top.submenu?.items.first(where: { $0.action.map(NSStringFromSelector) == action }) { return found }
        }
        return nil
    }

    @Test("The hidden Edit menu makes paste, copy, cut, select all and undo work in the password field")
    func editCommandsExist() throws {
        let menu = AppDelegate.makeMainMenu()
        for (action, key) in [("paste:", "v"), ("copy:", "c"), ("cut:", "x"), ("selectAll:", "a"), ("undo:", "z")] {
            let found = try #require(item(action, in: menu))
            #expect(found.keyEquivalent == key)
            #expect(found.keyEquivalentModifierMask == .command)
        }
        #expect(try #require(item("redo:", in: menu)).keyEquivalentModifierMask == [.command, .shift])
    }

    @Test("The hidden main menu's About opens the same About window as the menu bar")
    func aboutItem() throws {
        let menu = AppDelegate.makeMainMenu()
        let about = try #require(item("showAbout:", in: menu))
        #expect(about.action == #selector(AppDelegate.showAbout(_:)))
        // ⌘Q goes through terminate, which is refused while locked.
        #expect(try #require(item("terminate:", in: menu)).keyEquivalent == "q")
    }
}

@Suite("Settings fallbacks")
struct SettingsFallbackTests {
    @Test("An unknown saved lock color falls back to orange")
    func unknownTint() {
        let suite = IsolatedDefaults()
        suite.defaults.set("chartreuse", forKey: "tint")
        #expect(Preferences(store: suite.defaults).tint == .orange)
    }

    @Test("Every lock color survives a relaunch", arguments: LockTint.allCases)
    func tintRoundTrip(tint: LockTint) {
        let suite = IsolatedDefaults()
        Preferences(store: suite.defaults).tint = tint
        #expect(Preferences(store: suite.defaults).tint == tint)
    }

    @Test("Every pill position survives a relaunch", arguments: CardPosition.allCases)
    func positionRoundTrip(position: CardPosition) {
        let suite = IsolatedDefaults()
        Preferences(store: suite.defaults).cardPosition = position
        #expect(Preferences(store: suite.defaults).cardPosition == position)
    }

    @Test("The last update check is remembered, so automatic checks stay about a day apart")
    func lastUpdateCheckPersists() {
        let suite = IsolatedDefaults()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Preferences(store: suite.defaults).lastUpdateCheck == nil)
        Preferences(store: suite.defaults).lastUpdateCheck = when
        #expect(Preferences(store: suite.defaults).lastUpdateCheck == when)
    }

    @Test("The dim slider's ends are kept exactly: 0% and 90%")
    func dimBounds() {
        let suite = IsolatedDefaults()
        for level in [0.0, 0.9] {
            Preferences(store: suite.defaults).dimLevel = level
            #expect(Preferences(store: suite.defaults).dimLevel == level)
        }
    }

    @Test("Seven lock colors, orange first")
    func tintChoices() {
        #expect(LockTint.allCases.count == 7)
        #expect(LockTint.allCases.first == .orange)
    }
}

@Suite("Shortcut keys by name")
struct ShortcutNameTests {
    private func record(_ characters: String, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [.command]) -> Shortcut? {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false,
                                     keyCode: UInt16(keyCode))!
        return Shortcut(event: event)
    }

    @Test("Space, Return and the arrows can be shortcut keys, recorded by name rather than as invisible characters")
    func specialKeys() {
        for (chars, code) in [(" ", kVK_Space), ("\r", kVK_Return), ("\u{F700}", kVK_UpArrow), ("\u{F702}", kVK_LeftArrow)] {
            let shortcut = record(chars, code)
            #expect(shortcut?.key.isEmpty == false)
            #expect(shortcut?.key.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } == false)
            #expect(shortcut?.key != chars)
        }
        #expect(record(" ", kVK_Space)?.menuKeyEquivalent == "")
    }

    @Test("Digits work as shortcut keys and show next to the menu item")
    func digitKey() {
        let shortcut = record("1", kVK_ANSI_1, [.control, .option])
        #expect(shortcut?.key == "1")
        #expect(shortcut?.menuKeyEquivalent == "1")
    }
}

@Suite("Lid sleep is restored whenever Clearlock stops using it")
struct LidReleaseTests {
    private final class FakePmset {
        var calls: [Bool] = []
        var succeeds = true
        func run(_ disable: Bool) -> Bool {
            calls.append(disable)
            return succeeds
        }
    }

    @Test("Unlocking or quitting turns lid sleep back on and forgets it was off")
    func releaseRestores() {
        let suite = IsolatedDefaults()
        suite.defaults.set(true, forKey: LidSleepManager.engagedKey)
        let pmset = FakePmset()
        let manager = LidSleepManager(store: suite.defaults, pmset: pmset.run)
        manager.release()
        #expect(pmset.calls == [false])
        #expect(!manager.isEngaged)
        #expect(!suite.defaults.bool(forKey: LidSleepManager.engagedKey))
    }

    @Test("When lid sleep was never turned off, unlocking and quitting leave pmset alone")
    func releaseWhenNotEngaged() {
        let suite = IsolatedDefaults()
        let pmset = FakePmset()
        let manager = LidSleepManager(store: suite.defaults, pmset: pmset.run)
        manager.release()
        manager.release()
        #expect(pmset.calls.isEmpty)
    }

    @Test("If turning lid sleep back on fails, it's still remembered as off, so it's retried")
    func failedReleaseIsRemembered() {
        let suite = IsolatedDefaults()
        suite.defaults.set(true, forKey: LidSleepManager.engagedKey)
        let pmset = FakePmset()
        pmset.succeeds = false
        let manager = LidSleepManager(store: suite.defaults, pmset: pmset.run)
        manager.release()
        #expect(manager.isEngaged)
        pmset.succeeds = true
        manager.release()
        #expect(!manager.isEngaged)
        #expect(pmset.calls == [false, false])
    }
}

@Suite("Identity of the test bundle and measurements")
struct TestBundleIdentityTests {
    private final class Token {}

    @Test("The test bundle keeps its own ID, separate from the app's")
    func testBundleID() {
        #expect(Bundle(for: Token.self).bundleIdentifier == "com.farhan2077.clearlock.tests")
    }

    @Test("Two readings taken at the same moment never give infinite or negative rates")
    func sameMomentReadings() {
        let now = Date(timeIntervalSince1970: 1000)
        let a = ResourceSample.Raw(date: now, cpuNanos: 5, wakeups: 5, energyNanojoules: 5, footprint: 1)
        let sample = ResourceSample.between(a, a)
        #expect(sample.cpuPercent.isFinite && sample.cpuPercent >= 0)
        #expect(sample.wakeupsPerSecond.isFinite && sample.wakeupsPerSecond >= 0)
    }

    @Test("Energy that went backwards (a counter reset) is unknown, not negative")
    func energyReset() {
        let start = Date(timeIntervalSince1970: 1000)
        let a = ResourceSample.Raw(date: start, cpuNanos: 0, wakeups: 0, energyNanojoules: 9_000, footprint: 1)
        let b = ResourceSample.Raw(date: start.addingTimeInterval(1), cpuNanos: 0, wakeups: 0, energyNanojoules: 1_000, footprint: 1)
        #expect(ResourceSample.between(a, b).milliwatts == nil)
    }
}
