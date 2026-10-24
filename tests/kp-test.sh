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

# Failure injection that works in EVERY shell. A stand-in `grep` or `mv` placed first in PATH is NOT
# enough: busybox ash runs its own built-in applets and never looks at PATH for them, so such a test
# silently injected nothing there (the operation succeeded and the test failed). A shell FUNCTION with
# the command's name beats both the built-in applet and the real command in every shell. inj writes a
# small runner that defines the functions and then runs the script under test with the given arguments:
#   inj 'grep() { ...; }'; INJ_TARGET="$KPSH" sh "$T/inj.sh" mode 3
inj() { printf '%s\n. "$INJ_TARGET"\n' "$1" > "$T/inj.sh"; }
GREP_FAILS='grep() { for ij_a; do case "$ij_a" in */config) return 2 ;; esac; done; command grep "$@"; }'
MV_FAILS='mv() { return 1; }'

# An existing config that cannot be READ is never replaced by a file holding only the new key.
rm -rf "$T/cfg"; echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
sh "$KPSH" mode 2 >/dev/null; sh "$KPSH" auto Y >/dev/null; good=$(cksum < "$T/cfg/config")
inj "$GREP_FAILS"
printf 'grep -v zzz "%s" >/dev/null 2>&1; echo $?\n' "$T/cfg/config" > "$T/probe.sh"
check "injection is active (grep on the config fails in this shell)" 2 "$(INJ_TARGET="$T/probe.sh" sh "$T/inj.sh")"
out=$(INJ_TARGET="$KPSH" sh "$T/inj.sh" mode 3 2>&1); rc=$?
check "config unreadable: mode exits 1" 1 "$rc"
check "config unreadable: the old config is byte for byte the same" "$good" "$(cksum < "$T/cfg/config")"
check "config unreadable: no temporary file left" no "$([ -e "$T/cfg/config.tmp" ] && echo yes || echo no)"
INJ_TARGET="$KPSH" sh "$T/inj.sh" auto N >/dev/null 2>&1; check "config unreadable: auto exits 1" 1 "$?"
check "config unreadable: still the same after auto" "$good" "$(cksum < "$T/cfg/config")"
INJ_TARGET="$KPSH" sh "$T/inj.sh" persist 0 >/dev/null 2>&1; check "config unreadable: persist exits 1" 1 "$?"
check "config unreadable: still the same after persist" "$good" "$(cksum < "$T/cfg/config")"
INJ_TARGET="$KPSH" sh "$T/inj.sh" persist 1 >/dev/null 2>&1; check "config unreadable: persist 1 exits 1" 1 "$?"
check "config unreadable: still the same after persist 1" "$good" "$(cksum < "$T/cfg/config")"

