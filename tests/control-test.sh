#!/bin/sh
# Controller source migration, mutually exclusive command guards and verified handoff.
HERE=$(cd "$(dirname "$0")" && pwd)
MOD="$HERE/../module"
CONTROL="$MOD/control.sh"
KP="$MOD/kp.sh"
TUNE="$MOD/tune.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
contains() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }

setup_state() {
  CASE_DIR=$1
  export CFG_DIR="$CASE_DIR/cfg" CONTROL_DIR="$CASE_DIR/cfg" CONTROL_FILE="$CASE_DIR/cfg/control.conf"
  export KP_PATH="$CASE_DIR/kp_mode" AUTO_PATH="$CASE_DIR/auto_kp"
  mkdir -p "$CFG_DIR"
  echo 0 > "$KP_PATH"; echo N > "$AUTO_PATH"
}

# A previously active preset plus a kernel mode must not be silently resolved.
setup_state "$T/migrate-conflict"
printf 'ENABLED=1\nSCREENOFF=1\nPRESET=tilt\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=1\nMODE=2\nAUTO=N\n' > "$CFG_DIR/config"
echo 2 > "$KP_PATH"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "overlapping legacy preset and kernel mode: init returns without guessing" 0 "$rc"
check "overlapping legacy setup: source becomes conflict" "conflict" "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "overlapping legacy setup: current kernel mode is left untouched" 2 "$(cat "$KP_PATH")"
check "overlapping legacy setup: message asks for explicit choice" yes "$(contains "$out" "Choose a controller")"

# auto_kp=Y can re-activate kernel profiles after screen transitions, so it also counts as a possible overlap.
setup_state "$T/migrate-auto-conflict"
printf 'ENABLED=1\nSCREENOFF=1\nPRESET=tilt\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=0\nMODE=0\nAUTO=N\n' > "$CFG_DIR/config"
echo Y > "$AUTO_PATH"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "auto_kp overlap: init returns without guessing" 0 "$rc"
check "auto_kp overlap: source becomes conflict" conflict "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "auto_kp overlap: auto_kp is not silently changed during migration" Y "$(cat "$AUTO_PATH")"

# A single active kernel selection migrates to Kernel source, preserves its preference, and is neutralized before service reapplies it.
setup_state "$T/migrate-kernel"
printf 'ENABLED=0\nSCREENOFF=1\nPRESET=stock\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=1\nMODE=2\nAUTO=Y\n' > "$CFG_DIR/config"
echo 2 > "$KP_PATH"; echo Y > "$AUTO_PATH"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "kernel-only legacy state migrates successfully" 0 "$rc"
check "kernel-only legacy state selects kernel source" kernel "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "kernel preference is saved separately" 2 "$(sed -n 's/^KP_MODE_PREF=//p' "$CONTROL_FILE")"
check "auto preference is saved separately" Y "$(sed -n 's/^KP_AUTO_PREF=//p' "$CONTROL_FILE")"
check "migration runtime mode is neutralized" 0 "$(cat "$KP_PATH")"
check "migration auto_kp is neutralized" N "$(cat "$AUTO_PATH")"

# Missing Kprofiles support is a valid module-only configuration; malformed support becomes a conflict.
setup_state "$T/migrate-unsupported"
printf 'ENABLED=0\nPRESET=stock\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=1\nMODE=2\nAUTO=Y\n' > "$CFG_DIR/config"
rm -f "$KP_PATH" "$AUTO_PATH"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "missing Kprofiles interface allows module-only migration" 0 "$rc"
check "missing Kprofiles interface selects Module presets" module "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"

setup_state "$T/migrate-unknown"
printf 'ENABLED=0\nPRESET=stock\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=0\nMODE=0\nAUTO=N\n' > "$CFG_DIR/config"
echo unknown > "$KP_PATH"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "unknown Kprofiles state cannot be guessed" conflict "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "unknown Kprofiles value is left untouched" unknown "$(cat "$KP_PATH")"

