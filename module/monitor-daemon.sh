#!/system/bin/sh
# Background battery collector. It only READS standard power/display interfaces and writes Kprofiles Control's
# own cache. For the current discharge cycle it keeps two independent sets of totals:
#   active: time with the screen ON, and the charge drawn in that time
#   idle:   time with the screen OFF for at least PENDING_MS (confirmed Screen-Off Time), and its charge
# Average current = charge / measured time. Charge is integrated from current_now with time-weighted
# trapezoids on a monotonic clock (/proc/uptime), never on wall-clock time.
set -f
LC_ALL=C
export LC_ALL

MODE=${1:-run}
case "$0" in */*) SELF_DIR=${0%/*} ;; *) SELF_DIR=. ;; esac
MODDIR=${2:-$SELF_DIR}
CACHE="$MODDIR/monitor-cache.sh"
CACHE_FILE=${MONITOR_CACHE_FILE:-/data/adb/kprofiles_ui/monitor-cache}
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
SYS_ROOT=${MONITOR_SYS_ROOT:-/sys}
UPTIME_FILE=${MONITOR_UPTIME_FILE:-/proc/uptime}
SCREEN_FILE=${MONITOR_SCREEN_STATE_FILE:-}
LOGCAT_CMD=${MONITOR_LOGCAT_CMD:-logcat}
DAEMON_VERSION=unknown
if [ -r "$MODDIR/module.prop" ]; then
  DAEMON_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" | sed -n 's/^version=//p' | head -n 1)
  [ -n "$DAEMON_VERSION" ] || DAEMON_VERSION=unknown
fi

# ---- tunables (the environment overrides exist for off-device tests and later on-device tuning) ----
pos_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ]; }
ACTIVE_INTERVAL=${MONITOR_ACTIVE_INTERVAL:-1}      # seconds between samples while the screen is on
IDLE_INTERVAL=${MONITOR_IDLE_INTERVAL:-5}          # seconds between samples while the screen is off
PENDING_MS=${MONITOR_PENDING_MS:-10000}            # a screen-off interval counts only after this long
ROLL_MS=${MONITOR_ROLL_MS:-300000}                 # rolling window of recent eligible state time (internal)
SMOOTH_MS=${MONITOR_SMOOTH_MS:-10000}              # current smoothing horizon (noise reduction only)
GAP_MS=${MONITOR_GAP_MS:-30000}                    # longer gaps between samples are not trapezoid-integrated as exact
MAX_GAP_MS=${MONITOR_MAX_GAP_MS:-43200000}         # longer gaps are discarded (nothing is counted)
PERSIST_MS=${MONITOR_PERSIST_MS:-15000}            # at most one routine cache write per this long
MAX_SANE_UA=${MONITOR_MAX_SANE_UA:-20000000}       # readings above 20 A are not battery current
for _tn in ACTIVE_INTERVAL IDLE_INTERVAL PENDING_MS ROLL_MS SMOOTH_MS GAP_MS MAX_GAP_MS PERSIST_MS MAX_SANE_UA; do
  case "$_tn" in
    ACTIVE_INTERVAL) pos_int "$ACTIVE_INTERVAL" || ACTIVE_INTERVAL=1 ;;
    IDLE_INTERVAL) pos_int "$IDLE_INTERVAL" || IDLE_INTERVAL=5 ;;
    PENDING_MS) pos_int "$PENDING_MS" || PENDING_MS=10000 ;;
    ROLL_MS) pos_int "$ROLL_MS" || ROLL_MS=300000 ;;
    SMOOTH_MS) pos_int "$SMOOTH_MS" || SMOOTH_MS=10000 ;;
    GAP_MS) pos_int "$GAP_MS" || GAP_MS=30000 ;;
    MAX_GAP_MS) pos_int "$MAX_GAP_MS" || MAX_GAP_MS=43200000 ;;
    PERSIST_MS) pos_int "$PERSIST_MS" || PERSIST_MS=15000 ;;
    MAX_SANE_UA) pos_int "$MAX_SANE_UA" || MAX_SANE_UA=20000000 ;;
  esac
done

if [ ! -x "$CACHE" ]; then
  [ -f "$CACHE" ] || exit 1
fi

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


# =====================================================================================================
# Measurement engine
# =====================================================================================================

read_first() {
  _R=
  [ -r "$1" ] || return 1
  IFS= read -r _R < "$1" 2>/dev/null || [ -n "$_R" ]
}

# NOW = milliseconds on the monotonic boot clock (counts suspend time, unaffected by wall-clock changes).
now_ms() {
  NOW=
  _up=
  IFS=' ' read -r _up _ < "$UPTIME_FILE" 2>/dev/null || [ -n "$_up" ] || return 1
  _int=${_up%%.*}
  case "$_int" in ''|*[!0-9]*) return 1 ;; esac
  _frac=0
  case "$_up" in *.*) _frac=${_up#*.} ;; esac
  case "$_frac" in
    '') _f3=000 ;;
    ?) _f3=${_frac}00 ;;
    ??) _f3=${_frac}0 ;;
    *) _f3=${_frac%"${_frac#???}"} ;;
  esac
  case "$_f3" in *[!0-9]*) return 1 ;; esac
  while [ "${#_f3}" -gt 1 ] && [ "${_f3#0}" != "$_f3" ]; do _f3=${_f3#0}; done
  while [ "${#_int}" -gt 1 ] && [ "${_int#0}" != "$_int" ]; do _int=${_int#0}; done
  [ "${#_int}" -le 13 ] || return 1
  NOW=$((_int * 1000 + _f3))
}

discover_battery() {
  BATT_DIR=
  ONLINE_FILES=
  set +f
  for _d in "$SYS_ROOT"/class/power_supply/*; do
    [ -d "$_d" ] || continue
    _btype=
    read_first "$_d/type" && _btype=$_R
    case "$_btype" in [Bb]attery) BATT_DIR=$_d; break ;; esac
    [ "${_d##*/}" = battery ] && BATT_DIR=$_d
  done
  if [ -n "$BATT_DIR" ]; then
    for _d in "$SYS_ROOT"/class/power_supply/*; do
      [ -d "$_d" ] || continue
      [ "$_d" != "$BATT_DIR" ] || continue
      _stype=
      read_first "$_d/type" && _stype=$_R
      case "$_stype:${_d##*/}" in
        Mains:*|USB:*|USB_C:*|Wireless:*|Usb*:*|*usb*:*|*USB*:*|*mains*:*|*wireless*:*|*typec*:*|*AC:*)
          [ -r "$_d/online" ] && ONLINE_FILES="$ONLINE_FILES $_d/online" ;;
      esac
    done
  fi
  set -f
  [ -n "$BATT_DIR" ]
}

