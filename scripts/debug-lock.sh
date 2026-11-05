#!/bin/zsh
# Development helper for Debug builds: lock, unlock or open windows from Terminal
# (or over SSH), so a lock can always be released while testing.
#   scripts/debug-lock.sh lock|unlock|settings|diagnostics|onboarding
#   scripts/debug-lock.sh snapshot <folder>   Save PNGs of all visible windows
#   scripts/debug-lock.sh status <file>       Write lock/focus state to a file
#   scripts/debug-lock.sh cardtest <file>     Build an invisible pill, open the password field and
#                                             record whether the pill or fingerprint moved (no lock)
set -euo pipefail
ACTION=${1:?Usage: debug-lock.sh lock|unlock|settings|diagnostics|onboarding|snapshot <folder>|status <file>|cardtest <file>}
case $ACTION in
  lock|unlock) NAME="com.farhan2077.clearlock.debug.$ACTION"; OBJECT="" ;;
  snapshot) NAME="com.farhan2077.clearlock.debug.snapshot"; OBJECT=${2:?folder required} ;;
  status) NAME="com.farhan2077.clearlock.debug.status"; OBJECT=${2:?file required} ;;
  cardtest) NAME="com.farhan2077.clearlock.debug.cardtest"; OBJECT=${2:?file required} ;;
  *) NAME="com.farhan2077.clearlock.debug.window"; OBJECT=$ACTION ;;
esac
swift -e "import Foundation
DistributedNotificationCenter.default().postNotificationName(.init(\"$NAME\"), object: \"$OBJECT\".isEmpty ? nil : \"$OBJECT\", userInfo: nil, deliverImmediately: true)"
