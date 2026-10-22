#!/system/bin/sh
# Action button: cycle the frequency presets Stock -> Battery tilt -> Battery saver -> Stock.
MODDIR=${0%/*}
cur=$(sh "$MODDIR/tune.sh" status | sed -n 's/^preset=//p' | head -n 1)
case "$cur" in stock) n=tilt ;; tilt) n=saver ;; *) n=stock ;; esac
sh "$MODDIR/tune.sh" preset "$n" >/dev/null
echo "Frequency preset: $n"
sh "$MODDIR/tune.sh" status | grep -E '^(enabled|state|cur_)' 
