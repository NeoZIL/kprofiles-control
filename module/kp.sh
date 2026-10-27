#!/system/bin/sh
# Kprofiles Control helper. Used by the WebUI, action.sh and service.sh.
# Paths can be overridden with env vars (only useful for testing off-device).
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
CFG_DIR="${CFG_DIR:-/data/adb/kprofiles_ui}"
if [ ! -r "$MODDIR/control-lib.sh" ] && [ -n "${INJ_TARGET:-}" ]; then MODDIR=${INJ_TARGET%/*}; fi
. "$MODDIR/control-lib.sh"
KP="${KP_PATH:-$(kp_find mode)}"
AUTO="${AUTO_PATH:-$(kp_find auto)}"
CFG="$CFG_DIR/config"

cfg_get() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" | head -n 1; }
# cfg_set KEY VALUE [KEY VALUE ...] saves one or more settings in ONE replace of the config file, or
# changes nothing: the new file is prepared completely beside the old one and only then moved over it.
# Returns non-zero if the folder cannot be made, the temporary file cannot be written or the config
# cannot be replaced. The old config is never overwritten by a failed write (it stays byte for byte as
# it was, even when several settings were being saved), and the temporary file is removed again.
cfg_set() {
  [ $(($# % 2)) = 0 ] && [ "$#" -ge 2 ] || return 1
  mkdir -p "$CFG_DIR" 2>/dev/null || return 1
  [ ! -d "$CFG" ] || return 1
  cs_pat=""; cs_new=""
  while [ "$#" -ge 2 ]; do
    cs_pat="$cs_pat -e ^$1="
    cs_new="$cs_new$1=$2
"
    shift 2
  done
  { printf "" > "$CFG.tmp"; } 2>/dev/null || return 1
  if [ -e "$CFG" ]; then
    # grep exits 0 or 1 when it could read the file; anything else means the old config could not be
    # read, and it must not be replaced by a file holding only the new keys
    # shellcheck disable=SC2086
    grep -v $cs_pat "$CFG" > "$CFG.tmp" 2>/dev/null; cs_rc=$?
    [ "$cs_rc" -le 1 ] || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  fi
  { printf '%s' "$cs_new" >> "$CFG.tmp"; } 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  mv "$CFG.tmp" "$CFG" 2>/dev/null || { rm -f "$CFG.tmp" 2>/dev/null; return 1; }
  return 0
}
# Persistence is ON unless the config says PERSIST=0.
persist_on() { [ "$(cfg_get PERSIST)" != "0" ]; }

read_mode() { cat "$KP" 2>/dev/null; }
read_auto() { cat "$AUTO" 2>/dev/null; }

# The mode node (values 0..3) is found by kp_find in control-lib.sh: the upstream module parameter or the
# /sys/kernel/kprofiles node some kernels use. Treat the mode node as the core capability; auto_kp is an optional parameter and may be
# absent (or unused by a downstream kernel) without making the mode interface unusable.
mode_support() {
  [ -e "$KP" ] || { echo unsupported; return 0; }
  ms_value=$(read_mode); ms_rc=$?
  [ "$ms_rc" = 0 ] || { echo unknown; return 0; }
  case "$ms_value" in 0|1|2|3) echo supported ;; *) echo unknown ;; esac
}

auto_support() {
  [ -e "$AUTO" ] || { echo unsupported; return 0; }
  as_value=$(read_auto); as_rc=$?
  [ "$as_rc" = 0 ] || { echo unknown; return 0; }
  case "$as_value" in Y|y|N|n|0|1) echo supported ;; *) echo unknown ;; esac
}

name_of() {
  case "$1" in
    0) echo None ;; 1) echo Battery ;; 2) echo Balanced ;; 3) echo Performance ;; *) echo Unknown ;;
  esac
}

status() {
  m=$(read_mode); mr=$?
  a=$(read_auto); ar=$?
  [ "$mr" = 0 ] && [ -n "$m" ] || m='?'
  [ "$ar" = 0 ] && [ -n "$a" ] || a='?'
  p=1; persist_on || p=0
  echo "mode=$m auto=$a persist=$p support=$(mode_support) auto_support=$(auto_support)"
}

ensure_controller_initialized() {
  ei_source=$(control_source)
  [ "$ei_source" != legacy ] && return 0
  case "$(mode_support)" in
    unsupported) return 0 ;; # A kernel without Kprofiles cannot have a competing kernel-profile controller.
    supported) ;;
    *) echo "error: controller is not initialized and Kprofiles state is unknown; refusing to change it"; return 1 ;;
  esac
  sh "$MODDIR/control.sh" init >/dev/null 2>&1 || { echo "error: controller initialization failed; refusing to change Kprofiles"; return 1; }
  ei_source=$(control_source)
  [ "$ei_source" != legacy ] || { echo "error: controller initialization did not save an owner"; return 1; }
  return 0
}

write_mode_runtime() {
  case "$1" in 0|1|2|3) ;; *) echo "error: mode must be 0, 1, 2 or 3"; return 1 ;; esac
  case "$(mode_support)" in
    supported) ;;
    unsupported) echo "warn: Kprofiles mode interface is absent; nothing to write"; return 0 ;;
    *) echo "error: Kprofiles mode support is not confirmed; refusing to write"; return 1 ;;
  esac
  { echo "$1" > "$KP"; } 2>/dev/null
  now=$(read_mode)
  [ "$now" = "$1" ] || { echo "error: wrote $1 but the kernel reports ${now:-nothing}"; return 1; }
  return 0
}
write_auto_runtime() {
  case "$1" in Y|y|1) v=Y ;; N|n|0) v=N ;; *) echo "error: auto must be Y or N"; return 1 ;; esac
  case "$(auto_support)" in
    unsupported) echo "warn: optional auto_kp parameter is absent; nothing to write"; return 0 ;;
    supported) ;;
    *) echo "error: auto_kp state is not confirmed; refusing to write"; return 1 ;;
  esac
  case "$(read_auto)" in 0|1) case "$v" in Y) w=1 ;; *) w=0 ;; esac ;; *) w=$v ;; esac
  { echo "$w" > "$AUTO"; } 2>/dev/null
  now=$(read_auto)
  [ "$now" = "$w" ] || { echo "error: wrote $w but the kernel reports ${now:-nothing}"; return 1; }
  return 0
}
enforce_module() {
  case "$(mode_support)" in
    unsupported) echo "warn: Kprofiles interface is absent; module-only control is available"; return 0 ;;
    supported) ;;
    *) echo "error: Kprofiles mode state is unknown; module-only exclusivity cannot be verified"; return 1 ;;
  esac
  write_mode_runtime 0 || return 1
  case "$(auto_support)" in
    unsupported) return 0 ;;
    supported) write_auto_runtime N ;;
    *) echo "error: auto_kp state is unknown; module-only exclusivity cannot be verified"; return 1 ;;
  esac
}
set_mode() {
  case "$1" in 0|1|2|3) ;; *) echo "error: mode must be 0, 1, 2 or 3"; return 1 ;; esac
  control_internal || ensure_controller_initialized || return 1
  sm_source=$(control_source)
  if ! control_internal; then
    case "$sm_source:$1" in
      module:0) return_runtime_only=1 ;;
      module:*) echo "error: kernel profiles are inactive while Module presets control tuning; switch control source first"; return 1 ;;
      kernel:*) return_runtime_only=0 ;;
      conflict:*) echo "error: controller source is unresolved; choose Module presets or Kernel profile first"; return 1 ;;
      unknown:*) echo "error: controller state cannot be read; refusing to change Kprofiles"; return 1 ;;
      *) return_runtime_only=0 ;;
    esac
  else return_runtime_only=1
  fi
  case "$(mode_support)" in
    supported) ;;
    unsupported) echo "error: Kprofiles mode interface is not present at $KP; nothing was changed"; return 1 ;;
    *) echo "error: Kprofiles mode interface at $KP cannot be read or its current mode is not recognized; refusing to write"; return 1 ;;
  esac
  { echo "$1" > "$KP"; } 2>/dev/null
  now=$(read_mode)
  [ "$now" = "$1" ] || { echo "error: wrote $1 but the kernel reports ${now:-nothing}"; return 1; }
  # Module mode's mandatory None is a runtime state, not a replacement for the saved kernel preference.
  if [ "$return_runtime_only" != 1 ]; then
    if [ "$sm_source" = kernel ] && ! control_set KP_MODE_PREF "$1"; then
      echo "error: kernel accepted mode $1, but the saved kernel preference could not be updated"
      return 1
    fi
    if persist_on && ! cfg_set MODE "$1"; then
      echo "error: the kernel accepted mode $1, but saving it to $CFG failed, so it will not be re-applied at boot"
      return 1
    fi
  fi
  return 0
}

set_auto() {
  case "$1" in Y|y|1) v=Y ;; N|n|0) v=N ;; *) echo "error: auto must be Y or N"; return 1 ;; esac
  control_internal || ensure_controller_initialized || return 1
  sa_source=$(control_source)
  if ! control_internal; then
    case "$sa_source:$v" in
      module:N) return_runtime_only=1 ;;
      module:*) echo "error: auto_kp must stay off while Module presets control tuning; switch control source first"; return 1 ;;
      kernel:*) return_runtime_only=0 ;;
      conflict:*) echo "error: controller source is unresolved; choose Module presets or Kernel profile first"; return 1 ;;
      unknown:*) echo "error: controller state cannot be read; refusing to change auto_kp"; return 1 ;;
      *) return_runtime_only=0 ;;
    esac
  else return_runtime_only=1
  fi
  [ "$(mode_support)" = supported ] || { echo "error: Kprofiles mode support is not confirmed; refusing to change auto_kp"; return 1; }
  case "$(auto_support)" in
    supported) ;;
    unsupported) echo "error: optional auto_kp parameter is not present at $AUTO; nothing was changed"; return 1 ;;
    *) echo "error: auto_kp at $AUTO cannot be read or recognized; refusing to write"; return 1 ;;
  esac
  # Write in the node's own style: auto_support accepts a node that reads 0/1 as well as Y/N, so a kernel
  # whose auto_kp reads 0 or 1 gets 1 or 0, and a bool parameter (Y/N) gets Y or N. The saved setting stays Y/N.
  case "$(read_auto)" in
    0|1) case "$v" in Y) w=1 ;; *) w=0 ;; esac ;;
    *) w=$v ;;
  esac
  { echo "$w" > "$AUTO"; } 2>/dev/null
  now=$(read_auto)
  [ "$now" = "$w" ] || { echo "error: wrote $w but the kernel reports ${now:-nothing}"; return 1; }
  if [ "$return_runtime_only" != 1 ]; then
    if [ "$sa_source" = kernel ] && ! control_set KP_AUTO_PREF "$v"; then
      echo "error: the kernel accepted auto $v, but the saved kernel preference could not be updated"
      return 1
    fi
    if persist_on && ! cfg_set AUTO "$v"; then
      echo "error: the kernel accepted auto $v, but saving it to $CFG failed, so it will not be re-applied at boot"
      return 1
    fi
  fi
  return 0
}

set_persist() {
  control_internal || ensure_controller_initialized || return 1
  sp_source=$(control_source)
  case "$sp_source" in
    conflict|unknown) echo "error: controller source is unresolved; persistence was not changed"; return 1 ;;
  esac
  case "$1" in
    1)
      if [ "$sp_source" = module ]; then
        # Module mode has temporarily forced the live mode/auto off. Do not persist those temporary values.
        sp_mode=$(control_get KP_MODE_PREF); case "$sp_mode" in 0|1|2|3) ;; *) sp_mode=$(cfg_get MODE); case "$sp_mode" in 0|1|2|3) ;; *) sp_mode=0 ;; esac ;; esac
        sp_auto=$(control_get KP_AUTO_PREF); case "$sp_auto" in Y|N) ;; *) sp_auto=$(control_norm_auto "$(cfg_get AUTO)"); [ "$sp_auto" = unknown ] && sp_auto=N ;; esac
        if ! cfg_set PERSIST 1 MODE "$sp_mode" AUTO "$sp_auto"; then echo "error: could not save the persistence setting to $CFG"; return 1; fi
        return 0
      fi
      case "$(mode_support)" in
        supported) current_mode=$(read_mode) ;;
        unsupported) echo "error: Kprofiles mode interface is not available; persistence was not changed"; return 1 ;;
        *) echo "error: Kprofiles mode interface cannot be read or recognized; persistence was not changed"; return 1 ;;
      esac
      case "$(auto_support)" in
        supported)
          current_auto=$(control_norm_auto "$(read_auto)")
          [ "$current_auto" != unknown ] || { echo "error: optional auto_kp exists but cannot be read or recognized; persistence was not changed"; return 1; }
          if ! cfg_set PERSIST 1 MODE "$current_mode" AUTO "$current_auto"; then
            echo "error: could not save the persistence setting to $CFG"; return 1
          fi ;;
        unsupported)
          if ! cfg_set PERSIST 1 MODE "$current_mode"; then echo "error: could not save the persistence setting to $CFG"; return 1; fi ;;
        *) echo "error: optional auto_kp exists but cannot be read or recognized; persistence was not changed"; return 1 ;;
      esac ;;
    0) if ! cfg_set PERSIST 0; then echo "error: could not save the persistence setting to $CFG"; return 1; fi ;;
    *) echo "error: persist must be 0 or 1"; return 1 ;;
  esac
  return 0
}

# apply and cycle report the resulting state either way, but exit non-zero if a requested change failed.
apply() {
  control_internal || ensure_controller_initialized || return 1
  aa_source=$(control_source)
  case "$aa_source" in
    module) enforce_module || { status; return 1; }; echo "Module controller enforced: Kprofiles None, auto_kp off"; status; return 0 ;;
    conflict) echo "error: controller source is unresolved; no kernel profile was applied"; status; return 1 ;;
    unknown) echo "error: controller state cannot be read; refusing to apply a kernel profile"; status; return 1 ;;
  esac
  persist_on || { echo "persist is off, nothing to apply"; return 0; }
  ap_rc=0
  m=$(cfg_get MODE); a=$(cfg_get AUTO)
  case "$(mode_support)" in
    unsupported)
      # A missing optional Kprofiles interface is a normal capability result on other kernels.
      # Keep the saved preference for a later compatible kernel, but never write to guessed paths.
      [ -z "$m" ] || echo "warn: this kernel does not expose the Kprofiles mode interface; saved mode was skipped"
      [ -z "$a" ] || echo "warn: auto_kp was skipped because the Kprofiles mode interface is unavailable"
      status
      return 0 ;;
    unknown)
      echo "error: the Kprofiles mode interface exists but cannot be read or recognized; no saved mode was applied"
      status
      return 1 ;;
    supported) ;;
  esac
  if [ -n "$m" ]; then set_mode "$m" || ap_rc=1; fi
  if [ -n "$a" ]; then
    case "$(auto_support)" in
      supported) set_auto "$a" || ap_rc=1 ;;
      unsupported) echo "warn: this kernel does not expose the optional auto_kp parameter; saved auto setting was skipped" ;;
      *) echo "error: auto_kp exists but cannot be read or recognized; saved auto setting was not applied"; ap_rc=1 ;;
    esac
  fi
  status
  return "$ap_rc"
}

cycle() {
  control_internal || ensure_controller_initialized || return 1
  cy_source=$(control_source)
  case "$cy_source" in module) echo "error: kernel profiles are inactive while Module presets control tuning"; return 1 ;; conflict|unknown) echo "error: controller source is unresolved"; return 1 ;; esac
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
  control-mode) write_mode_runtime "$2" ;;
  control-auto) write_auto_runtime "$2" ;;
  enforce-module) enforce_module ;;
  *) echo "usage: kp.sh status | mode 0-3 | auto Y/N | persist 0/1 | apply | cycle | control-mode 0-3 | control-auto Y/N | enforce-module"; exit 1 ;;
esac
