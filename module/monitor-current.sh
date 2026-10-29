#!/system/bin/sh
# Pure helpers for time-weighted battery-current accounting.
# All current and charge-counter inputs use Linux power_supply units: uA and uAh.

monitor_valid_current_ua() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$1" != "-" ] || return 1
  awk -v n="$1" 'BEGIN { if (n ~ /^-?[0-9]+$/ && n+0 >= -20000000 && n+0 <= 20000000) exit 0; exit 1 }'
}

monitor_normalize_current_ua() {
  monitor_valid_current_ua "$1" || return 1
  awk -v n="$1" 'BEGIN { if (n < 0) n = -n; printf "%.0f\n", n }'
}

monitor_valid_counter_uah() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ] || return 1
  awk -v n="$1" 'BEGIN { if (n ~ /^[0-9]+$/ && n+0 > 0 && n+0 <= 100000000) exit 0; exit 1 }'
}

monitor_valid_elapsed_ms() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ] && [ "$1" -gt 0 ] 2>/dev/null
}

# Output consumed charge in uAh using the trapezoidal average of adjacent samples.
# The caller must enforce its state-specific maximum gap before invoking this function.
monitor_integrate_current_uah() {
  [ "$#" -eq 3 ] || return 1
  _mc_prev=$1; _mc_curr=$2; _mc_ms=$3
  monitor_valid_current_ua "$_mc_prev" && monitor_valid_current_ua "$_mc_curr" && monitor_valid_elapsed_ms "$_mc_ms" || return 1
  _mc_prev=$(monitor_normalize_current_ua "$_mc_prev") || return 1
  _mc_curr=$(monitor_normalize_current_ua "$_mc_curr") || return 1
  awk -v a="$_mc_prev" -v b="$_mc_curr" -v ms="$_mc_ms" 'BEGIN { q=((a+b)/2)*ms/3600000; if (q < 0 || q > 100000000) exit 1; printf "%.6f\n", q }'
}

# Output charge-counter loss in uAh if plausible. A rising counter is treated as a
# charging/reset event, never as negative discharge. The 20 A bound plus a small
# quantisation margin rejects obvious counter resets while allowing coarse counters.
monitor_counter_loss_uah() {
  [ "$#" -eq 4 ] || return 1
  _mc_start=$1; _mc_end=$2; _mc_ms=$3; _mc_cap=${4:-}
  monitor_valid_counter_uah "$_mc_start" && monitor_valid_counter_uah "$_mc_end" && monitor_valid_elapsed_ms "$_mc_ms" || return 1
  [ -z "$_mc_cap" ] || monitor_valid_counter_uah "$_mc_cap" || return 1
  awk -v a="$_mc_start" -v b="$_mc_end" -v ms="$_mc_ms" -v cap="${_mc_cap:-0}" '
    BEGIN {
      d=a-b
      # A counter that rises may have been reset or observed during charging.
      if (d <= 0) exit 1
      # Maximum physically plausible loss at 20 A, plus 2 mAh for counter quantisation.
      max_loss=(20000000*ms/3600000)+2000
      if (d > max_loss || d > 100000000) exit 1
      if (cap > 0 && d > cap*1.25) exit 1
      printf "%.6f\n", d
    }'
}

monitor_average_current_ma() {
  [ "$#" -eq 2 ] || return 1
  _mc_charge=$1; _mc_ms=$2
  case "$_mc_charge" in ''|*[!0-9.]*) return 1 ;; esac
  monitor_valid_elapsed_ms "$_mc_ms" || return 1
  awk -v q="$_mc_charge" -v ms="$_mc_ms" 'BEGIN { if (q !~ /^[0-9]+([.][0-9]+)?$/ || q+0 < 0 || ms <= 0) exit 1; a=q*3600/ms; if (a < 0 || a > 20000.001) exit 1; printf "%.3f\n", a }'
}

monitor_add_decimal() {
  [ "$#" -eq 2 ] || return 1
  case "$1:$2" in *[!0-9.:]*) return 1 ;; esac
  awk -v a="$1" -v b="$2" 'BEGIN { if (a !~ /^[0-9]+([.][0-9]+)?$/ || b !~ /^[0-9]+([.][0-9]+)?$/) exit 1; s=a+b; if (s < 0 || s > 1000000000000) exit 1; printf "%.6f\n", s }'
}
