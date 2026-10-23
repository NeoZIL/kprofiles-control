#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# Stop the watcher and put the phone's own limits back, put the kernel profile back to None,
# then delete the saved settings. (KernelSU-Next runs this at the next boot, when the kernel
# profile has normally reset already, so this is belt and braces.)
[ -f "$MODDIR/tune.sh" ] && sh "$MODDIR/tune.sh" stop >/dev/null 2>&1
[ -f "$MODDIR/kp.sh" ] && sh "$MODDIR/kp.sh" mode 0 >/dev/null 2>&1
rm -rf "${CFG_DIR:-/data/adb/kprofiles_ui}"
