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
mkfake() {
  rm -rf "$T/cpufreq" "$T/gpu" "$T/cfg"; mkdir -p "$T/bl"
  mkpol "$T/cpufreq/policy0" "364800 441600 595200 787200 902400 1017600 1113600 1228800 1344000 1478400 1593600 1708800 1843200 1900800 2016000" 595200 2016000
  mkpol "$T/cpufreq/policy3" "480000 633600 787200 940800 1056000 1190400 1286400 1401600 1497600 1593600 1708800 1824000 1920000 2073600 2188800 2361600 2572800 2611200 2707200" 633600 2572800
  mkpol "$T/cpufreq/policy7" "480000 633600 787200 960000 1094400 1209600 1324800 1459200 1651200 1766400 1900800 2150400 2304000 2457600 2668800 2803200 2918400" 633600 2668800
  mkdir -p "$T/gpu"; echo "1100000000 1000000000 950000000 900000000 835000000 736000000 684000000 633000000 500000000 353000000 255000000" > "$T/gpu/available_frequencies"
  echo 255000000 > "$T/gpu/min_freq"; echo 900000000 > "$T/gpu/max_freq"
  echo 120 > "$T/bl/brightness"
}
export CPUFREQ_DIR="$T/cpufreq" GPU_DIR="$T/gpu" BL_PATH="$T/bl/brightness" CFG_DIR="$T/cfg" TUNE_NO_DAEMON=1
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

echo "--- boot: rebuild defaults, forget old bookkeeping ---"
mkfake; S preset tilt >/dev/null
out=$(S boot); has "boot reports" "boot done: enabled=1 preset=tilt" "$out"
check "boot re-applied on-set" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
out=$(S status); has "boot captured the values it found as defaults" "def_big_max=2188800" "$out"

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

[ "$fail" = 0 ] && echo "all tune tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