# Turning persistence on saves PERSIST, MODE and AUTO as ONE transaction: one replace of the config
# file, so a failure can never leave some of the three saved and the others not. The saved values here
# differ from what the kernel has now, which is exactly the state in which a half-saved file is wrong.
rm -rf "$T/cfg"; mkdir -p "$T/cfg"; echo 2 > "$T/kp_mode"; echo Y > "$T/auto_kp"
printf 'PERSIST=0\nMODE=1\nAUTO=N\nOTHER=keep\n' > "$T/cfg/config"; good=$(cksum < "$T/cfg/config")
inj 'mv() { echo x >> "$MVLOG"; command mv "$@"; }'; rm -f "$T/mvlog"
out=$(MVLOG="$T/mvlog" INJ_TARGET="$KPSH" sh "$T/inj.sh" persist 1 2>&1); rc=$?
check "persist 1: exits 0" 0 "$rc"
check "persist 1: the config is replaced exactly once" 1 "$(wc -l < "$T/mvlog" | tr -d ' ')"
check "persist 1: PERSIST saved" 1 "$(sed -n 's/^PERSIST=//p' "$T/cfg/config")"
check "persist 1: MODE saved (the kernel's, not the old one)" 2 "$(sed -n 's/^MODE=//p' "$T/cfg/config")"
check "persist 1: AUTO saved (the kernel's, not the old one)" Y "$(sed -n 's/^AUTO=//p' "$T/cfg/config")"
check "persist 1: other settings are kept" 1 "$(grep -c '^OTHER=keep$' "$T/cfg/config")"
check "persist 1: no setting is saved twice" 3 "$(grep -c '^\(PERSIST\|MODE\|AUTO\)=' "$T/cfg/config")"
# the replace fails: the old config stays byte for byte (nothing of the three is half saved)
printf 'PERSIST=0\nMODE=1\nAUTO=N\nOTHER=keep\n' > "$T/cfg/config"; good=$(cksum < "$T/cfg/config")
inj "$MV_FAILS"
out=$(INJ_TARGET="$KPSH" sh "$T/inj.sh" persist 1 2>&1); rc=$?
check "persist 1, replace fails: exits 1" 1 "$rc"
check "persist 1, replace fails: says so" 1 "$(printf '%s\n' "$out" | grep -c 'could not save the persistence setting')"
check "persist 1, replace fails: the old config is byte for byte the same" "$good" "$(cksum < "$T/cfg/config")"
check "persist 1, replace fails: no temporary file left" no "$([ -e "$T/cfg/config.tmp" ] && echo yes || echo no)"
# the audit's exact case: the THIRD replace of the config fails. With one replace there is no third one;
# either way the file must never end up half saved (some of the three new, the rest old).
printf 'PERSIST=0\nMODE=1\nAUTO=N\nOTHER=keep\n' > "$T/cfg/config"; good=$(cksum < "$T/cfg/config"); rm -f "$T/mvn"
inj 'mv() { ij_n=$(cat "$MVN" 2>/dev/null || echo 0); ij_n=$((ij_n + 1)); echo "$ij_n" > "$MVN"; [ "$ij_n" = 3 ] && return 1; command mv "$@"; }'
MVN="$T/mvn" INJ_TARGET="$KPSH" sh "$T/inj.sh" persist 1 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(sed -n 's/^PERSIST=//p' "$T/cfg/config")$(sed -n 's/^MODE=//p' "$T/cfg/config")$(sed -n 's/^AUTO=//p' "$T/cfg/config")" = "12Y" ]; then verdict=all-saved
elif [ "$rc" != 0 ] && [ "$good" = "$(cksum < "$T/cfg/config")" ]; then verdict=nothing-changed
else verdict="half saved (exit $rc)"; fi
case "$verdict" in "half saved"*) check "persist 1, third replace fails: never half saved" "all-saved or nothing-changed" "$verdict" ;; *) check "persist 1, third replace fails: never half saved" ok ok ;; esac
# the temporary file cannot be written (a folder is in its place)
printf 'PERSIST=0\nMODE=1\nAUTO=N\nOTHER=keep\n' > "$T/cfg/config"; good=$(cksum < "$T/cfg/config")
mkdir "$T/cfg/config.tmp"
sh "$KPSH" persist 1 >/dev/null 2>&1; check "persist 1, no temporary file possible: exits 1" 1 "$?"
check "persist 1, no temporary file possible: the old config is byte for byte the same" "$good" "$(cksum < "$T/cfg/config")"
rmdir "$T/cfg/config.tmp"
sh "$KPSH" persist 1 >/dev/null 2>&1; check "persist 1 once the problem is gone: exits 0" 0 "$?"
check "persist 1 once the problem is gone: MODE follows the kernel" 2 "$(sed -n 's/^MODE=//p' "$T/cfg/config")"
check "persist 1 once the problem is gone: AUTO follows the kernel" Y "$(sed -n 's/^AUTO=//p' "$T/cfg/config")"
rm -f "$T/inj.sh" "$T/probe.sh" "$T/mvlog" "$T/mvn"
[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
