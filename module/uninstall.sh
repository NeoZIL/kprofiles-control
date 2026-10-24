#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# Stop the watcher and put the phone's own limits back, put the kernel profile back to None,
# then delete the saved settings. (KernelSU-Next runs this at the next boot, when the kernel
# profile has normally reset already, so this is belt and braces.)
# The saved settings, the recorded stock values and the "changed" markers are what a later restore
# needs. They are deleted only when EVERYTHING above worked: the watcher stopped, every limit was put
# back and verified, and the kernel profile is None. Otherwise they stay (and the exit status is 1);
# the watcher also hands the limits back itself once the module's folder is marked for removal.
done_ok=1
if [ -f "$MODDIR/tune.sh" ]; then sh "$MODDIR/tune.sh" stop >/dev/null 2>&1 || done_ok=0; fi
# A kernel without Kprofiles has nothing to reset; only a node that exists and cannot be reset counts.
if [ -f "$MODDIR/kp.sh" ] && [ -e "${KP_PATH:-/sys/kernel/kprofiles/kp_mode}" ]; then
  sh "$MODDIR/kp.sh" mode 0 >/dev/null 2>&1 || done_ok=0
fi
if [ "$done_ok" = 1 ]; then
  rm -rf /data/adb/kprofiles_ui
  exit 0
fi
echo "uninstall: the phone's own values or the kernel profile could not be restored; saved settings kept" >&2
exit 1
