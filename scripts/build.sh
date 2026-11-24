#!/bin/zsh
# Builds Clearlock and signs it with the stable self-signed identity.
#   scripts/build.sh            Release build → build/Clearlock.app (com.farhan2077.clearlock)
#   scripts/build.sh debug      Debug build → build/Clearlock Dev.app (com.farhan2077.clearlock.dev),
#                               a separate app with its own settings and permissions, plus Terminal test hooks
#   scripts/build.sh --run      Build, quit the running copy of that same app, and launch the new one
# Clearlock and Clearlock Dev run side by side; --run never quits the other one.
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=Release
NAME=Clearlock
BUNDLE_ID=com.farhan2077.clearlock
RUN=0
for arg in "$@"; do
  case $arg in
    debug) CONFIG=Debug; NAME="Clearlock Dev"; BUNDLE_ID=com.farhan2077.clearlock.dev ;;
    --run) RUN=1 ;;
  esac
done

KEYCHAIN="$ROOT/.signing/clearlock-signing.keychain-db"
IDENTITY="ClearLock Self-Signed"
[[ -f "$KEYCHAIN" ]] || "$ROOT/scripts/setup-signing.sh"

# scripts/release.sh can stamp a version without editing the project:
# CLEARLOCK_VERSION=1.0.0 CLEARLOCK_BUILD=2 scripts/build.sh
OVERRIDES=()
[[ -n ${CLEARLOCK_VERSION:-} ]] && OVERRIDES+=("MARKETING_VERSION=$CLEARLOCK_VERSION")
[[ -n ${CLEARLOCK_BUILD:-} ]] && OVERRIDES+=("CURRENT_PROJECT_VERSION=$CLEARLOCK_BUILD")

xcodebuild -project "$ROOT/Clearlock.xcodeproj" -scheme Clearlock -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" -destination "generic/platform=macOS" \
  -quiet build "${OVERRIDES[@]}"

APP="$ROOT/build/$NAME.app"
rm -rf "$APP"
ditto "$ROOT/build/DerivedData/Build/Products/$CONFIG/$NAME.app" "$APP"

# The release's bundle ID is protected (Accessibility, settings and updates are keyed to it),
# and Dev must never share it, or the two copies would overwrite each other's settings.
BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
if [[ $BUILT_ID != "$BUNDLE_ID" ]]; then
  echo "error: $APP has bundle ID $BUILT_ID, expected $BUNDLE_ID" >&2
  exit 1
fi

security unlock-keychain -p clearlock "$KEYCHAIN"
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP ($CONFIG)"

if (( RUN )); then
  pkill -x "$NAME" 2>/dev/null && sleep 0.5 || true
  open "$APP"
fi
