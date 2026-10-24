#!/system/bin/sh
# Frequency limits for the CPU clusters and the GPU, with separate screen-on and
# screen-off sets, presets and custom values.
#
# Safety rules built in:
#  * only values from the phone's own "available frequencies" lists are accepted
#  * only nodes the user explicitly set are ever written (nothing else is touched)
#  * the phone's own values are saved at boot and restored by "Stock" / disable
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
CFG_DIR="${CFG_DIR:-/data/adb/kprofiles_ui}"
CFG="$CFG_DIR/tune.conf"
DEF="$CFG_DIR/defaults"
APPLIED="$CFG_DIR/applied"
PIDF="$CFG_DIR/daemon.pid"
CPUFREQ="${CPUFREQ_DIR:-/sys/devices/system/cpu/cpufreq}"
GPUDIR="${GPU_DIR:-/sys/class/kgsl/kgsl-3d0/devfreq}"
BL="${BL_PATH:-/sys/class/backlight/panel0-backlight/brightness}"
KPNODE="${KP_PATH:-/sys/kernel/kprofiles/kp_mode}"   # read only here; kp.sh is the only writer
POLL_ON="${TUNE_POLL_ON:-3}"       # seconds between checks while the screen is on
POLL_OFF="${TUNE_POLL_OFF:-1}"     # seconds between checks while the screen is off
REASSERT_EVERY="${TUNE_REASSERT:-10}"
CLUSTERS="little big prime gpu"

upper() {
  case "$1" in
    little) echo LITTLE ;; big) echo BIG ;; prime) echo PRIME ;; gpu) echo GPU ;;
    min) echo MIN ;; max) echo MAX ;; on) echo ON ;; off) echo OFF ;; none) echo NONE ;;
  esac
}

lower() { case "$1" in LITTLE) echo little ;; BIG) echo big ;; PRIME) echo prime ;; GPU) echo gpu ;; esac; }

dom_dir() {
  case "$1" in
    little) echo "$CPUFREQ/policy0" ;; big) echo "$CPUFREQ/policy3" ;;
    prime) echo "$CPUFREQ/policy7" ;; gpu) echo "$GPUDIR" ;;
  esac
}
node() { d=$(dom_dir "$1"); if [ "$1" = gpu ]; then echo "$d/${2}_freq"; else echo "$d/scaling_${2}_freq"; fi; }
avail_node() { d=$(dom_dir "$1"); if [ "$1" = gpu ]; then echo "$d/available_frequencies"; else echo "$d/scaling_available_frequencies"; fi; }
rd() { cat "$1" 2>/dev/null; }
wr() { { echo "$2" > "$1"; } 2>/dev/null; }

# ---------- config ----------
load_cfg() { ENABLED=0; SCREENOFF=1; PRESET=stock; [ -f "$CFG" ] && . "$CFG"; return 0; }
cfg_put() {
  mkdir -p "$CFG_DIR" 2>/dev/null; touch "$CFG"
  grep -v "^$1=" "$CFG" > "$CFG.tmp" 2>/dev/null
  echo "$1=$2" >> "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
}
parse_key() {
  case "$1" in ON_*) PK_S=ON; r=${1#ON_} ;; OFF_*) PK_S=OFF; r=${1#OFF_} ;; *) return 1 ;; esac
  case "$r" in
    LITTLE_MIN) PK_c=little; PK_K=MIN ;; LITTLE_MAX) PK_c=little; PK_K=MAX ;;
    BIG_MIN) PK_c=big; PK_K=MIN ;;       BIG_MAX) PK_c=big; PK_K=MAX ;;
    PRIME_MIN) PK_c=prime; PK_K=MIN ;;   PRIME_MAX) PK_c=prime; PK_K=MAX ;;
    GPU_MIN) PK_c=gpu; PK_K=MIN ;;       GPU_MAX) PK_c=gpu; PK_K=MAX ;;
    *) return 1 ;;
  esac
  PK_C=$(upper "$PK_c")
  return 0
}
list_has() { for f in $(rd "$(avail_node "$1")"); do [ "$f" = "$2" ] && return 0; done; return 1; }

