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
cleanup() { reap; rm -rf "$T"; }
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
mkfake() { reap; rm -rf "$T/cpufreq" "$T/gpu" "$T/cfg" "$T/kp"; mksys; }
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
# the shipped script deletes a fixed path, so run a copy whose target is the fixture folder
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh"
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
export TUNE_NO_DAEMON=1

echo "--- preset values are checked against the phone's own list ---"
mkfake; export TUNE_NO_DAEMON=1
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
out=$(S preset tilt); has "no stock recorded: Apply warns" "warn: the phone's own limits are not recorded yet" "$out"
out=$(S preset stock); has "no stock recorded: Stock warns" "warn: the phone's own limits are not recorded yet" "$out"
mksys; S boot >/dev/null                                                # a reboot records the real values
out=$(S preset tilt); case "$out" in *"not recorded yet"*) echo "FAIL warning persists after boot"; fail=1 ;; *) echo "ok   no warning once stock is recorded" ;; esac
S preset stock >/dev/null
check "after the reboot Stock restores the real value" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"

echo "--- the watcher hands the limits back when the module is disabled or removed ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3 TUNE_DAEMON_LOG="$T/daemon.log"
for marker in disable remove; do
  : > "$T/daemon.log"
  mkfake; rm -rf "$T/mod"; mkdir -p "$T/mod"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod/"   # tune.sh looks for the marker in its own folder
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
S preset tilt >/dev/null; out=$(S preset stock); has "no record: Stock says so" "not recorded yet" "$out"

echo "--- Reset everything: profile first, and failures are reported ---"
mkfake; S preset saver >/dev/null; sh "$HERE/../module/kp.sh" mode 1 >/dev/null
out=$(S resetall); has "resetall ok: says ok" "ok" "$out"
check "resetall ok: profile None" 0 "$(v kp/kp_mode)"
check "resetall ok: big max stock" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
mkfake; S preset saver >/dev/null; rm -f "$T/kp/kp_mode"; mkdir "$T/kp/kp_mode"      # a kernel profile node that cannot be written
S resetall >"$T/ra.out" 2>&1; rc=$?
check "resetall: failing profile gives a non-zero exit" 1 "$rc"
has "resetall: failing profile is reported" "error: the kernel profile could not be set to None" "$(cat "$T/ra.out")"
check "resetall: limits still restored when the profile fails" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
rmdir "$T/kp/kp_mode"; echo 0 > "$T/kp/kp_mode"
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
echo "--- a stale pid file never makes stop signal an unrelated process ---"
sleep 300 & bystander=$!
mkfake; mkdir -p "$T/cfg"; echo "$bystander" > "$T/cfg/daemon.pid"
S stop >/dev/null
if kill -0 "$bystander" 2>/dev/null; then echo "ok   unrelated process left alone"; else echo "FAIL unrelated process was killed"; fail=1; fi
kill "$bystander" 2>/dev/null
export TUNE_NO_DAEMON=1

