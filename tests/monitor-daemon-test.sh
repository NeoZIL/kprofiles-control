#!/bin/sh
# Background battery-monitor collector tests; all cache and sensor paths are temporary/read-only.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
setup_mod() {
  mkdir -p "$1"
  cp "$ROOT/module/monitor-daemon.sh" "$ROOT/module/monitor-cache.sh" "$ROOT/module/module.prop" "$1/"
  chmod +x "$1/monitor-daemon.sh" "$1/monitor-cache.sh"
  cat > "$1/monitor.sh" <<'MONITOR'
#!/bin/sh
screen=${MONITOR_TEST_SCREEN:-on}
status=${MONITOR_TEST_STATUS:-Discharging}
capacity=${MONITOR_TEST_CAPACITY:-68}
charge=${MONITOR_TEST_CHARGE:-2891000}
charger=${MONITOR_TEST_CHARGER:-unknown}
if [ -n "${MONITOR_TEST_SEQUENCE_FILE:-}" ]; then
  n=0; [ -r "${MONITOR_TEST_SEQUENCE_COUNT:-}" ] && IFS= read -r n < "$MONITOR_TEST_SEQUENCE_COUNT"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); printf '%s\n' "$n" > "$MONITOR_TEST_SEQUENCE_COUNT"
  line=$(sed -n "${n}p" "$MONITOR_TEST_SEQUENCE_FILE")
  if [ -n "$line" ]; then
    IFS='|' read -r capacity charge status charger sequence_screen <<EOF_SEQUENCE
$line
EOF_SEQUENCE
    [ -n "$sequence_screen" ] && screen=$sequence_screen
  fi
fi
printf 'screen_state=%s\n' "$screen"
printf 'battery_status=%s\n' "$status"
printf 'battery_capacity=%s\n' "$capacity"
printf 'battery_charge_counter=%s\n' "$charge"
printf 'battery_charge_full=%s\n' "${MONITOR_TEST_FULL:-4425000}"
printf 'charger_online=%s\n' "$charger"
MONITOR
  chmod +x "$1/monitor.sh"
}
run_daemon_once() {
  MOD=$1; CACHE_FILE=$2
  shift 2
  env MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$T/data-$$" "$@" sh "$MOD/monitor-daemon.sh" once "$MOD"
}
setup_fast_tools() {
  mkdir -p "$T/tools"
  cat > "$T/tools/date" <<'DATE'
#!/bin/sh
if [ "$1" = +%s ]; then
  n=0; [ -r "$DATE_SEQUENCE_COUNT" ] && IFS= read -r n < "$DATE_SEQUENCE_COUNT"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); printf '%s\n' "$n" > "$DATE_SEQUENCE_COUNT"
  # Never let a runner-level DATE_STEP (for example 0) collapse the clock.
  # The run helper below also supplies a deterministic default; this is a second guard.
  step=${DATE_STEP:-120}
  case "$step" in ''|*[!0-9]*|0) step=120 ;; esac
  echo $((1700000000 + (n - 1) * step))
else
  exec /bin/date "$@"
fi
DATE
  cat > "$T/tools/sleep" <<'SLEEP'
