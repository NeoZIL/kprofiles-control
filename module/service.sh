#!/system/bin/sh
# At boot: wait until Android has settled, save the phone's own frequency limits,
# then re-apply your saved choices.
MODDIR=${0%/*}
D=/data/adb/kprofiles_ui
mkdir -p "$D" 2>/dev/null
# Safety switch: create /data/adb/kprofiles_ui/skip (for example from OrangeFox) to boot without applying anything.
[ -f "$D/skip" ] && exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 25
{ sh "$MODDIR/kp.sh" apply; sh "$MODDIR/tune.sh" boot; } > "$D/boot.log" 2>&1
