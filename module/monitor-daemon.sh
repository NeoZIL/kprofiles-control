#!/system/bin/sh
# Background battery-rate collector. It only reads standard power/thermal interfaces and writes
# Kprofiles Control's own cache. Pending windows live in memory and are discarded on restart.
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
DAEMON_VERSION=unknown
if [ -r "$MODDIR/module.prop" ]; then
  DAEMON_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" | sed -n 's/^version=//p' | head -n 1)
  [ -n "$DAEMON_VERSION" ] || DAEMON_VERSION=unknown
fi

last_screen_sample_t=
last_screen_sample_state=
last_screen_sample_charge=
last_screen_sample_capacity=
last_screen_sample_valid=0

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
  last_screen_sample_valid=0
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
  screen_state=unknown; battery_status=Unknown; capacity=; charge=; full=; charger_online=unknown
  while IFS='=' read -r key value; do
    case "$key" in
      screen_state) screen_state=$value ;;
      battery_status) battery_status=$value ;;
      battery_capacity) capacity=$value ;;
      battery_charge_counter) charge=$value ;;
      battery_charge_full) full=$value ;;
      battery_charge_full_design) [ -n "$full" ] || full=$value ;;
      charger_online) charger_online=$value ;;
    esac
  done <<EOF_RECORD
$1
EOF_RECORD
  case "$capacity" in ''|*[!0-9.]*) capacity= ;; esac
  case "$charge" in ''|*[!0-9.-]*) charge= ;; esac
  case "$full" in ''|*[!0-9.-]*) full= ;; esac
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

record_screen_time() {
  # Use the previous confirmed screen state for the interval. When waking after a long idle,
  # the interval since the last OFF sample was overwhelmingly screen-off; counting it as OFF
  # prevents the totals from freezing at the last WebUI session. ON intervals stay tightly bounded.
  on_battery=0
  if [ "$battery_status" = Discharging ]; then
    on_battery=1
  elif [ "$charger_online" = 0 ]; then
    on_battery=1
  fi
  if [ "$monitor_enabled" != 1 ] || [ "$charger_now" = connected ] || [ "$on_battery" != 1 ]; then
    clear_screen_sample
    return 0
  fi
  case "$screen_state" in on|off) ;; *) clear_screen_sample; return 0 ;; esac

  if [ "$last_screen_sample_valid" = 1 ]; then
    _elapsed_ms=$((now - last_screen_sample_t))
    if [ "$last_screen_sample_state" = on ]; then
      _max_gap_ms=$(((sampling_interval + 15) * 1000))
    else
      # The device may spend hours in Doze without running shell timers. A same-cycle OFF
      # baseline is still useful when it wakes; reject implausibly old intervals beyond 12 hours.
      _max_gap_ms=43200000
    fi
    _contaminated=0
    if [ -n "$last_screen_sample_charge" ] && [ -n "$charge" ] &&
       awk -v a="$last_screen_sample_charge" -v b="$charge" 'BEGIN { exit !(b > a) }'; then
      _contaminated=1
    fi
    if [ -n "$last_screen_sample_capacity" ] && [ -n "$capacity" ] &&
       awk -v a="$last_screen_sample_capacity" -v b="$capacity" 'BEGIN { exit !(b > a) }'; then
      _contaminated=1
    fi
    if [ "$_contaminated" = 0 ] && [ "$_elapsed_ms" -gt 0 ] && [ "$_elapsed_ms" -le "$_max_gap_ms" ]; then
      # Credit the prior state: ON->OFF covers the final bounded on interval; OFF->ON covers
      # the sleeping interval up to wake. The cache generation check rejects reset races.
      _count_state=$last_screen_sample_state
      _cache_error=$(sh "$CACHE" add-screen-time "$_count_state" "$_elapsed_ms" "$generation" 2>&1)
      _cache_rc=$?
      if [ "$_cache_rc" -ne 0 ] && [ "$_cache_rc" -ne 3 ]; then
        printf 'monitor-daemon: screen-time cache write failed (status %s): %s\n' "$_cache_rc" "$_cache_error" >&2
      fi
    fi
  fi
  last_screen_sample_t=$now
  last_screen_sample_state=$screen_state
  last_screen_sample_charge=$charge
  last_screen_sample_capacity=$capacity
  last_screen_sample_valid=1
}

