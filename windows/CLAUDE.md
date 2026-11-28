# Clearlock for Windows

**Status: planned, nothing built yet.** This file records the decisions made with the owner so far. The shared rules in the repo's root `CLAUDE.md` apply here too (name, license, README, releases and pushing, signing keys).

The decisions below were made with the owner and are final. Don't reverse or "improve" one without asking first.

## Goal

**Full feature parity with the Mac app** (`macos/CLAUDE.md` is the spec). Every Mac feature, default and rule gets a Windows equivalent. Where Windows makes exact parity impossible, say so and propose the closest match; never drop a feature silently. When the Mac app changes, check whether this app needs the same change.

## Platform and stack

- **Windows 10 and 11.** Mica exists only on 11, so the pill uses Acrylic (available on both).
- **C# with WinUI 3**, Microsoft packages only (Windows App SDK, .NET). No third-party code, same as the Mac.
- **Tests:** MSTest (Microsoft's), with decisions pulled into pure functions and tested, like the Mac's.
- **Idle budget is the same: 0% CPU, no wakeups.** .NET can wake up on its own (tiered compilation, GC), so measure the Release build instead of assuming, and tune it.
- **Clearlock Dev** exists here too: Debug builds are a separate app with their own settings, startup entry, no updates, never two locks at once, and the same default shortcut as the release.

## Built the way PowerToys is, so Defender has nothing to flag

The owner doesn't want Microsoft Defender to flag Clearlock as malware.
- Input blocking only through the documented low-level hooks (`WH_KEYBOARD_LL`, `WH_MOUSE_LL`) in Clearlock's own process. Input with the "injected" flag is an agent's and always passes; the rest is physical.
- **Never:** DLL injection, drivers, packers or obfuscation, compressed single-file bundles, Windows policy-registry changes (e.g. `DisableTaskMgr`), RunOnce entries, installing certificates, killing other processes, admin rights for normal use.
- Full version info (product, company, description) in every executable; a normal installer with an uninstall entry; start at login only through the standard per-user mechanism; a visible tray icon; nothing hidden.
- Every Windows build gets a Defender scan in CI, and each release is submitted to Microsoft's file-submission portal before it's published.

## Signing

- **Every build is signed with Clearlock's own self-signed key** (in the root `.signing/`, backed up, never committed). The Windows updater trusts only that key, just as the Mac updater trusts only its certificate.
- **On top of it, a trusted signature from SignPath Foundation** (free for open source; the repo is GPLv3) so Defender and SmartScreen don't treat Clearlock as unknown. SignPath's certificate is shared by every project it signs, so it can't prove an update is Clearlock's; that's why the own key stays. The owner submits the SignPath application.

## Locking

- **Default shortcut: Ctrl+Shift+L** (Win+L belongs to Windows), changeable, with the same ↺ reset.
- Keep Awake always on, display included (`SetThreadExecutionState`).
- Physical keystrokes go to the pill or are ignored, exactly as on the Mac (the password field opens only on a double-click on the pill; typing never opens it); agents' input passes to their app, which stays in front.
- **Ctrl+Alt+Del can't be blocked by any app.** Instead: while locked, if a window Clearlock can't block comes to the front (for example Task Manager running as administrator), Clearlock locks Windows for real (`LockWorkStation`). A small watcher, started at lock and gone at unlock, does the same if Clearlock dies while locked. Sign out and power can lose work but can't get anyone in, like the power button on a Mac.
- **Unlocking:** Windows Hello (fingerprint, face or PIN) and the Windows account password. Hello is a system window, not part of the pill; **what starts it is undecided** (proposed: a single click on the pill's fingerprint, rather than opening on every lock). Make sure it always appears above the overlay.
- Everything else matches the Mac: waits after wrong attempts, failed attempts reported, can't quit while locked, locking paused during the welcome guide, the pill's sizes, positions, dimming and no-movement rules.

## Tray, Settings, onboarding

- Tray icon with the Mac's menu bar states and menu. New tray icons start hidden under the taskbar's ^ arrow and apps can't pin themselves.
- Settings: the Mac's two tabs and sections. Advanced › Agents shows only the "agents always keep working" note (there's no Accessibility permission on Windows).
- Lid closed: Windows' lid action has separate plugged-in and battery values, so "Only when connected to power" changes only the plugged-in one. Restored after a crash.
- **Onboarding: two pages,** same structure and buttons as the Mac (Continue; Back, page dots, Done).
  1. Welcome: the three features (stays awake, locks with Ctrl+Shift+L with Windows Hello or password, agents keep working).
  2. Make sure you can unlock: a Windows Hello status row with Set Up…, which opens Windows' Sign-in options (Clearlock changes nothing itself), plus how to drag the tray icon out of ^. This is a deliberate Windows-only exception to the Mac's "no Touch ID step", because PIN-only users may not know their account password.

## Releases and updates

- Tags `windows-v<version>`, always `--latest=false`, never a `.zip` with "clearlock" in its name (see the root `CLAUDE.md`: installed Mac copies read the latest release).
- The updater finds the newest `windows-v*` release, checks the self-signed signature, installs without the internet mark (so SmartScreen only ever warns on the first install), and never installs while locked.
