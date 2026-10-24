#!/system/bin/sh
# At boot: wait until Android has settled, save the phone's own frequency limits, then re-apply your
# saved choices.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
D=/data/adb/kprofiles_ui
mkdir -p "$D" 2>/dev/null
# Safety switch: create /data/adb/kprofiles_ui/skip (for example from OrangeFox) to boot without applying anything.
[ -f "$D/skip" ] && exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 25
# One job. This module does not touch the kernel's Kprofiles mode at all, so there is no other step to
# order. tune.sh boot exits 0 (fine), 2 (the phone's own limits could not be saved and none were on record,
# so NO limit was changed) or 1 (some other error, already reported above it). The result goes to boot.log.
{
  sh "$MODDIR/tune.sh" boot; tune_rc=$?
  case "$tune_rc" in
    0) ;;
    2) echo "boot: the phone's own limits could not be recorded, so no limit was changed at this boot (exit status 2). Reboot, or open the app, to try again" ;;
    *) echo "boot: tune.sh finished with errors (exit status $tune_rc, see above)" ;;
  esac
} > "$D/boot.log" 2>&1
