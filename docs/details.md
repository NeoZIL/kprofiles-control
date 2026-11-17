# Details

The longer explanations behind the README. Nothing here is needed to use the module.

## Files

| File | Purpose |
|:--|:--|
| `module/tune.sh` | Frequency limits, presets, screen watcher, restore logic |
| `module/kp.sh` | Detects the Kprofiles mode interface and reads/writes supported modes |
| `module/control.sh`, `module/control-lib.sh` | Which controller owns performance (Module presets or Kernel profile), the handoff between them, and recovery |
| `module/monitor.sh` | Read-only hardware telemetry snapshot for the Monitor page |
| `module/monitor-daemon.sh` | Background collector for screen-on time and Active/Idle drain |
| `module/monitor-cache.sh` | Reads and writes the collector's saved totals and settings |
| `module/service.sh` | Boot script (about 25 s after boot completes): save the phone's limits, then start the chosen controller |
| `module/action.sh` | Action button: cycle Stock, Battery tilt, Battery saver |
| `module/uninstall.sh` | Runs `tune.sh resetall` and deletes saved settings only if that worked; otherwise keeps them and exits 1 |
| `module/webroot/index.html` | The WebUI |
| `module/module.prop` | Version, and the `updateJson` link the manager uses to offer updates |
| `build.sh`, `release.sh` | Build the zip, `update.json` and release notes; publish a release |

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

CPU/GPU frequency behavior described above is specific to the POCO F6 / Theettam configuration. Kprofiles support is detected at the two node locations listed in the Kernel profiles section; a kernel that uses other paths requires a separately reviewed adapter. The statements above come from reading the kernel source, so confirm them once on your device
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

## Battery monitor: how Active and Idle Drain are measured

Each **discharge cycle** has two independent sets of totals, each made of *time* and *charge*:

| | Time | Charge | Shown as |
|---|---|---|---|
| **Active** | time with the screen ON | current drawn in that time | Active drain (average mA) and Screen-on Time (SOT) |
| **Idle** | time with the screen OFF for at least 10 s (**confirmed Screen-Off Time**) | current drawn in that time | Idle drain (average mA) and Screen-off time |

