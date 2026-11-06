# Clearlock

A native macOS menu bar app. It keeps the Mac awake and locks out everyone but the owner while their work (AI agents, builds) keeps running. Unlocking is by Touch ID or the login password.

The decisions below were made with the owner and are final. Don't reverse or "improve" one without asking first.

## Commands

```bash
scripts/build.sh --run          # Release build, signed with the self-signed cert, launched
scripts/build.sh debug --run    # Debug build with Terminal hooks (scripts/debug-lock.sh)
scripts/test.sh                 # Unit tests (must pass before any change is done)
scripts/release.sh 1.1.0        # Dry run: test, build, package .dmg and .zip; changes and publishes nothing
scripts/release.sh 1.1.0 --publish   # Only with the owner's go-ahead for that version
```

- **First build:** `scripts/build.sh` runs `scripts/setup-signing.sh`, which creates the self-signed certificate in `.signing/` if it's missing.
- **Xcode:** `Clearlock.xcodeproj` opens fine, but Cmd-R signs ad hoc, so Accessibility permission resets with each Xcode build. Use the scripts when testing the Shield.
- **Window focus trace** (Debug builds only, `DebugTrace`): menu open and close, Settings… firing, activation and every titled window's key and visibility changes go to the system log. Read them with `log show --last 10m --predicate 'subsystem == "com.farhan2077.clearlock" AND category == "trace"' --style compact`. `menutest` clicks the menu bar icon for real when the build may post events, otherwise it drives the same menu from inside the app.
- **Debug hooks** (Debug builds only; they also let you release a lock from Terminal or over SSH):

```bash
scripts/debug-lock.sh lock                    # or: unlock, settings, settings-general, settings-advanced, diagnostics, about, onboarding
scripts/debug-lock.sh snapshot <folder>       # PNGs of all visible windows
scripts/debug-lock.sh status <file>           # lock and focus state
scripts/debug-lock.sh cardtest <file>         # checks the pill never moves, without locking
scripts/debug-lock.sh menutest <file>         # chooses Settings… from the real menu and records the window state
```

## Keeping the docs in sync

