#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# Stop the watcher and put the phone's own limits back, put the kernel profile back to None,
# then delete the saved settings. (KernelSU-Next runs this at the next boot, when the kernel
# profile has normally reset already, so this is belt and braces.)
# If the watcher cannot be stopped, the saved settings and the recorded stock values stay: they are
# what a later restore needs, and the watcher itself also hands the limits back once the module's
# folder is marked for removal.
stopped=1
if [ -f "$MODDIR/tune.sh" ]; then sh "$MODDIR/tune.sh" stop >/dev/null 2>&1 || stopped=0; fi
if [ -f "$MODDIR/kp.sh" ]; then sh "$MODDIR/kp.sh" mode 0 >/dev/null 2>&1; fi
if [ "$stopped" = 1 ]; then
  rm -rf /data/adb/kprofiles_ui
fi
exit 0
