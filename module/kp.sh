#!/system/bin/sh
# Kprofiles Control helper. Used by the WebUI, action.sh and service.sh.
# Paths can be overridden with env vars (only useful for testing off-device).
KP="${KP_PATH:-/sys/kernel/kprofiles/kp_mode}"
AUTO="${AUTO_PATH:-/sys/module/kprofiles/parameters/auto_kp}"
CFG_DIR="${CFG_DIR:-/data/adb/kprofiles_ui}"
CFG="$CFG_DIR/config"

cfg_get() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" | head -n 1; }
cfg_set() {
  mkdir -p "$CFG_DIR" 2>/dev/null
  touch "$CFG"
  grep -v "^$1=" "$CFG" > "$CFG.tmp" 2>/dev/null
  echo "$1=$2" >> "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
}
# Persistence is ON unless the config says PERSIST=0.
persist_on() { [ "$(cfg_get PERSIST)" != "0" ]; }

read_mode() { cat "$KP" 2>/dev/null; }
read_auto() { cat "$AUTO" 2>/dev/null; }

name_of() {
  case "$1" in
    0) echo Off ;; 1) echo Battery ;; 2) echo Balanced ;; 3) echo Performance ;; *) echo Unknown ;;
  esac
}

status() {
  m=$(read_mode); a=$(read_auto)
  p=1; persist_on || p=0
  echo "mode=${m:-?} auto=${a:-?} persist=$p"
}

set_mode() {
  case "$1" in 0|1|2|3) ;; *) echo "error: mode must be 0, 1, 2 or 3"; return 1 ;; esac
  [ -e "$KP" ] || { echo "error: $KP not found (no Kprofiles in this kernel?)"; return 1; }
  { echo "$1" > "$KP"; } 2>/dev/null
  now=$(read_mode)
  [ "$now" = "$1" ] || { echo "error: wrote $1 but the kernel reports ${now:-nothing}"; return 1; }
  persist_on && cfg_set MODE "$1"
  return 0
}

set_auto() {
  case "$1" in Y|y|1) v=Y ;; N|n|0) v=N ;; *) echo "error: auto must be Y or N"; return 1 ;; esac
  [ -e "$AUTO" ] || { echo "error: $AUTO not found (no Kprofiles in this kernel?)"; return 1; }
  { echo "$v" > "$AUTO"; } 2>/dev/null
  now=$(read_auto)
  [ "$now" = "$v" ] || { echo "error: wrote $v but the kernel reports ${now:-nothing}"; return 1; }
  persist_on && cfg_set AUTO "$v"
  return 0
}

set_persist() {
  case "$1" in
    1) cfg_set PERSIST 1; cfg_set MODE "$(read_mode)"; cfg_set AUTO "$(read_auto)" ;;
    0) cfg_set PERSIST 0 ;;
    *) echo "error: persist must be 0 or 1"; return 1 ;;
  esac
  return 0
}

# apply and cycle report the resulting state either way, but exit non-zero if a requested change failed.
apply() {
  persist_on || { echo "persist is off, nothing to apply"; return 0; }
  ap_rc=0
  m=$(cfg_get MODE); a=$(cfg_get AUTO)
  if [ -n "$m" ]; then set_mode "$m" || ap_rc=1; fi
  if [ -n "$a" ]; then set_auto "$a" || ap_rc=1; fi
  status
  return "$ap_rc"
}

cycle() {
  cy_rc=0
  case "$(read_mode)" in 1) n=2 ;; 2) n=3 ;; 3) n=1 ;; *) n=2 ;; esac
  if set_mode "$n"; then echo "Kprofiles: switched to $(name_of "$n")"; else cy_rc=1; fi
  status
  return "$cy_rc"
}

case "$1" in
  status|"") status ;;
  mode)    set_mode "$2"    && status ;;
  auto)    set_auto "$2"    && status ;;
  persist) set_persist "$2" && status ;;
  apply)   apply ;;
  cycle)   cycle ;;
  *) echo "usage: kp.sh status | mode 0-3 | auto Y/N | persist 0/1 | apply | cycle"; exit 1 ;;
esac
