#!/bin/sh
# Build the flashable module zip into ./dist
set -e
cd "$(dirname "$0")"
VER=$(sed -n 's/^version=//p' module/module.prop)
OUT="dist/Kprofiles-Control-${VER}.zip"
mkdir -p dist
rm -f "$OUT"
( cd module && zip -q -r9 -X "../$OUT" . )
echo "built $OUT"
