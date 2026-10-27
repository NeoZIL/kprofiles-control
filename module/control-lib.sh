#!/system/bin/sh
# Shared controller-source state and atomic storage. This file is sourced by kp.sh/tune.sh/control.sh.
CONTROL_DIR="${CONTROL_DIR:-${CFG_DIR:-/data/adb/kprofiles_ui}}"
CONTROL_FILE="${CONTROL_FILE:-$CONTROL_DIR/control.conf}"

control_get() {
  [ -r "$CONTROL_FILE" ] || return 1
  sed -n "s/^$1=//p" "$CONTROL_FILE" 2>/dev/null | head -n 1
}
control_source() {
  [ -e "$CONTROL_FILE" ] || { echo legacy; return 0; }
  [ -r "$CONTROL_FILE" ] || { echo unknown; return 0; }
  cs_source=$(control_get SOURCE)
  case "$cs_source" in module|kernel|conflict) echo "$cs_source" ;; *) echo unknown ;; esac
}
control_norm_auto() {
  case "$1" in Y|y|1) echo Y ;; N|n|0) echo N ;; *) echo unknown ;; esac
}
control_valid_pair() {
  case "$1:$2" in
    SOURCE:module|SOURCE:kernel|SOURCE:conflict|KP_MODE_PREF:0|KP_MODE_PREF:1|KP_MODE_PREF:2|KP_MODE_PREF:3|KP_AUTO_PREF:Y|KP_AUTO_PREF:N|KP_AUTO_PREF:unknown) return 0 ;;
    *) return 1 ;;
  esac
}
# control_set KEY VALUE [KEY VALUE ...]: atomic one-file update. Values/keys are allow-listed above.
control_set() {
  [ $(($# % 2)) = 0 ] && [ "$#" -ge 2 ] || return 1
  mkdir -p "$CONTROL_DIR" 2>/dev/null || return 1
  [ ! -d "$CONTROL_FILE" ] || return 1
  cl_pat=""; cl_new=""
  while [ "$#" -ge 2 ]; do
    control_valid_pair "$1" "$2" || return 1
    cl_pat="$cl_pat -e ^$1="
    cl_new="$cl_new$1=$2
"
    shift 2
  done
  { printf '' > "$CONTROL_FILE.tmp"; } 2>/dev/null || return 1
  if [ -e "$CONTROL_FILE" ]; then
    # shellcheck disable=SC2086
    grep -v $cl_pat "$CONTROL_FILE" > "$CONTROL_FILE.tmp" 2>/dev/null; cl_rc=$?
    [ "$cl_rc" -le 1 ] || { rm -f "$CONTROL_FILE.tmp" 2>/dev/null; return 1; }
  fi
  { printf '%s' "$cl_new" >> "$CONTROL_FILE.tmp"; } 2>/dev/null || { rm -f "$CONTROL_FILE.tmp" 2>/dev/null; return 1; }
  mv "$CONTROL_FILE.tmp" "$CONTROL_FILE" 2>/dev/null || { rm -f "$CONTROL_FILE.tmp" 2>/dev/null; return 1; }
  return 0
}
control_internal() { [ "${KPC_CONTROL_INTERNAL:-0}" = 1 ]; }

# Where this kernel keeps Kprofiles. The upstream driver (dakkshesh07/Kprofiles) documents its module
# parameters, /sys/module/kprofiles/parameters/kp_mode and auto_kp. Some kernels (for example the Theettam
# kernel of the POCO F6) also, or instead, expose the mode under /sys/kernel/kprofiles. The first node that
# exists wins, in the order below, so a phone that already worked keeps using the same node. When none
# exists the first candidate is returned: that is the path reported in messages and what "absent" means.
# KP_SYSROOT puts a prefix in front of every candidate (off-device tests only).
kp_find() { # mode | auto
  kf_root=${KP_SYSROOT:-}
  case "$1" in
    auto) set -- /sys/module/kprofiles/parameters/auto_kp /sys/kernel/kprofiles/auto_kp ;;
    *)    set -- /sys/kernel/kprofiles/kp_mode /sys/module/kprofiles/parameters/kp_mode ;;
  esac
  for kf_p in "$@"; do
    if [ -e "$kf_root$kf_p" ]; then echo "$kf_root$kf_p"; return 0; fi
  done
  echo "$kf_root$1"
}
