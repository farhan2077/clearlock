#!/bin/zsh
# Builds Clearlock and signs it with the stable self-signed identity.
#   scripts/build.sh            Release build → build/Clearlock.app
#   scripts/build.sh debug      Debug build (includes Terminal test hooks)
#   scripts/build.sh --run      Build, quit the running copy, and launch the new one
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=Release
RUN=0
for arg in "$@"; do
  case $arg in
    debug) CONFIG=Debug ;;
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

APP="$ROOT/build/Clearlock.app"
rm -rf "$APP"
ditto "$ROOT/build/DerivedData/Build/Products/$CONFIG/Clearlock.app" "$APP"

security unlock-keychain -p clearlock "$KEYCHAIN"
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP ($CONFIG)"

if (( RUN )); then
  pkill -x Clearlock 2>/dev/null && sleep 0.5 || true
  open "$APP"
fi
