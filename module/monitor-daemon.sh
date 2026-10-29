#!/system/bin/sh
# Background battery/current-rate collector. It only reads standard power interfaces and writes
# Kprofiles Control's own cache. Unflushed recent samples are memory-only and are conservatively dropped on restart.
set -f
LC_ALL=C
export LC_ALL

MODE=${1:-run}
case "$0" in */*) SELF_DIR=${0%/*} ;; *) SELF_DIR=. ;; esac
MODDIR=${2:-$SELF_DIR}
CACHE="$MODDIR/monitor-cache.sh"
DATA_DIR=${MONITOR_DATA_DIR:-/data/adb/kprofiles_ui}
# The clock and the sampling pause are named explicitly so that tests can supply a fake clock by path.
# A shell that prefers its own built-in applets over PATH (busybox ash on Debian/Ubuntu does) would
# otherwise never run a fake "date" or "sleep" placed in PATH, and the test would use the real clock.
DATE_CMD=${MONITOR_DATE_CMD:-date}
SLEEP_CMD=${MONITOR_SLEEP_CMD:-sleep}
PID_FILE="$DATA_DIR/monitor.pid"
PROC_DIR=${MONITOR_PROC_DIR:-/proc}
# Named explicitly so tests can supply a hooked awk by path (see MONITOR_DATE_CMD above).
AWK_CMD=${MONITOR_AWK_CMD:-awk}
BOOT_ID_FILE=${MONITOR_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
UPTIME_FILE=${MONITOR_UPTIME_FILE:-/proc/uptime}
CLOCK_CMD=${MONITOR_CLOCK_CMD:-}
[ -r "$MODDIR/monitor-current.sh" ] || { echo 'monitor-daemon: missing monitor-current.sh' >&2; exit 1; }
. "$MODDIR/monitor-current.sh" || exit 1
DAEMON_VERSION=unknown
if [ -r "$MODDIR/module.prop" ]; then
  DAEMON_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" | sed -n 's/^version=//p' | head -n 1)
  [ -n "$DAEMON_VERSION" ] || DAEMON_VERSION=unknown
fi

last_screen_sample_t=
last_screen_sample_state=
last_screen_sample_charge=
last_screen_sample_capacity=
last_screen_sample_full=
last_screen_sample_current_ua=
last_screen_sample_valid=0
pending_off_start_t=
pending_off_wall_t=
pending_off_start_charge=
pending_off_start_capacity=
pending_off_start_full=
pending_off_charge_uah=0
pending_off_current_ms=0
screen_off_confirmed=0
idle_session_completed=0
pending_active_charge_uah=0
pending_active_current_ms=0
pending_idle_charge_uah=0
pending_idle_current_ms=0
last_current_flush_t=0
pending_active_time_ms=0
pending_idle_time_ms=0
last_screen_time_flush_t=0
current_capacity_uah=
active_roll_history=
idle_roll_history=
active_roll_charge_uah=0
active_roll_current_ms=0
idle_roll_charge_uah=0
idle_roll_current_ms=0
active_roll_avg_ma=
idle_roll_avg_ma=
last_rate_check_t=

if [ ! -x "$CACHE" ]; then
  [ -f "$CACHE" ] || exit 1
fi

read_settings() {
  _out=$(sh "$CACHE" get 2>/dev/null) || return 1
  monitor_enabled=1; sampling_interval=30; reset_on_charging=1; generation=0; last_charger=unknown
  active_rate=; active_time=; idle_rate=; idle_time=
  while IFS='=' read -r key value; do
    case "$key" in
      monitor_enabled) monitor_enabled=$value ;;
      sampling_interval) sampling_interval=$value ;;
      reset_on_charging) reset_on_charging=$value ;;
      generation) generation=$value ;;
      last_charger) last_charger=$value ;;
      active_rate) active_rate=$value ;;
      active_time) active_time=$value ;;
      idle_rate) idle_rate=$value ;;
    esac
  done <<EOF_CACHE
$_out
EOF_CACHE
  case "$monitor_enabled" in 0|1) ;; *) monitor_enabled=1 ;; esac
  case "$sampling_interval" in 15|30|60) ;; *) sampling_interval=30 ;; esac
  case "$reset_on_charging" in 0|1) ;; *) reset_on_charging=1 ;; esac
  case "$last_charger" in connected|disconnected|unknown) ;; *) last_charger=unknown ;; esac
  case "$generation" in ''|*[!0-9]*) generation=0 ;; esac
  return 0
}

clear_windows() {
  active_start_t=; active_start_charge=; active_start_capacity=; active_start_full=
  idle_start_t=; idle_start_charge=; idle_start_capacity=; idle_start_full=
}

clear_screen_sample() {
  last_screen_sample_t=
  last_screen_sample_state=
  last_screen_sample_charge=
  last_screen_sample_capacity=
  last_screen_sample_full=
  last_screen_sample_current_ua=
  last_screen_sample_valid=0
  pending_off_start_t=
  pending_off_wall_t=
  pending_off_start_charge=
  pending_off_start_capacity=
  pending_off_start_full=
  pending_off_charge_uah=0
  pending_off_current_ms=0
  screen_off_confirmed=0
  idle_session_completed=0
}
clear_drain_tracking() {
  clear_screen_sample
  pending_active_charge_uah=0; pending_active_current_ms=0
  pending_idle_charge_uah=0; pending_idle_current_ms=0
  active_roll_history=; idle_roll_history=
  active_roll_charge_uah=0; active_roll_current_ms=0
  idle_roll_charge_uah=0; idle_roll_current_ms=0
  active_roll_avg_ma=; idle_roll_avg_ma=
  last_current_flush_t=0
  pending_active_time_ms=0; pending_idle_time_ms=0
  last_screen_time_flush_t=0
  last_rate_check_t=
}
read_monotonic_ms() {
  if [ -n "$CLOCK_CMD" ]; then
    _clock_ms=$("$CLOCK_CMD" 2>/dev/null) || return 1
    case "$_clock_ms" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#_clock_ms}" -le 15 ] || return 1
    printf '%s\n' "$_clock_ms"
    return 0
  fi
  [ -r "$UPTIME_FILE" ] || return 1
  _uptime=$(awk 'NR == 1 { print $1; exit }' "$UPTIME_FILE" 2>/dev/null) || return 1
  case "$_uptime" in ''|*[!0-9.]*) return 1 ;; esac
  case "$_uptime" in *.*) _sec=${_uptime%%.*}; _frac=${_uptime#*.} ;; *) _sec=$_uptime; _frac=000 ;; esac
  case "$_sec" in ''|*[!0-9]*) return 1 ;; esac
  case "$_frac" in *.*|*[!0-9]*) return 1 ;; esac
  _frac=$(printf '%s000' "$_frac" | cut -c1-3)
  case "$_frac" in ''|*[!0-9]*) return 1 ;; esac
  # /proc/uptime is boot-based and includes suspend time on Android/Linux; unlike wall time,
  # it cannot jump because the user or network adjusted the clock. No anchors survive a reboot.
  _mono=$((_sec * 1000 + _frac)) 2>/dev/null || return 1
  case "$_mono" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_mono"
}

is_monitor_process() {
  _pid=$1
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "${MONITOR_PROC_DIR:-/proc}/$_pid/cmdline" ] || return 1
  _cmdline=$(tr '\000' ' ' < "${MONITOR_PROC_DIR:-/proc}/$_pid/cmdline" 2>/dev/null)
  case "$_cmdline" in
    *"$MODDIR/monitor-daemon.sh"*run*"$MODDIR"*) return 0 ;;
    *) return 1 ;;
  esac
}

proc_start_time() {
  [ "$#" -eq 1 ] || return 1
  _stat=$(cat "$PROC_DIR/$1/stat" 2>/dev/null) || return 1
  _start=$(printf '%s\n' "$_stat" | "$AWK_CMD" '{ sub(/^.*\) /, ""); if (NF < 20) exit 1; if ($1 == "Z" || $1 == "X") { print "dead"; exit }; print $20; exit }') || return 1
  # A zombie still answers kill -0 but can no longer own a lock.
  case "$_start" in dead) printf 'dead\n'; return 0 ;; esac
  case "$_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_start"
}
current_boot_id() {
  _boot=
  if IFS= read -r _boot 2>/dev/null < "$BOOT_ID_FILE"; then
    case "$_boot" in ''|*[!0-9a-fA-F-]*) printf 'unknown\n' ;; *) printf '%s\n' "$_boot" ;; esac
  else
    printf 'unknown\n'
  fi
}
lock_owner_state() {
  _lock_dir=$1
  _owner=; _owner_start=; _owner_boot=
  [ -r "$_lock_dir/pid" ] || { printf 'unknown\n'; return; }
  IFS= read -r _owner < "$_lock_dir/pid" || { printf 'unknown\n'; return; }
  case "$_owner" in ''|*[!0-9]*) printf 'unknown\n'; return ;; esac
  kill -0 "$_owner" 2>/dev/null || { printf 'stale\n'; return; }
  _owner_start=$(sed -n '2p' "$_lock_dir/pid" 2>/dev/null)
  _owner_boot=$(sed -n '3p' "$_lock_dir/pid" 2>/dev/null)
  case "$_owner_start" in ''|*[!0-9]*) printf 'unknown\n'; return ;; esac
  _actual_start=$(proc_start_time "$_owner") || { printf 'unknown\n'; return; }
  [ "$_actual_start" = "$_owner_start" ] || { printf 'stale\n'; return; }
  _actual_boot=$(current_boot_id)
  if [ "$_owner_boot" != unknown ] && [ "$_actual_boot" != unknown ] && [ "$_owner_boot" != "$_actual_boot" ]; then
    printf 'stale\n'
  else
    printf 'live\n'
  fi
}
write_lock_owner() {
  _self_start=$(proc_start_time "$$") || _self_start=unknown
  _self_boot=$(current_boot_id)
  printf '%s\n%s\n%s\n' "$$" "$_self_start" "$_self_boot" > "$1/pid"
}
pidfile_is_current() {
  [ -f "$PID_FILE" ] || return 1
  _pid=; _version=; _path=
  IFS= read -r _pid < "$PID_FILE"
  _version=$(sed -n '2p' "$PID_FILE" 2>/dev/null)
  _path=$(sed -n '3p' "$PID_FILE" 2>/dev/null)
  [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null || return 1
  is_monitor_process "$_pid" || return 1
  [ "$_version" = "$DAEMON_VERSION" ] && [ "$_path" = "$MODDIR" ]
}

# Remove a lock directory ONLY if it is still abandoned when looked at again under a short guard
# (<lock>.reclaim, taken with mkdir). Deciding "stale" and removing the lock are two steps; without the
# guard a second waiter could decide on an old reading, after another waiter had already reclaimed the lock
# and taken it, and then delete that live lock. Under the guard nobody else can remove the lock, and a lock
# can only be replaced after it is gone, so the second reading is exact. $2 is the state the caller saw.
reclaim_lock() {
  _rc_dir=$1; _rc_want=$2
  mkdir "$_rc_dir.reclaim" 2>/dev/null || return 0     # another waiter is reclaiming right now
  # A lock whose owner never wrote its identity may be a brand-new lock between mkdir and the write:
  # give its creator a moment, then look again.
  if [ "$_rc_want" = unknown ]; then sleep 0.2; fi
  _rc_now=$(lock_owner_state "$_rc_dir")
  if [ "$_rc_now" = stale ] || { [ "$_rc_want" = unknown ] && [ "$_rc_now" = unknown ]; }; then
    rm -f "$_rc_dir/pid"
    rmdir "$_rc_dir" 2>/dev/null || :
  fi
  rmdir "$_rc_dir.reclaim" 2>/dev/null || :
}
# Release the start lock only if this process still owns it (never delete somebody else's lock).
release_start_lock() {
  _rl_owner=
  [ -r "$1/pid" ] && IFS= read -r _rl_owner < "$1/pid"
  [ "$_rl_owner" = "$$" ] || return 0
  rm -f "$1/pid"
  rmdir "$1" 2>/dev/null || :
}

start_detached_daemon() {
  mkdir -p "$DATA_DIR" 2>/dev/null || return 1
  # Detach from the WebUI command session where possible. Some manager shells terminate
  # descendants when their exec callback closes, which would stop sampling with the UI.
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/monitor-daemon.sh" run "$MODDIR" </dev/null >> "$DATA_DIR/monitor.log" 2>&1 &
  else
    nohup sh "$MODDIR/monitor-daemon.sh" run "$MODDIR" </dev/null >> "$DATA_DIR/monitor.log" 2>&1 &
  fi
  _spawned_pid=$!
  _wait=0
  while [ "$_wait" -lt 20 ]; do
    if pidfile_is_current; then return 0; fi
    # A short-lived test daemon may intentionally exit after a fixed sample count.
    if grep -q 'monitor-daemon: started' "$DATA_DIR/monitor.log" 2>/dev/null; then return 0; fi
    if ! kill -0 "$_spawned_pid" 2>/dev/null; then break; fi
    sleep 0.1
    _wait=$((_wait + 1))
  done
  printf 'monitor-daemon: detached start did not become healthy (child %s)\n' "$_spawned_pid" >> "$DATA_DIR/monitor.log"
  return 1
}

record_from_output() {
  screen_state=unknown; battery_status=Unknown; capacity=; charge=; full=; current_ua=; _raw_current=; charger_online=unknown
  while IFS='=' read -r key value; do
    case "$key" in
      screen_state) screen_state=$value ;;
      battery_status) battery_status=$value ;;
      battery_capacity) capacity=$value ;;
      battery_charge_counter) charge=$value ;;
      battery_charge_full) full=$value ;;
      battery_charge_full_design) [ -n "$full" ] || full=$value ;;
      battery_current_now) _raw_current=$value ;;
      charger_online) charger_online=$value ;;
    esac
  done <<EOF_RECORD
$1
EOF_RECORD
  case "$capacity" in ''|*[!0-9]*) capacity= ;; *) [ "$capacity" -le 100 ] 2>/dev/null || capacity= ;; esac
  monitor_valid_counter_uah "$charge" || charge=
  monitor_valid_counter_uah "$full" || full=
  if monitor_valid_current_ua "${_raw_current:-}"; then
    current_ua=$(monitor_normalize_current_ua "$_raw_current") || current_ua=
  fi
  case "$screen_state" in on|off) ;; *) screen_state=unknown ;; esac
  case "$battery_status" in Charging|Discharging|Full|Not\ charging|Unknown) ;; *) battery_status=Unknown ;; esac
  case "$charger_online" in 1|0|unknown) ;; *) charger_online=unknown ;; esac
}

is_charging() {
  case "$charger_online" in
    1) return 0 ;;
    0|unknown) [ "$battery_status" = Charging ] && return 0; return 1 ;;
  esac
  return 1
}

valid_measurement() {
  # Positive rates only: unchanged/quantized battery counters do not become fake 0%/h readings.
  awk -v r="$1" 'BEGIN { if (r ~ /^[0-9]+([.][0-9]+)?$/ && r+0 > 0 && r+0 < 100) exit 0; exit 1 }'
}

compute_rate() {
  _start_t=$1; _start_charge=$2; _start_capacity=$3; _start_full=$4
  _end_t=$5; _end_charge=$6; _end_capacity=$7; _end_full=$8
  _elapsed=$((_end_t - _start_t))
  [ "$_elapsed" -ge 120000 ] || return 1
  _full=$_end_full; [ -n "$_full" ] || _full=$_start_full
  _rate=
  if [ -n "$_start_charge" ] && [ -n "$_end_charge" ] && [ -n "$_full" ] && awk -v f="$_full" 'BEGIN{exit !(f+0>0)}'; then
    _lost=$(awk -v a="$_start_charge" -v b="$_end_charge" 'BEGIN{printf "%.6f", a-b}')
    if awk -v l="$_lost" 'BEGIN{exit !(l+0>0)}'; then
      _rate=$(awk -v l="$_lost" -v f="$_full" -v e="$_elapsed" 'BEGIN{printf "%.6f", (l/f)*100*3600000/e}')
    fi
  fi
  if [ -z "$_rate" ] && [ -n "$_start_capacity" ] && [ -n "$_end_capacity" ]; then
    _drop=$(awk -v a="$_start_capacity" -v b="$_end_capacity" 'BEGIN{printf "%.6f", a-b}')
    if awk -v d="$_drop" 'BEGIN{exit !(d+0>0)}'; then
      _rate=$(awk -v d="$_drop" -v e="$_elapsed" 'BEGIN{printf "%.6f", d*3600000/e}')
    fi
  fi
  valid_measurement "$_rate" || return 1
  printf '%s\n' "$_rate"
}

update_window() {
  _kind=$1; _now=$2
  if [ "$_kind" = active ]; then
    [ -n "$active_start_t" ] || {
      active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
      return 0
    }
    _start_t=$active_start_t; _start_charge=$active_start_charge; _start_capacity=$active_start_capacity; _start_full=$active_start_full
  else
    [ -n "$idle_start_t" ] || {
      idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
      return 0
    }
    _start_t=$idle_start_t; _start_charge=$idle_start_charge; _start_capacity=$idle_start_capacity; _start_full=$idle_start_full
  fi
  # A counter/capacity increase means that a charging event may have occurred between polls.
  # Rebase immediately so a brief, unobserved charging event cannot be averaged into a drain rate.
  if [ -n "$_start_charge" ] && [ -n "$charge" ] && awk -v a="$_start_charge" -v b="$charge" 'BEGIN { exit !(b > a) }'; then
    if [ "$_kind" = active ]; then active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
    else idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
    fi
    return 0
  fi
  if [ -n "$_start_capacity" ] && [ -n "$capacity" ] && awk -v a="$_start_capacity" -v b="$capacity" 'BEGIN { exit !(b > a) }'; then
    if [ "$_kind" = active ]; then active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
    else idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
    fi
    return 0
  fi
  _elapsed=$((_now - _start_t))
  # Percentage-only battery interfaces are quantized to whole percentages. Keep the baseline
  # until a real drop is observable; rebasing every 10 minutes made low idle drain look like a
  # sudden 6%/h drain (or never produce a useful reading). Screen transitions and charging still
  # close the window, and these maximums prevent stale behavior being averaged indefinitely.
  _max_window_ms=5400000
  [ "$_kind" = idle ] && _max_window_ms=43200000
  if [ "$_elapsed" -lt 0 ]; then
    if [ "$_kind" = active ]; then active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
    else idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
    fi
    return 0
  fi
  if _rate=$(compute_rate "$_start_t" "$_start_charge" "$_start_capacity" "$_start_full" "$_now" "$charge" "$capacity" "$full"); then
    # The generation guard prevents an in-flight sample from restoring readings after a reset.
    _cache_error=$(sh "$CACHE" "set-$_kind" "$_rate" "$_now" "$generation" 2>&1)
    _cache_rc=$?
    if [ "$_cache_rc" -ne 0 ] && [ "$_cache_rc" -ne 3 ]; then
      printf 'monitor-daemon: %s drain cache write failed (status %s): %s\n' "$_kind" "$_cache_rc" "$_cache_error" >&2
    fi
    # A good measurement starts the next window here, avoiding repeated use of one large delta.
    if [ "$_kind" = active ]; then active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
    else idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
    fi
    return 0
  fi
  # If the percentage did not move yet, keep the original baseline up to the bounded window.
  # At that limit, start a new window rather than reporting an inaccurate rate from one tick.
  if [ "$_elapsed" -gt "$_max_window_ms" ]; then
    if [ "$_kind" = active ]; then active_start_t=$_now; active_start_charge=$charge; active_start_capacity=$capacity; active_start_full=$full
    else idle_start_t=$_now; idle_start_charge=$charge; idle_start_capacity=$capacity; idle_start_full=$full
    fi
  fi
}

queue_screen_time_amount() {
  [ "$#" -eq 2 ] || return 2
  _time_state=$1; _time_delta=$2
  case "$_time_state" in on|off) ;; *) return 2 ;; esac
  case "$_time_delta" in ''|*[!0-9]*) return 2 ;; esac
  [ "${#_time_delta}" -le 15 ] || return 2
  [ "$_time_delta" -gt 0 ] || return 0
  if [ "$_time_state" = on ]; then
    # Active gaps beyond 120 seconds are not trusted as screen-on time.
    [ "$_time_delta" -le 120000 ] 2>/dev/null || return 0
    pending_active_time_ms=$((pending_active_time_ms + _time_delta))
    [ "${#pending_active_time_ms}" -le 15 ] || { pending_active_time_ms=0; return 2; }
  else
    pending_idle_time_ms=$((pending_idle_time_ms + _time_delta))
    [ "${#pending_idle_time_ms}" -le 15 ] || { pending_idle_time_ms=0; return 2; }
  fi
  return 0
}

# Persist screen-time in batches (30 s, transitions, and idle confirmation), not on each poll.
# Successfully written chunks are removed from the pending amount immediately, so a later write
# failure cannot cause the completed chunks to be counted twice on retry.
flush_screen_time_pending() {
  for _time_state in on off; do
    if [ "$_time_state" = on ]; then _time_remaining=$pending_active_time_ms; _time_max=120000
    else _time_remaining=$pending_idle_time_ms; _time_max=43200000; fi
    case "$_time_remaining" in ''|*[!0-9]*) _time_remaining=0 ;; esac
    while [ "$_time_remaining" -gt 0 ]; do
      _time_part=$_time_remaining
      [ "$_time_part" -le "$_time_max" ] || _time_part=$_time_max
      _time_error=$(sh "$CACHE" add-screen-time "$_time_state" "$_time_part" "$generation" 2>&1)
      _time_rc=$?
      if [ "$_time_rc" -eq 0 ]; then
        _time_remaining=$((_time_remaining - _time_part))
        if [ "$_time_state" = on ]; then pending_active_time_ms=$_time_remaining
        else pending_idle_time_ms=$_time_remaining; fi
      elif [ "$_time_rc" -eq 3 ]; then
        # The cycle was reset concurrently; its generation change makes these old deltas invalid.
        if [ "$_time_state" = on ]; then pending_active_time_ms=0
        else pending_idle_time_ms=0; fi
        break
      else
        printf 'monitor-daemon: screen-time cache write failed (status %s): %s\n' "$_time_rc" "$_time_error" >&2
        # Back off after storage errors instead of retrying a failed write on every fast poll.
        last_screen_time_flush_t=${now_mono_ms:-${last_screen_time_flush_t:-0}}
        return 1
      fi
    done
  done
  last_screen_time_flush_t=${now_mono_ms:-${last_screen_time_flush_t:-0}}
  return 0
}

roll_add() {
  [ "$#" -eq 3 ] || return 1
  _roll_kind=$1; _roll_charge=$2; _roll_ms=$3
  case "$_roll_kind" in active|idle) ;; *) return 2 ;; esac
  monitor_valid_elapsed_ms "$_roll_ms" || return 2
  monitor_add_decimal 0 "$_roll_charge" >/dev/null || return 2
  if [ "$_roll_kind" = active ]; then
    _roll_history=$active_roll_history
  else
    _roll_history=$idle_roll_history
  fi
  if [ -n "$_roll_history" ]; then _roll_history="$_roll_history
${_roll_ms}|${_roll_charge}"; else _roll_history="${_roll_ms}|${_roll_charge}"; fi
  _roll_trimmed=$(printf '%s\n' "$_roll_history" | "$AWK_CMD" -F '|' -v w=300000 '
    NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $1+0 > 0 && $2+0 >= 0 {
      n++; d[n]=$1+0; q[n]=$2+0; total+=d[n]
    }
    END {
      excess=total-w
      for (i=1; i<=n; i++) {
        if (excess > 0) {
          if (d[i] <= excess) { excess-=d[i]; d[i]=0; q[i]=0 }
          else { keep=d[i]-excess; if (d[i] > 0) q[i]=q[i]*keep/d[i]; d[i]=keep; excess=0 }
        }
        if (d[i] > 0) printf "%d|%.6f\n", d[i], q[i]
      }
    }') || return 1
  _roll_totals=$(printf '%s\n' "$_roll_trimmed" | "$AWK_CMD" -F '|' 'NF >= 2 { d += $1; q += $2 } END { printf "%.6f|%.0f", q, d }') || return 1
  _roll_charge=${_roll_totals%%|*}; _roll_duration=${_roll_totals#*|}
  _roll_avg=
  if [ "$_roll_duration" -gt 0 ] 2>/dev/null; then
    _roll_avg=$(monitor_average_current_ma "$_roll_charge" "$_roll_duration") || _roll_avg=
  fi
  if [ "$_roll_kind" = active ]; then
    active_roll_history=$_roll_trimmed; active_roll_charge_uah=$_roll_charge; active_roll_current_ms=$_roll_duration; active_roll_avg_ma=$_roll_avg
  else
    idle_roll_history=$_roll_trimmed; idle_roll_charge_uah=$_roll_charge; idle_roll_current_ms=$_roll_duration; idle_roll_avg_ma=$_roll_avg
  fi
}

queue_current_contribution() {
  [ "$#" -eq 3 ] || return 1
  _queue_kind=$1; _queue_charge=$2; _queue_ms=$3
  case "$_queue_kind" in active|idle) ;; *) return 2 ;; esac
  monitor_valid_elapsed_ms "$_queue_ms" || return 2
  monitor_average_current_ma "$_queue_charge" "$_queue_ms" >/dev/null || return 2
  if [ "$_queue_kind" = active ]; then
    pending_active_charge_uah=$(monitor_add_decimal "$pending_active_charge_uah" "$_queue_charge") || return 2
    pending_active_current_ms=$((pending_active_current_ms + _queue_ms))
  else
    pending_idle_charge_uah=$(monitor_add_decimal "$pending_idle_charge_uah" "$_queue_charge") || return 2
    pending_idle_current_ms=$((pending_idle_current_ms + _queue_ms))
  fi
  roll_add "$_queue_kind" "$_queue_charge" "$_queue_ms" || :
}

flush_current_pending() {
  [ -n "${generation:-}" ] || return 0
  if [ "${pending_active_current_ms:-0}" -gt 0 ] 2>/dev/null; then
    _flush_error=$(sh "$CACHE" add-current active "$pending_active_charge_uah" "$pending_active_current_ms" "${current_capacity_uah:-}" "$generation" 2>&1)
    _flush_rc=$?
    if [ "$_flush_rc" -eq 0 ] || [ "$_flush_rc" -eq 3 ]; then
      pending_active_charge_uah=0; pending_active_current_ms=0
    else
      printf 'monitor-daemon: active current cache write failed (status %s): %s\n' "$_flush_rc" "$_flush_error" >&2
    fi
  fi
  if [ "${pending_idle_current_ms:-0}" -gt 0 ] 2>/dev/null; then
    _flush_error=$(sh "$CACHE" add-current idle "$pending_idle_charge_uah" "$pending_idle_current_ms" "${current_capacity_uah:-}" "$generation" 2>&1)
    _flush_rc=$?
    if [ "$_flush_rc" -eq 0 ] || [ "$_flush_rc" -eq 3 ]; then
      pending_idle_charge_uah=0; pending_idle_current_ms=0
    else
      printf 'monitor-daemon: idle current cache write failed (status %s): %s\n' "$_flush_rc" "$_flush_error" >&2
    fi
  fi
  last_current_flush_t=${now_mono_ms:-${last_current_flush_t:-0}}
}

calculate_interval_contribution() {
  # Arguments describe the previous and current sample. Never attribute an interval that crosses
  # a display-state boundary to either side: even a charge-counter delta would blend ON and OFF
  # consumption. Counter fallback is reserved for long gaps wholly inside one confirmed state.
  _ci_old_state=$1; _ci_new_state=$2; _ci_start_t=$3; _ci_start_i=$4; _ci_start_charge=$5; _ci_start_full=$6
  _ci_end_t=$7; _ci_end_i=$8; _ci_end_charge=$9; _ci_end_full=${10}
  contribution_charge_uah=; contribution_ms=0
  case "$_ci_old_state" in
    on) _ci_current_gap=5000; _ci_counter_min_gap=30000; _ci_counter_gap=5400000 ;;
    off) _ci_current_gap=15000; _ci_counter_min_gap=120000; _ci_counter_gap=43200000 ;;
    *) return 1 ;;
  esac
  case "$_ci_start_t:$_ci_end_t" in *[!0-9:]*) return 1 ;; esac
  [ "$_ci_old_state" = "$_ci_new_state" ] || return 1
  _ci_elapsed=$((_ci_end_t - _ci_start_t))
  [ "$_ci_elapsed" -gt 0 ] && [ "$_ci_elapsed" -le "$_ci_counter_gap" ] || return 1
  if [ -n "$_ci_start_i" ] && [ -n "$_ci_end_i" ] && [ "$_ci_elapsed" -le "$_ci_current_gap" ]; then
    contribution_charge_uah=$(monitor_integrate_current_uah "$_ci_start_i" "$_ci_end_i" "$_ci_elapsed") || contribution_charge_uah=
  fi
  # Charge counters are too quantized for safe mA estimates over 1–15 second polls. Use them
  # only for longer same-state gaps, and never to assign a mixed ON/OFF interval to one bucket.
  if [ -z "$contribution_charge_uah" ] && [ "$_ci_elapsed" -ge "$_ci_counter_min_gap" ] && [ -n "$_ci_start_charge" ] && [ -n "$_ci_end_charge" ]; then
    _ci_cap=$_ci_end_full; [ -n "$_ci_cap" ] || _ci_cap=$_ci_start_full
    contribution_charge_uah=$(monitor_counter_loss_uah "$_ci_start_charge" "$_ci_end_charge" "$_ci_elapsed" "${_ci_cap:-}") || contribution_charge_uah=
  fi
  [ -n "$contribution_charge_uah" ] || return 1
  monitor_average_current_ma "$contribution_charge_uah" "$_ci_elapsed" >/dev/null || { contribution_charge_uah=; return 1; }
  contribution_ms=$_ci_elapsed
  return 0
}

queue_previous_interval() {
  [ "$last_screen_sample_valid" = 1 ] || return 0
  calculate_interval_contribution "$last_screen_sample_state" "$1" "$last_screen_sample_t" \
    "$last_screen_sample_current_ua" "$last_screen_sample_charge" "$last_screen_sample_full" \
    "$now_mono_ms" "$current_ua" "$charge" "$full" || return 0
  case "$last_screen_sample_state" in
    on)
      queue_current_contribution active "$contribution_charge_uah" "$contribution_ms" || :
      ;;
    off)
      if [ "$screen_off_confirmed" = 1 ]; then
        queue_current_contribution idle "$contribution_charge_uah" "$contribution_ms" || :
      else
        pending_off_charge_uah=$(monitor_add_decimal "$pending_off_charge_uah" "$contribution_charge_uah") || pending_off_charge_uah=0
        pending_off_current_ms=$((pending_off_current_ms + contribution_ms))
      fi
      ;;
  esac
}

confirm_pending_idle() {
  [ "$screen_off_confirmed" = 1 ] && return 0
  [ -n "$pending_off_start_t" ] || return 1
  _confirm_span=$((now_mono_ms - pending_off_start_t))
  [ "$_confirm_span" -ge 10000 ] || return 1
  screen_off_confirmed=1
  queue_screen_time_amount off "$_confirm_span" || :
  flush_screen_time_pending || :
  if [ "$pending_off_current_ms" -gt 0 ] 2>/dev/null; then
    queue_current_contribution idle "$pending_off_charge_uah" "$pending_off_current_ms" || :
  fi
  pending_off_charge_uah=0; pending_off_current_ms=0
  # Legacy percentage-rate estimate is kept as a secondary metric, but only after the 10 s
  # candidate qualifies. Its baseline begins at the original observed OFF timestamp.
  if [ -z "$idle_start_t" ]; then
    idle_start_t=$pending_off_wall_t
    idle_start_charge=$pending_off_start_charge
    idle_start_capacity=$pending_off_start_capacity
    idle_start_full=$pending_off_start_full
  fi
  flush_current_pending
  return 0
}

record_drain_state() {
  idle_session_completed=0
  current_capacity_uah=$full
  on_battery=0
  if [ "$battery_status" = Discharging ] || [ "$charger_online" = 0 ]; then on_battery=1; fi
  if [ "$monitor_enabled" != 1 ] || [ "$charger_now" = connected ] || [ "$on_battery" != 1 ]; then
    flush_current_pending
    flush_screen_time_pending || :
    clear_screen_sample
    return 0
  fi
  case "$screen_state" in on|off) ;; *)
    flush_current_pending
    flush_screen_time_pending || :
    clear_screen_sample
    return 0
    ;;
  esac

  if [ "$last_screen_sample_valid" = 1 ]; then
    _state_delta=$((now_mono_ms - last_screen_sample_t))
    if [ "$_state_delta" -lt 0 ]; then
      # Monotonic time reset/corruption: rebase instead of creating negative/huge durations.
      flush_current_pending
      flush_screen_time_pending || :
      clear_screen_sample
      if [ "$screen_state" = off ]; then
        pending_off_start_t=$now_mono_ms; pending_off_wall_t=$now
        pending_off_start_charge=$charge; pending_off_start_capacity=$capacity; pending_off_start_full=$full
      fi
    elif [ "$last_screen_sample_state" = on ]; then
      queue_screen_time_amount on "$_state_delta" || :
      queue_previous_interval "$screen_state"
      if [ "$screen_state" = off ]; then
        # Close the active measurement window at the observed transition; a cross-state current
        # pair is never trapezoid-integrated into either class.
        flush_current_pending
        flush_screen_time_pending || :
        pending_off_start_t=$now_mono_ms
        pending_off_wall_t=$now
        pending_off_start_charge=$charge
        pending_off_start_capacity=$capacity
        pending_off_start_full=$full
        pending_off_charge_uah=0; pending_off_current_ms=0
        screen_off_confirmed=0
        idle_start_t=; idle_start_charge=; idle_start_capacity=; idle_start_full=
      fi
    elif [ "$last_screen_sample_state" = off ]; then
      queue_previous_interval "$screen_state"
      if [ "$screen_off_confirmed" = 1 ]; then
        [ "$_state_delta" -gt 0 ] && queue_screen_time_amount off "$_state_delta" || :
      fi
      if [ "$screen_state" = on ]; then
        if [ "$screen_off_confirmed" != 1 ]; then confirm_pending_idle || :; fi
        if [ "$screen_off_confirmed" = 1 ]; then
          idle_session_completed=1
          flush_current_pending
          flush_screen_time_pending || :
        else
          # The entire under-10-second candidate, including any buffered current charge, is rejected.
          pending_off_charge_uah=0; pending_off_current_ms=0
          idle_start_t=; idle_start_charge=; idle_start_capacity=; idle_start_full=
        fi
        pending_off_start_t=; pending_off_wall_t=; pending_off_start_charge=; pending_off_start_capacity=; pending_off_start_full=
        screen_off_confirmed=0
      else
        if [ "$screen_off_confirmed" != 1 ]; then confirm_pending_idle || :; fi
      fi
    else
      clear_screen_sample
    fi
  else
    if [ "$screen_state" = off ]; then
      pending_off_start_t=$now_mono_ms
      pending_off_wall_t=$now
      pending_off_start_charge=$charge
      pending_off_start_capacity=$capacity
      pending_off_start_full=$full
      pending_off_charge_uah=0; pending_off_current_ms=0
      screen_off_confirmed=0
    fi
  fi

  last_screen_sample_t=$now_mono_ms
  last_screen_sample_state=$screen_state
  last_screen_sample_charge=$charge
  last_screen_sample_capacity=$capacity
  last_screen_sample_full=$full
  last_screen_sample_current_ua=$current_ua
  last_screen_sample_valid=1

  _flush_elapsed=$((now_mono_ms - last_current_flush_t))
  if [ "$last_current_flush_t" -eq 0 ] 2>/dev/null || [ "$_flush_elapsed" -ge 30000 ]; then flush_current_pending; fi
  _screen_time_flush_elapsed=$((now_mono_ms - last_screen_time_flush_t))
  if [ "$last_screen_time_flush_t" -eq 0 ] 2>/dev/null || [ "$_screen_time_flush_elapsed" -ge 30000 ]; then flush_screen_time_pending || :; fi
}

sample_once() {
  read_settings || return 1
  if [ "$generation" != "$seen_generation" ]; then
    clear_windows
    clear_drain_tracking
    seen_generation=$generation
  fi
  _out=$(sh "$MODDIR/monitor.sh" screen 2>/dev/null) || _out='screen_state=unknown'
  record_from_output "$_out"
  now_s=$("$DATE_CMD" +%s 2>/dev/null)
  case "$now_s" in ''|*[!0-9]*) return 1 ;; esac
  now="${now_s}000"
  now_mono_ms=$(read_monotonic_ms) || { printf 'monitor-daemon: monotonic clock unavailable; skipping sample\n' >&2; return 1; }

  if is_charging; then charger_now=connected; else charger_now=disconnected; fi
  if [ "$charger_now" != "$last_charger" ]; then
    if [ "$charger_now" = connected ]; then
      if [ "$reset_on_charging" = 1 ]; then
        sh "$CACHE" reset-data >/dev/null 2>&1 || :
      else
        # The preference controls legacy %/h history only. New cycle-wide current averages and
        # both screen-time totals always reset at plug-in, as the drain cycle has ended.
        sh "$CACHE" reset-cycle keep-rates >/dev/null 2>&1 || :
      fi
      clear_windows
      read_settings || return 1
      seen_generation=$generation
      clear_drain_tracking
    else
      # A new discharge cycle starts from empty current totals left by the plug-in boundary.
      clear_windows
      clear_drain_tracking
    fi
    sh "$CACHE" set-charger-state "$charger_now" >/dev/null 2>&1 || :
    last_charger=$charger_now
  fi

  previous_screen_state=$last_screen_sample_state
  record_drain_state

  if [ "$charger_now" = connected ] || [ "$monitor_enabled" != 1 ] || [ "$battery_status" != Discharging ]; then
    clear_windows
    return 0
  fi

  # The UI preference controls how often the older battery-counter %/h estimator is checked.
  # Current integration itself uses the lower-latency 1 s screen-ON / 5 s screen-OFF cadence.
  rate_due=0
  if [ -z "$last_rate_check_t" ]; then rate_due=1
  else
    rate_elapsed=$((now - last_rate_check_t))
    [ "$rate_elapsed" -ge "$((sampling_interval * 1000))" ] && rate_due=1
  fi
  if [ "$previous_screen_state" != "$screen_state" ]; then rate_due=1; fi
  [ "$rate_due" -eq 1 ] && last_rate_check_t=$now

  case "$screen_state" in
    on)
      if [ "$previous_screen_state" = off ] && [ "$idle_session_completed" = 1 ] && [ -n "$idle_start_t" ]; then
        update_window idle "$now"
      fi
      if [ "$previous_screen_state" = off ]; then
        idle_start_t=; idle_start_charge=; idle_start_capacity=; idle_start_full=
      fi
      [ "$rate_due" -eq 1 ] && update_window active "$now"
      ;;
    off)
      active_start_t=; active_start_charge=; active_start_capacity=; active_start_full=
      if [ "$screen_off_confirmed" = 1 ] && [ "$rate_due" -eq 1 ]; then update_window idle "$now"; fi
      ;;
    *) clear_windows ;;
  esac
}

case "$MODE" in
  once)
    sample_once
    _once_rc=$?
    flush_current_pending
    flush_screen_time_pending
    exit "$_once_rc"
    ;;
  ensure)
    mkdir -p "$DATA_DIR" 2>/dev/null || exit 1
    if pidfile_is_current; then exit 0; fi
    _lock="$DATA_DIR/monitor-start.lock"
    _tries=0
    while ! mkdir "$_lock" 2>/dev/null; do
      _state=$(lock_owner_state "$_lock")
      # A reclaim guard still present after 1.5 seconds was left by a reclaimer that died. Clear it whether the
      # lock looks stale or unidentified, or no reclaim could ever succeed (the guard survives a reboot).
      if [ "$_tries" -eq 15 ] && [ "$_state" != live ]; then rmdir "$_lock.reclaim" 2>/dev/null || :; fi
      case "$_state" in
        stale) reclaim_lock "$_lock" stale ;;
        unknown)
          # Legacy/incomplete locks have no trustworthy owner identity. Allow about 2 seconds for a
          # starter to write metadata; verified live owners are never evicted just for running slowly.
          if [ "$_tries" -eq 20 ]; then reclaim_lock "$_lock" unknown; fi
          ;;
        live) ;;
      esac
      _tries=$((_tries + 1))
      if [ "$_tries" -ge 30 ]; then exit 1; fi
      sleep 0.1
      if pidfile_is_current; then exit 0; fi
    done
    write_lock_owner "$_lock" || { release_start_lock "$_lock"; exit 1; }
    if ! pidfile_is_current; then start_detached_daemon || { release_start_lock "$_lock"; exit 1; }; fi
    release_start_lock "$_lock"
    exit 0
    ;;
  stop)
    old_pid=
    [ -r "$PID_FILE" ] && IFS= read -r old_pid < "$PID_FILE"
    case "$old_pid" in ''|*[!0-9]*) rm -f "$PID_FILE"; exit 0 ;; esac
    if ! is_monitor_process "$old_pid"; then rm -f "$PID_FILE"; exit 0; fi
    [ "$old_pid" != "$$" ] || exit 0
    kill -TERM "$old_pid" 2>/dev/null || exit 0
    _wait=0
    while [ "$_wait" -lt 5 ] && kill -0 "$old_pid" 2>/dev/null && is_monitor_process "$old_pid"; do sleep 1; _wait=$((_wait + 1)); done
    kill -0 "$old_pid" 2>/dev/null && is_monitor_process "$old_pid" && kill -KILL "$old_pid" 2>/dev/null || :
    exit 0
    ;;
  run)
    mkdir -p "$DATA_DIR" 2>/dev/null || exit 1
    if [ -f "$PID_FILE" ]; then
      old_pid=; old_version=; old_path=
      IFS= read -r old_pid < "$PID_FILE"
      old_version=$(sed -n '2p' "$PID_FILE" 2>/dev/null)
      old_path=$(sed -n '3p' "$PID_FILE" 2>/dev/null)
      case "$old_pid" in ''|*[!0-9]*) old_pid= ;; esac
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && [ "$old_pid" != "$$" ] && is_monitor_process "$old_pid"; then
        if [ "$old_version" = "$DAEMON_VERSION" ] && [ "$old_path" = "$MODDIR" ]; then exit 0; fi
        kill -TERM "$old_pid" 2>/dev/null || :
        _wait=0
        while [ "$_wait" -lt 5 ] && kill -0 "$old_pid" 2>/dev/null && is_monitor_process "$old_pid"; do sleep 1; _wait=$((_wait + 1)); done
        kill -0 "$old_pid" 2>/dev/null && is_monitor_process "$old_pid" && kill -KILL "$old_pid" 2>/dev/null || :
      fi
      # PID may be stale or reused by an unrelated process after reboot. Never signal such a process.
      rm -f "$PID_FILE"
    fi
    _pid_tmp="$PID_FILE.tmp.$$"
    printf '%s\n%s\n%s\n' "$$" "$DAEMON_VERSION" "$MODDIR" > "$_pid_tmp" || exit 1
    chmod 600 "$_pid_tmp" 2>/dev/null || { rm -f "$_pid_tmp"; exit 1; }
    mv -f "$_pid_tmp" "$PID_FILE" || { rm -f "$_pid_tmp"; exit 1; }
    trap 'flush_current_pending; flush_screen_time_pending; rm -f "$PID_FILE"; exit 0' HUP INT TERM
    trap 'flush_current_pending; flush_screen_time_pending; rm -f "$PID_FILE"' EXIT
    max_samples=${MONITOR_DAEMON_MAX_SAMPLES:-0}
    case "$max_samples" in ''|*[!0-9]*) max_samples=0 ;; esac
    sample_count=0
    clear_windows
    clear_drain_tracking
    seen_generation=
    read_settings || exit 1
    seen_generation=$generation
    printf '%s\n' "monitor-daemon: started (active current samples every 1s; idle current samples every 5s)"
    while :; do
      # Stop if the module is disabled or its files have been removed during uninstall/update.
      CURRENT_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" 2>/dev/null | sed -n 's/^version=//p' | head -n 1)
      if [ ! -f "$MODDIR/module.prop" ] || [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ "$CURRENT_VERSION" != "$DAEMON_VERSION" ]; then exit 0; fi
      sample_once || :
      sample_count=$((sample_count + 1))
      if [ "$max_samples" -gt 0 ] && [ "$sample_count" -ge "$max_samples" ]; then exit 0; fi
      read_settings || { "$SLEEP_CMD" 60; continue; }
      if [ "$monitor_enabled" = 1 ] && [ "$screen_state" = on ] && [ "$charger_online" != 1 ] && [ "$battery_status" = Discharging ]; then
        sleep_for=${MONITOR_ACTIVE_SAMPLE_SECONDS:-1}
      elif [ "$monitor_enabled" = 1 ] && [ "$screen_state" = off ] && [ "$charger_online" != 1 ] && [ "$battery_status" = Discharging ]; then
        sleep_for=${MONITOR_IDLE_SAMPLE_SECONDS:-5}
      else
        sleep_for=60
      fi
      case "$sleep_for" in ''|*[!0-9]*|0) sleep_for=1 ;; esac
      "$SLEEP_CMD" "$sleep_for"
    done
    ;;
  *)
    echo 'usage: monitor-daemon.sh run|once|ensure|stop [MODULE_DIR]' >&2
    exit 2
    ;;
esac
