#!/bin/sh
# Off-device test of module/tune.sh using a fake sysfs tree that mirrors a POCO F6 (peridot).
HERE=$(cd "$(dirname "$0")" && pwd)
TUNE="$HERE/../module/tune.sh"
T=$(mktemp -d)
# Stop every watcher this test run started (found by its environment, so even one whose pid file is gone
# is found). A watcher that outlives its section keeps re-applying limits to the next fake phone.
reap() {
  rp=""
  # One grep over all command lines finds the few candidates; only those get a closer look. Errors for
  # processes we may not read are silenced around the redirection itself (a redirection that fails is
  # reported by the shell, not by the command, so a plain 2>/dev/null after it is not enough).
  for e in $(grep -l 'tune.sh' /proc/[0-9]*/cmdline 2>/dev/null); do
    p=${e%/cmdline}
    case "$({ tr '\0' ' ' < "$e"; } 2>/dev/null)" in *"tune.sh daemon"*) ;; *) continue ;; esac
    { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "CFG_DIR=$T/cfg" || continue
    rp="$rp ${p#/proc/}"
  done
  [ -n "$rp" ] || return 0
  # shellcheck disable=SC2086
  kill $rp 2>/dev/null
  rk=0; while [ "$rk" -lt 30 ]; do
    ra=""; for q in $rp; do kill -0 "$q" 2>/dev/null && ra="$ra $q"; done
    [ -n "$ra" ] || return 0
    sleep 0.1 2>/dev/null || sleep 1; rk=$((rk + 1))
  done
  # shellcheck disable=SC2086
  kill -9 $ra 2>/dev/null
  return 0
}
# Also stops the background "sleep" stand-ins this test starts (a run that is interrupted or aborted must not
# leave one behind: it would keep the caller's output pipe open for minutes and look like a stalled test).
cleanup() { chattr -i "$T/kp/kp_mode" 2>/dev/null; for bg in ${bystander:-} ${other:-} ${holder:-}; do kill "$bg" 2>/dev/null; done; reap; rm -rf "$T"; }
trap cleanup EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
has()   { case "$3" in *"$2"*) echo "ok   $1" ;; *) echo "FAIL $1: '$3' lacks '$2'"; fail=1 ;; esac; }

mkpol() { # dir avail min max
  mkdir -p "$1"; echo "$2" > "$1/scaling_available_frequencies"
  echo "$3" > "$1/scaling_min_freq"; echo "$4" > "$1/scaling_max_freq"; echo walt > "$1/scaling_governor"
}
mksys() { # the kernel's own files, exactly as a freshly booted phone has them (a reboot resets these)
  mkdir -p "$T/bl" "$T/kp"
  mkpol "$T/cpufreq/policy0" "364800 441600 595200 787200 902400 1017600 1113600 1228800 1344000 1478400 1593600 1708800 1843200 1900800 2016000" 595200 2016000
  mkpol "$T/cpufreq/policy3" "480000 633600 787200 940800 1056000 1190400 1286400 1401600 1497600 1593600 1708800 1824000 1920000 2073600 2188800 2361600 2572800 2611200 2707200" 633600 2572800
  mkpol "$T/cpufreq/policy7" "480000 633600 787200 960000 1094400 1209600 1324800 1459200 1651200 1766400 1900800 2150400 2304000 2457600 2668800 2803200 2918400" 633600 2668800
  mkdir -p "$T/gpu"; echo "1100000000 1000000000 950000000 900000000 835000000 736000000 684000000 633000000 500000000 353000000 255000000" > "$T/gpu/available_frequencies"
  echo 255000000 > "$T/gpu/min_freq"; echo 900000000 > "$T/gpu/max_freq"
  echo 120 > "$T/bl/brightness"; echo 0 > "$T/kp/kp_mode"; echo N > "$T/kp/auto_kp"
}
mkfake() {
  reap; chattr -i "$T/kp/kp_mode" 2>/dev/null
  rm -rf "$T/cpufreq" "$T/gpu" "$T/cfg" "$T/kp"
  mksys
  # Make fixture ownership explicit; a missing state file is now tested separately as legacy migration.
  mkdir -p "$T/cfg"
  printf 'SOURCE=module\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$T/cfg/control.conf"
}
export TUNE_CAP_SAMPLES=1 TUNE_CAP_GAP=0 TUNE_CAP_BOOT_SAMPLES=1 TUNE_CAP_BOOT_GAP=0
export CPUFREQ_DIR="$T/cpufreq" GPU_DIR="$T/gpu" BL_PATH="$T/bl/brightness" CFG_DIR="$T/cfg" TUNE_NO_DAEMON=1 KP_PATH="$T/kp/kp_mode" AUTO_PATH="$T/kp/auto_kp"
v() { cat "$T/$1"; }
# A node that reads a valid mode but refuses writes. As a normal user a read-only file does it; as root file
# modes are ignored, so the immutable flag is used. If neither blocks writes here, the check is skipped.
refuse_writes() { chmod 444 "$1"; if ( : >> "$1" ) 2>/dev/null; then chattr +i "$1" 2>/dev/null; fi; ! ( : >> "$1" ) 2>/dev/null; }
allow_writes() { chattr -i "$1" 2>/dev/null; chmod 644 "$1" 2>/dev/null; }
waitfor() { # name expected file seconds   (poll instead of a fixed sleep, so slow runners do not flake)
  i=0
  while [ "$i" -lt "$4" ]; do
    if [ "$(cat "$T/$3")" = "$2" ]; then echo "ok   $1"; return; fi
    sleep 1; i=$((i + 1))
  done
  echo "FAIL $1: expected '$2' got '$(cat "$T/$3")'"; fail=1
}
S() { export TUNE_START_TRIES TUNE_LOCK_TRIES TUNE_BOOT_RETRIES TUNE_BOOT_WAIT; sh "$TUNE" "$@"; }
# Failure injection that works in EVERY shell. A stand-in grep or mv placed first in PATH is NOT enough:
# busybox ash runs its own built-in applets and never looks at PATH for them, so such a test silently
# injected nothing there. A shell FUNCTION with the command's name beats both the built-in applet and the
# real command. inj writes a small runner that defines the functions and then runs tune.sh (as a dotted
# file, so the functions are in force inside it); SI runs it with the given arguments.
inj() { printf '%s\n. "$INJ_TARGET"\n' "$1" > "$T/inj.sh"; }
SI() { INJ_TARGET="$TUNE" sh "$T/inj.sh" "$@"; }

mkfake
echo "--- initial ---"
out=$(S status); has "status: stock/disabled" "enabled=0" "$out"; has "status: preset" "preset=stock" "$out"
has "status: defaults captured" "def_big_max=2572800" "$out"
out=$(S lists); has "lists: little" "little=364800 441600" "$out"; has "lists: gpu" "gpu=1100000000" "$out"

echo "--- preset tilt, screen on ---"
S preset tilt >/dev/null
check "on: big max"    2188800   "$(v cpufreq/policy3/scaling_max_freq)"
check "on: prime max"  2457600   "$(v cpufreq/policy7/scaling_max_freq)"
check "on: gpu max"    736000000 "$(v gpu/max_freq)"
check "on: little untouched" 2016000 "$(v cpufreq/policy0/scaling_max_freq)"
check "on: mins untouched"   633600  "$(v cpufreq/policy3/scaling_min_freq)"

echo "--- screen off ---"
echo 0 > "$T/bl/brightness"; S apply >/dev/null
check "off: little max" 1017600   "$(v cpufreq/policy0/scaling_max_freq)"
check "off: big max"    787200    "$(v cpufreq/policy3/scaling_max_freq)"
check "off: prime max"  633600    "$(v cpufreq/policy7/scaling_max_freq)"
check "off: gpu max"    353000000 "$(v gpu/max_freq)"

echo "--- screen on again: restore anything the on-set leaves default ---"
echo 120 > "$T/bl/brightness"; S apply >/dev/null
check "back: little restored to system default" 2016000 "$(v cpufreq/policy0/scaling_max_freq)"
check "back: big on-set"   2188800   "$(v cpufreq/policy3/scaling_max_freq)"
check "back: gpu on-set"   736000000 "$(v gpu/max_freq)"

echo "--- validation ---"
out=$(S cfg ON_BIG_MAX 9999); has "reject unknown freq" "error:" "$out"
out=$(S cfg ON_BIG_MAX abc);  has "reject non-number" "error:" "$out"
out=$(S cfg ON_BIG_MIN 2572800); has "reject min above max" "error: min must not be above max" "$out"
out=$(S cfg ON_NOPE_MAX 1); has "reject unknown key" "error: unknown setting" "$out"
out=$(S cfg ENABLED 5); has "reject bad switch" "error:" "$out"
check "bad input changed nothing" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- custom values ---"
S cfg ON_LITTLE_MAX 1593600 >/dev/null
check "custom little max" 1593600 "$(v cpufreq/policy0/scaling_max_freq)"
out=$(S status); has "preset becomes custom" "preset=custom" "$out"
S cfg ON_BIG_MIN 787200 >/dev/null
check "custom big min" 787200 "$(v cpufreq/policy3/scaling_min_freq)"
S cfg ON_BIG_MIN default >/dev/null
check "min back to system default" 633600 "$(v cpufreq/policy3/scaling_min_freq)"

echo "--- implicit clamp (max below the system min) ---"
S cfg ON_PRIME_MAX 480000 >/dev/null
check "prime max 480000" 480000 "$(v cpufreq/policy7/scaling_max_freq)"
check "prime min lowered to match" 480000 "$(v cpufreq/policy7/scaling_min_freq)"

echo "--- stock restores the phone's own values ---"
S preset stock >/dev/null
check "stock: little max" 2016000 "$(v cpufreq/policy0/scaling_max_freq)"
check "stock: big max"    2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "stock: prime max"  2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "stock: prime min"  633600  "$(v cpufreq/policy7/scaling_min_freq)"
check "stock: gpu max"    900000000 "$(v gpu/max_freq)"

echo "--- performance profile leaves the phone's own frequency limits in control without a poller ---"
mkfake; unset TUNE_NO_DAEMON; S preset tilt >/dev/null
out=$(S preset performance); rc=$?; check "performance preset applies cleanly" 0 "$rc"
out=$(S status); has "performance preset is named" "preset=performance" "$out"; has "performance leaves limits enabled but does not screen-off-cap" "screenoff=0" "$out"
has "performance does not keep an unnecessary background watcher" "daemon=0" "$out"
has "performance reports that no watcher is needed" "watcher_needed=0" "$out"
export TUNE_NO_DAEMON=1
check "performance restores little max" 2016000 "$(v cpufreq/policy0/scaling_max_freq)"
check "performance restores big max" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "performance restores prime max" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "performance restores GPU max" 900000000 "$(v gpu/max_freq)"

echo "--- screen-on limits without screen-off caps still keep the watcher (re-assert and hand-back) ---"
mkfake; unset TUNE_NO_DAEMON; S preset tilt >/dev/null
S cfg SCREENOFF 0 >/dev/null
out=$(S status); has "custom screen-on caps without screen-off caps still need a watcher" "watcher_needed=1" "$out"; has "and the watcher is running" "daemon=1" "$out"
S preset performance >/dev/null
out=$(S status); has "switching to performance then stops the watcher" "daemon=0" "$out"
export TUNE_NO_DAEMON=1

echo "--- dynamic profile leaves screen-on unrestricted and caps screen-off ---"
mkfake; S preset dynamic >/dev/null
out=$(S status); has "dynamic preset is named" "preset=dynamic" "$out"; has "dynamic uses screen-off sets" "screenoff=1" "$out"
check "dynamic screen-on big max remains stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "dynamic screen-on GPU max remains stock" 900000000 "$(v gpu/max_freq)"
echo 0 > "$T/bl/brightness"; S apply >/dev/null
check "dynamic screen-off little cap" 1017600 "$(v cpufreq/policy0/scaling_max_freq)"
check "dynamic screen-off big cap" 787200 "$(v cpufreq/policy3/scaling_max_freq)"
check "dynamic screen-off prime cap" 633600 "$(v cpufreq/policy7/scaling_max_freq)"
check "dynamic screen-off GPU cap" 353000000 "$(v gpu/max_freq)"
echo 120 > "$T/bl/brightness"; S apply >/dev/null
check "dynamic screen-on returns big max to stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "dynamic screen-on returns GPU max to stock" 900000000 "$(v gpu/max_freq)"

echo "--- custom profile preserves existing values and opens the editor ---"
mkfake; S preset tilt >/dev/null
out=$(S preset custom); rc=$?; check "custom profile command succeeds" 0 "$rc"
out=$(S status); has "custom preset is named" "preset=custom" "$out"; has "custom preset remains enabled" "enabled=1" "$out"
check "custom keeps existing on-state value" 2188800 "$(sed -n 's/^ON_BIG_MAX=//p' "$T/cfg/tune.conf")"
check "custom keeps existing off-state value" 787200 "$(sed -n 's/^OFF_BIG_MAX=//p' "$T/cfg/tune.conf")"
S cfg ON_BIG_MAX 1593600 >/dev/null
check "custom editor can change a value after selecting Custom" 1593600 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- nodes the user never set are never written ---"
mkfake; S status >/dev/null
echo 902400 > "$T/cpufreq/policy0/scaling_min_freq"     # pretend Android boosted it
S preset tilt >/dev/null; S apply >/dev/null
check "system boost on untouched node survives" 902400 "$(v cpufreq/policy0/scaling_min_freq)"

echo "--- screen-off sets can be turned off ---"
S cfg SCREENOFF 0 >/dev/null
echo 0 > "$T/bl/brightness"; S apply >/dev/null
check "screenoff=0: stays on on-set (big)" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
check "screenoff=0: little back to default" 2016000 "$(v cpufreq/policy0/scaling_max_freq)"
S cfg SCREENOFF 1 >/dev/null; echo 120 > "$T/bl/brightness"

echo "--- missing hardware nodes ---"
mkfake; rm -rf "$T/gpu"
out=$(S preset tilt); has "missing gpu: warns" "warn: gpu controls not found" "$out"
check "missing gpu: cpu still applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake; rm -f "$T/bl/brightness"; S preset tilt >/dev/null
out=$(S status); has "no backlight node: treated as screen on" "state=on" "$out"