# Engine-side enforcement cannot be bypassed by using direct shell commands.
setup_state "$T/guards"
printf 'SOURCE=module\nKP_MODE_PREF=2\nKP_AUTO_PREF=Y\n' > "$CONTROL_FILE"
sh "$KP" mode 3 >/dev/null 2>&1; check "kernel profile write is blocked in Module mode" 1 "$?"
check "blocked kernel profile write changes nothing" 0 "$(cat "$KP_PATH")"
sh "$KP" auto Y >/dev/null 2>&1; check "auto_kp enable is blocked in Module mode" 1 "$?"
check "blocked auto_kp enable changes nothing" N "$(cat "$AUTO_PATH")"
sh "$KP" persist 1 >/dev/null 2>&1; check "persist 1 in Module mode succeeds" 0 "$?"
check "persist 1 preserves saved kernel mode" 2 "$(sed -n 's/^MODE=//p' "$CFG_DIR/config")"
check "persist 1 normalizes saved auto preference" Y "$(sed -n 's/^AUTO=//p' "$CFG_DIR/config")"

setup_state "$T/guards-kernel"
printf 'SOURCE=kernel\nKP_MODE_PREF=2\nKP_AUTO_PREF=Y\n' > "$CONTROL_FILE"
printf 'ENABLED=0\nPRESET=stock\n' > "$CFG_DIR/tune.conf"
cp "$CFG_DIR/tune.conf" "$T/tune.before"
sh "$TUNE" preset saver >/dev/null 2>&1; check "module preset write is blocked in Kernel mode" 1 "$?"
check "blocked preset write preserves config" "$(cksum < "$T/tune.before")" "$(cksum < "$CFG_DIR/tune.conf")"

# A missing controller file is not permission to bypass the engine guard. Legacy migration must run
# before either direct kp.sh or tune.sh writes, and overlapping legacy state must remain unresolved.
setup_state "$T/legacy-direct-conflict"
printf 'ENABLED=1\nSCREENOFF=1\nPRESET=tilt\n' > "$CFG_DIR/tune.conf"
printf 'PERSIST=1\nMODE=2\nAUTO=N\n' > "$CFG_DIR/config"
echo 2 > "$KP_PATH"
rm -f "$CONTROL_FILE"
out=$(sh "$KP" mode 3 2>&1); rc=$?
check "legacy direct Kprofiles write is refused on overlapping state" 1 "$rc"
check "legacy direct write creates explicit conflict state" conflict "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "legacy direct write leaves the active kernel mode unchanged" 2 "$(cat "$KP_PATH")"
out=$(sh "$TUNE" preset saver 2>&1); rc=$?
check "legacy direct preset is refused on overlapping state" 1 "$rc"
check "legacy direct preset leaves the conflict unresolved" conflict "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"

