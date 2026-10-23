#!/bin/sh
# Publish the files in ./dist as a GitHub release (run by the workflow on a v* tag, after build.sh).
#   sh release.sh [tag]        tag defaults to $GITHUB_REF_NAME
#
# Rules:
#  - A new release is created as a draft with all three files, then published. It is never public
#    without update.json, because the manager reads that file from the LATEST release.
#  - An existing DRAFT gets the full file set and is then published (the same as a new release).
#  - An existing PUBLISHED release only gets the files it is MISSING attached (retried, then
#    verified). A file that is already there is never deleted or replaced, because GitHub's
#    `--clobber` deletes the old file before uploading the new one, and a failed upload would leave
#    users with no file. If a published file differs from the build, the job stops and says so.
#  - Only GitHub's "release not found" answer means "there is no such release". Any other failure
#    (network, API, authentication) stops the job; it is never read as "no latest release", which
#    could let an older release be promoted to latest.
#  - The release becomes "latest" only when its versionCode is higher than the current latest's.
#    Re-running an older tag repairs its files but never takes over "latest".
#  - A new release whose versionCode is not higher than the current latest's is refused.
#  - After publishing, update.json is downloaded from the latest/download URL and its zip and
#    changelog links are fetched, so a broken release fails the job instead of users' updates.
set -e
cd "$(dirname "$0")"
TAG="${1:-$GITHUB_REF_NAME}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
ZIP="dist/Kprofiles-Control-$TAG.zip"
die() { echo "release: $*" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# gh_view ARGS: run `gh release view ARGS`. Status 0 = ok (output on stdout), 44 = GitHub says the
# release does not exist, 1 = any other failure (reported on stderr, never mistaken for "not found").
gh_view() {
  if gh release view "$@" 2>"$TMP/err"; then return 0; fi
  if grep -qi 'release not found' "$TMP/err"; then return 44; fi
  echo "release: 'gh release view $*' failed: $(cat "$TMP/err")" >&2
  return 1
}

for f in "$ZIP" dist/update.json dist/changelog.md; do
  [ -s "$f" ] || die "missing $f (run build.sh first)"
done
CODE=$(tr -d '\r' < module/module.prop | sed -n 's/^versionCode=//p' | head -n 1)
printf '%s\n' "$CODE" | grep -Eq '^[1-9][0-9]*$' || die "bad versionCode '$CODE'"

# Name and size of every file on the release, one "name size" pair per line.
assets_of() { gh_view "$TAG" --json assets --jq '.assets[] | "\(.name) \(.size)"'; }

# upload draft|published
#  draft:     replace all three files (--clobber). Nobody can see a draft, so a failed replacement
#             costs nothing: the release stays a draft and is never published.
#  published: attach only the files that are missing; no --clobber, nothing is ever deleted.
upload() {
  mode=$1; n=0
  while :; do
    have=$(assets_of) || die "could not list the files of release $TAG"
    set --
    for f in "$ZIP" dist/update.json dist/changelog.md; do
      b=$(basename "$f"); size=$(wc -c < "$f" | tr -d ' ')
      cur=$(printf '%s\n' "$have" | awk -v n="$b" '$1 == n { print $2; exit }')
      if [ "$mode" = draft ]; then
        set -- "$@" "$f"
      elif [ -z "$cur" ]; then
        set -- "$@" "$f"
      elif [ "$cur" != "$size" ]; then
        die "$b on the published release $TAG is $cur bytes but the build is $size bytes. Not replacing a public file (an upload that fails would leave it missing). Delete it on the release page, then re-run this job."
      fi
    done
    if [ "$#" -eq 0 ]; then break; fi
    if [ "$mode" = draft ]; then
      if gh release upload "$TAG" "$@" --clobber; then break; fi
    else
      if gh release upload "$TAG" "$@"; then break; fi
    fi
    n=$((n + 1)); [ "$n" -lt 3 ] || die "uploading the files failed 3 times"
    echo "release: upload failed, retrying ($n/3)" >&2; sleep 5
  done
  have=$(assets_of) || die "could not list the files of release $TAG"
  for f in "$ZIP" dist/update.json dist/changelog.md; do
    b=$(basename "$f"); size=$(wc -c < "$f" | tr -d ' ')
    printf '%s\n' "$have" | grep -qx "$b $size" || die "$b is missing from the release after upload (or has the wrong size)"
  done
}

# What is "latest" today, and is this release newer than it?
rc=0; LATEST=$(gh_view --json tagName --jq .tagName) || rc=$?
case "$rc" in
  0) ;;
  44) LATEST="" ;;   # GitHub confirmed there is no release yet
  *) die "cannot tell which release is the latest; stopping instead of guessing" ;;
esac
MAKE_LATEST=yes
if [ -n "$LATEST" ] && [ "$LATEST" != "$TAG" ]; then
  PREV=$(git show "$LATEST:module/module.prop" 2>/dev/null | tr -d '\r' | sed -n 's/^versionCode=//p' | head -n 1)
  printf '%s\n' "$PREV" | grep -Eq '^[0-9]+$' || die "cannot read the versionCode of the current latest release $LATEST"
  if [ "$CODE" -eq "$PREV" ]; then
    die "versionCode $CODE is the same as $LATEST. Raise it in module.prop."
  elif [ "$CODE" -lt "$PREV" ]; then
    MAKE_LATEST=no
  fi
fi

rc=0; STATE=$(gh_view "$TAG" --json isDraft --jq '.isDraft') || rc=$?
case "$rc" in
  0) ;;
  44) STATE="" ;;    # GitHub confirmed this tag has no release yet
  *) die "cannot tell whether release $TAG exists; stopping instead of guessing" ;;
esac
case "$STATE" in
  '')
    [ "$MAKE_LATEST" = yes ] || die "versionCode $CODE is lower than $LATEST ($PREV). Raise it in module.prop."
    gh release create "$TAG" --draft --title "Kprofiles Control $TAG" --notes-file dist/changelog.md
    upload draft
    gh release edit "$TAG" --draft=false --latest
    ;;
  true)
    upload draft
    gh release edit "$TAG" --notes-file dist/changelog.md --draft=false "--latest=$([ "$MAKE_LATEST" = yes ] && echo true || echo false)"
    ;;
  false)
    upload published
    if [ "$MAKE_LATEST" = yes ]; then gh release edit "$TAG" --latest; fi
    ;;
  *) die "unexpected release state '$STATE'" ;;
esac

# Post-release check: what a phone will fetch must resolve.
[ "$MAKE_LATEST" = yes ] || { echo "release: $TAG repaired; not latest ($LATEST stays latest), so the latest-manifest check is skipped"; exit 0; }
get() { curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$1" "$2"; }
get "$TMP/update.json" "https://github.com/$REPO/releases/latest/download/update.json" ||
  die "latest/download/update.json does not resolve"
field() { sed -n "s/.*\"$1\": \"\\(.*\\)\".*/\\1/p" "$TMP/update.json" | head -n 1; }
[ "$(field version)" = "$TAG" ] || die "latest update.json says version '$(field version)', expected $TAG"
grep -q "\"versionCode\": $CODE," "$TMP/update.json" || die "latest update.json has a different versionCode than $CODE"
for k in zipUrl changelog; do
  url=$(field "$k"); [ -n "$url" ] || die "update.json has no $k"
  get "$TMP/$k" "$url" || die "$k $url does not resolve"
done
echo "release: $TAG published and verified (update.json, zip and changelog resolve)"
