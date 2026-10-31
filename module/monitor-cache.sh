#!/system/bin/sh
# Persistent battery-monitor settings and the current discharge cycle's active/idle charge and time totals.
# All updates are validated and replaced atomically; settings survive data resets.
set -f
umask 077

CACHE_FILE=${MONITOR_CACHE_FILE:-/data/adb/kprofiles_ui/monitor-cache}
CACHE_DIR=${CACHE_FILE%/*}
MODE=${1:-get}
LEGACY_CACHE_FILE=/data/adb/modules/kprofiles_ui/.monitor-cache
LOCK_DIR="$CACHE_FILE.lock"
PROC_DIR=${MONITOR_PROC_DIR:-/proc}
# Named explicitly so tests can supply a hooked awk by path: a shell that prefers its own built-in applets over
# PATH (busybox ash on Debian/Ubuntu) would never run a fake awk placed in PATH.
AWK_CMD=${MONITOR_AWK_CMD:-awk}
BOOT_ID_FILE=${MONITOR_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}

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

monitor_enabled=1
generation=0
reset_time=0
cycle_id=0
cycle_state=none
cycle_boot=
active_charge=0
active_ms=0
active_unmeasured=0
active_prov=0
idle_charge=0
idle_ms=0
idle_unmeasured=0
idle_prov=0
active_recent_ua=
active_recent_ms=0
idle_recent_ua=
idle_recent_ms=0

load_file() {
  _file=$1
  [ -f "$_file" ] && [ ! -L "$_file" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      monitor_enabled) monitor_enabled=$value ;;
      generation) generation=$value ;;
      reset_time) reset_time=$value ;;
      cycle_id) cycle_id=$value ;;
      cycle_state) cycle_state=$value ;;
      cycle_boot) cycle_boot=$value ;;
      active_charge) active_charge=$value ;;
      active_ms) active_ms=$value ;;
      active_unmeasured) active_unmeasured=$value ;;
      active_prov) active_prov=$value ;;
      idle_charge) idle_charge=$value ;;
      idle_ms) idle_ms=$value ;;
      idle_unmeasured) idle_unmeasured=$value ;;
      idle_prov) idle_prov=$value ;;
      active_recent_ua) active_recent_ua=$value ;;
      active_recent_ms) active_recent_ms=$value ;;
      idle_recent_ua) idle_recent_ua=$value ;;
      idle_recent_ms) idle_recent_ms=$value ;;
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
  valid_bool "$monitor_enabled" || monitor_enabled=1
  valid_generation "$generation" || generation=0
  valid_time "$reset_time" || reset_time=0
  valid_duration "$cycle_id" || cycle_id=0
  case "$cycle_state" in discharging|charging|none) ;; *) cycle_state=none ;; esac
  case "$cycle_boot" in *[!0-9a-fA-F-]*) cycle_boot= ;; esac
  [ "${#cycle_boot}" -le 64 ] || cycle_boot=
  valid_duration "$active_charge" || active_charge=0
  valid_duration "$active_ms" || active_ms=0
  valid_duration "$active_unmeasured" || active_unmeasured=0
  valid_duration "$idle_charge" || idle_charge=0
  valid_duration "$idle_ms" || idle_ms=0
  valid_duration "$idle_unmeasured" || idle_unmeasured=0
  valid_duration "$active_recent_ms" || active_recent_ms=0
  valid_duration "$idle_recent_ms" || idle_recent_ms=0
  valid_bool "$active_prov" || active_prov=0
  valid_bool "$idle_prov" || idle_prov=0
  case "$active_recent_ua" in *[!0-9]*) active_recent_ua= ;; esac
  case "$idle_recent_ua" in *[!0-9]*) idle_recent_ua= ;; esac
  [ "${#active_recent_ua}" -le 12 ] || active_recent_ua=
  [ "${#idle_recent_ua}" -le 12 ] || idle_recent_ua=
  # Unmeasured time can never exceed the time it is part of.
  [ "$active_unmeasured" -le "$active_ms" ] || active_unmeasured=$active_ms
  [ "$idle_unmeasured" -le "$idle_ms" ] || idle_unmeasured=$idle_ms
}
write_cache() {
  [ ! -L "$CACHE_FILE" ] || return 1
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  tmp="$CACHE_FILE.tmp.$$"
  (umask 077; {
    printf 'monitor_enabled=%s\ngeneration=%s\nreset_time=%s\n' "$monitor_enabled" "$generation" "$reset_time"
    printf 'cycle_id=%s\ncycle_state=%s\ncycle_boot=%s\n' "$cycle_id" "$cycle_state" "$cycle_boot"
    printf 'active_charge=%s\nactive_ms=%s\nactive_unmeasured=%s\nactive_prov=%s\n' "$active_charge" "$active_ms" "$active_unmeasured" "$active_prov"
    printf 'idle_charge=%s\nidle_ms=%s\nidle_unmeasured=%s\nidle_prov=%s\n' "$idle_charge" "$idle_ms" "$idle_unmeasured" "$idle_prov"
    printf 'active_recent_ua=%s\nactive_recent_ms=%s\nidle_recent_ua=%s\nidle_recent_ms=%s\n' "$active_recent_ua" "$active_recent_ms" "$idle_recent_ua" "$idle_recent_ms"
  } > "$tmp") || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CACHE_FILE" || { rm -f "$tmp"; return 1; }
}
proc_start_time() {
  [ "$#" -eq 1 ] || return 1
  _stat=$(cat "$PROC_DIR/$1/stat" 2>/dev/null) || return 1
  # Strip pid and parenthesized comm (which itself can contain spaces or parentheses). The remaining
  # first field is stat field 3 (state), so field 20 in this list is process start time (stat field 22).
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
acquire_lock() {
  _tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _state=$(lock_owner_state "$LOCK_DIR")
    # A reclaim guard is held for a fraction of a second. One still present after 2.5 seconds was left by a
    # reclaimer that died, and it must be cleared whether the lock looks stale or unidentified: otherwise every
    # reclaim attempt backs off at the guard and the lock can never be cleared (the guard lives in the data
    # folder, so this would also survive a reboot).
    if [ "$_tries" -eq 25 ] && [ "$_state" != live ]; then rmdir "$LOCK_DIR.reclaim" 2>/dev/null || :; fi
    case "$_state" in
      stale) reclaim_lock "$LOCK_DIR" stale ;;
      unknown)
        # Legacy/incomplete locks have no trustworthy identity. Give their creator time to finish
        # writing metadata; after about 3 seconds treat the lock as abandoned. A verified live owner
        # is never evicted merely because a slow device took longer than expected.
        if [ "$_tries" -eq 30 ]; then reclaim_lock "$LOCK_DIR" unknown; fi
        ;;
      live) ;;
    esac
    _tries=$((_tries + 1))
    [ "$_tries" -lt 50 ] || return 1
    sleep 0.1
  done
  write_lock_owner "$LOCK_DIR" || { rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || :; return 1; }
}
release_lock() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  _owner=
  [ -r "$LOCK_DIR/pid" ] && IFS= read -r _owner < "$LOCK_DIR/pid"
  [ "$_owner" = "$$" ] || return 0
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null
}

zero_active() { active_charge=0; active_ms=0; active_unmeasured=0; active_prov=0; active_recent_ua=; active_recent_ms=0; }
zero_idle() { idle_charge=0; idle_ms=0; idle_unmeasured=0; idle_prov=0; idle_recent_ua=; idle_recent_ms=0; }

case "$MODE" in
  get)
    load_cache
    printf 'monitor_enabled=%s\ngeneration=%s\nreset_time=%s\n' "$monitor_enabled" "$generation" "$reset_time"
    printf 'cycle_id=%s\ncycle_state=%s\ncycle_boot=%s\n' "$cycle_id" "$cycle_state" "$cycle_boot"
    printf 'active_charge=%s\nactive_ms=%s\nactive_unmeasured=%s\nactive_prov=%s\n' "$active_charge" "$active_ms" "$active_unmeasured" "$active_prov"
    printf 'idle_charge=%s\nidle_ms=%s\nidle_unmeasured=%s\nidle_prov=%s\n' "$idle_charge" "$idle_ms" "$idle_unmeasured" "$idle_prov"
    printf 'active_recent_ua=%s\nactive_recent_ms=%s\nidle_recent_ua=%s\nidle_recent_ms=%s\n' "$active_recent_ua" "$active_recent_ms" "$idle_recent_ua" "$idle_recent_ms"
    ;;
  set-enabled)
    [ "$#" -eq 2 ] && valid_bool "$2" || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache; monitor_enabled=$2; write_cache
    ;;
  set-cycle)
    # set-cycle GENERATION key=value ... : the collector's whole cycle record in one atomic, validated write.
    # A write made under an older generation (a reset happened meanwhile) is refused with status 3.
    [ "$#" -ge 3 ] || exit 2
    expected_generation=$2
    valid_generation "$expected_generation" || exit 2
    shift 2
    # Validate every pair before touching the cache.
    for _pair in "$@"; do
      _k=${_pair%%=*}; _v=${_pair#*=}
      case "$_k" in
        cycle_id|active_charge|active_ms|active_unmeasured|idle_charge|idle_ms|idle_unmeasured|active_recent_ms|idle_recent_ms)
          valid_duration "$_v" || exit 2 ;;
        active_prov|idle_prov) valid_bool "$_v" || exit 2 ;;
        cycle_state) case "$_v" in discharging|charging|none) ;; *) exit 2 ;; esac ;;
        cycle_boot) case "$_v" in *[!0-9a-fA-F-]*) exit 2 ;; esac; [ "${#_v}" -le 64 ] || exit 2 ;;
        active_recent_ua|idle_recent_ua) case "$_v" in *[!0-9]*) exit 2 ;; esac; [ "${#_v}" -le 12 ] || exit 2 ;;
        *) exit 2 ;;
      esac
    done
    acquire_lock || exit 1
    trap release_lock EXIT
    load_cache
    [ "$expected_generation" = "$generation" ] || exit 3
    for _pair in "$@"; do
      _k=${_pair%%=*}; _v=${_pair#*=}
      case "$_k" in
        cycle_id) cycle_id=$_v ;;
        cycle_state) cycle_state=$_v ;;
        cycle_boot) cycle_boot=$_v ;;
        active_charge) active_charge=$_v ;;
        active_ms) active_ms=$_v ;;
        active_unmeasured) active_unmeasured=$_v ;;
        active_prov) active_prov=$_v ;;
        idle_charge) idle_charge=$_v ;;
        idle_ms) idle_ms=$_v ;;
        idle_unmeasured) idle_unmeasured=$_v ;;
        idle_prov) idle_prov=$_v ;;
        active_recent_ua) active_recent_ua=$_v ;;
        active_recent_ms) active_recent_ms=$_v ;;
        idle_recent_ua) idle_recent_ua=$_v ;;
        idle_recent_ms) idle_recent_ms=$_v ;;
      esac
    done
    # Re-apply the consistency rules (unmeasured time cannot exceed its state's time) before saving.
    [ "$active_unmeasured" -le "$active_ms" ] || exit 2
    [ "$idle_unmeasured" -le "$idle_ms" ] || exit 2
    write_cache
    ;;
  reset-screen-on-time)
    [ "$#" -eq 1 ] || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache
    # Screen-on time and the active charge it divides restart together so Active Drain stays consistent.
    # Idle (screen-off) totals are preserved. The new generation makes the collector drop any in-flight state.
    zero_active
    generation=$((generation + 1))
    reset_time="$(date +%s)000"
    write_cache || exit 1
    ;;
  reset-data)
    [ "$#" -eq 1 ] || exit 2
    acquire_lock || exit 1; trap release_lock EXIT
    load_cache
    zero_active; zero_idle
    generation=$((generation + 1))
    reset_time="$(date +%s)000"
    write_cache || exit 1
    ;;
  *)
    echo 'usage: monitor-cache.sh get | set-enabled 0|1 | set-cycle GENERATION key=value... | reset-screen-on-time | reset-data' >&2
    exit 2
    ;;
esac
