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
{ sh "$MODDIR/tune.sh" boot; sh "$MODDIR/kp.sh" apply; } > "$D/boot.log" 2>&1