#!/bin/sh
# Sampling loop only: remove real delays in the deterministic test process.
exit 0
SLEEP
  chmod +x "$T/tools/date" "$T/tools/sleep"
}
# The fake clock and sleep are handed to the daemon BY PATH (MONITOR_DATE_CMD / MONITOR_SLEEP_CMD), never
# found through PATH: busybox ash on Debian/Ubuntu runs its own date and sleep applets in preference to any
# file in PATH, which made these tests read the real clock and really sleep on the CI runner.
run_daemon_limited() {
  MOD=$1; CACHE_FILE=$2; MAX=$3
  shift 3
  env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" DATE_SEQUENCE_COUNT="$T/date-count-$$" DATE_STEP=120 MONITOR_CACHE_FILE="$CACHE_FILE" \
    MONITOR_DATA_DIR="$T/data-loop-${CACHE_FILE##*/}-$$" MONITOR_DAEMON_MAX_SAMPLES="$MAX" "$@" \
    sh "$MOD/monitor-daemon.sh" run "$MOD"
}
init_cache() {
  CACHE_FILE=$1
  MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" set-active 4.25 1700000000000
  MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" set-idle 1.75 1700000005000
  MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" add-screen-time on 30000 0
  MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" add-screen-time off 60000 0
  MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" set-charger-state disconnected
}
MOD="$T/module"
setup_mod "$MOD"

# Plugging in with full auto-reset enabled clears Kprofiles Control's drain data and both screen-time totals.
CACHE_FILE="$T/charging-on-cache"
init_cache "$CACHE_FILE"
MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" set-reset-on-charging 1
run_daemon_once "$MOD" "$CACHE_FILE" MONITOR_TEST_STATUS=Charging MONITOR_TEST_CHARGER=1 MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
for key in active_rate active_time idle_rate idle_time; do check "charger connection clears $key with auto-reset enabled" '' "$(field "$out" "$key")"; done
check "charger connection clears screen-on time with auto-reset enabled" 0 "$(field "$out" screen_on_ms)"
check "charger connection clears screen-off time with auto-reset enabled" 0 "$(field "$out" screen_off_ms)"
check "charger-triggered reset increments generation" 1 "$(field "$out" generation)"
check "charger connection is remembered" connected "$(field "$out" last_charger)"
check "auto-reset leaves the monitoring toggle unchanged" 1 "$(field "$out" monitor_enabled)"
check "auto-reset leaves interval unchanged" 30 "$(field "$out" sampling_interval)"
check "auto-reset leaves its own preference enabled" 1 "$(field "$out" reset_on_charging)"

# With bulk auto-reset off, preserve valid rates and screen-off time but reset SOT at cycle start; never retain a measurement window over charging.
CACHE_FILE="$T/charging-off-cache"
init_cache "$CACHE_FILE"
MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" set-reset-on-charging 0
run_daemon_once "$MOD" "$CACHE_FILE" MONITOR_TEST_STATUS=Charging MONITOR_TEST_CHARGER=1 MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "charger connection preserves active rate when auto-reset is off" 4.25 "$(field "$out" active_rate)"
check "charger connection preserves idle rate when auto-reset is off" 1.75 "$(field "$out" idle_rate)"
check "SOT resets at the start of a charge cycle even when bulk auto-reset is OFF" 0 "$(field "$out" screen_on_ms)"
check "screen-off time is preserved when bulk auto-reset is off" 60000 "$(field "$out" screen_off_ms)"
check "SOT-only charge reset preserves drain-data generation guard" 1 "$(field "$out" generation)"
check "auto-reset OFF is preserved" 0 "$(field "$out" reset_on_charging)"
check "charging state is remembered when auto-reset is off" connected "$(field "$out" last_charger)"

# A Full status without a positive charger-online reading must not be treated as a plug-in event.
CACHE_FILE="$T/full-unplugged-cache"
init_cache "$CACHE_FILE"
run_daemon_once "$MOD" "$CACHE_FILE" MONITOR_TEST_STATUS=Full MONITOR_TEST_CHARGER=0 MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "Full-but-unplugged is not a false charging reset" 4.25 "$(field "$out" active_rate)"
check "Full-but-unplugged keeps disconnected state" disconnected "$(field "$out" last_charger)"

# Unknown online state plus Full is ambiguous; fail safe and do not erase saved rates.
CACHE_FILE="$T/full-unknown-cache"
init_cache "$CACHE_FILE"
run_daemon_once "$MOD" "$CACHE_FILE" MONITOR_TEST_STATUS=Full MONITOR_TEST_CHARGER=unknown MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "ambiguous Full status does not auto-reset saved data" 4.25 "$(field "$out" active_rate)"
check "ambiguous Full status does not invent a charger connection" disconnected "$(field "$out" last_charger)"

# A single sampling pass only establishes an in-memory baseline; no incomplete window is persisted.
CACHE_FILE="$T/fresh-cache"
run_daemon_once "$MOD" "$CACHE_FILE" MONITOR_TEST_STATUS=Discharging MONITOR_TEST_CHARGER=0 MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "first screen-on sample is not stored as an active rate" '' "$(field "$out" active_rate)"
check "first screen-on sample is not stored as a timestamp" '' "$(field "$out" active_time)"
check "daemon does not persist an unfinished active window" 0 "$(find "$T" -type f -name '*.active-window' -o -name '*.pending' | wc -l | tr -d ' ')"

# Verify the live run loop computes rates after a full window, independently of any WebUI.
# GitHub Actions environments may carry unrelated DATE_STEP values; the helper must remain deterministic.
setup_fast_tools
CACHE_FILE="$T/active-loop-cache"
printf '68|2891000|Discharging|0\n68|2890000|Discharging|0\n' > "$T/active-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 MONITOR_TEST_SEQUENCE_FILE="$T/active-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/active-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
active_rate=$(field "$out" active_rate)
case "$active_rate" in ''|*[!0-9.]*) check "screen-on collector persists a numeric active drain rate" yes no ;; *) check "screen-on collector persists a numeric active drain rate" yes yes ;; esac
check "screen-on collector persists a millisecond timestamp" 1700000120000 "$(field "$out" active_time)"

