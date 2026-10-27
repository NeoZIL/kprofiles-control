#!/bin/sh
# Read-only hardware monitor discovery against a fake sysfs/procfs tree.
HERE=$(cd "$(dirname "$0")" && pwd)
MON="$HERE/../module/monitor.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
SYS="$T/sys"; PROC="$T/proc"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

# Three CPUFreq policies with active limits distinct from hardware-supported maxima.
for policy in 0 3 7; do mkdir -p "$SYS/devices/system/cpu/cpufreq/policy$policy"; done
put "$SYS/devices/system/cpu/cpufreq/policy0/related_cpus" '0 1 2'
put "$SYS/devices/system/cpu/cpufreq/policy0/affected_cpus" '0 1 2'
put "$SYS/devices/system/cpu/cpufreq/policy0/scaling_cur_freq" 1017600
put "$SYS/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq" 998400
put "$SYS/devices/system/cpu/cpufreq/policy0/scaling_min_freq" 595200
put "$SYS/devices/system/cpu/cpufreq/policy0/scaling_max_freq" 1017600
put "$SYS/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq" 364800
put "$SYS/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq" 2016000
put "$SYS/devices/system/cpu/cpufreq/policy3/related_cpus" '3 4 5 6'
put "$SYS/devices/system/cpu/cpufreq/policy3/affected_cpus" '3 4 5 6'
put "$SYS/devices/system/cpu/cpufreq/policy3/scaling_cur_freq" 787200
put "$SYS/devices/system/cpu/cpufreq/policy3/scaling_min_freq" 633600
put "$SYS/devices/system/cpu/cpufreq/policy3/scaling_max_freq" 787200
put "$SYS/devices/system/cpu/cpufreq/policy3/cpuinfo_min_freq" 480000
put "$SYS/devices/system/cpu/cpufreq/policy3/cpuinfo_max_freq" 2803200
put "$SYS/devices/system/cpu/cpufreq/policy7/related_cpus" 7
put "$SYS/devices/system/cpu/cpufreq/policy7/affected_cpus" 7
put "$SYS/devices/system/cpu/cpufreq/policy7/scaling_cur_freq" 633600
put "$SYS/devices/system/cpu/cpufreq/policy7/scaling_min_freq" 633600
put "$SYS/devices/system/cpu/cpufreq/policy7/scaling_max_freq" 633600
put "$SYS/devices/system/cpu/cpufreq/policy7/cpuinfo_min_freq" 480000
put "$SYS/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq" 3014400
put "$SYS/devices/system/cpu/online" '0-7'
for n in 0 1 2 3 4 5 6 7; do mkdir -p "$SYS/devices/system/cpu/cpu$n"; put "$SYS/devices/system/cpu/cpu$n/online" 1; done
put "$PROC/stat" 'cpu 1 2 3 4 5 6 7 8 0 0
cpu0 1 2 3 4 5 6 7 8 0 0
cpu1 1 2 3 4 5 6 7 8 0 0
cpu2 1 2 3 4 5 6 7 8 0 0
cpu3 1 2 3 4 5 6 7 8 0 0
cpu4 1 2 3 4 5 6 7 8 0 0
cpu5 1 2 3 4 5 6 7 8 0 0
cpu6 1 2 3 4 5 6 7 8 0 0
cpu7 1 2 3 4 5 6 7 8 0 0'

