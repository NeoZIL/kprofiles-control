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
cycle_gen() { field "$(run get)" generation; }
run_cyc() { run set-cycle "$(cycle_gen)" "cycle_id=$1"; }

out=$(run get)
check "monitoring defaults enabled" 1 "$(field "$out" monitor_enabled)"
check "data generation begins at zero" 0 "$(field "$out" generation)"
check "no cycle exists on an empty cache" none "$(field "$out" cycle_state)"
for key in active_charge active_ms active_unmeasured active_prov idle_charge idle_ms idle_unmeasured idle_prov active_recent_ms idle_recent_ms cycle_id; do check "empty cache emits $key as zero" 0 "$(field "$out" "$key")"; done
for key in active_recent_ua idle_recent_ua cycle_boot; do check "empty cache emits $key as empty" '' "$(field "$out" "$key")"; done
check "the retired sampling-interval setting is gone" '' "$(field "$out" sampling_interval)"
check "the retired reset-on-charging setting is gone" '' "$(field "$out" reset_on_charging)"
check "the retired rate fields are gone" '' "$(field "$out" active_rate)$(field "$out" idle_rate)"

run set-cycle 0 cycle_id=3 cycle_state=discharging cycle_boot=abcd0123-ef45-6789-abcd-ef0123456789 \
  active_charge=123456789012 active_ms=60000 active_unmeasured=5000 active_prov=1 \
  idle_charge=98765432100 idle_ms=300000 idle_unmeasured=0 idle_prov=0 \
  active_recent_ua=250000 active_recent_ms=60000 idle_recent_ua=31000 idle_recent_ms=300000
out=$(run get)
check "the whole cycle record survives a fresh script invocation" "3|discharging|abcd0123-ef45-6789-abcd-ef0123456789" "$(field "$out" cycle_id)|$(field "$out" cycle_state)|$(field "$out" cycle_boot)"
check "active totals survive" "123456789012|60000|5000|1" "$(field "$out" active_charge)|$(field "$out" active_ms)|$(field "$out" active_unmeasured)|$(field "$out" active_prov)"
check "idle totals survive and stay separate" "98765432100|300000|0|0" "$(field "$out" idle_charge)|$(field "$out" idle_ms)|$(field "$out" idle_unmeasured)|$(field "$out" idle_prov)"
check "recent estimates survive" "250000|60000|31000|300000" "$(field "$out" active_recent_ua)|$(field "$out" active_recent_ms)|$(field "$out" idle_recent_ua)|$(field "$out" idle_recent_ms)"
run set-cycle 0 active_ms=70000
check "a partial update keeps every other field" "70000|98765432100|3" "$(field "$(run get)" active_ms)|$(field "$(run get)" idle_charge)|$(field "$(run get)" cycle_id)"

refuse() {
  _what=$1; shift
  if run "$@" >/dev/null 2>&1; then check "$_what" refused accepted; else check "$_what" refused refused; fi
}
refuse "an unknown key is refused" set-cycle 0 evil_key=1
refuse "shell metacharacters in a value are refused" set-cycle 0 'cycle_id=1;touch /tmp/kp-injected'
refuse "a non-numeric duration is refused" set-cycle 0 active_ms=12x
refuse "a negative duration is refused" set-cycle 0 active_ms=-5
refuse "a bad cycle state is refused" set-cycle 0 cycle_state=exploding
refuse "a non-hex boot id is refused" set-cycle 0 'cycle_boot=zz;zz'
refuse "a non-0/1 provisional flag is refused" set-cycle 0 active_prov=2
refuse "unmeasured time larger than its total is refused" set-cycle 0 idle_unmeasured=999999999
refuse "a missing generation is refused" set-cycle cycle_id=1
refuse "a stale generation is refused" set-cycle 99 cycle_id=1
check "no injected file was created" no "$([ -e /tmp/kp-injected ] && echo yes || echo no)"
check "refused writes changed nothing" 70000 "$(field "$(run get)" active_ms)"
run set-cycle 99 cycle_id=1 >/dev/null 2>&1; check "a stale generation exits with status 3" 3 "$?"

run set-enabled 0
check "monitoring can be switched off" 0 "$(field "$(run get)" monitor_enabled)"
refuse "an invalid enabled value is refused" set-enabled 2
run set-enabled 1

