#!/system/bin/sh
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
# "tune.sh resetall" stops the watcher and puts the phone's own limits back, then verifies them. The
# kernel's Kprofiles mode is NOT touched: this module does not manage it. If a limit cannot be put back
# (a control is gone, the kernel refuses, or something outside the module holds it), resetall exits 1 and
# everything the module saved is kept, so the restore can be tried again.
# (KernelSU-Next runs this at the next boot.)
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
