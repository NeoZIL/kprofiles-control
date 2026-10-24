# Changelog

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
