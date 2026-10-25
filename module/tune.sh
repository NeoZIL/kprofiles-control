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
# A settings file that exists but cannot be read, parsed, or validated is NOT the same as "no settings":
# CFG_BAD is set, safe defaults are loaded, and callers that would change anything refuse to go on.
# (The dot command aborts a whole script when its file cannot be read, so it is tried in a subshell first.)
cfg_reset() {
  ENABLED=0; SCREENOFF=1; PRESET=stock
  for cv_s in ON OFF; do for cv_c in LITTLE BIG PRIME GPU; do for cv_k in MIN MAX; do eval "${cv_s}_${cv_c}_${cv_k}="; done; done; done
}
cfg_values_valid() {
  case "$ENABLED" in 0|1) ;; *) return 1 ;; esac
  case "$SCREENOFF" in 0|1) ;; *) return 1 ;; esac
  case "$PRESET" in stock|tilt|saver|custom) ;; *) return 1 ;; esac
  for cv_s in ON OFF; do for cv_cu in LITTLE BIG PRIME GPU; do
    cv_c=$(lower "$cv_cu")
    eval "cv_min=\${${cv_s}_${cv_cu}_MIN:-}"; eval "cv_max=\${${cv_s}_${cv_cu}_MAX:-}"
    for cv_k in MIN MAX; do
      eval "cv_val=\${${cv_s}_${cv_cu}_${cv_k}:-}"
      [ -n "$cv_val" ] || continue
      case "$cv_val" in *[!0-9]*) return 1 ;; esac
      [ "$cv_val" -gt 0 ] 2>/dev/null || return 1
    done
    if [ -n "$cv_min" ] && [ -n "$cv_max" ] && [ "$cv_min" -gt "$cv_max" ] 2>/dev/null; then return 1; fi
  done; done
  return 0
}
# This checks the current kernel lists separately from basic config parsing. Status and Apply need the full
# check; the screen watcher does it only when reasserting/changing limits, not on every polling iteration.
cfg_values_available() {
  for cv_s in ON OFF; do for cv_cu in LITTLE BIG PRIME GPU; do
    cv_c=$(lower "$cv_cu")
    for cv_k in MIN MAX; do
      eval "cv_val=\${${cv_s}_${cv_cu}_${cv_k}:-}"
      [ -n "$cv_val" ] || continue
      if [ -e "$(node "$cv_c" max)" ]; then list_has "$cv_c" "$cv_val" || return 1; fi
    done
  done; done
  return 0
}
NOREAD="error: the saved settings at $CFG cannot be read or validated, so nothing was changed (set a preset to write them again)"
load_cfg() {
  cfg_reset; CFG_BAD=""
  if [ -e "$CFG" ]; then
    if [ -f "$CFG" ] && ( . "$CFG" ) >/dev/null 2>&1; then . "$CFG"; else CFG_BAD=1; fi
  fi
  if [ -z "$CFG_BAD" ] && ! cfg_values_valid; then CFG_BAD=1; fi
  [ -z "$CFG_BAD" ] || cfg_reset
  return 0
}
# cfg_put KEY VALUE [KEY VALUE ...]: saves one or more settings in ONE replace of the config file, or
# changes nothing. Fails (and removes its temporary file) if the folder cannot be made, the settings
# path is a folder, the temporary file cannot be written or it cannot be moved into place.
NOSAVE="error: could not save the settings to $CFG, so nothing was changed"
cfg_put() {
  [ $(($# % 2)) = 0 ] && [ "$#" -ge 2 ] || return 1
  mkdir -p "$CFG_DIR" 2>/dev/null || return 1
  [ ! -d "$CFG" ] || return 1
  cp_pat=""; cp_new=""
  while [ "$#" -ge 2 ]; do
    cp_pat="$cp_pat -e ^$1="
    cp_new="$cp_new$1=$2
"
    shift 2
  done
  { printf "" > "$CFG.tmp"; } 2>/dev/null || return 1
  if [ -e "$CFG" ]; then
    # grep exits 0 (kept some lines) or 1 (kept none: fine); anything else means the old file could not
    # be read, and then it must not be replaced by a file holding only the new keys
    # shellcheck disable=SC2086
    grep -v $cp_pat "$CFG" > "$CFG.tmp" 2>/dev/null; cp_rc=$?
    [ "$cp_rc" -le 1 ] || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  fi
  { printf '%s' "$cp_new" >> "$CFG.tmp"; } 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  mv "$CFG.tmp" "$CFG" 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  return 0
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
# True only when the phone's list for this cluster can be read and holds exactly ONE frequency, a plain
# positive number: a cluster that really has a single speed (its minimum then equals its maximum). A list
# that is missing, empty, unreadable, malformed or longer is NOT that: it is "unknown" (or a normal
# cluster), and must never make a minimum that sits at its maximum look like the phone's own setting.
lone_freq() {
  lo_n=0; lo_v=""
  for lf in $(rd "$(avail_node "$1")"); do lo_n=$((lo_n + 1)); lo_v=$lf; done
  [ "$lo_n" = 1 ] || return 1
  case "$lo_v" in ""|*[!0-9]*) return 1 ;; esac
  [ "$lo_v" -gt 0 ] 2>/dev/null
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
# A usable stock record is a regular file with something in it. A zero-byte file is not one, and neither
# is a folder standing where the file should be (-s alone is true for a folder).
have_def() { [ -f "$DEF" ] && [ -s "$DEF" ]; }
capture_defaults() {
  CAP_BAD=""; CAP_PIN=""
  if [ "$1" != force ]; then
    have_def && return 0                          # already recorded (an empty file is not a record)
    # Our own limits are in place, so what the kernel shows now is NOT stock and must not be recorded as
    # such. Without a usable record this is a FAILURE (status 2), never a success: the caller must not
    # change any further limit that could not be put back. (Callers log it; this runs on every status poll.)
    [ -s "$APPLIED" ] && return 2
  fi
  # The kernel Battery profile lowers the values we read, so a reading taken now is not stock.
  # This holds for the forced boot-time capture too: keep whatever was recorded before, or nothing.
  if [ "$(rd "$KPNODE")" = 1 ]; then
    have_def && return 0                          # an earlier record exists and is kept untouched
    # Nothing is on record and this reading is not stock. At boot that is a failure to record the phone's
    # own limits (exit status 2 in cmd_boot, so service.sh does not apply the kernel profile); every other
    # caller keeps its old behaviour of carrying on without a record (and warning that there is none).
    if [ "$1" = force ]; then
      log_msg "boot: the kernel Battery profile is active and no earlier record exists, so nothing was recorded as stock"
      return 2
    fi
    return 0
  fi
  # Returns 2 when the snapshot could not be SAVED (a saved one is then left exactly as it was).
  cd_fail() { rm -f "$DEF.tmp" 2>/dev/null; log_msg "could not save the phone's own values"; return 2; }
  mkdir -p "$CFG_DIR" 2>/dev/null || { log_msg "could not save the phone's own values"; return 2; }
  [ ! -d "$DEF" ] || { log_msg "could not save the phone's own values"; return 2; }
  { printf "" > "$DEF.tmp"; } 2>/dev/null || { log_msg "could not save the phone's own values"; return 2; }
  for c in $CLUSTERS; do for k in min max; do
    cn=$(node $c $k)
    v=$(rd "$cn")
    case "$v" in
      "") [ -e "$cn" ] && CAP_BAD="$CAP_BAD ${c}_${k}" ;;      # the node exists but gave no reading
      *[!0-9]*) CAP_BAD="$CAP_BAD ${c}_${k}" ;;                # not a plain number
      *[!0]*) { echo "${c}_${k}=$v" >> "$DEF.tmp"; } 2>/dev/null || { cd_fail; return 2; } ;;   # a positive number
      *) CAP_BAD="$CAP_BAD ${c}_${k}" ;;                       # all zeros: not a frequency
    esac
  done; done
  # A minimum at or above its maximum is not the phone's own setting: something is holding that cluster
  # up (a boot boost, another module or app). It is never recorded as stock. Only a cluster that the
  # phone's own list shows to have exactly one frequency is exempt; an unreadable list does not count.
  for c in $CLUSTERS; do
    cp_min=$(sed -n "s/^${c}_min=//p" "$DEF.tmp" 2>/dev/null | head -n 1)
    cp_max=$(sed -n "s/^${c}_max=//p" "$DEF.tmp" 2>/dev/null | head -n 1)
    if [ -n "$cp_min" ] && [ -n "$cp_max" ] && [ "$cp_min" -ge "$cp_max" ] && ! lone_freq "$c"; then
      CAP_PIN="$CAP_PIN $c"
      grep -v "^${c}_min=" "$DEF.tmp" > "$DEF.tmp2" 2>/dev/null
      { [ $? -le 1 ] && mv "$DEF.tmp2" "$DEF.tmp"; } 2>/dev/null || { rm -f "$DEF.tmp2" 2>/dev/null; cd_fail; return 2; }
    fi
  done
  if [ -n "$CAP_BAD$CAP_PIN" ]; then
    # An incomplete or pinned reading must never replace a saved snapshot. With nothing saved yet the
    # readable values are still better than none, so they are kept.
    [ -z "$CAP_BAD" ] || log_msg "could not read:$CAP_BAD"
    [ -z "$CAP_PIN" ] || log_msg "minimum at or above maximum, not recorded as stock for:$CAP_PIN"
    if have_def; then rm -f "$DEF.tmp"; return 0; fi
  fi
  # An empty snapshot cannot be used to put the phone's own limits back, and it must never count as one.
  if [ ! -s "$DEF.tmp" ]; then
    rm -f "$DEF.tmp" 2>/dev/null
    if have_def; then
      log_msg "no usable frequency values were read; the earlier stock record is kept"
      return 0
    fi
    [ ! -f "$DEF" ] || [ -s "$DEF" ] || rm -f "$DEF" 2>/dev/null     # drop a stale zero-byte file
    log_msg "no usable frequency values were read; no stock record exists"
    return 2
  fi
  mv "$DEF.tmp" "$DEF" 2>/dev/null || { cd_fail; return 2; }
  return 0
}
def_of() {
  df_v=$(sed -n "s/^$1=//p" "$DEF" 2>/dev/null | head -n 1)
  case "$1" in
    *_min)
      df_c=${1%_min}; df_x=$(sed -n "s/^${df_c}_max=//p" "$DEF" 2>/dev/null | head -n 1)
      # A recorded minimum at or above its maximum is a pinned reading, never the phone's own setting:
      # writing it back would pin the cluster at its top speed. Treat it as not recorded (unless the
      # phone's list shows a single frequency; a missing list is unknown, not proof of that).
      if [ -n "$df_v" ] && [ -n "$df_x" ] && [ "$df_v" -ge "$df_x" ] && ! lone_freq "$df_c"; then df_v=""; fi ;;
  esac
  echo "$df_v"
}