# Reads the battery. Sets b_status, b_cur (raw), b_ctr (charge counter, uAh) and b_online (1, 0 or unknown).
read_battery() {
  b_status=; b_cur=; b_ctr=; b_online=unknown
  [ -n "$BATT_DIR" ] && [ -d "$BATT_DIR" ] || discover_battery || return 1
  read_first "$BATT_DIR/status" && b_status=$_R
  read_first "$BATT_DIR/current_now" && b_cur=$_R
  read_first "$BATT_DIR/charge_counter" && b_ctr=$_R
  _seen=0
  for _f in $ONLINE_FILES; do
    if read_first "$_f"; then
      _seen=1
      if [ "$_R" = 1 ]; then b_online=1; break; fi
    fi
  done
  if [ "$b_online" != 1 ] && [ "$_seen" = 1 ]; then b_online=0; fi
  return 0
}

# PLUG = plugged | unplugged | unknown. A full or "not charging" battery on a charger is still plugged in, so
# reaching 100% never looks like an unplug.
plug_from() {
  PLUG=unknown
  if [ "$b_online" = 1 ]; then PLUG=plugged; return 0; fi
  case "$b_status" in
    Charging|Full) PLUG=plugged ;;
    "Not charging") if [ "$b_online" = 0 ]; then PLUG=unplugged; else PLUG=plugged; fi ;;
    Discharging) PLUG=unplugged ;;
  esac
  return 0
}

# SCR = on | off | unknown
probe_screen() {
  SCR=unknown
  if [ -n "$SCREEN_FILE" ]; then
    read_first "$SCREEN_FILE" && SCR=$_R
    case "$SCR" in on|off) ;; *) SCR=unknown ;; esac
    return 0
  fi
  command -v dumpsys >/dev/null 2>&1 || return 0
  _pdump=$(dumpsys power 2>/dev/null)
  case "$_pdump" in
    *mWakefulness=Asleep*|*mWakefulness=Dozing*|*mInteractive=false*|*"Display Power: state=OFF"*) SCR=off ;;
    *mWakefulness=Awake*|*mInteractive=true*|*"Display Power: state=ON"*) SCR=on ;;
  esac
  return 0
}