**Average current = total charge ÷ total time** of that state, in mA. Next to it the card may show an estimated **%/h** (average current ÷ the battery's reported full-charge capacity); this line is labelled *est.* and is left out when the capacity is not available or implausible. Active and Idle never overlap, and neither includes charging time.

* **Units.** Charge is kept as an exact integer in microamp-milliseconds (1 mAh = 3,600,000,000 µA·ms) so no rounding error builds up; the UI converts to mA and mAh-based figures only for display.
* **Charge** is integrated from `current_now` with time-weighted trapezoids (the area between two adjacent readings), on the monotonic boot clock (`/proc/uptime`, which counts suspend time and ignores wall-clock changes). Readings are smoothed over about 10 s to reduce noise, and the smoothing restarts at every screen transition so one state's current never leaks into the other. Both signs of `current_now` are treated as the discharge magnitude; the value is read as microamps, the Linux power-supply unit.
* **The 10-second rule.** When the display turns off, the collector buffers the time and charge from the *original* turn-off moment. If the screen is still off after 10 s the whole interval, from that original moment, is confirmed and counted as idle, and idle keeps accumulating until the screen turns on. If the screen turns on first, the buffer is discarded: a short off interval is counted as neither screen-off time nor screen-on time.
* **Transition times.** At a screen change the real time is taken from Android's own screen-state event log when it is available (`logcat -b events`), so a delay in the collector, for example during deep sleep, does not move the boundary; otherwise the first sample that shows the new state is used. Across a transition each side uses its own state's reading.
* **Sampling.** Every 1 s while the screen is on and every 5 s while it is off (the proposed starting values; they are constants at the top of `monitor-daemon.sh` and can be overridden by environment variables when tuning). Routine saves to the cache are limited to one every 15 s, plus a save at every important change (screen transition, confirmation, plug-in or unplug, reset). `monitor-daemon.sh probe MODULE_DIR [SECONDS]` reports how often `current_now` actually changes, to check that the reading is fresh.
* **Gaps.** A gap between samples of more than 30 s (for example deep sleep) is still counted as time. Its charge comes from the fuel-gauge charge counter when that counter moved; otherwise it is interpolated between the two readings. Either way the result is marked *provisional* and the card says "Includes sleep gaps". A gap longer than 12 h, an unreadable screen state, a restart, a reboot or a monitor that was switched off is never guessed: nothing is counted for it. Time with no valid current reading still counts as screen time but is recorded as *unmeasured* and left out of the average's divisor, so a missing reading is never treated as 0 mA, and a card with only unmeasured time shows **Unavailable**.
* **Preliminary values.** Until 5 minutes of eligible time exist for a state, its average is labelled *Preliminary estimate*. A bounded 5-minute rolling window of recent eligible time is also kept per state (trimmed by time, not sample count) and saved as an internal recent-average estimate; it never changes the cycle totals and is not shown in the UI.
* **Cycles.** A cycle opens when the phone is unplugged and is finalized when it is plugged in; totals stay on screen, labelled *Last discharge cycle*, while charging, and a new cycle starts from zero at the next unplug. A battery at 100% or reporting "Not charging" while still on the charger is plugged in, so it neither ends nor restarts a cycle. A restart or reboot continues the open cycle without counting the time the collector was not running. Pending (unconfirmed) screen-off data and the measurement anchors are deliberately not saved: after a restart the collector re-reads the real screen and charger state and starts a fresh pending interval, so nothing can be counted twice; a reboot is recognised by the boot id and never subtracts timestamps across the two clocks.
* **Resets.** **Reset SOT** restarts Screen-on Time *and* Active Drain together (an average needs both halves) and keeps the idle side. **Reset data** clears both sides and any pending measurement. Neither starts a new cycle or touches Android's battery statistics. A generation number in the cache makes the collector pick up a reset and refuse to write older totals back. The earlier **Reset data on charging** switch and the 15/30/60 s refresh interval no longer exist, because the cycle lifecycle and cadence are fixed by this design.

Cycle totals, the monitoring preference and the generation number are stored in `/data/adb/kprofiles_ui/monitor-cache`, outside the replaceable module directory, and survive WebUI reopening and reboots; the WebUI only reads and displays them, so reopening it never restarts a measurement. If a state has no valid data the UI shows **Collecting data** or **Unavailable** rather than inventing a value. Charger-online reporting varies between kernels: the collector uses every `online` node it finds and falls back to the battery status; if a ROM exposes neither reliably, plug/unplug detection should be checked on the target device. The collector cannot know about a charge that happened while it was not running at all.

The DOM updates only values that change. Current CPU frequency includes the `MHz` unit and is displayed separately from utilization (`%`), which always occupies its own line; GPU frequency and utilization also have separate labels and values. The verbose **How to read this** explainer has been removed from Monitor to keep the dashboard compact. Percentages are utilization/activity, not frequency as a percentage of maximum. CPU utilization is computed from successive `/proc/stat` counter samples as `(delta total - delta idle - delta I/O wait) / delta total × 100`; for a cluster, the counter deltas are aggregated across CPUs in that policy. The first sample establishes a baseline, so the percentage is unavailable until a second sample exists. GPU utilization uses the driver's busy-percentage value where available, otherwise deltas of GPU busy/total counters or busy-time/total-time counters. Battery power prefers the standard `power_now` property, but sanity-checks it against current × voltage where both measurements exist. Missing or unidentifiable sensors display **Unavailable** rather than invented values. Malformed or missing controller status is treated as Unknown/conflict, not inferred to mean Module presets.

Battery temperature badges use stricter warning bands than CPU/SoC/GPU temperature badges. These labels are visual indicators only; Android and the kernel remain responsible for thermal throttling. The interface follows the device's light/dark theme and respects reduced-motion preferences.

## The WebUI page

The five screens (Monitor, CPU & GPU, Home, Kernel, Settings) are one offline HTML page. A floating, rounded bottom dock switches pages locally without reloading the document; the active page is highlighted and safe-area spacing is respected on narrow phones. The UI uses no remote fonts, scripts, or UI frameworks. Monitor shows battery readings, the latest Active/Idle Drain rates, and persistent Screen-on/Screen-off time totals first, CPU cluster cards and GPU information next, then the existing engine and kernel status. CPU/GPU hardware cards use a compact two-column layout where the screen width allows it. The Battery Monitor preferences are in Settings.

The visible hardware panel makes a single read-only `monitor.sh snapshot` call every 5 seconds while Monitor is visible. That live-telemetry sampler stops when another page is selected or the WebView becomes hidden. Separately, `monitor-daemon.sh` is launched by the boot service and measures battery use independently of WebUI visibility.
