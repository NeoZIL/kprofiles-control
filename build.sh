#!/bin/sh
# Build the flashable module zip, the update manifest and the release notes into ./dist
#   dist/Kprofiles-Control-<version>.zip   what you install
#   dist/update.json                       what the KernelSU-Next manager reads to offer updates
#   dist/changelog.md                      this version's section of CHANGELOG.md
set -e
cd "$(dirname "$0")"
REPO="${REPO:-${GITHUB_REPOSITORY:-NeoZIL/kprofiles-control}}"
# dist/ belongs to this script. Clear what it makes FIRST, before any check can fail, so a refused
# build never leaves an earlier build's zip, manifest or notes behind to be uploaded by mistake.
mkdir -p dist
rm -f dist/Kprofiles-Control-*.zip dist/update.json dist/changelog.md
prop() { tr -d '\r' < module/module.prop | sed -n "s/^$1=//p" | head -n 1; }
VER=$(prop version)
CODE=$(prop versionCode)
# Version: exactly vMAJOR.MINOR.PATCH (digits only, no leading text or suffix).
printf '%s\n' "$VER" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
  { echo "build: bad version '$VER' in module.prop (expected vMAJOR.MINOR.PATCH, e.g. v1.1.4)" >&2; exit 1; }
# versionCode: a canonical positive integer (no sign, no leading zero, no zero) that fits the
# signed 32-bit range (so any parser reads it exactly). Leading zeros would make update.json invalid JSON.
# The range check uses expr, not [ -le ]: mksh's built-in test does 32-bit arithmetic, so 2147483648 wraps
# negative there and would wrongly pass.
printf '%s\n' "$CODE" | grep -Eq '^[1-9][0-9]{0,9}$' && expr "$CODE" \<= 2147483647 >/dev/null ||
  { echo "build: versionCode '$CODE' must be a whole number from 1 to 2147483647 without leading zeros" >&2; exit 1; }
OUT="dist/Kprofiles-Control-${VER}.zip"


# Release notes: the "## <version>" section of CHANGELOG.md. A release without notes is an error.
tr -d '\r' < CHANGELOG.md | awk -v h="## $VER" '
  $0 == h { f = 1; next }
  /^## /  { if (f) exit }
  f
' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' > dist/changelog.md
[ -s dist/changelog.md ] || { echo "build: CHANGELOG.md has no '## $VER' section" >&2; rm -f dist/changelog.md; exit 1; }

# Reproducible zip: the files are copied to a scratch folder, given one fixed date and added in sorted
# order, so building the same source twice gives byte-identical zips (release.sh compares them).
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp -R module/. "$STAGE/"
chmod -R u=rwX,go=rX "$STAGE"
ABS_OUT="$PWD/$OUT"
find "$STAGE" -exec touch -t 200001010000 {} +
( cd "$STAGE" && find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -q -9 -X "$ABS_OUT" -@ )

BASE="https://github.com/$REPO/releases"
cat > dist/update.json <<JSON
{
  "version": "$VER",
  "versionCode": $CODE,
  "zipUrl": "$BASE/download/$VER/Kprofiles-Control-$VER.zip",
  "changelog": "$BASE/download/$VER/changelog.md"
}
JSON
echo "built $OUT, dist/update.json, dist/changelog.md"
