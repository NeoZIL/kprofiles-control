# Changelog

## v4.0.3
- Efficiency (tuning): configurations that hold no limits at all (Performance, or Custom with nothing set and screen-off caps off) stop the background watcher instead of waking periodically with nothing to switch or re-assert.
- Fix (audit): the watcher is kept whenever any limit is held, including Custom with screen-on caps and screen-off caps turned off. The watcher also re-asserts held limits and hands them back when the module is disabled or removed in the manager, so stopping it for such a profile would have left the caps in place until reboot. `tune.sh status` now reports `watcher_needed`, and the WebUI shows Not needed only when that is 0.
- Efficiency (monitor): returning to the WebUI no longer runs an extra screen-state probe unless a screen-off baseline was actually saved.
- Efficiency (monitor): visible Monitor telemetry refreshes every 5 seconds instead of every 2.5 seconds; sampling still stops outside Monitor or while the WebView is hidden.
- Thermal display: battery temperature keeps its stricter 38°C/45°C bands, while CPU/SoC/GPU indicators use 45°C/75°C bands to avoid labelling an ordinary 45°C SoC reading as Hot. These indicators do not replace Android/kernel thermal protection.
- Version: v4.0.3, versionCode 33.
- Tests: add regression coverage for no unnecessary Performance watcher and sensor-specific temperature labels.

## v4.0.2
- Fix (monitor): preserve the latest measured active and idle drain estimates across WebUI reopen/reload, with an explicit “Last measured · refreshing” label while a fresh active window is collected.
- Fix (monitor): finalize idle drain as soon as the WebUI returns, even when Home rather than Monitor is selected. The screen-off baseline is used once on return and then discarded, so a window that is too short or shows no battery change can never be paired with later screen-on use and stored as an idle rate.
- Safety: active sample history is persisted in a compact window, expires when stale, and is cleared on hidden/screen-off transitions or sample gaps so a screen-off interval is never averaged into active drain.
- Version: v4.0.2, versionCode 32.
- Tests: add regressions for drain-rate persistence across reloads, screen-off/on sampling from Home, active sample reset without hiding the last valid estimate, and unmeasurable idle windows being discarded.

## v4.0.1
Fix the ShellCheck failures that stopped the build workflow. No behaviour change: the module does exactly what v4.0.0 does.
- Fix (CI): `kp.sh status` assigned `m=?` and `a=?` unquoted, which ShellCheck reads as a glob (SC2125). They are now `m='?'` and `a='?'`; the output is identical.
- Fix (CI): the thermal-zone filter in `monitor.sh` listed `*cpuss*`, `*CPUSS*`, `*gpuss*` and `*GPUSS*` after `*cpu*`, `*CPU*`, `*gpu*` and `*GPU*`, which already match them (SC2221/SC2222). The redundant patterns are removed; the same zones are exported.
- Fix (CI): `monitor.sh` cleared the GPU variables with `GPU_CUR= GPU_MIN= ...` on one line (SC1007). Each is now assigned `''` explicitly.
- Version: v4.0.1, versionCode 31. v4.0.0 was never published (its tag run failed before the release step), so this is the first release of the 4.0 series.
- Tests: all dash suites and both WebUI suites pass; ShellCheck was not available in the build environment, so the three findings above were fixed from the CI log and should be confirmed by the Actions run.

## v4.0.0
This release was prepared as v3.6.0 and v3.6.1, neither of which was ever committed or published; it is numbered v4.0.0.
Add a universal-interface, read-only live hardware monitor and mutually exclusive tuning-controller selection.
- Exclusive control source: choose **Module presets** or **Kernel profile** explicitly. The source is stored separately from the saved preset and kernel-profile preferences.
- Handoff order: verify the outgoing controller is released first, stop/restore the module tuning engine when leaving Module presets, verify a complete stock CPU/GPU record before enabling Kernel profile, then apply and verify the incoming controller. Failed or incomplete handoffs use the existing recovery lock rather than claiming success.
- Engine enforcement: direct shell calls cannot apply non-Stock module presets in Kernel profile mode or enable a non-None kernel profile / `auto_kp=Y` in Module presets mode. At boot, only the saved owner is applied; an unresolved conflict leaves both tuning sides unapplied until the user chooses.
- First-run migration: a legacy setup with both an active non-Stock preset and an active kernel profile (including enabled `auto_kp`) becomes an explicit conflict; neither setting is silently discarded. If Kprofiles is absent, Module presets remain available. If the Kprofiles state is present but unknown, the module fails closed.
- Saved kernel preferences are kept separately from the temporary None/off runtime state used by Module presets. `kp.sh persist 1` normalizes numeric `auto_kp` nodes to the saved `AUTO=Y`/`AUTO=N` form.
- Live monitor: show every discovered CPUFreq policy (Little/Big/Prime labels only when the known peridot CPU map matches), current frequency with utilization in brackets, temperature status badge, online-core count, and current allowed minimum/maximum frequencies. GPU telemetry uses discovered devfreq/KGSL interfaces; battery shows charge state, current, power, voltage, temperature, and best-effort active/idle drain.
- Temperature colors: Normal below 38°C (blue), Warm from 38°C to below 45°C (yellow), Hot at 45°C or above (red). Battery charge colors: below 20% red, 20% to below 80% green, 80–100% blue.
- Home: add a same-size Quick Access card, Live Monitoring, which opens Monitor instead of starting a second sampler. Full telemetry appears at the top of Monitor, with existing Monitor information preserved below it.
- Performance: a single read-only `monitor.sh` batches sensor discovery; refresh runs every 2.5 seconds only while Monitor is visible. Polling stops when another page is selected or the WebView becomes hidden. DOM values update only when changed; missing or ambiguous readings are unavailable, not guessed. Active/idle drain is shown only after a usable sample window.
- Version: v4.0.0, versionCode 30. Diagnostic interfaces were verified on a POCO F6 (`peridot`) running Theettam 6.1.176; full on-device WebUI, controller handoff and drain-rate behavior still require installation testing.
- Tests: add controller migration / handoff / failure coverage, numeric `auto_kp` persistence coverage, and live-monitor fake-sysfs/procfs and WebUI regression tests.
- Fix (audit): **the live monitor no longer reports a GPU bus/bandwidth monitor as the GPU.** The GPU lookup
  took the first devfreq node whose name contained "gpu", so a node such as `gpubw` that sorts before the real
  GPU supplied the frequency, range and governor. KGSL's own node is now preferred, bus/bandwidth/LLCC/DDR nodes
  are skipped, and another vendor's GPU-named node is still found.
- Fix (audit): **active battery drain no longer averages in a screen-off gap.** The samples were kept when the
  page was hidden, so after the screen slept the first new sample was paired with one from before it and the
  idle period was averaged into the "active" rate. Collection now restarts whenever the page is hidden.
- Fix (audit): **controller ownership fails closed on malformed status.** A failed command, empty output, invalid
  source, or uninitialized legacy source is no longer assumed to mean Module presets. The page shows Unknown or an
  explicit choice conflict and keeps tuning controls locked until ownership can be verified (Reset remains available).
- Fix (audit): **screen-off battery baseline can be collected from any WebUI page.** Leaving Monitor for Home before
  locking the phone no longer suppresses the one-shot screen-state/battery sample.
