# Kprofiles Control

A KernelSU-Next module for the POCO F6 / Redmi Turbo 3 (`peridot`). It gives you a WebUI for CPU and GPU frequency limits, separate limits for screen on and screen off, the kernel's Kprofiles modes, and a battery monitor that tracks screen-on time and how fast the battery drains.

I made it for the Theettam 6.1 kernel on my own phone, so the frequency paths and preset numbers are for that setup. The Kprofiles part is detected separately and should work on any kernel that has the same sysfs nodes.

## What it does

- Presets: Stock, Battery tilt, Battery saver, Performance, Dynamic and Custom
- Different limits for screen on and screen off
- Kernel Kprofiles modes (None, Battery, Balanced, Performance) when the kernel has them
- Only one thing controls performance at a time, either the module's presets or the kernel profile. You pick on the Home page.
- A Monitor page with live CPU, GPU and battery readings, screen-on time, and active/idle drain in mA

## Install

1. Download the newest `Kprofiles-Control-v*.zip` from Releases.
2. In the KernelSU-Next manager go to Modules, install the zip, reboot.
3. Open the module and tap WebUI.

Updates show up in the manager's module list. Install, reboot, your settings stay.

## Presets

| Preset | Screen on | Screen off |
|:--|:--|:--|
| Stock | phone's own limits | phone's own limits |
| Battery tilt | big max 2188.8 MHz, prime max 2457.6, GPU max 736 | little max 1017.6, big 787.2, prime 633.6, GPU 353 |
| Battery saver | little and big max 1593.6, prime 1766.4, GPU 633 | little 787.2, big 633.6, prime 633.6, GPU 255 |
| Performance | no extra caps | no extra caps |
| Dynamic | no extra caps | the Battery tilt caps |
| Custom | your own values | your own values |

Performance doesn't overclock anything or touch thermals, it just means the module adds no caps. Custom values are edited on the CPU & GPU page and applied together with Save & Apply.

Only values you pick are written, and only ones the phone lists as available. Stock puts back the limits the phone had at boot. The Action button in the manager cycles Stock, tilt, saver.

Screen off is read from the backlight (brightness 0). With an always-on display the screen counts as on.

## If something goes wrong

- Tap Stock, or Reset everything (stock limits and kernel profile None).
- Disable or uninstall the module in the manager. The watcher hands the limits back within a few seconds.
- From recovery, create an empty file `/data/adb/kprofiles_ui/skip`. Nothing is applied at boot while it exists.

## Battery monitor

A small background script samples `current_now` (every second with the screen on, every 5 s off) and adds up charge over time. Average mA is charge divided by time, kept separately for screen on and screen off. Charging time is never counted, and when a reading is missing it shows Unavailable instead of a guess. How it handles sleep gaps, reboots and resets is in [docs/details.md](docs/details.md).

## Build and test

```
sh build.sh                       # zip, update.json and release notes in dist/
sh tests/tune-test.sh             # and the other tests/*-test.sh, see docs/releasing.md
node tests/webui-dom-test.js module/webroot/index.html
```

More in [docs/details.md](docs/details.md) (how each part works) and [docs/releasing.md](docs/releasing.md) (releases, CI, all the tests).

## Status

The v1.x versions were confirmed on my POCO F6 (Theettam 6.1.176, KernelSU-Next 3.4.2). Everything newer is covered by the test suites off-device. The v4 battery monitor and the controller handoff still need proper on-device checks, so treat the drain numbers as unverified. Android or Xiaomi services can override some values; the page shows a warning when the kernel doesn't accept a write. If you see one, open an issue with the message.

## License

MIT
