#!/bin/zsh
# Runs the unit tests. The app launches as an inert test host: no menu bar item,
# no hotkeys, no lock, and the user's real settings are never read or written.
#
# The test host sometimes fails to exit after every test has finished (it logs a failed
# connection to macOS's linkd service, then waits). So once the final "Test run with …"
# line appears, it gets 20 s to exit and is then stopped, keeping the real result.
# Each test is also stopped by Xcode after 60 s, and anything else that stalls is stopped
# after 5 minutes with the still-running tests named.
set -uo pipefail
ROOT=${0:A:h:h}
LOG=$(mktemp -t clearlock-tests)
LIMIT=300
GRACE=20

xcodebuild test -project "$ROOT/Clearlock.xcodeproj" -scheme Clearlock -destination "platform=macOS" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  "$@" > "$LOG" 2>&1 &
PID=$!

# Tests use throwaway settings domains named ClearlockTests.<UUID>. cfprefsd can write
# their empty plist files after the test host exits, so sweep them once the run ends.
# The pattern only matches those test files (and ClearLockTests.* from before the rename).
# The log is kept only when the run failed, for looking into it.
clean_up() {
  local code=$?
  sleep 2
  rm -f ~/Library/Preferences/ClearlockTests.*.plist(N) ~/Library/Preferences/ClearLockTests.*.plist(N)
  (( code == 0 )) && rm -f "$LOG"
}
trap clean_up EXIT

stop() {
  pkill -f "$ROOT/build/DerivedData/Build/Products/Debug/Clearlock.app" 2>/dev/null
  kill $PID 2>/dev/null
  wait $PID 2>/dev/null
}

# Xcode relaunches the host after a test times out, and that second run can end in
# "passed", so a pass also requires that no test anywhere in the log failed.
passed_cleanly() {
  grep -qE 'Test run with .* passed' "$1" && ! grep -qE 'recorded an issue|" failed after|Test run with .* failed' "$1"
}

finished_at=-1
for (( t = 0; t < LIMIT; t += 2 )); do
  kill -0 $PID 2>/dev/null || break
  if (( finished_at < 0 )) && grep -qE 'Test run with .* (passed|failed)' "$LOG"; then
    finished_at=$t
  fi
  if (( finished_at >= 0 && t - finished_at >= GRACE )); then
    stop
    grep -E "✔|✘|Test run|passed|failed|error:" "$LOG" | grep -v "linkd" || true
    echo "(The test host didn't exit after the tests finished; stopped it. Results above are complete.)"
    passed_cleanly "$LOG" && exit 0 || exit 1
  fi
  sleep 2
done

if kill -0 $PID 2>/dev/null; then
  echo "Tests stalled for $LIMIT s; stopping them."
  stop
  # Tests that started but never passed or failed.
  grep -E 'Test "[^"]+" (started|passed|failed)' "$LOG" \
    | sed -E 's/.*Test "([^"]+)".* (started|passed|failed).*/\2 \1/' \
    | awk '{ state = $1; $1 = ""; if (state == "started") running[$0] = 1; else delete running[$0] }
           END { for (t in running) print "Still running:" t }'
  echo "Full log: $LOG"
  exit 1
fi

wait $PID
STATUS=$?
(( STATUS == 0 )) && ! passed_cleanly "$LOG" && STATUS=1
grep -E "✔|✘|Test run|passed|failed|error:|\*\* TEST" "$LOG" | grep -v "linkd" || true
exit $STATUS