# ---------- a small log (kept short) ----------
log_msg() {
  LOG_LINE="$(date '+%F %T' 2>/dev/null) $1"
  LOGF="$CFG_DIR/tune.log"; mkdir -p "$CFG_DIR" 2>/dev/null
  echo "$LOG_LINE" >> "$LOGF" 2>/dev/null
  if [ "$(wc -l < "$LOGF" 2>/dev/null | tr -d ' ')" -gt 50 ] 2>/dev/null; then
    tail -n 25 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv "$LOGF.tmp" "$LOGF"
  fi
  return 0
}

# ---------- the phone's own values ----------
capture_defaults() {
  CAP_BAD=""
  if [ "$1" != force ]; then
    [ -f "$DEF" ] && return 0                    # already recorded
    [ -s "$APPLIED" ] && return 0                # our own limits are in place: would record them as stock
  fi
  # The kernel Battery profile lowers the values we read, so a reading taken now is not stock.
  # This holds for the forced boot-time capture too: keep whatever was recorded before, or nothing.
  [ "$(rd "$KPNODE")" = 1 ] && return 0
  mkdir -p "$CFG_DIR" 2>/dev/null
  : > "$DEF.tmp"
  for c in $CLUSTERS; do for k in min max; do
    cn=$(node $c $k)
    v=$(rd "$cn")
    case "$v" in
      "") [ -e "$cn" ] && CAP_BAD="$CAP_BAD ${c}_${k}" ;;      # the node exists but gave no reading
      *[!0-9]*) CAP_BAD="$CAP_BAD ${c}_${k}" ;;                # not a plain number
      *[!0]*) echo "${c}_${k}=$v" >> "$DEF.tmp" ;;             # a positive number
      *) CAP_BAD="$CAP_BAD ${c}_${k}" ;;                       # all zeros: not a frequency
    esac
  done; done
  if [ -n "$CAP_BAD" ]; then
    # An incomplete reading must never replace a saved snapshot. With nothing saved yet the readable
    # values are still better than none, so they are kept.
    log_msg "could not read:$CAP_BAD"
    if [ -s "$DEF" ]; then rm -f "$DEF.tmp"; return 0; fi
  fi
  mv "$DEF.tmp" "$DEF"
}
def_of() { sed -n "s/^$1=//p" "$DEF" 2>/dev/null | head -n 1; }

# ---------- bookkeeping of what we changed ----------
is_applied() { grep -qx "$1" "$APPLIED" 2>/dev/null; }
mark_applied() { mkdir -p "$CFG_DIR" 2>/dev/null; is_applied "$1" || echo "$1" >> "$APPLIED"; }
unmark_applied() { grep -vx "$1" "$APPLIED" > "$APPLIED.tmp" 2>/dev/null; mv "$APPLIED.tmp" "$APPLIED" 2>/dev/null; }