# Thermal names match the observed Qualcomm CPU-cluster, GPU and battery scheme.
for pair in '0:cpu-0-0-0:33400' '1:cpu-0-1-0:34200' '2:cpu-1-0-0:33400' '3:cpu-1-1-0:33000' '4:cpu-2-0-0:33400' '5:gpuss-0:33400' '6:battery:30600' '7:modem:39000'; do
  id=${pair%%:*}; tail=${pair#*:}; type=${tail%%:*}; temp=${tail#*:}
  mkdir -p "$SYS/class/thermal/thermal_zone$id"
  put "$SYS/class/thermal/thermal_zone$id/type" "$type"
  put "$SYS/class/thermal/thermal_zone$id/temp" "$temp"
done

# GPU devfreq and KGSL expose current range and utilization.
mkdir -p "$SYS/class/devfreq/3d00000.qcom,kgsl-3d0" "$SYS/class/kgsl/kgsl-3d0"
put "$SYS/class/devfreq/3d00000.qcom,kgsl-3d0/name" '3d00000.qcom,kgsl-3d0'
put "$SYS/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq" 684000000
put "$SYS/class/devfreq/3d00000.qcom,kgsl-3d0/min_freq" 255000000
put "$SYS/class/devfreq/3d00000.qcom,kgsl-3d0/max_freq" 736000000
put "$SYS/class/kgsl/kgsl-3d0/gpuclk" 684000000
put "$SYS/class/kgsl/kgsl-3d0/max_gpuclk" 736000000
put "$SYS/class/kgsl/kgsl-3d0/gpu_busy_percentage" '27 %'
put "$SYS/class/kgsl/kgsl-3d0/gpubusy" '277665 1013335'

# Battery uses standard Linux power-supply units (uA, uV, tenths of a degree C, uAh).
mkdir -p "$SYS/class/power_supply/battery"
put "$SYS/class/power_supply/battery/type" Battery
put "$SYS/class/power_supply/battery/status" Discharging
put "$SYS/class/power_supply/battery/capacity" 68
put "$SYS/class/power_supply/battery/current_now" -400000
put "$SYS/class/power_supply/battery/voltage_now" 4084000
put "$SYS/class/power_supply/battery/temp" 306
put "$SYS/class/power_supply/battery/charge_counter" 2891000
put "$SYS/class/power_supply/battery/charge_full" 4425000

MONITOR_SYS_ROOT="$SYS" MONITOR_PROC_ROOT="$PROC" MONITOR_DEVICE=peridot sh "$MON" snapshot > "$T/out"
check "snapshot schema emitted" 1 "$(grep -cx 'schema=1' "$T/out")"
check "device override emitted" 1 "$(grep -cx 'device=peridot' "$T/out")"
check "all three CPU policies found" 3 "$(grep -c '^cpu_policy_[037]_cpus=' "$T/out")"
check "policy active max is distinct from hardware max" 'cpu_policy_0_max_khz=1017600' "$(grep '^cpu_policy_0_max_khz=' "$T/out")"
check "hardware-reported current frequency takes precedence when available" 'cpu_policy_0_cur_khz=998400' "$(grep '^cpu_policy_0_cur_khz=' "$T/out")"
check "hardware max is separately available" 'cpu_policy_0_hwmax_khz=2016000' "$(grep '^cpu_policy_0_hwmax_khz=' "$T/out")"
check "online list exposed" 'cpu_online_list=0-7' "$(grep '^cpu_online_list=' "$T/out")"
check "per-core stat counter exposed" 'stat_cpu7=1 2 3 4 5 6 7 8 0 0' "$(grep '^stat_cpu7=' "$T/out")"
check "CPU thermal sensors exposed" 'thermal_1_type=cpu-0-1-0' "$(grep '^thermal_1_type=' "$T/out")"
check "irrelevant modem thermal sensor filtered" 0 "$(grep -c '^thermal_7_' "$T/out" || true)"
check "GPU current frequency exposed" 'gpu_cur_hz=684000000' "$(grep '^gpu_cur_hz=' "$T/out")"
check "GPU active max exposes policy cap" 'gpu_max_hz=736000000' "$(grep '^gpu_max_hz=' "$T/out")"
check "GPU busy percentage exposed" 'gpu_busy_pct=27 %' "$(grep '^gpu_busy_pct=' "$T/out")"
check "battery capacity exposed" 'battery_capacity=68' "$(grep '^battery_capacity=' "$T/out")"
check "battery temperature unit source exposed" 'battery_temp=306' "$(grep '^battery_temp=' "$T/out")"

MONITOR_SYS_ROOT="$SYS" MONITOR_PROC_ROOT="$PROC" MONITOR_SCREEN_STATE=off sh "$MON" screen > "$T/screen"
check "screen probe accepts confirmed off state" 'screen_state=off' "$(grep '^screen_state=' "$T/screen")"
check "screen probe returns battery readings too" 'battery_charge_counter=2891000' "$(grep '^battery_charge_counter=' "$T/screen")"

# Per-CPU cpufreq fallback works on kernels without policy directories.
SYS2="$T/sys2"; mkdir -p "$SYS2/devices/system/cpu/cpu0/cpufreq" "$SYS2/devices/system/cpu/cpu1/cpufreq" "$SYS2/devices/system/cpu/cpu2/cpufreq"
put "$SYS2/devices/system/cpu/cpu0/cpufreq/related_cpus" '0 1 2'
put "$SYS2/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq" 600000
put "$SYS2/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq" 300000
put "$SYS2/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq" 1800000
put "$SYS2/devices/system/cpu/cpu1/cpufreq/related_cpus" '0 1 2'
put "$SYS2/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq" 600000
put "$SYS2/devices/system/cpu/cpu1/cpufreq/cpuinfo_min_freq" 300000
put "$SYS2/devices/system/cpu/cpu1/cpufreq/cpuinfo_max_freq" 1800000
put "$SYS2/devices/system/cpu/cpu2/cpufreq/related_cpus" '0 1 2'
put "$SYS2/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq" 600000
put "$SYS2/devices/system/cpu/cpu2/cpufreq/cpuinfo_min_freq" 300000
put "$SYS2/devices/system/cpu/cpu2/cpufreq/cpuinfo_max_freq" 1800000
MONITOR_SYS_ROOT="$SYS2" MONITOR_PROC_ROOT="$PROC" MONITOR_DEVICE=test sh "$MON" snapshot > "$T/fallback"
check "per-CPU cpufreq fallback finds a policy" 'cpu_policy_0_cur_khz=600000' "$(grep '^cpu_policy_0_cur_khz=' "$T/fallback")"
check "per-CPU fallback reports shared related CPU list" 'cpu_policy_1_cpus=0 1 2' "$(grep '^cpu_policy_1_cpus=' "$T/fallback")"
check "per-CPU fallback keeps allowed minimum unavailable when only hardware minimum exists" "" "$(grep '^cpu_policy_0_min_khz=' "$T/fallback" || true)"
check "per-CPU fallback still reports hardware minimum separately" 'cpu_policy_0_hwmin_khz=300000' "$(grep '^cpu_policy_0_hwmin_khz=' "$T/fallback")"
check "per-CPU fallback reports hardware maximum separately" 'cpu_policy_0_hwmax_khz=1800000' "$(grep '^cpu_policy_0_hwmax_khz=' "$T/fallback")"

# A GPU bus/bandwidth monitor that sorts before the real GPU node is never reported as the GPU.
G="$T/gpu"; mkdir -p "$G/sys/class/devfreq" "$G/proc"
put "$G/sys/class/devfreq/aaa.qcom,gpubw/name" aaa.qcom,gpubw; put "$G/sys/class/devfreq/aaa.qcom,gpubw/cur_freq" 5000
put "$G/sys/class/devfreq/aaa.qcom,gpubw/max_freq" 100; put "$G/sys/class/devfreq/aaa.qcom,gpubw/governor" bw_vbif
out=$(MONITOR_SYS_ROOT="$G/sys" MONITOR_PROC_ROOT="$G/proc" sh "$MON" snapshot)
check "gpu: only a bandwidth monitor exists: nothing is reported as the GPU" 0 "$(printf '%s\n' "$out" | grep -c '^gpu_')"
put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/name" zzz.qcom,kgsl-3d0; put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/cur_freq" 684000000
put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/max_freq" 736000000; put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/governor" msm-adreno-tz
out=$(MONITOR_SYS_ROOT="$G/sys" MONITOR_PROC_ROOT="$G/proc" sh "$MON" snapshot)
check "gpu: the KGSL node wins over a bandwidth monitor that sorts first" "gpu_name=zzz.qcom,kgsl-3d0" "$(printf '%s\n' "$out" | grep '^gpu_name=')"
check "gpu: its frequency is used" "gpu_cur_hz=684000000" "$(printf '%s\n' "$out" | grep '^gpu_cur_hz=')"
check "gpu: its governor is used, not the bus governor" "gpu_governor=msm-adreno-tz" "$(printf '%s\n' "$out" | grep '^gpu_governor=')"
rm -rf "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0"; put "$G/sys/class/devfreq/mali-gpu/name" mali-gpu; put "$G/sys/class/devfreq/mali-gpu/cur_freq" 500000000
out=$(MONITOR_SYS_ROOT="$G/sys" MONITOR_PROC_ROOT="$G/proc" sh "$MON" snapshot)
check "gpu: another vendor's GPU-named node is still found" "gpu_name=mali-gpu" "$(printf '%s\n' "$out" | grep '^gpu_name=')"
# A KGSL-named interconnect/bus monitor must not win merely because its name contains "kgsl".
rm -rf "$G/sys/class/devfreq"; mkdir -p "$G/sys/class/devfreq/aaa.kgsl-busmon" "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0"
put "$G/sys/class/devfreq/aaa.kgsl-busmon/name" kgsl-busmon; put "$G/sys/class/devfreq/aaa.kgsl-busmon/cur_freq" 5000
put "$G/sys/class/devfreq/aaa.kgsl-busmon/max_freq" 9000; put "$G/sys/class/devfreq/aaa.kgsl-busmon/governor" busmon
put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/name" zzz.qcom,kgsl-3d0; put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/cur_freq" 684000000
put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/max_freq" 736000000; put "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0/governor" msm-adreno-tz
out=$(MONITOR_SYS_ROOT="$G/sys" MONITOR_PROC_ROOT="$G/proc" sh "$MON" snapshot)
check "gpu: kgsl-busmon is skipped in KGSL-preference pass" "gpu_name=zzz.qcom,kgsl-3d0" "$(printf '%s\n' "$out" | grep '^gpu_name=')"
check "gpu: KGSL bus monitor frequency is never used" "gpu_cur_hz=684000000" "$(printf '%s\n' "$out" | grep '^gpu_cur_hz=')"
# When only the misleading bus monitor exists, return unavailable instead of a false GPU reading.
rm -rf "$G/sys/class/devfreq/zzz.qcom,kgsl-3d0"
out=$(MONITOR_SYS_ROOT="$G/sys" MONITOR_PROC_ROOT="$G/proc" sh "$MON" snapshot)
check "gpu: only kgsl-busmon produces no GPU telemetry" 0 "$(printf '%s\n' "$out" | grep -c '^gpu_')"

exit "$fail"
