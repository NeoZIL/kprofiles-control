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
  step=${DATE_STEP:-120}
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
run_daemon_limited() {
  MOD=$1; CACHE_FILE=$2; MAX=$3
  shift 3
  env PATH="$T/tools:$PATH" DATE_SEQUENCE_COUNT="$T/date-count-$$" MONITOR_CACHE_FILE="$CACHE_FILE" \
    MONITOR_DATA_DIR="$T/data-loop-$$" MONITOR_DAEMON_MAX_SAMPLES="$MAX" "$@" \
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
env PATH="$T/tools:$PATH" MONITOR_CACHE_FILE="$CACHE_FILE" MONITOR_DATA_DIR="$T/ensure-data" MONITOR_DAEMON_MAX_SAMPLES=1 sh "$MOD/monitor-daemon.sh" ensure "$MOD"
_i=0
while [ "$_i" -lt 40 ] && ! grep -q 'monitor-daemon: started' "$T/ensure-data/monitor.log" 2>/dev/null; do _i=$((_i + 1)); /bin/sleep 0.05; done
check "ensure starts the background collector when the PID file is stale" yes "$(grep -q 'monitor-daemon: started' "$T/ensure-data/monitor.log" 2>/dev/null && echo yes || echo no)"
check "ensure never kills an unrelated process whose PID was reused" yes "$(kill -0 "$unrelated_pid" 2>/dev/null && echo yes || echo no)"
kill "$unrelated_pid" 2>/dev/null || :

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

[ "$fail" -eq 0 ] && echo "all monitor-daemon tests passed" || exit 1