# ---------- applying ----------
apply_domain() { # cluster state(on|off|none)
  ad_c=$1; ad_S=$(upper "$2"); ad_C=$(upper "$1")
  eval "ad_wmin=\${${ad_S}_${ad_C}_MIN:-}"
  eval "ad_wmax=\${${ad_S}_${ad_C}_MAX:-}"
  ad_dmin=$ad_wmin; ad_dmax=$ad_wmax; ad_rmin=""; ad_rmax=""
  if [ -z "$ad_dmin" ] && is_applied "${ad_c}_min"; then ad_dmin=$(def_of "${ad_c}_min"); ad_rmin=1; fi
  if [ -z "$ad_dmax" ] && is_applied "${ad_c}_max"; then ad_dmax=$(def_of "${ad_c}_max"); ad_rmax=1; fi
  [ -z "$ad_dmin$ad_dmax" ] && return 0
  ad_pmin=$(node "$ad_c" min); ad_pmax=$(node "$ad_c" max)
  [ -e "$ad_pmax" ] || { echo "warn: $ad_c controls not found on this phone"; return 0; }
  ad_curmin=$(rd "$ad_pmin"); ad_curmax=$(rd "$ad_pmax")
  # keep min <= max
  if [ -z "$ad_dmin" ] && [ -n "$ad_dmax" ] && [ -n "$ad_curmin" ] && [ "$ad_curmin" -gt "$ad_dmax" ]; then ad_dmin=$ad_dmax; ad_rmin=""; fi
  if [ -z "$ad_dmax" ] && [ -n "$ad_dmin" ] && [ -n "$ad_curmax" ] && [ "$ad_curmax" -lt "$ad_dmin" ]; then ad_dmax=$ad_dmin; ad_rmax=""; fi
  if [ -n "$ad_dmin" ] && [ -n "$ad_dmax" ] && [ "$ad_dmin" -gt "$ad_dmax" ]; then ad_dmin=$ad_dmax; fi
  # write min, then max, then min again (so the order never blocks a change)
  [ -n "$ad_dmin" ] && [ "$ad_curmin" != "$ad_dmin" ] && wr "$ad_pmin" "$ad_dmin"
  [ -n "$ad_dmax" ] && [ "$ad_curmax" != "$ad_dmax" ] && wr "$ad_pmax" "$ad_dmax"
  [ -n "$ad_dmin" ] && [ "$(rd "$ad_pmin")" != "$ad_dmin" ] && wr "$ad_pmin" "$ad_dmin"
  # check what the kernel really took
  ad_okmin=1; ad_okmax=1
  if [ -n "$ad_dmin" ] && [ "$(rd "$ad_pmin")" != "$ad_dmin" ]; then ad_okmin=""; echo "warn: $ad_c min wanted $ad_dmin, kernel says $(rd "$ad_pmin")"; fi
  if [ -n "$ad_dmax" ] && [ "$(rd "$ad_pmax")" != "$ad_dmax" ]; then ad_okmax=""; echo "warn: $ad_c max wanted $ad_dmax, kernel says $(rd "$ad_pmax")"; fi
  # Remember what we changed. A limit of ours is forgotten only once the phone's own value has been
  # verified back in place; a restore the kernel refused stays marked, so Stock or Apply can retry it.
  ad_note=""
  if [ -n "$ad_dmin" ]; then
    if [ -z "$ad_rmin" ]; then mark_applied "${ad_c}_min"
    elif [ -n "$ad_okmin" ]; then unmark_applied "${ad_c}_min"
    else ad_note="$ad_note ${ad_c}_min"; fi
  fi
  if [ -n "$ad_dmax" ]; then
    if [ -z "$ad_rmax" ]; then mark_applied "${ad_c}_max"
    elif [ -n "$ad_okmax" ]; then unmark_applied "${ad_c}_max"
    else ad_note="$ad_note ${ad_c}_max"; fi
  fi
  if [ -n "$ad_note" ]; then
    echo "warn: could not put the phone's own value back for:$ad_note; it stays marked as changed so a later Stock or Apply tries again"
    log_msg "restore refused by the kernel for:$ad_note (kept marked, will be retried)"
    return 1       # the restore is incomplete: callers must not treat it as done
  fi
  return 0
}
# Limits we changed whose original value was never recorded: Stock has nothing to put back for them.
# Nothing is guessed; the caller is told which ones.
warn_nodefault() {
  wn=""
  for c in $CLUSTERS; do for k in min max; do
    if is_applied "${c}_${k}" && [ -z "$(def_of "${c}_${k}")" ]; then wn="$wn ${c}_${k}"; fi
  done; done
  [ -z "$wn" ] || echo "warn: the phone's own value is not recorded for:$wn, so Stock cannot put it back until the next reboot"
  return 0
}
# The watcher hands limits back without a terminal: whatever apply_state says goes to the log.
apply_none_logged() {
  anl=$(apply_state none)
  [ -z "$anl" ] || log_msg "watcher $$: $(printf '%s' "$anl" | tr '\n' ';')"
  return 0
}
# Returns 1 when any restore of the phone's own value was refused by the kernel (the limit stays marked).
apply_state() { load_cfg; as_rc=0; for c in $CLUSTERS; do apply_domain "$c" "$1" || as_rc=1; done; return "$as_rc"; }

