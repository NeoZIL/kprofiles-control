#!/system/bin/sh
# Explicit mutual exclusion between module CPU/GPU presets and kernel Kprofiles.
# Controller state and saved preferences are separate from the active sysfs mode.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
CFG_DIR="${CFG_DIR:-/data/adb/kprofiles_ui}"
. "$MODDIR/control-lib.sh"

value() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1; }
file_value() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
kp_status() { sh "$MODDIR/kp.sh" status 2>&1; }
tune_status() { sh "$MODDIR/tune.sh" status 2>&1; }
mode_cfg() { file_value "$CFG_DIR/config" MODE; }
auto_cfg() { file_value "$CFG_DIR/config" AUTO; }
persist_cfg() { file_value "$CFG_DIR/config" PERSIST; }
get_saved_mode() {
  v=$(control_get KP_MODE_PREF)
  case "$v" in 0|1|2|3) echo "$v"; return 0 ;; esac
  v=$(mode_cfg); case "$v" in 0|1|2|3) echo "$v"; return 0 ;; esac
  v=$(value "$1" mode); case "$v" in 0|1|2|3) echo "$v"; return 0 ;; esac
  echo 0
}
get_saved_auto() {
  v=$(control_get KP_AUTO_PREF)
  case "$v" in Y|N) echo "$v"; return 0 ;; esac
  v=$(auto_cfg); v=$(control_norm_auto "$v"); [ "$v" != unknown ] && { echo "$v"; return 0; }
  v=$(value "$1" auto); v=$(control_norm_auto "$v"); [ "$v" != unknown ] && { echo "$v"; return 0; }
  echo N
}
write_prefs_from_legacy() {
  ws_kp=$1; ws_source=$2
  ws_mode=$(value "$ws_kp" mode); ws_support=$(value "$ws_kp" support)
  ws_persist=$(value "$ws_kp" persist); ws_cfg_mode=$(mode_cfg); ws_cfg_auto=$(auto_cfg)
  # A persisted preference wins over a runtime None on migration; otherwise preserve a currently active mode.
  case "$ws_mode" in 0|1|2|3) ;; *) ws_mode=0 ;; esac
  case "$ws_cfg_mode" in 0|1|2|3) ;; *) ws_cfg_mode= ;; esac
  if [ "$ws_persist" = 1 ] && [ -n "$ws_cfg_mode" ]; then ws_pref_mode=$ws_cfg_mode
  elif [ "$ws_mode" != 0 ]; then ws_pref_mode=$ws_mode
  elif [ -n "$ws_cfg_mode" ]; then ws_pref_mode=$ws_cfg_mode
  else ws_pref_mode=$ws_mode
  fi
  ws_auto=$(value "$ws_kp" auto); ws_auto=$(control_norm_auto "$ws_auto")
  if [ "$ws_persist" = 1 ]; then
    ws_cfg_auto=$(control_norm_auto "$ws_cfg_auto")
    [ "$ws_cfg_auto" = unknown ] || ws_auto=$ws_cfg_auto
  fi
  [ "$ws_auto" = unknown ] && ws_auto=$(control_norm_auto "$ws_cfg_auto")
  [ "$ws_auto" = unknown ] && ws_auto=N
  control_set KP_MODE_PREF "$ws_pref_mode" KP_AUTO_PREF "$ws_auto" || return 1
}
neutralize_kernel() {
  # A genuinely absent interface is a normal capability result; a present but unknown interface is not.
  nk_status=$(kp_status)
  nk_support=$(value "$nk_status" support)
  case "$nk_support" in
    unsupported) echo "warn: Kprofiles is absent; module presets can run without the kernel controller"; return 0 ;;
    supported) ;;
    *) echo "error: Kprofiles state is unknown; exclusive control cannot be verified"; return 1 ;;
  esac
  nk_out=$(sh "$MODDIR/kp.sh" control-mode 0 2>&1) || { echo "$nk_out"; return 1; }
  nk_status=$(kp_status); [ "$(value "$nk_status" mode)" = 0 ] || { echo "error: Kprofiles mode None could not be verified"; return 1; }
  nk_auto_support=$(value "$nk_status" auto_support)
  case "$nk_auto_support" in
    unsupported) return 0 ;;
    supported)
      nk_out=$(sh "$MODDIR/kp.sh" control-auto N 2>&1) || { echo "$nk_out"; return 1; }
      nk_status=$(kp_status); nk_auto=$(control_norm_auto "$(value "$nk_status" auto)")
      [ "$nk_auto" = N ] || { echo "error: auto_kp off could not be verified"; return 1; }
      ;;
    *) echo "error: auto_kp exists but its state is unknown; exclusive control cannot be verified"; return 1 ;;
  esac
}
restore_kernel_pref() {
  rp_mode=$1; rp_auto=$2; rp_rc=0
  case "$rp_mode" in 0|1|2|3) ;; *) rp_mode=0 ;; esac
  sh "$MODDIR/kp.sh" control-mode "$rp_mode" || rp_rc=1
  case "$rp_auto" in Y|N)
    rp_kps=$(kp_status); rp_as=$(value "$rp_kps" auto_support)
    case "$rp_as" in
      supported) sh "$MODDIR/kp.sh" control-auto "$rp_auto" || rp_rc=1 ;;
      unsupported) : ;;
      *) echo "warn: could not confirm the saved auto_kp preference" ;;
    esac ;;
  esac
  return "$rp_rc"
}

