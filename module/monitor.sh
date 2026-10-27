#!/system/bin/sh
# Read-only hardware telemetry for the WebUI. No writes to sysfs/procfs or settings.
# Optional roots/device/screen overrides are used by off-device tests only.
LC_ALL=C
export LC_ALL
SYS_ROOT=${MONITOR_SYS_ROOT:-/sys}
PROC_ROOT=${MONITOR_PROC_ROOT:-/proc}
MODE=${1:-snapshot}
VALUE=

read_value() {
  VALUE=
  [ -r "$1" ] || return 1
  IFS= read -r VALUE < "$1" 2>/dev/null || [ -n "$VALUE" ]
}
emit_file() {
  if read_value "$2"; then printf '%s=%s\n' "$1" "$VALUE"; fi
}
emit_policy() {
  p=$1
  id=$2
  related=$3
  [ -n "$related" ] && printf 'cpu_policy_%s_cpus=%s\n' "$id" "$related"
  if read_value "$p/affected_cpus"; then printf 'cpu_policy_%s_affected_cpus=%s\n' "$id" "$VALUE"; fi
  # Prefer the hardware-reported current frequency when the driver exposes it;
  # scaling_cur_freq can be the last requested value on some drivers.
  if read_value "$p/cpuinfo_cur_freq"; then
    printf 'cpu_policy_%s_cur_khz=%s\n' "$id" "$VALUE"
  elif read_value "$p/scaling_cur_freq"; then
    printf 'cpu_policy_%s_cur_khz=%s\n' "$id" "$VALUE"
  fi
  for pair in 'min_khz:scaling_min_freq' 'max_khz:scaling_max_freq' 'hwmin_khz:cpuinfo_min_freq' 'hwmax_khz:cpuinfo_max_freq'; do
    key=${pair%%:*}; file=${pair#*:}
    if read_value "$p/$file"; then
      printf 'cpu_policy_%s_%s=%s\n' "$id" "$key" "$VALUE"
    fi
  done
}

battery_fields() {
  BATT_DIR=
  for d in "$SYS_ROOT"/class/power_supply/*; do
    [ -d "$d" ] || continue
    BTYPE=
    read_value "$d/type" && BTYPE=$VALUE
    case "$BTYPE" in [Bb]attery) BATT_DIR=$d; break ;; esac
    [ "${d##*/}" = battery ] && BATT_DIR=$d
  done
  [ -n "$BATT_DIR" ] || return 0
  for a in status capacity current_now current_avg voltage_now power_now temp charge_counter charge_full charge_full_design energy_now energy_full time_to_empty_now time_to_full_now; do
    emit_file "battery_$a" "$BATT_DIR/$a"
  done
}

screen_state() {
  # Called only on visibility transitions, not during each live refresh.
  if [ -n "${MONITOR_SCREEN_STATE:-}" ]; then
    printf 'screen_state=%s\n' "$MONITOR_SCREEN_STATE"
    battery_fields
    return
  fi
  state=unknown
  if command -v dumpsys >/dev/null 2>&1; then
    pdump=$(dumpsys power 2>/dev/null)
    case "$pdump" in
      *mWakefulness=Asleep*|*mWakefulness=Dozing*|*mInteractive=false*|*"Display Power: state=OFF"*) state=off ;;
      *mWakefulness=Awake*|*mInteractive=true*|*"Display Power: state=ON"*) state=on ;;
    esac
  fi
  printf 'screen_state=%s\n' "$state"
  battery_fields
}

if [ "$MODE" = screen ]; then
  screen_state
  exit 0
fi

printf 'schema=1\n'
device=${MONITOR_DEVICE:-}
if [ -z "$device" ] && command -v getprop >/dev/null 2>&1; then device=$(getprop ro.product.device 2>/dev/null); fi
case "$device" in *[!A-Za-z0-9._-]*|'') device=unknown ;; esac
printf 'device=%s\n' "$device"

# CPUFreq policies are discovered at runtime; policy numbers and cluster sizes are not assumed.
policy_found=0
for p in "$SYS_ROOT"/devices/system/cpu/cpufreq/policy[0-9]*; do
  [ -d "$p" ] || continue
  id=${p##*policy}
  related=
  if read_value "$p/related_cpus"; then related=$VALUE; elif read_value "$p/affected_cpus"; then related=$VALUE; fi
  emit_policy "$p" "$id" "$related"
  policy_found=1
done
# Some kernels expose per-CPU cpufreq directories but no policy directories.
if [ "$policy_found" -eq 0 ]; then
  for c in "$SYS_ROOT"/devices/system/cpu/cpu[0-9]*; do
    [ -d "$c" ] || continue
    id=${c##*cpu}
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ -d "$c/cpufreq" ] || continue
    related=$id
    if read_value "$c/cpufreq/related_cpus"; then related=$VALUE
    elif read_value "$c/cpufreq/affected_cpus"; then related=$VALUE
    fi
    emit_policy "$c/cpufreq" "$id" "$related"
  done
fi

# Global online list is compact; per-core flags are supplied as fallback.
emit_file cpu_online_list "$SYS_ROOT/devices/system/cpu/online"
for c in "$SYS_ROOT"/devices/system/cpu/cpu[0-9]*; do
  [ -d "$c" ] || continue
  id=${c##*cpu}
  case "$id" in ''|*[!0-9]*) continue ;; esac
  if read_value "$c/online"; then
    printf 'cpu%s_online=%s\n' "$id" "$VALUE"
  elif [ "$id" = 0 ]; then
    printf 'cpu0_online=1\n'
  fi
done

# One /proc/stat sample; the WebUI computes utilization from successive samples.
if [ -r "$PROC_ROOT/stat" ]; then
  while IFS= read -r line; do
    case "$line" in
      cpu[0-9]*\ *) id=${line%% *}; id=${id#cpu}; printf 'stat_cpu%s=%s\n' "$id" "${line#* }" ;;
    esac
  done < "$PROC_ROOT/stat"
fi

# Export only likely CPU/GPU/SoC/battery thermal zones, avoiding irrelevant modem/radio sensors per poll.
for z in "$SYS_ROOT"/class/thermal/thermal_zone[0-9]*; do
  [ -d "$z" ] || continue
  id=${z##*thermal_zone}
  read_value "$z/type" || continue
  type=$VALUE
  case "$type" in
    *cpu*|*CPU*|*gpu*|*GPU*|*battery*|*Battery*|*soc*|*SOC*) ;;
    *) continue ;;
  esac
  if read_value "$z/temp"; then
    printf 'thermal_%s_type=%s\n' "$id" "$type"
    printf 'thermal_%s_raw=%s\n' "$id" "$VALUE"
  fi