# scr_get sets ST (on|off) with shell built-ins only: the watcher calls it every second, and
# the old $(cat ...) started two extra processes each time.
scr_get() {
  ST=on
  if [ -r "$BL" ] && read -r sb 2>/dev/null < "$BL"; then
    [ "$sb" = 0 ] && ST=off
  fi
  return 0
}
screen_state() { scr_get; echo "$ST"; }
want_state() { load_cfg; if [ "$SCREENOFF" = 1 ]; then screen_state; else echo on; fi; }

# ---------- background watcher (switches sets when the screen turns on/off) ----------
daemon_alive() {
  [ -f "$PIDF" ] || return 1
  dp=$(cat "$PIDF" 2>/dev/null); [ -n "$dp" ] || return 1
  kill -0 "$dp" 2>/dev/null && grep -q "tune.sh" "/proc/$dp/cmdline" 2>/dev/null
}
tick() { sleep 0.1 2>/dev/null || sleep 1; }   # a tenth of a second where sleep allows it
# Start and stop take one lock, so two callers can never start, or stop, a watcher at the same time.
# The lock is a folder holding its owner's pid; a lock whose owner is gone is taken over.
LOCKD="$CFG_DIR/daemon.lock"
DLOG="${TUNE_DAEMON_LOG:-/dev/null}"       # where the watcher's own output goes (tests set this to see its errors)
LOCK_TRIES="${TUNE_LOCK_TRIES:-100}"     # about a tenth of a second each
START_TRIES="${TUNE_START_TRIES:-100}"   # how long start_daemon waits for the new watcher to appear (tenths of a second)
lock_take() {
  lk=0
  while ! mkdir "$LOCKD" 2>/dev/null; do
    lo=$(cat "$LOCKD/pid" 2>/dev/null)
    if [ -n "$lo" ] && ! kill -0 "$lo" 2>/dev/null; then rm -rf "$LOCKD"; continue; fi
    if [ -z "$lo" ] && [ "$lk" -ge 50 ]; then rm -rf "$LOCKD"; continue; fi   # no pid after ~5 s: the owner died before writing it
    lk=$((lk + 1)); [ "$lk" -lt "$LOCK_TRIES" ] || return 1
    tick
  done
  echo $$ > "$LOCKD/pid"
  return 0
}
# Only the process that wrote the pid removes the lock, so a late caller never frees a lock that someone
# else has taken over in the meantime.
lock_free() { [ "$(cat "$LOCKD/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKD"; return 0; }
abs_moddir() { ( cd "$MODDIR" 2>/dev/null && pwd ) || echo "$MODDIR"; }
start_daemon() {
  [ "$TUNE_NO_DAEMON" = 1 ] && return 0
  mkdir -p "$CFG_DIR" 2>/dev/null
  lock_take || { echo "error: another start or stop of the watcher is in progress, the watcher was not started"; return 1; }
  if ! daemon_alive; then
    md=$(abs_moddir)
    # The module folder is passed on explicitly: a script started by name alone has no folder in $0.
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$md/tune.sh" daemon "$md" >>"$DLOG" 2>&1 </dev/null &
    else
      nohup sh "$md/tune.sh" daemon "$md" >>"$DLOG" 2>&1 </dev/null &
    fi
    # Hold the lock until the new watcher has written its pid file, so the next caller sees it.
    i=0; while [ "$i" -lt "$START_TRIES" ] && ! daemon_alive; do tick; i=$((i + 1)); done
  fi
  sd_ok=0; daemon_alive && sd_ok=1
  lock_free
  if [ "$sd_ok" != 1 ]; then
    log_msg "watcher did not start (no pid file after the wait)"
    echo "error: the screen on/off watcher did not start"
    return 1
  fi
  return 0
}
# Stop the watcher and wait until it has really gone, so a new one can never be started while the
# old one is still on its way out. Only a process that daemon_alive recognises is signalled.
# Returns 1 (and says so) if the watcher is still running after the wait; its pid file is then kept.
stop_daemon() {
  mkdir -p "$CFG_DIR" 2>/dev/null
  lock_take || { echo "warn: another start or stop of the watcher is in progress"; return 1; }
  sd_rc=0
  if daemon_alive; then
    sdp=$dp
    kill "$sdp" 2>/dev/null
    i=0
    while kill -0 "$sdp" 2>/dev/null && [ "$i" -lt 30 ]; do
      sleep 0.1 2>/dev/null || { sleep 1; i=$((i + 9)); }
      i=$((i + 1))
    done
    if kill -0 "$sdp" 2>/dev/null; then
      echo "warn: the watcher (pid $sdp) did not stop within 3 seconds"; log_msg "watcher $sdp did not stop in time"
      sd_rc=1
    elif [ "$(cat "$PIDF" 2>/dev/null)" = "$sdp" ]; then
      rm -f "$PIDF"                          # only the file that still names the process we stopped
    fi
  else
    rm -f "$PIDF"                            # nothing recognisable is running: the file is stale
  fi
  lock_free
  return "$sd_rc"
}
# True while the pid file still names this very process. read is a built-in: no process is started.
owns_pidf() { wp=""; [ -r "$PIDF" ] && read -r wp 2>/dev/null < "$PIDF"; [ "$wp" = "$$" ]; }
# An exiting watcher removes the pid file only if it still names this very process.
pidf_release() { [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"; return 0; }
run_daemon() {
  # The module folder arrives as an argument. Without it a script started by name alone would look
  # for the disable / remove markers in the current folder.
  if [ -n "${1:-}" ] && [ -f "$1/tune.sh" ]; then MODDIR=$1; fi
  mkdir -p "$CFG_DIR" 2>/dev/null
  echo $$ > "$PIDF"
  sp=""
  trap 'kill "$sp" 2>/dev/null; pidf_release; exit 0' TERM INT
  last=""; n=0
  while :; do
    # Only the watcher the pid file names may act. One that lost the file (a wiped folder, a start
    # that raced another) leaves quietly, so two watchers can never fight over the limits: a second
    # one used to re-apply the caps right after the first had handed them back.
    owns_pidf || { log_msg "watcher $$ no longer owns the pid file, leaving"; exit 0; }
    load_cfg
    if [ "$ENABLED" != 1 ]; then apply_none_logged; break; fi
    # Disabling or removing a module in the manager only drops a marker file. Notice it here and
    # hand the limits back, instead of holding them until the next reboot.
    if [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
      log_msg "watcher $$: module disabled or removed, handing the limits back"
      apply_none_logged; break
    fi
    st=on
    if [ "$SCREENOFF" = 1 ]; then scr_get; st=$ST; fi
    if [ "$st" != "$last" ] || [ "$n" -ge "$REASSERT_EVERY" ]; then
      apply_state "$st" >/dev/null; last=$st; n=0
    fi
    n=$((n + 1))
    if [ "$st" = off ]; then nap=$POLL_OFF; else nap=$POLL_ON; fi
    sleep "$nap" & sp=$!       # wait, not a plain sleep: a stop signal is then handled at once
    wait "$sp"
  done
  pidf_release
}

# ---------- commands ----------
NORESTORE="error: some of the phone's own values could not be put back (see the warning above); your settings and the recorded values are kept, so Stock or Apply can try again"
NOSTOCK="warn: the phone's own limits are not recorded yet (the kernel Battery profile is on), so Stock cannot put them back until the next reboot"
cmd_apply() {
  ca_rc=0
  load_cfg
  if [ "$ENABLED" = 1 ]; then
    capture_defaults
    [ -f "$DEF" ] || echo "$NOSTOCK"
    if ! apply_state "$(want_state)"; then echo "$NORESTORE"; ca_rc=1; fi
    [ ! -f "$DEF" ] || warn_nodefault
    if ! start_daemon; then
      echo "error: your limits are applied for the current screen state, but the watcher that switches them when the screen turns on or off is not running"
      ca_rc=1
    fi
  else
    capture_defaults
    [ -f "$DEF" ] || [ ! -s "$APPLIED" ] || echo "$NOSTOCK"
    if ! stop_daemon; then
      echo "error: the watcher is still running and may apply the limits again; your settings are kept, try again or reboot"
      ca_rc=1
    fi
    if ! apply_state none; then echo "$NORESTORE"; ca_rc=1; fi
    [ ! -f "$DEF" ] || warn_nodefault
  fi
  return "$ca_rc"
}

cmd_cfg() { # KEY VALUE
  key="$1"; val="$2"
  case "$val" in default|-) val="" ;; esac
  case "$key" in
    ENABLED|SCREENOFF)
      case "$val" in 0|1) ;; *) echo "error: $key must be 0 or 1"; return 1 ;; esac
      cfg_put "$key" "$val"
      ;;
    *)
      parse_key "$key" || { echo "error: unknown setting $key"; return 1; }
      if [ -n "$val" ]; then
        case "$val" in *[!0-9]*) echo "error: value must be a number"; return 1 ;; esac
        list_has "$PK_c" "$val" || { echo "error: $val is not an available $PK_c frequency on this phone"; return 1; }
      fi
      load_cfg
      if [ "$PK_K" = MIN ]; then okn="${PK_S}_${PK_C}_MAX"; else okn="${PK_S}_${PK_C}_MIN"; fi
      eval "other=\${$okn:-}"
      if [ -n "$val" ] && [ -n "$other" ]; then
        if [ "$PK_K" = MIN ] && [ "$val" -gt "$other" ]; then echo "error: min must not be above max"; return 1; fi
        if [ "$PK_K" = MAX ] && [ "$val" -lt "$other" ]; then echo "error: max must not be below min"; return 1; fi
      fi
      cfg_put "$key" "$val"
      cfg_put PRESET custom
      ;;
  esac
  cmd_apply
}