# Reset screen-on time restarts the active side (time AND the charge it divides) and keeps idle totals and the cycle.
run reset-screen-on-time
out=$(run get)
check "SOT reset clears screen-on time" 0 "$(field "$out" active_ms)"
check "SOT reset clears the active charge so Active Drain stays consistent" 0 "$(field "$out" active_charge)"
check "SOT reset clears active unmeasured time and provisional flag" "0|0" "$(field "$out" active_unmeasured)|$(field "$out" active_prov)"
check "SOT reset preserves screen-off time" 300000 "$(field "$out" idle_ms)"
check "SOT reset preserves idle charge" 98765432100 "$(field "$out" idle_charge)"
check "SOT reset keeps the cycle" "3|discharging" "$(field "$out" cycle_id)|$(field "$out" cycle_state)"
check "SOT reset advances the generation" 1 "$(field "$out" generation)"
refuse "a collector write made before the SOT reset is refused" set-cycle 0 active_ms=5000

run set-cycle 1 active_ms=9000 active_charge=2700000000
run reset-data
out=$(run get)
for key in active_charge active_ms idle_charge idle_ms active_unmeasured idle_unmeasured active_recent_ms idle_recent_ms; do check "manual reset clears $key" 0 "$(field "$out" "$key")"; done
check "manual reset clears the recent estimates" "" "$(field "$out" active_recent_ua)$(field "$out" idle_recent_ua)"
check "manual reset keeps the monitoring setting" 1 "$(field "$out" monitor_enabled)"
check "manual reset keeps the cycle" "3|discharging" "$(field "$out" cycle_id)|$(field "$out" cycle_state)"
check "manual reset advances the generation again" 2 "$(field "$out" generation)"
refuse "a stale-generation write is refused after a reset" set-cycle 1 active_ms=1
run set-cycle 2 active_ms=1234
check "a current-generation write succeeds" 1234 "$(field "$(run get)" active_ms)"

# Old caches written by v4.0.x are read without error; their rate fields are ignored.
printf 'active_rate=4.25\nactive_time=1700000000000\nsampling_interval=60\nreset_on_charging=0\nlast_charger=connected\nscreen_on_ms=30000\nmonitor_enabled=0\ngeneration=7\n' > "$T/oldcache"
out=$(MONITOR_CACHE_FILE="$T/oldcache" sh "$CACHE" get)
check "an old cache keeps its monitoring setting" 0 "$(field "$out" monitor_enabled)"
check "an old cache keeps its generation" 7 "$(field "$out" generation)"
check "an old cache's retired fields are not carried over" "0" "$(field "$out" active_ms)"

# A stale lock must not block cache writes forever. The lock lives in /data, so it survives a reboot, and the
# pid recorded in it can then belong to an unrelated live process (here: this test shell).
mkdir -p "$T/cache.lock" && printf '%s\n' "$$" > "$T/cache.lock/pid"
if run_cyc 15 >/dev/null 2>&1; then check "a lock left by a reused pid is cleared and the write succeeds" 15 "$(field "$(run get)" cycle_id)"; else check "a lock left by a reused pid is cleared and the write succeeds" yes no; fi
rm -rf "$T/cache.lock"; mkdir -p "$T/cache.lock"
if run_cyc 30 >/dev/null 2>&1; then check "a lock whose owner never wrote a pid is cleared and the write succeeds" 30 "$(field "$(run get)" cycle_id)"; else check "a lock whose owner never wrote a pid is cleared and the write succeeds" yes no; fi
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
MONITOR_CACHE_FILE="$T/cache" sh "$CACHE" set-cycle "$(cycle_gen)" cycle_id=15 >"$T/live-lock-writer.log" 2>&1 & writer=$!
sleep 3.2
check "a verified live cache-lock owner is not evicted after the legacy timeout" "$holder" "$(sed -n '1p' "$T/cache.lock/pid" 2>/dev/null)"
check "the cache writer remains waiting while the live owner holds the lock" yes "$(kill -0 "$writer" 2>/dev/null && echo yes || echo no)"
wait "$holder" 2>/dev/null
wait "$writer" 2>/dev/null; writer_rc=$?
check "a waiting cache write succeeds after the live lock is released" 0 "$writer_rc"
check "the waiting cache write is committed after release" 15 "$(field "$(run get)" cycle_id)"