# End-to-end switch on fake CPUFreq/KGSL nodes. This exercises the same stop/restore/apply order as the phone.
setup_state "$T/handoff"
SYS="$T/handoff/sys"
CPUFREQ="$SYS/devices/system/cpu/cpufreq"
GPU="$SYS/class/kgsl/kgsl-3d0/devfreq"
mkdir -p "$CPUFREQ/policy0" "$CPUFREQ/policy3" "$CPUFREQ/policy7" "$GPU" "$SYS/class/backlight"
export CPUFREQ_DIR="$CPUFREQ" GPU_DIR="$GPU" BL_PATH="$SYS/class/backlight/brightness"
export TUNE_CAP_SAMPLES=1 TUNE_CAP_GAP=0 TUNE_CAP_BOOT_SAMPLES=1 TUNE_CAP_BOOT_GAP=0 TUNE_BOOT_RETRIES=1 TUNE_BOOT_WAIT=0 TUNE_NO_DAEMON=1 TUNE_LOCK_TRIES=3 TUNE_START_TRIES=3
printf '100\n' > "$BL_PATH"
make_policy() {
  d=$1; min=$2; max=$3; avail=$4
  printf '%s\n' "$min" > "$d/scaling_min_freq"
  printf '%s\n' "$max" > "$d/scaling_max_freq"
  printf '%s\n' "$avail" > "$d/scaling_available_frequencies"
  printf '%s\n' 'qcom-cpufreq-hw' > "$d/scaling_driver"
}
make_policy "$CPUFREQ/policy0" 364800 2016000 '364800 595200 787200 1017600 1209600 1401600 1708800 2016000'
make_policy "$CPUFREQ/policy3" 480000 2803200 '480000 633600 787200 1286400 1593600 1766400 2016000 2188800 2457600 2572800 2803200'
make_policy "$CPUFREQ/policy7" 480000 3014400 '480000 633600 787200 1286400 1593600 1766400 2016000 2188800 2457600 2572800 2668800 2803200 3014400'
printf '364800 595200 787200 1017600 1209600 1401600 1708800 2016000\n' > "$CPUFREQ/policy0/scaling_available_frequencies"
printf '255000000\n' > "$GPU/min_freq"
printf '1100000000\n' > "$GPU/max_freq"
printf '255000000 353000000 500000000 633000000 684000000 736000000 835000000 900000000 950000000 1000000000 1100000000\n' > "$GPU/available_frequencies"
printf 'PERSIST=1\nMODE=2\nAUTO=Y\n' > "$CFG_DIR/config"
printf 'SOURCE=module\nKP_MODE_PREF=2\nKP_AUTO_PREF=Y\n' > "$CONTROL_FILE"
printf 'ENABLED=0\nSCREENOFF=1\nPRESET=stock\n' > "$CFG_DIR/tune.conf"
echo 0 > "$KP_PATH"; echo N > "$AUTO_PATH"
TUNE_NO_DAEMON=1 sh "$TUNE" preset tilt >/dev/null 2>&1; rc=$?
check "fake module preset can be applied on exposed policies" 0 "$rc"
check "fake module preset applies a limit before handoff" 2188800 "$(cat "$CPUFREQ/policy3/scaling_max_freq")"
out=$(sh "$CONTROL" switch kernel 2>&1); rc=$?
check "Module -> Kernel handoff succeeds" 0 "$rc"
check "Module -> Kernel handoff selects kernel source" kernel "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "Module -> Kernel restores module CPU cap" 2803200 "$(cat "$CPUFREQ/policy3/scaling_max_freq")"
check "Module -> Kernel leaves Kprofiles mode at saved choice" 2 "$(cat "$KP_PATH")"
check "Module -> Kernel restores auto_kp preference" Y "$(cat "$AUTO_PATH")"
sh "$TUNE" preset saver >/dev/null 2>&1; check "direct tune.sh preset is rejected after Kernel handoff" 1 "$?"
out=$(sh "$CONTROL" switch module 2>&1); rc=$?
check "Kernel -> Module handoff succeeds" 0 "$rc"
check "Kernel -> Module selects module source" module "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "Kernel -> Module applies module cap again" 2188800 "$(cat "$CPUFREQ/policy3/scaling_max_freq")"
check "Kernel -> Module forces kernel mode None" 0 "$(cat "$KP_PATH")"
check "Kernel -> Module turns auto_kp off" N "$(cat "$AUTO_PATH")"
sh "$KP" mode 3 >/dev/null 2>&1; check "direct kp.sh mode is rejected after Module handoff" 1 "$?"
check "blocked direct kp.sh mode remains None" 0 "$(cat "$KP_PATH")"
out=$(sh "$CONTROL" switch kernel 2>&1); rc=$?
check "repeated Module -> Kernel handoff succeeds" 0 "$rc"
check "second Kernel handoff reuses original stock max" 2803200 "$(cat "$CPUFREQ/policy3/scaling_max_freq")"


# A legacy setup whose Kprofiles node is at the upstream module-parameter path is recognised, not treated as absent.
UP="$T/upstream"; setup_state "$UP"; unset KP_PATH AUTO_PATH
UPP="$UP/root/sys/module/kprofiles/parameters"; mkdir -p "$UPP"; export KP_SYSROOT="$UP/root"
echo 2 > "$UPP/kp_mode"; echo Y > "$UPP/auto_kp"
printf 'ENABLED=0\nSCREENOFF=1\nPRESET=stock\n' > "$CFG_DIR/tune.conf"; printf 'PERSIST=1\nMODE=2\nAUTO=Y\n' > "$CFG_DIR/config"
out=$(sh "$CONTROL" init 2>&1); rc=$?
check "upstream path: legacy kernel-profile setup migrates successfully" 0 "$rc"
check "upstream path: it is recognised as Kernel source, not module-only" kernel "$(sed -n 's/^SOURCE=//p' "$CONTROL_FILE")"
check "upstream path: the kernel preference is saved" 2 "$(sed -n 's/^KP_MODE_PREF=//p' "$CONTROL_FILE")"
check "upstream path: the live mode is neutralized at that node" 0 "$(cat "$UPP/kp_mode")"
check "upstream path: auto_kp is neutralized at that node" N "$(cat "$UPP/auto_kp")"
unset KP_SYSROOT

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