# ---------- bookkeeping of what we changed ----------
is_applied() { grep -qx "$1" "$APPLIED" 2>/dev/null; }
# mark_applied fails (returns 1) unless the marker is really on file afterwards.
mark_applied() {
  mkdir -p "$CFG_DIR" 2>/dev/null || return 1
  is_applied "$1" && return 0
  { echo "$1" >> "$APPLIED"; } 2>/dev/null || return 1
  is_applied "$1"
}
# unmark_applied fails unless the marker is really gone afterwards. A marker that stays is the safe
# direction (the limit is simply checked again next time), so callers only warn about it.
unmark_applied() {
  [ -e "$APPLIED" ] || return 0
  { printf "" > "$APPLIED.tmp"; } 2>/dev/null || return 1
  grep -vx "$1" "$APPLIED" > "$APPLIED.tmp" 2>/dev/null; um_rc=$?
  [ "$um_rc" -le 1 ] || { rm -f "$APPLIED.tmp" 2>/dev/null; return 1; }
  mv "$APPLIED.tmp" "$APPLIED" 2>/dev/null || { rm -f "$APPLIED.tmp" 2>/dev/null; return 1; }
  ! is_applied "$1"
}

# ---------- applying ----------
apply_domain() { # cluster state(on|off|none)
  AD_REJ=""; AD_NOREST=""
  ad_c=$1; ad_S=$(upper "$2"); ad_C=$(upper "$1")
  eval "ad_wmin=\${${ad_S}_${ad_C}_MIN:-}"
  eval "ad_wmax=\${${ad_S}_${ad_C}_MAX:-}"
  ad_dmin=$ad_wmin; ad_dmax=$ad_wmax; ad_rmin=""; ad_rmax=""
  ad_nodef=""
  if [ -z "$ad_dmin" ] && is_applied "${ad_c}_min"; then
    ad_dmin=$(def_of "${ad_c}_min"); ad_rmin=1; [ -n "$ad_dmin" ] || ad_nodef="$ad_nodef ${ad_c}_min"
  fi
  if [ -z "$ad_dmax" ] && is_applied "${ad_c}_max"; then
    ad_dmax=$(def_of "${ad_c}_max"); ad_rmax=1; [ -n "$ad_dmax" ] || ad_nodef="$ad_nodef ${ad_c}_max"
  fi
  if [ -z "$ad_dmin$ad_dmax" ]; then
    # Nothing to write. If a limit of ours has no recorded original value it can NOT be put back: that
    # is a failed restore (it stays marked), never a silent success.
    [ -z "$ad_nodef" ] && return 0
    log_msg "no recorded original value for:$ad_nodef (kept marked)"
    AD_NOREST=$ad_nodef
    return 1
  fi
  ad_pmin=$(node "$ad_c" min); ad_pmax=$(node "$ad_c" max)
  AD_REJ=""; AD_NOREST=""
  # A control that is gone although this module changed it earlier can NOT be put back: that is a failed
  # restore (the limit stays marked and nothing recorded is deleted), never "not found, fine". Hardware
  # that was never changed by us and is simply absent is still not a failure.
  ad_gone=""
  if is_applied "${ad_c}_min" && [ ! -e "$ad_pmin" ]; then ad_gone="$ad_gone ${ad_c}_min"; fi
  if is_applied "${ad_c}_max" && [ ! -e "$ad_pmax" ]; then ad_gone="$ad_gone ${ad_c}_max"; fi
  if [ -n "$ad_gone" ]; then
    echo "warn: the $ad_c controls are gone, but this module changed:$ad_gone earlier, so the phone's own value could not be put back; it stays marked as changed"
    log_msg "controls missing for marked limit:$ad_gone (kept marked)"
    AD_NOREST=$ad_gone
    return 1
  fi
  [ -e "$ad_pmax" ] || { echo "warn: $ad_c controls not found on this phone"; return 0; }
  ad_curmin=$(rd "$ad_pmin"); ad_curmax=$(rd "$ad_pmax")
  # keep min <= max
  if [ -z "$ad_dmin" ] && [ -n "$ad_dmax" ] && [ -n "$ad_curmin" ] && [ "$ad_curmin" -gt "$ad_dmax" ]; then ad_dmin=$ad_dmax; ad_rmin=""; fi
  if [ -z "$ad_dmax" ] && [ -n "$ad_dmin" ] && [ -n "$ad_curmax" ] && [ "$ad_curmax" -lt "$ad_dmin" ]; then ad_dmax=$ad_dmin; ad_rmax=""; fi
  # (a minimum clamped to the new maximum is no longer the phone's own value, so it stays marked as ours)
  if [ -n "$ad_dmin" ] && [ -n "$ad_dmax" ] && [ "$ad_dmin" -gt "$ad_dmax" ]; then ad_dmin=$ad_dmax; ad_rmin=""; fi
  # A limit is recorded as ours BEFORE it is changed: if the record cannot be saved, the limit is left alone.
  if [ -n "$ad_dmin" ] && [ -z "$ad_rmin" ] && ! mark_applied "${ad_c}_min"; then
    echo "error: could not save the record of the $ad_c min limit, so it was not changed"; log_msg "marker write failed for ${ad_c}_min"; return 1
  fi
  if [ -n "$ad_dmax" ] && [ -z "$ad_rmax" ] && ! mark_applied "${ad_c}_max"; then
    echo "error: could not save the record of the $ad_c max limit, so it was not changed"; log_msg "marker write failed for ${ad_c}_max"; return 1
  fi
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
  if [ -n "$ad_dmin" ] && [ -n "$ad_rmin" ]; then
    if [ -n "$ad_okmin" ]; then
      unmark_applied "${ad_c}_min" || { echo "warn: ${ad_c}_min is back, but its changed-marker could not be cleared; it will be checked again next time"; log_msg "marker not cleared for ${ad_c}_min"; }
    else ad_note="$ad_note ${ad_c}_min"; fi
  fi
  if [ -n "$ad_dmax" ] && [ -n "$ad_rmax" ]; then
    if [ -n "$ad_okmax" ]; then
      unmark_applied "${ad_c}_max" || { echo "warn: ${ad_c}_max is back, but its changed-marker could not be cleared; it will be checked again next time"; log_msg "marker not cleared for ${ad_c}_max"; }
    else ad_note="$ad_note ${ad_c}_max"; fi
  fi
  if [ -n "$ad_nodef" ]; then
    log_msg "no recorded original value for:$ad_nodef (kept marked)"
  fi
  # A limit that was REQUESTED (not a restore) and that the kernel did not take is a failure too: the
  # command must not say ok while a limit the person asked for is not in place.
  ad_rej=""
  if [ -n "$ad_dmin" ] && [ -z "$ad_rmin" ] && [ -z "$ad_okmin" ]; then ad_rej="$ad_rej ${ad_c}_min"; fi
  if [ -n "$ad_dmax" ] && [ -z "$ad_rmax" ] && [ -z "$ad_okmax" ]; then ad_rej="$ad_rej ${ad_c}_max"; fi
  if [ -n "$ad_rej" ]; then log_msg "kernel did not take the requested limit for:$ad_rej"; fi
  AD_REJ=$ad_rej; AD_NOREST="$ad_note$ad_nodef"
  if [ -n "$ad_note" ]; then
    echo "warn: could not put the phone's own value back for:$ad_note; it stays marked as changed so a later Stock or Apply tries again"
    log_msg "restore refused by the kernel for:$ad_note (kept marked, will be retried)"
    return 1       # the restore is incomplete: callers must not treat it as done
  fi
  [ -z "$ad_nodef" ] || return 1     # a limit with no recorded original value was left as it is
  [ -z "$ad_rej" ] || return 1       # a requested limit is not in place
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
# AS_REJ lists requested limits the kernel did not take, AS_NOREST limits that could not be put back.
apply_state() {
  load_cfg; as_rc=0; AS_REJ=""; AS_NOREST=""
  for c in $CLUSTERS; do
    AD_REJ=""; AD_NOREST=""
    apply_domain "$c" "$1" || as_rc=1
    AS_REJ="$AS_REJ$AD_REJ"; AS_NOREST="$AS_NOREST$AD_NOREST"
  done
  return "$as_rc"
}

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
  kill -0 "$dp" 2>/dev/null || return 1
  # Match the script path, daemon argument, and module folder for THIS module. Do not match only the
  # basename: another module can also run tune.sh, and a reused PID must never be signalled by Stop.
  md=$(abs_moddir)
  dcmd=$({ tr '\0' '\n' < "/proc/$dp/cmdline"; } 2>/dev/null) || return 1
  # argv[0] varies by shell (sh, dash, mksh, or an Android shell path); the remaining three arguments
  # are the identity we control: this exact tune.sh, the word daemon, and this exact module folder.
  dargs=$(printf '%s\n' "$dcmd" | sed '1d')
  expected=$(printf '%s/tune.sh\ndaemon\n%s' "$md" "$md")
  [ "$dargs" = "$expected" ] && return 0
  return 1
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
    # Every pass is counted, including the ones that remove a stale lock: if the removal fails, the loop
    # still ends after LOCK_TRIES passes instead of spinning for ever.
    lk=$((lk + 1))
    if [ -n "$lo" ] && ! kill -0 "$lo" 2>/dev/null; then rm -rf "$LOCKD" 2>/dev/null; [ "$lk" -lt "$LOCK_TRIES" ] || return 1; continue; fi
    if [ -z "$lo" ] && [ "$lk" -gt 50 ]; then rm -rf "$LOCKD" 2>/dev/null; [ "$lk" -lt "$LOCK_TRIES" ] || return 1; continue; fi   # no pid after ~5 s: the owner died before writing it
    [ "$lk" -lt "$LOCK_TRIES" ] || return 1
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
    [ -z "$CFG_BAD" ] || log_msg "watcher $$: the saved settings cannot be read, handing the limits back"
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
      if ! have_def && [ -s "$APPLIED" ]; then
        # Limits of this module are in place but the phone's own values are not on record: changing more
        # limits now would be changes that can never be put back. Leave everything as it is.
        [ -n "$dg_logged" ] || log_msg "watcher $$: no usable record of the phone's own values while limits are in place, not changing any more limits"
        dg_logged=1; n=0
      else
        if ! cfg_values_available; then
          log_msg "watcher $$: a saved frequency is not available on this phone, handing the limits back"
          apply_none_logged; break
        fi
        dg_logged=""; apply_state "$st" >/dev/null; last=$st; n=0
      fi
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
# One message per kind of failure, so a rejected limit is never reported as a failed restore or the other way round.
report_apply_failure() {
  if [ -n "$AS_NOREST" ]; then echo "$NORESTORE"; fi
  if [ -n "$AS_REJ" ]; then
    echo "error: the kernel did not take these limits:$AS_REJ (see the warnings above); the other limits are in place, so the phone is only partly set up. Try again, or choose Stock"
  fi
  if [ -z "$AS_NOREST$AS_REJ" ]; then echo "error: not every limit could be applied (see the messages above)"; fi
}
NOSTOCK="warn: the phone's own limits are not recorded yet (for example because the kernel Battery profile was on), so Stock cannot put them back until the next reboot"
cmd_apply() {
  ca_rc=0
  load_cfg
  [ -z "$CFG_BAD" ] || { echo "$NOREAD"; return 1; }
  if ! cfg_values_available; then
    CFG_BAD=1; cfg_reset
    log_msg "apply refused: a saved frequency is not available on this phone"
    echo "$NOREAD"; return 1
  fi
  if [ "$ENABLED" = 1 ]; then
    capture_defaults; ca_cd=$?
    if [ "$ca_cd" != 0 ] && ! have_def; then
      if [ -s "$APPLIED" ]; then
        log_msg "apply refused: limits of this module are in place but no usable record of the phone's own values exists"
        echo "error: this module's limits are already in place but the phone's own limits are not on record, so no further limit was changed (a reboot records them again)"
      else
        echo "error: the phone's own limits could not be saved, so no limit was changed"
      fi
      return 1
    fi
    [ "$ca_cd" = 0 ] || echo "warn: the phone's own limits could not be saved again; the earlier record is kept"
    have_def || echo "$NOSTOCK"
    if ! apply_state "$(want_state)"; then report_apply_failure; ca_rc=1; fi
    ! have_def || warn_nodefault
    if ! start_daemon; then
      echo "error: your limits are applied for the current screen state, but the watcher that switches them when the screen turns on or off is not running"
      ca_rc=1
    fi
  else
    # (With limits of ours in place and no record there is nothing to capture; the line below says so.)
    if have_def || [ ! -s "$APPLIED" ]; then capture_defaults || echo "warn: the phone's own limits could not be saved"; fi
    have_def || [ ! -s "$APPLIED" ] || echo "$NOSTOCK"
    if ! stop_daemon; then
      echo "error: the watcher is still running and may apply the limits again; your settings are kept, try again or reboot"
      ca_rc=1
    fi
    if ! apply_state none; then report_apply_failure; ca_rc=1; fi
    ! have_def || warn_nodefault
  fi
  return "$ca_rc"
}

cmd_cfg() { # KEY VALUE
  key="$1"; val="$2"
  case "$val" in default|-) val="" ;; esac
  case "$key" in
    ENABLED|SCREENOFF)
      case "$val" in 0|1) ;; *) echo "error: $key must be 0 or 1"; return 1 ;; esac
      cfg_put "$key" "$val" || { echo "$NOSAVE"; return 1; }
      ;;
    *)
      parse_key "$key" || { echo "error: unknown setting $key"; return 1; }
      if [ -n "$val" ]; then
        case "$val" in *[!0-9]*) echo "error: value must be a number"; return 1 ;; esac
        list_has "$PK_c" "$val" || { echo "error: $val is not an available $PK_c frequency on this phone"; return 1; }
      fi
      load_cfg
      [ -z "$CFG_BAD" ] || { echo "$NOREAD"; return 1; }
      if [ "$PK_K" = MIN ]; then okn="${PK_S}_${PK_C}_MAX"; else okn="${PK_S}_${PK_C}_MIN"; fi
      eval "other=\${$okn:-}"
      if [ -n "$val" ] && [ -n "$other" ]; then
        if [ "$PK_K" = MIN ] && [ "$val" -gt "$other" ]; then echo "error: min must not be above max"; return 1; fi
        if [ "$PK_K" = MAX ] && [ "$val" -lt "$other" ]; then echo "error: max must not be below min"; return 1; fi
      fi
      cfg_put "$key" "$val" PRESET custom || { echo "$NOSAVE"; return 1; }   # one save: the value and the name together
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
  # the new settings are built in memory and written once, so a failed save leaves the old file alone
  pbody="ENABLED=$P_ENABLED