# A live but unrelated PID with a mismatching recorded start time is a reused PID, not a live lock owner.
mkdir -p "$T/cache.lock"
printf '%s\n0\n%s\n' "$$" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$T/cache.lock/pid"
if run_cyc 60 >/dev/null 2>&1; then check "a reused live PID with a mismatching start token is reclaimed" 60 "$(field "$(run get)" cycle_id)"; else check "a reused live PID with a mismatching start token is reclaimed" yes no; fi
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
MONITOR_AWK_CMD="$race_dir/bin/awk" MONITOR_CACHE_FILE="$race_dir/cache" sh "$CACHE" set-cycle 0 cycle_id=7 >/dev/null 2>&1; race_rc=$?
check "race: the hook ran, so the race really happened (it is not a PATH lookup, which busybox ash ignores)" yes "$([ -f "$race_dir/hooked" ] && echo yes || echo no)"
check "race: the waiter that read an old 'stale' does not take a lock that is live now" 1 "$race_rc"
check "race: the live owner's lock is untouched" "$race_p2" "$(sed -n 1p "$race_lock/pid" 2>/dev/null)"
check "race: nothing was written by the waiter that lost" no "$([ -e "$race_dir/cache" ] && echo yes || echo no)"
kill "$race_p1" "$race_p2" 2>/dev/null; wait "$race_p1" "$race_p2" 2>/dev/null; rm -rf "$race_dir"

# A normal stale reclaim leaves no reclaim guard behind
gd=$(mktemp -d); sleep 300 & gp=$!
mkdir "$gd/cache.lock"; printf '%s\n%s\n%s\n' "$gp" 1 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$gd/cache.lock/pid"
MONITOR_CACHE_FILE="$gd/cache" sh "$CACHE" set-cycle 0 cycle_id=7 >/dev/null 2>&1; check "stale lock (reused PID) is reclaimed and the write succeeds" 0 "$?"
check "no reclaim guard is left behind" no "$([ -e "$gd/cache.lock.reclaim" ] && echo yes || echo no)"
check "the lock is released after the write" no "$([ -e "$gd/cache.lock" ] && echo yes || echo no)"
kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null

# A reclaim guard left by a reclaimer that died does not block an abandoned lock for ever
mkdir "$gd/cache2.lock" "$gd/cache2.lock.reclaim"                       # lock without identity + a guard nobody will remove
MONITOR_CACHE_FILE="$gd/cache2" sh "$CACHE" set-cycle 0 cycle_id=7 >/dev/null 2>&1; check "an abandoned guard and an abandoned lock are both cleared and the write succeeds" 0 "$?"
check "the abandoned guard is gone afterwards" no "$([ -e "$gd/cache2.lock.reclaim" ] && echo yes || echo no)"
# ... and the same when the abandoned lock has a real but dead owner ("stale"): the guard must not block it either
sleep 0.1 & dead_p=$!; wait "$dead_p" 2>/dev/null
mkdir "$gd/cache3.lock" "$gd/cache3.lock.reclaim"
printf '%s\n%s\n%s\n' "$dead_p" 12345 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$gd/cache3.lock/pid"
MONITOR_CACHE_FILE="$gd/cache3" sh "$CACHE" set-cycle 0 cycle_id=7 >/dev/null 2>&1; check "a stale lock (dead owner) behind an abandoned guard is cleared and the write succeeds" 0 "$?"
check "the abandoned guard of a stale lock is gone afterwards" no "$([ -e "$gd/cache3.lock.reclaim" ] && echo yes || echo no)"
check "the stale lock is released afterwards" no "$([ -e "$gd/cache3.lock" ] && echo yes || echo no)"
MONITOR_CACHE_FILE="$gd/cache3" sh "$CACHE" set-cycle 0 cycle_id=60 >/dev/null 2>&1; check "a later write is not slowed or blocked" 0 "$?"
rm -rf "$gd"


[ "$fail" -eq 0 ] && echo "all monitor-cache tests passed" || exit 1
