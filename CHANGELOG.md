# Changelog

## v1.1.3
- Fix: disabling or removing the module in the manager now hands the limits back. The watcher
  used to keep re-applying them until the next reboot, because the manager only drops a marker
  file. The watcher now looks for `disable` / `remove` in the module folder.
- The screen watcher reads the brightness with shell built-ins instead of starting `cat` and a
  subshell every second (about 30% fewer processes started while the screen is off).
- Presets fail closed: a value is also skipped, with a warning, when the controls exist but
  the phone's list of available frequencies cannot be read. Missing controls still report
  "controls not found".
- Stock and Apply now warn when the phone's own limits were never recorded (kernel Battery was
  on before the first recording), instead of silently leaving the caps in place until a reboot.
- `uninstall.sh` always deletes `/data/adb/kprofiles_ui`; a stray `CFG_DIR` in the environment
  can no longer redirect `rm -rf`.
- The page says "Applied, with a warning" (not "the kernel did not accept") because warnings can
  also come from skipped preset values or missing stock values.
- Tests: disable and remove markers, unreadable and empty lists, the missing-stock warning,
  stray `CFG_DIR`, brightness reading. Each new test was checked by deliberately breaking the
  code. README: who controls what, and a short on-phone check of the kernel profile modes.

## v1.1.2
- New **Reset everything** button (and `tune.sh resetall`): Stock limits and the kernel profile
  set to None. The Stock preset text now says it only covers the CPU/GPU limits.
- Stock values are never recorded while the kernel Battery profile is on (it lowers the values
  the module reads) or while the module's own limits are in place.
- Uninstall also sets the kernel profile to None before deleting settings.
- Tests: the boot test now simulates a real reboot (the phone's own values return) instead of
  accepting an already-limited value as stock; new tests for stock changing between boots,
  Reset everything, uninstall, the capture guards, and that `tune.sh` never writes the kernel
  profile node. Each new test was checked by deliberately breaking the code.
- README: install filename no longer pinned to a version; explains how the limits and the
  kernel profile combine.

## v1.1.1
- Fix: at boot the module now saves the phone's own limits before applying the kernel
  profile. Before, a kernel Battery profile kept from the last session could be recorded
  as "stock", and Stock would then restore the capped values.
- Presets are now checked against the phone's available frequency lists too; unavailable
  values are skipped with a warning.
- Uninstall stops the watcher and restores the phone's limits first.
- `action.sh` and `service.sh` find their own folder even when started without a path.
- Tests: the watcher test polls instead of sleeping for fixed times; new tests for preset
  validation and boot order.
- CI: ShellCheck, tests under mksh and busybox ash as well as dash, and a check that the
  release tag matches `module.prop`.

## v1.1
- CPU and GPU min/max limits with presets (Stock, Battery tilt, Battery saver) and custom
  values, with separate screen-on and screen-off sets.
- Kernel profile card rewritten to say what each mode really does; the `auto_kp` toggle
  was removed because this kernel never reads it.

## v1.0
- First release: WebUI for the Kprofiles mode and the `auto_kp` switch.
