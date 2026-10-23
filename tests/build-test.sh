#!/bin/sh
# Off-device test of build.sh: the zip, the update manifest and the release notes.
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }

# Work on a scratch copy so the real dist/ is never touched.
mk() {
  rm -rf "$T/r"; mkdir -p "$T/r/module"
  cp "$HERE/../build.sh" "$T/r/"; cp "$HERE/../module/"* "$T/r/module/" 2>/dev/null
  printf '%s' "$1" > "$T/r/module/module.prop"
  printf '%s' "$2" > "$T/r/CHANGELOG.md"
}
PROP='id=x
name=X
version=v2.3.4
versionCode=42
updateJson=https://example.invalid/update.json
'
LOG='# Changelog

## v2.3.4
- newest thing
- another line

## v2.3.3
- older thing
'
mk "$PROP" "$LOG"
( cd "$T/r" && REPO=me/mod sh build.sh >/dev/null 2>&1 ); check "build succeeds" 0 $?
check "zip name"        "Kprofiles-Control-v2.3.4.zip" "$(ls "$T/r/dist" | grep '\.zip$')"
check "manifest version" "v2.3.4" "$(sed -n 's/.*"version": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "manifest code"    "42" "$(sed -n 's/.*"versionCode": \([0-9]*\),/\1/p' "$T/r/dist/update.json")"
check "manifest zipUrl"  "https://github.com/me/mod/releases/download/v2.3.4/Kprofiles-Control-v2.3.4.zip" \
  "$(sed -n 's/.*"zipUrl": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "manifest changelog" "https://github.com/me/mod/releases/download/v2.3.4/changelog.md" \
  "$(sed -n 's/.*"changelog": "\(.*\)"/\1/p' "$T/r/dist/update.json")"
check "notes are this version only" "- newest thing
- another line" "$(cat "$T/r/dist/changelog.md")"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d["versionCode"],int)' "$T/r/dist/update.json" 2>/dev/null
  check "manifest is valid JSON" 0 $?
fi
check "zip has module.prop" 1 "$(unzip -l "$T/r/dist/"*.zip | grep -c ' module.prop$')"

# Windows line endings in module.prop and CHANGELOG.md must not leak into the output.
mk "$(printf '%s' "$PROP" | sed 's/$/\r/')
" "$(printf '%s' "$LOG" | sed 's/$/\r/')
"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "CRLF inputs build" 0 $?
check "CRLF: version clean" "v2.3.4" "$(sed -n 's/.*"version": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "CRLF: no CR in notes" 0 "$(grep -c "$(printf '\r')" "$T/r/dist/changelog.md")"

# Refusals: a build that would publish something broken must fail and leave no manifest.
mk "$PROP" "# Changelog

## v9.9.9
- other
"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "missing changelog section fails" 1 $?
check "no manifest left behind" 0 "$(ls "$T/r/dist" 2>/dev/null | grep -c json)"
# Every malformed versionCode / version must be refused, and must leave no manifest behind.
refuse() { # $1 label  $2 sed expression applied to PROP
  mk "$(printf '%s' "$PROP" | sed "$2")" "$LOG"
  ( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "$1 fails" 1 $?
  check "$1: no manifest" 0 "$(ls "$T/r/dist" 2>/dev/null | grep -c json)"
}
refuse "versionCode 4x"            's/^versionCode=42/versionCode=4x/'
refuse "versionCode leading zero"  's/^versionCode=42/versionCode=0042/'
refuse "versionCode zero"          's/^versionCode=42/versionCode=0/'
refuse "versionCode empty"         's/^versionCode=42/versionCode=/'
refuse "versionCode negative"      's/^versionCode=42/versionCode=-5/'
refuse "versionCode too large"     's/^versionCode=42/versionCode=2147483648/'
refuse "versionCode 20 digits"     's/^versionCode=42/versionCode=99999999999999999999/'
refuse "version quote"             's/^version=v2.3.4/version=v2.3.4"x/'
refuse "version double dot"        's/^version=v2.3.4/version=v2..4/'
refuse "version trailing dot"      's/^version=v2.3.4/version=v2.3.4./'
refuse "version inner v"           's/^version=v2.3.4/version=v2.3v4/'
refuse "version trailing v"        's/^version=v2.3.4/version=v2.3.4v/'
refuse "version double v"          's/^version=v2.3.4/version=vv2.3.4/'
refuse "version two parts"         's/^version=v2.3.4/version=v2.3/'
refuse "version four parts"        's/^version=v2.3.4/version=v2.3.4.5/'
refuse "version suffix"            's/^version=v2.3.4/version=v2.3.4-rc1/'
refuse "version no v"              's/^version=v2.3.4/version=2.3.4/'
# The top of the allowed range is accepted and still valid JSON.
mk "$(printf '%s' "$PROP" | sed 's/^versionCode=42/versionCode=2147483647/')" "$LOG"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "versionCode max builds" 0 $?
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["versionCode"]==2147483647' "$T/r/dist/update.json" 2>/dev/null
  check "versionCode max is valid JSON" 0 $?
fi

# The real module must point at a manifest that matches the real build.
real=$(tr -d '\r' < "$HERE/../module/module.prop")
check "real module.prop has updateJson" 1 "$(printf '%s\n' "$real" | grep -c '^updateJson=https://github.com/.*/releases/latest/download/update.json$')"
rm -rf "$T/real"; mkdir -p "$T/real/module"; cp "$HERE/../build.sh" "$HERE/../CHANGELOG.md" "$T/real/"; cp -r "$HERE/../module/." "$T/real/module/"
( cd "$T/real" && sh build.sh >/dev/null 2>&1 ); check "real repo builds" 0 $?

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
