#!/usr/bin/env bash
# Proof that the store-screenshot hooks (-fixedNow, -storeCapture) are compiled out of Release.
#
#   PulseLoopiOS/scripts/release_hooks_check.sh
#
# Compiles the two hook files (PulseLoop/Services/AppClock.swift, StoreCapture.swift; Foundation only) into a tiny
# harness twice — once WITHOUT `-DDEBUG` (what a Release build is) and once WITH it (the positive control) — and runs
# each with `-fixedNow 2026-09-24T19:30:00 -storeCapture YES` on its command line:
#   Release : the clock offset stays 0 and StoreCapture stays off, both through the launch-argument path
#             (`applyLaunchArguments`, whose UserDefaults reads are inside #if DEBUG) and through the direct `configure`
#             calls that use the default build-type gate
#   Debug   : the clock is shifted and StoreCapture is on (the positive control: proves the harness can fail)
# (A `strings | grep fixedNow` check is useless: Swift keeps literals up to 15 bytes as immediates in the code.)
# Cheap (a few seconds, well under 10 MB of scratch); exit 0 = compiled out of Release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/PulseLoop/Services"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/main.swift" <<'SWIFT'
import Foundation
AppClock.applyLaunchArguments()
StoreCapture.applyLaunchArguments()
// The default build-type gate (no explicit debugBuild) must also refuse in Release.
let direct = AppClock.configure("2026-09-24T19:30:00")
let capture = StoreCapture.configure("YES")
print("debugBuild=\(AppClock.isDebugBuild) offsetSeconds=\(Int(AppClock.offset)) direct=\(Int(direct)) capture=\(capture) active=\(StoreCapture.isActive) debugChrome=\(StoreCapture.showsDebugChrome)")
SWIFT

build_and_run() {  # $1 = label, $2... = extra swiftc flags
  local label="$1"; shift
  swiftc -O "$@" "$SRC/AppClock.swift" "$SRC/StoreCapture.swift" "$WORK/main.swift" -o "$WORK/$label" 2>"$WORK/$label.err" \
    || { cat "$WORK/$label.err" >&2; exit 1; }
  "$WORK/$label" -fixedNow 2026-09-24T19:30:00 -storeCapture YES
}

release_out="$(build_and_run release)"
debug_out="$(build_and_run debug -DDEBUG)"
echo "release: $release_out"
echo "debug  : $debug_out"

fail=0
case "$release_out" in
  *"debugBuild=false offsetSeconds=0 direct=0 capture=false active=false debugChrome=false"*) echo "OK  release ignores -fixedNow and -storeCapture" ;;
  *) echo "FAIL release honoured a hook"; fail=1 ;;
esac
case "$debug_out" in
  *"debugBuild=true "*"capture=true active=true debugChrome=false"*) echo "OK  debug honours them (positive control)" ;;
  *) echo "FAIL debug build did not honour the hooks; the check proves nothing"; fail=1 ;;
esac
exit $fail
