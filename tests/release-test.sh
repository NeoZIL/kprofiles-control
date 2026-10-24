#!/bin/sh
# Off-device test of release.sh with a fake gh, git and curl (no network, no GitHub). `sleep` is made a no-op
# by a shell function, not a PATH stand-in: busybox ash runs its own built-in sleep and ignores PATH for it.
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }

F="$T/fake"; mkdir -p "$T/bin"
# fake gh: state lives in files under $FAKE (latest, state_<tag>, assets_<tag> holding "name size"
# lines, upload_fail, calls). It mimics the real gh where it matters: "release not found" is printed
# only when there really is no such release; FAKE_GH_FAIL=latest|tag simulates a transient API/network
# error on that lookup; an upload without --clobber refuses a name that already exists; and an upload
# WITH --clobber deletes the old file first, so a failed upload leaves it missing (the real behaviour).
cat > "$T/bin/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$FAKE/calls"
[ "$1" = release ] || exit 2
sub=$1; shift; sub=$1; shift
tag=""; case "$1" in --*|"") ;; *) tag=$1; shift ;; esac
json=""; prev=""; clobber=""
for a in "$@"; do [ "$prev" = --json ] && json=$a; [ "$a" = --clobber ] && clobber=1; prev=$a; done
notfound() { echo "release not found" >&2; exit 1; }
neterr() { echo "error connecting to api.github.com" >&2; exit 1; }
case "$sub" in
  view)
    if [ -z "$tag" ]; then
      [ "$FAKE_GH_FAIL" = latest ] && neterr
      [ -s "$FAKE/latest" ] || notfound
      cat "$FAKE/latest"; exit 0
    fi
    [ "$FAKE_GH_FAIL" = tag ] && neterr
    [ -f "$FAKE/state_$tag" ] || notfound
    case "$json" in
      isDraft) [ "$(cat "$FAKE/state_$tag")" = draft ] && echo true || echo false ;;
      assets)
        n=$(cat "$FAKE/viewmiss" 2>/dev/null || echo 0)       # a just-created release is not found yet
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAKE/viewmiss"; notfound; fi
        cat "$FAKE/assets_$tag" ;;
    esac ;;
  create) echo draft > "$FAKE/state_$tag"; : > "$FAKE/assets_$tag" ;;
  upload)
    names=""
    for a in "$@"; do case "$a" in --*) ;; *) names="$names $(basename "$a")" ;; esac; done
    if [ -z "$clobber" ]; then
      for n in $names; do
        if grep -q "^$n " "$FAKE/assets_$tag"; then echo "a release with the same name already exists: $n" >&2; exit 1; fi
      done
    else
      for n in $names; do grep -v "^$n " "$FAKE/assets_$tag" > "$FAKE/tmp"; mv "$FAKE/tmp" "$FAKE/assets_$tag"; done
    fi
    n=$(cat "$FAKE/upload_fail" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAKE/upload_fail"; exit 1; fi
    for a in "$@"; do case "$a" in --*) ;; *) echo "$(basename "$a") $(wc -c < "$a" | tr -d ' ')" >> "$FAKE/assets_$tag"; cp "$a" "$FAKE/blob_${tag}_$(basename "$a")" ;; esac; done
    # race hook: another release is published while this job is busy uploading (its versionCode is in $FAKE/race)
    if [ -f "$FAKE/race" ]; then
      echo v2.4.0 > "$FAKE/latest"; printf 'versionCode=%s\n' "$(cat "$FAKE/race")" > "$FAKE/props_v2.4.0"; echo published > "$FAKE/state_v2.4.0"
    fi ;;
  edit)
    for a in "$@"; do
      case "$a" in
        --draft=false) echo published > "$FAKE/state_$tag" ;;
        --latest|--latest=true) echo "$tag" > "$FAKE/latest" ;;
      esac
    done ;;
esac
exit 0
GH
cat > "$T/bin/git" <<'GIT'
#!/bin/sh
# git fetch ...: succeeds, unless FAKE_GIT_FETCH_FAIL is set (a network error)
if [ "$1" = fetch ]; then echo "git $*" >> "$FAKE/calls"; [ -z "$FAKE_GIT_FETCH_FAIL" ] || { echo "fatal: unable to access remote" >&2; exit 128; }; exit 0; fi
# git show <tag>:module/module.prop  ->  the versionCode recorded for that tag
ref=${2%%:*}
[ -f "$FAKE/props_$ref" ] || exit 128
cat "$FAKE/props_$ref"
GIT
cat > "$T/bin/curl" <<'CURL'
#!/bin/sh
out=""; prev=""; url=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
echo "curl $url" >> "$FAKE/calls"
case "$url" in
  */latest/download/update.json)
    [ -z "$FAKE_NO_MANIFEST" ] || exit 22
    if [ -n "$FAKE_WRONG_URL" ]; then sed 's#download/v2.3.4#download/v1.0.0#g' "$FAKE_DIST/update.json" > "$out"; else cp "$FAKE_DIST/update.json" "$out"; fi ;;
  */download/*/*)
    name=${url##*/}; rest=${url%/*}; tg=${rest##*/}
    [ -n "$FAKE_BAD_URL" ] && case "$url" in *"$FAKE_BAD_URL"*) exit 22 ;; esac
    [ -f "$FAKE/blob_${tg}_$name" ] || exit 22
    if [ -n "$FAKE_CORRUPT" ] && [ "$name" = "$FAKE_CORRUPT" ]; then echo corrupt > "$out"; else cp "$FAKE/blob_${tg}_$name" "$out"; fi ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$T/bin/"*

