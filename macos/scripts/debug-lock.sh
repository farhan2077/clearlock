#!/bin/zsh
# Development helper for Debug builds (Clearlock Dev): lock, unlock or open windows from Terminal
# (or over SSH), so a lock can always be released while testing.
#   macos/scripts/debug-lock.sh lock|unlock|settings|diagnostics|onboarding
#   macos/scripts/debug-lock.sh snapshot <folder>   Save PNGs of all visible windows
#   macos/scripts/debug-lock.sh status <file>       Write lock/focus state to a file
#   macos/scripts/debug-lock.sh cardtest <file>     Build an invisible pill, open the password field and
#                                             record whether the pill or fingerprint moved (no lock)
set -euo pipefail
# Only Clearlock Dev has these hooks; its notification names start with its bundle ID.
PREFIX=com.farhan2077.clearlock.dev.debug
ACTION=${1:?Usage: debug-lock.sh lock|unlock|settings|diagnostics|onboarding|snapshot <folder>|status <file>|cardtest <file>}
case $ACTION in
  lock|unlock) NAME="$PREFIX.$ACTION"; OBJECT="" ;;
  snapshot) NAME="$PREFIX.snapshot"; OBJECT=${2:?folder required} ;;
  status) NAME="$PREFIX.status"; OBJECT=${2:?file required} ;;
  cardtest) NAME="$PREFIX.cardtest"; OBJECT=${2:?file required} ;;
  menutest) NAME="$PREFIX.menutest"; OBJECT=${2:?file required} ;;
  *) NAME="$PREFIX.window"; OBJECT=$ACTION ;;
esac
swift -e "import Foundation
DistributedNotificationCenter.default().postNotificationName(.init(\"$NAME\"), object: \"$OBJECT\".isEmpty ? nil : \"$OBJECT\", userInfo: nil, deliverImmediately: true)"