echo "--- boot: a real reboot (the kernel files return to the phone's own values) ---"
mkfake; S preset tilt >/dev/null
check "before reboot: limits are applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
mksys                                                   # reboot: sysfs is reset, saved config on disk stays
out=$(S boot); has "boot reports" "boot done: enabled=1 preset=tilt" "$out"
out=$(S status)
has "boot recorded the phone's REAL big max as stock" "def_big_max=2572800" "$out"
has "boot recorded the phone's REAL gpu max as stock" "def_gpu_max=900000000" "$out"
check "boot re-applied the saved on-set (big)" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
S preset stock >/dev/null
check "Stock after reboot restores the real value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- boot re-records stock even if the phone's own values changed (for example after a ROM update) ---"
mkfake; S preset tilt >/dev/null
mksys; echo 2611200 > "$T/cpufreq/policy3/scaling_max_freq"   # the update moved the phone's own big max
S boot >/dev/null
out=$(S status); has "boot recorded the NEW stock value" "def_big_max=2611200" "$out"
S preset stock >/dev/null
check "Stock restores the NEW stock value, not the old one" 2611200 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- defaults are never recorded from a capped or already-limited state ---"
mkfake; echo 1 > "$T/kp/kp_mode"                         # kernel Battery profile active, defaults not recorded yet
out=$(S status); has "kernel Battery active: nothing recorded as stock" "def_big_max=" "$out"
check "no defaults file written" "no" "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"
echo 0 > "$T/kp/kp_mode"; out=$(S status)
has "after the kernel profile is None: recorded" "def_big_max=2572800" "$out"
mkfake; S preset tilt >/dev/null; rm -f "$T/cfg/defaults"
out=$(S status); has "own limits in place: not recorded as stock" "def_big_max=" "$out"
check "still no defaults file" "no" "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"

echo "--- Reset everything: stock limits AND kernel profile ---"
mkfake; S preset saver >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 1 >/dev/null
check "kernel profile Battery set" 1 "$(v kp/kp_mode)"
S resetall >/dev/null
check "resetall: big max stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "resetall: gpu max stock" 900000000 "$(v gpu/max_freq)"
check "resetall: kernel profile None" 0 "$(v kp/kp_mode)"
out=$(S status); has "resetall: limits disabled" "enabled=0" "$out"

echo "--- uninstall restores limits, resets the kernel profile, removes saved settings ---"
mkfake; S preset tilt >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 3 >/dev/null
check "performance profile set" 3 "$(v kp/kp_mode)"
# the shipped script deletes a fixed path, so run a copy whose target is the fixture folder
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh"
check "uninstall: big max restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "uninstall: prime max restored" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "uninstall: gpu max restored" 900000000 "$(v gpu/max_freq)"
check "uninstall: kernel profile None" 0 "$(v kp/kp_mode)"
check "uninstall: saved settings removed" "no" "$([ -d "$T/cfg" ] && echo yes || echo no)"

echo "--- uninstall on a kernel whose kernel-profile node is not standard ---"
for kind in "unknown value 4" "unreadable (a folder)"; do
  mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -f "$T/kp/kp_mode"
  if [ "$kind" = "unknown value 4" ]; then echo 4 > "$T/kp/kp_mode"; else mkdir "$T/kp/kp_mode"; fi
  sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
  check "uninstall, profile $kind: exits 0" 0 "$rc"
  check "uninstall, profile $kind: the limits were restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
  check "uninstall, profile $kind: saved settings removed" "no" "$([ -d "$T/cfg" ] && echo yes || echo no)"
  rm -rf "$T/kp/kp_mode"; echo 0 > "$T/kp/kp_mode"
done

echo "--- tune.sh never writes the kernel profile directly (kp.sh is its only writer) ---"
check "no direct write to the kernel profile node" 0 "$(grep -c 'wr "\$KPNODE"\|> *"\$KPNODE"' "$TUNE")"

echo "--- background watcher ---"
mkfake; unset TUNE_NO_DAEMON
export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3
S preset tilt >/dev/null
i=0; while [ "$i" -lt 10 ]; do out=$(S status); case "$out" in *daemon=1*) break ;; esac; sleep 1; i=$((i + 1)); done
has "watcher running" "daemon=1" "$out"
echo 0 > "$T/bl/brightness"
waitfor "watcher: screen off applied" 1017600 cpufreq/policy0/scaling_max_freq 15
echo 120 > "$T/bl/brightness"
waitfor "watcher: screen on restored" 2016000 cpufreq/policy0/scaling_max_freq 15
echo 2572800 > "$T/cpufreq/policy3/scaling_max_freq"      # something outside changes our limit
waitfor "watcher: drift re-asserted" 2188800 cpufreq/policy3/scaling_max_freq 20
S cfg ENABLED 0 >/dev/null
i=0; while [ "$i" -lt 10 ]; do out=$(S status); case "$out" in *daemon=0*) break ;; esac; sleep 1; i=$((i + 1)); done
has "watcher stopped after disable" "daemon=0" "$out"
waitfor "disable restored big max" 2572800 cpufreq/policy3/scaling_max_freq 10
export TUNE_NO_DAEMON=1

echo "--- preset values are checked against the phone's own list ---"
mkfake; export TUNE_NO_DAEMON=1
sed -i 's/ 1017600//' "$T/cpufreq/policy0/scaling_available_frequencies"   # this phone lacks 1017600
out=$(S preset tilt); has "preset skips unavailable value" "warn: preset value 1017600 is not available for little" "$out"
check "skipped value not saved" "" "$(sed -n 's/^OFF_LITTLE_MAX=//p' "$T/cfg/tune.conf")"
check "valid preset values still applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- boot order: the real service.sh records stock BEFORE it applies the kernel profile ---"
# A copy of the shipped service.sh and the module, with only three things changed so it can run here:
# the data folder, the 25 s settle wait, and a getprop that says "boot completed".
mksvc() {
  rm -rf "$T/svc"; mkdir -p "$T/svc/bin"; cp "$HERE/../module/"*.sh "$T/svc/"
  sed -e "s|^D=/data/adb/kprofiles_ui\$|D=$T/cfg|" -e 's|^sleep 25$|sleep 0|' "$HERE/../module/service.sh" > "$T/svc/service.sh"
  # Fake sysfs does not emulate the Kprofiles driver's mode-1 -> mode-0 release side effect.
  # Simulate its known Battery big-cluster cap release; deliberately empty node files remain empty.
  python3 - "$T/svc/kp.sh" <<'PYKP'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '  { echo "$1" > "$KP"; } 2>/dev/null\n  now=$(read_mode)\n'
replacement = '''  mode_before=$(read_mode)
  { echo "$1" > "$KP"; } 2>/dev/null
  if [ "$1" = 0 ] && [ "$mode_before" = 1 ] && [ "$(cat "$CPUFREQ_DIR/policy3/scaling_max_freq" 2>/dev/null)" = 1286400 ]; then
    echo 2572800 > "$CPUFREQ_DIR/policy3/scaling_max_freq"
  fi
  now=$(read_mode)
'''
if needle not in s:
    raise SystemExit('fake kp mode write not found')
p.write_text(s.replace(needle, replacement, 1))
PYKP
  printf '#!/bin/sh\necho 1\n' > "$T/svc/bin/getprop"; chmod +x "$T/svc/bin/getprop"
}
runsvc() { PATH="$T/svc/bin:$PATH" TUNE_BOOT_WAIT=0 TUNE_BOOT_RETRIES=2 sh "$T/svc/service.sh"; }
kpsave() {
  # This fixture represents a user who chose Kernel profile, saved the requested mode, then rebooted.
  printf 'SOURCE=kernel\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$T/cfg/control.conf"
  sh "$HERE/../module/kp.sh" mode "$1" >/dev/null
  echo 0 > "$T/kp/kp_mode"
}
mksvc
check "service copy: data folder replaced" 1 "$(grep -c "^D=$T/cfg\$" "$T/svc/service.sh")"
check "service copy: settle wait replaced" 1 "$(grep -c '^sleep 0$' "$T/svc/service.sh")"
mkfake; kpsave 1; runsvc
check "boot: stock was recorded first (big max)" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
check "boot: stock was recorded first (big min)" 633600 "$(sed -n 's/^big_min=//p' "$T/cfg/defaults")"
check "boot: the kernel profile was applied afterwards" 1 "$(v kp/kp_mode)"
has "boot.log: reports stock capture before kernel apply" "boot capture-only done" "$(cat "$T/cfg/boot.log")"

echo "--- boot: the phone's own limits cannot be saved and none are on record ---"
mkfake; kpsave 1; mkdir -p "$T/cfg/defaults"          # the snapshot file cannot be written (it is a folder)
S boot capture-only >/dev/null; rc=$?
check "no record, save fails: tune.sh boot exits 2" 2 "$rc"
check "no record, save fails: the log says so" 1 "$(grep -c 'not on record; the kernel profile is not applied' "$T/cfg/tune.log")"
runsvc
check "no record, save fails: the kernel profile is NOT applied" 0 "$(v kp/kp_mode)"
has "no record, save fails: boot.log reports it" "kernel profile was NOT applied" "$(cat "$T/cfg/boot.log")"
has "no record, save fails: boot.log has the status" "exit status 2" "$(cat "$T/cfg/boot.log")"
mkfake; kpsave 1; mkdir -p "$T/cfg/defaults.tmp"      # the temporary file cannot be written (it is a folder)
runsvc
check "no record, temp file fails: the kernel profile is NOT applied" 0 "$(v kp/kp_mode)"
check "no record, temp file fails: nothing was recorded" no "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"

echo "--- boot: a legacy active kernel cap is released before stock capture ---"
mkfake; printf 'SOURCE=kernel\nKP_MODE_PREF=0\nKP_AUTO_PREF=N\n' > "$T/cfg/control.conf"; sh "$HERE/../module/kp.sh" mode 3 >/dev/null; rm -f "$T/cfg/control.conf"; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"   # saved choice 3, legacy boot at Battery
runsvc
check "Battery active, no record: saved kernel profile is re-applied after stock capture" 3 "$(v kp/kp_mode)"
has "Battery active, no record: boot.log records stock capture" "boot capture-only done" "$(cat "$T/cfg/boot.log")"
has "Battery active, no record: saved preference is reported" "mode=3" "$(cat "$T/cfg/boot.log")"
check "Battery active, no record: released stock big max is recorded" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults" 2>/dev/null)"
mkfake; S boot >/dev/null; kpsave 3; echo 1 > "$T/kp/kp_mode"
runsvc
check "Battery active, earlier record: the saved kernel profile IS applied" 3 "$(v kp/kp_mode)"

echo "--- boot: no usable frequency value can be read at all ---"
blank() {
  # shellcheck disable=SC2016
  find "$T/cpufreq" "$T/gpu" -type f -exec sh -c 'for bf do : > "$bf"; done' sh {} + 2>/dev/null
}   # every node reads empty
mkfake; blank
S boot >/dev/null; rc=$?
check "all reads empty, no record: tune.sh boot exits 2" 2 "$rc"
check "all reads empty, no record: no snapshot file is left" no "$([ -e "$T/cfg/defaults" ] && echo yes || echo no)"
check "all reads empty, no record: the log says so" 1 "$(grep -c 'no usable frequency values were read; no stock record exists' "$T/cfg/tune.log")"
mkfake; rm -rf "$T/cpufreq" "$T/gpu"
S boot >/dev/null; rc=$?
check "all nodes missing, no record: tune.sh boot exits 2" 2 "$rc"
check "all nodes missing, no record: no snapshot file is left" no "$([ -e "$T/cfg/defaults" ] && echo yes || echo no)"
mkfake; S boot >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"; blank
S boot >/dev/null; rc=$?
check "all reads empty, earlier record: boot exits 0 (the record is kept)" 0 "$rc"
check "all reads empty, earlier record: the record is byte-for-byte unchanged" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
mkfake; S boot >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"; rm -rf "$T/cpufreq" "$T/gpu"
S boot >/dev/null; rc=$?
check "all nodes missing, earlier record: boot exits 0" 0 "$rc"
check "all nodes missing, earlier record: the record is byte-for-byte unchanged" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
check "all nodes missing, earlier record: the log says it was kept" 1 "$(grep -c 'the earlier stock record is kept' "$T/cfg/tune.log")"
mkfake; mkdir -p "$T/cfg"; : > "$T/cfg/defaults"                    # a stale zero-byte file
out=$(S status); has "empty defaults file: Status records a real snapshot" "def_big_max=2572800" "$out"
check "empty defaults file: replaced by a real snapshot" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake; mkdir -p "$T/cfg"; : > "$T/cfg/defaults"; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
out=$(S preset tilt); has "empty defaults file, Battery on: Apply says nothing is recorded" "not recorded yet" "$out"
S boot >/dev/null; rc=$?; check "empty defaults file, Battery on: tune.sh boot exits 2" 2 "$rc"
mkfake; mkdir -p "$T/cfg"; : > "$T/cfg/defaults"; blank
out=$(S preset tilt); rc=$?
check "empty defaults file, nothing readable: Apply refuses to change a limit" 1 "$rc"
has "empty defaults file, nothing readable: Apply says why" "so no limit was changed" "$out"
mkfake; kpsave 1; blank; runsvc
check "service.sh, all reads empty: the kernel profile is NOT applied" 0 "$(v kp/kp_mode)"
has "service.sh, all reads empty: boot.log has the no-record status" "no usable stock record exists" "$(cat "$T/cfg/boot.log")"
check "service.sh, all reads empty: no snapshot file" no "$([ -e "$T/cfg/defaults" ] && echo yes || echo no)"

echo "--- boot: the save fails but an earlier record exists ---"
mkfake; S boot >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"; kpsave 1; mkdir "$T/cfg/defaults.tmp"
S boot >/dev/null; rc=$?
check "earlier record, save fails: tune.sh boot exits 1" 1 "$rc"
runsvc
check "earlier record, save fails: the record is untouched" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
check "earlier record, save fails: the kernel profile IS applied" 1 "$(v kp/kp_mode)"
has "earlier record, save fails: boot.log reports the refresh problem" "status 1" "$(cat "$T/cfg/boot.log")"

echo "--- boot: another error (unreadable settings) still applies the kernel profile ---"
mkfake; kpsave 1; mkdir -p "$T/cfg/tune.conf"
runsvc
check "other error: the kernel profile IS applied" 1 "$(v kp/kp_mode)"
check "other error: stock was still recorded" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"