preset_vals() {
  for s in ON OFF; do for c in LITTLE BIG PRIME GPU; do for k in MIN MAX; do eval "P_${s}_${c}_${k}="; done; done; done
  P_ENABLED=1; P_SCREENOFF=1
  case "$1" in
    stock) P_ENABLED=0 ;;
    tilt)  # balanced, tilted toward battery: light caps in use, strong caps with the screen off
      P_ON_BIG_MAX=2188800; P_ON_PRIME_MAX=2457600; P_ON_GPU_MAX=736000000
      P_OFF_LITTLE_MAX=1017600; P_OFF_BIG_MAX=787200; P_OFF_PRIME_MAX=633600; P_OFF_GPU_MAX=353000000 ;;
    saver) # noticeably slower in use, much cooler and longer lasting
      P_ON_LITTLE_MAX=1593600; P_ON_BIG_MAX=1593600; P_ON_PRIME_MAX=1766400; P_ON_GPU_MAX=633000000
      P_OFF_LITTLE_MAX=787200; P_OFF_BIG_MAX=633600; P_OFF_PRIME_MAX=633600; P_OFF_GPU_MAX=255000000 ;;
    *) return 1 ;;
  esac
}
cmd_preset() {
  preset_vals "$1" || { echo "error: unknown preset (use stock, tilt or saver)"; return 1; }
  mkdir -p "$CFG_DIR" 2>/dev/null
  { echo "ENABLED=$P_ENABLED"; echo "SCREENOFF=$P_SCREENOFF"; echo "PRESET=$1"; } > "$CFG.tmp"
  for s in ON OFF; do for c in LITTLE BIG PRIME GPU; do for k in MIN MAX; do
    eval "pv=\$P_${s}_${c}_${k}"
    if [ -n "$pv" ]; then
      pc=$(lower "$c"); pl=$(rd "$(avail_node "$pc")")
      if [ -n "$pl" ]; then
        if ! list_has "$pc" "$pv"; then
          echo "warn: preset value $pv is not available for $pc on this phone, skipped"; pv=""
        fi
      elif [ -e "$(node "$pc" max)" ]; then
        # the controls exist but the phone's list cannot be read: do not guess
        echo "warn: preset value $pv skipped for $pc because the phone's list of available frequencies could not be read"; pv=""
      fi
      # (controls missing altogether: keep the value, apply_domain reports "controls not found")
    fi
    echo "${s}_${c}_${k}=$pv" >> "$CFG.tmp"
  done; done; done
  mv "$CFG.tmp" "$CFG"
  cmd_apply
}

