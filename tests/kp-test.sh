#!/bin/sh
# Off-device test of module/kp.sh using fake sysfs files.
HERE=$(cd "$(dirname "$0")" && pwd)
KPSH="$HERE/../module/kp.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
export KP_PATH="$T/kp_mode" AUTO_PATH="$T/auto_kp" CFG_DIR="$T/cfg"
set_kernel_source() {
  mkdir -p "$CFG_DIR"
  printf 'SOURCE=kernel\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$CFG_DIR/control.conf"
}
set_kernel_source
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }

check "initial status"      "mode=0 auto=N persist=1 support=supported auto_support=supported" "$(sh "$KPSH" status)"
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
miss_status=$(KP_PATH="$T/missing" sh "$KPSH" status)
check "missing mode node is identified as unsupported" "mode=? auto=Y persist=1 support=unsupported auto_support=supported" "$miss_status"
# Unknown/unreadable is distinct from unsupported; never write an unrecognized node.
echo unknown > "$T/kp_mode"
out=$(sh "$KPSH" status); case "$out" in *"support=unknown"*) echo "ok   malformed current mode is reported as unknown" ;; *) echo "FAIL malformed current mode should be unknown: $out"; fail=1 ;; esac
sh "$KPSH" mode 1 >/dev/null 2>&1; check "malformed mode node is not written" "1" "$?"
check "malformed mode content remains untouched" "unknown" "$(cat "$T/kp_mode")"
echo 0 > "$T/kp_mode"

# If a mode node exists but is unreadable, apply/cycle must fail closed and still report state.
# A mode node that cannot be read is simulated by a directory in place of the file.
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"; rm -rf "$T/cfg"; set_kernel_source
sh "$KPSH" mode 2 >/dev/null; sh "$KPSH" auto Y >/dev/null            # saved choices: mode 2, auto Y
echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"
out=$(sh "$KPSH" apply); check "apply, all fine: exit 0" "0" "$?"
rm -f "$T/kp_mode"; mkdir "$T/kp_mode"
out=$(sh "$KPSH" apply); rc=$?
check "apply with a refused mode: exit 1" "1" "$rc"
case "$out" in *"cannot be read or recognized; no saved mode was applied"*) echo "ok   apply with an unreadable mode node refuses to write" ;; *) echo "FAIL apply refusal was not clear: $out"; fail=1 ;; esac
case "$out" in *"auto=Y"*) echo "ok   apply with a refused mode: unrelated auto setting was left untouched" ;; *) echo "FAIL apply changed auto or omitted state: $out"; fail=1 ;; esac
out=$(sh "$KPSH" cycle); rc=$?
check "cycle with a refused mode: exit 1" "1" "$rc"
case "$out" in *"switched to"*) echo "FAIL cycle claimed a switch"; fail=1 ;; *) echo "ok   cycle with a refused mode: no 'switched' message" ;; esac
case "$out" in *"mode="*) echo "ok   cycle with a refused mode: state still printed" ;; *) echo "FAIL cycle: no state"; fail=1 ;; esac
rmdir "$T/kp_mode"; echo 0 > "$T/kp_mode"
# A kernel without the documented mode node is a supported no-op for boot apply, not a boot failure.
rm -rf "$T/cfg-no-kp"; mkdir -p "$T/cfg-no-kp"
printf 'PERSIST=1\nMODE=3\nAUTO=Y\n' > "$T/cfg-no-kp/config"
rm -f "$T/auto_kp"
out=$(CFG_DIR="$T/cfg-no-kp" KP_PATH="$T/no-kp-mode" AUTO_PATH="$T/no-kp-auto" sh "$KPSH" apply 2>&1); rc=$?
check "kernel without Kprofiles does not fail boot apply" "0" "$rc"
case "$out" in *"saved mode was skipped"*) echo "ok   absent Kprofiles mode is clearly reported as skipped" ;; *) echo "FAIL absent Kprofiles warning missing: $out"; fail=1 ;; esac
[ ! -e "$T/no-kp-mode" ] && [ ! -e "$T/no-kp-auto" ]; check "unsupported kernel: no guessed sysfs nodes are created" "0" "$?"
case "$out" in *"support=unsupported"*) echo "ok   no-Kprofiles boot status remains explicit" ;; *) echo "FAIL no-Kprofiles status unclear: $out"; fail=1 ;; esac
echo N > "$T/auto_kp"
# A present but malformed/unreadable optional parameter is not equivalent to an absent one.
# Persistence must not silently proceed while its current value is unknown.
rm -rf "$T/cfg-auto-unknown"; mkdir -p "$T/cfg-auto-unknown"
printf 'PERSIST=0\nMODE=1\nAUTO=Y\n' > "$T/cfg-auto-unknown/config"
printf 'SOURCE=kernel\nKP_MODE_PREF=1\nKP_AUTO_PREF=Y\n' > "$T/cfg-auto-unknown/control.conf"
rm -f "$T/auto_kp"; mkdir "$T/auto_kp"
out=$(CFG_DIR="$T/cfg-auto-unknown" sh "$KPSH" persist 1 2>&1); rc=$?
check "persist refuses unknown optional auto value" "1" "$rc"
case "$out" in *"auto_kp exists but cannot be read or recognized"*) echo "ok   persist explains unknown optional auto value" ;; *) echo "FAIL persist did not explain unknown auto value: $out"; fail=1 ;; esac
check "persist leaves prior settings unchanged when optional auto is unknown" "$(printf 'PERSIST=0\nMODE=1\nAUTO=Y\n' | cksum)" "$(cksum < "$T/cfg-auto-unknown/config")"
rmdir "$T/auto_kp"; echo N > "$T/auto_kp"
# auto_kp is optional: mode profiles remain usable if a compatible kernel omits the parameter.
rm -rf "$T/cfg-auto-missing"; mkdir -p "$T/cfg-auto-missing"
printf 'PERSIST=1\nMODE=3\nAUTO=Y\n' > "$T/cfg-auto-missing/config"
printf 'SOURCE=kernel\nKP_MODE_PREF=3\nKP_AUTO_PREF=Y\n' > "$T/cfg-auto-missing/control.conf"
rm -f "$T/auto_kp"
out=$(CFG_DIR="$T/cfg-auto-missing" sh "$KPSH" apply 2>&1); rc=$?
check "missing optional auto_kp does not fail mode apply" "0" "$rc"
check "mode is applied when optional auto_kp is absent" "3" "$(cat "$T/kp_mode")"
case "$out" in *"auto_kp parameter; saved auto setting was skipped"*) echo "ok   absent auto_kp is explicitly reported as skipped" ;; *) echo "FAIL absent auto_kp warning missing: $out"; fail=1 ;; esac
check "missing auto parameter is reported as unsupported" "auto_support=unsupported" "$(CFG_DIR="$T/cfg-auto-missing" sh "$KPSH" status | sed 's/.*\(auto_support=[^ ]*\).*/\1/')"
echo N > "$T/auto_kp"
rm -f "$T/auto_kp"; mkdir "$T/auto_kp"
sh "$KPSH" apply >/dev/null; check "apply with a refused auto setting: exit 1" "1" "$?"
check "apply with a refused auto setting: the mode was still applied" "2" "$(cat "$T/kp_mode")"
rmdir "$T/auto_kp"; echo N > "$T/auto_kp"
echo 1 > "$T/kp_mode"; sh "$KPSH" cycle >/dev/null; check "cycle, all fine: exit 0" "0" "$?"

