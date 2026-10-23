#!/bin/sh
# Off-device test of module/tune.sh using a fake sysfs tree that mirrors a POCO F6 (peridot).
HERE=$(cd "$(dirname "$0")" && pwd)
TUNE="$HERE/../module/tune.sh"
T=$(mktemp -d)
cleanup() { [ -f "$T/cfg/daemon.pid" ] && kill "$(cat "$T/cfg/daemon.pid")" 2>/dev/null; rm -rf "$T"; }
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
mkfake() { rm -rf "$T/cpufreq" "$T/gpu" "$T/cfg" "$T/kp"; mksys; }
export CPUFREQ_DIR="$T/cpufreq" GPU_DIR="$T/gpu" BL_PATH="$T/bl/brightness" CFG_DIR="$T/cfg" TUNE_NO_DAEMON=1 KP_PATH="$T/kp/kp_mode" AUTO_PATH="$T/kp/auto_kp"
v() { cat "$T/$1"; }
waitfor() { # name expected file seconds   (poll instead of a fixed sleep, so slow runners do not flake)
  i=0
  while [ "$i" -lt "$4" ]; do
    if [ "$(cat "$T/$3")" = "$2" ]; then echo "ok   $1"; return; fi
    sleep 1; i=$((i + 1))
  done
  echo "FAIL $1: expected '$2' got '$(cat "$T/$3")'"; fail=1
}
S() { sh "$TUNE" "$@"; }

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
mkfake; S preset saver >/dev/null; sh "$HERE/../module/kp.sh" mode 1 >/dev/null
check "kernel profile Battery set" 1 "$(v kp/kp_mode)"
S resetall >/dev/null
check "resetall: big max stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "resetall: gpu max stock" 900000000 "$(v gpu/max_freq)"
check "resetall: kernel profile None" 0 "$(v kp/kp_mode)"
out=$(S status); has "resetall: limits disabled" "enabled=0" "$out"

echo "--- uninstall restores limits, resets the kernel profile, removes saved settings ---"
mkfake; S preset tilt >/dev/null; sh "$HERE/../module/kp.sh" mode 3 >/dev/null
check "performance profile set" 3 "$(v kp/kp_mode)"
KPUI_TEST_CFG_DIR="$T/cfg" sh "$HERE/../module/uninstall.sh"
check "uninstall: big max restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
check "uninstall: prime max restored" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
check "uninstall: gpu max restored" 900000000 "$(v gpu/max_freq)"
check "uninstall: kernel profile None" 0 "$(v kp/kp_mode)"
check "uninstall: saved settings removed" "no" "$([ -d "$T/cfg" ] && echo yes || echo no)"

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

echo "--- preset values are checked against the phone's own list ---"
mkfake; TUNE_NO_DAEMON=1
sed -i 's/ 1017600//' "$T/cpufreq/policy0/scaling_available_frequencies"   # this phone lacks 1017600
out=$(S preset tilt); has "preset skips unavailable value" "warn: preset value 1017600 is not available for little" "$out"
check "skipped value not saved" "" "$(sed -n 's/^OFF_LITTLE_MAX=//p' "$T/cfg/tune.conf")"
check "valid preset values still applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- boot order: record stock values BEFORE the kernel profile is applied ---"
SVC="$HERE/../module/service.sh"
a=$(grep -n 'tune.sh" boot' "$SVC" | head -n 1 | cut -d: -f1); b=$(grep -n 'kp.sh" apply' "$SVC" | head -n 1 | cut -d: -f1)
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -le "$b" ] && [ "$(sed -n "${a}p" "$SVC" | grep -c 'kp.sh')" -ge 0 ]; then
  # on one line: tune boot must come first in the command list
  line=$(grep 'tune.sh" boot' "$SVC" | head -n 1)
  case "$line" in *'tune.sh" boot'*'kp.sh" apply'*) echo "ok   service.sh runs tune boot before kp apply" ;; *) echo "FAIL service.sh order"; fail=1 ;; esac
else
  echo "FAIL service.sh lines not found"; fail=1
fi

echo "--- uninstall never deletes a folder named by a stray CFG_DIR ---"
mkfake; mkdir -p "$T/precious"; echo keep > "$T/precious/file"
CFG_DIR="$T/precious" sh "$HERE/../module/uninstall.sh"
check "stray CFG_DIR survives uninstall" "keep" "$(cat "$T/precious/file" 2>/dev/null)"

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
out=$(S preset tilt); has "no stock recorded: Apply warns" "warn: the phone's own limits are not recorded yet" "$out"
out=$(S preset stock); has "no stock recorded: Stock warns" "warn: the phone's own limits are not recorded yet" "$out"
mksys; S boot >/dev/null                                                # a reboot records the real values
out=$(S preset tilt); case "$out" in *"not recorded yet"*) echo "FAIL warning persists after boot"; fail=1 ;; *) echo "ok   no warning once stock is recorded" ;; esac
S preset stock >/dev/null
check "after the reboot Stock restores the real value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- the watcher hands the limits back when the module is disabled or removed ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3
for marker in disable remove; do
  mkfake; rm -rf "$T/mod"; mkdir -p "$T/mod"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod/"   # tune.sh looks for the marker in its own folder
  S2() { sh "$T/mod/tune.sh" "$@"; }
  S2 preset tilt >/dev/null
  i=0; while [ "$i" -lt 10 ]; do out=$(S2 status); case "$out" in *daemon=1*) break ;; esac; sleep 1; i=$((i + 1)); done
  has "$marker test: watcher running" "daemon=1" "$out"
  check "$marker test: limit applied" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
  touch "$T/mod/$marker"
  waitfor "$marker marker: limit handed back" 2572800 cpufreq/policy3/scaling_max_freq 15
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

[ "$fail" = 0 ] && echo "all tune tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
