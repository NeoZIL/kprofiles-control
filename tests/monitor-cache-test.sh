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
# A stale lock must not block cache writes forever. The lock lives in /data, so it survives a reboot, and the
# pid recorded in it can then belong to an unrelated live process (here: this test shell).
mkdir -p "$T/cache.lock" && printf '%s\n' "$$" > "$T/cache.lock/pid"
if run set-interval 15 >/dev/null 2>&1; then check "a lock left by a reused pid is cleared and the write succeeds" 15 "$(field "$(run get)" sampling_interval)"; else check "a lock left by a reused pid is cleared and the write succeeds" yes no; fi
rm -rf "$T/cache.lock"; mkdir -p "$T/cache.lock"
if run set-interval 30 >/dev/null 2>&1; then check "a lock whose owner never wrote a pid is cleared and the write succeeds" 30 "$(field "$(run get)" sampling_interval)"; else check "a lock whose owner never wrote a pid is cleared and the write succeeds" yes no; fi
check "the cache lock folder is released after the write" no "$([ -d "$T/cache.lock" ] && echo yes || echo no)"

# A live owner with matching PID/start-time/boot identity must not be evicted at the legacy 3-second timeout.
cat > "$T/hold-cache-lock.sh" <<'HOLDER'
#!/bin/sh
lock=$1
mkdir "$lock" || exit 1
pid=$$
start=$(awk '{ sub(/^.*\) /, ""); if (NF < 20) exit 1; print $20; exit }' "/proc/$pid/stat") || exit 1
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$boot" ] || boot=unknown
printf '%s\n%s\n%s\n' "$pid" "$start" "$boot" > "$lock/pid"
sleep 4
rm -f "$lock/pid"
rmdir "$lock" 2>/dev/null || :
HOLDER
chmod +x "$T/hold-cache-lock.sh"
sh "$T/hold-cache-lock.sh" "$T/cache.lock" & holder=$!
_i=0
while [ "$_i" -lt 40 ] && { [ ! -r "$T/cache.lock/pid" ] || [ "$(sed -n '1p' "$T/cache.lock/pid")" != "$holder" ]; }; do sleep 0.05; _i=$((_i + 1)); done
MONITOR_CACHE_FILE="$T/cache" sh "$CACHE" set-interval 15 >"$T/live-lock-writer.log" 2>&1 & writer=$!
sleep 3.2
check "a verified live cache-lock owner is not evicted after the legacy timeout" "$holder" "$(sed -n '1p' "$T/cache.lock/pid" 2>/dev/null)"
check "the cache writer remains waiting while the live owner holds the lock" yes "$(kill -0 "$writer" 2>/dev/null && echo yes || echo no)"
wait "$holder" 2>/dev/null
wait "$writer" 2>/dev/null; writer_rc=$?
check "a waiting cache write succeeds after the live lock is released" 0 "$writer_rc"
check "the waiting cache write is committed after release" 15 "$(field "$(run get)" sampling_interval)"

