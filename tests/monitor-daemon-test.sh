#!/bin/sh
# Background battery-monitor collector tests; all cache and sensor paths are temporary/read-only.
# The measurement engine is driven by scripted scenarios: a fake sleep applies the next scenario line
# (clock step, screen state, battery files) before every tick, so every duration and charge is exact.
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
mkdir -p "$T/tools"
# Scenario sleep: applies line N of $SC_DIR/scenario, then returns. Line = "DT SCREEN STATUS CURRENT COUNTER ONLINE [COMMAND]".
# DT is milliseconds to add to the fake uptime, or Rnnn to set it to nnn (a reboot/clock restart).
cat > "$T/tools/scenario-sleep" <<'SCSLEEP'
#!/bin/sh
d=$SC_DIR
idx=0; [ -r "$d/idx" ] && IFS= read -r idx < "$d/idx"
idx=$((idx + 1)); printf '%s\n' "$idx" > "$d/idx"
line=$(sed -n "${idx}p" "$d/scenario")
[ -n "$line" ] || exit 0
dt=${line%% *}; rest=${line#* }
screen=${rest%% *}; rest=${rest#* }
status=${rest%% *}; rest=${rest#* }
cur=${rest%% *}; rest=${rest#* }
ctr=${rest%% *}; rest=${rest#* }
online=${rest%% *}; cmd=
case "$rest" in *" "*) cmd=${rest#* } ;; esac
up=$(cat "$d/upms")
case "$dt" in R*) up=${dt#R} ;; *) up=$((up + dt)) ;; esac
printf '%s\n' "$up" > "$d/upms"
printf '%d.%02d 1.00\n' $((up / 1000)) $(((up % 1000) / 10)) > "$d/uptime"
printf '%s\n' "$screen" > "$d/screen"
b="$d/sys/class/power_supply/battery"
printf '%s\n' "$(printf '%s' "$status" | tr _ ' ')" > "$b/status"
if [ "$cur" = EMPTY ]; then : > "$b/current_now"; else printf '%s\n' "$cur" > "$b/current_now"; fi
if [ "$ctr" = EMPTY ]; then rm -f "$b/charge_counter"; else printf '%s\n' "$ctr" > "$b/charge_counter"; fi
[ -d "$d/sys/class/power_supply/usb" ] && printf '%s\n' "$online" > "$d/sys/class/power_supply/usb/online"
[ -z "$cmd" ] || eval "$cmd"
exit 0
SCSLEEP
chmod +x "$T/tools/scenario-sleep"

MOD="$T/module"
setup_mod "$MOD"
SC="$T/sc"; mkdir -p "$SC"
# new_sc NAME SCREEN STATUS CURRENT COUNTER ONLINE : a fresh fake phone in its initial state
new_sc() {
  d="$SC/$1"; rm -rf "$d"
  mkdir -p "$d/sys/class/power_supply/battery" "$d/sys/class/power_supply/usb" "$d/data"
  printf 'Battery\n' > "$d/sys/class/power_supply/battery/type"
  printf 'USB\n' > "$d/sys/class/power_supply/usb/type"
  printf '100000\n' > "$d/upms"; printf '100.00 1.00\n' > "$d/uptime"
  printf 'aaaa0001-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' > "$d/boot_id"
  printf '0\n' > "$d/idx"; : > "$d/scenario"
  set_state "$d" "$2" "$3" "$4" "$5" "$6"
}
set_state() {
  printf '%s\n' "$2" > "$1/screen"
  printf '%s\n' "$3" > "$1/sys/class/power_supply/battery/status"
  printf '%s\n' "$4" > "$1/sys/class/power_supply/battery/current_now"
  printf '%s\n' "$5" > "$1/sys/class/power_supply/battery/charge_counter"
  [ -d "$1/sys/class/power_supply/usb" ] && printf '%s\n' "$6" > "$1/sys/class/power_supply/usb/online"
}
rep() { _n=$1; shift; _i=0; while [ "$_i" -lt "$_n" ]; do printf '%s\n' "$*"; _i=$((_i + 1)); done; }
# sc_run NAME TICKS [ENV=VALUE...] : run the collector for TICKS samples against the scenario in $SC/NAME/scenario
sc_run() {
  d="$SC/$1"; n=$2; shift 2
  printf '0\n' > "$d/idx"
  env MONITOR_DATA_DIR="$d/data" MONITOR_CACHE_FILE="$d/data/monitor-cache" MONITOR_SYS_ROOT="$d/sys" \
    MONITOR_UPTIME_FILE="$d/uptime" MONITOR_SCREEN_STATE_FILE="$d/screen" MONITOR_SLEEP_CMD="$T/tools/scenario-sleep" \
    SC_DIR="$d" MONITOR_DAEMON_MAX_SAMPLES="$n" MONITOR_BOOT_ID_FILE="$d/boot_id" MONITOR_LOGCAT_CMD="$d/no-logcat" \
    MONITOR_DATE_CMD="$T/tools/date" DATE_SEQUENCE_COUNT="$d/date-count" DATE_STEP=1 "$@" \
    sh "$MOD/monitor-daemon.sh" run "$MOD" > "$d/out.log" 2>&1
}
cache_get() { MONITOR_CACHE_FILE="$SC/$1/data/monitor-cache" sh "$ROOT/module/monitor-cache.sh" get; }
setup_fast_tools

echo '--- steady screen-on drain: exact charge, time and average ---'
new_sc steady on Discharging -300000 3000000 0
rep 60 '1000 on Discharging -300000 3000000 0' > "$SC/steady/scenario"
sc_run steady 61
out=$(cache_get steady)
check "screen-on time is the sum of observed intervals" 60000 "$(field "$out" active_ms)"
check "active charge is current x time (300 mA for 60 s, in uA*ms)" 18000000000 "$(field "$out" active_charge)"
check "no screen-off time is invented" 0 "$(field "$out" idle_ms)"
check "no unmeasured time when every reading is valid" 0 "$(field "$out" active_unmeasured)"
check "the first discharge cycle is numbered 1" 1 "$(field "$out" cycle_id)"
check "the cycle is open while discharging" discharging "$(field "$out" cycle_state)"
check "a clean measurement is not marked provisional" 0 "$(field "$out" active_prov)"
check "the rolling recent average of constant current equals it" 300000 "$(field "$out" active_recent_ua)"
check "the rolling window holds all 60 s while under 5 min" 60000 "$(field "$out" active_recent_ms)"

echo '--- the 10 s rule ---'
new_sc short on Discharging -300000 3000000 0
{ rep 5 '1000 on Discharging -300000 3000000 0'; rep 8 '1000 off Discharging -30000 3000000 0'; rep 5 '1000 on Discharging -300000 3000000 0'; } > "$SC/short/scenario"
sc_run short 19
out=$(cache_get short)
check "a screen-off interval under 10 s adds no Screen-Off Time" 0 "$(field "$out" idle_ms)"
check "a screen-off interval under 10 s adds no idle charge" 0 "$(field "$out" idle_charge)"
check "the discarded short interval is not credited to screen-on time either" 10000 "$(field "$out" active_ms)"
check "screen-on charge excludes the discarded interval" 3000000000 "$(field "$out" active_charge)"

new_sc long on Discharging -300000 3000000 0
{ rep 5 '1000 on Discharging -300000 3000000 0'; rep 15 '1000 off Discharging -30000 3000000 0'; rep 3 '1000 on Discharging -300000 3000000 0'; } > "$SC/long/scenario"
sc_run long 24
out=$(cache_get long)
check "a confirmed screen-off interval counts from its ORIGINAL timestamp (all 15 s, not 5 s)" 15000 "$(field "$out" idle_ms)"
check "idle charge covers the whole confirmed interval, including the buffered first 10 s" 450000000 "$(field "$out" idle_charge)"
check "screen-on time stops when the screen turns off and resumes after" 8000 "$(field "$out" active_ms)"
check "screen-on charge is only screen-on current" 2400000000 "$(field "$out" active_charge)"
check "screen-on and confirmed screen-off time do not overlap (sum equals observed time)" 23000 "$(( $(field "$out" active_ms) + $(field "$out" idle_ms) ))"

new_sc exact10 on Discharging -300000 3000000 0
{ rep 2 '1000 on Discharging -300000 3000000 0'; rep 11 '1000 off Discharging -30000 3000000 0'; rep 2 '1000 on Discharging -300000 3000000 0'; } > "$SC/exact10/scenario"
sc_run exact10 16
out=$(cache_get exact10)
check "a screen-off interval of exactly 10 s is confirmed" 11000 "$(field "$out" idle_ms)"

echo '--- acceptance matrix: twenty 4-minute screen-off intervals ---'
new_sc twenty on Discharging -300000 3000000 0
: > "$SC/twenty/scenario"
_c=0
while [ "$_c" -lt 20 ]; do
  { printf '1000 off Discharging -30000 3000000 0\n'; rep 3 '60000 off Discharging -30000 3000000 0'; printf '60000 on Discharging -300000 3000000 0\n'; } >> "$SC/twenty/scenario"
  _c=$((_c + 1))
done
sc_run twenty 101 MONITOR_GAP_MS=600000
out=$(cache_get twenty)
check "twenty qualifying 4-minute intervals add 80 minutes of confirmed Screen-Off Time" 4800000 "$(field "$out" idle_ms)"
check "idle charge is the sum over all twenty intervals (30 mA for 80 min)" 144000000000 "$(field "$out" idle_charge)"
check "the idle rolling history holds only its latest 5 eligible minutes" 300000 "$(field "$out" idle_recent_ms)"
check "rolling eviction left the cycle's idle total at the full 80 minutes" 80 "$(( $(field "$out" idle_ms) / 60000 ))"
check "the recent idle estimate is the average over those 5 minutes" 30000 "$(field "$out" idle_recent_ua)"
check "each separate OFF interval started its own pending buffer (not merged)" 20000 "$(field "$out" active_ms)"

echo '--- unequal sample intervals are time-weighted ---'
new_sc uneq on Discharging -100000 3000000 0
{ printf '1000 on Discharging -200000 3000000 0\n'; printf '3000 on Discharging -400000 3000000 0\n'; } > "$SC/uneq/scenario"
sc_run uneq 3 MONITOR_SMOOTH_MS=1
check "charge over a 1 s and a 3 s interval is weighted by duration" 1049498500 "$(field "$(cache_get uneq)" active_charge)"

echo '--- manual reset while a screen-off interval is pending ---'
new_sc rpend on Discharging -300000 3000000 0
{ rep 3 '1000 on Discharging -300000 3000000 0'; rep 6 '1000 off Discharging -30000 3000000 0'; printf '1000 off Discharging -30000 3000000 0 MONITOR_CACHE_FILE="%s/data/monitor-cache" sh "%s/module/monitor-cache.sh" reset-data\n' "$SC/rpend" "$ROOT"; rep 11 '1000 off Discharging -30000 3000000 0'; printf '1000 on Discharging -300000 3000000 0\n'; } > "$SC/rpend/scenario"
sc_run rpend 23
out=$(cache_get rpend)
check "after a reset the old pending buffer and anchors cannot leak into the new record (only the 12 s since the reset)" 12000 "$(field "$out" idle_ms)"
check "nothing measured before the reset survives it" 0 "$(field "$out" active_ms)"

echo '--- restart does not double-count a screen-off interval ---'
new_sc rsoff on Discharging -300000 3000000 0
{ rep 2 '1000 on Discharging -300000 3000000 0'; rep 15 '1000 off Discharging -30000 3000000 0'; } > "$SC/rsoff/scenario"
sc_run rsoff 18
out=$(cache_get rsoff)
check "first run confirms and saves the screen-off time" 14000 "$(field "$out" idle_ms)"
printf '9000000\n' > "$SC/rsoff/upms"; printf '9000.00 1.00\n' > "$SC/rsoff/uptime"
set_state "$SC/rsoff" off Discharging -30000 3000000 0
rep 12 '1000 off Discharging -30000 3000000 0' > "$SC/rsoff/scenario"
sc_run rsoff 13
out=$(cache_get rsoff)
check "after a restart the saved total plus only the newly observed time is counted (14 s + 12 s)" 26000 "$(field "$out" idle_ms)"

echo '--- trapezoid integration and 10 s smoothing ---'
new_sc trap on Discharging -100000 3000000 0
printf '1000 on Discharging -300000 3000000 0\n' > "$SC/trap/scenario"
sc_run trap 2 MONITOR_SMOOTH_MS=1
out=$(cache_get trap)
check "charge over a 1 s interval is the trapezoid of the two readings" 199900000 "$(field "$out" active_charge)"
sc_run trap 1
new_sc smooth on Discharging -100000 3000000 0
printf '1000 on Discharging -300000 3000000 0\n' > "$SC/smooth/scenario"
sc_run smooth 2
out=$(cache_get smooth)
check "default smoothing damps a sudden current step (about a 10 s horizon)" 109000000 "$(field "$out" active_charge)"
new_sc sign on Discharging 300000 3000000 0
rep 4 '1000 on Discharging 300000 3000000 0' > "$SC/sign/scenario"
sc_run sign 5
check "positive and negative current_now give the same discharge magnitude" 1200000000 "$(field "$(cache_get sign)" active_charge)"

echo '--- invalid readings are unmeasured, never zero ---'
new_sc bad on Discharging -300000 3000000 0
rep 4 '1000 on Discharging EMPTY 3000000 0' > "$SC/bad/scenario"
sc_run bad 5
out=$(cache_get bad)
check "time with no valid current still counts as screen-on time" 4000 "$(field "$out" active_ms)"
check "that time is recorded as unmeasured" 4000 "$(field "$out" active_unmeasured)"
check "no charge is invented for unmeasured time" 0 "$(field "$out" active_charge)"
new_sc zero on Discharging 0 3000000 0
rep 3 '1000 on Discharging 0 3000000 0' > "$SC/zero/scenario"
sc_run zero 4
check "a constant zero current_now is treated as unavailable, not measured" 3000 "$(field "$(cache_get zero)" active_unmeasured)"

echo '--- cycles: charging closes the cycle, unplugging starts a new one ---'
new_sc cyc on Discharging -300000 3000000 0
{ rep 5 '1000 on Discharging -300000 3000000 0'; rep 3 '1000 on Charging 1500000 3000100 1'; } > "$SC/cyc/scenario"
sc_run cyc 9
out=$(cache_get cyc)
check "plugging in ends the discharge cycle" charging "$(field "$out" cycle_state)"
check "the finished cycle's totals stay visible while charging" 5000 "$(field "$out" active_ms)"
check "charging time and current are not added to the cycle" 1500000000 "$(field "$out" active_charge)"
check "no new cycle starts while charging" 1 "$(field "$out" cycle_id)"
{ rep 2 '1000 off Full 0 3000100 1'; rep 2 '1000 on Full 1000 3000100 1'; } > "$SC/cyc/scenario"
set_state "$SC/cyc" on Charging 1500000 3000100 1
sc_run cyc 5
out=$(cache_get cyc)
check "reaching 100% (Full) on the charger does not start a new cycle" 1 "$(field "$out" cycle_id)"
check "Full on the charger keeps the cycle closed" charging "$(field "$out" cycle_state)"
check "Full on the charger leaves the totals untouched" 5000 "$(field "$out" active_ms)"
{ rep 4 '1000 on Discharging -300000 3000000 0'; } > "$SC/cyc/scenario"
set_state "$SC/cyc" on Full 1000 3000100 1
sc_run cyc 5
out=$(cache_get cyc)
check "unplugging starts a new cycle" 2 "$(field "$out" cycle_id)"
check "the new cycle is discharging" discharging "$(field "$out" cycle_state)"
check "the new cycle starts from zero (only post-unplug time)" 3000 "$(field "$out" active_ms)"
check "the new cycle's screen-off total starts from zero" 0 "$(field "$out" idle_ms)"

new_sc nonline on Discharging -300000 3000000 0
rm -rf "$SC/nonline/sys/class/power_supply/usb"
{ rep 3 '1000 on Discharging -300000 3000000 0'; rep 3 '1000 on Full 1000 3000100 0'; } > "$SC/nonline/scenario"
sc_run nonline 7
out=$(cache_get nonline)
check "without any charger-online node, Full still means plugged in" charging "$(field "$out" cycle_state)"
{ rep 2 '1000 on Full 1000 3000100 0'; rep 3 '1000 on Discharging -300000 3000000 0'; } > "$SC/nonline/scenario"
set_state "$SC/nonline" on Full 1000 3000100 0
sc_run nonline 6
check "Full without a charger-online node does not reset the cycle before the real unplug" 2 "$(field "$(cache_get nonline)" cycle_id)"
new_sc notchg on Discharging -300000 3000000 0
rm -rf "$SC/notchg/sys/class/power_supply/usb"
{ rep 3 '1000 on Discharging -300000 3000000 0'; rep 4 '1000 on Not_charging 0 3000000 0'; } > "$SC/notchg/scenario"
sc_run notchg 8
out=$(cache_get notchg)
check "a Not-charging battery with no charger-online node is treated as plugged in" charging "$(field "$out" cycle_state)"
check "Not charging adds nothing to the closed cycle" 3000 "$(field "$out" active_ms)"
new_sc notchg2 on Discharging -300000 3000000 0
{ rep 3 '1000 on Not_charging -300000 3000000 0'; } > "$SC/notchg2/scenario"
sc_run notchg2 4
check "Not charging with the charger reported offline is still on battery" 3000 "$(field "$(cache_get notchg2)" active_ms)"

echo '--- gaps: counter-based, provisional, or discarded ---'
new_sc gap on Discharging -300000 3000000 0
printf '120000 on Discharging -300000 2999900 0\n' > "$SC/gap/scenario"
sc_run gap 2
out=$(cache_get gap)
check "a long gap is still counted as time" 120000 "$(field "$out" active_ms)"
check "a long gap's charge comes from the charge counter (100 uAh)" 360000000 "$(field "$out" active_charge)"
check "a counter-based gap is marked provisional" 1 "$(field "$out" active_prov)"
new_sc gapi on Discharging -300000 EMPTY 0
printf '120000 on Discharging -300000 EMPTY 0\n' > "$SC/gapi/scenario"
sc_run gapi 2
out=$(cache_get gapi)
check "without a counter a long gap is interpolated" 36000000000 "$(field "$out" active_charge)"
check "an interpolated long gap is marked provisional" 1 "$(field "$out" active_prov)"
new_sc gapmax on Discharging -300000 3000000 0
{ printf '50000000 on Discharging -300000 3000000 0\n'; rep 2 '1000 on Discharging -300000 3000000 0'; } > "$SC/gapmax/scenario"
sc_run gapmax 4
out=$(cache_get gapmax)
check "a gap beyond 12 h is discarded, nothing is credited for it" 2000 "$(field "$out" active_ms)"

echo '--- Android screen events give the real transition time after a sleep gap ---'
cat > "$T/tools/fake-logcat" <<'LOGCAT'
#!/bin/sh
printf '%s\n' '1699999000.100  1000  1234  1250 I power_screen_state: [0,3,0,0]'
printf '%s\n' '1699999980.123  1000  1234  1250 I power_screen_state: [1,0,0,0]'
LOGCAT
chmod +x "$T/tools/fake-logcat"
cat > "$T/tools/fixed-date" <<'FDATE'
#!/bin/sh
[ "$1" = +%s ] && { echo 1700000000; exit 0; }
exec /bin/date "$@"
FDATE
chmod +x "$T/tools/fixed-date"
new_sc ev off Discharging -30000 EMPTY 0
printf '60000 on Discharging -300000 EMPTY 0\n' > "$SC/ev/scenario"
sc_run ev 2 MONITOR_LOGCAT_CMD="$T/tools/fake-logcat" MONITOR_DATE_CMD="$T/tools/fixed-date"
out=$(cache_get ev)
check "the screen-on event time splits the sleep gap (off until 20.377 s before the sample)" 39623 "$(field "$out" idle_ms)"
check "the time after the real wake-up is screen-on time" 20377 "$(field "$out" active_ms)"
check "screen-off charge in the gap uses the screen-off reading" 1188690000 "$(field "$out" idle_charge)"
check "screen-on charge in the gap uses the screen-on reading" 6113100000 "$(field "$out" active_charge)"
new_sc ev2 off Discharging -30000 EMPTY 0
printf '60000 on Discharging -300000 EMPTY 0\n' > "$SC/ev2/scenario"
sc_run ev2 2
out=$(cache_get ev2)
check "without an event log the sample time is the transition time" 60000 "$(field "$out" idle_ms)"
check "without an event log nothing is credited to the new state before the sample" 0 "$(field "$out" active_ms)"

echo '--- rolling window is bounded by time and never touches cycle totals ---'
new_sc roll on Discharging -100000 3000000 0
{ rep 30 '1000 on Discharging -100000 3000000 0'; rep 30 '1000 on Discharging -400000 3000000 0'; } > "$SC/roll/scenario"
sc_run roll 61 MONITOR_ROLL_MS=20000 MONITOR_SMOOTH_MS=1
out=$(cache_get roll)
check "the rolling window never exceeds its configured length" 20000 "$(field "$out" active_recent_ms)"
check "cycle totals still cover the whole 60 s" 60000 "$(field "$out" active_ms)"
recent=$(field "$out" active_recent_ua)
check "the recent estimate follows only the latest data" yes "$([ "$recent" -gt 395000 ] && [ "$recent" -le 400000 ] && echo yes || echo no)"
total=$(field "$out" active_charge)
check "cycle charge is the full-run integral, not the recent window" yes "$([ "$total" -gt 14000000000 ] && [ "$total" -lt 14900000000 ] && echo yes || echo no)"
new_sc roll5 on Discharging -100000 3000000 0
rep 330 '1000 on Discharging -100000 3000000 0' > "$SC/roll5/scenario"
sc_run roll5 331
out=$(cache_get roll5)
check "the default rolling window is 5 minutes of eligible time" 300000 "$(field "$out" active_recent_ms)"
check "the cycle total keeps counting past the rolling window" 330000 "$(field "$out" active_ms)"

echo '--- disabled monitoring, unknown screen, resets ---'
new_sc off1 on Discharging -300000 3000000 0
rep 5 '1000 on Discharging -300000 3000000 0' > "$SC/off1/scenario"
MONITOR_CACHE_FILE="$SC/off1/data/monitor-cache" sh "$ROOT/module/monitor-cache.sh" set-enabled 0
sc_run off1 6
check "nothing is counted while monitoring is switched off" 0 "$(field "$(cache_get off1)" active_ms)"
new_sc unk unknown Discharging -300000 3000000 0
rep 4 '1000 unknown Discharging -300000 3000000 0' > "$SC/unk/scenario"
sc_run unk 5
check "an unreadable screen state counts as neither screen-on nor screen-off" 0 "$(( $(field "$(cache_get unk)" active_ms) + $(field "$(cache_get unk)" idle_ms) ))"

new_sc rst on Discharging -300000 3000000 0
{ rep 9 '1000 on Discharging -300000 3000000 0'; printf '1000 on Discharging -300000 3000000 0 MONITOR_CACHE_FILE="%s/data/monitor-cache" sh "%s/module/monitor-cache.sh" reset-data\n' "$SC/rst" "$ROOT"; rep 4 '1000 on Discharging -300000 3000000 0'; } > "$SC/rst/scenario"
sc_run rst 15
out=$(cache_get rst)
check "a manual reset advances the generation" 1 "$(field "$out" generation)"
check "after a reset the collector measures from zero (no pre-reset totals written back)" 4000 "$(field "$out" active_ms)"
check "a reset does not start a new cycle" 1 "$(field "$out" cycle_id)"

new_sc rsot on Discharging -300000 3000000 0
{ rep 3 '1000 on Discharging -300000 3000000 0'; rep 15 '1000 off Discharging -30000 3000000 0'; rep 2 '1000 on Discharging -300000 3000000 0'; printf '1000 on Discharging -300000 3000000 0 MONITOR_CACHE_FILE="%s/data/monitor-cache" sh "%s/module/monitor-cache.sh" reset-screen-on-time\n' "$SC/rsot" "$ROOT"; rep 3 '1000 on Discharging -300000 3000000 0'; } > "$SC/rsot/scenario"
sc_run rsot 25
out=$(cache_get rsot)
check "resetting screen-on time keeps the confirmed screen-off total" 15000 "$(field "$out" idle_ms)"
check "resetting screen-on time restarts only the active side" 3000 "$(field "$out" active_ms)"

echo '--- restart and reboot recovery ---'
new_sc rs on Discharging -300000 3000000 0
rep 19 '1000 on Discharging -300000 3000000 0' > "$SC/rs/scenario"
sc_run rs 20
out=$(cache_get rs)
check "first run totals" 19000 "$(field "$out" active_ms)"
printf '5000000\n' > "$SC/rs/upms"; printf '5000.00 1.00\n' > "$SC/rs/uptime"
rep 9 '1000 on Discharging -300000 3000000 0' > "$SC/rs/scenario"
sc_run rs 10
out=$(cache_get rs)
check "a restarted collector continues the same cycle" 1 "$(field "$out" cycle_id)"
check "the time the collector was not running is not counted" 28000 "$(field "$out" active_ms)"
printf 'bbbb0002-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n' > "$SC/rs/boot_id"; printf '2000\n' > "$SC/rs/upms"; printf '2.00 1.00\n' > "$SC/rs/uptime"
rep 4 '1000 on Discharging -300000 3000000 0' > "$SC/rs/scenario"
sc_run rs 5
out=$(cache_get rs)
check "after a reboot the cycle continues with the new boot recorded" bbbb0002-bbbb-bbbb-bbbb-bbbbbbbbbbbb "$(field "$out" cycle_boot)"
check "after a reboot nothing is subtracted across the two clocks" 32000 "$(field "$out" active_ms)"

new_sc clk on Discharging -300000 3000000 0
{ rep 5 '1000 on Discharging -300000 3000000 0'; printf 'R5000 on Discharging -300000 3000000 0\n'; rep 4 '1000 on Discharging -300000 3000000 0'; } > "$SC/clk/scenario"
sc_run clk 11
check "a monotonic clock that restarts mid-run never produces negative or double-counted time" 9000 "$(field "$(cache_get clk)" active_ms)"

echo '--- cache write refused after a reset is picked up, not overwritten ---'
new_sc stale on Discharging -300000 3000000 0
{ rep 3 '1000 on Discharging -300000 3000000 0'; printf '1000 on Discharging -300000 3000000 0 MONITOR_CACHE_FILE="%s/data/monitor-cache" sh "%s/module/monitor-cache.sh" reset-data\n' "$SC/stale" "$ROOT"; } > "$SC/stale/scenario"
sc_run stale 5 MONITOR_PERSIST_MS=1
check "totals are zeroed by the reset and not restored by a late write" 0 "$([ "$(field "$(cache_get stale)" active_ms)" -le 1000 ] && echo 0 || echo 1)"

echo '--- the collector only reads: poisoned date/sleep in PATH are never used ---'
mkdir -p "$T/poison"
for tool in date sleep; do
  printf '#!/bin/sh\necho %s >> "%s/poison-called"\nexit 1\n' "$tool" "$T" > "$T/poison/$tool"
  chmod +x "$T/poison/$tool"
done
new_sc pz on Discharging -300000 3000000 0
rep 5 '1000 on Discharging -300000 3000000 0' > "$SC/pz/scenario"
rm -f "$T/poison-called"
PATH="$T/poison:$PATH" sc_run pz 6
check "daemon never runs a date or sleep found through PATH when it was given its own" no "$([ -e "$T/poison-called" ] && echo yes || echo no)"
check "the run still produced its measurements" 5000 "$(field "$(cache_get pz)" active_ms)"

echo '--- probe reports how fresh current_now is ---'
new_sc pr on Discharging -300000 3000000 0
{ printf '1000 on Discharging -300000 3000000 0\n'; printf '1000 on Discharging -310000 3000000 0\n'; printf '1000 on Discharging -310000 3000000 0\n'; } > "$SC/pr/scenario"
out=$(env MONITOR_SYS_ROOT="$SC/pr/sys" MONITOR_SLEEP_CMD="$T/tools/scenario-sleep" SC_DIR="$SC/pr" sh "$MOD/monitor-daemon.sh" probe "$MOD" 4)
check "probe counts samples and distinct changes" "samples=4 valid=4 changes=1" "$out"

echo '--- process management: ensure / stop / start locks ---'

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

# --- Two starters must never both reclaim the same abandoned start lock ---------------------------------
# Same race as in the cache: B read "stale", then A reclaimed the lock and took it with a live identity.
# B must neither delete A's lock nor launch a second collector.
CACHE_FILE="$T/race-cache"; MOD="$T/race-mod"; setup_mod "$MOD"
race_data="$T/race-data"; mkdir -p "$race_data" "$T/race-bin"
sleep 300 & race_p1=$!; sleep 300 & race_p2=$!
real_awk=$(command -v awk)
case "$real_awk" in /*) ;; *) real_awk="awk"; for _d in /usr/bin /bin /usr/local/bin; do [ -x "$_d/awk" ] && { real_awk="$_d/awk"; break; }; done ;; esac
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