# A built release for v2.3.4 / versionCode 42, in a scratch repo.
R="$T/r"; mkdir -p "$R/module"
cp "$HERE/../build.sh" "$HERE/../release.sh" "$R/"
printf 'id=x\nversion=v2.3.4\nversionCode=42\n' > "$R/module/module.prop"
printf '# Changelog\n\n## v2.3.4\n- thing\n' > "$R/CHANGELOG.md"
( cd "$R" && REPO=me/mod sh build.sh >/dev/null 2>&1 )

run() { # env assignments are passed as arguments: run NAME=value ...
  printf 'sleep() { :; }\n. "$R/release.sh"\n' > "$R/run-release.sh"
  ( cd "$R" && env R="$R" PATH="$T/bin:$PATH" FAKE="$F" FAKE_DIST="$R/dist" GITHUB_REPOSITORY=me/mod GITHUB_REF_NAME=v2.3.4 "$@" sh "$R/run-release.sh" >"$T/out" 2>&1 )
}
size() { wc -c < "$R/dist/$1" | tr -d ' '; }
seed() { # seed TAG NAME... : the release already holds these files, with the sizes of the current build
  t=$1; shift; for n in "$@"; do echo "$n $(size "$n")" >> "$F/assets_$t"; cp "$R/dist/$n" "$F/blob_${t}_$n"; done
}
reset() { rm -rf "$F"; mkdir -p "$F"; : > "$F/calls"; }
latest() { echo "$1" > "$F/latest"; printf 'versionCode=%s\n' "$2" > "$F/props_$1"; echo published > "$F/state_$1"; }
calls() { grep -c "$1" "$F/calls"; }

# 1. First ever release: draft, files, publish as latest, then verified.
reset; run; check "new release: ok" 0 $?
check "new release: created as draft"      1 "$(calls 'release create v2.3.4 --draft')"
check "new release: no files on create"    0 "$(calls 'release create.*\.zip')"
check "new release: 3 files attached"      "Kprofiles-Control-v2.3.4.zip update.json changelog.md" "$(cut -d' ' -f1 "$F/assets_v2.3.4" | tr '\n' ' ' | sed 's/ $//')"
check "new release: published as latest"   1 "$(calls 'release edit v2.3.4 --draft=false --latest')"
check "new release: manifest fetched"      1 "$(calls 'curl .*/latest/download/update.json')"
check "new release: zip url fetched"       1 "$(calls 'curl .*/download/v2.3.4/Kprofiles-Control-v2.3.4.zip')"
check "new release: changelog url fetched" 1 "$(calls 'curl .*/download/v2.3.4/changelog.md')"

# 2. Existing draft (made by hand): filled and published, newest becomes latest.
reset; latest v2.3.3 41; echo draft > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run; check "draft: ok" 0 $?
check "draft: not recreated"  0 "$(calls 'release create')"
check "draft: published"      1 "$(calls 'release edit v2.3.4 .*--draft=false')"
check "draft: is latest"      "v2.3.4" "$(cat "$F/latest")"

# 3. Existing published release that is the newest: files re-attached, stays/becomes latest, never re-drafted.
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run; check "published: ok" 0 $?
check "published: files attached" 3 "$(wc -l < "$F/assets_v2.3.4" | tr -d ' ')"
check "published: not re-drafted" 0 "$(calls 'draft=false')"
check "published: is latest"      "v2.3.4" "$(cat "$F/latest")"

# 4. Re-running an OLDER tag repairs it but must not take over latest.
reset; latest v2.4.0 50; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run; check "older rerun: ok" 0 $?
check "older rerun: files attached" 3 "$(wc -l < "$F/assets_v2.3.4" | tr -d ' ')"
check "older rerun: latest unchanged" "v2.4.0" "$(cat "$F/latest")"
check "older rerun: no latest edit" 0 "$(calls 'release edit.*--latest')"
reset; latest v2.4.0 50; echo draft > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run; check "older draft: ok" 0 $?
check "older draft: published, latest unchanged" "v2.4.0" "$(cat "$F/latest")"
check "older draft: published not latest" 1 "$(calls 'release edit v2.3.4 .*--draft=false --latest=false')"

