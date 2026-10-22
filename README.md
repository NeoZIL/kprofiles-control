# Kprofiles Control

A small KernelSU-Next module with a WebUI page for the **Kprofiles** driver that
is built into the Theettam kernel (POCO F6 / Redmi Turbo 3, `peridot`).

From one screen you can:

- pick the profile: **Off**, **Battery**, **Balanced** or **Performance**
- turn the **auto battery mode when the screen is off** switch (`auto_kp`) on or off
- choose whether your choices are **remembered after reboot**

The module's **Action** button in the manager cycles Battery, Balanced, Performance.

## What it controls

| What | Where in the kernel |
|:--|:--|
| Profile (0 Off, 1 Battery, 2 Balanced, 3 Performance) | `/sys/kernel/kprofiles/kp_mode` |
| Auto switch (`Y` or `N`) | `/sys/module/kprofiles/parameters/auto_kp` |

How much a profile changes depends on which parts of the kernel read it. Kprofiles
itself only keeps the mode number. Test one change at a time.

## Install

1. Download `Kprofiles-Control-v1.0.zip` from the Releases page, or from the
   latest successful run under Actions, then Artifacts (unzip the artifact once).
2. In the KernelSU-Next manager open **Modules** and install the zip.
3. Reboot, then open the module and tap **WebUI**.

## How it works

| File | Purpose |
|:--|:--|
| `module/kp.sh` | Reads and writes the two kernel files, validates input, saves choices |
| `module/webroot/index.html` | The WebUI page, calls `kp.sh` through the manager |
| `module/service.sh` | At boot, re-applies saved choices (about 10 s after boot completes) |
| `module/action.sh` | Action button: cycles the profile |
| `module/uninstall.sh` | Deletes saved settings in `/data/adb/kprofiles_ui` |

Every write is read back. If the kernel disagrees, the WebUI shows an error.
Saved choices live in `/data/adb/kprofiles_ui/config`. Reboot to undo any live change
when "remember my choices" is off.

## Build

```
sh tests/kp-test.sh   # off-device self-test with fake sysfs files
sh build.sh           # writes dist/Kprofiles-Control-<version>.zip
```

GitHub Actions runs the same two steps on every push. Push a tag such as `v1.0`
to publish a release with the zip attached.

## Status

Confirmed working by the author on a POCO F6 (`peridot`) with the Theettam 6.1.176
kernel and KernelSU-Next 3.4.2: it installs and the WebUI runs. How much a profile
changes battery or smoothness depends on the kernel, so measure it yourself. If a
write is refused, the WebUI shows the message. Please open an issue with it.

## License

MIT