# Saving a choice can fail while the kernel accepts it: that is reported as exactly that, and exits non-zero.
rm -rf "$T/cfg"; echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"; set_kernel_source
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
mkdir -p "$T/cfg2/config"; printf 'SOURCE=kernel\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$T/cfg2/control.conf"; echo 0 > "$T/kp_mode"
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
rm -rf "$T/cfg"; echo 0 > "$T/kp_mode"; echo N > "$T/auto_kp"; set_kernel_source
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
rm -rf "$T/cfg"; mkdir -p "$T/cfg"; set_kernel_source; echo 2 > "$T/kp_mode"; echo Y > "$T/auto_kp"
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
# auto_kp in the 0/1 style: written as 1/0, saved as Y/N, re-applied as 1/0 at boot
echo 0 > "$T/kp_mode"; echo 0 > "$T/auto_kp"; rm -rf "$T/cfg"; set_kernel_source
sh "$KPSH" auto Y >/dev/null; check "auto on, node in 0/1 style: exit" 0 "$?"
check "auto on, node in 0/1 style: written as 1" 1 "$(cat "$T/auto_kp")"
check "auto on, node in 0/1 style: saved as Y" Y "$(sed -n 's/^AUTO=//p' "$T/cfg/config")"
sh "$KPSH" auto N >/dev/null; check "auto off, node in 0/1 style: exit" 0 "$?"
check "auto off, node in 0/1 style: written as 0" 0 "$(cat "$T/auto_kp")"
sh "$KPSH" auto Y >/dev/null; echo 0 > "$T/auto_kp"; echo 0 > "$T/kp_mode"
sh "$KPSH" apply >/dev/null; check "boot apply, node in 0/1 style: exit" 0 "$?"
check "boot apply, node in 0/1 style: auto re-applied as 1" 1 "$(cat "$T/auto_kp")"
echo Y > "$T/auto_kp"; sh "$KPSH" auto N >/dev/null
check "node in Y/N style still gets Y/N" N "$(cat "$T/auto_kp")"
# persist 1 normalizes the *live* numeric auto_kp value before saving; it must never persist AUTO=0/1.
echo 0 > "$T/kp_mode"; echo 0 > "$T/auto_kp"; rm -rf "$T/cfg"; set_kernel_source
sh "$KPSH" persist 1 >/dev/null; check "persist 1 with numeric auto_kp saves N, not 0" N "$(sed -n 's/^AUTO=//p' "$T/cfg/config")"
echo 1 > "$T/auto_kp"; sh "$KPSH" persist 1 >/dev/null
check "persist 1 with numeric auto_kp saves Y, not 1" Y "$(sed -n 's/^AUTO=//p' "$T/cfg/config")"
rm -f "$T/inj.sh" "$T/probe.sh" "$T/mvlog" "$T/mvn"

