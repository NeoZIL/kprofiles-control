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
| **Stock** | the phone's own CPU/GPU limits | the phone's own CPU/GPU limits |
| **Battery tilt** | big max 2188.8 MHz, prime max 2457.6 MHz, GPU max 736 MHz | little max 1017.6, big max 787.2, prime max 633.6, GPU max 353 MHz |
| **Battery saver** | little and big max 1593.6, prime max 1766.4, GPU max 633 MHz | little max 787.2, big max 633.6, prime max 633.6, GPU max 255 MHz |

Stock removes the limits this module set. It does not touch the kernel profile; the
**Reset everything** button does both (Stock limits and kernel profile None).

A preset only fills in the values. Edit any picker afterwards and the preset becomes
"custom". The Action button in the manager cycles Stock, Battery tilt, Battery saver.

### How the screen-off set works

A small background script reads `/sys/class/backlight/panel0-backlight/brightness`
every 1 to 3 seconds. Brightness 0 means screen off. With an always-on display the
value may be above 0, which counts as "screen on". If the node does not exist the
module always uses the screen-on set.

### Safety

- Values outside the phone's available list are rejected. Presets follow the same rule: a preset
  value that is not in the list, or whose list cannot be read, is skipped with a warning.
- The phone's own limits are saved at every boot and restored by **Stock**, by the
  "Apply my limits" switch, and when a value is set back to Default.
- Android's own changes (for example a temporary boost) are left alone for any value
  you did not set. Values you did set are re-applied about every 10 to 30 seconds.
- Recovery if the phone feels wrong: tap **Stock**; or disable or uninstall the module in
  the manager (the watcher notices within a few seconds and hands the limits back; the
  kernel profile is separate, use **Reset everything** for that); or from a recovery create
  an empty file `/data/adb/kprofiles_ui/skip` (nothing is applied at boot while it exists).

### How the limits and the kernel profile combine

They never overwrite each other. Writing a value to `scaling_max_freq` only updates this
module's own request to the kernel; the kernel profile's caps are separate requests. The
kernel enforces the **lowest** maximum of all requests, so with the kernel Battery profile on,
a limit you set above its cap is accepted but has no effect until the profile is None. The
page then shows a warning that the kernel did not take the value, which is expected.

Who controls what: `kp.sh` is the only script that writes the kernel profile. `tune.sh` only
reads it, and writes nothing but the min and max nodes of the three CPU clusters and the GPU.

### Checking this on your phone

The statements above come from reading the kernel source, so confirm them once on the device
(as root, for example through `adb shell su`). For each kernel profile `N` in 0, 1, 2 and 3:

```
M=/data/adb/modules/kprofiles_ui
sh $M/kp.sh mode N
sh $M/tune.sh cfg ON_BIG_MAX 2188800
cat /sys/devices/system/cpu/cpufreq/policy3/scaling_max_freq
```

Expected: with 0, 2 and 3 the file shows `2188800`; with 1 it shows the Battery cap (about
`1286400`) and the call prints a warning. If the cap ever shows the higher value, or the value
flips back and forth, please open an issue with the output. Finish with **Reset everything**.
To check the disable handling, turn the module off in the manager with a preset active and
read `scaling_max_freq` again a few seconds later: it should be back at the phone's own value.

## Kernel profile (advanced)

The Theettam kernel contains the Kprofiles driver. It only stores a number; other
kernel code reacts to it. Reading the kernel source, this is what each mode does:

| Mode | Effect |
|:--|:--|
| None (0 or 2) | no kernel caps |
| Battery (1) | little cores capped at about 1.59 GHz, big cores about 1.29 GHz, prime core held at its lowest speed, always on |
| Performance (3) | no CPU caps; the GPU can no longer be slowed by the thermal controller |

The Battery mode lowers the value `scaling_max_freq` reports, so at boot the module saves
the phone's own limits **before** it applies the kernel profile, and it never records stock
values while the kernel Battery profile is on or while its own limits are in place. If you ever see a stock
value that looks capped, set the kernel profile to None, reboot, and let it save again.

The driver also has an `auto_kp` switch, but this kernel never reads it, so it does
nothing. The module no longer shows it.

## Install

1. Download the newest `Kprofiles-Control-v*.zip` from Releases (or Actions, then Artifacts;
   unzip the artifact once).
