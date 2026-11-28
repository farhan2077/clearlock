# Clearlock

Clearlock keeps a computer awake and locks out everyone but its owner while their work (AI agents, builds, downloads) keeps running. One repo, `farhan2077/clearlock`, holds every part of it:

| Folder | What | Status | Rules |
|---|---|---|---|
| `macos/` | The native macOS menu bar app | Released | `macos/CLAUDE.md` |
| `windows/` | The Windows app | Planned, not built yet | `windows/CLAUDE.md` |
| `site/` | The website's chosen colors only (`site/COLORS.md`); the site itself was removed to start again later | Not built | `site/COLORS.md` |
| `.signing/` | Signing keys (gitignored, never committed, must be backed up) | | below |

Read the folder's `CLAUDE.md` before working there; the rules in this file apply everywhere.

The decisions below were made with the owner and are final. Don't reverse or "improve" one without asking first.

## Name and license

- **Name:** **Clearlock** (capital C only) in the interface, the Xcode project, targets, folders and the app file (`Clearlock.app`); lowercase `clearlock` in identifiers and paths. The project folder on disk is `clearlock`. **Repo:** `farhan2077/clearlock`.
  - The meaning: like a glass case, everything stays visible but nothing can be touched.
  - History: AwakeLock, then ClearLock, before the first release. Nothing should say either any more, except the signing certificate name below.
  - The Mac app's folder is `macos/`, the Windows app's `windows/`.
- **License:** GPLv3 (the owner chose it over MIT so no one can ship a closed-source copy). `LICENSE` is the unmodified text from gnu.org; don't edit it. The README doesn't mention the license; GitHub shows it in the repo sidebar.

## Keeping the docs in sync

- **`README.md` is for users and stays short:** the icon, badges (latest release, macOS 26+, app size, which is the download size of the `.dmg`, set by hand; no Swift or dependency badges), a centered "Download for macOS" button under them linking to the latest release page (not a versioned file, so it never goes stale), a one-line pitch, a feature list in plain language, Install, Uninstall, two build commands that point here, and a centered "Built by Farhan Bin Amin" credit line at the end. No implementation details, settings tables, test counts, debug hooks or release steps; those live in the `CLAUDE.md` files. **Whenever a change touches anything it mentions, update the README in the same change.** A change isn't done while the README says something the app no longer does.
  - It covers the features, the shortcut, requirements, the install steps (including "Open Anyway" and Accessibility), uninstalling (including the lid helper), and that it uses no CPU while idle.
  - **No memory figures,** in the README or any `CLAUDE.md` (the owner's decision). When CPU or wakeup behavior changes, measure the Release build again (`top`) instead of guessing, and update the README and `macos/CLAUDE.md`. Say so when something couldn't be re-measured, for example anything that needs locking the owner's screen.
- **The `CLAUDE.md` files are updated the same way** whenever a decision, default or rule changes: shared rules here, platform rules in that folder's file.
- The README describes the Mac app; the Windows app gets its own Download button and install steps there once it's released.

## Signing keys

- **`.signing/` sits at the repo root** and is shared by every platform's scripts. It's gitignored: never commit it, never move or regenerate it.
- **It must be backed up.** The Mac certificate (`ClearLock Self-Signed`) is what Accessibility permission and every installed copy's updater trust; losing it resets every user's permission and breaks their updates. The Windows key will have the same role for the Windows updater.

## Releases and pushing

- **Releases need the owner's specific instruction, every time.** Without it, never publish a new release: no `macos/scripts/release.sh --publish`, no version bump, no `git tag`, no `gh release create`, nothing uploaded to GitHub. A dry run (`macos/scripts/release.sh <version>` without `--publish`) is fine anytime.
  - The instruction must come from the owner in chat and name that release. Never infer it from a finished feature, a passing test run, a doc, a TODO or an earlier approval. One approval covers one release only.
  - Building locally (`macos/scripts/build.sh`) and running tests are fine anytime.
- **Pushing commits** to GitHub also needs the owner to say so in chat. Commit only when asked.
- **Windows releases must never disturb the Mac updater.** Installed Mac copies look at the repo's **latest** release and install the first `.zip` whose name contains "clearlock". So Windows releases use their own tags (`windows-v1.0.0`), are always published with `--latest=false`, and never carry a `.zip` with "clearlock" in its name. The Mac keeps the plain `v*` tags.