echo "--- boot: tune.sh cannot run at all ---"
mkfake; kpsave 1; rm -f "$T/svc/tune.sh"
runsvc
check "tune.sh missing: the kernel profile is NOT applied" 0 "$(v kp/kp_mode)"
has "tune.sh missing: boot.log says the profile was skipped" "kernel profile was NOT applied" "$(cat "$T/cfg/boot.log")"
mksvc

echo "--- the shipped uninstall.sh deletes one fixed folder and reads nothing from the environment ---"
check "uninstall.sh: fixed delete target" 1 "$(grep -c '^ *rm -rf /data/adb/kprofiles_ui$' "$HERE/../module/uninstall.sh")"
check "uninstall.sh: no variable in any rm line" 0 "$(grep 'rm ' "$HERE/../module/uninstall.sh" | grep -c '\$')"

echo "--- preset check fails closed when the list cannot be read ---"
mkfake; rm -f "$T/cpufreq/policy3/scaling_available_frequencies"      # controls exist, list is gone
out=$(S preset tilt); has "unreadable list: warns" "warn: preset value 2188800 skipped for big because the phone's list" "$out"
check "unreadable list: value not saved" "" "$(sed -n 's/^ON_BIG_MAX=//p' "$T/cfg/tune.conf")"
check "unreadable list: nothing written" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "unreadable list: other clusters still applied" 2457600 "$(v cpufreq/policy7/scaling_max_freq)"
mkfake; : > "$T/cpufreq/policy3/scaling_available_frequencies"          # empty list counts as unreadable
out=$(S preset tilt); has "empty list: warns" "could not be read" "$out"
check "empty list: nothing written" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- Stock says so when it has no recorded values to restore from ---"
mkfake; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"   # kernel Battery on before anything was recorded
out=$(S preset tilt); rc=$?; check "no stock recorded: Apply is refused" 1 "$rc"
has "no stock recorded: Apply says what is not on record" "not on record for" "$out"
check "no stock recorded: nothing was written" 1286400 "$(v cpufreq/policy3/scaling_max_freq)"
check "no stock recorded: nothing was marked as changed" no "$([ -s "$T/cfg/applied" ] && echo yes || echo no)"
out=$(S preset stock); rc=$?; check "no stock recorded: Stock has nothing to restore and says ok" 0 "$rc"
mksys; S boot >/dev/null                                                # a reboot records the real values
out=$(S preset tilt); case "$out" in *"not recorded yet"*) echo "FAIL warning persists after boot"; fail=1 ;; *) echo "ok   no warning once stock is recorded" ;; esac
S preset stock >/dev/null
check "after the reboot Stock restores the real value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- the watcher hands the limits back when the module is disabled or removed ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3 TUNE_DAEMON_LOG="$T/daemon.log"
for marker in disable remove; do
  : > "$T/daemon.log"
  mkfake; rm -rf "$T/mod"; mkdir -p "$T/mod"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$HERE/../module/control-lib.sh" "$T/mod/"   # tune.sh looks for the marker and controller library in its own folder
  S2() { sh "$T/mod/tune.sh" "$@"; }
  S2 preset tilt >/dev/null
  i=0; while [ "$i" -lt 10 ]; do out=$(S2 status); case "$out" in *daemon=1*) break ;; esac; sleep 1; i=$((i + 1)); done
  has "$marker test: watcher running" "daemon=1" "$out"
  check "$marker test: limit applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
  touch "$T/mod/$marker"
  waitfor "$marker marker: limit handed back" 2572800 cpufreq/policy3/scaling_max_freq 30
  if [ "$(v cpufreq/policy3/scaling_max_freq)" != 2572800 ]; then   # leave evidence in the log if this ever fails again
    echo "diag: $(S2 status | grep -E '^(enabled|daemon|state)=' | tr '\n' ' ')"
    echo "diag: pidfile=$(cat "$T/cfg/daemon.pid" 2>/dev/null) markers=$(ls "$T/mod" | tr '\n' ' ')"
    echo "diag: shells running tune.sh: $(grep -l 'tune.sh' /proc/[0-9]*/cmdline 2>/dev/null | wc -l)"
    wpd=$(cat "$T/cfg/daemon.pid" 2>/dev/null)
    echo "diag: watcher pid '$wpd' alive=$(kill -0 "$wpd" 2>/dev/null && echo yes || echo no) args='$(tr '\0' ' ' < "/proc/$wpd/cmdline" 2>/dev/null)'"
    echo "diag: config: $(tr '\n' ' ' < "$T/cfg/tune.conf" 2>/dev/null | cut -c1-300)"
    echo "diag: defaults: $(tr '\n' ' ' < "$T/cfg/defaults" 2>/dev/null)  applied: $(tr '\n' ' ' < "$T/cfg/applied" 2>/dev/null)"
    echo "diag: tune.log: $(tr '\n' ' ' < "$T/cfg/tune.log" 2>/dev/null)"
    echo "diag: watcher output: $(tr '\n' ' ' < "$T/daemon.log" 2>/dev/null | cut -c1-600)"
  fi
  i=0; while [ "$i" -lt 10 ]; do out=$(S2 status); case "$out" in *daemon=0*) break ;; esac; sleep 1; i=$((i + 1)); done
  has "$marker marker: watcher stopped" "daemon=0" "$out"
done
export TUNE_NO_DAEMON=1

echo "--- screen detection ---"
mkfake; : > "$T/bl/brightness"; out=$(S status); has "empty brightness reading counts as screen on" "state=on" "$out"
echo 0 > "$T/bl/brightness"; out=$(S status); has "brightness 0 is screen off" "screen=off" "$out"
echo 1 > "$T/bl/brightness"; out=$(S status); has "lowest brightness is still screen on" "screen=on" "$out"
# the watcher polls every second, so the check must not start processes (the old $(cat ...) started two)
check "watcher reads brightness with built-ins only" 0 "$(grep -c 'st=\$(screen_state)' "$TUNE")"
check "brightness is not read through cat" 0 "$(sed -n '/^scr_get()/,/^}/p' "$TUNE" | grep -c 'cat \|rd ')"

echo "--- boot never records a capped reading as stock ---"
mkfake; S boot >/dev/null                                               # a normal boot records the real values
check "boot with profile 0: recorded" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
S boot >/dev/null
check "boot with Battery on: earlier record kept" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
S boot >/dev/null
check "boot with Battery on and no record: nothing is saved" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults" 2>/dev/null)"
mkfake; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
out=$(S boot); rc=$?
check "boot with Battery on and no record: tune.sh boot exits 2" 2 "$rc"
has "boot with Battery on and no record: the error is reported" "kernel profile must not be applied at this boot" "$out"
check "boot with Battery on and no record: the log says why" 1 "$(grep -c 'Battery profile is active and no earlier record exists' "$T/cfg/tune.log")"
check "boot with Battery on and no record: no snapshot file" no "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
mkfake; S boot >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
S boot >/dev/null; rc=$?
check "boot with Battery on and an earlier record: exits 0" 0 "$rc"
check "boot with Battery on and an earlier record: the record is untouched" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
mkfake; echo 1 > "$T/kp/kp_mode"; echo 1286400 > "$T/cpufreq/policy3/scaling_max_freq"
S status >/dev/null; rc=$?; check "status with Battery on and no record still works" 0 "$rc"
S preset tilt >/dev/null; rc=$?; check "Apply with Battery on and no record is refused" 1 "$rc"
check "no record: nothing was marked as changed" no "$([ -s "$T/cfg/applied" ] && echo yes || echo no)"

echo "--- Reset everything: profile first, and failures are reported ---"
mkfake; S preset saver >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 1 >/dev/null
out=$(S resetall); has "resetall ok: says ok" "ok" "$out"
check "resetall ok: profile None" 0 "$(v kp/kp_mode)"
check "resetall ok: big max stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake; S preset saver >/dev/null; echo 1 > "$T/kp/kp_mode"
if refuse_writes "$T/kp/kp_mode"; then
  S resetall >"$T/ra.out" 2>&1; rc=$?
  check "resetall: a profile that refuses the write gives a non-zero exit" 1 "$rc"
  has "resetall: a refused profile write is reported as an error" "error: the kernel profile could not be set to None" "$(cat "$T/ra.out")"
  check "resetall: limits still restored when the profile write is refused" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
  check "resetall: the refused profile was left as it was" 1 "$(v kp/kp_mode)"
else
  echo "skip resetall with a profile that refuses writes (this environment cannot block writes to a file)"
fi
allow_writes "$T/kp/kp_mode"
# a node that exists but cannot be read, or holds a value this module does not know (another kernel's fork):
# not a failure of the restore. The limits decide the result.
for kind in "unreadable (a folder)" "unknown value 4" "unknown text"; do
  mkfake; S preset saver >/dev/null; rm -f "$T/kp/kp_mode"
  case "$kind" in "unreadable (a folder)") mkdir "$T/kp/kp_mode" ;; "unknown value 4") echo 4 > "$T/kp/kp_mode" ;; *) echo auto > "$T/kp/kp_mode" ;; esac
  S resetall >"$T/ra.out" 2>&1; rc=$?
  check "resetall, profile $kind: succeeds" 0 "$rc"
  has "resetall, profile $kind: says it left the profile alone" "so it was left as it is" "$(cat "$T/ra.out")"
  check "resetall, profile $kind: limits restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
  if grep -q 'could not be set to None' "$T/ra.out"; then echo "FAIL resetall, profile $kind: reported as an error"; fail=1; else echo "ok   resetall, profile $kind: not reported as an error"; fi
  if [ "$kind" = "unknown value 4" ]; then check "resetall, profile $kind: the node was not written" 4 "$(v kp/kp_mode)"; fi
  rm -rf "$T/kp/kp_mode"; echo 0 > "$T/kp/kp_mode"
done
# ...but if that profile really holds a limit down, the limit restore itself still fails and says so
mkfake; S preset tilt >/dev/null; echo 4 > "$T/kp/kp_mode"
rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"
S resetall >"$T/ra.out" 2>&1; rc=$?
check "resetall, unknown profile and a refused limit: still fails" 1 "$rc"
has "resetall, unknown profile and a refused limit: the limit is named" "big_max" "$(cat "$T/ra.out")"
rm -rf "$T/cpufreq/policy3/scaling_max_freq"; echo 2572800 > "$T/cpufreq/policy3/scaling_max_freq"; echo 0 > "$T/kp/kp_mode"
mkfake; S preset saver >/dev/null; rm -rf "$T/kp"                                     # no Kprofiles in this kernel at all
S resetall >/dev/null 2>&1; check "resetall without Kprofiles still works" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake

echo "--- watcher lifecycle: stop, restart, and exit never touch each other's pid file ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=3 TUNE_POLL_OFF=3 TUNE_REASSERT=10
mkfake; S preset tilt >/dev/null; sleep 1
old=$(cat "$T/cfg/daemon.pid"); S cfg ENABLED 0 >/dev/null
if kill -0 "$old" 2>/dev/null; then echo "FAIL stop waits for the old watcher to exit"; fail=1; else echo "ok   stop waits for the old watcher to exit"; fi
S preset tilt >/dev/null; sleep 1
new=$(cat "$T/cfg/daemon.pid" 2>/dev/null)
sleep 4                                                                 # longer than a poll: any late cleanup of the old one has happened
check "new watcher keeps its pid file" "$new" "$(cat "$T/cfg/daemon.pid" 2>/dev/null)"
out=$(S status); has "status still sees the new watcher" "daemon=1" "$out"
S cfg ENABLED 0 >/dev/null
out=$(S status); has "stopped for good" "daemon=0" "$out"
echo "--- an exiting watcher leaves a pid file that names someone else alone ---"
mkfake; S preset tilt >/dev/null; sleep 1
w=$(cat "$T/cfg/daemon.pid"); echo 4242424 > "$T/cfg/daemon.pid"        # another watcher has taken over the file
kill "$w"; sleep 1
check "foreign pid file survives the old watcher's exit" 4242424 "$(cat "$T/cfg/daemon.pid" 2>/dev/null)"
rm -f "$T/cfg/daemon.pid"
echo "--- a stale pid file never makes stop signal an unrelated tune.sh daemon ---"
mkfake; mkdir -p "$T/cfg" "$T/elsewhere"
cat > "$T/elsewhere/tune.sh" <<'EOF_UNRELATED'
#!/bin/sh
sp=""
trap 'kill "$sp" 2>/dev/null; exit 0' TERM INT
while :; do sleep 300 & sp=$!; wait "$sp"; done
EOF_UNRELATED
sh "$T/elsewhere/tune.sh" daemon "$T/elsewhere" >/dev/null 2>&1 & bystander=$!
echo "$bystander" > "$T/cfg/daemon.pid"
S stop >/dev/null
if kill -0 "$bystander" 2>/dev/null; then echo "ok   unrelated tune.sh daemon left alone"; else echo "FAIL unrelated tune.sh daemon was killed"; fail=1; fi
kill "$bystander" 2>/dev/null; wait "$bystander" 2>/dev/null
export TUNE_NO_DAEMON=1

echo "--- watcher started by name from inside the module folder still gets the real module folder ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3
for marker in disable remove; do
  mkfake; rm -rf "$T/mod" "$T/elsewhere"; mkdir -p "$T/mod" "$T/elsewhere"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$HERE/../module/control-lib.sh" "$T/mod/"
  ( cd "$T/mod" && sh tune.sh preset tilt >/dev/null )        # $0 is just "tune.sh": no folder in it
  i=0; while [ "$i" -lt 10 ] && [ ! -s "$T/cfg/daemon.pid" ]; do sleep 1; i=$((i + 1)); done
  wp=$(cat "$T/cfg/daemon.pid" 2>/dev/null)
  args=$(tr '\0' ' ' < "/proc/$wp/cmdline" 2>/dev/null)
  case "$args" in *" daemon $T/mod "*) echo "ok   $marker test: watcher was handed the module folder" ;; *) echo "FAIL $marker test: watcher arguments were '$args'"; fail=1 ;; esac
  check "$marker test: limit applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
  ( cd "$T/elsewhere" && touch "$T/mod/$marker" )
  waitfor "$marker marker found from another working folder: limit handed back" 2572800 cpufreq/policy3/scaling_max_freq 30
  i=0; while [ "$i" -lt 10 ] && kill -0 "$wp" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  if kill -0 "$wp" 2>/dev/null; then echo "FAIL $marker test: watcher still running"; fail=1; else echo "ok   $marker test: watcher exited"; fi