CACHE_FILE="$T/idle-loop-cache"
rm -f "$T/date-count-$$" "$T/idle-count"
printf '68|2891000|Discharging|0\n68|2890000|Discharging|0\n' > "$T/idle-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 MONITOR_TEST_SEQUENCE_FILE="$T/idle-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/idle-count" MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
idle_rate=$(field "$out" idle_rate)
case "$idle_rate" in ''|*[!0-9.]*) check "screen-off collector persists a numeric idle drain rate" yes no ;; *) check "screen-off collector persists a numeric idle drain rate" yes yes ;; esac
check "screen-off collector keeps active rate separate" '' "$(field "$out" active_rate)"

CACHE_FILE="$T/charging-pulse-cache"
rm -f "$T/date-count-$$" "$T/pulse-count"
printf '68|2891000|Discharging|0\n68|2892000|Discharging|0\n' > "$T/pulse-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 MONITOR_TEST_SEQUENCE_FILE="$T/pulse-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/pulse-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "charge-counter increase discards a potentially contaminated window" '' "$(field "$out" active_rate)"

CACHE_FILE="$T/rebased-window-cache"
rm -f "$T/date-count-$$" "$T/rebase-count"
printf '68|2891000|Discharging|0\n68|2892000|Discharging|0\n68|2891000|Discharging|0\n' > "$T/rebase-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 3 MONITOR_TEST_SEQUENCE_FILE="$T/rebase-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/rebase-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
case "$(field "$out" active_rate)" in ''|*[!0-9.]*) check "collector rebases after an increase before measuring later drain" yes no ;; *) check "collector rebases after an increase before measuring later drain" yes yes ;; esac

# Screen time totals are persisted only between close samples with the same screen state on battery.
CACHE_FILE="$T/screen-on-time-cache"
rm -f "$T/date-count-$$" "$T/screen-on-count"
printf '68|2891000|Discharging|0|on\n68|2890000|Discharging|0|on\n' > "$T/screen-on-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=30 MONITOR_TEST_SEQUENCE_FILE="$T/screen-on-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/screen-on-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "screen-on duration is recorded from a valid 30-second same-state interval" 30000 "$(field "$out" screen_on_ms)"
check "screen-on duration does not leak into screen-off total" 0 "$(field "$out" screen_off_ms)"

CACHE_FILE="$T/screen-off-time-cache"
rm -f "$T/date-count-$$" "$T/screen-off-count"
printf '68|2891000|Discharging|0|off\n68|2890000|Discharging|0|off\n' > "$T/screen-off-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=60 MONITOR_TEST_SEQUENCE_FILE="$T/screen-off-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/screen-off-count" MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "screen-off duration is recorded from a valid 60-second same-state interval" 60000 "$(field "$out" screen_off_ms)"
check "screen-off duration does not leak into screen-on total" 0 "$(field "$out" screen_on_ms)"

CACHE_FILE="$T/screen-transition-cache"
rm -f "$T/date-count-$$" "$T/screen-transition-count"
printf '68|2891000|Discharging|0|on\n68|2890000|Discharging|0|off\n' > "$T/screen-transition-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=30 MONITOR_TEST_SEQUENCE_FILE="$T/screen-transition-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/screen-transition-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "short ON-to-OFF transition interval is credited to the prior screen-on state" 30000 "$(field "$out" screen_on_ms)"
check "short ON-to-OFF transition does not leak into screen-off time" 0 "$(field "$out" screen_off_ms)"


# With percentage-only telemetry, the rate must use the full interval between visible capacity
# steps rather than rebasing every ten minutes and overstating low drain.
CACHE_FILE="$T/active-capacity-only-cache"
rm -f "$T/date-count-$$" "$T/active-capacity-count"
printf '68||Discharging|0|on\n68||Discharging|0|on\n67||Discharging|0|on\n' > "$T/active-capacity-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 3 DATE_STEP=1800 MONITOR_TEST_SEQUENCE_FILE="$T/active-capacity-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/active-capacity-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "capacity-only active drain keeps the 60-minute baseline instead of resetting at 10 minutes" 1.000000 "$(field "$out" active_rate)"