done

# hwmon is a secondary standard source; labels are driver-dependent.
for h in "$SYS_ROOT"/class/hwmon/hwmon[0-9]*; do
  [ -d "$h" ] || continue
  read_value "$h/name" || continue
  hname=$VALUE
  case "$hname" in *cpu*|*CPU*|*soc*|*SoC*|*gpu*|*GPU*|*thermal*|*Thermal*|*battery*|*Battery*) ;; *) continue ;; esac
  hid=${h##*hwmon}
  printf 'hwmon_%s_name=%s\n' "$hid" "$hname"
  for f in "$h"/temp[0-9]*_input; do
    [ -r "$f" ] || continue
    base=${f##*/}; num=${base#temp}; num=${num%_input}
    if read_value "$f"; then printf 'hwmon_%s_temp_%s_raw=%s\n' "$hid" "$num" "$VALUE"; fi
    if read_value "${f%_input}_label"; then printf 'hwmon_%s_temp_%s_label=%s\n' "$hid" "$num" "$VALUE"; fi
  done
done

# Prefer a GPU devfreq policy; use KGSL's direct values when present.
GPU_CUR='' GPU_MIN='' GPU_MAX='' GPU_NAME='' GPU_GOV='' GPU_BUSY='' GPU_BUSY_COUNTERS='' GPU_BUSY_TIME='' GPU_TOTAL_TIME=''
# KGSL's own devfreq node wins. Otherwise any other GPU-named node is used, but never a bus/bandwidth
# monitor (for example "gpubw"), which is not the GPU clock and can sort before the real node.
for pass in kgsl gpu; do
  for d in "$SYS_ROOT"/class/devfreq/*; do
    [ -d "$d" ] || continue
    dname=${d##*/}
    if read_value "$d/name"; then dname=$VALUE; fi
    # Exclude interconnect/bandwidth devices before the KGSL preference check too:
    # some drivers name their bus monitor "kgsl-busmon", which contains "kgsl" but
    # is not the graphics clock domain. Match common spellings case-insensitively.
    case "$dname" in
      *[bB][wW]*|*[bB][aA][nN][dD][wW][iI][dD][tT][hH]*|*[bB][uU][sS]*|*[lL][lL][cC][cC]*|*[dD][dD][rR]*) continue ;;
    esac
    case "$pass:$dname" in
      kgsl:*kgsl*|kgsl:*KGSL*) ;;
      gpu:*gpu*|gpu:*GPU*) ;;
      *) continue ;;
    esac
    GPU_NAME=$dname
    read_value "$d/cur_freq" && GPU_CUR=$VALUE
    read_value "$d/min_freq" && GPU_MIN=$VALUE
    read_value "$d/max_freq" && GPU_MAX=$VALUE
    read_value "$d/governor" && GPU_GOV=$VALUE
    read_value "$d/busy_time" && GPU_BUSY_TIME=$VALUE
    read_value "$d/total_time" && GPU_TOTAL_TIME=$VALUE
    break
  done
  [ -z "$GPU_NAME" ] || break
done
KGSL="$SYS_ROOT/class/kgsl/kgsl-3d0"
read_value "$KGSL/gpuclk" && GPU_CUR=$VALUE
read_value "$KGSL/min_gpuclk" && GPU_MIN=$VALUE
read_value "$KGSL/max_gpuclk" && GPU_MAX=$VALUE
read_value "$KGSL/gpu_busy_percentage" && GPU_BUSY=$VALUE
read_value "$KGSL/gpubusy" && GPU_BUSY_COUNTERS=$VALUE
if [ -z "$GPU_NAME" ] && [ -d "$KGSL" ]; then GPU_NAME=kgsl-3d0; fi
[ -n "$GPU_CUR" ] && printf 'gpu_cur_hz=%s\n' "$GPU_CUR"
[ -n "$GPU_MIN" ] && printf 'gpu_min_hz=%s\n' "$GPU_MIN"
[ -n "$GPU_MAX" ] && printf 'gpu_max_hz=%s\n' "$GPU_MAX"
[ -n "$GPU_NAME" ] && printf 'gpu_name=%s\n' "$GPU_NAME"
[ -n "$GPU_GOV" ] && printf 'gpu_governor=%s\n' "$GPU_GOV"
[ -n "$GPU_BUSY" ] && printf 'gpu_busy_pct=%s\n' "$GPU_BUSY"
[ -n "$GPU_BUSY_COUNTERS" ] && printf 'gpu_busy_counters=%s\n' "$GPU_BUSY_COUNTERS"
[ -n "$GPU_BUSY_TIME" ] && printf 'gpu_busy_time=%s\n' "$GPU_BUSY_TIME"
[ -n "$GPU_TOTAL_TIME" ] && printf 'gpu_total_time=%s\n' "$GPU_TOTAL_TIME"

battery_fields
printf 'sample_end=1\n'