cmd_resetall() { # kernel profile back to None first (so nothing holds the limits down), then stock limits
  ra_rc=0
  if [ -e "$KPNODE" ]; then
    if ! ra_out=$(sh "$MODDIR/kp.sh" mode 0 2>&1); then
      ra_msg=$(printf '%s\n' "$ra_out" | head -n 1); ra_msg=${ra_msg#error: }
      echo "error: the kernel profile could not be set to None: ${ra_msg:-no answer from kp.sh}"; ra_rc=1
    fi
  fi
  cmd_preset stock || ra_rc=1
  return "$ra_rc"
}

cmd_boot() {
  rm -f "$APPLIED" "$PIDF" 2>/dev/null
  mkdir -p "$CFG_DIR" 2>/dev/null
  capture_defaults force
  [ -z "$CAP_BAD" ] || echo "warn: could not read these frequency values at boot:$CAP_BAD (an earlier record is kept if there is one)"
  load_cfg
  cb_rc=0
  if [ "$ENABLED" = 1 ]; then cmd_apply || cb_rc=1; fi
  if [ "$cb_rc" = 0 ]; then
    echo "boot done: enabled=$ENABLED preset=$PRESET"
  else
    echo "boot finished with errors: enabled=$ENABLED preset=$PRESET (see the messages above)"
    log_msg "boot finished with errors"
  fi
  return "$cb_rc"
}

cmd_lists() { for c in $CLUSTERS; do echo "$c=$(rd "$(avail_node $c)")"; done; }

cmd_status() {
  capture_defaults
  load_cfg
  echo "enabled=$ENABLED"; echo "screenoff=$SCREENOFF"; echo "preset=$PRESET"
  echo "screen=$(screen_state)"; echo "state=$(want_state)"; echo "bl=$(rd "$BL")"
  if daemon_alive; then echo "daemon=1"; else echo "daemon=0"; fi
  for s in on off; do for c in $CLUSTERS; do for k in min max; do
    sv=$(upper $s); cv=$(upper $c); kv=$(upper $k)
    eval "v=\${${sv}_${cv}_${kv}:-}"; echo "cfg_${s}_${c}_${k}=$v"
  done; done; done
  for c in $CLUSTERS; do for k in min max; do
    echo "cur_${c}_${k}=$(rd "$(node $c $k)")"; echo "def_${c}_${k}=$(def_of "${c}_${k}")"
  done; done
}

case "$1" in
  status|"") cmd_status ;;
  lists)     cmd_lists ;;
  cfg)       cmd_cfg "$2" "$3" && echo ok ;;
  preset)    cmd_preset "$2" && echo ok ;;
  resetall)  cmd_resetall && echo ok ;;
  apply)     cmd_apply && echo ok ;;
  boot)      cmd_boot ;;
  daemon)    run_daemon "$2" ;;
  stop)      # stops the watcher AND hands the limits back; ok only if both worked (uninstall relies on this)
             st_rc=0; st_msg=""
             stop_daemon || { st_rc=1; st_msg="the watcher did not stop"; }
             apply_state none || { st_rc=1; st_msg="${st_msg:+$st_msg; }the phone's own values could not all be put back"; }
             if [ "$st_rc" = 0 ]; then echo ok; else echo "error: $st_msg"; exit 1; fi ;;
  *) echo "usage: tune.sh status | lists | cfg KEY VALUE | preset stock|tilt|saver | resetall | apply | boot | stop"; exit 1 ;;
esac