CACHE_FILE="$T/idle-capacity-only-cache"
rm -f "$T/date-count-$$" "$T/idle-capacity-count"
printf '68||Discharging|0|off\n68||Discharging|0|off\n67||Discharging|0|off\n' > "$T/idle-capacity-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 3 DATE_STEP=3600 MONITOR_TEST_SEQUENCE_FILE="$T/idle-capacity-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/idle-capacity-count" MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "capacity-only idle drain uses the full two-hour baseline instead of inflating the rate" 0.500000 "$(field "$out" idle_rate)"

# A phone may not execute shell timers during Doze; waking after an overnight OFF interval should
# persist screen-off time and finish the pending idle-drain window instead of leaving it collecting forever.
CACHE_FILE="$T/overnight-idle-cache"
rm -f "$T/date-count-$$" "$T/overnight-count"
printf '68|2891000|Discharging|0|off\n67|2889000|Discharging|0|on\n' > "$T/overnight-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=28800 MONITOR_TEST_SEQUENCE_FILE="$T/overnight-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/overnight-count" MONITOR_TEST_SCREEN=off
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "screen-off time is persisted across an eight-hour sleep interval" 28800000 "$(field "$out" screen_off_ms)"
case "$(field "$out" idle_rate)" in ''|*[!0-9.]*) check "waking finalizes an overnight idle-drain measurement" yes no ;; *) check "waking finalizes an overnight idle-drain measurement" yes yes ;; esac

# ensure mode starts a detached collector even when a stale PID file names an unrelated reused PID.
CACHE_FILE="$T/ensure-cache"
MOD="$T/ensure-mod"
setup_mod "$MOD"
mkdir -p "$T/ensure-data"
setup_fast_tools
/bin/sleep 30 & unrelated_pid=$!
printf '%s\n%s\n%s\n' "$unrelated_pid" "$(sed -n 's/^version=//p' "$MOD/module.prop" | head -n 1)" "$MOD" > "$T/ensure-data/monitor.pid"
env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$T/ensure-data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD"
_i=0
while [ "$_i" -lt 40 ] && ! grep -q 'monitor-daemon: started' "$T/ensure-data/monitor.log" 2>/dev/null; do _i=$((_i + 1)); /bin/sleep 0.05; done
check "ensure starts the background collector when the PID file is stale" yes "$(grep -q 'monitor-daemon: started' "$T/ensure-data/monitor.log" 2>/dev/null && echo yes || echo no)"
check "ensure never kills an unrelated process whose PID was reused" yes "$(kill -0 "$unrelated_pid" 2>/dev/null && echo yes || echo no)"
kill "$unrelated_pid" 2>/dev/null || :

# A verified live starter may hold the start lock longer than the old 2-second cutoff. Ensure must wait,
# not steal the lock and launch a duplicate collector while the owner is still alive.
CACHE_FILE="$T/ensure-live-lock-cache"
MOD="$T/ensure-live-lock-mod"
setup_mod "$MOD"
mkdir -p "$T/ensure-live-lock-data"
cat > "$T/hold-start-lock.sh" <<'HOLDER'
#!/bin/sh
lock=$1
mkdir "$lock" || exit 1
pid=$$
start=$(awk '{ sub(/^.*\) /, ""); if (NF < 20) exit 1; print $20; exit }' "/proc/$pid/stat") || exit 1
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$boot" ] || boot=unknown
printf '%s\n%s\n%s\n' "$pid" "$start" "$boot" > "$lock/pid"
sleep 2.7
rm -f "$lock/pid"
rmdir "$lock" 2>/dev/null || :
HOLDER
chmod +x "$T/hold-start-lock.sh"
sh "$T/hold-start-lock.sh" "$T/ensure-live-lock-data/monitor-start.lock" & lock_holder=$!
_i=0
while [ "$_i" -lt 40 ] && { [ ! -r "$T/ensure-live-lock-data/monitor-start.lock/pid" ] || [ "$(sed -n '1p' "$T/ensure-live-lock-data/monitor-start.lock/pid")" != "$lock_holder" ]; }; do /bin/sleep 0.05; _i=$((_i + 1)); done
env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" DATE_SEQUENCE_COUNT="$T/ensure-live-date-count" DATE_STEP=120 MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$T/ensure-live-lock-data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD" >"$T/ensure-live-lock-output.log" 2>&1 & ensure_waiter=$!
/bin/sleep 2.2
check "ensure does not steal a verified live start lock after the old cutoff" "$lock_holder" "$(sed -n '1p' "$T/ensure-live-lock-data/monitor-start.lock/pid" 2>/dev/null)"
check "ensure waits while the verified live start-lock owner exists" yes "$(kill -0 "$ensure_waiter" 2>/dev/null && echo yes || echo no)"
wait "$lock_holder" 2>/dev/null
wait "$ensure_waiter" 2>/dev/null; ensure_rc=$?
check "ensure proceeds successfully after the live start lock is released" 0 "$ensure_rc"
check "ensure starts a collector after obtaining the released start lock" yes "$(grep -q 'monitor-daemon: started' "$T/ensure-live-lock-data/monitor.log" 2>/dev/null && echo yes || echo no)"

