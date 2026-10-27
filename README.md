# Kprofiles Control

A KernelSU-Next module with a POCO F6 / Redmi Turbo 3 (`peridot`) CPU/GPU tuning engine,
plus optional Kprofiles mode control for kernels that implement the documented Kprofiles sysfs ABI.
The CPU/GPU frequency paths and preset values remain specific to the F6 / Theettam configuration;
Kprofiles support is detected independently. The v4.0.3 interface is organized into Home, CPU & GPU,
Kernel, Monitor, and Settings pages. From the UI you can:

- choose **Stock, Battery tilt, Battery saver, Performance, Custom, or Dynamic** CPU/GPU profiles
- use **different limits when the screen is on and when it is off**
- use the kernel's built-in **Kprofiles** modes when the documented mode interface is present and readable
- inspect engine-reported CPU/GPU limits and screen-watcher state
- view live CPU cluster, GPU and battery telemetry without changing tuning settings

### WebUI layout and responsiveness

The five screens share one lightweight, offline HTML page. Bottom navigation switches
which page is visible locally without reloading the document. The UI uses no remote fonts,
scripts, or UI frameworks. A single read-only `monitor.sh snapshot` call samples CPUFreq policies,
`/proc/stat`, matching thermal zones/hwmon sensors, GPU devfreq/KGSL counters and battery power-supply
attributes every 5 seconds while Monitor is visible. Polling stops when another page is selected
or the WebView becomes hidden; when the WebView is hidden, a one-shot screen/battery probe may capture
an idle-drain baseline regardless of which in-app page was open. The Home Live Monitoring card is a
navigation shortcut and does not start a separate sampler. DOM values are only rewritten when they change. Current CPU/GPU frequencies include the `MHz` unit and are shown
beside utilization; the percentage in brackets is activity/utilization, not frequency as a percentage of maximum.
CPU utilization is computed from successive `/proc/stat` counter samples as `(delta total - delta idle - delta I/O wait) / delta total × 100`; for a cluster, the counter deltas are aggregated across CPUs in that policy. The first sample establishes a baseline, so the percentage is unavailable until a second sample exists. GPU utilization uses the driver's busy-percentage value where available, otherwise deltas of GPU busy/total counters or busy-time/total-time counters.
Active/idle battery drain uses the charge counter relative to full-charge capacity where reliable, with battery-percentage change as a fallback; only discharging intervals are counted. The latest valid estimates survive WebUI reopen/reload and are labelled as last measured while the active estimate refreshes. Active sample history expires when stale and is cleared across hidden/screen-off transitions, so the screen-off gap is not included in active drain. The screen-off estimate is best-effort: it uses a baseline captured when the WebView becomes hidden and the display is confirmed off, then a sample when the WebView returns. If you wake the phone and use other apps before returning to this WebUI, that interval may include screen-on use and should not be treated as a laboratory-grade idle measurement. Battery power prefers the standard `power_now` property, but sanity-checks it against current × voltage where both measurements exist. Missing or unidentifiable sensors display Unavailable rather than invented values. Malformed or missing controller status is treated as Unknown/conflict, not inferred to mean Module presets.
Battery temperature badges use stricter warning bands than CPU/SoC/GPU temperature badges. These labels are visual indicators only; Android and the kernel remain responsible for thermal throttling. The existing Monitor status, kernel status and explanatory cards remain below the live panel. The
interface follows the device's light/dark theme and respects reduced-motion preferences.

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
| **Performance** | phone's own limits; no additional caps from this module | phone's own limits; screen-off capping is disabled |
| **Custom** | preserves your saved screen-on choices | preserves your saved screen-off choices |
| **Dynamic** | phone's own limits; no extra caps while the screen is on | battery-tilt caps while the screen is off |

Stock restores the saved limits and disables this module's tuning. **Performance** keeps the module's
settings active but applies no extra frequency caps; it does **not** overclock or bypass thermal controls. The separate kernel **Performance** mode is a different feature.
Dynamic leaves screen-on behavior to the phone and applies lower maxima only when the screen is off.
Custom preserves the current saved limits and opens the existing pickers for editing. The outlined **Reset everything** button uses a red icon and label (not a solid red fill); it restores Stock and sets the separate kernel profile to None.

