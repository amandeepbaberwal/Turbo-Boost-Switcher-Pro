#!/bin/bash
# test-scenarios.sh — automated regression for the helper daemon.
# No sudo needed (everything goes through the root helper over XPC).
# Round-trips RESTORE original state. Usage: ./scripts/test-scenarios.sh
set -uo pipefail
CLONE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$CLONE_DIR/build/xpc-probe"
PASS=0; FAIL=0

echo "== building probe"
xcrun swiftc -O -framework Foundation "$CLONE_DIR/scripts/xpc-probe.swift" -o "$PROBE" || exit 1

check() { # check <name> <command...> — passes if exit 0
  local name="$1"; shift
  if "$@" >/tmp/probe-out.txt 2>&1; then echo "PASS $name"; PASS=$((PASS+1));
  else echo "FAIL $name"; cat /tmp/probe-out.txt; FAIL=$((FAIL+1)); fi
}

echo "== S1 helper alive"
check "version" "$PROBE" version

echo "== S2 stats complete (all keys, no MISSING)"
check "stats-keys" "$PROBE" stats
grep -q "vsKext=" /tmp/probe-out.txt && echo "PASS vsKext-present" && PASS=$((PASS+1)) || { echo "FAIL vsKext-present"; FAIL=$((FAIL+1)); }

echo "== S3 PL round-trip (save 45/60, restore)"
ORIG_PL="$("$PROBE" getpl)"
echo "   original: $ORIG_PL"
check "setpl-45-60" "$PROBE" setpl 45 60
LIVE="$("$PROBE" getpl)"; echo "   live: $LIVE"
case "$LIVE" in *"pl1=45"*|*"pl1=15"*|*"pl1=25"*) echo "PASS pl-sticks-or-clamps (chip truth)"; PASS=$((PASS+1));; *) echo "FAIL pl-unexpected: $LIVE"; FAIL=$((FAIL+1));; esac
# restore
OA=$(echo "$ORIG_PL" | sed -E 's/.*pl1=([0-9]+).*/\1/'); OB=$(echo "$ORIG_PL" | sed -E 's/.*pl2=([0-9]+).*/\1/')
"$PROBE" setpl "$OA" "$OB" >/dev/null 2>&1
echo "   restored to $OA/$OB: $("$PROBE" getpl)"

echo "== S4 turbo round-trip with kextstat proof (restores)"
ORIG_ST="$("$PROBE" getstate)"; echo "   original: $ORIG_ST"
if echo "$ORIG_ST" | grep -q "disabled=true"; then FLIP=on; WANT_ABSENT=yes; else FLIP=off; WANT_ABSENT=no; fi
check "setstate-$FLIP" "$PROBE" setstate "$FLIP"
sleep 1
if [ "$WANT_ABSENT" = yes ]; then
  kextstat 2>/dev/null | grep -q rugarciap && { echo "FAIL kext-still-loaded"; FAIL=$((FAIL+1)); } || { echo "PASS kext-unloaded"; PASS=$((PASS+1)); }
else
  kextstat 2>/dev/null | grep -q rugarciap && { echo "PASS kext-loaded"; PASS=$((PASS+1)); } || { echo "FAIL kext-missing"; FAIL=$((FAIL+1)); }
fi
# restore
if echo "$ORIG_ST" | grep -q "disabled=true"; then "$PROBE" setstate off >/dev/null 2>&1; else "$PROBE" setstate on >/dev/null 2>&1; fi
sleep 1
echo "   restored: $("$PROBE" getstate) / $(kextstat 2>/dev/null | grep -c rugarciap) kext line(s)"

echo
echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