# Android's own screen-state event log gives the real moment of a transition even when this process was not
# scheduled for a while (deep sleep). EV_T = that moment on the monotonic clock, clamped to the sample pair, or
# empty when the log has nothing usable (the sample time is then used).
screen_event_time() {
  EV_T=
  _want=$1; _lo=$2; _hi=$3
  if [ ! -x "$LOGCAT_CMD" ]; then command -v "$LOGCAT_CMD" >/dev/null 2>&1 || return 1; fi
  _evlog=$("$LOGCAT_CMD" -b events -d -v epoch -t 400 'power_screen_state:I' 'screen_toggled:I' '*:S' 2>/dev/null) || return 1
  [ -n "$_evlog" ] || return 1
  _evms=$(printf '%s\n' "$_evlog" | "$AWK_CMD" -v want="$_want" '
    /power_screen_state|screen_toggled/ {
      if (match($0, /(power_screen_state: \[|screen_toggled: )[0-9]/)) {
        d = substr($0, RSTART + RLENGTH - 1, 1)
        st = (d == "0") ? "off" : "on"
        ts = $1 + 0
        if (ts > 1000000000) { last_state = st; last_ts = ts }
      }
    }
    END { if (last_state == want && last_ts > 0) printf "%.0f\n", last_ts * 1000 }')
  case "$_evms" in ''|*[!0-9]*) return 1 ;; esac
  _epoch_s=$("$DATE_CMD" +%s 2>/dev/null)
  case "$_epoch_s" in ''|*[!0-9]*) return 1 ;; esac
  now_ms || return 1
  # Mid-second correction: date has one-second resolution.
  EV_T=$(( _evms - (_epoch_s * 1000 + 500 - NOW) ))
  [ "$EV_T" -ge "$_lo" ] || EV_T=$_lo
  [ "$EV_T" -le "$_hi" ] || EV_T=$_hi
  return 0
}

