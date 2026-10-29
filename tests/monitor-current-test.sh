#!/bin/sh
# Deterministic unit tests for active/idle battery current math and validation.
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../module/monitor-current.sh" || exit 1
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }
reject() { if "$@" >/dev/null 2>&1; then echo "FAIL $1 was accepted"; fail=1; else echo "ok   $1 rejected"; fi; }

check "negative kernel current normalizes to a positive discharge magnitude" 400000 "$(monitor_normalize_current_ua -400000)"
check "positive kernel current stays positive" 80000 "$(monitor_normalize_current_ua 80000)"
reject "non-integer current" monitor_valid_current_ua 1.2
reject "malformed signed current" monitor_valid_current_ua 4-0
reject "current beyond the physical validation bound" monitor_valid_current_ua 30000000
reject "empty current" monitor_valid_current_ua ''

# uA × milliseconds / 3,600,000 = uAh. One-second 400 mA endpoints give 111.111111 uAh.
check "trapezoidal integration accepts unequal endpoint values" 138.888889 "$(monitor_integrate_current_uah -400000 -600000 1000)"
check "trapezoidal integration accepts zero current" 0.000000 "$(monitor_integrate_current_uah 0 0 1000)"
reject "zero-duration current interval" monitor_integrate_current_uah 400000 400000 0
reject "negative elapsed interval" monitor_integrate_current_uah 400000 400000 -1000
reject "extreme integration duration" monitor_integrate_current_uah 400000 400000 99999999999

check "sampled charge and time derive 400 mA" 400.000 "$(monitor_average_current_ma 111.111111 1000)"
check "independent idle sample derives 80 mA" 80.000 "$(monitor_average_current_ma 22.222222 1000)"
reject "average above 20 A is refused" monitor_average_current_ma 10000 1000
reject "negative integrated charge is refused" monitor_average_current_ma -10 1000

check "plausible charge-counter loss is returned separately" 1000.000000 "$(monitor_counter_loss_uah 3000000 2999000 10000 4425000)"
reject "rising charge counter is treated as reset/charging" monitor_counter_loss_uah 2999000 3000000 10000 4425000
reject "implausible charge-counter drop is rejected" monitor_counter_loss_uah 3000000 2000000 1000 4425000
reject "invalid capacity is rejected by counter fallback" monitor_counter_loss_uah 3000000 2999000 10000 xyz

check "decimal addition keeps precision to six places" 133.333333 "$(monitor_add_decimal 111.111111 22.222222)"
reject "decimal addition refuses shell metacharacters" monitor_add_decimal 10 '1;touch /tmp/nope'
[ "$fail" -eq 0 ] && echo "all monitor-current tests passed" || exit 1