- Fix (audit): **GPU selection excludes interconnect nodes before preferring KGSL.** This also skips misleading names
  such as `kgsl-busmon`, mixed-case bandwidth/LLCC/DDR nodes, and still falls back to a genuine GPU-named devfreq node.
- Fix (audit): **per-CPU CPUFreq fallback preserves `related_cpus` / `affected_cpus`.** Kernels that expose shared policies
  through per-CPU links no longer lose the policy's CPU membership, so the WebUI can deduplicate the shared policy.
- Fix (audit): **battery power is sanity-checked against current × voltage.** When both values are available, a plausible
  current/voltage product takes precedence if a vendor's `power_now` differs by more than 4x; otherwise the kernel's value
  is retained. This addresses a POCO F6 diagnostic sample where `power_now` read 10 W while current × voltage implied 0.67 W.
- Tests (audit): cover kgsl-busmon before KGSL and alone, shared CPU membership in per-CPU fallback, hidden-page idle
  capture from Home, empty/legacy controller status, and inconsistent battery power. Each new regression case fails on the
  preceding candidate.
- Fix (UI audit): **the Home current-profile banner now reflects the active controller.** When Kernel profile owns tuning it shows the actual kernel mode (None, Battery, Balanced, or Performance), labels the banner “Kernel profile”, and reports “Kernel active” rather than incorrectly presenting a saved module preset as active. The saved module preset remains visible as an inactive preference. Unknown/conflicted controller states no longer imply a verified active profile.
- Fix (UI audit): **live current-frequency values now include units**, e.g. `902 MHz (23%)` for CPU and `255 MHz (13%)` for GPU.
- Documentation (UI audit): expand the final Monitor “How to read this” section to explain the CPU `/proc/stat` utilization formula, cluster aggregation, GPU busy-counter fallbacks, current allowed frequency limits, and battery drain estimate methodology.
- Tests (UI audit): verify the active Kernel profile banner uses the live Kprofiles mode, current CPU/GPU MHz units are present, and the percentage calculation guide remains at the bottom of Monitor.
- Fix: **Kprofiles at the upstream path was treated as absent.** The upstream driver documents its mode as the
  module parameter `/sys/module/kprofiles/parameters/kp_mode`; the module only looked for it at
  `/sys/kernel/kprofiles/kp_mode` (the Theettam kernel's node). On a kernel with the upstream layout the module
  therefore reported "unsupported", disabled the Kernel profiles controls and migrated a legacy setup to
  Module presets while the kernel profile was still active.
- Fix: **a Battery profile on such a kernel could be recorded as the phone's own stock limits.** The engine
  decides whether the kernel profile is holding the limits down by reading the mode node, and it read the wrong
  one. It now uses the same discovery as `kp.sh`.
- How it works: one function, `kp_find` in `control-lib.sh`, picks the mode node (`/sys/kernel/kprofiles/kp_mode`
  first, then the module parameter) and the `auto_kp` node (module parameter first, then `/sys/kernel/kprofiles`).
  The first one that exists wins, so a phone that already worked keeps using the same node. If neither exists
  nothing is written anywhere. `KP_PATH` and `AUTO_PATH` still override it. `auto_kp` is still optional.
- Cleanup: removed two unused path variables from `control.sh` and the wrong "documented ABI" comment in `kp.sh`.
- Tests: 18 new checks in `tests/kp-test.sh` (upstream, Theettam, both, auto only under /sys/kernel, none, mode
  without auto_kp, `KP_PATH` override), 5 in `tests/control-test.sh` (legacy migration on the upstream layout) and
  3 in `tests/tune-test.sh` (stock is not recorded while Battery is active at the upstream node).

## v3.5.1
Make Kprofiles compatibility capability-aware without changing the POCO F6 CPU/GPU tuning engine.
- Detection: `kp.sh status` now reports `support=supported|unsupported|unknown` based on the documented mode node and its readable mode value. A missing node is unsupported; a present but unreadable or unrecognized node is unknown.
- Safety: mode writes and persistence changes refuse to proceed unless the mode interface is confirmed and its current value is one of the documented modes 0–3.
- Optional feature: `auto_kp` is detected independently. If the mode interface exists but the optional parameter is absent, saved mode profiles still apply; the missing auto setting is skipped with a warning instead of making the boot apply fail. If the parameter exists but cannot be read/recognized, the script fails closed.
- Unsupported kernels: boot-time `apply` safely skips saved Kprofiles settings when the mode interface is absent, preserving the saved preference for a later compatible kernel without writing to guessed paths.
- WebUI: consumes explicit support state so a missing interface is shown as unsupported while a present but unreadable/malformed interface is shown as unconfirmed. Kernel commands remain disabled unless support is confirmed. Exposes the complete standard mode set: None (0), Battery (1), Balanced (2), Performance (3); it highlights mode 2 as Balanced instead of incorrectly treating it as None.
- Scope: CPU/GPU cluster paths, POCO F6 frequencies, presets, and the screen watcher remain device-specific and unchanged. This supports kernels implementing the documented Kprofiles sysfs interface; non-standard forks need a separately verified adapter.
- Tests: cover supported, unsupported and unknown mode detection, optional `auto_kp` absence, and no writes when mode support is unconfirmed.
- Fix (found in an audit of the first v3.5.1 candidate): **Reset everything and uninstall could never finish on a kernel whose kernel-profile node is not standard.** The new rule refuses to write a node it cannot read or whose value it does not know, but `tune.sh resetall` counted that refusal as a failure, so Reset everything exited 1 and uninstall reported "restoration failed" and kept its data, even though the CPU/GPU limits had been restored. Now an unreadable or unrecognised kernel-profile node is reported as a warning ("left as it is") and the result is decided by the limits themselves, which are still verified by readback. A node that reads a valid mode but refuses the write is still an error.
- Fix: **`auto_kp` is written in the node's own style.** The helper accepted a node that reads `0`/`1` as supported but only ever wrote `Y`/`N`, so such a kernel could never change or re-apply it. A `0`/`1` node now gets `1`/`0` (a bool parameter still gets `Y`/`N`); the saved setting stays `Y`/`N`.
- Tests: Reset everything and uninstall with an unreadable, unknown-value and unknown-text kernel-profile node, with a node that refuses writes, and with an unknown node plus a refused limit; `auto_kp` in the `0`/`1` style (write, save, boot re-apply); the page's failure detection with the new warning. The old "node that cannot be written" test used a folder, which is now an unreadable node, so it was replaced by a real refused write.
- Version: v3.5.1, versionCode 28.

## v3.5.0
First release after v3.0.0. It rolls up the unreleased v3.1.0, v3.2.0 and v3.2.1 work (see those sections below) and adds the
fixes found when the earlier builds were tested on a phone. v3.1.0 to v3.2.1 were never published, so versionCode goes from 23 (v3.0.0) to 27.
- Change (UI): **the CPU/GPU profile "No Extra Caps" is now called "Performance".** Only the name changed: the internal ID is still
  `performance`, so saved settings, the Tilt/Saver bridge and the engine are untouched. The kernel **Performance** mode is a separate control on the Kernel page.
- Fix (UI): **the Settings (gear) icon was off centre.** The top-bar button, the Home quick link, the bottom navigation and the
  Settings icon each used a different hand-drawn gear with a made-up `translate`/`scale`, which left the glyph 2 to 3 px off
  centre. All use one symmetric gear now. The page was rendered and every icon's drawing was measured against its box: all within 0.4 px.
- Fix (UI): **Reset everything and Dynamic used the same lopsided four-arc glyph.** Reset is now a single counter-clockwise arrow;
  Dynamic is the two-arrow cycle. Both are symmetric about the centre of their box.
- Fix (UI): **profile and kernel-mode icons no longer depend on the phone's font.** They were placed with `vertical-align: -4px`, which
  matched one font only. The title is now a flex row, so the icon sits on the first line whatever the font and when a name wraps.
- Fix (engine): **a boost could be saved as the phone's own "stock" value.** The ROM raises the minimum frequencies for a few seconds when the
  screen turns on or an app opens (seen on a POCO F6: 595200/633600/633600 became 1843200/1286400/1651200 for about 2 to 8 s, several
  times a minute). A single reading taken inside one was recorded, and Stock would have restored it. The phone's own limits are now
  read several times (15 over about 30 s at boot, 6 over about 5 s when Apply records them) and the lowest minimum and highest maximum seen are recorded.
- Fix (engine): **no limit is written unless every value it could move can be put back.** A maximum set below the current minimum also lowers
  that minimum (and the reverse), in either screen state. Apply now refuses, with "not on record for: ...", when the phone's own minimum or maximum is not recorded for a
  cluster that has any limit set. It changes no frequency and creates no changed-marker; a reboot records the values again. It used to apply and only warn.
- Fix (engine): **a refused preset no longer stays saved.** When Apply refuses a preset because an original value is not on record, the previous
  settings are put back, so the page keeps showing the profile that is really in place (it used to highlight the refused profile and lock the other
  Battery profile although nothing was applied). Found by driving the page against the real scripts.
- Tests: `boost window`, `unrecorded minimum` and `refused preset` in `tests/tune-test.sh` (both fail without the engine fixes). Older checks that expected a limit
  to be applied without a record now expect the refusal; restore-path checks that needed such a state now simulate what an older version could leave behind.
- Version: v3.5.0, versionCode 27. Not tested on a phone yet.

## v3.2.1
Polish the five-page WebUI without changing tuning behavior.
- Reset: replace the solid red recovery block with a neutral outlined button matching the other controls; only its reset icon and label are red, while the chevron and explanatory note remain neutral.
- Icons: add small, semantic color accents to the Home status indicators and quick links, the six CPU/GPU profile names, and the three kernel modes. Icons use inline SVG only; no remote assets or libraries are added.
- Compatibility: leave all profile IDs, shell commands, reset/recovery behavior, kernel support detection, and safety rules unchanged.
- Tests: verify the Reset styling and icon structure, plus the presence of inline icons and their semantic color styles.
- Version: v3.2.1, versionCode 26.

## v3.2.0
Redesigned the WebUI as a clean, lightweight five-page interface without changing the tuning engine.
- Navigation: add Home, CPU & GPU, Kernel, Monitor, and Settings screens with a fixed bottom navigation bar and local in-page switching. Navigation does not reload the document or issue shell commands.
- Home: provide a current-profile summary, CPU/GPU limit overview, screen and watcher state, quick links, and a visibly red Reset everything recovery control.
- CPU & GPU: display the six existing profiles in a compact responsive grid and keep the screen-on/off frequency pickers together on the tuning page.
- Kernel: give kernel modes their own screen while retaining supported / unsupported / unknown detection, disabled controls on unsupported kernels, and the kernel command guard.
- Monitor: show engine-reported CPU/GPU limit ranges and kernel status; explain that these are applied limits, not continuous measurements of live clock speed.
- Settings: group the existing tuning switches, safety-rule explanations, and installed-version information. No new tuning settings or kernel actions were invented.
- Responsiveness: keep the interface dependency-free and offline, avoid polling and shell commands during navigation, use compact local CSS transitions, support the device's light/dark theme, and honor reduced-motion preferences.
- Compatibility: preserve the existing command engine, profile IDs, validation, cooldown, Tilt/Saver bridge, recovery lock, reset flow, and kernel-support guard.
- Tests: extend DOM behavior tests to verify page visibility, navigation state, quick links, and that page switching sends no shell commands; extend build checks for the new page shell and offline assets.
- Version: v3.2.0, versionCode 25. CPU/GPU and kernel engine scripts are unchanged from v3.1.0.

## v3.1.0
Expanded the user-facing profile set and made kernel-profile support explicit in the WebUI.
- Profiles: add **No Extra Caps** (stored under the internal preset ID `performance`), which removes this module's extra CPU/GPU caps and leaves the phone's own governors and thermal policy in control; this label is deliberately distinct from the separate kernel **Performance** mode; the status panel says “No extra caps” instead of implying that limits are actively set; **Dynamic**, which leaves screen-on limits alone and applies battery-tilt caps only with the screen off; and an explicit **Custom** entry that preserves existing custom values and opens the existing editor.
- Custom: selecting Custom preserves the saved screen-on/off values, marks the configuration as custom, and enables the editor instead of replacing the user's choices.
- Switching safety: preserve the Stock/Reset bridge between Battery tilt and Battery saver even if the user passes through Custom, No Extra Caps, or Dynamic.
- Kernel profiles: move the section to the bottom and collapse the three existing kernel choices under a **Kernel profiles** button. Support is determined from `kp.sh status`; when the kernel reports `mode=?`, the three choices are hidden, the button is disabled, and the page says extra kernel features are not supported by the kernel. If the status cannot be read, the page reports that support could not be confirmed instead of claiming the kernel is unsupported.
- Reset: highlight **Reset everything** in red so its recovery function is visually distinct.
- Engine: add the No Extra Caps (internal ID `performance`), Dynamic and explicit Custom preset entry points to `tune.sh`, retaining the existing validated, atomic configuration write and apply/restore path. The separate kernel `kp.sh` modes and their semantics are unchanged.
- Tests: add fake-sysfs coverage for the `performance`/No Extra Caps preset, Dynamic, and Custom preservation, plus WebUI checks for profile presence, the distinct CPU/GPU and kernel Performance labels, kernel support/unsupported display, collapsed kernel options, and the red Reset control.
- Test portability (audit): explicitly export temporary watcher/boot retry overrides from the tuning-test helper so BusyBox ash receives the same values as dash.
- Status panel: No Extra Caps and Dynamic-on-screen states no longer look like a CPU/GPU cap set is actively applied when no caps are configured.
- Fix (audit): **a kernel-profile command is never sent unless support was confirmed.** The page relied only on the
  buttons being disabled; a tap that still reached the handler sent `kp.sh mode` or `kp.sh persist` on a kernel
  without Kprofiles. `act()` now refuses it, with a message, when support is unsupported or not yet confirmed.
- Tests (audit): the Tilt <-> Saver bridge is now tested by behaviour, not by reading the source: from Tilt and from
  Saver through No Extra Caps, Custom and Dynamic (blocked, remembered, kept after a reload, cleared by Stock and by
  Reset everything, a corrupt stored value ignored); the status wording for each new profile; the kernel section when
  support is unknown, unsupported, lost after a refresh, and under a recovery lock; and that the three kernel
  choices send `mode 0/1/3`. Engine tests add: an unknown preset, Custom from Stock, Custom with unreadable or
  unsavable settings (the file stays byte for byte), a Dynamic cap the phone does not list, Reset everything from
  Dynamic with the screen off, boot with the `performance`/No Extra Caps preset and Dynamic, a Tilt -> No Extra Caps -> Tilt -> Stock round trip,
  and the Action button leaving each new profile for Stock.
- Downgrading: v3.0.0 does not know the names `performance` and `dynamic`. If one of them is selected and you install
  v3.0.0, it reports the settings as unreadable and shows the module as not active until you choose Stock or Reset
  everything. Choose Stock before downgrading.
- Version: v3.1.0, versionCode 24. This release extends the preset model; the settings file keeps its v3.0.0 layout
  (only the preset name can now be `performance` or `dynamic`), and the recovery-storage format is unchanged.

## v3.0.0
WebUI startup and recovery-diagnostic hardening. The tuning engine, kernel-profile scripts, watcher,
frequency application, locking and restore rules are unchanged from v2.0.0. The WebUI is the only
functional module file changed; `module.prop` changes for version metadata.
- Fix: **profile controls cannot be used before the current state is known.** On initial load, every
  control except Reset everything stays disabled until the first successful status response. This
  prevents the Tilt/Saver bridge rule from being bypassed while the page is still loading and does not
  require any frequency polling.
- Fix: **the latest failed recovery attempt survives a reload.** The most recent Reset everything error
  details are now stored separately with the recovery lock and shown again after a WebUI reload. A
  successful, verified recovery clears both stored messages.
- Fix: **the start-up lock covered the buttons but not the pickers.** The 16 min/max pickers are built after
  the first lock pass and were left enabled until the first status arrived, so a custom limit could be saved
  while the current preset was still unknown. They are now locked as soon as they are built, and the page
  itself refuses every command except Reset everything until the first status has been read, so a toggle or
  tap that still reaches a handler sends nothing.
- Fix: **a failed first status no longer leaves the page locked until Reset everything.** If the frequency
  lists or the first status cannot be read, the page tries again by itself three times (3 s apart), then shows
  a "Try again" button. Before, the only control left usable was Reset everything, which also resets the
  saved settings and the kernel profile, so a slow first read could push someone into it.
- Tests: add regression checks for the initial status gate and persistence of the latest recovery details, and
  `tests/webui-dom-test.js`, which runs the page's real script against a small fake DOM, a fake localStorage
  and a controllable `ksu.exec`. It checks what the page does: which controls are usable while the first
  status is pending, that no command reaches the engine except Reset, the retry and the button, the stored
  lock after a reload, the stored latest response after a failed Reset, and that a clean Reset clears all
  three stored keys. Each of the three fixes above was removed in turn and the test failed.
- Documentation: clarify that only the WebUI changes functionally; `module.prop` also changes for the
  version and versionCode.
- Version: v3.0.0, versionCode 23. This is a major-version milestone; settings format and recovery data
  remain compatible with v2.0.0.

## v2.0.0
WebUI recovery-lock fixes and a CI update. The tuning engine, kernel-profile scripts, watcher and restore
rules are unchanged from v1.4.4. The WebUI is the only functional module file changed; `module.prop` also
differs for version metadata.
- Fix: **the page missed the most common refused limit.** When the kernel rejects a write and reads back
  nothing, the engine prints `warn: big max wanted 2188800, kernel says ` with an empty reading. The page
  only recognised `kernel says` followed by digits, so that case did not lock the page to Reset everything
  and the notice was not shown as a recovery failure. Reproduced against v1.4.4's page. It now recognises
  the message with or without a reading.
- Fix: **the page locked itself for a harmless warning.** `big_min is back, but its changed-marker could
  not be cleared` means the limit WAS restored and only a small bookkeeping file could not be written. The
  page took it for a frequency failure, entered the recovery lock, and stored the lock, so it survived a
  reload. Reproduced against v1.4.4's page. Failure detection now matches only the engine's own wording for
  a refused or unrestorable frequency (`kernel says`, `could not put ... back`, `could not be put back`,
  `did not take the requested limit`, `the kernel did not take these limits`, `not every limit could be
  applied`, `restore refused by the kernel`), instead of broad patterns that could match anything that
  mentions a cluster and "could not".
- Fix: **a recovery lock that could never clear.** The lock cleared only if Reset everything printed no
  warnings at all, so an unrelated warning (for example that the phone's own limits are not recorded yet)
  kept the stored lock forever. Now a Reset everything that ends without an error and without a frequency
  failure message, followed by a fresh status read, clears the lock; any warnings are still shown, in the
  result notice. A failed Reset everything keeps the lock and shows the latest response under the original
  failure details.
- CI: the workflow now uses `actions/checkout@v7` and `actions/upload-artifact@v7` (both published).
- Tests: the three page checks that asserted the old clearing rules now assert the new ones, and a new
  `tests/webui-test.js` (run by `tests/build-test.sh` when node is installed, as in CI) takes the page's own
  `isFrequencyMismatch` and checks it against 14 real engine messages: 8 that must lock the page and 6
  harmless ones that must not. Two of those fail on v1.4.4's page, and it also checks that every inline
  script parses.
- Version: v2.0.0, versionCode 22. The major number is a milestone choice; there is no engine change and
  no settings or recovery-data format change, so installing over v1.4.4 keeps everything.

## v1.4.4
WebUI-only guardrails for profile switching. The tuning engine and kernel-profile scripts are unchanged.
- UX: **Battery tilt and Battery saver cannot be selected directly from one another in the WebUI.** Select Stock or Reset everything first; that neutral step returns the UI to a state where either preset can be chosen.
- UX: after a successful preset application or Reset everything operation, all WebUI controls remain greyed out for 8 seconds. The existing result notice includes a live countdown telling the user when controls can be used again.
- UX: when the existing engine reports a CPU/GPU frequency mismatch or restore refusal, the page preserves and prominently displays the existing `warn:`/`error:` detail, enters a recovery-only lock, and disables all controls except **Reset everything**. The recovery lock persists across WebUI reloads when browser storage is available.
- UX: the recovery lock clears only after Reset everything returns cleanly, a fresh status read succeeds, and the settings are not reported invalid; all controls then remain paused for the normal 8-second cooldown. Failed or warning-producing reset attempts leave the recovery lock in place and show the returned details.
- Scope: these are superficial WebUI safeguards only. They do not poll frequency nodes, serialize operations, or prevent changes issued through ADB or another interface. The tuning engine, kernel-profile scripts, watcher timing, frequency application, locking, and restore behavior are unchanged. The lock responds to reported failures; it cannot detect a silent mismatch that the engine does not report.
- Tests: add build-test checks for cooldown, bridge rule, frequency-error recognition, preserving notices, recovery lock except Reset everything, persistence, and clean-reset-only unlock.
- Version: v1.4.4, versionCode 21.

## v1.4.3
A re-read of v1.4.2 found three smaller problems. None was seen on a phone.
- Fix: **Stop could signal a process that is not the watcher.** The check for "is the watcher running" only
  looked for `tune.sh` in a process's command line, so a pid file that named another module's `tune.sh` (or
  a process that had reused the number) was taken for the watcher and sent a stop signal. Reproduced: a
  made-up `tune.sh` process was killed by `tune.sh stop`. A process now counts as the watcher only if its
  command line is `... tune.sh daemon <folder>`; an unrelated one is left alone and the stale pid file is
  removed.
- Fix: **an unreadable settings file no longer looks like normal defaults in the page.** `status` printed
  `enabled=0 preset=stock` for a settings file that exists but cannot be read, the same as for no settings.
  It now also prints `cfg_error=1` in that case, and the page shows a message saying the settings cannot be
  read and what to do (Apply and the presets already refused to change anything; that is unchanged).
- Fix: **line endings.** `.gitattributes` now forces LF for the scripts, `module.prop`, the page and the
  other text files, so a Windows checkout can no longer hand out CRLF scripts that fail on Android.
- Tests: Stop with a pid file naming an unrelated `tune.sh` process (it must survive, the stale file must
  go, Status must say no watcher), `cfg_error` with good, unreadable and missing settings, and the
  `.gitattributes` rules. Each fails on the code it replaces.

- Follow-up audit hardening before publication: watcher identity now matches this module's exact script path and folder, not just the words `tune.sh daemon`; the unrelated-process regression includes a foreign script invoked with daemon arguments. The corrupt-settings page warning also no longer claims that current limits have been undone, and the line-ending test checks every declared `.gitattributes` rule.
- Further fail-closed validation: syntactically valid but invalid saved values (frequencies not present in the kernel's available list, invalid booleans/preset names, and inverted min/max pairs) are now reported as `cfg_error=1`. Apply refuses them without changing any limits; Status shows the warning, and the watcher falls back to the safe disabled state so it restores limits it owns. Regression tests cover these invalid settings.

## v1.4.2
An audit of v1.4.1 found that the stock snapshot could end up empty. Not seen on a phone.
- Fix: **an empty stock snapshot is never saved or accepted.** When no CPU or GPU frequency value could be
  used (every node unreadable, empty or missing), `capture_defaults` still moved an empty temporary file
  over the snapshot and returned success. Reproduced: with every frequency node missing, boot **replaced a
  good saved snapshot with a zero-byte file**, and with nothing saved it left a zero-byte file and exited
  0, so `service.sh` applied the kernel profile. Now an earlier snapshot is kept untouched (and the log
  says so), and with no earlier snapshot nothing is written, the stale empty file is removed, the capture
  returns status 2, `tune.sh boot` exits 2 and `service.sh` does not apply the kernel profile.
- Fix: **a zero-byte `defaults` file no longer counts as a record.** Apply, Stock, Status and boot all
  treat only a regular, non-empty file as a usable stock record (a folder in its place is still refused).
  A stale empty file is replaced by a real snapshot on the next capture, Apply warns that nothing is
  recorded, and Apply refuses to change a limit when nothing can be recorded.
- Fix: **Apply no longer changes limits when module-owned limits exist but no usable stock record does.**
  `capture_defaults` returned success as soon as the `applied` file had markers, even when `defaults` was
  empty or missing. Reproduced: boot, Tilt, replace `defaults` with a zero-byte file, then Saver exited 0
  and printed `ok` while the big max went 2,188,800 -> 1,593,600, the prime max 2,457,600 -> 1,766,400 and
  the GPU max 736,000,000 -> 633,000,000, with a new `little_max` marker, so a later Stock or uninstall
  could not put the phone's own values back. It now returns status 2 in that case; Apply, a changed limit
  and a preset refuse with an `error:` line and exit 1, log `apply refused`, and change no frequency node
  and no marker. Stock still says the values are not recorded (without blaming a failed save), and Status
  stays quiet. A reboot records the phone's own values again.
- Fix: **a running watcher also holds back.** Refusing in Apply was not enough: the new setting is saved
  before Apply runs, and the watcher re-reads the saved settings and would have applied them itself.
  With limits of ours in place and no usable record, the watcher now leaves every limit as it is and says
  so once in the log.
- Fix: **the lock wait can no longer spin forever.** `lock_take` skipped its counter on the paths that
  remove a stale lock, so a lock that could not be removed made it loop without end (reproduced with a
  failing `rm`: the command only ended when killed). Every pass is now counted.
- CI: each suite (kp, tune, build, release) is its own step under dash, mksh and busybox ash, with its
  own time limit (and a job limit), so a hang is reported at the suite that hung. The full tune suite takes
  about 95 seconds here under dash.
- Tests: Apply with an empty and with a missing `defaults` file while Tilt's markers exist (exit status,
  message, every frequency node and the marker file compared before and after, no invented record, log,
  plain Apply, a changed limit, Status output, Stock output); a good record still lets Apply carry on;
  the running watcher with no record; and an undeletable stale lock. Each fails on the code it replaces.
- Tests: every reading empty and every node missing, each with and without an earlier snapshot (exit
  status, file left behind, byte-for-byte comparison, log); a zero-byte `defaults` file with Status, with
  Apply, with the Battery profile on, and with nothing readable; and the real `service.sh` against a
  fake phone with nothing readable (kernel profile skipped, no snapshot file). Each of these fails on v1.4.1.
- Version: v1.4.2, versionCode 19.

## v1.4.1
An audit of v1.4.0 found one hole in the boot-safety rule introduced in v1.2.3. Not seen on a phone.
- Fix: **boot no longer applies the kernel profile when the Battery profile is already active and nothing
  was ever recorded as stock.** `capture_defaults` skips the reading while the kernel Battery profile is
  on (the values are capped and are not stock), but it returned success even when no snapshot existed, so
  `tune.sh boot` exited 0 and `service.sh` applied the kernel profile anyway. The forced boot-time capture
  now returns status 2 in that case: `tune.sh boot` exits 2, `service.sh` does not apply the kernel profile
  at that boot, and `boot.log` and `tune.log` say so. An earlier record is still kept untouched (exit 0),
  and Apply, Stock and Status behave as before (they warn that nothing is recorded).
- Tests: Battery active at boot with no record (exit status, error text, log, no snapshot file), with an
  earlier record (exit 0, record untouched), Apply and Status still working, and the real `service.sh`
  against a fake phone for both cases (profile skipped without a record, applied with one).
- Version: v1.4.1, versionCode 18.

## v1.4.0
Release of the v1.2.3 code under a new version number. No script or WebUI change from v1.2.3.
- Change: version number only (v1.2.3 to v1.4.0, versionCode 16 to 17).

## v1.2.3
An audit of v1.2.2 (before it was flashed) reproduced one hole in the new stock protection and one gap in
the boot order. Neither was seen on a phone.
- Fix: **an unreadable frequency list no longer hides a pinned minimum.** v1.2.2 let a minimum that sat at
  its maximum through when the cluster's list of available frequencies was missing, empty or unreadable,
  because it counted that as "this cluster has a single frequency". Reproduced: with the big cluster's list
  removed and its minimum at its maximum (2572800), boot recorded 2572800 as stock and never looked again.
  Now only a list that can be read and holds exactly one real frequency counts as a single-frequency
  cluster; a missing, empty, unreadable or malformed list (a lone word that is not a positive number)
  is "unknown", and the minimum is treated as pinned: not recorded, the earlier snapshot is kept, and boot
  looks again. The same rule is used when a recorded minimum is about to be written back, so a pinned
  recorded minimum is not written back either when the list has disappeared.
- Fix: **boot no longer applies the kernel profile blindly when stock could not be recorded.** `service.sh`
  ran `tune.sh boot; kp.sh apply` regardless of the result. Now `tune.sh boot` exits 2 when the phone's
  own limits could not be saved AND no earlier record exists, and `service.sh` then does **not** apply the
  kernel profile at that boot (a Battery profile would keep the real values from being recorded
  afterwards) and says so in `boot.log` and `tune.log`. Exit status 0 or 1 (any other error, already
  reported) still applies the profile, as before. Anything else (for example `tune.sh` cannot run) skips
  it too. Reboot, or open the app, to try again.
- Tests: missing, empty, unreadable, malformed and zero lists with a pinned minimum (saved snapshot,
  retries, exit status, kernel value, log); a genuine one-frequency list; a good snapshot that must
  survive a suspicious reading; restoring after the list disappears (a pinned record is not written
  back and stays marked, a good record is restored); and the real `service.sh` run against a fake phone
  for the normal order, a failed save with and without an earlier record, another error, and a missing
  `tune.sh`. The old text check of `service.sh` was replaced by these. Each new test fails on the
  v1.2.2 code, and six deliberate breaks of the fixes were each caught.
- Tests: the temporary `sleep` processes of the tune test are now stopped if a run is interrupted, so
  they cannot keep an output pipe open. (A stall reported in an independent run could not be
  reproduced: the suite finishes in about 80 seconds here.)

## v1.2.2
Found on a real POCO F6 after flashing v1.2.1: the recorded stock minimums were equal to the maximums
(little 2016000, big 2572800, prime 2668800 instead of 595200, 633600, 633600). At the moment of the
boot-time recording every cluster's minimum read equal to its maximum, so something was holding them
up (most likely a boot boost; the cause is not confirmed), and the module saved that as "stock".
- Fix: **a minimum at or above its maximum is never recorded as stock.** The recording drops that
  reading (a cluster that really has one frequency is not affected). With an earlier snapshot the
  earlier one is kept; with none, the maximum is saved and the minimum is left out.
- Fix: **boot waits for the boost to end.** When it sees held minimums it looks again every 10 seconds,
  up to 8 times, before giving up, and says so on screen and in `tune.log`. Applying your preset
  waits for that, so in that case it can start up to about a minute later.
- Fix: **a recorded minimum at or above its maximum is never written back.** Snapshots made by earlier
  versions can already contain one. Stock, Apply and the screen watcher now treat such a minimum as
  not recorded: the limit stays marked, the command says so and exits 1, and the cluster is not
  pinned at its top speed. (`status` shows an empty `def_*_min` for it.)
- Fix: **a restored minimum that had to follow a lower maximum lost its marker.** When the phone's
  own minimum was above the new maximum, the module wrote the lower value but cleared the "changed by
  this module" marker as if the phone's own value was back, so Stock never repaired it. The marker now
  stays until the real value is back.
- Boot now logs the values it recorded (`tune.log`, line "boot: stock recorded: ..."), so a wrong
  snapshot can be traced to the boot that made it.
- Tests: pinned minimums with and without an earlier snapshot, a boost that ends during boot, a
  single-frequency cluster, a pinned recorded snapshot at Stock, a clamped minimum across screen
  off and on, and the boot log line. Each new test was checked by deliberately breaking the code.

## v1.2.1
Fixes eight ways the module could report success while the information needed to put the phone's own
limits back was missing, unsaved or lost, or while a limit you asked for was not in place. Each has a
failure-injection test that fails on the code it replaces.
- Fix: **no recorded original value.** A limit the module had changed, whose original value was never
  recorded (for example because the kernel Battery profile was on at boot), counted as restored.
  `preset stock`, `stop` and `resetall` printed ok, and uninstall then deleted the saved settings and
  markers while the limit was still capped. Now that is a failed restore: exit 1, the limit stays
  marked, and uninstall keeps everything.
- Fix: **changed-markers.** A marker that could not be written was ignored, so a limit could be
  changed with no record that the module owned it (Stock then did nothing and uninstall succeeded).
  The marker is now saved and read back BEFORE a limit is changed; if that fails the limit is left
  alone and the command fails. A marker that cannot be cleared after a verified restore is reported
  and kept (the safe direction); it is checked again next time.
- Fix: **settings that cannot be read.** `tune.sh cfg` and `kp.sh` replaced an existing settings file
  with one holding only the new key when reading the old one failed (19 lines became 2, and the
  command said ok). Now a failed read is a failure: the file is left byte for byte as it was.
- Fix: **damaged settings.** A settings file that cannot be read or parsed used to stop `tune.sh`
  outright (exit 2 on every command, including the uninstall restore), or was taken for "no settings".
  Now `apply`, `cfg` and `boot` say the settings cannot be read and change nothing, `status` still
  works, and setting a preset, or uninstalling, writes a fresh file and goes on to restore the phone.
- Fix: **saving the phone's own values.** `capture_defaults` did not check its writes and boot ignored
  the result. A snapshot that cannot be saved is now reported (boot exits 1), an earlier snapshot is
  never replaced by a failed one, a snapshot path that is a folder is refused, and no limit is
  changed when there is no snapshot and none could be saved.
- Fix: **a control that disappears after the module changed it.** If a limit's control file was gone
  when the phone's own value had to be put back (the module had capped it earlier), Stock, `stop` and
  `resetall` said "controls not found", exited 0, and uninstall then deleted the saved settings and
  recorded values while the limit stayed capped. Now that is a failed restore: exit 1, the limit
  stays marked, and uninstall keeps everything. Hardware the module never changed that is simply
  absent is still not a failure.
- Fix: **a limit the kernel refuses is no longer reported as ok.** When you apply a preset or custom
  value and the kernel does not take it, the command used to print a warning and then `ok` with exit
  0. Now it exits 1, names the limits that were refused (for example `big_max gpu_max`), says the
  others are in place, and `boot` and the Action button report it too. A refused limit is described
  as refused, not as a failed restore.
- Fix: **turning persistence on is one save.** `kp.sh persist 1` saved `PERSIST`, `MODE` and `AUTO`
  in three separate replaces of the settings file, so a failure part-way left some of them saved and
  some not. The three are now written together in a single replace; if it fails the old file is
  untouched, byte for byte.
- Fix (tests): **failure injection that works in busybox ash.** The "settings cannot be read" and
  "snapshot cannot be moved" tests put a stand-in `grep` or `mv` first in `PATH`. busybox ash runs its
  own built-in `grep` and `mv` and never looks in `PATH` for them, so nothing was injected there and
  the CI busybox step failed with "mode exits 1: expected 1 got 0". The tests now define a shell
  function of the same name, which wins in every shell, and first check that the injection really
  took effect. The module code was not at fault.
- Internal: redirections that can fail now use `printf` rather than `:` (a failed redirection on a
  special built-in ends the whole script in a POSIX shell).
- Wording: the "not recorded yet" warning no longer says the Battery profile is the only cause.
- Tests: 94 new checks in `tests/tune-test.sh` and 27 in `tests/kp-test.sh` cover every case above.
  Run against the v1.2.0 code they fail.

## v1.2.0
- Fix: a settings file that cannot be saved no longer slips past the uninstall safety check. `tune.sh`
  used to ignore failures while writing its settings (`cfg_put`, and the preset save in
  `cmd_preset`). `preset stock` (the first step of `resetall`) then carried on and "applied" the old
  settings, said ok, and `uninstall.sh` deleted the recorded stock values and the changed-limit
  markers while the phone was still running the old limits. Now every step of a save is checked: the
  folder, the temporary file and the move into place, and a settings path that is itself a folder is
  refused (a plain move would have dropped the new file inside it and reported success). On any
  failure the old settings stay exactly as they were, the temporary file is removed, nothing is
  applied, the command prints `error: could not save the settings to <path>, so nothing was changed`
  and exits 1. `resetall` then fails and `uninstall.sh` keeps all recovery data.
- Fix: changing a custom value and switching the preset name to `custom` is now one save instead of
  two, so a failure cannot leave the new value with the old preset name (or the reverse).
- Presets are built in memory and written once, so a failed save also leaves no half-written file.
- Tests: with the temporary file unwritable, `cfg` and `preset` exit 1, print the error, leave the
  settings byte for byte as they were and apply nothing; uninstall exits 1 and keeps the recorded
  stock values, the settings and the markers, then succeeds once saving works again; a settings path
  that is a folder is refused with nothing moved into it; a custom value and its preset name are
  saved together, once each, with no temporary file left. Each new check fails on the code it replaces.

## v1.1.9
- Fix: uninstall now runs `tune.sh resetall`, which sets the kernel profile to None BEFORE it restores
  the limits. Before, the limits were restored first, while a restrictive profile such as Battery
  could still be holding them down, so the restore could be refused. `uninstall.sh` deletes
  `/data/adb/kprofiles_ui` only when `resetall` succeeded (watcher stopped, every limit put back and
  verified, profile None); otherwise everything stays, it says so on stderr and exits 1. A kernel
  without Kprofiles has nothing to reset and does not block the uninstall.
- Fix: `kp.sh` no longer claims success when it cannot save a choice. `cfg_set` now fails if the folder
  cannot be made, the temporary file cannot be written or the config cannot be replaced; it never
  overwrites the old config in that case and removes its temporary file. `mode`, `auto`, `persist`,
  `apply` and `cycle` then exit 1 with an error that says the kernel DID accept the value but saving
  it failed (so it will not be re-applied at boot), not that the kernel write failed.
- Fix: `release.sh` no longer ignores a failed `git fetch --tags`. The fresh fetch before promotion is
  what makes a release published while the job ran readable; if it fails the job stops (the release
  stays a draft, or is left unpromoted) instead of deciding from stale tags.
- Tests: uninstall resets the profile before restoring (a stand-in kernel only unlocks the limit once
  the profile is None); a failed profile reset and a refused restore each keep the recovery data and
  succeed once fixed; `kp.sh` with an unwritable, impossible or directory config; a failed tag fetch in
  `release.sh`. Each new check fails on the code it replaces.

## v1.1.8
- Fix: uninstall no longer throws away the recovery data after a failed restore. `apply_state` used to
  report success even when the kernel refused to take the phone's own value back, so `tune.sh stop`
  said ok and `uninstall.sh` deleted the saved settings, the recorded stock values and the "changed"
  markers that a later restore needs. A refused restore now makes `apply_state` fail, and `stop`
  prints `error:` and exits 1 instead of `ok`. `uninstall.sh` also checks the reset of the kernel
  profile.
- Fix: Stock, Apply and any setting change exit non-zero, with an `error:` line, when a restore of the
  phone's own value was refused (the warning naming the limit is still shown, and the limit stays
  marked for a retry). Before, they ended in `ok`.
- Fix: the Action button no longer announces `Frequency preset: ...` when the preset failed. It shows
  the real `error:` / `warn:` lines, says the preset was not fully applied, and exits 1. Warnings are
  shown on success too.
- Fix: `kp.sh apply` and `kp.sh cycle` exit non-zero when a requested mode or auto change failed (the
  resulting state is still printed, and `cycle` no longer says "switched" after a failure). The
  kernel's refusal no longer prints a stray shell error line either.
- Fix: `tune.sh boot` no longer prints `boot done` after a failed apply or watcher start. It prints
  `boot finished with errors`, logs it in `tune.log`, and exits 1.
- Tests: a refused restore through Stock, `stop`, a setting change and uninstall; boot after a failed
  watcher start; the Action button on success, failed watcher start and refused restore; and
  `kp.sh apply` / `cycle` with a refused mode and a refused auto setting.

## v1.1.7
- Fix: a restore the kernel refuses no longer makes the module forget the limit. Before, a failed
  write of the phone's own value was reported but the limit was still unmarked as changed, so a later
  Stock, Apply or disable no longer knew it had to put that value back. A limit is now unmarked only
  after the phone's own value has been read back correctly; otherwise it stays marked, the module says
  so (`warn: could not put the phone's own value back for: ...`), logs it, and Stock or Apply tries
  again.
- Fix: the watcher no longer discards what the hand-back says. When it hands the limits back for a
  disabled or removed module (or for "Apply my limits" turned off), any warning is written to
  `/data/adb/kprofiles_ui/tune.log`.
- Fix: an incomplete first-boot snapshot no longer lets Stock look complete. If a limit was changed and
  the phone's own value for it was never recorded, Apply and Stock now say which one
  (`warn: the phone's own value is not recorded for: ...`). No frequency is ever made up.
- Fix: a watcher that fails to start is reported. Apply, a preset or a setting now exits non-zero with
  an `error:` line if the watcher did not appear (or another start or stop held the lock), and says
  that the limits themselves are applied for the current screen state. Before, it said ok.
- Safer lock: only the process that took the lock removes it, and a lock whose owner has not written
  its pid yet is given about five seconds (it was two) before it is treated as abandoned.
- `release.sh`: right after a new draft release is created, a brief "release not found" answer while
  listing its files is retried a few times (only that answer; any other failure still stops the job).
- Tests: the cleanup between sections no longer opens every process's environment (about 250 `Permission
  denied` lines per run and a slow start of each section); one `grep` over the command lines finds the
  watchers and only those are looked at, still including a watcher whose pid file is gone. New tests
  cover a refused restore and its retry, the watcher's log of it, a partial snapshot, a watcher that
  fails to start, a busy lock, a pid-less lock and the release retry. Each new test fails on v1.1.6.

## v1.1.6
- Fix: two watchers could run at once and the second one undid the first one's work. When a
  watcher lost its pid file (a wiped settings folder, or a start that raced another) it kept
  running unseen, never saw the `disable` / `remove` marker of the module, and put the caps back
  right after the tracked watcher had handed them back. This was the intermittent "limit handed
  back" failure in the tests. Every watcher now checks, on each pass, that the pid file still names
  it, and leaves quietly if not. (Reading the file is a shell built-in, so no extra process runs.)
- The watcher logs when it hands the limits back for a disabled or removed module, and when it
  leaves because it lost the pid file (`/data/adb/kprofiles_ui/tune.log`).
- Starting the watcher waits up to ten seconds for it to appear (it used to give up after three,
  which a heavily loaded phone could exceed), and only as long as it needs.
- Apply with "Apply my limits" off, and Stop, now report a watcher that will not stop (non-zero
  exit, `error:` line) instead of saying ok. Your settings are kept.
- `uninstall.sh` keeps the saved settings and the recorded stock values if the watcher could not be
  stopped, so a later restore still has what it needs.
- A stock frequency reading of `0` (or `00`) is no longer recorded as a frequency; it never
  replaces a saved snapshot.
- `build.sh` clears `dist/` before any check can fail, so a refused build never leaves an earlier
  build's zip, manifest or notes behind.
- Tests: the test run itself leaked watchers into later sections (one section never turned the
  no-watcher switch back on), which is what made the failure intermittent. Every fake phone now
  starts by stopping all watchers of the run. New tests cover a watcher without the pid file,
  a watcher that will not stop (apply, stop, uninstall), zero readings and stale build output.
  Each new test was checked by deliberately breaking the code.

## v1.1.5
- Fix: the background watcher is now started with the module folder passed to it explicitly. Before,
  it worked out its folder from the way the script was started, which fails when the script is
  started by name alone, and then the `disable` / `remove` markers would be looked for in the wrong
  place. The previous test change did not include this source change; it is in now, with tests that
  start the watcher from inside the module folder, check which folder it received, and cover both
  the `disable` and the `remove` marker.
- Fix: stopping the watcher no longer claims success when it did not stop. If it is still running
  after three seconds, Stop says so and keeps its pid file; otherwise the pid file is removed only if
  it still names the process that was stopped. Starting and stopping the watcher now share one lock,
  so two of them can no longer run at the same time (a lock left by a dead process is taken over).
- Fix: the boot-time recording of the phone's own limits is checked before it replaces anything. If a
  frequency node exists but gives no reading, or a reading that is not a number, the earlier record is
  kept, the boot output warns which values could not be read, and a short line goes to
  `/data/adb/kprofiles_ui/tune.log`. A phone with no saved record yet still keeps the values it could
  read. Hardware that is simply absent (for example no GPU node) is not treated as a failure.
- Release safety (`release.sh`):
  - The latest release is read again right before a release is promoted. If a newer release appeared
    while the job ran, this one is still published but does not take "latest"; a new latest with the
    same `versionCode` stops the job. Releases from tags are also queued one at a time in the workflow.
  - Files already on a public release must match the build byte for byte, not only in size.
  - After publishing, the zip, `changelog.md` and `update.json` are downloaded from the release and
    compared with the build, and `latest/download/update.json` must carry this release's version,
    `versionCode`, zip link and changelog link exactly. Public files are still never replaced
    automatically.
- Build (`build.sh`): `dist/` is cleared of every module zip from earlier local builds, so uploading
  `dist/*.zip` can never include a stale one. The zip is now reproducible (fixed file dates, sorted
  file order, fixed permissions): the same source gives the same bytes, which the byte-for-byte check
  above relies on.
- New tests for all of the above, under dash, mksh and busybox ash in CI.

## v1.1.4
- New: **updates straight from the KernelSU-Next manager.** The module now carries an
  `updateJson` link. When a newer release is published on GitHub, the manager shows an update
  button on the module (with the release notes); tap it, then reboot. Nothing to download by hand.
- Each release now publishes three files: the module zip, `update.json` (the manifest the manager
  reads) and `changelog.md` (the notes for that version). The manifest is a release asset, so it
  only changes when a release is actually published and its zip is already attached.
- The release notes are taken from this changelog instead of being auto-generated.
- `build.sh` writes `dist/update.json` and `dist/changelog.md` next to the zip, reads
  `module.prop` safely even with Windows line endings, and stops if this changelog has no section
  for the version being built. The version must be exactly `vMAJOR.MINOR.PATCH` (so `v1..4`,
  `v1.1v4`, `v1.1.`, `v1.1` and `v1.1.4-rc1` are refused), and `versionCode` must be a whole number
  from 1 to 2147483647 with no leading zero (`0007` used to build and produce an update.json that
  is not valid JSON). The manifest's changelog link points at that version's own `changelog.md`,
  not at whatever release is newest.
- Publishing moved into `release.sh`, which the workflow runs on a version tag:
  - A new release is created as a draft, filled with the zip, `update.json` and `changelog.md`
    (re-tried if an upload fails, and checked to be complete), and only then published, so the
    manager never sees a release without its manifest.
  - A draft you created by hand is filled and published the same way, instead of being left as a
    draft that the manager cannot see. Files already on a draft are replaced, which is safe because
    nobody can see a draft.
  - A release that is already public only gets the files it is missing. A file that is already
    there is never deleted or replaced: GitHub's `--clobber` removes the old file before it uploads
    the new one, so a failed upload would leave users without it. If a public file differs from the
    build, the job stops and tells you to delete that file on the release page and re-run.
  - Only GitHub's "release not found" answer is taken to mean "no such release". Any other failure
    while looking up the latest release (network, API, authentication) stops the job. Before, such a
    failure looked like "no latest release yet" and could let an older release be made the latest.
  - A release is refused if its `versionCode` is the same as, or lower than, the current latest
    release's, because the manager would not offer it as an update.
  - Re-running the workflow for an older tag repairs that release's files but never makes it the
    latest release.
  - After publishing, `latest/download/update.json` is downloaded and its zip and changelog links
    are fetched. A release that does not resolve fails the job.
- New tests, run under dash, mksh and busybox ash in CI: `tests/build-test.sh` (manifest fields
  and JSON, release notes cut to one version, Windows line endings, refusal of a missing changelog
  section and of 17 malformed version / versionCode values) and `tests/release-test.sh` (the
  release rules above, run against a fake `gh`, no network). The fake `gh` behaves like the real
  one where it matters: it reports "release not found" only when that is true, can fail like a
  network error, and deletes the old file when a `--clobber` upload fails. Tests cover a failed
  latest-release or tag look-up, public releases that must never be clobbered, a failed upload that
  must not lose existing files, and a public file that differs from the build.
- The page header shows the installed version, so you can see that an update has taken effect.
- Updating keeps your settings (they live outside the module folder). The first install of v1.1.4
  has to be done by hand once, because older versions have no update link.

## v1.1.3
- Fix: disabling or removing the module in the manager now hands the limits back. The watcher
  used to keep re-applying them until the next reboot, because the manager only drops a marker
  file. The watcher now looks for `disable` / `remove` in the module folder.
- Fix: stopping and restarting the watcher quickly could leave the new one without its pid file
  (the old one deleted it as it woke up), so the page showed "not running" while a watcher was
  running. The watcher now reacts to a stop at once, removes the pid file only if it is still
  its own, and Stop waits until the old one has really gone. Stop also signals only a process
  that is recognisably the watcher, never whatever a stale pid file names.
- Fix: the boot-time recording of the phone's own limits no longer takes a reading while the
  kernel Battery profile is on. It keeps the earlier record instead, or records nothing.
- Reset everything now sets the kernel profile to None first, then restores the limits, and
  reports an error if the kernel profile could not be changed (the limits are still restored).
- The screen watcher reads the brightness with shell built-ins instead of starting `cat` and a
  subshell every second (about 30% fewer processes started while the screen is off).
- Presets fail closed: a value is also skipped, with a warning, when the controls exist but
  the phone's list of available frequencies cannot be read. Missing controls still report
  "controls not found".
- Stock and Apply now warn when the phone's own limits were never recorded (kernel Battery was
  on before the first recording), instead of silently leaving the caps in place until a reboot.
- `uninstall.sh` deletes the fixed folder `/data/adb/kprofiles_ui` and reads nothing from the
  environment.
- The page says "Applied, with a warning" (not "the kernel did not accept") because warnings can
  also come from skipped preset values or missing stock values.
- Tests: disable and remove markers, watcher stop/restart/exit, boot with the Battery profile on,
  Reset everything with a failing profile node, unreadable and empty lists, the missing-stock
  warning, the shipped uninstall script, brightness reading. Each new test was checked by
  deliberately breaking the code. README: who controls what, and a short on-phone check of the
  kernel profile modes.

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