- **`README.md` is for users and stays short:** the icon, badges (latest release, macOS 26+, app size; no Swift or dependency badges), a one-line pitch, a feature list in plain language, Install, Uninstall, two build commands that point here, and a centered "Built by Farhan Bin Amin" credit line at the end. No implementation details, settings tables, test counts, debug hooks or release steps; those live in this file. **Whenever a change touches anything it mentions, update the README in the same change.** A change isn't done while the README says something the app no longer does.
  - It covers the features, the shortcut, requirements, the install steps (including "Open Anyway" and Accessibility), uninstalling (including the lid helper), and that it uses no CPU while idle.
  - **No memory figures,** in the README or this file (the owner's decision). When CPU or wakeup behavior changes, measure the Release build again (`top`) instead of guessing, and update both files. Say so when something couldn't be re-measured, for example anything that needs locking the owner's screen.
- **This file is updated the same way** whenever a decision, default or rule changes.

## Product and platform

- **Name:** **Clearlock** (capital C only) in the interface, the Xcode project, targets, folders and the app file (`Clearlock.app`); lowercase `clearlock` in identifiers and paths. The project folder on disk is `clearlock`. **Repo:** `farhan2077/clearlock`.
  - The meaning: like a glass case, everything stays visible but nothing can be touched.
  - History: AwakeLock, then ClearLock, before the first release. Nothing should say either any more, except the signing certificate name below.
- **Protected identifiers, never change:**
  - **Bundle ID `com.farhan2077.clearlock`.** Accessibility permission, the settings domain, Open at Login and the updater's signature check are keyed to it; changing it after a release resets every user's permission and breaks their updates. The test bundle is `com.farhan2077.clearlock.tests`. The owner chose it before the first release; it replaced `com.clearlock.ClearLock`, which was only ever on the owner's Mac.
  - **Signing certificate name `ClearLock Self-Signed`** in `.signing/`. Updates and permissions trust that certificate. Its old capitalization is deliberate.
  - Debug notification names use the bundle ID as a prefix (`com.farhan2077.clearlock.debug.*`).
- **Platform:** macOS 26 or later.
- **Stack:** Swift 6 with AppKit for the core (menu bar item, lock windows, event tap, hotkeys) and SwiftUI only for Settings, Onboarding and Diagnostics.
- **No third-party code.** No Sparkle, no packages.
- **Default actor isolation:** MainActor (`SWIFT_DEFAULT_ACTOR_ISOLATION`). C callbacks are `nonisolated` free functions that hop in with `MainActor.assumeIsolated`.

## Resource budget

- **Idle:** 0% CPU, 0 wakeups.
- **No timers or polling while idle.** Timers only exist while something needs them: permission polling only while Settings or Onboarding is open, Diagnostics sampling only while it's open, and while locked only short-lived feedback and wait-countdown timers.
- **SwiftUI windows are created on demand and fully released on close** (`WindowCoordinator`).

## Signing, distribution and updates

- **Signing:** a self-signed certificate in `.signing/` (gitignored). Never commit it.
  - It must be backed up. Losing it resets every user's Accessibility permission and breaks auto-updates.
  - Build with the scripts. Xcode's Cmd-R signs ad-hoc, which resets Accessibility permission on every build.
- **No Apple Developer account,** so no notarization. Users click "Open Anyway" once.
- **Updates:** built-in updater (`Updater.swift`) reading GitHub Releases from `farhan2077/clearlock` (`AWLUpdateRepository` in `Config/Info.plist`).
  - A download is installed only if it satisfies the running app's designated requirement, meaning it's signed with the same certificate.
  - Installing quits Clearlock, so it never happens while locked (`Updater.canInstall`).
- **Versions follow semver,** `MAJOR.MINOR.PATCH`, no leading zeros, no pre-release suffixes (the updater compares plain numbers). The first release is **1.0.0**; each later one must be higher than the latest `v*` tag. Tags are `v` plus the version (`v1.0.0`). The build number (`CURRENT_PROJECT_VERSION`) goes up by one per release. `scripts/release.sh` enforces all of this.
- **Release assets:** every GitHub release carries `Clearlock-<version>.dmg` (the app next to an Applications shortcut, signed, for people to download) and `Clearlock-<version>.zip` (what the in-app updater downloads; it picks the `.zip` whose name contains "clearlock"). Keep both.
- **Release steps** (only with the owner's instruction, see below):
  1. `scripts/release.sh <version>` is a dry run: it checks the version, runs the tests, builds with that version stamped in, and packages both files into `build/release/`. It edits no files and publishes nothing.
  2. `scripts/release.sh <version> --publish` also needs a clean `main` in sync with GitHub. It sets the version in the project, updates the README's "app size" badge to the new app's installed size (decimal MB, as Finder shows), commits both as "Release <version>", creates the annotated tag `v<version>`, pushes both, and runs `gh release create` with the two files and generated notes. If anything fails before the commit, the version change is undone.
  - Installed copies find a new release within a day, or right away from Check for Updates….
  - The updater downloads without quarantining the file and checks the signature itself, so "Open Anyway" is only ever needed for the first install.
- **Not unit-tested:** the release script (it's shell, and tests can't read the project folder). After changing it, check bad versions are refused and run a dry run, then mount the DMG with `-nobrowse` and check its contents, version and signature.
- **Releases need the owner's specific instruction, every time.** Without it, never publish a new release: no `scripts/release.sh --publish`, no version bump, no `git tag`, no `gh release create`, nothing uploaded to GitHub. A dry run (`scripts/release.sh <version>` without `--publish`) is fine anytime.
  - The instruction must come from the owner in chat and name that release. Never infer it from a finished feature, a passing test run, a doc, a TODO or an earlier approval. One approval covers one release only.
  - Building locally (`scripts/build.sh`) and running tests are fine anytime.
- **Pushing commits** to GitHub also needs the owner to say so in chat. Commit only when asked.

## Locking behavior

- **Default lock shortcut:** ⇧⌘L. It's the only global shortcut. **Keep Awake has no shortcut** and no timed sessions; both were removed at the owner's request.
- **Keep Awake is always on.** It starts when Clearlock launches and runs until it quits. There's no switch anywhere (`AwakeController.startsAtLaunch`).
- **The display always stays on while Clearlock keeps the Mac awake**, locked or not (`PowerAssertions.needed`). There's no "Keep display on" switch; the owner chose this knowing the battery cost.
- **Shield:** an Accessibility event tap that blocks *physical* input only. It runs whenever Accessibility is allowed; there is no separate Shield switch.
  - Input is classified by its event source PID: 0 or WindowServer means hardware; any other process means automation.
  - **Agents and automation always keep working.** There's no setting to block them (`InputShield.decide` always passes agents' input), and lock mode is either standard (no Accessibility) or shield.
  - A blocked physical key press or click brings the card's focus back.
  - Agents' clicks pass through the overlay (`ignoresMouseEvents`).
  - While the card has keyboard focus, agents' keystrokes are re-posted to the frontmost app (`postToPid`) so they never land in the password field.
- **The unlock pill always has keyboard focus while locked.**
  - It's a non-activating `NSPanel`, so the agents' app stays frontmost.
  - If it loses key status, it takes it back. It never gives focus away on a timer.
- **Window levels:** overlay at `.screenSaver`, card at `.screenSaver + 1`. Never set `isFloatingPanel` on the card; it resets the level to `.floating`, which put the card below the overlay.
- **Unlocking:** Touch ID is always used when the Mac has it; there's no switch. It runs inside the card (`LAAuthenticationView`), never as a system sheet, which could hide behind the overlay. The login password always works (checked with OpenDirectory).
- **Wrong attempts:** after every 3rd failure, a wait of 30 s, 60 s, 120 s, and so on, capped at 5 minutes. Failed attempts are reported after unlocking.
- **Locking is paused while the welcome guide is open.** A blocked attempt shows a short banner and brings the guide forward.
- **The app can't be quit while locked.**

## Lock screen design

- **The card is a wide Liquid Glass pill** (`UnlockPanel.pillSize`, 360 × 72, fully rounded ends). It's always fully shown while locked; there's no hidden-card mode. It shows only:
  - **Left:** the Touch ID fingerprint (`LAAuthenticationView`), or a lock symbol on Macs without Touch ID or after a Touch ID lockout.
  - **Right:** "Locked by Clearlock" over one helper line ("Touch ID or start typing your password", or "Type your password to unlock" without Touch ID).
  - **No date, time, greeting, border, status chips, memory or battery readouts, or custom message.** No clock, so no clock timer.
- **Password field:** typing (the keystroke is kept) or clicking the pill swaps the helper line for the field. Escape on an empty field swaps back to Touch ID. Without Touch ID the field shows from the start.
- **Feedback** ("Incorrect password", "Touch ID not recognized", "Try again in 25 s") briefly replaces the title in red.
- **The pill never changes size or moves**, and the fingerprint never moves; tests enforce this. The window is a transparent canvas exactly the pill's size.
  - Never animate the panel's window frame.
  - Never put the content inside `NSGlassEffectView.contentView`; it bottom-anchors its content. The glass is a background sibling.
- **Settings › Lock Screen:**
  - **Position** (Center by default): any of nine spots, Top Left through Bottom Right (`CardPosition`, placed by `UnlockPanel.frame(for:in:topInset:)`). It's picked on a 3 × 3 grid drawn like a small screen, with no menu bar or notch (`PositionGrid`), not a dropdown: the chosen cell shows a small pill in the lock color, the others a dot, and the current choice's name sits under the "Position" label. Grid cells map to positions with `CardPosition.at(gridRow:gridColumn:)`, rows from the top. Center and the middle row sit 4 % above the screen's middle. Edge positions keep `UnlockPanel.edgeMargin` (24 pt) from the edges, and top ones also stay below the menu bar and the camera housing. The whole pill is always on screen.
  - **No blur or Liquid Glass background.** The screen behind the lock is only ever dimmed. The full-screen glass option was removed at the owner's request; don't add it back.
  - **Dim screen** slider: 0–90%, default 30%. Values are clamped to that range.

## Menu bar

- **Icon:** always a lock. Open lock (`lock.open`) while unlocked (no cup, no dimming). White lock on a pill in the chosen tint while locked. Keep Awake shows only in the tooltip and VoiceOver label.
- **Clicking the icon always opens the menu.** There's no "click to lock" option.
- **Menu items, only:** Lock Now (Unlock… while locked, Finish Setup to Lock… while the welcome guide is open), Settings…, Check for Updates… (Restart to Update once an update is downloaded), About, Quit (disabled while locked). `StatusItemController.menuEntries` decides this.
- **About:** the standard About window with the tagline "Lock your Mac without stopping your work." and "Built by Farhan Bin Amin · GitHub", the name linking to https://farhanbinamin.com and GitHub to https://github.com/farhan2077/clearlock (`WindowCoordinator.aboutCredits`). The hidden main menu's About item opens the same window.
  - No status header, no Keep Awake, no Diagnostics in the menu. Diagnostics lives in Settings › Advanced; Keep Awake is always on.

## Settings

**Two tabs** (`SettingsPane`): **General** for everyday settings, **Advanced** for specialist ones. Every section has a header. Each tab lists its sections (`SettingsPane.sections`), and every section is on exactly one tab. The window resizes to each tab's content. Anything not listed uses its default and isn't shown. The owner tried a single page and preferred tabs.

- **General:**
  1. **Basics:** Open at login, Lock shortcut, Lock color.
  2. **Lock Screen:** Position, Dim screen.
  3. **Updates:** version, status, Check Now, Check automatically.
- **Advanced:**
  1. **Agents:** Accessibility status, with a footer saying agents always keep working.
  2. **Keep Awake:** Keep running with the lid closed, Only when connected to power, and a footer saying the Mac and display stay awake while Clearlock runs. No Keep Awake switch.
  3. **Diagnostics:** Open Diagnostics….
- **Lock shortcut:** a reset button (↺) appears whenever the shortcut differs from ⇧⌘L, whether changed or cleared, and puts ⇧⌘L back (`ShortcutRecorder.showsReset`).
- **Lid closed:** "Only when connected to power" is always listed. While lid-closed mode is off it shows off and is disabled, and its saved choice is kept for when the mode is turned on (`SettingsView.lidPowerToggle`). There's no button to remove the lid helper.
- **Removed, don't add back:** the Keep Awake switch, shortcut and durations, "Keep display on", "Unlock with Touch ID", "Show card" (and the hidden-card mode behind it), "Let AI agents keep working", the lid helper's Remove button, the Shield switch, "Clicking the icon", the "Right Now" status section, background update downloads, "Show welcome guide again", a single scrolling page, the old Lock tab, separate Awake/Shortcuts/Updates tabs.

## Onboarding

**Two pages** (changed at the owner's request; it used to be one).
1. **Welcome:** "Welcome to Clearlock" and three main features: stays awake, locks with ⇧⌘L (Touch ID or password), agents keep working. Button: **Continue**.
2. **Accessibility:** the permission row. Buttons: **Back**, and **Done** once Accessibility is allowed, **Skip for Now** before that.

Two small page dots sit between the buttons (`OnboardingView.primaryButton`, `OnboardingView.showsBack`). Everything else is always on or has a default and isn't shown: Touch ID unlock, Keep Awake, the ⇧⌘L shortcut, letting agents keep working. No Touch ID, shortcut or "Lock Now" steps.
- **No** agents switch, **no** "Try It" test, **no** "locking is paused" note.
- **Stale permissions repair themselves.** After a reinstall or a new signature, macOS keeps the old Accessibility entry; it can look switched on but no longer applies. When Clearlock may not be listed correctly, "Allow…" first clears Clearlock's own entry (`tccutil reset Accessibility <bundle ID>`, no admin needed) and then prompts, so the switch the user flips always works (`PermissionCenter.staleAccessibilityReset`, `PermissionCenter.accessibilityRequest`, `PermissionCenter.signatureToRemember`). Never ask the user to remove entries by hand, never reset another app's entry or "All", and never reset while permission works. Clearlock's own pre-release ID (`PermissionCenter.formerBundleIDs`: `com.clearlock.ClearLock`) is cleared the same way, so no second "Clearlock" row is left behind.
- **No redundant system dialog.** macOS's "would like to control this Mac" dialog only appears when Clearlock may not be in the list yet: the first Allow… from a build signature, a new signature, or a retry after opening System Settings didn't help. Otherwise Allow… opens System Settings directly. When the dialog does show, Clearlock doesn't also open System Settings, since the dialog's button does. Having permission proves the entry exists, so the signature is remembered then too (`PermissionCenter.accessibilityRequest`, `PermissionCenter.signatureToRemember`).
- **Windows open on the first click.** Clearlock is a menu bar app, so it has to ask macOS to come forward, and macOS can refuse a request that arrives late. Every window (Settings, onboarding, Diagnostics, About) asks right away, before the window is built (`WindowCoordinator.requestActivation`). It then puts the window on top even if the request was refused, and asks once more after the window is on screen if Clearlock still isn't in front (`WindowCoordinator.present`). Before this, the first Settings… after launch could need a second click. Tests fake activation (`activateApp`, `isAppActive`) so the test host never takes focus.
- **Window placement:** onboarding and Settings windows open truly centered in the visible frame (`WindowCoordinator.centeredOrigin`), sized before centering.

## Settings persistence

- **Storage:** UserDefaults, mirrored to `~/.config/clearlock/settings.plist`.
- **Restore:** on launch, if the defaults domain is empty (for example after an uninstaller) and the backup exists, the backup is restored before anything reads settings. Open at Login is re-registered if it was on.
- **Existing settings are never overwritten by the backup.**

## Lid closed

- **Opt-in.** A one-time admin prompt installs `/etc/sudoers.d/clearlock`, which allows exactly `pmset -a disablesleep 1` and `0` for this user. Nothing else runs as root.
- **"Only when connected to power"** is on by default.
- **If the app quit while lid sleep was disabled,** it's restored on the next launch.
- **The helper is never removed from the app.** Turning the mode off just stops using it. To remove it by hand: `sudo rm /etc/sudoers.d/clearlock`.

## Diagnostics

- **One style for the whole window** (`DiagnosticsStyle`): one spacing scale (page padding 24, sections 20, cards 12 apart with 16 inside, rows 12, text 4) and four text styles (page title, card title, body, detail), plus the metric value.
- **The Impact Test leaves the window out.** The live tiles measure the whole process, so they include the window's own drawing (the header says so). While the test runs, live sampling and the charts pause and nothing in the window animates; the result comes only from one reading at each end (`ResourceMonitor.TestResult.measured`), and sampling resumes afterwards. So there's no Peak CPU figure.
- **Every box is a `DiagnosticsCard`:** title row (optional control on the right) over content, same padding, corners and background. Don't mix in `GroupBox` or one-off fonts and paddings.

## Testing rules

- **Swift Testing**, in `ClearlockTests/`. The app is the test host but starts nothing under XCTest (`main.swift`): no status item, no hotkeys, no lock, no real settings.
- **Test behavior, not copy.** Never assert UI strings or that a label exists.
  - Pull decisions into pure functions and test those (`InputShield.decide`, `LockController.throttleDelay`, `LockController.mode`, `LockController.agentTarget`, `LockController.eventRect`, `LockController.kioskOptions`, `PowerAssertions.needed`, `AwakeController.startsAtLaunch`, `StatusItemController.icon`, `AppDelegate.terminateReply`, `Updater.evaluate`, `Updater.repository(from:)`, `LidSleepManager.sudoersRule`, `LidSleepManager.shouldEngage`, `SettingsBackup.shouldReRegisterLoginItem`, `UnlockPanel.startsTyping`, `UnlockPanel.frame(for:in:topInset:)`, `ResourceMonitor.TestResult.verdict`, `ResourceMonitor.TestResult.measured`, `WindowCoordinator.centeredOrigin`, `StatusItemController.menuEntries`, `LockController.focusAction`, `LockController.reportsFailures`, `OnboardingView.finishButton`, `OnboardingView.primaryButton`, `OnboardingView.showsBack`, `CardPosition.at(gridRow:gridColumn:)`, `ShortcutRecorder.showsReset`, `SettingsView.lidPowerToggle`, `PermissionCenter.staleAccessibilityReset`, `Updater.canInstall`, `InputShield.blockedTypes`, `AppDelegate.makeMainMenu`).
  - Real input goes through `InputShield.shouldPass` with `CGEvent`s whose source PID is set (0 for hands, any other PID for agents). Never start the tap in tests.
- **Every feature and every decision in this file has a test.** A change to behavior ships with a test that fails without it. Before finishing, break the behavior on purpose once and confirm a test catches it, then restore the code.
- **Not unit-tested on purpose** (needs a person or changes the Mac): real Touch ID, checking the real login password (repeated wrong attempts could count against the account), registering global hotkeys, taking power assertions, the lid-closed helper's admin prompt, and Open at Login registration. Their decisions are tested as pure functions instead. `LidSleepManager` takes a fake `pmset` and its own defaults in tests, so recovery after a crash is tested without touching the Mac.
- **Tests must be deterministic.** Use `IsolatedDefaults` and `TemporaryFile`, never `UserDefaults.standard` or the real backup file. Tests leave nothing behind on disk, not even empty settings files in `~/Library/Preferences`. `IsolatedDefaults` deletes its file, but cfprefsd can write the empty file again after the test host exits, so `scripts/test.sh` also sweeps `~/Library/Preferences/ClearlockTests.*.plist` when every run ends. It deletes its own log after a passing run and keeps it after a failure. Time-based checks assert an invariant at every sample, with a generous deadline, never "after N ms the value is X".
- **Never lock the owner's screen in tests,** or repeatedly while they're using the Mac. Build the card off-screen (alpha 0) instead, or use `scripts/debug-lock.sh cardtest`.
- **Tests never read files from the project folder.** It's in ~/Documents, and the test host reading it waits on a macOS privacy prompt until the test times out.
- **Shared singletons:** suites that touch them are `.serialized` and restore state in `defer`.
- **Tests never start real Touch ID** (`UnlockPanel.armTouchID` returns early under XCTest). A pending Touch ID request kept the test host from exiting after all tests had passed; that caused the earlier test-run hangs. Anything that makes the card key (a click, `becomeKey`) would otherwise arm it.
- **CI:** `.github/workflows/tests.yml` runs `scripts/test.sh` on GitHub's `macos-26` runner (its default Xcode, the project's ad-hoc signing, no certificate) for every push that changes `Clearlock/`, `ClearlockTests/`, `Clearlock.xcodeproj/`, `Config/`, `scripts/test.sh` or the workflow itself. It can also be started by hand from the Actions tab. Pushes that only touch docs or housekeeping (`README.md`, `CLAUDE.md`, `.gitignore`, the other scripts) don't run it. It's an allowlist: when app code or test inputs move to a new folder, add that folder to the workflow's `paths`. A failed run keeps the test log as the `test-log` artifact (CI passes the path in `CLEARLOCK_TEST_LOG`; macOS's `mktemp` ignores `TMPDIR`), and when the build fails before any test runs, `test.sh` prints the compiler's messages, crashes included.
  - **The code must build with the runner's Xcode 26 (Swift 6.3) as well as Xcode 27.** Swift 6.3 crashed generating code for a method passed straight in as a SwiftUI `Binding` setter (`set: setLidMode`); wrap such methods in a closure.
  - Tests that click send the whole click (press and release). A lone mouse-down on a text field waits forever for the release.
- **Always run tests through `scripts/test.sh`.** Each test is stopped after 60 s. If the host doesn't exit within 20 s of the final "Test run with …" line, it's stopped and the real result is kept. A run only counts as passed if no test anywhere in the log failed, since Xcode relaunches the host after a timeout and that relaunch can end in "passed"; any other stall is stopped after 5 minutes with the still-running tests named.