# --- rolling window of recent eligible time (internal; trimmed by time, not by sample count) ---
# Buffer = space-separated "durationMs:charge" tokens, oldest first.
roll_push() {
  R_BUF="$1 $4:$5"; R_MS=$(( $2 + $4 )); R_Q=$(( $3 + $5 ))
  while [ "$R_MS" -gt "$ROLL_MS" ]; do
    _first=${R_BUF# }; _first=${_first%% *}
    _fd=${_first%%:*}; _fq=${_first#*:}
    _ex=$(( R_MS - ROLL_MS ))
    if [ "$_fd" -le "$_ex" ]; then
      R_BUF=${R_BUF#" $_first"}; R_MS=$(( R_MS - _fd )); R_Q=$(( R_Q - _fq ))
    else
      _nd=$(( _fd - _ex )); _nq=$(( _fq * _nd / _fd ))
      R_BUF=" $_nd:$_nq${R_BUF#" $_first"}"; R_MS=$(( R_MS - _ex )); R_Q=$(( R_Q - _fq + _nq ))
    fi
  done
}

# --- one sample pair: previous (l_t, l_i, l_ctr, l_scr) and current (t, c_i, c_ctr, SCR) ---
# pair_mode: trap (interpolate between the two readings), trap_prov (same, over a long gap, so provisional),
# counter (long gap measured by the fuel-gauge charge counter, provisional) or none (no usable reading).
prepare_pair() {
  pair_dt=$(( t - l_t )); pair_mode=none; pair_q=0; pair_trans=0
  if [ "$l_scr" != "$SCR" ]; then pair_trans=1; fi
  if [ "$pair_dt" -le "$GAP_MS" ]; then
    if [ -n "$l_i" ] && [ -n "$c_i" ]; then pair_mode="trap"; fi
  else
    # Long gap (deep sleep): the charge counter is the trustworthy source when it moved; otherwise interpolate
    # between the two readings and mark the result provisional. A stale reading is never extended across it.
    if [ -n "$l_ctr" ] && [ -n "$c_ctr" ] && [ "$l_ctr" -gt "$c_ctr" ]; then
      pair_q=$(( (l_ctr - c_ctr) * 3600000 ))
      if [ $(( pair_q / pair_dt )) -le "$MAX_SANE_UA" ]; then pair_mode=counter; fi
    fi
    if [ "$pair_mode" = none ] && [ -n "$l_i" ] && [ -n "$c_i" ]; then pair_mode=trap_prov; fi
  fi
}

# Charge in [$1,$2] (inside the current pair). Sets SEG_DT, SEG_Q, SEG_OK (1 = measured), SEG_PROV.
# Across a screen transition each side uses its OWN state's reading (HOLD), never a blend of the two states.
seg_calc() {
  SEG_DT=$(( $2 - $1 )); SEG_Q=0; SEG_OK=0; SEG_PROV=0
  if [ "$SEG_DT" -le 0 ]; then SEG_DT=0; return 0; fi
  if [ "$pair_mode" = counter ]; then
    SEG_Q=$(( pair_q * SEG_DT / pair_dt )); SEG_OK=1; SEG_PROV=1
  elif [ "$pair_trans" = 1 ]; then
    if [ -n "$HOLD" ]; then
      SEG_Q=$(( HOLD * SEG_DT )); SEG_OK=1
      if [ "$pair_dt" -gt "$GAP_MS" ]; then SEG_PROV=1; fi
    fi
  elif [ "$pair_mode" = trap ] || [ "$pair_mode" = trap_prov ]; then
    _ia=$(( l_i + (c_i - l_i) * ($1 - l_t) / pair_dt ))
    _ib=$(( l_i + (c_i - l_i) * ($2 - l_t) / pair_dt ))
    SEG_Q=$(( (_ia + _ib) * SEG_DT / 2 )); SEG_OK=1
    if [ "$pair_mode" = trap_prov ]; then SEG_PROV=1; fi
  fi
  return 0
}

acc_active() {
  seg_calc "$1" "$2"
  [ "$SEG_DT" -gt 0 ] || return 0
  A_ms=$(( A_ms + SEG_DT )); dirty=1
  if [ "$SEG_OK" = 1 ]; then
    A_chg=$(( A_chg + SEG_Q ))
    roll_push "$A_roll" "$A_rms" "$A_rq" "$SEG_DT" "$SEG_Q"
    A_roll=$R_BUF; A_rms=$R_MS; A_rq=$R_Q
  else
    A_unm=$(( A_unm + SEG_DT ))
  fi
  if [ "$SEG_PROV" = 1 ]; then A_prov=1; fi
  return 0
}

acc_idle() {
  seg_calc "$1" "$2"
  [ "$SEG_DT" -gt 0 ] || return 0
  I_ms=$(( I_ms + SEG_DT )); dirty=1
  if [ "$SEG_OK" = 1 ]; then
    I_chg=$(( I_chg + SEG_Q ))
    roll_push "$I_roll" "$I_rms" "$I_rq" "$SEG_DT" "$SEG_Q"
    I_roll=$R_BUF; I_rms=$R_MS; I_rq=$R_Q
  else
    I_unm=$(( I_unm + SEG_DT ))
  fi
  if [ "$SEG_PROV" = 1 ]; then I_prov=1; fi
  return 0
}

# Screen-off time before the 10 s rule is met is buffered, not counted anywhere.
acc_pending() {
  seg_calc "$1" "$2"
  [ "$SEG_DT" -gt 0 ] || return 0
  P_ms=$(( P_ms + SEG_DT ))
  if [ "$SEG_OK" = 1 ]; then
    P_chg=$(( P_chg + SEG_Q )); P_roll="$P_roll $SEG_DT:$SEG_Q"
  else
    P_unm=$(( P_unm + SEG_DT ))
  fi
  if [ "$SEG_PROV" = 1 ]; then P_prov=1; fi
  return 0
}

clear_pending() { P_chg=0; P_ms=0; P_unm=0; P_prov=0; P_roll=; }

# The screen stayed off for the whole pending time: it becomes confirmed idle, counted from the ORIGINAL
# screen-off timestamp.
confirm_pending() {
  I_ms=$(( I_ms + P_ms )); I_chg=$(( I_chg + P_chg )); I_unm=$(( I_unm + P_unm ))
  if [ "$P_prov" = 1 ]; then I_prov=1; fi
  for _tok in $P_roll; do
    roll_push "$I_roll" "$I_rms" "$I_rq" "${_tok%%:*}" "${_tok#*:}"
    I_roll=$R_BUF; I_rms=$R_MS; I_rq=$R_Q
  done
  clear_pending
  conf=1; dirty=1; force=1
}

# Screen-off segment [$1,$2]: pending until PENDING_MS after the original screen-off time.
acc_off() {
  _a=$1; _b=$2
  if [ "$conf" = 0 ]; then
    _c=$(( pend_t + PENDING_MS ))
    if [ "$_b" -lt "$_c" ]; then acc_pending "$_a" "$_b"; return 0; fi
    if [ "$_a" -lt "$_c" ]; then acc_pending "$_a" "$_c"; _a=$_c; fi
    confirm_pending
  fi
  acc_idle "$_a" "$_b"
}

start_off() { pend_t=$1; conf=0; clear_pending; }
end_off() { clear_pending; conf=0; pend_t=; }

# Account for everything between the previous sample and this one, splitting at a screen transition.
process_pair() {
  prepare_pair
  HOLD=
  if [ "$l_scr" = "$SCR" ]; then
    case "$SCR" in
      on) acc_active "$l_t" "$t" ;;
      off) acc_off "$l_t" "$t" ;;
    esac
    return 0
  fi
  _tt=$t
  if screen_event_time "$SCR" "$l_t" "$t"; then _tt=$EV_T; fi
  case "$l_scr" in
    on)
      HOLD=$l_i
      acc_active "$l_t" "$_tt"
      start_off "$_tt"
      HOLD=$c_i
      acc_off "$_tt" "$t"
      ;;
    off)
      HOLD=$l_i
      acc_off "$l_t" "$_tt"
      end_off
      HOLD=$c_i
      acc_active "$_tt" "$t"
      ;;
  esac
  HOLD=
  sm=
  force=1
  return 0
}