done
export TUNE_NO_DAEMON=1

echo "--- stop reports a watcher that will not exit and keeps its pid file ---"
export TUNE_NO_DAEMON=1
mkfake; mkdir -p "$T/cfg"; rm -rf "$T/modu"; mkdir -p "$T/modu"
cp "$HERE/../module/"*.sh "$T/modu/"
sed "s|trap 'kill \"\$sp\" 2>/dev/null; pidf_release; exit 0' TERM INT|trap ':' TERM INT|" \
  "$T/modu/tune.sh" > "$T/modu/tune.tmp"
mv "$T/modu/tune.tmp" "$T/modu/tune.sh"
printf 'ENABLED=1\nSCREENOFF=1\nPRESET=tilt\n' > "$T/cfg/tune.conf"
TUNE="$T/modu/tune.sh"
unset TUNE_NO_DAEMON
sh "$TUNE" daemon "$T/modu" >/dev/null 2>&1 & stubp=$!
i=0; while [ "$i" -lt 10 ] && [ "$(cat "$T/cfg/daemon.pid" 2>/dev/null)" != "$stubp" ]; do sleep 1; i=$((i + 1)); done
out=$(S stop); has "stubborn watcher: stop warns" "did not stop within 3 seconds" "$out"
check "stubborn watcher: pid file kept" "$stubp" "$(cat "$T/cfg/daemon.pid" 2>/dev/null)"
kill -9 "$stubp" 2>/dev/null; wait "$stubp" 2>/dev/null
rm -f "$T/cfg/daemon.pid"
TUNE="$HERE/../module/tune.sh"
unset TUNE_NO_DAEMON
echo "--- stop never removes a pid file that names another process ---"
mkfake; mkdir -p "$T/cfg"; sleep 300 & other=$!
echo "$other" > "$T/cfg/daemon.pid"; S stop >/dev/null
check "stale pid file of an unrelated process is cleaned up" "no" "$([ -f "$T/cfg/daemon.pid" ] && echo yes || echo no)"
kill "$other" 2>/dev/null
echo "--- a watcher that fails to start is reported, not called ok ---"
# The start is made to fail without touching PATH (busybox ash runs setsid and nohup as built-in applets
# and would ignore fake ones): the pid file's place is taken by a folder, so no watcher can ever write it.
mkfake; mkdir -p "$T/cfg/daemon.pid"
out=$(TUNE_START_TRIES=5 S preset tilt); rc=$?
check "no watcher: the command fails" 1 "$rc"
has "no watcher: the failure is reported" "error: the screen on/off watcher did not start" "$out"
has "no watcher: says the limits themselves are applied" "your limits are applied for the current screen state" "$out"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL no watcher: must not print ok"; fail=1; else echo "ok   no watcher: no ok line"; fi
check "no watcher: limits are applied anyway" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
has "no watcher: logged" "watcher did not start" "$(cat "$T/cfg/tune.log")"
check "no watcher: lock released" "no" "$([ -d "$T/cfg/daemon.lock" ] && echo yes || echo no)"
rm -rf "$T/cfg/daemon.pid"
out=$(S preset tilt); rc=$?; check "a working watcher: the command succeeds" 0 "$rc"
S cfg ENABLED 0 >/dev/null

echo "--- a lock whose owner has not written its pid yet is not taken over quickly ---"
mkfake; mkdir -p "$T/cfg/daemon.lock"
out=$(TUNE_LOCK_TRIES=30 S preset tilt); rc=$?
check "pid-less lock: start gives up instead of taking it over" 1 "$rc"
check "pid-less lock: lock still there" "yes" "$([ -d "$T/cfg/daemon.lock" ] && echo yes || echo no)"
rm -rf "$T/cfg/daemon.lock"

echo "--- a restore the kernel refuses is logged by the watcher and kept for a retry ---"
mkfake; rm -rf "$T/mod"; mkdir -p "$T/mod"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$HERE/../module/control-lib.sh" "$T/mod/"
export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3
sh "$T/mod/tune.sh" boot >/dev/null; sh "$T/mod/tune.sh" preset tilt >/dev/null
i=0; while [ "$i" -lt 10 ] && [ ! -s "$T/cfg/daemon.pid" ]; do sleep 1; i=$((i + 1)); done
rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"   # writes to it now fail
touch "$T/mod/disable"
i=0; while [ "$i" -lt 30 ]; do [ -s "$T/cfg/daemon.pid" ] || break; sleep 1; i=$((i + 1)); done
has "watcher: refused restore is in the log" "could not put the phone's own value back for: big_max" "$(cat "$T/cfg/tune.log" 2>/dev/null)"
check "watcher: refused restore stays marked" 1 "$(grep -cx big_max "$T/cfg/applied")"
check "watcher: the other limits were handed back" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
export TUNE_POLL_ON=3 TUNE_POLL_OFF=3 TUNE_REASSERT=10
rm -f "$T/mod/disable"

echo "--- start and stop share one lock ---"
mkfake; mkdir -p "$T/cfg/daemon.lock"; sleep 300 & holder=$!; echo "$holder" > "$T/cfg/daemon.lock/pid"
out=$(TUNE_LOCK_TRIES=5 S preset tilt); rc=$?; has "busy lock: start is skipped with a warning" "another start or stop of the watcher is in progress" "$out"
check "busy lock: the command fails, it does not say ok" 1 "$rc"
check "busy lock: limits are still applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
check "busy lock: a live owner's lock is left alone" "$holder" "$(cat "$T/cfg/daemon.lock/pid" 2>/dev/null)"
check "busy lock: no watcher started" "no" "$([ -f "$T/cfg/daemon.pid" ] && echo yes || echo no)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
S status >/dev/null; S apply >/dev/null; sleep 1
check "lock of a dead owner is taken over" "yes" "$([ -f "$T/cfg/daemon.pid" ] && echo yes || echo no)"
check "lock is released afterwards" "no" "$([ -d "$T/cfg/daemon.lock" ] && echo yes || echo no)"
S cfg ENABLED 0 >/dev/null
export TUNE_NO_DAEMON=1

echo "--- a restore that fails keeps the limit marked until a retry succeeds ---"
mkfake; S boot >/dev/null; S preset tilt >/dev/null
rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"       # the kernel refuses writes
out=$(S preset stock)
has "refused restore: Stock says so" "could not put the phone's own value back for: big_max" "$out"
check "refused restore: big max still marked as changed" 1 "$(grep -cx big_max "$T/cfg/applied")"
check "refused restore: logged" 1 "$(grep -c 'restore refused by the kernel for: big_max' "$T/cfg/tune.log")"
check "refused restore: the other limits were restored" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
rmdir "$T/cpufreq/policy3/scaling_max_freq"; echo 2188800 > "$T/cpufreq/policy3/scaling_max_freq"   # the node accepts writes again
out=$(S apply); case "$out" in *"could not put"*) echo "FAIL retry: still failing"; fail=1 ;; *) echo "ok   retry: no warning" ;; esac
check "retry: the phone's own value is back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "retry: the marker is gone" 0 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; S preset stock >/dev/null
check "clean restore: nothing stays marked" 0 "$(grep -c . "$T/cfg/applied" 2>/dev/null)"

echo "--- a partial snapshot is reported by Stock, and nothing is made up ---"
mkfake; : > "$T/cpufreq/policy3/scaling_max_freq"; S boot >/dev/null     # first boot, one reading missing
out=$(S preset tilt); rc=$?; check "partial snapshot: Apply is refused" 1 "$rc"
has "partial snapshot: Apply names the missing value" "not on record for: big_max" "$out"
out=$(S preset stock); rc=$?; check "partial snapshot: nothing was applied, so Stock is ok" 0 "$rc"
check "partial snapshot: no value was invented for big max" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
check "partial snapshot: big max is left as it is" "" "$(v cpufreq/policy3/scaling_max_freq)"
check "partial snapshot: the other limits are untouched" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
mkfake; S boot >/dev/null; out=$(S preset tilt); case "$out" in *"not recorded for"*) echo "FAIL complete snapshot warns"; fail=1 ;; *) echo "ok   complete snapshot: no warning" ;; esac
out=$(S preset stock); case "$out" in *"not recorded for"*) echo "FAIL complete snapshot: Stock warns"; fail=1 ;; *) echo "ok   complete snapshot: Stock does not warn" ;; esac

echo "--- boot never replaces a saved snapshot with an incomplete reading ---"
mkfake; S boot >/dev/null
check "snapshot saved at first boot" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mksys; : > "$T/cpufreq/policy3/scaling_max_freq"                         # a transient empty read
out=$(S boot); has "empty reading: boot warns" "warn: could not read these frequency values at boot: big_max" "$out"
check "empty reading: saved big max kept" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
check "empty reading: saved little max kept" 2016000 "$(sed -n 's/^little_max=//p' "$T/cfg/defaults")"
check "empty reading: no temp file left" "no" "$([ -f "$T/cfg/defaults.tmp" ] && echo yes || echo no)"
has "empty reading: logged" "could not read: big_max" "$(cat "$T/cfg/tune.log")"
mksys; echo "garbage" > "$T/gpu/max_freq"                              # not a number
out=$(S boot); has "invalid reading: boot warns" "gpu_max" "$out"
check "invalid reading: saved gpu max kept" 900000000 "$(sed -n 's/^gpu_max=//p' "$T/cfg/defaults")"
mksys; echo 2611200 > "$T/cpufreq/policy3/scaling_max_freq"
out=$(S boot); case "$out" in *warn:*) echo "FAIL complete reading: unexpected warning"; fail=1 ;; *) echo "ok   complete reading: no warning" ;; esac
check "complete reading: snapshot updated" 2611200 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake; : > "$T/cpufreq/policy3/scaling_max_freq"; out=$(S boot)         # nothing saved yet: keep what can be read
has "first boot with one empty reading: warns" "big_max" "$out"
check "first boot with one empty reading: readable values saved" 2016000 "$(sed -n 's/^little_max=//p' "$T/cfg/defaults")"
check "first boot with one empty reading: unreadable one not invented" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake; rm -rf "$T/gpu"; out=$(S boot)                                  # hardware that is simply absent is not a failure
case "$out" in *"could not read"*) echo "FAIL absent gpu is not a read failure"; fail=1 ;; *) echo "ok   absent gpu is not a read failure" ;; esac

echo "--- a watcher that no longer owns the pid file cannot undo a restore ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=2
mkfake; rm -rf "$T/mod0" "$T/mod"; mkdir -p "$T/mod0" "$T/mod"
cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$HERE/../module/control-lib.sh" "$T/mod0/"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$HERE/../module/control-lib.sh" "$T/mod/"
sh "$T/mod0/tune.sh" preset tilt >/dev/null            # watcher A: looks for markers in mod0
i=0; while [ "$i" -lt 10 ]; do out=$(sh "$T/mod0/tune.sh" status); case "$out" in *daemon=1*) break ;; esac; sleep 1; i=$((i + 1)); done
has "ownership: watcher A running" "daemon=1" "$out"
wa=$(cat "$T/cfg/daemon.pid")
rm -f "$T/cfg/daemon.pid"                                # its pid file is lost (a wiped folder, a crash ...)
sh "$T/mod/tune.sh" apply >/dev/null                     # watcher B: looks for markers in mod
i=0; while [ "$i" -lt 10 ]; do out=$(sh "$T/mod/tune.sh" status); case "$out" in *daemon=1*) break ;; esac; sleep 1; i=$((i + 1)); done
has "ownership: watcher B running" "daemon=1" "$out"
i=0; while [ "$i" -lt 10 ] && kill -0 "$wa" 2>/dev/null; do sleep 1; i=$((i + 1)); done
if kill -0 "$wa" 2>/dev/null; then echo "FAIL ownership: the watcher without the pid file keeps running"; fail=1; else echo "ok   ownership: the watcher without the pid file left"; fi
touch "$T/mod/disable"
waitfor "ownership: limit handed back" 2572800 cpufreq/policy3/scaling_max_freq 15
sleep 5                                                 # long enough for any other watcher to re-apply the cap
check "ownership: the limit stays handed back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
export TUNE_NO_DAEMON=1

echo "--- a watcher that will not stop is reported, and nothing is thrown away ---"
export TUNE_NO_DAEMON=1
stubborn() { # run the real watcher from this module path, with TERM ignored only in the test copy
  mkfake; rm -rf "$T/modu"; mkdir -p "$T/modu"
  cp "$HERE/../module/"*.sh "$T/modu/"
  sed -e "s|trap 'kill \"\$sp\" 2>/dev/null; pidf_release; exit 0' TERM INT|trap ':' TERM INT|" \
      -e 's|if \[ "$ENABLED" != 1 \]; then apply_none_logged; break; fi|: # test-only stubborn watcher ignores disabled settings|' \
      "$T/modu/tune.sh" > "$T/modu/tune.tmp"
  mv "$T/modu/tune.tmp" "$T/modu/tune.sh"
  TUNE="$T/modu/tune.sh"
  S preset tilt >/dev/null
  unset TUNE_NO_DAEMON
  sh "$TUNE" daemon "$T/modu" >/dev/null 2>&1 & stubp=$!
  i=0; while [ "$i" -lt 10 ] && [ "$(cat "$T/cfg/daemon.pid" 2>/dev/null)" != "$stubp" ]; do sleep 1; i=$((i + 1)); done
  [ "$(cat "$T/cfg/daemon.pid" 2>/dev/null)" = "$stubp" ] || { echo "FAIL stubborn watcher started"; fail=1; }
}
stubborn
out=$(S cfg ENABLED 0); rc=$?
check "apply with a stuck watcher: non-zero exit" 1 "$rc"
has "apply with a stuck watcher: says so" "error: the watcher is still running" "$out"
check "apply with a stuck watcher: the setting is kept" "0" "$(sed -n 's/^ENABLED=//p' "$T/cfg/tune.conf")"
check "apply with a stuck watcher: pid file kept" "$stubp" "$(cat "$T/cfg/daemon.pid" 2>/dev/null)"
out=$(S stop); rc=$?
check "stop with a stuck watcher: non-zero exit" 1 "$rc"
case "$out" in *ok*) echo "FAIL stop with a stuck watcher printed ok"; fail=1 ;; *) echo "ok   stop with a stuck watcher does not print ok" ;; esac
# uninstall keeps the recovery data while the watcher is still running. Keep the test-only tune.sh copy:
# it is the same module path as the watcher, with only its TERM trap altered for this test.
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; check "uninstall with a stuck watcher: exits non-zero" 1 "$?"
check "uninstall with a stuck watcher keeps the recorded stock values" "yes" "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "uninstall with a stuck watcher keeps the settings" "yes" "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
kill -9 "$stubp" 2>/dev/null; wait "$stubp" 2>/dev/null; rm -f "$T/cfg/daemon.pid"
sh "$T/modu/uninstall.sh"
check "uninstall removes the saved settings once the watcher is gone" "no" "$([ -e "$T/cfg" ] && echo yes || echo no)"
TUNE="$HERE/../module/tune.sh"
export TUNE_NO_DAEMON=1

