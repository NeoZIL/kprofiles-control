#!/bin/sh
# Persistent battery-monitor settings/data tests. Does not touch the real module directory.
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE="$HERE/../module/monitor-cache.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
run() { MONITOR_CACHE_FILE="$T/cache" sh "$CACHE" "$@"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
out=$(run get)
for key in active_rate active_time idle_rate idle_time; do check "empty cache emits $key" '' "$(field "$out" "$key")"; done
check "screen-on time defaults to zero" 0 "$(field "$out" screen_on_ms)"
check "screen-off time defaults to zero" 0 "$(field "$out" screen_off_ms)"
check "monitoring defaults enabled" 1 "$(field "$out" monitor_enabled)"
check "screen-on sampling defaults to 30 seconds" 30 "$(field "$out" sampling_interval)"
check "reset-on-charging defaults enabled" 1 "$(field "$out" reset_on_charging)"
check "data generation begins at zero" 0 "$(field "$out" generation)"

run set-active 4.25 1700000000000 0
out=$(run get)
check "active rate survives a fresh script invocation" 4.25 "$(field "$out" active_rate)"
check "active timestamp survives a fresh script invocation" 1700000000000 "$(field "$out" active_time)"
run set-idle 1.75 1700000005000 0
out=$(run get)
check "setting idle preserves active rate" 4.25 "$(field "$out" active_rate)"
check "idle rate survives a fresh script invocation" 1.75 "$(field "$out" idle_rate)"
check "idle timestamp survives a fresh script invocation" 1700000005000 "$(field "$out" idle_time)"
run add-screen-time on 30000 0
run add-screen-time off 60000 0
out=$(run get)
check "screen-on time is saved in the persistent cache" 30000 "$(field "$out" screen_on_ms)"
check "screen-off time is saved separately" 60000 "$(field "$out" screen_off_ms)"
if run add-screen-time on 30000 99 >/dev/null 2>&1; then check "stale screen-time write is refused" no yes; else check "stale screen-time write is refused" yes yes; fi
if run add-screen-time on 120001 0 >/dev/null 2>&1; then check "oversized screen-time delta is refused" no yes; else check "oversized screen-time delta is refused" yes yes; fi
if run set-active '4.2;touch /tmp/injected' 1700000006000 >/dev/null 2>&1; then check "malformed rate is refused" no yes; else check "malformed rate is refused" yes yes; fi
if run set-idle 4.2 '1000x' >/dev/null 2>&1; then check "malformed timestamp is refused" no yes; else check "malformed timestamp is refused" yes yes; fi

run set-enabled 0
run set-interval 60
run set-reset-on-charging 0
run set-charger-state connected
out=$(run get)
check "monitoring preference persists" 0 "$(field "$out" monitor_enabled)"
check "sampling interval persists" 60 "$(field "$out" sampling_interval)"
check "reset-on-charging preference persists" 0 "$(field "$out" reset_on_charging)"
check "charger state persists" connected "$(field "$out" last_charger)"

# Reset SOT independently without deleting saved rates or the screen-off total.
run set-active 3.5 1700000008000 0
run set-idle 1.5 1700000009000 0
run add-screen-time on 120000 0
run add-screen-time off 120000 0
run add-screen-time off 60000 0
run reset-screen-on-time
out=$(run get)
check "SOT-only reset clears screen-on time" 0 "$(field "$out" screen_on_ms)"
check "SOT-only reset preserves screen-off time" 240000 "$(field "$out" screen_off_ms)"
check "SOT-only reset preserves active drain" 3.5 "$(field "$out" active_rate)"
check "SOT-only reset preserves idle drain" 1.5 "$(field "$out" idle_rate)"
check "SOT-only reset advances generation for stale-writer protection" 1 "$(field "$out" generation)"
if run add-screen-time on 30000 0 >/dev/null 2>&1; then check "SOT-only reset rejects stale screen-time write" no yes; else check "SOT-only reset rejects stale screen-time write" yes yes; fi

run reset-data
out=$(run get)
for key in active_rate active_time idle_rate idle_time; do check "manual reset clears $key" '' "$(field "$out" "$key")"; done
check "manual reset clears screen-on time" 0 "$(field "$out" screen_on_ms)"
check "manual reset clears screen-off time" 0 "$(field "$out" screen_off_ms)"
check "manual reset increments data generation" 2 "$(field "$out" generation)"
check "manual reset preserves monitoring preference" 0 "$(field "$out" monitor_enabled)"
check "manual reset preserves sampling interval" 60 "$(field "$out" sampling_interval)"
check "manual reset preserves reset-on-charging preference" 0 "$(field "$out" reset_on_charging)"
check "manual reset preserves charger-state context" connected "$(field "$out" last_charger)"
if run set-active 2.4 1700000007000 1 >/dev/null 2>&1; then check "stale generation rate write is refused after reset" no yes; else check "stale generation rate write is refused after reset" yes yes; fi
run set-active 2.4 1700000007000 2
out=$(run get)
check "current-generation rate write succeeds" 2.4 "$(field "$out" active_rate)"
check "cache file is not world-readable" 600 "$(stat -c %a "$T/cache" 2>/dev/null || stat -f %Lp "$T/cache" 2>/dev/null)"
[ "$fail" -eq 0 ] && echo "all monitor-cache tests passed" || exit 1