# --- state ---
reset_memory() {
  l_t=; l_i=; l_ctr=; l_scr=; sm=
  conf=0; pend_t=
  clear_pending
  A_roll=; A_rms=0; A_rq=0; I_roll=; I_rms=0; I_rq=0
}

zero_totals() {
  A_chg=0; A_ms=0; A_unm=0; A_prov=0; I_chg=0; I_ms=0; I_unm=0; I_prov=0
}

load_totals() {
  _out=$(sh "$CACHE" get 2>/dev/null) || return 1
  gen=0; cyc_id=0; cyc_state=none; cyc_boot=
  zero_totals
  while IFS='=' read -r _k _v; do
    case "$_k" in
      generation) gen=$_v ;;
      cycle_id) cyc_id=$_v ;;
      cycle_state) cyc_state=$_v ;;
      cycle_boot) cyc_boot=$_v ;;
      active_charge) A_chg=$_v ;;
      active_ms) A_ms=$_v ;;
      active_unmeasured) A_unm=$_v ;;
      active_prov) A_prov=$_v ;;
      idle_charge) I_chg=$_v ;;
      idle_ms) I_ms=$_v ;;
      idle_unmeasured) I_unm=$_v ;;
      idle_prov) I_prov=$_v ;;
    esac
  done <<EOF_CACHE
$_out
EOF_CACHE
  for _n in gen cyc_id A_chg A_ms A_unm A_prov I_chg I_ms I_unm I_prov; do
    case "$_n" in
      gen) case "$gen" in ''|*[!0-9]*) gen=0 ;; esac ;;
      cyc_id) case "$cyc_id" in ''|*[!0-9]*) cyc_id=0 ;; esac ;;
      A_chg) case "$A_chg" in ''|*[!0-9]*) A_chg=0 ;; esac ;;
      A_ms) case "$A_ms" in ''|*[!0-9]*) A_ms=0 ;; esac ;;
      A_unm) case "$A_unm" in ''|*[!0-9]*) A_unm=0 ;; esac ;;
      A_prov) case "$A_prov" in 0|1) ;; *) A_prov=0 ;; esac ;;
      I_chg) case "$I_chg" in ''|*[!0-9]*) I_chg=0 ;; esac ;;
      I_ms) case "$I_ms" in ''|*[!0-9]*) I_ms=0 ;; esac ;;
      I_unm) case "$I_unm" in ''|*[!0-9]*) I_unm=0 ;; esac ;;
      I_prov) case "$I_prov" in 0|1) ;; *) I_prov=0 ;; esac ;;
    esac
  done
  dirty=0; force=0
  return 0
}