2. In the KernelSU-Next manager open **Modules**, install the zip, then reboot.
3. Open the module and tap **WebUI**.

## Updating

From v1.1.4 on, the module updates itself through the KernelSU-Next manager. Its `module.prop`
has an `updateJson` link that points at `update.json` on the newest GitHub release. When a newer
version is published, the module in the manager's **Modules** list shows an update button with the
release notes. Tap it, let it install, then reboot. Your settings are kept.

- The first install of v1.1.4 has to be done by hand (step above), because older versions have no
  update link.
- The manager compares `versionCode`, so every release must raise it by at least one. The release
  step refuses a `versionCode` that is not higher than the current latest release's.
- The installed version is shown under the title in the WebUI.
- Nothing is downloaded in the background, and the module itself never uses the network. The
  manager does the check and the download, and only when you open it.

## Releasing (maintainers)

1. Raise `version` (exactly `vMAJOR.MINOR.PATCH`) and `versionCode` (a whole number, higher than the
   last release's, no leading zero) in `module/module.prop`, and add a `## <version>` section to
   `CHANGELOG.md`. The build stops without that section; it becomes the release notes.
2. Commit and push. When Actions is green, push a tag equal to the version (for example `v1.1.4`).
3. Actions builds the zip and runs `release.sh`: it creates the release as a draft, attaches
   `Kprofiles-Control-<version>.zip`, `update.json` and `changelog.md`, publishes it as the latest
   release, then downloads `latest/download/update.json` and checks that the zip and changelog it
   names resolve. Let the tag create the release. If you create one yourself first, the files are
   attached, and a draft is published; but a release you publish by hand is public for a moment
   before its files arrive.
4. Re-running the workflow for an older tag only repairs that release's files; it does not become
   the latest release. On a release that is already public it only attaches missing files and never
   replaces one (a failed replacement would leave users without it); if a public file differs from
   the build, the job stops and asks you to delete that file on the release page first.
5. If GitHub cannot be reached while the job looks up the latest release, the job fails instead of
   guessing. Re-run it.

`sh build.sh` writes the same three files to `dist/` for a local check.

## How it works

| File | Purpose |
|:--|:--|
| `module/tune.sh` | Frequency limits, presets, screen watcher, restore logic |
| `module/kp.sh` | Reads and writes the kernel Kprofiles mode |
| `module/webroot/index.html` | The WebUI page |
| `module/module.prop` | Version, and the `updateJson` link the manager uses to offer updates |
| `build.sh` | Builds the zip, `update.json` and the release notes into `dist/` |
| `release.sh` | Publishes `dist/` as a GitHub release (draft first, versionCode check, post-release check) |
| `module/service.sh` | At boot (about 25 s after boot completes): save the phone's limits, re-apply yours |
| `module/action.sh` | Action button: cycle presets |
| `module/uninstall.sh` | Runs `tune.sh resetall` (kernel profile to None first, then stops the watcher and restores the phone's limits) and deletes saved settings only if that worked; otherwise they are kept and it exits 1 |

## Build and test

```
sh tests/kp-test.sh     # kernel profile script, fake sysfs
sh tests/tune-test.sh   # frequency script and screen watcher, fake sysfs
sh tests/build-test.sh  # zip, update manifest and release notes
sh tests/release-test.sh  # release.sh rules against a fake gh (no network)
sh build.sh             # writes dist/Kprofiles-Control-<version>.zip, update.json, changelog.md
```

GitHub Actions runs ShellCheck, then all four tests under dash, **mksh** (the shell Android
uses) and busybox ash, and checks that a pushed tag matches the `version` in
`module.prop`. Push a tag such as `v1.1.4` to publish a release.

## Status

v1.0, v1.1 and v1.1.4 are confirmed working by the author on a POCO F6 (`peridot`) with the
Theettam 6.1.176 kernel and KernelSU-Next 3.4.2. v1.2.0 is covered by off-device tests (script
logic against a fake copy of the phone's frequency tables, run in CI under dash, mksh and busybox
ash, and the page in a simulated browser) and has not been tried on the phone yet; the same goes
for v1.1.5 to v1.1.9. Android or Xiaomi services may override some
values. Every write is checked and the page shows a warning if the kernel did not accept
it. Please open an issue with that message.

## License

MIT
