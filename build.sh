#!/bin/sh
# Build the flashable module zip, the update manifest and the release notes into ./dist
#   dist/Kprofiles-Control-<version>.zip   what you install
#   dist/update.json                       what the KernelSU-Next manager reads to offer updates
#   dist/changelog.md                      this version's section of CHANGELOG.md
set -e
cd "$(dirname "$0")"
REPO="${REPO:-${GITHUB_REPOSITORY:-NeoZIL/kprofiles-control}}"
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

mkdir -p dist
rm -f "$OUT" dist/update.json dist/changelog.md

# Release notes: the "## <version>" section of CHANGELOG.md. A release without notes is an error.
tr -d '\r' < CHANGELOG.md | awk -v h="## $VER" '
  $0 == h { f = 1; next }
  /^## /  { if (f) exit }
  f
' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' > dist/changelog.md
[ -s dist/changelog.md ] || { echo "build: CHANGELOG.md has no '## $VER' section" >&2; rm -f dist/changelog.md; exit 1; }

( cd module && zip -q -r9 -X "../$OUT" . )

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