peek_cache() {
  pk_gen=$gen; pk_en=1
  [ -r "$CACHE_FILE" ] || return 0
  while IFS='=' read -r _k _v; do
    case "$_k" in
      generation) pk_gen=$_v ;;
      monitor_enabled) pk_en=$_v ;;
    esac
  done < "$CACHE_FILE"
  case "$pk_gen" in ''|*[!0-9]*) pk_gen=$gen ;; esac
  case "$pk_en" in 0|1) ;; *) pk_en=1 ;; esac
  return 0
}

persist() {
  _aru=; _iru=
  if [ "$A_rms" -gt 0 ]; then _aru=$(( A_rq / A_rms )); fi
  if [ "$I_rms" -gt 0 ]; then _iru=$(( I_rq / I_rms )); fi
  sh "$CACHE" set-cycle "$gen" "cycle_id=$cyc_id" "cycle_state=$cyc_state" "cycle_boot=$cyc_boot" \
    "active_charge=$A_chg" "active_ms=$A_ms" "active_unmeasured=$A_unm" "active_prov=$A_prov" \
    "idle_charge=$I_chg" "idle_ms=$I_ms" "idle_unmeasured=$I_unm" "idle_prov=$I_prov" \
    "active_recent_ua=$_aru" "active_recent_ms=$A_rms" "idle_recent_ua=$_iru" "idle_recent_ms=$I_rms" >/dev/null 2>&1
  _prc=$?
  case "$_prc" in
    0) dirty=0; force=0; last_persist=${t:-0} ;;
    3)
      # A reset happened since this process last looked: the cache is authoritative. Pick it up and start
      # measuring again from the current state instead of writing old totals back.
      load_totals || :
      reset_memory
      ;;
    *) printf 'monitor-daemon: cache write failed (%s)\n' "$_prc" >&2 ;;
  esac
  return 0
}

maybe_persist() {
  [ "$dirty" = 1 ] || return 0
  if [ "$force" != 1 ] && [ -n "$last_persist" ] && [ $(( t - last_persist )) -lt "$PERSIST_MS" ]; then return 0; fi
  persist
}

start_new_cycle() {
  cyc_id=$(( cyc_id + 1 )); cyc_state=discharging
  zero_totals
  reset_memory
  dirty=1; force=1
}

# Raw current_now (uA, either sign) -> c_i (smoothed magnitude) or empty when unusable.
current_sample() {
  c_i=
  case "$b_cur" in
    ''|-|*[!0-9-]*|?*-*) return 0 ;;
  esac
  _raw=${b_cur#-}
  case "$_raw" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#_raw}" -le 12 ] || return 0
  [ "$_raw" -gt 0 ] && [ "$_raw" -le "$MAX_SANE_UA" ] || return 0
  if [ -z "$sm" ] || [ -z "$l_t" ] || [ "$l_scr" != "$SCR" ]; then
    # First reading, or the screen state just changed: start from the raw value so one state's smoothed
    # current never carries into the other state.
    sm=$_raw
  else
    _sa=$(( (t - l_t) * 1000 / (t - l_t + SMOOTH_MS) ))
    sm=$(( sm + (_raw - sm) * _sa / 1000 ))
  fi
  c_i=$sm
  return 0
}

tick() {
  now_ms || return 1
  t=$NOW
  if [ -n "$l_t" ] && [ "$t" -lt "$l_t" ]; then reset_memory; fi   # the clock restarted (reboot)
  read_battery || { reset_memory; return 1; }
  plug_from
  peek_cache
  if [ "$pk_gen" != "$gen" ]; then load_totals || :; reset_memory; fi
  if [ "$pk_en" != 1 ]; then reset_memory; return 0; fi
  case "$PLUG" in
    unknown) reset_memory; return 0 ;;
    plugged)
      if [ "$cyc_state" != charging ]; then
        # The discharge cycle ends here. Everything measured up to the previous sample is already in the
        # totals; an unconfirmed screen-off interval is discarded; nothing is added while charging.
        cyc_state=charging; dirty=1; force=1
      fi
      reset_memory
      maybe_persist
      return 0
      ;;
  esac
  # Unplugged and discharging.
  if [ "$cyc_state" != discharging ]; then start_new_cycle; fi
  if [ "$cyc_boot" != "$cur_boot" ]; then cyc_boot=$cur_boot; dirty=1; fi
  probe_screen
  if [ "$SCR" = unknown ]; then reset_memory; maybe_persist; return 0; fi
  c_ctr=
  case "$b_ctr" in ''|*[!0-9]*) ;; *) [ "${#b_ctr}" -le 12 ] && c_ctr=$b_ctr ;; esac
  current_sample
  if [ -n "$l_t" ] && [ $(( t - l_t )) -gt "$MAX_GAP_MS" ]; then reset_memory; current_sample; fi
  if [ -z "$l_t" ]; then
    # First sample after start, reset, gap or plug change: anchor only; nothing is credited for time not observed.
    if [ "$SCR" = off ]; then start_off "$t"; fi
  elif [ "$t" -gt "$l_t" ]; then
    process_pair
  fi
  l_t=$t; l_i=$c_i; l_ctr=$c_ctr; l_scr=$SCR
  maybe_persist
  return 0
}