echo "--- watcher started by name from inside the module folder still gets the real module folder ---"
unset TUNE_NO_DAEMON; export TUNE_POLL_ON=1 TUNE_POLL_OFF=1 TUNE_REASSERT=3
for marker in disable remove; do
  mkfake; rm -rf "$T/mod" "$T/elsewhere"; mkdir -p "$T/mod" "$T/elsewhere"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod/"
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
unset TUNE_NO_DAEMON
mkfake; mkdir -p "$T/cfg" "$T/stub"
printf 'trap "" TERM\nwhile :; do sleep 1; done\n' > "$T/stub/tune.sh"
sh "$T/stub/tune.sh" & stubp=$!
echo "$stubp" > "$T/cfg/daemon.pid"; sleep 1
out=$(S stop); has "stubborn watcher: stop warns" "did not stop within 3 seconds" "$out"
check "stubborn watcher: pid file kept" "$stubp" "$(cat "$T/cfg/daemon.pid" 2>/dev/null)"
kill -9 "$stubp" 2>/dev/null; wait "$stubp" 2>/dev/null
rm -f "$T/cfg/daemon.pid"
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
mkfake; rm -rf "$T/mod"; mkdir -p "$T/mod"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod/"
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
out=$(S preset tilt); has "partial snapshot: Apply names the missing value" "not recorded for: big_max" "$out"
out=$(S preset stock); has "partial snapshot: Stock names it too" "not recorded for: big_max" "$out"
check "partial snapshot: no value was invented for big max" "" "$(sed -n 's/^big_max=//p' "$T/cfg/defaults")"
check "partial snapshot: big max is left as it is" 2188800 "$(v cpufreq/policy3/scaling_max_freq)"
check "partial snapshot: the recorded ones were restored" 2668800 "$(v cpufreq/policy7/scaling_max_freq)"
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
cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod0/"; cp "$HERE/../module/tune.sh" "$HERE/../module/kp.sh" "$T/mod/"
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
stubborn() { # a stand-in watcher that ignores TERM; its pid file names it
  mkfake; mkdir -p "$T/cfg" "$T/stub"
  printf 'trap "" TERM\nwhile :; do sleep 1; done\n' > "$T/stub/tune.sh"
  S preset tilt >/dev/null
  sh "$T/stub/tune.sh" daemon & stubp=$!
  echo "$stubp" > "$T/cfg/daemon.pid"; sleep 1
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
# uninstall keeps the recovery data while the watcher is still running
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; check "uninstall with a stuck watcher: exits non-zero" 1 "$?"
check "uninstall with a stuck watcher keeps the recorded stock values" "yes" "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "uninstall with a stuck watcher keeps the settings" "yes" "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
kill -9 "$stubp" 2>/dev/null; wait "$stubp" 2>/dev/null; rm -f "$T/cfg/daemon.pid"
sh "$T/modu/uninstall.sh"
check "uninstall removes the saved settings once the watcher is gone" "no" "$([ -e "$T/cfg" ] && echo yes || echo no)"

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

echo "--- uninstall keeps the recovery data when the kernel profile cannot be reset ---"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; sh "$HERE/../module/kp.sh" mode 3 >/dev/null
rm -f "$T/kp/kp_mode"; mkdir "$T/kp/kp_mode"                            # the kernel profile node cannot be written
rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "kernel profile reset fails: uninstall exits non-zero" 1 "$rc"
check "kernel profile reset fails: recorded stock values kept" yes "$([ -s "$T/cfg/defaults" ] && echo yes || echo no)"
check "kernel profile reset fails: settings kept" yes "$([ -s "$T/cfg/tune.conf" ] && echo yes || echo no)"
check "kernel profile reset fails: the limits themselves were restored" 2572800 "$(v cpufreq/policy3/scaling_max_freq)"
rmdir "$T/kp/kp_mode"; echo 3 > "$T/kp/kp_mode"
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "kernel profile resets: uninstall exits 0" 0 "$rc"
check "kernel profile resets: profile is None" 0 "$(v kp/kp_mode)"
check "kernel profile resets: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"
mkfake; S boot >/dev/null; S preset tilt >/dev/null; rm -rf "$T/kp"     # a kernel without Kprofiles has nothing to reset
sh "$T/modu/uninstall.sh" >/dev/null 2>&1; rc=$?
check "no Kprofiles in the kernel: uninstall still finishes" 0 "$rc"
check "no Kprofiles in the kernel: saved settings removed" no "$([ -e "$T/cfg" ] && echo yes || echo no)"

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
  mkfake; S boot >/dev/null; S preset tilt >/dev/null; sh "$HERE/../module/kp.sh" mode 1 >/dev/null
  rm -f "$T/cpufreq/policy3/scaling_max_freq"; mkdir "$T/cpufreq/policy3/scaling_max_freq"
  rm -rf "$T/modu"; cp -r "$HERE/../module" "$T/modu"
  sed "s#/data/adb/kprofiles_ui#$T/cfg#" "$HERE/../module/uninstall.sh" > "$T/modu/uninstall.sh"
  mv "$T/modu/kp.sh" "$T/modu/kp-real.sh"
  cat > "$T/modu/kp.sh" <<'WRAP'
#!/bin/sh
D=$(dirname "$0")
sh "$D/kp-real.sh" "$@"; rc=$?
if [ "$1" = mode ] && [ "$2" = 0 ] && [ "$rc" = 0 ] && [ -d "$BIGNODE" ]; then rmdir "$BIGNODE"; echo 2188800 > "$BIGNODE"; fi
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
mkfake; S boot >/dev/null; S preset tilt >/dev/null; sh "$HERE/../module/kp.sh" mode 1 >/dev/null
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

[ "$fail" = 0 ] && echo "all tune tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