echo "--- a zero reading is never recorded as a stock frequency ---"
mkfake; S boot >/dev/null
echo 0 > "$T/cpufreq/policy3/scaling_max_freq"; S boot >/dev/null
check "zero reading does not replace a saved snapshot" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake; echo 0 > "$T/cpufreq/policy3/scaling_max_freq"; S boot >/dev/null
check "zero reading with nothing saved: not recorded" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
check "zero reading with nothing saved: the other values are" 2016000 "$(sed -n 's/^little_max=//p' "$T/cfg/defaults")"
echo 00 > "$T/cpufreq/policy3/scaling_max_freq"; mkfake; echo 00 > "$T/cpufreq/policy3/scaling_max_freq"; S boot >/dev/null
check "00 is not a frequency either" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
mkfake

echo "--- a restore the kernel refuses makes the command fail, and uninstall keeps the recovery data ---"
export TUNE_NO_DAEMON=1
refuse_big() { rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"; }   # writes to it fail
accept_big() { rmdir "$T/cpufreq/policy3/scaling_max_freq"; echo 2188800 > "$T/cpufreq/policy3/scaling_max_freq"; }
mkfake; S boot >/dev/null; S preset tilt >/dev/null; refuse_big
out=$(S preset stock); rc=$?
check "refused restore: Stock exits non-zero" 1 "$rc"
has "refused restore: Stock reports an error" "error: some of the phone's own values could not be put back" "$out"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL refused restore: Stock printed ok"; fail=1; else echo "ok   refused restore: Stock does not print ok"; fi
out=$(S stop); rc=$?
check "refused restore: stop exits non-zero" 1 "$rc"
has "refused restore: stop says what failed" "could not all be put back" "$out"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL refused restore: stop printed ok"; fail=1; else echo "ok   refused restore: stop does not print ok"; fi
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "uninstall after a refused restore: exits non-zero" 1 "$rc"
check "uninstall after a refused restore: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "uninstall after a refused restore: settings kept" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
check "uninstall after a refused restore: the marker is kept" 1 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
check "uninstall after a refused restore: the other limits were restored" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
accept_big                                                              # the kernel takes writes again
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "uninstall once the restore works: exits 0" 0 "$rc"
check "uninstall once the restore works: the phone's own value is back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "uninstall once the restore works: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
# the same while the limits are in use: changing a setting back to default is a restore too
mkfake; S boot >/dev/null; S preset tilt >/dev/null; refuse_big
out=$(S cfg ON_BIG_MAX default); rc=$?
check "refused restore while enabled: the command exits non-zero" 1 "$rc"
has "refused restore while enabled: reports an error" "error: some of the phone's own values could not be put back" "$out"
check "refused restore while enabled: the marker is kept" 1 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"

echo "--- uninstall keeps the recovery data when the kernel profile refuses to be reset ---"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 3 >/dev/null
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
if refuse_writes "$T/kp/kp_mode"; then                                      # reads a valid mode but refuses the write
  sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
  check "kernel profile reset refused: uninstall exits non-zero" 1 "$rc"
  check "kernel profile reset refused: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
  check "kernel profile reset refused: settings kept" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
  check "kernel profile reset refused: the limits themselves were restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
else
  echo "skip uninstall with a profile that refuses writes (this environment cannot block writes to a file)"
fi
allow_writes "$T/kp/kp_mode"; echo 3 > "$T/kp/kp_mode"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "kernel profile resets: uninstall exits 0" 0 "$rc"
check "kernel profile resets: profile is None" 0 "$(v kp/kp_mode)"
check "kernel profile resets: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -rf "$T/kp"     # a kernel without Kprofiles has nothing to reset
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "no Kprofiles in the kernel: uninstall still finishes" 0 "$rc"
check "no Kprofiles in the kernel: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"

echo "--- a settings file that cannot be saved: nothing is applied, nothing is reported ok, uninstall keeps everything ---"
cfgsum() { cksum < "$T/cfg/tune.conf"; }
mkfake; S boot >/dev/null; S preset tilt >/dev/null
before=$(cfgsum); bigmax=$(v cpufreq/policy3/scaling_max_freq)
mkdir "$T/cfg/tune.conf.tmp"                                  # the temporary file cannot be written
out=$(S cfg ON_BIG_MAX 2073600); rc=$?
check "unwritable temp file: cfg exits non-zero" 1 "$rc"
has "unwritable temp file: cfg says the setting was not saved" "error: could not save" "$out"
case "$out" in *ok*) case "$out" in *"error: could not save"*) echo "ok   unwritable temp file: cfg does not print ok" ;; *) echo "FAIL cfg printed ok"; fail=1 ;; esac ;; *) echo "ok   unwritable temp file: cfg does not print ok" ;; esac
check "unwritable temp file: cfg leaves the saved settings as they were" "$before" "$(cfgsum)"
check "unwritable temp file: cfg does not apply the old settings as if saved" "$bigmax" "$(v cpufreq/policy3/scaling_max_freq)"
check "unwritable temp file: the preset name is not half-changed" tilt "$(sed -n 's/^PRESET=//p' "$T/cfg/tune.conf")"
out=$(S preset saver); rc=$?
check "unwritable temp file: preset exits non-zero" 1 "$rc"
has "unwritable temp file: preset says the setting was not saved" "error: could not save" "$out"
check "unwritable temp file: preset leaves the saved settings as they were" "$before" "$(cfgsum)"
check "unwritable temp file: preset does not apply anything" "$bigmax" "$(v cpufreq/policy3/scaling_max_freq)"
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "settings cannot be saved: uninstall exits non-zero" 1 "$rc"
check "settings cannot be saved: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "settings cannot be saved: settings kept" "$before" "$(cfgsum)"
check "settings cannot be saved: the changed-limit markers are kept" 1 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
rmdir "$T/cfg/tune.conf.tmp"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "settings can be saved again: uninstall exits 0" 0 "$rc"
check "settings can be saved again: the phone's own value is back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "settings can be saved again: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
# the settings path is itself a folder: mv would drop the new file INSIDE it and report success
mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -f "$T/cfg/tune.conf"; mkdir "$T/cfg/tune.conf"
out=$(S preset saver); rc=$?
check "settings path is a folder: preset exits non-zero" 1 "$rc"
check "settings path is a folder: nothing was moved into it" 0 "$(ls "$T/cfg/tune.conf" | wc -l | tr -d ' ')"
out=$(S cfg ENABLED 0); rc=$?
check "settings path is a folder: cfg exits non-zero" 1 "$rc"
# a setting and the preset name are saved together or not at all
mkfake; S boot >/dev/null; S preset tilt >/dev/null
S cfg ON_BIG_MAX 2073600 >/dev/null
check "cfg saves the value" 2073600 "$(sed -n 's/^ON_BIG_MAX=//p' "$T/cfg/tune.conf")"
check "cfg saves PRESET=custom with it" custom "$(sed -n 's/^PRESET=//p' "$T/cfg/tune.conf")"
check "cfg keeps each key once" 1 "$(grep -c '^ON_BIG_MAX=' "$T/cfg/tune.conf")"
check "cfg keeps PRESET once" 1 "$(grep -c '^PRESET=' "$T/cfg/tune.conf")"
check "cfg leaves no temporary file" no "$([ -e "$T/cfg/tune.conf.tmp" ] && echo yes || echo no)"

echo "--- v1.2.1 failure injection: recovery data is never lost, and no failure is reported as success ---"
rununinst() { # runs the real uninstall.sh against the test folders; prints nothing, returns its status
  rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
  sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
  sh "$T/modu/uninstall.sh" >/dev/null 2>&1
}
marked() { grep -cx "$1" "$T/cfg/applied" 2>/dev/null; }
# 1. no stock snapshot while one of our limits is in place
mkfake; S boot >/dev/null; S preset tilt >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"; rm -f "$T/cfg/defaults"
out=$(S preset stock); rc=$?
check "no snapshot: Stock exits 1" 1 "$rc"
has "no snapshot: Stock says the restore is incomplete" "could not be put back" "$out"
check "no snapshot: the limit is left as it is" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
check "no snapshot: the changed-marker is kept" 1 "$(marked big_max)"
rununinst; rc=$?
check "no snapshot: uninstall exits 1" 1 "$rc"
check "no snapshot: uninstall keeps the settings" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
check "no snapshot: uninstall keeps the markers" 1 "$(marked big_max)"
cp "$T/defaults.keep" "$T/cfg/defaults"; rununinst; rc=$?
check "snapshot back: uninstall exits 0" 0 "$rc"
check "snapshot back: the phone's own value is restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake; echo 1 > "$T/kp/kp_mode"; S boot >/dev/null                  # Battery profile on at boot: nothing was recorded
check "Battery profile at boot: no snapshot was taken" no "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"
S preset tilt >/dev/null           # refused: nothing is on record. A limit changed by an older version is simulated:
echo 2188800 > "$T/cpufreq/policy3/scaling_max_freq"; printf 'big_max\n' > "$T/cfg/applied"
rununinst; rc=$?
check "Battery profile at boot, limits changed: uninstall exits 1" 1 "$rc"
check "Battery profile at boot, limits changed: recovery data kept" yes "$([ -d "$T/cfg" ] && echo yes || echo no)"
S stop >/dev/null 2>&1; check "stop with no snapshot: exits 1" 1 "$(S stop >/dev/null 2>&1; echo $?)"
# 2. the changed-marker cannot be saved: the limit must not be changed
mkfake; S boot >/dev/null; mkdir "$T/cfg/applied"
out=$(S preset tilt); rc=$?
check "marker unwritable: preset exits 1" 1 "$rc"
has "marker unwritable: says the record could not be saved" "could not save the record" "$out"
check "marker unwritable: big max not changed" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "marker unwritable: prime max not changed" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "marker unwritable: gpu max not changed" 900000000 "$(v gpu/max_freq)"
rmdir "$T/cfg/applied"
# the marker cannot be cleared: the value is back, the marker stays, and it is said
mkfake; S boot >/dev/null; S preset tilt >/dev/null; mkdir "$T/cfg/applied.tmp"
out=$(S preset stock); rc=$?
check "marker not clearable: the phone's own value is back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
has "marker not clearable: says so" "marker could not be cleared" "$out"
check "marker not clearable: the marker stays (safe direction)" 1 "$(marked big_max)"
rmdir "$T/cfg/applied.tmp"; S apply >/dev/null
check "marker clearable again: it is cleared" 0 "$(marked big_max)"
# 3. the existing settings cannot be READ: they are never replaced by a file with only the new key
mkfake; S boot >/dev/null; S preset tilt >/dev/null; before=$(cfgsum); bigmax=$(v cpufreq/policy3/scaling_max_freq)
inj 'grep() { for ij_a; do case "$ij_a" in *tune.conf) return 2 ;; esac; done; command grep "$@"; }'
printf 'grep -v zzz "%s" >/dev/null 2>&1; echo $?\n' "$T/cfg/tune.conf" > "$T/probe.sh"
check "injection is active (grep on the settings fails in this shell)" 2 "$(INJ_TARGET="$T/probe.sh" sh "$T/inj.sh")"
out=$(SI cfg ON_BIG_MAX 2073600); rc=$?
check "settings unreadable: cfg exits 1" 1 "$rc"
has "settings unreadable: cfg says nothing was saved" "error: could not save" "$out"
check "settings unreadable: the old settings are byte for byte the same" "$before" "$(cfgsum)"
check "settings unreadable: no temporary file left" no "$([ -e "$T/cfg/tune.conf.tmp" ] && echo yes || echo no)"
check "settings unreadable: nothing was applied" "$bigmax" "$(v cpufreq/policy3/scaling_max_freq)"
rm -f "$T/probe.sh"
# a settings file that is damaged (cannot be parsed) is not "no settings"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; bigmax=$(v cpufreq/policy3/scaling_max_freq)
printf 'ENABLED=1\nthis is ( broken\n' > "$T/cfg/tune.conf"; bad=$(cfgsum)
out=$(S apply); rc=$?
check "settings damaged: apply exits 1" 1 "$rc"
has "settings damaged: apply says they cannot be read" "cannot be read" "$out"
check "settings damaged: apply changed nothing" "$bigmax" "$(v cpufreq/policy3/scaling_max_freq)"
out=$(S status); rc=$?
check "settings damaged: status still works" 0 "$rc"
out=$(S cfg ON_BIG_MAX 2073600); rc=$?
check "settings damaged: cfg exits 1" 1 "$rc"
check "settings damaged: cfg leaves the file alone" "$bad" "$(cfgsum)"
out=$(S preset stock); rc=$?
check "settings damaged: a preset writes them again" 0 "$rc"
check "settings damaged: and the phone is back to stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake; S boot >/dev/null; printf 'ENABLED=1\nthis is ( broken\n' > "$T/cfg/tune.conf"
out=$(S boot); rc=$?
check "settings damaged: boot exits 1" 1 "$rc"
has "settings damaged: boot says so" "cannot be read" "$out"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; printf 'ENABLED=1\nthis is ( broken\n' > "$T/cfg/tune.conf"
rununinst; rc=$?
check "settings damaged: uninstall still restores and exits 0" 0 "$rc"
check "settings damaged: uninstall restored the phone's own value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
# 4. the phone's own values cannot be SAVED
mkfake; mkdir -p "$T/cfg/defaults.tmp"
out=$(S boot); rc=$?
check "snapshot unsavable, nothing on record: boot exits 2" 2 "$rc"
has "snapshot unsavable: boot says so" "could not be saved at boot" "$out"
check "snapshot unsavable: no snapshot file" no "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"
out=$(S preset tilt); rc=$?
check "snapshot unsavable: apply exits 1" 1 "$rc"
has "snapshot unsavable: apply refuses to change a limit" "no limit was changed" "$out"
check "snapshot unsavable: big max not changed" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
rmdir "$T/cfg/defaults.tmp"; S boot >/dev/null; snap=$(cksum < "$T/cfg/defaults"); mkdir "$T/cfg/defaults.tmp"
out=$(S boot); rc=$?
check "saved snapshot, save fails again: boot exits 1" 1 "$rc"
check "saved snapshot, save fails again: the earlier snapshot is untouched" "$snap" "$(cksum < "$T/cfg/defaults")"
mkfake; rm -rf "$T/cfg"; mkdir -p "$T/cfg/defaults"                 # the snapshot path is a folder
out=$(S boot); rc=$?
check "snapshot path is a folder, nothing on record: boot exits 2" 2 "$rc"
check "snapshot path is a folder: nothing moved into it" 0 "$(ls "$T/cfg/defaults" | wc -l | tr -d ' ')"
# the final move of the snapshot into place fails (a stand-in mv refuses it)
mkfake; rm -rf "$T/cfg"
inj 'mv() { for ij_a; do case "$ij_a" in *defaults.tmp) return 1 ;; esac; done; command mv "$@"; }'
out=$(SI boot); rc=$?
check "snapshot move fails, nothing on record: boot exits 2" 2 "$rc"
has "snapshot move fails: boot says so" "could not be saved at boot" "$out"
check "snapshot move fails: no snapshot file claimed" no "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"
check "snapshot move fails: no temporary file left" no "$([ -e "$T/cfg/defaults.tmp" ] && echo yes || echo no)"
out=$(SI preset tilt); rc=$?
check "snapshot move fails: apply exits 1 and changes no limit" "1 2572800" "$rc $(v cpufreq/policy3/scaling_max_freq)"
rm -f "$T/inj.sh"