# A live but unrelated PID with a mismatching recorded start time is a reused PID, not a live lock owner.
mkdir -p "$T/cache.lock"
printf '%s\n0\n%s\n' "$$" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$T/cache.lock/pid"
if run set-interval 60 >/dev/null 2>&1; then check "a reused live PID with a mismatching start token is reclaimed" 60 "$(field "$(run get)" sampling_interval)"; else check "a reused live PID with a mismatching start token is reclaimed" yes no; fi
check "the cache lock folder is released after the identity-based takeover" no "$([ -d "$T/cache.lock" ] && echo yes || echo no)"
# --- Two waiters must never both reclaim the same abandoned lock ---------------------------------------
# Waiter B reads "stale", then (simulated by a hook on the one external command in that check) waiter A
# reclaims the lock and takes it with a live identity. B must NOT delete A's live lock afterwards.
race_dir=$(mktemp -d); mkdir -p "$race_dir/bin"
sleep 300 & race_p1=$!; sleep 300 & race_p2=$!
real_awk=$(command -v awk)
case "$real_awk" in /*) ;; *) real_awk="awk"; for _d in /usr/bin /bin /usr/local/bin; do [ -x "$_d/awk" ] && { real_awk="$_d/awk"; break; }; done ;; esac
race_start2=$("$real_awk" '{ sub(/^.*\) /, ""); print $20 }' "/proc/$race_p2/stat")
race_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
race_lock="$race_dir/cache.lock"
mkdir "$race_lock"; printf '%s\n%s\n%s\n' "$race_p1" 1 "$race_boot" > "$race_lock/pid"      # recorded start time does not match: stale
cat > "$race_dir/bin/awk" <<HOOK
#!/bin/sh
out=\$("$real_awk" "\$@"); rc=\$?
case "\$*" in *"NF < 20"*)
  if [ ! -f "$race_dir/hooked" ]; then : > "$race_dir/hooked"
    rm -f "$race_lock/pid"; rmdir "$race_lock"; mkdir "$race_lock"
    printf '%s\n%s\n%s\n' "$race_p2" "$race_start2" "$race_boot" > "$race_lock/pid"
  fi ;; esac
printf '%s\n' "\$out"; exit \$rc
HOOK
chmod +x "$race_dir/bin/awk"
MONITOR_AWK_CMD="$race_dir/bin/awk" MONITOR_CACHE_FILE="$race_dir/cache" sh "$CACHE" set-active 4.25 1700000000000 0 >/dev/null 2>&1; race_rc=$?
check "race: the hook ran, so the race really happened (it is not a PATH lookup, which busybox ash ignores)" yes "$([ -f "$race_dir/hooked" ] && echo yes || echo no)"
check "race: the waiter that read an old 'stale' does not take a lock that is live now" 1 "$race_rc"
check "race: the live owner's lock is untouched" "$race_p2" "$(sed -n 1p "$race_lock/pid" 2>/dev/null)"
check "race: nothing was written by the waiter that lost" no "$([ -e "$race_dir/cache" ] && echo yes || echo no)"
kill "$race_p1" "$race_p2" 2>/dev/null; wait "$race_p1" "$race_p2" 2>/dev/null; rm -rf "$race_dir"

# A normal stale reclaim leaves no reclaim guard behind
gd=$(mktemp -d); sleep 300 & gp=$!
mkdir "$gd/cache.lock"; printf '%s\n%s\n%s\n' "$gp" 1 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$gd/cache.lock/pid"
MONITOR_CACHE_FILE="$gd/cache" sh "$CACHE" set-active 4.25 1700000000000 0 >/dev/null 2>&1; check "stale lock (reused PID) is reclaimed and the write succeeds" 0 "$?"
check "no reclaim guard is left behind" no "$([ -e "$gd/cache.lock.reclaim" ] && echo yes || echo no)"
check "the lock is released after the write" no "$([ -e "$gd/cache.lock" ] && echo yes || echo no)"
kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null

# A reclaim guard left by a reclaimer that died does not block an abandoned lock for ever
mkdir "$gd/cache2.lock" "$gd/cache2.lock.reclaim"                       # lock without identity + a guard nobody will remove
MONITOR_CACHE_FILE="$gd/cache2" sh "$CACHE" set-active 4.25 1700000000000 0 >/dev/null 2>&1; check "an abandoned guard and an abandoned lock are both cleared and the write succeeds" 0 "$?"
check "the abandoned guard is gone afterwards" no "$([ -e "$gd/cache2.lock.reclaim" ] && echo yes || echo no)"
# ... and the same when the abandoned lock has a real but dead owner ("stale"): the guard must not block it either
sleep 0.1 & dead_p=$!; wait "$dead_p" 2>/dev/null
mkdir "$gd/cache3.lock" "$gd/cache3.lock.reclaim"
printf '%s\n%s\n%s\n' "$dead_p" 12345 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$gd/cache3.lock/pid"
MONITOR_CACHE_FILE="$gd/cache3" sh "$CACHE" set-active 4.25 1700000000000 0 >/dev/null 2>&1; check "a stale lock (dead owner) behind an abandoned guard is cleared and the write succeeds" 0 "$?"
check "the abandoned guard of a stale lock is gone afterwards" no "$([ -e "$gd/cache3.lock.reclaim" ] && echo yes || echo no)"
check "the stale lock is released afterwards" no "$([ -e "$gd/cache3.lock" ] && echo yes || echo no)"
MONITOR_CACHE_FILE="$gd/cache3" sh "$CACHE" set-interval 60 >/dev/null 2>&1; check "a later write is not slowed or blocked" 0 "$?"
rm -rf "$gd"


[ "$fail" -eq 0 ] && echo "all monitor-cache tests passed" || exit 1
