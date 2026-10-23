#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# Stop the watcher and put the phone's own limits back, then delete saved settings.
[ -f "$MODDIR/tune.sh" ] && sh "$MODDIR/tune.sh" stop >/dev/null 2>&1
rm -rf /data/adb/kprofiles_ui
