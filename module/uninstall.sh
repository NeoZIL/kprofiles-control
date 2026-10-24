#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# "tune.sh resetall" does everything in the right order: the kernel profile goes back to None FIRST (a
# restrictive profile such as Battery can hold the limits down, so a restore attempted before it would
# be refused), then the watcher is stopped and the phone's own limits are put back and verified.
# (KernelSU-Next runs this at the next boot, when the kernel profile has normally reset already, so
# this is belt and braces.)
# The saved settings, the recorded stock values and the "changed" markers are what a later restore
# needs. They are deleted only when resetall succeeded; otherwise they stay, and the exit status is 1.
# The watcher also hands the limits back itself once the module's folder is marked for removal.
done_ok=0

if [ -f "$MODDIR/tune.sh" ] &&
   sh "$MODDIR/tune.sh" resetall >/dev/null 2>&1; then
  done_ok=1
fi

if [ "$done_ok" = 1 ]; then
  rm -rf /data/adb/kprofiles_ui
  exit 0
fi

echo "uninstall: restoration failed; saved settings and recovery data kept" >&2
exit 1