# A live but unrelated PID from an old start-lock format can be reused; the new recorded start token
# lets ensure reclaim it immediately instead of waiting for the legacy timeout.
CACHE_FILE="$T/ensure-reused-lock-cache"
MOD="$T/ensure-reused-lock-mod"
setup_mod "$MOD"
mkdir -p "$T/ensure-reused-lock-data/monitor-start.lock"
printf '%s\n0\n%s\n' "$$" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$T/ensure-reused-lock-data/monitor-start.lock/pid"
env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" DATE_SEQUENCE_COUNT="$T/ensure-reused-date-count" DATE_STEP=120 MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$T/ensure-reused-lock-data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD" >"$T/ensure-reused-lock-output.log" 2>&1
check "ensure reclaims a start lock whose live PID has a stale process-start token" yes "$(grep -q 'monitor-daemon: started' "$T/ensure-reused-lock-data/monitor.log" 2>/dev/null && echo yes || echo no)"
check "ensure removes the stale start-lock directory after starting" no "$([ -d "$T/ensure-reused-lock-data/monitor-start.lock" ] && echo yes || echo no)"

CACHE_FILE="$T/full-unplugged-screen-time-cache"
rm -f "$T/date-count-$$" "$T/full-unplugged-count"
printf '68|2891000|Full|0|on\n68|2891000|Full|0|on\n' > "$T/full-unplugged-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=30 MONITOR_TEST_SEQUENCE_FILE="$T/full-unplugged-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/full-unplugged-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "screen time still accumulates at Full when unplugging is confirmed" 30000 "$(field "$out" screen_on_ms)"

CACHE_FILE="$T/ambiguous-full-screen-time-cache"
rm -f "$T/date-count-$$" "$T/ambiguous-full-count"
printf '68|2891000|Full|unknown|on\n68|2891000|Full|unknown|on\n' > "$T/ambiguous-full-sequence"
run_daemon_limited "$MOD" "$CACHE_FILE" 2 DATE_STEP=30 MONITOR_TEST_SEQUENCE_FILE="$T/ambiguous-full-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/ambiguous-full-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "ambiguous Full state is not falsely counted as on-battery time" 0 "$(field "$out" screen_on_ms)"

# A shell that prefers its own applets ignores a date or sleep found through PATH. Put poisoned ones first in PATH:
# the daemon must not run them, and must still use the fake clock it was given by path.
mkdir -p "$T/poison"
for tool in date sleep; do
  printf '#!/bin/sh\necho %s >> "%s/poison-called"\nexit 1\n' "$tool" "$T" > "$T/poison/$tool"
  chmod +x "$T/poison/$tool"
done
CACHE_FILE="$T/poisoned-path-cache"
rm -f "$T/date-count-$$" "$T/poison-count" "$T/poison-called"
printf '68|2891000|Discharging|0\n68|2890000|Discharging|0\n' > "$T/poison-sequence"
PATH="$T/poison:$PATH" run_daemon_limited "$MOD" "$CACHE_FILE" 2 MONITOR_TEST_SEQUENCE_FILE="$T/poison-sequence" MONITOR_TEST_SEQUENCE_COUNT="$T/poison-count" MONITOR_TEST_SCREEN=on
out=$(MONITOR_CACHE_FILE="$CACHE_FILE" sh "$ROOT/module/monitor-cache.sh" get)
check "daemon never runs a date or sleep found through PATH when it was given its own" no "$([ -e "$T/poison-called" ] && echo yes || echo no)"
check "daemon uses the clock it was given even when PATH holds other date/sleep programs" 1700000120000 "$(field "$out" active_time)"

