# Changelog

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