echo "--- boot does not say 'boot done' after a failed apply or watcher start ---"
mkfake; export TUNE_NO_DAEMON=1; S preset tilt >/dev/null; unset TUNE_NO_DAEMON      # saved: enabled, tilt (no watcher yet)
mksys; rm -rf "$T/cfg/daemon.pid"; mkdir -p "$T/cfg/daemon.pid"                 # a watcher can never write its pid file
out=$(TUNE_START_TRIES=5 S boot); rc=$?
check "boot with a failed watcher start: exits non-zero" 1 "$rc"
has "boot with a failed watcher start: the error is shown" "error: the screen on/off watcher did not start" "$out"
has "boot with a failed watcher start: boot says it finished with errors" "boot finished with errors" "$out"
case "$out" in *"boot done"*) echo "FAIL boot printed 'boot done' after a failure"; fail=1 ;; *) echo "ok   boot does not print 'boot done' after a failure" ;; esac
check "boot with a failed watcher start: the limits were still applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
has "boot with a failed watcher start: logged" "boot finished with errors" "$(cat "$T/cfg/tune.log")"
rm -rf "$T/cfg/daemon.pid"
mkfake; export TUNE_NO_DAEMON=1; S preset tilt >/dev/null; mksys
out=$(S boot); rc=$?
check "boot, all fine: exits 0" 0 "$rc"
has "boot, all fine: says boot done" "boot done: enabled=1 preset=tilt" "$out"
mkfake; S preset stock >/dev/null
out=$(S boot); rc=$?; check "boot with the limits off: exits 0" 0 "$rc"
mkfake

echo "--- the Action button reports a failed preset instead of announcing success ---"
rm -rf "$T/modact"; cp -r "$HERE/../module" "$T/modact"
mkfake; export TUNE_NO_DAEMON=1
out=$(sh "$T/modact/action.sh" 2>&1); rc=$?
check "action, all fine: exits 0" 0 "$rc"
has "action, all fine: announces the preset" "Frequency preset: tilt" "$out"
mkfake; unset TUNE_NO_DAEMON; mkdir -p "$T/cfg/daemon.pid"                       # the watcher cannot start
out=$(TUNE_START_TRIES=5 sh "$T/modact/action.sh" 2>&1); rc=$?
check "action with a failed watcher start: exits non-zero" 1 "$rc"
has "action with a failed watcher start: shows the real error" "error: the screen on/off watcher did not start" "$out"
has "action with a failed watcher start: says it was not fully applied" "was NOT fully applied" "$out"
case "$out" in *"Frequency preset: tilt"*) echo "FAIL action announced success after a failure"; fail=1 ;; *) echo "ok   action does not announce success after a failure" ;; esac
rm -rf "$T/cfg/daemon.pid"
mkfake; export TUNE_NO_DAEMON=1; S preset tilt >/dev/null; S preset saver >/dev/null; refuse_big   # a refused restore through the Action button
out=$(sh "$T/modact/action.sh" 2>&1); rc=$?                                      # saver -> stock
check "action with a refused restore: exits non-zero" 1 "$rc"
has "action with a refused restore: shows the warning" "could not put the phone's own value back" "$out"
mkfake

echo "--- uninstall resets the kernel profile BEFORE it restores the limits ---"
# Stand-in for a kernel where the Battery profile holds the limit down: the big max can only be written
# once kp.sh has set the profile to None. (The node is a folder, so writes fail, until then.)
setup_locked() {
  mkfake; S boot >/dev/null; S preset tilt >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 1 >/dev/null
  rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"
  rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
  sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
  mv "$T/modu/kp.sh" "$T/modu/kp-real.sh"
  cat > "$T/modu/kp.sh" <<'WRAP'
#!/bin/sh
D=$(dirname "$0")
sh "$D/kp-real.sh" "$@"; rc=$?
if { [ "$1" = mode ] || [ "$1" = control-mode ]; } && [ "$2" = 0 ] && [ "$rc" = 0 ] && [ -d "$BIGNODE" ]; then rmdir "$BIGNODE"; echo 2188800 > "$BIGNODE"; fi
exit $rc
WRAP
}
export BIGNODE="$T/cpufreq/policy3/scaling_max_freq"
setup_locked
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "locked limit: uninstall succeeds because the profile is reset first" 0 "$rc"
check "locked limit: the big max is back to the phone's own value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "locked limit: the kernel profile is None" 0 "$(v kp/kp_mode)"
check "locked limit: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
# the profile cannot be reset: nothing can be restored, and everything is kept
setup_locked; rm -rf "$T/kp/kp_mode"; mkdir "$T/kp/kp_mode"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "profile reset fails: uninstall exits 1" 1 "$rc"
check "profile reset fails: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "profile reset fails: settings kept" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
check "profile reset fails: marker kept" 1 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
rmdir "$T/kp/kp_mode"; echo 1 > "$T/kp/kp_mode"                     # the profile can be reset now
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "after the profile can be reset: uninstall succeeds" 0 "$rc"
check "after the profile can be reset: limit restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "after the profile can be reset: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
# the profile resets but the restore is still refused: kept, and the profile is already None
mkfake; S boot >/dev/null; S preset tilt >/dev/null; KPC_CONTROL_INTERNAL=1 sh "$HERE/../module/kp.sh" mode 1 >/dev/null
rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"; sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "restore refused after the reset: uninstall exits 1" 1 "$rc"
check "restore refused after the reset: the profile was reset first" 0 "$(v kp/kp_mode)"
check "restore refused after the reset: recovery data kept" 1 "$([ -s "$T/cfg/defaults" ] && [ -s "$T/cfg/tune.conf" ] && grep -qx big_max "$T/cfg/applied" && echo 1 || echo 0)"
rmdir "$T/cpufreq/policy3/scaling_max_freq"; echo 2188800 > "$T/cpufreq/policy3/scaling_max_freq"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "restore works again: uninstall succeeds and cleans up" "0 no" "$rc $([ -e "$T/cfg" ] && echo yes || echo no)"
check "uninstall.sh runs tune.sh resetall" 1 "$(grep -c 'tune.sh" resetall' "$HERE/../module/uninstall.sh")"
check "uninstall.sh no longer calls kp.sh itself" 0 "$(grep -v '^ *#' "$HERE/../module/uninstall.sh" | grep -c 'kp.sh')"
mkfake

echo "--- audit round 2: a control that vanished after the module changed it is a failed restore ---"
export TUNE_NO_DAEMON=1
mkmodu() { rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"; sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"; }
BIGMAX="$T/cpufreq/policy3/scaling_max_freq"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -f "$BIGMAX"        # the node disappears after we capped it
out=$(S resetall); rc=$?
check "vanished control: resetall exits 1" 1 "$rc"
has "vanished control: resetall names the limit" "big_max" "$out"
has "vanished control: resetall says it stays marked" "stays marked" "$out"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL vanished control: resetall printed ok"; fail=1; else echo "ok   vanished control: resetall does not print ok"; fi
check "vanished control: the marker is kept" 1 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
check "vanished control: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "vanished control: saved settings kept" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
check "vanished control: the other limits were restored" "2668800 900000000" "$(v cpufreq/policy7/scaling_max_freq) $(v gpu/max_freq)"
out=$(S preset stock); rc=$?; check "vanished control: Stock exits 1" 1 "$rc"
out=$(S stop); rc=$?; check "vanished control: stop exits 1" 1 "$rc"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL vanished control: stop printed ok"; fail=1; else echo "ok   vanished control: stop does not print ok"; fi
mkmodu; sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "vanished control: uninstall exits 1" 1 "$rc"
check "vanished control: uninstall keeps the recovery data" 1 "$([ -s "$T/cfg/defaults" ] && [ -s "$T/cfg/tune.conf" ] && grep -qx big_max "$T/cfg/applied" && echo 1 || echo 0)"
echo 2188800 > "$BIGMAX"                                                     # the node is back
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "control back: uninstall exits 0" 0 "$rc"
check "control back: the phone's own value is back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "control back: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
# the same for a min limit
mkfake; S boot >/dev/null; S preset tilt >/dev/null; S cfg ON_BIG_MIN 787200 >/dev/null
check "vanished min: the min is marked as ours" 1 "$(grep -cx big_min "$T/cfg/applied")"
rm -f "$T/cpufreq/policy3/scaling_min_freq"
out=$(S preset stock); rc=$?
check "vanished min: Stock exits 1" 1 "$rc"
check "vanished min: the min marker is kept" 1 "$(grep -cx big_min "$T/cfg/applied" 2>/dev/null)"
# hardware the module never changed that is simply absent is still not a failure
mkfake; rm -rf "$T/gpu"; S boot >/dev/null
out=$(S preset tilt); rc=$?
check "absent hardware, never changed: still exits 0" 0 "$rc"
has "absent hardware, never changed: still says not found" "warn: gpu controls not found" "$out"
out=$(S preset stock); rc=$?; check "absent hardware, never changed: Stock exits 0" 0 "$rc"

echo "--- audit round 2: a requested limit the kernel refuses makes the command fail ---"
mkfake; S boot >/dev/null; refuse_big
out=$(S preset tilt); rc=$?
check "refused request: preset exits 1" 1 "$rc"
has "refused request: names the limit" "did not take these limits: big_max" "$out"
has "refused request: still shows what the kernel said" "warn: big max wanted 2188800" "$out"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL refused request: preset printed ok"; fail=1; else echo "ok   refused request: preset does not print ok"; fi
case "$out" in *"put back"*) echo "FAIL refused request: reported as a failed restore"; fail=1 ;; *) echo "ok   refused request: not reported as a failed restore" ;; esac
check "refused request: the other limits ARE in place" "2457600 736000000" "$(v cpufreq/policy7/scaling_max_freq) $(v gpu/max_freq)"
out=$(S apply); rc=$?; check "refused request: apply exits 1" 1 "$rc"
out=$(S cfg ON_BIG_MAX 2073600); rc=$?; check "refused request: cfg exits 1" 1 "$rc"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; mksys; refuse_big     # saved: tilt; the phone rebooted; the kernel refuses the big max
out=$(S boot); rc=$?
check "refused request: boot exits 1" 1 "$rc"
has "refused request: boot does not say done" "boot finished with errors" "$out"
accept_big
out=$(S apply); rc=$?
check "refused request, kernel takes it later: apply exits 0" 0 "$rc"
check "refused request, kernel takes it later: the limit is in place" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
# two clusters refused: both are named, and the one that worked stays in place
mkfake; S boot >/dev/null; refuse_big; rm -f "$T/gpu/max_freq"; mkdir "$T/gpu/max_freq"
out=$(S preset tilt); rc=$?
check "two refused: preset exits 1" 1 "$rc"
has "two refused: both are named" "limits: big_max gpu_max" "$out"
check "two refused: prime max is in place" 2457600 "$(v cpufreq/policy7/scaling_max_freq)"
# a refused min is reported too
mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -f "$T/cpufreq/policy3/scaling_min_freq"; mkdir "$T/cpufreq/policy3/scaling_min_freq"
out=$(S cfg ON_BIG_MIN 787200); rc=$?
check "refused min: cfg exits 1" 1 "$rc"
has "refused min: names the limit" "big_min" "$out"
mkfake

