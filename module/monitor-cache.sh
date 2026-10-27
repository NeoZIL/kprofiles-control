#!/system/bin/sh
# Persistent battery-monitor settings and latest valid drain rates.
# All updates are validated and replaced atomically; settings survive data resets.
set -f
umask 077

CACHE_FILE=${MONITOR_CACHE_FILE:-/data/adb/kprofiles_ui/monitor-cache}
CACHE_DIR=${CACHE_FILE%/*}
MODE=${1:-get}
LEGACY_CACHE_FILE=/data/adb/modules/kprofiles_ui/.monitor-cache
LOCK_DIR="$CACHE_FILE.lock"

valid_rate() {
  [ "$#" -eq 1 ] || return 1
  awk -v n="$1" 'BEGIN { if (n ~ /^[0-9]+([.][0-9]+)?$/ && n + 0 >= 0 && n + 0 < 100) exit 0; exit 1 }'
}
valid_time() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -ge 10 ] && [ "${#1}" -le 14 ] || return 1
  case "$1" in *[1-9]*) return 0 ;; *) return 1 ;; esac
}
valid_bool() { [ "$#" -eq 1 ] && { [ "$1" = 0 ] || [ "$1" = 1 ]; }; }
valid_duration() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 15 ] || return 1
  return 0
}
valid_generation() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ] || return 1
}

active_rate=
active_time=
idle_rate=
idle_time=
monitor_enabled=1
sampling_interval=30
reset_on_charging=1
generation=0
reset_time=0
last_charger=unknown
screen_on_ms=0
screen_off_ms=0

load_file() {
  _file=$1
  [ -f "$_file" ] && [ ! -L "$_file" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      active_rate) active_rate=$value ;;
      active_time) active_time=$value ;;
      idle_rate) idle_rate=$value ;;
      idle_time) idle_time=$value ;;
      monitor_enabled) monitor_enabled=$value ;;
      sampling_interval) sampling_interval=$value ;;
      reset_on_charging) reset_on_charging=$value ;;
      generation) generation=$value ;;
      reset_time) reset_time=$value ;;
      last_charger) last_charger=$value ;;
      screen_on_ms) screen_on_ms=$value ;;
      screen_off_ms) screen_off_ms=$value ;;
    esac
  done < "$_file"
}
load_cache() {
  if [ -f "$CACHE_FILE" ] && [ ! -L "$CACHE_FILE" ]; then
    load_file "$CACHE_FILE"
  elif [ -z "${MONITOR_CACHE_FILE:-}" ] && [ -f "$LEGACY_CACHE_FILE" ] && [ ! -L "$LEGACY_CACHE_FILE" ]; then
    # One-way migration from v4.0.5's cache in the replaceable module directory.
    load_file "$LEGACY_CACHE_FILE"
  fi
  if ! valid_rate "$active_rate" || ! valid_time "$active_time"; then active_rate=; active_time=; fi
  if ! valid_rate "$idle_rate" || ! valid_time "$idle_time"; then idle_rate=; idle_time=; fi
  valid_bool "$monitor_enabled" || monitor_enabled=1
  case "$sampling_interval" in 15|30|60) ;; *) sampling_interval=30 ;; esac
  valid_bool "$reset_on_charging" || reset_on_charging=1
  valid_generation "$generation" || generation=0
  valid_time "$reset_time" || reset_time=0
  case "$last_charger" in connected|disconnected|unknown) ;; *) last_charger=unknown ;; esac
  valid_duration "$screen_on_ms" || screen_on_ms=0
  valid_duration "$screen_off_ms" || screen_off_ms=0
}
write_cache() {
  [ ! -L "$CACHE_FILE" ] || return 1
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  tmp="$CACHE_FILE.tmp.$$"
  (umask 077; {
    printf 'active_rate=%s\n' "$active_rate"
    printf 'active_time=%s\n' "$active_time"
    printf 'idle_rate=%s\n' "$idle_rate"
    printf 'idle_time=%s\n' "$idle_time"
    printf 'monitor_enabled=%s\n' "$monitor_enabled"
    printf 'sampling_interval=%s\n' "$sampling_interval"
    printf 'reset_on_charging=%s\n' "$reset_on_charging"
    printf 'generation=%s\n' "$generation"
    printf 'reset_time=%s\n' "$reset_time"
    printf 'last_charger=%s\n' "$last_charger"
    printf 'screen_on_ms=%s\nscreen_off_ms=%s\n' "$screen_on_ms" "$screen_off_ms"
  } > "$tmp") || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CACHE_FILE" || { rm -f "$tmp"; return 1; }
}
acquire_lock() {
  _tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _owner=
    [ -r "$LOCK_DIR/pid" ] && IFS= read -r _owner < "$LOCK_DIR/pid"
    case "$_owner" in
      ''|*[!0-9]*) ;;
      *) if ! kill -0 "$_owner" 2>/dev/null; then rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null; fi ;;
    esac
    _tries=$((_tries + 1))
    [ "$_tries" -lt 50 ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
release_lock() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  _owner=
  [ -r "$LOCK_DIR/pid" ] && IFS= read -r _owner < "$LOCK_DIR/pid"
  [ "$_owner" = "$$" ] || return 0
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null
}

case "$MODE" in
  get)
    load_cache
    printf 'active_rate=%s\nactive_time=%s\nidle_rate=%s\nidle_time=%s\n' "$active_rate" "$active_time" "$idle_rate" "$idle_time"
    printf 'monitor_enabled=%s\nsampling_interval=%s\nreset_on_charging=%s\ngeneration=%s\nreset_time=%s\nlast_charger=%s\nscreen_on_ms=%s\nscreen_off_ms=%s\n' \
      "$monitor_enabled" "$sampling_interval" "$reset_on_charging" "$generation" "$reset_time" "$last_charger" "$screen_on_ms" "$screen_off_ms"
    ;;
  set-active|set-idle)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || exit 2
    new_rate=$2; new_time=$3; expected_generation=${4:-}
    valid_rate "$new_rate" && valid_time "$new_time" || exit 2
    acquire_lock || exit 1
    trap release_lock EXIT
    load_cache
    if [ -n "$expected_generation" ] && { ! valid_generation "$expected_generation" || [ "$expected_generation" != "$generation" ]; }; then exit 3; fi
    if [ "$MODE" = set-active ]; then active_rate=$new_rate; active_time=$new_time
    else idle_rate=$new_rate; idle_time=$new_time
    fi
    write_cache
    ;;
  set-enabled)
    [ "$#" -eq 2 ] && valid_bool "$2" || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache; monitor_enabled=$2; write_cache
    ;;
  set-interval)
    [ "$#" -eq 2 ] || exit 2
    case "$2" in 15|30|60) ;; *) exit 2 ;; esac
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache; sampling_interval=$2; write_cache
    ;;
  set-reset-on-charging)
    [ "$#" -eq 2 ] && valid_bool "$2" || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache; reset_on_charging=$2; write_cache
    ;;
  set-charger-state)
    [ "$#" -eq 2 ] || exit 2
    case "$2" in connected|disconnected|unknown) ;; *) exit 2 ;; esac
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache; last_charger=$2; write_cache
    ;;
  add-screen-time)
    [ "$#" -eq 4 ] || exit 2
    time_state=$2; delta_ms=$3; expected_generation=$4
    case "$time_state" in
      on) max_delta_ms=120000 ;;
      off) max_delta_ms=43200000 ;;
      *) exit 2 ;;
    esac
    valid_duration "$delta_ms" && [ "$delta_ms" -gt 0 ] && [ "$delta_ms" -le "$max_delta_ms" ] || exit 2
    valid_generation "$expected_generation" || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache
    [ "$expected_generation" = "$generation" ] || exit 3
    if [ "$time_state" = on ]; then
      screen_on_ms=$((screen_on_ms + delta_ms))
      valid_duration "$screen_on_ms" || exit 2
    else
      screen_off_ms=$((screen_off_ms + delta_ms))
      valid_duration "$screen_off_ms" || exit 2
    fi
    write_cache
    ;;
  reset-screen-on-time)
    [ "$#" -eq 1 ] || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache
    screen_on_ms=0
    # Advance generation so a screen-time sample already in flight cannot restore the old total.
    # Drain-rate values and screen-off time are deliberately preserved.
    generation=$((generation + 1))
    reset_time="$(date +%s)000"
    write_cache || exit 1
    rm -f "$CACHE_FILE.active-window" "$CACHE_FILE.idle-window" "$CACHE_FILE.pending"
    ;;
  reset-data)
    [ "$#" -eq 1 ] || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache
    active_rate=; active_time=; idle_rate=; idle_time=
    screen_on_ms=0; screen_off_ms=0
    generation=$((generation + 1))
    reset_time="$(date +%s)000"
    write_cache || exit 1
    # Daemon windows are memory-only, but remove any interrupted/older implementation's pending files too.
    rm -f "$CACHE_FILE.active-window" "$CACHE_FILE.idle-window" "$CACHE_FILE.pending"
    ;;
  *)
    echo 'usage: monitor-cache.sh get | set-active RATE TIMESTAMP [GENERATION] | set-idle RATE TIMESTAMP [GENERATION] | reset-screen-on-time | set-enabled 0|1 | set-interval 15|30|60 | set-reset-on-charging 0|1 | set-charger-state connected|disconnected|unknown | add-screen-time on|off DELTA_MS GENERATION (on <=120000ms; off <=43200000ms) | reset-data' >&2
    exit 2
    ;;
esac
