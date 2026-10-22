#!/system/bin/sh
# Re-apply the saved choices after boot (only if "remember my choices" is on).
MODDIR=${0%/*}
mkdir -p /data/adb/kprofiles_ui 2>/dev/null
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 10
sh "$MODDIR/kp.sh" apply > /data/adb/kprofiles_ui/boot.log 2>&1