SCREENOFF=$P_SCREENOFF
PRESET=$1
"
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
    pbody="$pbody${s}_${c}_${k}=$pv
"
  done; done; done
  mkdir -p "$CFG_DIR" 2>/dev/null || { echo "$NOSAVE"; return 1; }
  [ ! -d "$CFG" ] || { echo "$NOSAVE"; return 1; }
  { printf '%s' "$pbody" > "$CFG.tmp"; } 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; echo "$NOSAVE"; return 1; }
  mv "$CFG.tmp" "$CFG" 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; echo "$NOSAVE"; return 1; }
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

BOOT_RETRIES="${TUNE_BOOT_RETRIES:-8}"   # how often boot looks again when a cluster's minimum is held at its maximum
BOOT_WAIT="${TUNE_BOOT_WAIT:-10}"        # seconds between those looks
cmd_boot() {
  rm -f "$APPLIED" "$PIDF" 2>/dev/null
  mkdir -p "$CFG_DIR" 2>/dev/null
  cb_rc=0; cb_try=0
  while :; do
    capture_defaults force; cb_cd=$?
    # A boot boost can hold every minimum at its maximum for a while. Wait for it instead of recording it.
    { [ "$cb_cd" = 0 ] && [ -n "$CAP_PIN" ]; } || break
    cb_try=$((cb_try + 1)); [ "$cb_try" -lt "$BOOT_RETRIES" ] || break
    log_msg "boot: minimum held at maximum for:$CAP_PIN, looking again in ${BOOT_WAIT}s ($cb_try/$BOOT_RETRIES)"
    sleep "$BOOT_WAIT"
  done
  # cb_nostock: the snapshot could not be SAVED and there is no earlier one, so the phone's own limits are
  # on record nowhere. service.sh must not apply the kernel profile then (exit status 2, see the end).
  cb_nostock=""
  if [ "$cb_cd" != 0 ]; then
    echo "error: the phone's own limits could not be saved at boot; an earlier record is kept if there is one"; cb_rc=1
    have_def || cb_nostock=1
  fi
  [ -z "$CAP_BAD" ] || echo "warn: could not read these frequency values at boot:$CAP_BAD (an earlier record is kept if there is one)"
  [ -z "$CAP_PIN" ] || echo "warn: the minimum frequency was at or above the maximum for:$CAP_PIN, so it was not recorded as stock (something is holding it up); an earlier record is kept if there is one"
  [ "$cb_cd" != 0 ] || [ ! -s "$DEF" ] || log_msg "boot: stock recorded: $(tr '\n' ' ' < "$DEF" 2>/dev/null)"
  load_cfg
  [ -z "$CFG_BAD" ] || { echo "$NOREAD"; cb_rc=1; }
  if [ "$ENABLED" = 1 ] && [ -z "$CFG_BAD" ]; then cmd_apply || cb_rc=1; fi
  if [ "$cb_rc" = 0 ]; then
    echo "boot done: enabled=$ENABLED preset=$PRESET"
  else
    echo "boot finished with errors: enabled=$ENABLED preset=$PRESET (see the messages above)"
    log_msg "boot finished with errors"
  fi
  if [ -n "$cb_nostock" ]; then
    echo "error: the phone's own limits are not on record, so the kernel profile must not be applied at this boot (exit status 2)"
    log_msg "boot: the phone's own limits are not on record; the kernel profile is not applied at this boot"
    return 2
  fi
  return "$cb_rc"
}

cmd_lists() { for c in $CLUSTERS; do echo "$c=$(rd "$(avail_node $c)")"; done; }

cmd_status() {
  capture_defaults
  load_cfg
  if [ -z "$CFG_BAD" ] && ! cfg_values_available; then CFG_BAD=1; cfg_reset; fi
  # A settings file that exists but cannot be read or validated shows up as safe defaults below (disabled,
  # stock), which is NOT the same as "no settings": cfg_error=1 tells the page to warn instead of looking normal.
  [ -z "$CFG_BAD" ] || echo "cfg_error=1"
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
