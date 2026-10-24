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

# A requested change that the kernel refuses must make apply and cycle exit non-zero, while the
# resulting state is still printed. (A node that cannot be written is simulated by a folder.)
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"; rm -rf "$T/cfg"
sh "$KPSH" mode 2 >/dev/null; sh "$KPSH" auto Y >/dev/null            # saved choices: mode 2, auto Y
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
out=$(sh "$KPSH" apply); check "apply, all fine: exit 0" "0" "$?"
rm -f "$T/kp_mode"; mkdir "$T/kp_mode"
out=$(sh "$KPSH" apply); rc=$?
check "apply with a refused mode: exit 1" "1" "$rc"
case "$out" in *"error: wrote 2"*) echo "ok   apply with a refused mode: error shown" ;; *) echo "FAIL apply: error not shown: $out"; fail=1 ;; esac
case "$out" in *"auto=Y"*) echo "ok   apply with a refused mode: the auto setting was still applied and the state printed" ;; *) echo "FAIL apply: state/auto missing: $out"; fail=1 ;; esac
out=$(sh "$KPSH" cycle); rc=$?
check "cycle with a refused mode: exit 1" "1" "$rc"
case "$out" in *"switched to"*) echo "FAIL cycle claimed a switch"; fail=1 ;; *) echo "ok   cycle with a refused mode: no 'switched' message" ;; esac
case "$out" in *"mode="*) echo "ok   cycle with a refused mode: state still printed" ;; *) echo "FAIL cycle: no state"; fail=1 ;; esac
rmdir "$T/kp_mode"; echo 0 > "$T/kp_mode"
rm -f "$T/auto_kp"; mkdir "$T/auto_kp"
sh "$KPSH" apply >/dev/null; check "apply with a refused auto setting: exit 1" "1" "$?"
check "apply with a refused auto setting: the mode was still applied" "2" "$(cat "$T/kp_mode")"
rmdir "$T/auto_kp"; echo N > "$T/auto_kp"
echo 1 > "$T/kp_mode"; sh "$KPSH" cycle >/dev/null; check "cycle, all fine: exit 0" "0" "$?"

# Saving a choice can fail while the kernel accepts it: that is reported as exactly that, and exits non-zero.
rm -rf "$T/cfg"; echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
sh "$KPSH" mode 2 >/dev/null; sh "$KPSH" auto Y >/dev/null; cp "$T/cfg/config" "$T/config.good"
mkdir "$T/cfg/config.tmp"                                   # the temporary file cannot be written
out=$(sh "$KPSH" mode 3 2>&1); rc=$?
check "mode, config not writable: exit 1" 1 "$rc"
case "$out" in *"the kernel accepted mode 3, but saving it"*) echo "ok   mode, config not writable: says the kernel accepted it" ;; *) echo "FAIL mode: message was '$out'"; fail=1 ;; esac
check "mode, config not writable: the kernel did take it" 3 "$(cat "$T/kp_mode")"
check "mode, config not writable: the old config is untouched" "$(cat "$T/config.good")" "$(cat "$T/cfg/config")"
out=$(sh "$KPSH" auto N 2>&1); rc=$?
check "auto, config not writable: exit 1" 1 "$rc"
case "$out" in *"the kernel accepted auto N, but saving it"*) echo "ok   auto, config not writable: says the kernel accepted it" ;; *) echo "FAIL auto: message was '$out'"; fail=1 ;; esac
sh "$KPSH" persist 0 >/dev/null 2>&1; check "persist 0, config not writable: exit 1" 1 "$?"
sh "$KPSH" persist 1 >/dev/null 2>&1; check "persist 1, config not writable: exit 1" 1 "$?"
out=$(sh "$KPSH" persist 1 2>&1); case "$out" in *"could not save the persistence setting"*) echo "ok   persist: says what failed" ;; *) echo "FAIL persist: message was '$out'"; fail=1 ;; esac
sh "$KPSH" cycle >/dev/null 2>&1; check "cycle, config not writable: exit 1" 1 "$?"
sh "$KPSH" apply >/dev/null 2>&1; check "apply, config not writable: exit 1" 1 "$?"
check "failed saves: the old config is still untouched" "$(cat "$T/config.good")" "$(cat "$T/cfg/config")"
rmdir "$T/cfg/config.tmp"
sh "$KPSH" mode 1 >/dev/null; check "after the problem is gone: mode saves again" 0 "$?"
check "after the problem is gone: saved" 1 "$(sed -n 's/^MODE=//p' "$T/cfg/config")"
check "no temporary file is left behind" "no" "$([ -e "$T/cfg/config.tmp" ] && echo yes || echo no)"
# the config folder cannot be created (a file is in its place)
echo x > "$T/notadir"; echo 0 > "$T/kp_mode"
CFG_DIR="$T/notadir" sh "$KPSH" mode 2 >/dev/null 2>&1; check "config folder impossible: exit 1" 1 "$?"
CFG_DIR="$T/notadir" sh "$KPSH" persist 0 >/dev/null 2>&1; check "config folder impossible: persist exit 1" 1 "$?"
check "config folder impossible: the file in its place is untouched" "x" "$(cat "$T/notadir")"
# the config itself is a folder
mkdir -p "$T/cfg2/config"; echo 0 > "$T/kp_mode"
CFG_DIR="$T/cfg2" sh "$KPSH" mode 2 >/dev/null 2>&1; check "config is a folder: exit 1" 1 "$?"
check "config is a folder: nothing was moved into it" "0" "$(ls "$T/cfg2/config" | wc -l | tr -d ' ')"
check "config is a folder: no temporary file left" "no" "$([ -e "$T/cfg2/config.tmp" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
