# Kprofiles Control

A KernelSU-Next module with a WebUI page for the Theettam kernel on the POCO F6 /
Redmi Turbo 3 (`peridot`). From one screen you can:

- set **CPU and GPU speed limits** with presets or your own values
- use **different limits when the screen is on and when it is off**
- switch the kernel's built-in **Kprofiles** mode

## Frequency limits

Three CPU clusters and the GPU each get a **min** and a **max**:

| Control | Cluster | Node used |
|:--|:--|:--|
| Little cores | CPU0 to 2 | `cpufreq/policy0/scaling_{min,max}_freq` |
| Big cores | CPU3 to 6 | `cpufreq/policy3/scaling_{min,max}_freq` |
| Prime core | CPU7 | `cpufreq/policy7/scaling_{min,max}_freq` |
| GPU | kgsl | `/sys/class/kgsl/kgsl-3d0/devfreq/{min,max}_freq` |

The pickers only list frequencies the phone itself reports as available. Pick
**Default** to leave a value alone. Only values you pick are ever written.

### Presets

| Preset | Screen on | Screen off |
|:--|:--|:--|
| **Stock** | the phone's own limits | the phone's own limits |
| **Battery tilt** | big max 2188.8 MHz, prime max 2457.6 MHz, GPU max 736 MHz | little max 1017.6, big max 787.2, prime max 633.6, GPU max 353 MHz |
| **Battery saver** | little and big max 1593.6, prime max 1766.4, GPU max 633 MHz | little max 787.2, big max 633.6, prime max 633.6, GPU max 255 MHz |

A preset only fills in the values. Edit any picker afterwards and the preset becomes
"custom". The Action button in the manager cycles Stock, Battery tilt, Battery saver.

### How the screen-off set works

A small background script reads `/sys/class/backlight/panel0-backlight/brightness`
every 1 to 3 seconds. Brightness 0 means screen off. With an always-on display the
value may be above 0, which counts as "screen on". If the node does not exist the
module always uses the screen-on set.

### Safety

- Values outside the phone's available list are rejected.
- The phone's own limits are saved at every boot and restored by **Stock**, by the
  "Apply my limits" switch, and when a value is set back to Default.
- Android's own changes (for example a temporary boost) are left alone for any value
  you did not set. Values you did set are re-applied about every 10 to 30 seconds.
- Recovery if the phone feels wrong: tap **Stock**; or disable or uninstall the module in
  the manager; or from a recovery create an empty file
  `/data/adb/kprofiles_ui/skip` (nothing is applied at boot while it exists).

## Kernel profile (advanced)

The Theettam kernel contains the Kprofiles driver. It only stores a number; other
kernel code reacts to it. Reading the kernel source, this is what each mode does:

| Mode | Effect |
|:--|:--|
| None (0 or 2) | no kernel caps |
| Battery (1) | little cores capped at about 1.59 GHz, big cores about 1.29 GHz, prime core held at its lowest speed, always on |
| Performance (3) | no CPU caps; the GPU can no longer be slowed by the thermal controller |

The driver also has an `auto_kp` switch, but this kernel never reads it, so it does
nothing. The module no longer shows it.

## Install

1. Download `Kprofiles-Control-v1.1.zip` from Releases (or Actions, then Artifacts;
   unzip the artifact once).
2. In the KernelSU-Next manager open **Modules**, install the zip, then reboot.
3. Open the module and tap **WebUI**.

## How it works

| File | Purpose |
|:--|:--|
| `module/tune.sh` | Frequency limits, presets, screen watcher, restore logic |
| `module/kp.sh` | Reads and writes the kernel Kprofiles mode |
| `module/webroot/index.html` | The WebUI page |
| `module/service.sh` | At boot (about 25 s after boot completes): save the phone's limits, re-apply yours |
| `module/action.sh` | Action button: cycle presets |
| `module/uninstall.sh` | Deletes saved settings in `/data/adb/kprofiles_ui` |

## Build and test

```
sh tests/kp-test.sh     # kernel profile script, fake sysfs
sh tests/tune-test.sh   # frequency script and screen watcher, fake sysfs
sh build.sh             # writes dist/Kprofiles-Control-<version>.zip
```

GitHub Actions runs the same steps on every push. Push a tag such as `v1.1` to
publish a release with the zip attached.

## Status

v1.0 is confirmed working by the author on a POCO F6 (`peridot`) with the Theettam
6.1.176 kernel and KernelSU-Next 3.4.2. v1.1 passes its off-device tests (script logic
against a fake copy of the phone's frequency tables, and the page in a simulated
browser) but has not been confirmed on a phone yet. Android or Xiaomi services may
override some values. Every write is checked and the page shows a warning if the
kernel did not accept it. Please open an issue with that message.

## License

MIT
