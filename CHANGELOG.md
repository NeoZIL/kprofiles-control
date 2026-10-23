# Changelog

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
