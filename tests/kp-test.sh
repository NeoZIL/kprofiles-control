#!/bin/sh
# Off-device test of module/kp.sh using fake sysfs files.
HERE=$(cd "$(dirname "$0")" && pwd)
KPSH="$HERE/../module/kp.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
export KP_PATH="$T/kp_mode" AUTO_PATH="$T/auto_kp" CFG_DIR="$T/cfg"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }

check "initial status"      "mode=0 auto=N persist=1" "$(sh "$KPSH" status)"
sh "$KPSH" mode 2 >/dev/null;   check "set balanced"  "2" "$(cat "$T/kp_mode")"
sh "$KPSH" auto Y >/dev/null;   check "auto on"       "Y" "$(cat "$T/auto_kp")"
sh "$KPSH" mode 9 >/dev/null;   check "bad mode exit" "1" "$?"
check "bad mode unchanged"  "2" "$(cat "$T/kp_mode")"
sh "$KPSH" auto maybe >/dev/null; check "bad auto exit" "1" "$?"

echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
sh "$KPSH" apply >/dev/null
check "boot apply: mode"    "2" "$(cat "$T/kp_mode")"
check "boot apply: auto"    "Y" "$(cat "$T/auto_kp")"

sh "$KPSH" persist 0 >/dev/null
sh "$KPSH" mode 3 >/dev/null
echo 0 > "$T/kp_mode"
sh "$KPSH" apply >/dev/null
check "persist off: no apply" "0" "$(cat "$T/kp_mode")"
sh "$KPSH" persist 1 >/dev/null
check "persist on: saved"   "1" "$(sed -n 's/^PERSIST=//p' "$T/cfg/config")"

echo 1 > "$T/kp_mode"
sh "$KPSH" cycle >/dev/null; check "cycle 1->2" "2" "$(cat "$T/kp_mode")"
sh "$KPSH" cycle >/dev/null; check "cycle 2->3" "3" "$(cat "$T/kp_mode")"
sh "$KPSH" cycle >/dev/null; check "cycle 3->1" "1" "$(cat "$T/kp_mode")"

KP_PATH="$T/missing" sh "$KPSH" mode 1 >/dev/null; check "missing node exit" "1" "$?"

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