# --- where Kprofiles is found: upstream module parameters, /sys/kernel/kprofiles, both, neither, or only part ---
LAY="$T/layouts"
lay() { rm -rf "$LAY"; mkdir -p "$LAY/sys/kernel/kprofiles" "$LAY/sys/module/kprofiles/parameters" "$LAY/cfg"
        printf 'SOURCE=kernel\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$LAY/cfg/control.conf"; }
KL() { ( unset KP_PATH AUTO_PATH CONTROL_FILE CONTROL_DIR; export KP_SYSROOT="$LAY" CFG_DIR="$LAY/cfg"; sh "$KPSH" "$@" ); }
PM="$LAY/sys/module/kprofiles/parameters"; KD="$LAY/sys/kernel/kprofiles"
lay; echo 0 > "$PM/kp_mode"; echo N > "$PM/auto_kp"                    # the upstream driver's module parameters only
check "upstream layout: Kprofiles is supported" "mode=0 auto=N persist=1 support=supported auto_support=supported" "$(KL status)"
KL mode 2 >/dev/null; check "upstream layout: the mode is written to the module parameter" 2 "$(cat "$PM/kp_mode")"
KL auto Y >/dev/null; check "upstream layout: auto_kp is written to the module parameter" Y "$(cat "$PM/auto_kp")"
check "upstream layout: nothing is created under /sys/kernel/kprofiles" 0 "$(ls "$KD" | wc -l | tr -d ' ')"
lay; echo 0 > "$KD/kp_mode"; echo N > "$PM/auto_kp"                    # Theettam: mode under /sys/kernel, auto_kp as a parameter
check "Theettam layout: supported" "mode=0 auto=N persist=1 support=supported auto_support=supported" "$(KL status)"
KL mode 3 >/dev/null; check "Theettam layout: the mode is written under /sys/kernel/kprofiles" 3 "$(cat "$KD/kp_mode")"
check "Theettam layout: no module-parameter mode file appears" no "$([ -e "$PM/kp_mode" ] && echo yes || echo no)"
lay; echo 0 > "$KD/kp_mode"; echo 0 > "$PM/kp_mode"; echo N > "$PM/auto_kp"   # both mode nodes exist: the one that always worked wins
KL mode 2 >/dev/null; check "both mode nodes: /sys/kernel/kprofiles is used" 2 "$(cat "$KD/kp_mode")"
check "both mode nodes: the other one is left alone" 0 "$(cat "$PM/kp_mode")"
lay; echo 0 > "$KD/kp_mode"; echo N > "$KD/auto_kp"                    # auto_kp only under /sys/kernel/kprofiles
check "auto_kp under /sys/kernel/kprofiles is found" "mode=0 auto=N persist=1 support=supported auto_support=supported" "$(KL status)"
KL auto Y >/dev/null; check "auto_kp under /sys/kernel/kprofiles is written there" Y "$(cat "$KD/auto_kp")"
lay                                                                      # no Kprofiles at all
check "no Kprofiles: reported as absent" "mode=? auto=? persist=1 support=unsupported auto_support=unsupported" "$(KL status)"
KL mode 2 >/dev/null 2>&1; check "no Kprofiles: a mode write fails" 1 "$?"
check "no Kprofiles: no file is created anywhere" 0 "$(find "$LAY/sys" -type f | wc -l | tr -d ' ')"
lay; echo 0 > "$PM/kp_mode"                                            # mode only, no auto_kp
check "mode without auto_kp: auto is reported as absent" "mode=0 auto=? persist=1 support=supported auto_support=unsupported" "$(KL status)"
KL auto Y >/dev/null 2>&1; check "mode without auto_kp: an auto write fails" 1 "$?"
KL mode 1 >/dev/null; check "mode without auto_kp: the mode still works" 1 "$(cat "$PM/kp_mode")"
lay; echo 0 > "$PM/kp_mode"; echo N > "$PM/auto_kp"; echo 3 > "$T/custom_mode"   # an explicit path (tests, power users) beats discovery
check "KP_PATH still overrides discovery" 3 "$( ( unset AUTO_PATH CONTROL_FILE CONTROL_DIR; export KP_SYSROOT="$LAY" CFG_DIR="$LAY/cfg" KP_PATH="$T/custom_mode"; sh "$KPSH" status ) | sed -n 's/^mode=\([0-9?]*\) .*/\1/p')"
[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
