# Releasing

1. Raise `version` (exactly `vMAJOR.MINOR.PATCH`) and `versionCode` (a whole number, higher than the
   last release's, no leading zero) in `module/module.prop`, and add a `## <version>` section to
   `CHANGELOG.md`. The build stops without that section; it becomes the release notes.
2. Commit and push. When Actions is green, push a tag equal to the version (for example `v4.4.3`).
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

## How updates reach users

`module.prop` has an `updateJson` link to `update.json` on the newest GitHub release. The manager compares `versionCode` and shows an update button with the release notes. The manager does the download, and only when you open it; the module itself never uses the network. Versions before v1.1.4 have no link, so that one had to be installed by hand once.

## What CI runs

GitHub Actions runs ShellCheck (`shellcheck -s sh -S warning -e SC1090,SC2154,SC2034 module/*.sh tests/*.sh build.sh release.sh`),
both Node suites, then the shell suites under dash, mksh (the shell Android uses) and busybox ash, and checks that a pushed tag
matches the `version` in `module.prop`.

## Running the tests locally

```
sh tests/kp-test.sh              # kernel profile script, fake sysfs
sh tests/control-test.sh         # controller source: migration, exclusive writes, handoff, recovery
sh tests/tune-test.sh            # frequency script and screen watcher (the slow one)
sh tests/monitor-test.sh         # hardware monitor discovery
sh tests/monitor-cache-test.sh   # battery-rate cache and its lock
sh tests/monitor-daemon-test.sh  # battery collector and its start lock
sh tests/build-test.sh           # zip, update manifest and release notes
sh tests/release-test.sh         # release.sh rules against a fake gh (no network)
node tests/webui-test.js module/webroot/index.html
node tests/webui-dom-test.js module/webroot/index.html
sh build.sh                      # dist/Kprofiles-Control-<version>.zip, update.json, changelog.md
```
