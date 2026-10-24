#!/system/bin/sh
# At boot: wait until Android has settled, save the phone's own frequency limits FIRST
# (before the kernel profile can cap them), then re-apply your saved choices.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
D=/data/adb/kprofiles_ui
mkdir -p "$D" 2>/dev/null
# Safety switch: create /data/adb/kprofiles_ui/skip (for example from OrangeFox) to boot without applying anything.
[ -f "$D/skip" ] && exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 25
# Order matters: the kernel Battery profile lowers scaling_max_freq, so record the stock values before applying it.
# Policy when that recording fails: tune.sh boot exits 2 (or crashes) when the phone's own limits could not be
# saved AND no earlier record exists. Then the kernel profile is NOT applied at this boot (it could change the
# readings, and a Battery profile would keep the real values from being recorded later), and boot.log says so.
# Exit status 0 (all fine) or 1 (some other error, already reported above it) still applies it.
{
  sh "$MODDIR/tune.sh" boot; tune_rc=$?
  case "$tune_rc" in
    0) sh "$MODDIR/kp.sh" apply ;;
    1) echo "boot: tune.sh finished with errors (exit status 1, see above); this is not a failure to record the phone's own limits, so the kernel profile is applied"
       sh "$MODDIR/kp.sh" apply ;;
    *) echo "boot: tune.sh could not record the phone's own limits (exit status $tune_rc), so the kernel profile was NOT applied at this boot. Reboot, or open the app, to try again" ;;
  esac
} > "$D/boot.log" 2>&1
