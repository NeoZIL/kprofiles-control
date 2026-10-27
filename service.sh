#!/system/bin/sh
# Boot reconciliation: decide which controller owns tuning, neutralize the other safely, then apply only the selected side.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
D=/data/adb/kprofiles_ui
mkdir -p "$D" 2>/dev/null
# Safety switch: create /data/adb/kprofiles_ui/skip (for example from recovery) to boot without applying anything.
[ -f "$D/skip" ] && exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 25
{
  echo "boot: initializing exclusive controller source"
  ctl_out=$(sh "$MODDIR/control.sh" init 2>&1); ctl_rc=$?
  printf '%s\n' "$ctl_out"
  src=$(sh "$MODDIR/control.sh" status 2>/dev/null | sed -n 's/^source=//p' | head -n 1)
  case "$src" in
    module)
      if sh "$MODDIR/kp.sh" enforce-module; then
        sh "$MODDIR/tune.sh" boot
      else
        echo "boot: module source could not neutralize Kprofiles; no module frequency preset was applied"
        exit 1
      fi
      ;;
    kernel)
      # The init step has forced Kprofiles None/auto off first, so this captures the phone's stock limits
      # without applying any module preset. Only afterward may the saved kernel profile be restored.
      sh "$MODDIR/tune.sh" boot capture-only; cap_rc=$?
      if [ "$cap_rc" -eq 2 ]; then
        echo "boot: no usable stock record exists; the saved kernel profile was NOT applied this boot"
      else
        [ "$cap_rc" -eq 0 ] || echo "boot: stock limits could not all be refreshed (status $cap_rc); retaining an earlier record if present"
        if sh "$MODDIR/tune.sh" stock-recorded >/dev/null 2>&1; then
          sh "$MODDIR/kp.sh" apply
        else
          echo "boot: the stock record is incomplete; the saved kernel profile was NOT applied this boot"
        fi
      fi
      ;;
    conflict)
      echo "boot: controller conflict/unverified state. Neither tuning side will be auto-applied. Open WebUI and choose a controller."
      ;;
    *)
      echo "boot: controller state is not valid ($src); no tuning side was applied"
      ;;
  esac
} > "$D/boot.log" 2>&1