A preset only fills in the values. Edit any picker afterwards and the preset becomes "custom".

The Action button in the manager continues to cycle Stock, Battery tilt and Battery saver (from any other profile it goes to Stock). The WebUI
also requires Stock or Reset everything as a bridge between Battery tilt and Battery saver, even if
you select another profile in between.

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
- A stock minimum at or above its maximum is never recorded. That reading means something is holding
  the cluster up (for example a boot boost), so boot waits up to about a minute for it to end, and
  otherwise keeps the earlier record. A recorded minimum like that is also never written back. A
  cluster counts as having a single frequency only if its list of available frequencies can be read
  and holds exactly one; a missing or unreadable list does not.
- If the phone's own limits cannot be saved at boot and no earlier record exists, the kernel profile
  is not applied at that boot (`boot.log` says so); reboot or open the app to try again.
- Android's own changes (for example a temporary boost) are left alone for any value
  you did not set. Values you did set are re-applied about every 10 to 30 seconds.
- Recovery if the phone feels wrong: tap **Stock**; or disable or uninstall the module in
  the manager (the watcher notices within a few seconds and hands the limits back; the
  kernel profile is separate, use **Reset everything** for that); or from a recovery create
  an empty file `/data/adb/kprofiles_ui/skip` (nothing is applied at boot while it exists).

### Exclusive control source: Module presets or Kernel profile

Only one controller may own CPU/GPU performance settings at a time. The Home page exposes an
explicit **Control source** choice:

- **Module presets**: the module's preset engine and screen watcher own CPU/GPU frequency limits.
  The kernel profile is verified at **None** and `auto_kp` is turned off when that optional
  parameter is present and safely writable. The previously selected kernel mode and auto preference
  are saved separately so they can be restored when switching back.
- **Kernel profile**: the module watcher is stopped and its applied CPU/GPU limits are restored to
  the recorded stock values before the saved Kprofiles mode and optional `auto_kp` preference are
  applied. The module's preset and custom selections remain saved but are not applied while this
  source is active.

The handoff is performed by `control.sh`, not just by disabling WebUI buttons. `tune.sh` refuses
preset changes while Kernel profile owns tuning, and `kp.sh` refuses non-None modes or `auto_kp=Y`
while Module presets owns tuning. Boot initialization reads the saved source and only starts that
controller. Kernel profile is not activated at boot unless a complete stock CPU/GPU record is
available. A handoff isn't reported as successful until the outgoing controller is released and
the incoming controller is verified; an incomplete handoff enters the existing recovery lock.

On first upgrade, an existing combination of a non-Stock module preset and an active kernel mode
(or enabled `auto_kp`) is treated as a **conflict**. Neither side is silently chosen or applied; open
the WebUI and select a controller explicitly. If the Kprofiles interface is genuinely absent,
Module presets can run without the kernel controller and the selector is hidden. If the interface
exists but is unreadable or reports an unknown mode, exclusive control cannot be confirmed and the
module fails closed until the state is resolved. The optional `auto_kp` setting is stored as `Y`/`N`
even on kernels where its live sysfs node uses numeric `0`/`1` values.

The currently allowed min/max values are separate from the hardware's `cpuinfo_min_freq` and
`cpuinfo_max_freq` capabilities. The Monitor panel displays the limits currently enforced/requested
by the active CPUFreq policy; it does not claim the silicon capability maximum is the active cap.

### Checking this on your phone

CPU/GPU frequency behavior described above is specific to the POCO F6 / Theettam configuration. Kprofiles support is detected at the two node locations listed in the Kernel profiles section; a kernel that uses other paths requires a separately reviewed adapter. The statements above come from reading the kernel source, so confirm them once on the device
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

## Kernel profiles (advanced)