# 5. A new release that does not raise versionCode is refused before anything is created.
reset; latest v2.3.3 42
run; check "same versionCode refused" 1 $?
check "same versionCode: nothing created" 0 "$(calls 'release create')"
reset; latest v2.4.0 50
run; check "lower versionCode refused (new release)" 1 $?
check "lower versionCode: nothing created" 0 "$(calls 'release create')"
reset; latest v2.3.3 ""
run; check "unreadable latest versionCode refused" 1 $?

# 6. Upload trouble: retried, and a release whose upload never works is never published.
reset; echo 2 > "$F/upload_fail"
run; check "upload retried: ok" 0 $?
check "upload retried: published" 1 "$(calls 'draft=false')"
reset; echo 9 > "$F/upload_fail"
run; check "upload keeps failing: fails" 1 $?
check "upload keeps failing: still a draft" "draft" "$(cat "$F/state_v2.3.4")"
check "upload keeps failing: never published" 0 "$(calls 'draft=false')"

# 7. Post-release check catches a release that resolves wrongly.
reset; run FAKE_BAD_URL=Kprofiles-Control-v2.3.4.zip; check "unresolvable zip fails the job" 1 $?
reset; run FAKE_NO_MANIFEST=1;                         check "unresolvable manifest fails the job" 1 $?

# 9. A failed look-up of the latest release is an error, never "there is no latest release".
#    (Before the fix an API/network hiccup here let an older release be promoted to latest.)
reset; latest v2.4.0 50; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run FAKE_GH_FAIL=latest; check "latest look-up fails: job fails" 1 $?
check "latest look-up fails: nothing uploaded"   0 "$(calls 'release upload')"
check "latest look-up fails: nothing edited"     0 "$(calls 'release edit')"
check "latest look-up fails: latest unchanged"   "v2.4.0" "$(cat "$F/latest")"
reset; latest v2.3.3 41
run FAKE_GH_FAIL=latest; check "latest look-up fails (new release): job fails" 1 $?
check "latest look-up fails (new release): nothing created" 0 "$(calls 'release create')"
# ...while a genuine "release not found" still means a first release (test 1 above).

# 10. A failed look-up of this tag's release is an error too, not "it does not exist".
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; seed v2.3.4 Kprofiles-Control-v2.3.4.zip update.json changelog.md
run FAKE_GH_FAIL=tag; check "tag look-up fails: job fails" 1 $?
check "tag look-up fails: nothing created"  0 "$(calls 'release create')"
check "tag look-up fails: nothing uploaded" 0 "$(calls 'release upload')"

# 11. Published releases are never clobbered: only missing files are attached, nothing is deleted.
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
seed v2.3.4 update.json changelog.md
run; check "published, zip missing: ok" 0 $?
check "published, zip missing: only the zip uploaded" 1 "$(calls 'release upload v2.3.4 dist/Kprofiles-Control-v2.3.4.zip$')"
check "published, zip missing: no --clobber"          0 "$(calls 'upload.*clobber')"
check "published, zip missing: 3 files now"           3 "$(wc -l < "$F/assets_v2.3.4" | tr -d ' ')"
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
seed v2.3.4 Kprofiles-Control-v2.3.4.zip update.json changelog.md; echo 9 > "$F/upload_fail"
run; check "published, all present: ok even if uploads would fail" 0 $?
check "published, all present: no upload at all" 0 "$(calls 'release upload')"
check "published, all present: files untouched"  3 "$(wc -l < "$F/assets_v2.3.4" | tr -d ' ')"
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
seed v2.3.4 update.json changelog.md; echo 9 > "$F/upload_fail"
run; check "published, upload keeps failing: job fails" 1 $?
check "published, upload keeps failing: existing files NOT lost" 2 "$(wc -l < "$F/assets_v2.3.4" | tr -d ' ')"
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
seed v2.3.4 Kprofiles-Control-v2.3.4.zip changelog.md; echo "update.json 1" >> "$F/assets_v2.3.4"
run; check "published, file differs from build: refused" 1 $?
check "published, file differs: nothing uploaded"  0 "$(calls 'release upload')"
check "published, file differs: file kept"         1 "$(grep -c '^update.json 1$' "$F/assets_v2.3.4")"
# A draft is not public, so there --clobber is fine and a stale file is replaced.
reset; latest v2.3.3 41; echo draft > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
echo "update.json 1" >> "$F/assets_v2.3.4"
run; check "draft with stale file: ok" 0 $?
check "draft with stale file: replaced with --clobber" 1 "$(calls 'upload.*clobber')"
check "draft with stale file: new update.json attached" 1 "$(grep -c "^update.json $(size update.json)$" "$F/assets_v2.3.4")"