cmd_status() {
  cs=$(control_source)
  if [ "$cs" = legacy ]; then
    cmd_init >/dev/null 2>&1
    cs=$(control_source)
  fi
  case "$cs" in
    module) msg="Module presets control CPU/GPU limits; kernel profile and auto_kp are held at None/off." ;;
    kernel) msg="Kernel profile controls performance; module frequency caps and watcher are suspended." ;;
    conflict) msg="Choose a controller to resolve the saved configuration conflict. No module preset is applied automatically." ;;
    legacy) msg="Controller setup has not been initialized yet." ;;
    *) msg="Controller state cannot be read or validated." ;;
  esac
  echo "source=$cs"
  echo "source_message=$msg"
  echo "saved_kernel_mode=$(get_saved_mode "$(kp_status)")"
  echo "saved_kernel_auto=$(get_saved_auto "$(kp_status)")"
  echo "kernel_support=$(value "$(kp_status)" support)"
}
cmd_init() {
  ci_existing=$(control_source)
  ci_kp=$(kp_status); ci_support=$(value "$ci_kp" support)
  case "$ci_existing" in
    conflict) echo "source=conflict"; echo "error: controller choice is still required"; return 0 ;;
    unknown) echo "error: control state file cannot be read; no controller was changed"; return 1 ;;
    module|kernel)
      # If an interface becomes unreadable, do not assert exclusivity. A fully absent interface is a supported module-only setup.
      if [ "$ci_support" = unknown ]; then control_set SOURCE conflict || return 1; echo "source=conflict"; echo "error: Kprofiles state is unknown; no controller was applied"; return 1; fi
      if [ "$ci_existing" = kernel ] && [ "$ci_support" = unsupported ]; then
        control_set SOURCE module || return 1
        echo "warn: Kprofiles is absent on this kernel; returned to module-only control"
        ci_existing=module
      fi
      if [ "$ci_existing" = module ] || [ "$ci_existing" = kernel ]; then neutralize_kernel || { control_set SOURCE conflict; echo "source=conflict"; return 1; }; fi
      echo "source=$(control_source)"; return 0 ;;
    legacy) ;;
  esac
  # Read the saved tuning choices directly. Calling tune.sh status here could capture defaults before
  # the kernel profile is neutralized, which would be unsafe during first-run migration.
  ci_enabled=$(file_value "$CFG_DIR/tune.conf" ENABLED); ci_preset=$(file_value "$CFG_DIR/tune.conf" PRESET)
  [ -n "$ci_enabled" ] || ci_enabled=0
  [ -n "$ci_preset" ] || ci_preset=stock
  ci_mode=$(value "$ci_kp" mode); ci_auto=$(control_norm_auto "$(value "$ci_kp" auto)"); ci_persist=$(value "$ci_kp" persist); ci_cfg_mode=$(mode_cfg)
  ci_module_active=0; [ "$ci_enabled" = 1 ] && [ -n "$ci_preset" ] && [ "$ci_preset" != stock ] && ci_module_active=1
  case "$ci_support" in
    unsupported) ci_source=module ;;
    unknown) ci_source=conflict ;;
    supported)
      ci_kernel_active=0
      case "$ci_mode" in 1|2|3) ci_kernel_active=1 ;; esac
      if [ "$ci_persist" = 1 ]; then case "$ci_cfg_mode" in 1|2|3) ci_kernel_active=1 ;; esac; fi
      # auto_kp can reactivate kernel profiles after a screen transition even while mode currently reads 0.
      # Do not silently choose Module presets over an enabled automatic kernel controller.
      [ "$ci_auto" = Y ] && ci_kernel_active=1
      if [ "$ci_module_active" = 1 ] && [ "$ci_kernel_active" = 1 ]; then ci_source=conflict
      elif [ "$ci_kernel_active" = 1 ]; then ci_source=kernel
      else ci_source=module
      fi ;;
    *) ci_source=conflict ;;
  esac
  write_prefs_from_legacy "$ci_kp" "$ci_source" || { echo "error: could not save the kernel profile preference"; return 1; }
  control_set SOURCE "$ci_source" || { echo "error: could not save controller source"; return 1; }
  if [ "$ci_source" = conflict ]; then
    echo "source=conflict"
    echo "error: both controllers may be selected, or Kprofiles support is unknown. Choose a controller in the WebUI. No tuning side was applied by migration."
    return 0
  fi
  neutralize_kernel || { control_set SOURCE conflict; echo "source=conflict"; echo "error: could not neutralize Kprofiles safely; controller choice is unresolved"; return 1; }
  echo "source=$ci_source"
  return 0
}
emit_conflict_recovery() {
  control_set SOURCE conflict >/dev/null 2>&1
  echo "source=conflict"
  echo "recovery=1"
  echo "error: controller handoff was incomplete; use Reset everything to recover"
}
rollback_to_module() {
  # Only safe as an automatic rollback when Module presets was the known outgoing owner.
  [ "$current" = module ] || return 1
  control_set SOURCE module || return 1
  sh "$MODDIR/kp.sh" enforce-module >/dev/null 2>&1 || return 1
  KPC_CONTROL_INTERNAL=1 sh "$MODDIR/tune.sh" apply > "$CONTROL_DIR/handoff-rollback-module.log" 2>&1 || return 1
  return 0
}
rollback_to_kernel() {
  # The outgoing Kernel controller is restored only after module tuning was successfully stopped.
  [ "$current" = kernel ] || return 1
  control_set SOURCE kernel || return 1
  restore_kernel_pref "$pref_mode" "$pref_auto" || return 1
  return 0
}
cmd_switch() {
  target=$1
  case "$target" in module|kernel) ;; *) echo "error: choose module or kernel"; return 1 ;; esac
  current=$(control_source)
  [ "$current" != legacy ] || { cmd_init || return 1; current=$(control_source); }
  [ "$current" != unknown ] || { echo "error: controller state is unreadable"; return 1; }
  [ "$current" != "$target" ] || { echo "source=$current"; echo "already selected"; return 0; }
  kpnow=$(kp_status); support=$(value "$kpnow" support)
  if [ "$support" = unknown ]; then echo "error: Kprofiles state is unknown; no handoff was attempted"; return 1; fi
  if [ "$target" = kernel ] && [ "$support" != supported ]; then echo "error: this kernel does not expose the Kprofiles mode interface"; return 1; fi
  pref_mode=$(get_saved_mode "$kpnow"); pref_auto=$(get_saved_auto "$kpnow")

  if [ "$target" = module ]; then
    # Capture the live kernel preference before the temporary None/off runtime state is applied.
    if [ "$current" = kernel ] || [ "$current" = conflict ]; then
      now_mode=$(value "$kpnow" mode); now_auto=$(control_norm_auto "$(value "$kpnow" auto)")
      case "$now_mode" in 1|2|3) pref_mode=$now_mode ;; esac
      [ "$now_auto" = unknown ] || pref_auto=$now_auto
      control_set KP_MODE_PREF "$pref_mode" KP_AUTO_PREF "$pref_auto" || { echo "error: could not preserve the kernel profile preference"; return 1; }
    fi
    if ! neutralize_kernel; then
      if [ "$current" = kernel ] && restore_kernel_pref "$pref_mode" "$pref_auto"; then
        echo "source=kernel"; echo "error: kernel controller could not be released; the previous kernel preference was restored"; return 1
      fi
      emit_conflict_recovery
      return 1
    fi
    if ! sh "$MODDIR/tune.sh" stop > "$CONTROL_DIR/handoff-tune-stop.log" 2>&1; then
      cat "$CONTROL_DIR/handoff-tune-stop.log"
      emit_conflict_recovery
      return 1
    fi
    if ! control_set SOURCE module; then
      if [ "$current" = kernel ] && restore_kernel_pref "$pref_mode" "$pref_auto"; then
        echo "source=kernel"; echo "error: could not save Module presets as the controller; kernel preference restored and no module preset applied"; return 1
      fi
      emit_conflict_recovery
      return 1
    fi
    KPC_CONTROL_INTERNAL=1 sh "$MODDIR/tune.sh" boot > "$CONTROL_DIR/handoff-tune-boot.log" 2>&1; sw_rc=$?
    if [ "$sw_rc" -ne 0 ]; then
      cat "$CONTROL_DIR/handoff-tune-boot.log"
      if sh "$MODDIR/tune.sh" stop > "$CONTROL_DIR/handoff-rollback-stop.log" 2>&1 && rollback_to_kernel; then
        echo "source=kernel"; echo "error: Module presets could not be applied; the previous Kernel profile was restored"; return 1
      fi
      emit_conflict_recovery
      return 1
    fi
    cat "$CONTROL_DIR/handoff-tune-stop.log" "$CONTROL_DIR/handoff-tune-boot.log" 2>/dev/null | grep -E '^(warn:|error:)' || :
    echo "source=module"; echo "Module presets now control CPU/GPU limits"; return 0
  fi

  # target=kernel. Re-confirm None/off before releasing module limits; never trust a stale WebUI status.
  if ! neutralize_kernel; then
    if rollback_to_module; then
      echo "source=module"; echo "error: Kprofiles could not be confirmed at None/off; module controller was restored"; return 1
    fi
    emit_conflict_recovery
    return 1
  fi
  if ! sh "$MODDIR/tune.sh" stop > "$CONTROL_DIR/handoff-tune-stop.log" 2>&1; then
    cat "$CONTROL_DIR/handoff-tune-stop.log"
    if rollback_to_module; then
      echo "source=module"; echo "error: module limits could not be released; module controller was restored"; return 1
    fi
    emit_conflict_recovery
    return 1
  fi
  # Kernel-only mode must keep a verified record of the phone's original CPU/GPU limits. Capture only
  # after the module caps have been released, so no module limit is accidentally recorded as Stock.
  if ! sh "$MODDIR/tune.sh" stock-recorded > "$CONTROL_DIR/handoff-stock-check.log" 2>&1; then
    sh "$MODDIR/tune.sh" boot capture-only > "$CONTROL_DIR/handoff-capture.log" 2>&1 || :
    if ! sh "$MODDIR/tune.sh" stock-recorded >> "$CONTROL_DIR/handoff-stock-check.log" 2>&1; then
      cat "$CONTROL_DIR/handoff-capture.log" "$CONTROL_DIR/handoff-stock-check.log" 2>/dev/null
      if rollback_to_module; then
        echo "source=module"; echo "error: a complete stock CPU/GPU record could not be verified; kernel profile was not enabled"; return 1
      fi
      emit_conflict_recovery
      return 1
    fi
  fi
  if ! control_set SOURCE kernel; then
    if rollback_to_module; then
      echo "source=module"; echo "error: controller preference could not be saved; module controller was restored"; return 1
    fi
    emit_conflict_recovery
    return 1
  fi
  if ! sh "$MODDIR/kp.sh" mode "$pref_mode"; then
    if rollback_to_module; then
      echo "source=module"; echo "error: kernel mode could not be applied; module controller was restored"; return 1
    fi
    emit_conflict_recovery
    return 1
  fi
  kpnow=$(kp_status); support_auto=$(value "$kpnow" auto_support)
  case "$support_auto" in
    supported)
      if ! sh "$MODDIR/kp.sh" auto "$pref_auto"; then
        if rollback_to_module; then
          echo "source=module"; echo "error: auto_kp preference could not be applied; module controller was restored"; return 1
        fi
        emit_conflict_recovery
        return 1
      fi ;;
    unsupported) echo "warn: this kernel has no optional auto_kp parameter; profile mode was applied without it" ;;
    *) echo "warn: auto_kp is unreadable or unrecognized; kernel mode is active but the automatic preference was not changed" ;;
  esac
  echo "source=kernel"; echo "Kernel profile now controls performance"
  cat "$CONTROL_DIR/handoff-tune-stop.log" 2>/dev/null | grep -E '^warn:' || :
  return 0
}
case "$1" in
  init) cmd_init ;;
  status) cmd_status ;;
  switch) cmd_switch "$2" ;;
  *) echo "usage: control.sh init | status | switch module|kernel"; exit 1 ;;
esac