echo "--- a minimum held at its maximum is never recorded as stock ---"
export TUNE_NO_DAEMON=1
pinall() { echo 2016000 > "$T/cpufreq/policy0/scaling_min_freq"; echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"; echo 2668800 > "$T/cpufreq/policy7/scaling_min_freq"; }
unpin() { echo 595200 > "$T/cpufreq/policy0/scaling_min_freq"; echo 633600 > "$T/cpufreq/policy3/scaling_min_freq"; echo 633600 > "$T/cpufreq/policy7/scaling_min_freq"; }
dv() { sed -n "s/^$1=//p" "$T/cfg/defaults" 2>/dev/null | head -n 1; }
mkfake; S boot >/dev/null
check "good boot records the real minimum" 595200 "$(dv little_min)"
pinall; out=$(TUNE_BOOT_RETRIES=1 S boot)
check "pinned boot keeps the earlier little min" 595200 "$(dv little_min)"
check "pinned boot keeps the earlier big min" 633600 "$(dv big_min)"
check "pinned boot keeps the earlier prime min" 633600 "$(dv prime_min)"
has "pinned boot says why" "was at or above the maximum" "$out"
mkfake; pinall; TUNE_BOOT_RETRIES=1 S boot >/dev/null
check "pinned boot with no earlier record: no minimum saved (little)" "" "$(dv little_min)"
check "pinned boot with no earlier record: no minimum saved (big)" "" "$(dv big_min)"
check "pinned boot with no earlier record: the maximum is still saved" 2572800 "$(dv big_max)"
check "pinned boot with no earlier record: the GPU is unaffected" 255000000 "$(dv gpu_min)"
check "pinned boot is written to the log" 1 "$(grep -c 'minimum at or above maximum' "$T/cfg/tune.log")"
# a boost that ends: boot looks again and records the real values
mkfake; pinall
( TUNE_BOOT_RETRIES=8 TUNE_BOOT_WAIT=1 S boot >/dev/null ) & bp=$!
sleep 2; unpin; wait "$bp"
check "boot waits out a boost: little min" 595200 "$(dv little_min)"
check "boot waits out a boost: big min" 633600 "$(dv big_min)"
check "boot waits out a boost: prime min" 633600 "$(dv prime_min)"
check "boot logs what it recorded" 1 "$(grep -c 'boot: stock recorded' "$T/cfg/tune.log")"
# a cluster that really has one frequency is not flagged
mkfake; echo 633600 > "$T/cpufreq/policy7/scaling_available_frequencies"; echo 633600 > "$T/cpufreq/policy7/scaling_max_freq"; echo 633600 > "$T/cpufreq/policy7/scaling_min_freq"
TUNE_BOOT_RETRIES=1 S boot >/dev/null
check "single-frequency cluster: min recorded" 633600 "$(dv prime_min)"

echo "--- a recorded minimum at its maximum is never written back ---"
mkfake; mkdir -p "$T/cfg"
printf 'little_min=2016000\nlittle_max=2016000\nbig_min=2572800\nbig_max=2572800\nprime_min=2668800\nprime_max=2668800\ngpu_min=255000000\ngpu_max=900000000\n' > "$T/cfg/defaults"
out=$(S status | grep '^def_big_min='); check "status does not show a pinned recorded minimum" "def_big_min=" "$out"
S cfg ENABLED 1 >/dev/null; out=$(S cfg ON_BIG_MIN 787200); rc=$?
check "custom min is refused: the recorded minimum is a pinned reading" 1 "$rc"
has "custom min refusal names big_min" "big_min" "$out"
check "custom min refused: nothing written" 633600 "$(v cpufreq/policy3/scaling_min_freq)"
out=$(S preset stock); rc=$?
check "Stock does not pin the minimum at the maximum" 633600 "$(v cpufreq/policy3/scaling_min_freq)"
check "Stock has nothing to restore and says ok" 0 "$rc"

echo "--- a minimum clamped to a lower maximum stays marked and comes back ---"
mkfake; S boot >/dev/null
S cfg ENABLED 1 >/dev/null; S cfg ON_PRIME_MIN 787200 >/dev/null; S cfg OFF_PRIME_MAX 480000 >/dev/null
check "prime min is ours now" 1 "$(grep -c '^prime_min$' "$T/cfg/applied")"
echo 0 > "$T/bl/brightness"; S apply >/dev/null
check "screen off: the max is lowered below the stock min" 480000 "$(v cpufreq/policy7/scaling_max_freq)"
check "screen off: the min followed it down" 480000 "$(v cpufreq/policy7/scaling_min_freq)"
check "screen off: the min is still marked as ours" 1 "$(grep -c '^prime_min$' "$T/cfg/applied")"
echo 120 > "$T/bl/brightness"; S apply >/dev/null
check "screen on: the min is back at 787200" 787200 "$(v cpufreq/policy7/scaling_min_freq)"
S preset stock >/dev/null
check "Stock: the min is the phone's own again" 633600 "$(v cpufreq/policy7/scaling_min_freq)"
mkfake

echo "--- a pinned minimum is never recorded when the frequency list is not readable ---"
nolist_case() { # name, command that breaks the big cluster's list
  mkfake; eval "$2"; echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"
  out=$(TUNE_BOOT_RETRIES=3 TUNE_BOOT_WAIT=0 S boot); rc=$?
  check "$1: exit status" 0 "$rc"
  check "$1: the pinned minimum is not recorded" "" "$(dv big_min)"
  check "$1: the maximum is recorded" 2572800 "$(dv big_max)"
  check "$1: another cluster's minimum is recorded" 595200 "$(dv little_min)"
  check "$1: boot looked again twice" 2 "$(grep -c 'looking again' "$T/cfg/tune.log")"
  check "$1: the kernel minimum was not touched" 2572800 "$(v cpufreq/policy3/scaling_min_freq)"
  has "$1: boot warns" "was at or above the maximum for: big" "$out"
}
nolist_case "list missing"    'rm -f "$T/cpufreq/policy3/scaling_available_frequencies"'
nolist_case "list empty"      ': > "$T/cpufreq/policy3/scaling_available_frequencies"'
nolist_case "list unreadable" 'rm -f "$T/cpufreq/policy3/scaling_available_frequencies"; mkdir "$T/cpufreq/policy3/scaling_available_frequencies"'
nolist_case "list malformed"  'echo abc > "$T/cpufreq/policy3/scaling_available_frequencies"'
nolist_case "list is a zero"  'echo 0 > "$T/cpufreq/policy3/scaling_available_frequencies"'
# a list with exactly one real frequency is a genuine single-speed cluster: recorded, no retry, no warning
mkfake; echo 2572800 > "$T/cpufreq/policy3/scaling_available_frequencies"; echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"
out=$(TUNE_BOOT_RETRIES=3 TUNE_BOOT_WAIT=0 S boot)
check "one-frequency list: the minimum is recorded" 2572800 "$(dv big_min)"
check "one-frequency list: no retry" 0 "$(grep -c 'looking again' "$T/cfg/tune.log" 2>/dev/null)"
case "$out" in *"at or above the maximum"*) echo "FAIL one-frequency list: unexpected warning"; fail=1 ;; *) echo "ok   one-frequency list: no warning" ;; esac
# an existing good snapshot survives a suspicious reading when the list is gone
mkfake; S boot >/dev/null; cp "$T/cfg/defaults" "$T/defaults.keep"
rm -f "$T/cpufreq/policy3/scaling_available_frequencies"; echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"
TUNE_BOOT_RETRIES=3 TUNE_BOOT_WAIT=0 S boot >/dev/null; rc=$?
check "good snapshot, pinned reading, no list: exit status" 0 "$rc"
check "good snapshot, pinned reading, no list: snapshot unchanged" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
check "good snapshot, pinned reading, no list: boot looked again twice" 2 "$(grep -c 'looking again' "$T/cfg/tune.log")"
# status (which also records when nothing is saved yet) behaves the same
mkfake; rm -f "$T/cpufreq/policy3/scaling_available_frequencies"; echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"
S status >/dev/null
check "status with pinned minimum and no list: not recorded" "" "$(dv big_min)"

echo "--- restoring when the frequency list disappears after a minimum was changed ---"
# (a) the recorded minimum is a pinned reading (as an older version could have saved it): never written back
mkfake; mkdir -p "$T/cfg"
printf 'little_min=595200\nlittle_max=2016000\nbig_min=2572800\nbig_max=2572800\nprime_min=633600\nprime_max=2668800\ngpu_min=255000000\ngpu_max=900000000\n' > "$T/cfg/defaults"
cp "$T/cfg/defaults" "$T/defaults.keep"
# the state an older version could leave behind (Apply now refuses to create it): minimum changed and marked
echo 787200 > "$T/cpufreq/policy3/scaling_min_freq"; printf 'big_min\n' > "$T/cfg/applied"
check "pinned record: custom minimum applied and marked" 1 "$(grep -c '^big_min$' "$T/cfg/applied")"
rm -f "$T/cpufreq/policy3/scaling_available_frequencies"
out=$(S preset stock); rc=$?
check "pinned record, list gone: the minimum is NOT pinned at the maximum" 787200 "$(v cpufreq/policy3/scaling_min_freq)"
check "pinned record, list gone: exit status 1" 1 "$rc"
has "pinned record, list gone: says nothing is recorded" "not recorded" "$out"
check "pinned record, list gone: the changed-marker stays" 1 "$(grep -c '^big_min$' "$T/cfg/applied")"
check "pinned record, list gone: the record is untouched" 0 "$(cmp -s "$T/defaults.keep" "$T/cfg/defaults"; echo $?)"
check "pinned record, list gone: status shows no recorded minimum" "def_big_min=" "$(S status | grep '^def_big_min=')"
# (b) a good record: the list is not needed to put the phone's own minimum back
mkfake; S boot >/dev/null; S cfg ENABLED 1 >/dev/null; S cfg ON_BIG_MIN 787200 >/dev/null
check "good record: custom minimum applied and marked" 1 "$(grep -c '^big_min$' "$T/cfg/applied")"
rm -f "$T/cpufreq/policy3/scaling_available_frequencies"
S preset stock >/dev/null; rc=$?
check "good record, list gone: the phone's own minimum is back" 633600 "$(v cpufreq/policy3/scaling_min_freq)"
check "good record, list gone: exit status 0" 0 "$rc"
check "good record, list gone: the changed-marker is cleared" 0 "$(grep -c '^big_min$' "$T/cfg/applied")"
mkfake