sample_once() {
  read_settings || return 1
  if [ "$generation" != "$seen_generation" ]; then
    clear_windows
    clear_screen_sample
    seen_generation=$generation
  fi
  _out=$(sh "$MODDIR/monitor.sh" screen 2>/dev/null) || _out='screen_state=unknown'
  record_from_output "$_out"
  now_s=$("$DATE_CMD" +%s 2>/dev/null)
  case "$now_s" in ''|*[!0-9]*) return 1 ;; esac
  now="${now_s}000"

  if is_charging; then charger_now=connected; else charger_now=disconnected; fi
  if [ "$charger_now" != "$last_charger" ]; then
    if [ "$charger_now" = connected ]; then
      if [ "$reset_on_charging" = 1 ]; then
        # The global option clears drain rates and both timers at the start of a charge cycle.
        sh "$CACHE" reset-data >/dev/null 2>&1 || :
      else
        # Even with the global reset disabled, SOT is cycle-based and restarts at plug-in.
        sh "$CACHE" reset-screen-on-time >/dev/null 2>&1 || :
      fi
      clear_windows
      read_settings || return 1
      seen_generation=$generation
      clear_screen_sample
    else
      clear_windows
    fi
    sh "$CACHE" set-charger-state "$charger_now" >/dev/null 2>&1 || :
    last_charger=$charger_now
  fi

  # Capture the last confirmed sample after any charger-state reset. It is used to finish a
  # pending idle window when a deep-idle phone wakes with the screen on.
  previous_screen_state=$last_screen_sample_state
  record_screen_time

  if [ "$charger_now" = connected ] || [ "$monitor_enabled" != 1 ] || [ "$battery_status" != Discharging ]; then
    clear_windows
    return 0
  fi

  case "$screen_state" in
    on)
      if [ "$previous_screen_state" = off ] && [ -n "$idle_start_t" ]; then
        update_window idle "$now"
      fi
      idle_start_t=; idle_start_charge=; idle_start_capacity=; idle_start_full=
      update_window active "$now"
      ;;
    off)
      active_start_t=; active_start_charge=; active_start_capacity=; active_start_full=
      update_window idle "$now"
      ;;
    *) clear_windows ;;
  esac
}

case "$MODE" in
  once)
    sample_once
    exit $?
    ;;
  ensure)
    mkdir -p "$DATA_DIR" 2>/dev/null || exit 1
    if pidfile_is_current; then exit 0; fi
    _lock="$DATA_DIR/monitor-start.lock"
    _tries=0
    while ! mkdir "$_lock" 2>/dev/null; do
      _owner=
      [ -r "$_lock/pid" ] && IFS= read -r _owner < "$_lock/pid"
      case "$_owner" in ''|*[!0-9]*) ;; *) kill -0 "$_owner" 2>/dev/null || { rm -f "$_lock/pid"; rmdir "$_lock" 2>/dev/null || :; } ;; esac
      _tries=$((_tries + 1))
      if [ "$_tries" -ge 30 ]; then exit 1; fi
      sleep 0.1
      if pidfile_is_current; then exit 0; fi
    done
    printf '%s\n' "$$" > "$_lock/pid"
    if ! pidfile_is_current; then start_detached_daemon || { rm -f "$_lock/pid"; rmdir "$_lock" 2>/dev/null || :; exit 1; }; fi
    rm -f "$_lock/pid"; rmdir "$_lock" 2>/dev/null || :
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
    trap 'rm -f "$PID_FILE"; exit 0' HUP INT TERM
    trap 'rm -f "$PID_FILE"' EXIT
    max_samples=${MONITOR_DAEMON_MAX_SAMPLES:-0}
    case "$max_samples" in ''|*[!0-9]*) max_samples=0 ;; esac
    sample_count=0
    clear_windows
    seen_generation=
    read_settings || exit 1
    seen_generation=$generation
    printf '%s\n' "monitor-daemon: started (screen-on interval ${sampling_interval}s; idle samples every 60s)"
    while :; do
      # Stop if the module is disabled or its files have been removed during uninstall/update.
      CURRENT_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" 2>/dev/null | sed -n 's/^version=//p' | head -n 1)
      if [ ! -f "$MODDIR/module.prop" ] || [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ "$CURRENT_VERSION" != "$DAEMON_VERSION" ]; then exit 0; fi
      sample_once || :
      sample_count=$((sample_count + 1))
      if [ "$max_samples" -gt 0 ] && [ "$sample_count" -ge "$max_samples" ]; then exit 0; fi
      read_settings || { "$SLEEP_CMD" 60; continue; }
      if [ "$monitor_enabled" = 1 ] && [ "$screen_state" = on ] && [ "$charger_online" != 1 ] && { [ "$battery_status" = Discharging ] || [ "$charger_online" = 0 ]; }; then
        sleep_for=$sampling_interval
      else
        sleep_for=60
      fi
      "$SLEEP_CMD" "$sleep_for"
    done
    ;;
  *)
    echo 'usage: monitor-daemon.sh run|once|ensure|stop [MODULE_DIR]' >&2
    exit 2
    ;;
esac
