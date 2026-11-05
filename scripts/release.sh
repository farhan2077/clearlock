#!/bin/zsh
# Packages a Clearlock release: a .dmg for people to download and a .zip for the in-app updater.
# Versions follow semver, MAJOR.MINOR.PATCH, starting at 1.0.0.
#
#   scripts/release.sh 1.0.0             Dry run: checks the version, runs the tests, builds and
#                                        packages into build/release/. Changes no files, publishes nothing.
#   scripts/release.sh 1.0.0 --publish   Also sets the version in the project, commits it, tags
#                                        v1.0.0, pushes, and creates the GitHub release with both files.
#
# Only publish when the owner has asked for that exact version (see CLAUDE.md).
set -euo pipefail

ROOT=${0:A:h:h}
REPO=farhan2077/clearlock
PBX="$ROOT/Clearlock.xcodeproj/project.pbxproj"
OUT="$ROOT/build/release"
KEYCHAIN="$ROOT/.signing/clearlock-signing.keychain-db"
IDENTITY="ClearLock Self-Signed"

die() { print -u2 "release: $*"; exit 1 }

VERSION=${1:-}
PUBLISH=0
case ${2:-} in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) die "unknown option '$2' (only --publish)" ;;
esac

# MAJOR.MINOR.PATCH with no leading zeros. Pre-release suffixes (1.1.0-beta.1) aren't
# accepted, because the in-app updater compares plain version numbers.
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ $VERSION =~ $SEMVER ]] || die "the version must be MAJOR.MINOR.PATCH, like 1.0.0 (got '$VERSION')"

# Exit status 0 when $1 is a higher version than $2.
newer() {
  local -a a b
  a=(${(s:.:)1}); b=(${(s:.:)2})
  for i in 1 2 3; do
    (( a[i] > b[i] )) && return 0
    (( a[i] < b[i] )) && return 1
  done
  return 1
}

cd "$ROOT"
git fetch --quiet --tags origin 2>/dev/null || print -u2 "release: couldn't fetch tags from GitHub; checking local tags only"
[[ -z $(git tag -l "v$VERSION") ]] || die "v$VERSION is already tagged"
LATEST=$(git tag -l 'v*' | sed 's/^v//' | grep -E "$SEMVER" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
if [[ -z $LATEST ]]; then
  [[ $VERSION == 1.0.0 ]] || die "the first release must be 1.0.0"
else
  newer "$VERSION" "$LATEST" || die "$VERSION must be higher than the latest release, $LATEST"
fi

CURRENT_BUILD=$(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$PBX" | grep -oE '[0-9]+$')
BUILD=$(( CURRENT_BUILD + 1 ))

if (( PUBLISH )); then
  command -v gh >/dev/null || die "the GitHub CLI (gh) is needed to publish"
  gh auth status >/dev/null 2>&1 || die "sign in with 'gh auth login' first"
  [[ $(git branch --show-current) == main ]] || die "publish from the main branch"
  [[ -z $(git status --porcelain) ]] || die "commit or stash your changes first"
  git fetch --quiet origin main
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main isn't in sync with GitHub; pull or push first"

  # Undo the version change if anything fails before it's committed.
  trap 'git checkout -- "$PBX" 2>/dev/null' EXIT
  sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/" "$PBX"
  sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PBX"
fi

print "Releasing Clearlock $VERSION (build $BUILD)$( (( PUBLISH )) || print ' — dry run')"
print "Running the tests…"
"$ROOT/scripts/test.sh" > /dev/null || die "the tests failed; nothing was packaged"

CLEARLOCK_VERSION=$VERSION CLEARLOCK_BUILD=$BUILD "$ROOT/scripts/build.sh"
APP="$ROOT/build/Clearlock.app"
[[ $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) == "$VERSION" ]] \
  || die "the built app doesn't report version $VERSION"

rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ZIP="$OUT/Clearlock-$VERSION.zip"
DMG="$OUT/Clearlock-$VERSION.dmg"

# The .zip is what installed copies download to update themselves.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The .dmg: the app next to a shortcut to Applications, to drag it across.
ditto "$APP" "$OUT/dmg/Clearlock.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Clearlock $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/dmg"
security unlock-keychain -p clearlock "$KEYCHAIN"
codesign --force --timestamp=none --keychain "$KEYCHAIN" -s "$IDENTITY" --identifier com.farhan2077.clearlock.dmg "$DMG"
hdiutil verify -quiet "$DMG"

print "Packaged:"
for f in "$DMG" "$ZIP"; do print "  ${f#$ROOT/}  $(du -h "$f" | cut -f1)  sha256 $(shasum -a 256 "$f" | cut -c1-16)…"; done

if (( ! PUBLISH )); then
  print "Dry run: nothing was committed, tagged or published."
  print "To publish: scripts/release.sh $VERSION --publish"
  exit 0
fi

git add "$PBX"
git commit --quiet -m "Release $VERSION"
trap - EXIT
git tag -a "v$VERSION" -m "Clearlock $VERSION"
git push --quiet origin main "v$VERSION"
gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO" --verify-tag \
  --title "Clearlock $VERSION" --generate-notes
print "Published https://github.com/$REPO/releases/tag/v$VERSION"