echo "--- Apply never changes limits when module-owned limits exist but no stock record does ---"
export TUNE_NO_DAEMON=1
snap() { # every limit node and the marker file, as one comparable text
  for f in "$T"/cpufreq/policy*/scaling_*_freq "$T"/gpu/*_freq; do printf '%s=%s\n' "${f#"$T"/}" "$(cat "$f" 2>/dev/null)"; done
  echo "applied:"; cat "$T/cfg/applied" 2>/dev/null
}
for variant in empty missing; do
  mkfake; S boot >/dev/null; S preset tilt >/dev/null
  check "$variant record: tilt changed the big max first" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
  if [ "$variant" = empty ]; then : > "$T/cfg/defaults"; else rm -f "$T/cfg/defaults"; fi
  snap > "$T/snap.before"
  out=$(S preset saver); rc=$?
  check "$variant record: saver is refused (exit status)" 1 "$rc"
  has "$variant record: says why" "not on record, so no further limit was changed" "$out"
  if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL $variant record: printed ok"; fail=1; else echo "ok   $variant record: no ok line"; fi
  snap > "$T/snap.after"
  check "$variant record: no frequency node and no marker changed" "$(cat "$T/snap.before")" "$(cat "$T/snap.after")"
  check "$variant record: big max still the tilt value" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
  check "$variant record: prime max still the tilt value" 2457600 "$(v cpufreq/policy7/scaling_max_freq)"
  check "$variant record: no new little max marker" 0 "$(grep -cx little_max "$T/cfg/applied")"
  if [ "$variant" = empty ]; then check "$variant record: the record is still zero bytes" 0 "$(wc -c < "$T/cfg/defaults" | tr -d ' ')"
  else check "$variant record: no record was invented" no "$([ -e "$T/cfg/defaults" ] && echo yes || echo no)"; fi
  has "$variant record: logged" "apply refused" "$(cat "$T/cfg/tune.log")"
  # the other ways to ask for the same change
  snap > "$T/snap.before"
  S apply >/dev/null 2>&1; check "$variant record: plain Apply is refused too" 1 $?
  S cfg OFF_LITTLE_MAX 441600 >/dev/null 2>&1; check "$variant record: a changed limit is refused too" 1 $?
  snap > "$T/snap.after"
  check "$variant record: still nothing changed" "$(cat "$T/snap.before")" "$(cat "$T/snap.after")"
  out=$(S status); case "$out" in *"apply refused"*|*"error:"*) echo "FAIL $variant record: status output polluted"; fail=1 ;; *) echo "ok   $variant record: status output is unchanged" ;; esac
  # Stock still says what it cannot do, without a misleading "could not be saved" line
  out=$(S preset stock); has "$variant record: Stock names the missing record" "not recorded yet" "$out"
  case "$out" in *"could not be saved"*) echo "FAIL $variant record: Stock blamed a failed save"; fail=1 ;; *) echo "ok   $variant record: Stock does not blame a failed save" ;; esac
done
# a good record still lets Apply carry on (the fix must not block the normal case)
mkfake; S boot >/dev/null; S preset tilt >/dev/null
out=$(S preset saver); rc=$?
check "good record: saver is applied" 0 "$rc"
check "good record: the limits changed" 1593600 "$(v cpufreq/policy3/scaling_max_freq)"
# the same on a boot-time snapshot: nothing is marked yet, so a first Apply may record stock
mkfake; mkdir -p "$T/cfg"; : > "$T/cfg/defaults"
out=$(S preset tilt); rc=$?
check "empty record, no marker of ours: Apply records stock and proceeds" 0 "$rc"
check "empty record, no marker of ours: stock was recorded" 2572800 "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"

echo "--- a running watcher does not change more limits without a stock record ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=1
mkfake; S boot >/dev/null; S preset tilt >/dev/null
i=0; while [ "$i" -lt 10 ] && [ ! -s "$T/cfg/daemon.pid" ]; do sleep 1; i=$((i + 1)); done
: > "$T/cfg/defaults"; snap > "$T/snap.before"
S preset saver >/dev/null 2>&1                           # refused, but the new setting is saved for the watcher to find
sleep 5
snap > "$T/snap.after"
check "watcher: no limit changed without a record" "$(cat "$T/snap.before")" "$(cat "$T/snap.after")"
has "watcher: says it is holding back" "not changing any more limits" "$(cat "$T/cfg/tune.log")"
check "watcher: logged once, not on every poll" 1 "$(grep -c 'not changing any more limits' "$T/cfg/tune.log")"
mkfake
export TUNE_NO_DAEMON=1

echo "--- a lock that cannot be removed ends the wait instead of spinning ---"
unset TUNE_NO_DAEMON
mkfake; mkdir -p "$T/cfg"
# a lock whose recorded owner is dead, and a removal that always fails (a shell function beats rm in every shell)
mkdir -p "$T/cfg/daemon.lock"; echo 2147483646 > "$T/cfg/daemon.lock/pid"
inj 'rm() { for ij_a; do case "$ij_a" in *daemon.lock*) return 1 ;; esac; done; command rm "$@"; }'
out=$(INJ_TARGET="$TUNE" TUNE_LOCK_TRIES=20 timeout 60 sh "$T/inj.sh" preset tilt 2>&1); rc=$?
check "undeletable stale lock: the command ends (not killed by the timeout)" 1 "$([ "$rc" = 124 ] && echo 0 || echo 1)"
check "undeletable stale lock: the watcher start fails" 1 "$rc"
has "undeletable stale lock: says so" "another start or stop of the watcher is in progress" "$out"
rm -rf "$T/cfg/daemon.lock"
export TUNE_NO_DAEMON=1


echo "--- Stop never signals an unrelated tune.sh daemon ---"
mkfake; mkdir -p "$T/cfg" "$T/unrel"
printf 'while :; do sleep 1; done\n' > "$T/unrel/tune.sh"
sh "$T/unrel/tune.sh" daemon "$T/unrel" >/dev/null 2>&1 & other=$!  # same argv shape, different module path
sleep 1; echo "$other" > "$T/cfg/daemon.pid"
out=$(S status); has "unrelated daemon: status says no watcher" "daemon=0" "$out"
S stop >/dev/null 2>&1
check "unrelated daemon: still running after Stop" "yes" "$(kill -0 "$other" 2>/dev/null && echo yes || echo no)"
check "unrelated daemon: the stale pid file is cleaned up" "no" "$([ -f "$T/cfg/daemon.pid" ] && echo yes || echo no)"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

echo "--- status says so when the saved settings cannot be read ---"
mkfake; S preset tilt >/dev/null
case "$(S status)" in *cfg_error*) echo "FAIL good settings: status reports cfg_error"; fail=1 ;; *) echo "ok   good settings: no cfg_error line" ;; esac
printf 'ENABLED=1\nthis is ( not valid\n' > "$T/cfg/tune.conf"
out=$(S status); has "unreadable settings: status has cfg_error=1" "cfg_error=1" "$out"
has "unreadable settings: status still lists the rest" "enabled=0" "$out"
mkfake; case "$(S status)" in *cfg_error*) echo "FAIL no settings file: status reports cfg_error"; fail=1 ;; *) echo "ok   no settings file at all is not an error" ;; esac
mkfake; S boot >/dev/null; S preset tilt >/dev/null
before_big=$(v cpufreq/policy3/scaling_max_freq)
printf 'ENABLED=1\nSCREENOFF=0\nPRESET=custom\nON_BIG_MAX=99999999\n' > "$T/cfg/tune.conf"
out=$(S status); has "invalid saved frequency: status exposes cfg_error" "cfg_error=1" "$out"
out=$(S apply); rc=$?
check "invalid saved frequency: Apply refuses it" 1 "$rc"
has "invalid saved frequency: Apply explains the corrupted settings" "cannot be read or validated" "$out"
check "invalid saved frequency: unsupported limit not written" "$before_big" "$(v cpufreq/policy3/scaling_max_freq)"
printf 'ENABLED=1\nSCREENOFF=2\nPRESET=custom\n' > "$T/cfg/tune.conf"
has "invalid saved boolean: Status exposes cfg_error" "cfg_error=1" "$(S status)"
printf 'ENABLED=1\nSCREENOFF=0\nPRESET=night\n' > "$T/cfg/tune.conf"
has "invalid saved preset name: Status exposes cfg_error" "cfg_error=1" "$(S status)"
printf 'ENABLED=1\nSCREENOFF=0\nPRESET=custom\nON_BIG_MIN=2188800\nON_BIG_MAX=1593600\n' > "$T/cfg/tune.conf"
has "inverted saved min/max: Status exposes cfg_error" "cfg_error=1" "$(S status)"

echo "--- watcher hands limits back if a saved frequency is not in the kernel list ---"
mkfake; unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=1
S boot >/dev/null; S preset tilt >/dev/null
check "invalid saved frequency watcher: preset initially applies" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
printf 'ENABLED=1\nSCREENOFF=0\nPRESET=custom\nON_BIG_MAX=99999999\n' > "$T/cfg/tune.conf"
waitfor "invalid saved frequency watcher: original big max restored" 2572800 cpufreq/policy3/scaling_max_freq 15
waitfor "invalid saved frequency watcher: watcher exits" "" cfg/daemon.pid 15
has "invalid saved frequency watcher: refusal is logged" "a saved frequency is not available on this phone" "$(cat "$T/cfg/tune.log" 2>/dev/null)"
check "invalid saved frequency watcher: marker cleared after restore" 0 "$(grep -cx big_max "$T/cfg/applied" 2>/dev/null)"
export TUNE_NO_DAEMON=1 TUNE_POLL_ON=3 TUNE_POLL_OFF=1 TUNE_REASSERT=10

echo "--- the new profiles: failure paths and edge cases ---"
export TUNE_NO_DAEMON=1
out=$(S preset bogus); rc=$?
check "unknown preset: exit 1" 1 "$rc"
has "unknown preset: the message lists the new presets" "performance, dynamic or custom" "$out"
# Custom from Stock keeps everything empty and turns the editor on
mkfake; S preset stock >/dev/null
out=$(S preset custom); rc=$?; check "custom from stock: exit 0" 0 "$rc"
out=$(S status); has "custom from stock: named" "preset=custom" "$out"; has "custom from stock: enabled" "enabled=1" "$out"
check "custom from stock: big max untouched" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "custom from stock: no value invented" "" "$(sed -n 's/^ON_BIG_MAX=//p' "$T/cfg/tune.conf")"
# Custom never replaces a settings file it cannot read
mkfake; S preset tilt >/dev/null; printf 'ENABLED=7\nPRESET=tilt\n' > "$T/cfg/tune.conf"; cp "$T/cfg/tune.conf" "$T/conf.bad"
out=$(S preset custom); rc=$?
check "custom with unreadable settings: exit 1" 1 "$rc"
check "custom with unreadable settings: the file is byte for byte as it was" "$(cat "$T/conf.bad")" "$(cat "$T/cfg/tune.conf")"
if printf '%s\n' "$out" | grep -qx ok; then echo "FAIL custom with unreadable settings printed ok"; fail=1; else echo "ok   custom with unreadable settings: no ok line"; fi
# Custom with a settings file that cannot be saved
mkfake; S preset tilt >/dev/null; cp "$T/cfg/tune.conf" "$T/conf.good"
inj 'mv() { for ij_a; do case "$ij_a" in *tune.conf.tmp) return 1 ;; esac; done; command mv "$@"; }'
out=$(SI preset custom); rc=$?
check "custom, save fails: exit 1" 1 "$rc"
check "custom, save fails: the old settings are untouched" "$(cat "$T/conf.good")" "$(cat "$T/cfg/tune.conf")"
check "custom, save fails: the limits stay as they were" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
# Dynamic skips a cap this phone does not list, and says so (the same check every preset goes through)
mkfake; sed -i 's/ 787200//' "$T/cpufreq/policy3/scaling_available_frequencies"
out=$(S preset dynamic); has "dynamic: an unavailable cap is skipped with a warning" "warn: preset value 787200 is not available for big" "$out"
check "dynamic: the skipped cap is not saved" "" "$(sed -n 's/^OFF_BIG_MAX=//p' "$T/cfg/tune.conf")"
check "dynamic: the other screen-off caps are saved" 633600 "$(sed -n 's/^OFF_PRIME_MAX=//p' "$T/cfg/tune.conf")"
# Dynamic: the screen-off caps come off again when the module is turned off, and Reset everything restores them
mkfake; S preset dynamic >/dev/null; echo 0 > "$T/bl/brightness"; S apply >/dev/null
check "dynamic, screen off: capped" 787200 "$(v cpufreq/policy3/scaling_max_freq)"
S resetall >/dev/null; check "Reset everything from dynamic (screen off): big max back" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "Reset everything from dynamic: GPU max back" 900000000 "$(v gpu/max_freq)"
check "Reset everything from dynamic: no marker left" 0 "$(wc -l < "$T/cfg/applied" 2>/dev/null | tr -d ' ' | grep -v '^$' || echo 0)"
echo 120 > "$T/bl/brightness"
# Performance and Dynamic survive a reboot (boot re-applies the saved preset)
mkfake; S preset dynamic >/dev/null; mksys
out=$(S boot); has "boot with dynamic: done" "boot done: enabled=1 preset=dynamic" "$out"
mkfake; S preset performance >/dev/null; mksys
out=$(S boot); has "boot with performance: done" "boot done: enabled=1 preset=performance" "$out"
check "boot with performance: no limit changed" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
# A tilt -> performance -> tilt round trip leaves nothing behind
mkfake; S preset tilt >/dev/null; S preset performance >/dev/null; S preset tilt >/dev/null; S preset stock >/dev/null
check "round trip: big max back to the phone's own" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "round trip: no marker left" 0 "$(grep -c . "$T/cfg/applied" 2>/dev/null || true)"
# The Action button's cycle leaves the new presets for Stock
rm -rf "$T/modact"; cp -r "$HERE/../module" "$T/modact"
for np in performance dynamic custom; do
  mkfake; S preset "$np" >/dev/null
  out=$(sh "$T/modact/action.sh" 2>&1); has "Action from $np goes to Stock" "Frequency preset: stock" "$out"
done
mkfake

echo "--- v1.4.4: stock is the lowest minimum and highest maximum over a window, not one reading ---"
# A boost raises the minimums (and a cap lowers the maximums) for a few seconds. The reading at the start of
# the window lands inside it; the window must still record the phone's own values.
mkfake; rm -f "$T/cfg/defaults"
echo 1843200 > "$T/cpufreq/policy0/scaling_min_freq"; echo 1286400 > "$T/cpufreq/policy3/scaling_min_freq"; echo 1651200 > "$T/cpufreq/policy7/scaling_min_freq"
echo 2188800 > "$T/cpufreq/policy3/scaling_max_freq"; echo 2304000 > "$T/cpufreq/policy7/scaling_max_freq"
( sleep 3; echo 595200 > "$T/cpufreq/policy0/scaling_min_freq"; echo 633600 > "$T/cpufreq/policy3/scaling_min_freq"; echo 633600 > "$T/cpufreq/policy7/scaling_min_freq"
  echo 2572800 > "$T/cpufreq/policy3/scaling_max_freq"; echo 2668800 > "$T/cpufreq/policy7/scaling_max_freq" ) &
boostend=$!
TUNE_CAP_BOOT_SAMPLES=3 TUNE_CAP_BOOT_GAP=2 S boot >/dev/null 2>&1; wait "$boostend"
d=$(cat "$T/cfg/defaults" 2>/dev/null)
has "boost window: little min recorded at its real value" "little_min=595200" "$d"
has "boost window: big min recorded at its real value" "big_min=633600" "$d"
has "boost window: prime min recorded at its real value" "prime_min=633600" "$d"
has "boost window: big max recorded at its real value" "big_max=2572800" "$d"
has "boost window: prime max recorded at its real value" "prime_max=2668800" "$d"

echo "--- v1.4.4: a limit is refused when a bound it could move has no recorded original value ---"
# Minimums pinned at their maximums for the whole window are not recorded (they are not the phone's own values).
# Battery Tilt would then lower them to fit under the new maximums and Stock could not put them back.
mkfake; rm -f "$T/cfg/defaults" "$T/cfg/applied"
echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"; echo 2668800 > "$T/cpufreq/policy7/scaling_min_freq"
out=$(S preset tilt); rc=$?
check "unrecorded minimum: Battery Tilt is refused" 1 "$rc"
has "unrecorded minimum: the refusal names big_min" "big_min" "$out"
has "unrecorded minimum: the refusal names prime_min" "prime_min" "$out"
check "unrecorded minimum: big max unchanged" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "unrecorded minimum: big min unchanged" 2572800 "$(v cpufreq/policy3/scaling_min_freq)"
check "unrecorded minimum: prime max unchanged" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "unrecorded minimum: prime min unchanged" 2668800 "$(v cpufreq/policy7/scaling_min_freq)"
check "unrecorded minimum: gpu max unchanged" 900000000 "$(v gpu/max_freq)"
check "unrecorded minimum: no change markers" 0 "$(grep -c . "$T/cfg/applied" 2>/dev/null || echo 0)"

echo "--- v3.5.0: a refused preset does not stay saved as the chosen profile ---"
mkfake; rm -f "$T/cfg/defaults" "$T/cfg/applied"
echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"; echo 2668800 > "$T/cpufreq/policy7/scaling_min_freq"
S preset stock >/dev/null                      # an earlier choice is on file (and nothing is on record for the minimums)
out=$(S preset tilt); rc=$?
check "refused preset: exit status 1" 1 "$rc"
has "refused preset: says the earlier settings were kept" "previous settings were kept" "$out"
out=$(S status)
has "refused preset: status still shows the earlier profile" "preset=stock" "$out"
has "refused preset: status still shows nothing enabled" "enabled=0" "$out"
check "refused preset: no leftover backup file" no "$([ -e "$T/cfg/tune.conf.prev" ] && echo yes || echo no)"
mkfake; rm -f "$T/cfg/defaults" "$T/cfg/applied" "$T/cfg/tune.conf"
echo 2572800 > "$T/cpufreq/policy3/scaling_min_freq"; echo 2668800 > "$T/cpufreq/policy7/scaling_min_freq"
S preset tilt >/dev/null
check "refused preset with no earlier file: none is left behind" no "$([ -e "$T/cfg/tune.conf" ] && echo yes || echo no)"


echo "--- the tuning engine finds Kprofiles at the upstream module-parameter path too ---"
KLR="$T/kl"; rm -rf "$KLR"; mkdir -p "$KLR/sys/module/kprofiles/parameters"
mkfake; echo 1 > "$KLR/sys/module/kprofiles/parameters/kp_mode"          # kernel Battery profile active, nothing recorded yet
out=$( ( unset KP_PATH AUTO_PATH; export KP_SYSROOT="$KLR"; S status ) )
check "upstream path, Battery active: nothing is recorded as stock" "" "$(printf '%s\n' "$out" | sed -n 's/^def_big_max=//p')"
check "upstream path, Battery active: no defaults file is written" "no" "$([ -f "$T/cfg/defaults" ] && echo yes || echo no)"
echo 0 > "$KLR/sys/module/kprofiles/parameters/kp_mode"
out=$( ( unset KP_PATH AUTO_PATH; export KP_SYSROOT="$KLR"; S status ) )
check "upstream path, profile None: stock is recorded" 2572800 "$(printf '%s\n' "$out" | sed -n 's/^def_big_max=//p')"

[ "$fail" = 0 ] && echo "all tune tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