The WebUI checks `kp.sh status` before exposing kernel profiles. The Kprofiles mode node uses values
0–3 and is looked for at `/sys/kernel/kprofiles/kp_mode` and then at the upstream module parameter
`/sys/module/kprofiles/parameters/kp_mode`; `auto_kp` is looked for at
`/sys/module/kprofiles/parameters/auto_kp` and then at `/sys/kernel/kprofiles/auto_kp`. A missing mode node is
reported as **unsupported**; a node that exists but cannot be read or reports an unrecognized value
is **not confirmed**. In either case, the controls stay disabled and no mode write is attempted.
**Reset everything** and uninstall also leave an unconfirmed node alone (with a warning, not an error) and judge success by the CPU/GPU limits themselves, which are still verified; a node that reads a valid mode but refuses the write is still reported as an error.
When supported, tap the collapsed **Kernel profiles** button to reveal None, Battery, Balanced and
Performance. The kernel **Performance** mode (Kernel page) is distinct from the CPU/GPU **Performance**
profile (CPU & GPU page); the CPU/GPU one adds no caps and is not an overclock.

The main Kprofiles mode interface is separate from the optional `auto_kp` module parameter. Some
kernels do not expose that parameter or do not use it. If it is absent, the module can still apply a
saved kernel mode; it reports the optional auto setting as skipped rather than failing the mode apply.
A present but unreadable or malformed parameter is treated as an error. Kprofiles mode numbers are
standardized, but what each mode actually changes is defined by the code in the particular kernel.

The standard mode numbers and names are:

| Mode | Standard name |
|:--|:--|
| 0 | Disabled / None |
| 1 | Battery |
| 2 | Balanced |
| 3 | Performance |

The name is standardized, but the actual effect of each mode depends on the kernel implementation.
On the Theettam kernel used for development, mode 1 lowered `scaling_max_freq` for CPU clusters; modes 0 and 2 did not impose those observed caps, and mode 3 affected GPU thermal behavior. Do not assume those effects on another kernel. If using a different kernel, check its source or maintainer documentation before relying on a mode's thermal or power behavior.

At boot, the module saves the phone's own CPU/GPU limits before it applies the selected kernel profile and avoids recording stock values while its own limits are in place. On the Theettam Battery mode, `scaling_max_freq` is reduced, so the original values are especially important to preserve.

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
| `module/kp.sh` | Detects the documented Kprofiles mode interface and reads/writes supported modes |
| `module/webroot/index.html` | The WebUI page and live-monitor renderer |
| `module/monitor.sh` | Read-only hardware telemetry discovery/snapshot helper |
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

GitHub Actions runs ShellCheck, then all six test suites under dash, **mksh** (the shell Android
uses) and busybox ash, and checks that a pushed tag matches the `version` in
`module.prop`. The controller-source suite validates legacy migration, exclusive writes, verified handoffs and recovery behavior. Push a tag such as `v4.0.0` to publish a release.

## Status

v1.0, v1.1 and v1.1.4 were confirmed working by the author on a POCO F6 (`peridot`) with the
Theettam 6.1.176 kernel and KernelSU-Next 3.4.2. v1.4.3 has had on-device checks for boot, Tilt,
Stock restoration, screen transitions, and preset switching; intermittent historical kernel restore
refusals were observed and their cause remains unconfirmed. v1.4.4 added WebUI-only switching,
8-second cooldown, and recovery-lock guardrails. v2.0.0 improved frequency-failure recognition and
recovery unlock rules. v3.0.0 keeps profile controls disabled until the first successful status read and
persists the latest failed-reset detail across WebUI reloads. v3.1.0 added the CPU/GPU **Performance** profile (first called No Extra Caps; stored internally as `performance`), Custom and
Dynamic preset entries, a supported-kernel-only Kernel profiles accordion, and a red Reset everything
control. v3.2.0 reorganized the WebUI into five locally navigated screens without changing the tuning
engine. v3.2.1 and v3.5.0 polish the icons; v3.5.0 also changes how the phone's own limits are recorded
(see CHANGELOG.md). v4.0.0 adds universal-interface, read-only live telemetry and mutually exclusive Module presets / Kernel profile control; it still needs on-device
validation through the installed WebUI to confirm handoffs, performance and drain-rate behavior.
The page shows the engine's warning/error text and leaves only Reset everything available after a
reported frequency restore/apply mismatch. This is a UI safeguard, not an engine fix, and it cannot detect a
silent mismatch the engine does not report. Android or Xiaomi services may override some values.
Every write is checked and the page shows a warning if the kernel did not accept it. Please open an
issue with that message.

## License

MIT