# --- Two starters must never both reclaim the same abandoned start lock ---------------------------------
# Same race as in the cache: B read "stale", then A reclaimed the lock and took it with a live identity.
# B must neither delete A's lock nor launch a second collector.
CACHE_FILE="$T/race-cache"; MOD="$T/race-mod"; setup_mod "$MOD"
race_data="$T/race-data"; mkdir -p "$race_data" "$T/race-bin"
sleep 300 & race_p1=$!; sleep 300 & race_p2=$!
real_awk=$(command -v awk)
case "$real_awk" in /*) ;; *) real_awk=awk; for _d in /usr/bin /bin /usr/local/bin; do [ -x "$_d/awk" ] && { real_awk="$_d/awk"; break; }; done ;; esac
race_start2=$("$real_awk" '{ sub(/^.*\) /, ""); print $20 }' "/proc/$race_p2/stat")
race_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
race_lock="$race_data/monitor-start.lock"
mkdir "$race_lock"; printf '%s\n%s\n%s\n' "$race_p1" 1 "$race_boot" > "$race_lock/pid"
cat > "$T/race-bin/awk" <<HOOK
#!/bin/sh
out=\$("$real_awk" "\$@"); rc=\$?
case "\$*" in *"NF < 20"*)
  if [ ! -f "$T/race-hooked" ]; then : > "$T/race-hooked"
    rm -f "$race_lock/pid"; rmdir "$race_lock"; mkdir "$race_lock"
    printf '%s\n%s\n%s\n' "$race_p2" "$race_start2" "$race_boot" > "$race_lock/pid"
  fi ;; esac
printf '%s\n' "\$out"; exit \$rc
HOOK
chmod +x "$T/race-bin/awk"
env MONITOR_AWK_CMD="$T/race-bin/awk" MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$race_data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD" >"$T/race-output.log" 2>&1; race_rc=$?
check "race: the hook ran, so the race really happened (it is not a PATH lookup, which busybox ash ignores)" yes "$([ -f "$T/race-hooked" ] && echo yes || echo no)"
check "race: ensure does not take a start lock that is live now" 1 "$race_rc"
check "race: the live starter's lock is untouched" "$race_p2" "$(sed -n 1p "$race_lock/pid" 2>/dev/null)"
check "race: no second collector was launched" no "$(grep -q 'monitor-daemon: started' "$race_data/monitor.log" 2>/dev/null && echo yes || echo no)"
kill "$race_p1" "$race_p2" 2>/dev/null; wait "$race_p1" "$race_p2" 2>/dev/null

# The start lock is released only by its owner, and no guard is left after a normal stale reclaim
CACHE_FILE="$T/guard-cache"; MOD="$T/guard-mod"; setup_mod "$MOD"
guard_data="$T/guard-data"; mkdir -p "$guard_data/monitor-start.lock"
sleep 300 & guard_p=$!
printf '%s\n%s\n%s\n' "$guard_p" 1 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$guard_data/monitor-start.lock/pid"
env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$guard_data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD" >/dev/null 2>&1
check "stale start lock (reused PID) is reclaimed by ensure" 0 "$?"
check "no start-lock reclaim guard is left behind" no "$([ -e "$guard_data/monitor-start.lock.reclaim" ] && echo yes || echo no)"
check "the start lock is released after ensure" no "$([ -e "$guard_data/monitor-start.lock" ] && echo yes || echo no)"
kill "$guard_p" 2>/dev/null; wait "$guard_p" 2>/dev/null
# A start lock with a dead owner behind a guard left by a reclaimer that died must not stop the collector for ever
CACHE_FILE="$T/guard2-cache"; MOD="$T/guard2-mod"; setup_mod "$MOD"
guard2_data="$T/guard2-data"; mkdir -p "$guard2_data/monitor-start.lock" "$guard2_data/monitor-start.lock.reclaim"
sleep 0.1 & guard2_p=$!; wait "$guard2_p" 2>/dev/null
printf '%s\n%s\n%s\n' "$guard2_p" 12345 "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)" > "$guard2_data/monitor-start.lock/pid"
env MONITOR_DATE_CMD="$T/tools/date" MONITOR_SLEEP_CMD="$T/tools/sleep" MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$guard2_data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD" >/dev/null 2>&1
check "ensure clears a stale start lock that sits behind an abandoned guard" 0 "$?"
check "the abandoned start-lock guard is gone afterwards" no "$([ -e "$guard2_data/monitor-start.lock.reclaim" ] && echo yes || echo no)"
check "the start lock is released after that ensure" no "$([ -e "$guard2_data/monitor-start.lock" ] && echo yes || echo no)"


[ "$fail" -eq 0 ] && echo "all monitor-daemon tests passed" || exit 1
