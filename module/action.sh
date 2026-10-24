#!/system/bin/sh
# Action button: cycle the frequency presets Stock -> Battery tilt -> Battery saver -> Stock.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR="." ;; esac
cur=$(sh "$MODDIR/tune.sh" status | sed -n 's/^preset=//p' | head -n 1)
case "$cur" in stock) n=tilt ;; tilt) n=saver ;; *) n=stock ;; esac
rc=0
out=$(sh "$MODDIR/tune.sh" preset "$n" 2>&1) || rc=1
if [ "$rc" = 0 ]; then
  echo "Frequency preset: $n"
  printf '%s\n' "$out" | grep -E '^warn:'      # warnings are shown, ok is not repeated
else
  echo "Frequency preset $n was NOT fully applied:"
  printf '%s\n' "$out" | grep -E '^(error|warn):'
  [ -n "$out" ] || echo "error: no answer from tune.sh"
fi
sh "$MODDIR/tune.sh" status | grep -E '^(enabled|state|cur_)'
exit "$rc"