# 12. A newer release appears while the job runs: this one is published but never promoted over it.
reset; latest v2.3.3 41; echo 50 > "$F/race"
run; check "race, newer latest appears: job ok" 0 $?
check "race: this release is published" "published" "$(cat "$F/state_v2.3.4")"
check "race: published without --latest" 1 "$(calls 'release edit v2.3.4 --draft=false --latest=false')"
check "race: latest stays the newer release" "v2.4.0" "$(cat "$F/latest")"
reset; latest v2.3.3 41; echo draft > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"; echo 50 > "$F/race"
run; check "race (hand-made draft): job ok" 0 $?
check "race (hand-made draft): latest stays the newer release" "v2.4.0" "$(cat "$F/latest")"
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"; echo 50 > "$F/race"
run; check "race (published): job ok" 0 $?
check "race (published): latest stays the newer release" "v2.4.0" "$(cat "$F/latest")"
check "race (published): no promotion" 0 "$(calls 'release edit v2.3.4 --latest')"
reset; latest v2.3.3 41; echo 42 > "$F/race"
run; check "race, same versionCode as the new latest: job fails" 1 $?
check "race, same versionCode: not published" "draft" "$(cat "$F/state_v2.3.4")"

# 13. Content, not just size: a public file of the right size but different bytes is never accepted.
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
seed v2.3.4 Kprofiles-Control-v2.3.4.zip update.json changelog.md
sed 's/2\.3\.4/9.9.9/' "$R/dist/update.json" > "$F/blob_v2.3.4_update.json"
check "tampered fixture has the same size" "$(size update.json)" "$(wc -c < "$F/blob_v2.3.4_update.json" | tr -d ' ')"
run; check "published, same size but other content: refused" 1 $?
check "published, other content: nothing uploaded" 0 "$(calls 'release upload')"
check "published, other content: file kept" "$(sed 's/2\.3\.4/9.9.9/' "$R/dist/update.json")" "$(cat "$F/blob_v2.3.4_update.json")"
reset; run FAKE_CORRUPT=Kprofiles-Control-v2.3.4.zip; check "downloaded zip differs from the build: job fails" 1 $?
reset; run FAKE_CORRUPT=changelog.md; check "downloaded changelog differs from the build: job fails" 1 $?
reset; run FAKE_WRONG_URL=1; check "update.json pointing at another release: job fails" 1 $?
reset; run; check "verified release: ok" 0 $?
has_line() { grep -q "$2" "$1" && echo "ok   $3" || { echo "FAIL $3"; fail=1; }; }
has_line "$T/out" "published and verified" "success message says what was verified"

# 14. A release that GitHub cannot find for a moment after it was created: the asset listing is retried.
reset; echo 2 > "$F/viewmiss"
run; check "new release not visible yet: retried, job ok" 0 $?
check "new release not visible yet: published" "published" "$(cat "$F/state_v2.3.4")"
check "new release not visible yet: looked again twice" 2 "$(grep -c 'looking again' "$T/out")"
reset; echo 99 > "$F/viewmiss"
run; check "release never becomes visible: job fails" 1 $?
check "release never becomes visible: stays a draft" "draft" "$(cat "$F/state_v2.3.4")"
check "release never becomes visible: never published" 0 "$(calls 'draft=false')"
reset; run FAKE_GH_FAIL=tag; check "other lookup errors are still not retried" 0 "$(grep -c 'looking again' "$T/out")"

# 15. A failed tag fetch is an error: the previous versionCode must not be read from stale tags.
reset; latest v2.3.3 41; run
check "tags are fetched before promotion" 1 "$([ "$(calls 'git fetch --tags')" -ge 1 ] && echo 1 || echo 0)"
reset; latest v2.3.3 41; run FAKE_GIT_FETCH_FAIL=1; check "failed tag fetch: the job fails" 1 $?
check "failed tag fetch: says so" 1 "$(grep -c 'cannot fetch tags' "$T/out")"
check "failed tag fetch: the release is not published" 0 "$(calls 'draft=false')"
check "failed tag fetch: the release stays a draft" "draft" "$(cat "$F/state_v2.3.4")"
check "failed tag fetch: latest unchanged" "v2.3.3" "$(cat "$F/latest")"
reset; latest v2.3.3 41; echo published > "$F/state_v2.3.4"; : > "$F/assets_v2.3.4"
run FAKE_GIT_FETCH_FAIL=1; check "failed tag fetch (published release): the job fails" 1 $?
check "failed tag fetch (published release): not promoted" "v2.3.3" "$(cat "$F/latest")"
reset; run FAKE_GIT_FETCH_FAIL=1; check "first release (nothing to compare): a fetch failure does not matter" 0 $?

# 8. Missing build output is refused.
reset; rm -f "$R/dist/changelog.md"; run; check "missing file refused" 1 $?

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