persist_on_exit() {
  [ "${dirty:-0}" = 1 ] && [ -n "${gen:-}" ] || return 0
  persist
}

init_engine() {
  cur_boot=
  read_first "$BOOT_ID_FILE" && cur_boot=$_R
  case "$cur_boot" in *[!0-9a-fA-F-]*) cur_boot= ;; esac
  BATT_DIR=; ONLINE_FILES=
  last_persist=; t=; NOW=; HOLD=
  reset_memory
  zero_totals
  gen=0; cyc_id=0; cyc_state=none; cyc_boot=; dirty=0; force=0
  load_totals || return 1
  return 0
}

case "$MODE" in
  once)
    init_engine || exit 1
    tick || exit 1
    if [ "$dirty" = 1 ]; then force=1; persist; fi
    exit 0
    ;;
  probe)
    # On-device check of how fresh current_now is: reads it once a second and reports how often it changed.
    _n=${3:-20}
    case "$_n" in ''|*[!0-9]*) _n=20 ;; esac
    _i=0; _prev=; _changes=0; _valid=0
    while [ "$_i" -lt "$_n" ]; do
      if read_battery && [ -n "$b_cur" ]; then
        _valid=$(( _valid + 1 ))
        if [ -n "$_prev" ] && [ "$b_cur" != "$_prev" ]; then _changes=$(( _changes + 1 )); fi
        _prev=$b_cur
      fi
      _i=$(( _i + 1 ))
      if [ "$_i" -lt "$_n" ]; then "$SLEEP_CMD" 1; fi
    done
    printf 'samples=%s valid=%s changes=%s\n' "$_n" "$_valid" "$_changes"
    exit 0
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
    trap 'persist_on_exit; rm -f "$PID_FILE"; exit 0' HUP INT TERM
    trap 'rm -f "$PID_FILE"' EXIT
    max_samples=${MONITOR_DAEMON_MAX_SAMPLES:-0}
    case "$max_samples" in ''|*[!0-9]*) max_samples=0 ;; esac
    sample_count=0
    init_engine || exit 1
    PLUG=unknown; SCR=unknown; pk_en=1
    last_ver_t=
    printf '%s\n' "monitor-daemon: started (screen-on every ${ACTIVE_INTERVAL}s, screen-off every ${IDLE_INTERVAL}s)"
    while :; do
      # Stop if the module is disabled or its files have been removed during uninstall/update.
      if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -f "$MODDIR/module.prop" ]; then exit 0; fi
      if [ -z "$last_ver_t" ] || [ -z "$t" ] || [ $(( t - last_ver_t )) -ge 30000 ] || [ "$t" -lt "$last_ver_t" ]; then
        CURRENT_VERSION=$(tr -d '\r' < "$MODDIR/module.prop" 2>/dev/null | sed -n 's/^version=//p' | head -n 1)
        if [ "$CURRENT_VERSION" != "$DAEMON_VERSION" ]; then exit 0; fi
        last_ver_t=$t
      fi
      tick || :
      sample_count=$((sample_count + 1))
      if [ "$max_samples" -gt 0 ] && [ "$sample_count" -ge "$max_samples" ]; then persist_on_exit; exit 0; fi
      if [ "$pk_en" != 1 ]; then sleep_for=10
      elif [ "$PLUG" = unplugged ] && [ "$SCR" = on ]; then sleep_for=$ACTIVE_INTERVAL
      elif [ "$PLUG" = unplugged ]; then sleep_for=$IDLE_INTERVAL
      else sleep_for=10
      fi
      "$SLEEP_CMD" "$sleep_for"
    done
    ;;
  *)
    echo 'usage: monitor-daemon.sh run|once|ensure|stop [MODULE_DIR] | probe MODULE_DIR [SECONDS]' >&2
    exit 2
    ;;
esac
