#!/bin/sh
# Off-device test of build.sh: the zip, the update manifest and the release notes.
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi; }

# Work on a scratch copy so the real dist/ is never touched.
mk() {
  rm -rf "$T/r"; mkdir -p "$T/r/module"
  cp "$HERE/../build.sh" "$T/r/"; cp "$HERE/../module/"* "$T/r/module/" 2>/dev/null
  printf '%s' "$1" > "$T/r/module/module.prop"
  printf '%s' "$2" > "$T/r/CHANGELOG.md"
}
PROP='id=x
name=X
version=v2.3.4
versionCode=42
updateJson=https://example.invalid/update.json
'
LOG='# Changelog

## v2.3.4
- newest thing
- another line

## v2.3.3
- older thing
'
mk "$PROP" "$LOG"
( cd "$T/r" && REPO=me/mod sh build.sh >/dev/null 2>&1 ); check "build succeeds" 0 $?
zip_name=
zip_count=0
for f in "$T"/r/dist/*.zip; do
  [ -f "$f" ] || continue
  zip_count=$((zip_count + 1))
  zip_name=${f##*/}
done
check "zip name"        "Kprofiles-Control-v2.3.4.zip" "$zip_name"
check "exactly one ZIP" 1 "$zip_count"
check "manifest version" "v2.3.4" "$(sed -n 's/.*"version": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "manifest code"    "42" "$(sed -n 's/.*"versionCode": \([0-9]*\),/\1/p' "$T/r/dist/update.json")"
check "manifest zipUrl"  "https://github.com/me/mod/releases/download/v2.3.4/Kprofiles-Control-v2.3.4.zip" \
  "$(sed -n 's/.*"zipUrl": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "manifest changelog" "https://github.com/me/mod/releases/download/v2.3.4/changelog.md" \
  "$(sed -n 's/.*"changelog": "\(.*\)"/\1/p' "$T/r/dist/update.json")"
check "notes are this version only" "- newest thing
- another line" "$(cat "$T/r/dist/changelog.md")"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d["versionCode"],int)' "$T/r/dist/update.json" 2>/dev/null
  check "manifest is valid JSON" 0 $?
fi
check "zip has module.prop" 1 "$(unzip -l "$T/r/dist/"*.zip | grep -c ' module.prop$')"
check "zip includes the universal monitoring helper" 1 "$(unzip -l "$T/r/dist/"*.zip | grep -c ' monitor.sh$')"
check "zip includes the controller switch engine" 1 "$(unzip -l "$T/r/dist/"*.zip | grep -c ' control.sh$')"
check "zip includes the shared controller state library" 1 "$(unzip -l "$T/r/dist/"*.zip | grep -c ' control-lib.sh$')"

# Windows line endings in module.prop and CHANGELOG.md must not leak into the output.
mk "$(printf '%s' "$PROP" | sed 's/$/\r/')
" "$(printf '%s' "$LOG" | sed 's/$/\r/')
"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "CRLF inputs build" 0 $?
check "CRLF: version clean" "v2.3.4" "$(sed -n 's/.*"version": "\(.*\)",/\1/p' "$T/r/dist/update.json")"
check "CRLF: no CR in notes" 0 "$(grep -c "$(printf '\r')" "$T/r/dist/changelog.md")"

# Refusals: a build that would publish something broken must fail and leave no manifest.
mk "$PROP" "# Changelog

## v9.9.9
- other
"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "missing changelog section fails" 1 $?
json_count=0
for f in "$T"/r/dist/*.json; do
  [ -f "$f" ] || continue
  json_count=$((json_count + 1))
done
check "no manifest left behind" 0 "$json_count"
# Every malformed versionCode / version must be refused, and must leave no manifest behind.
refuse() { # $1 label  $2 sed expression applied to PROP
  mk "$(printf '%s' "$PROP" | sed "$2")" "$LOG"
  ( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "$1 fails" 1 $?
  json_count=0
  for f in "$T"/r/dist/*.json; do
    [ -f "$f" ] || continue
    json_count=$((json_count + 1))
  done
  check "$1: no manifest" 0 "$json_count"
}
refuse "versionCode 4x"            's/^versionCode=42/versionCode=4x/'
refuse "versionCode leading zero"  's/^versionCode=42/versionCode=0042/'
refuse "versionCode zero"          's/^versionCode=42/versionCode=0/'
refuse "versionCode empty"         's/^versionCode=42/versionCode=/'
refuse "versionCode negative"      's/^versionCode=42/versionCode=-5/'
refuse "versionCode too large"     's/^versionCode=42/versionCode=2147483648/'
refuse "versionCode 20 digits"     's/^versionCode=42/versionCode=99999999999999999999/'
refuse "version quote"             's/^version=v2.3.4/version=v2.3.4"x/'
refuse "version double dot"        's/^version=v2.3.4/version=v2..4/'
refuse "version trailing dot"      's/^version=v2.3.4/version=v2.3.4./'
refuse "version inner v"           's/^version=v2.3.4/version=v2.3v4/'
refuse "version trailing v"        's/^version=v2.3.4/version=v2.3.4v/'
refuse "version double v"          's/^version=v2.3.4/version=vv2.3.4/'
refuse "version two parts"         's/^version=v2.3.4/version=v2.3/'
refuse "version four parts"        's/^version=v2.3.4/version=v2.3.4.5/'
refuse "version suffix"            's/^version=v2.3.4/version=v2.3.4-rc1/'
refuse "version no v"              's/^version=v2.3.4/version=2.3.4/'
# The top of the allowed range is accepted and still valid JSON.
mk "$(printf '%s' "$PROP" | sed 's/^versionCode=42/versionCode=2147483647/')" "$LOG"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "versionCode max builds" 0 $?
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["versionCode"]==2147483647' "$T/r/dist/update.json" 2>/dev/null
  check "versionCode max is valid JSON" 0 $?
fi

# Old versioned zips left in dist/ by earlier local builds are removed, so dist/*.zip is only this build.
mk "$PROP" "$LOG"; mkdir -p "$T/r/dist"
: > "$T/r/dist/Kprofiles-Control-v1.0.0.zip"; : > "$T/r/dist/Kprofiles-Control-v2.3.3.zip"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); check "rebuild with stale zips succeeds" 0 $?
zip_count=0; zip_name=
for f in "$T"/r/dist/*.zip; do [ -f "$f" ] || continue; zip_count=$((zip_count + 1)); zip_name=${f##*/}; done
check "stale zips removed: exactly one zip left" 1 "$zip_count"
check "stale zips removed: it is the current one" "Kprofiles-Control-v2.3.4.zip" "$zip_name"

# The same source always builds the same zip (release.sh compares published files byte for byte).
cp "$T/r/dist/Kprofiles-Control-v2.3.4.zip" "$T/first.zip"
sleep 2; touch "$T/r/module/module.prop" "$T/r/module/kp.sh"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
cmp -s "$T/first.zip" "$T/r/dist/Kprofiles-Control-v2.3.4.zip"; check "zip is reproducible (file dates do not matter)" 0 $?

# The real module must point at a manifest that matches the real build.
real=$(tr -d '\r' < "$HERE/../module/module.prop")
check "real module.prop has updateJson" 1 "$(printf '%s\n' "$real" | grep -c '^updateJson=https://github.com/.*/releases/latest/download/update.json$')"
# Scripts and module.prop keep LF line endings in every checkout (a CRLF breaks them on Android).
for pat in '*.sh text eol=lf' '*.prop text eol=lf' '*.html text eol=lf' '*.json text eol=lf' '*.md text eol=lf' '*.yml text eol=lf'; do
  check ".gitattributes forces LF for: $pat" 1 "$(grep -cxF "$pat" "$HERE/../.gitattributes")"
done
warning=$(grep -F 'The saved settings are unreadable or invalid.' "$HERE/../module/webroot/index.html")
check "corrupt settings UI warns current limits may remain" 1 "$(printf '%s\n' "$warning" | grep -c 'may still reflect a previously applied preset')"
check "corrupt settings UI does not claim no limits are applied" 0 "$(printf '%s\n' "$warning" | grep -c 'nothing is applied')"
page="$HERE/../module/webroot/index.html"
check "WebUI preset cooldown is eight seconds" 1 "$(grep -Fc 'PROFILE_COOLDOWN_MS = 8000' "$page")"
for profile in stock tilt saver performance custom dynamic; do
  check "WebUI exposes $profile profile" 1 "$(grep -Fc "data-preset=\"$profile\"><span class=\"t\"" "$page")"
done
check "Performance says it does not overclock" yes "$(grep -Fq 'data-preset="performance"><span class="t"><svg' "$page" && grep -Fq 'This is not an overclock' "$page" && echo yes || echo no)"
check "CPU/GPU Performance and kernel Performance are separate controls" yes "$(grep -F 'data-preset="performance"><span class="t"><svg' "$page" | grep -Fq '</svg>Performance</span>' && grep -F 'data-kp="3"><span class="t"><svg' "$page" | grep -Fq '</svg>Performance</span>' && ! grep -Fq 'No Extra Caps' "$page" && echo yes || echo no)"
check "all standard Kprofiles modes are present" yes "$(for mode in 0 1 2 3; do grep -Fq "data-kp=\"$mode\"" "$page" || exit 1; done; grep -Fq 'Balanced kernel profile; exact effects depend on the kernel.' "$page" && echo yes || echo no)"
check "Performance status does not claim caps are applied" yes "$(grep -Fq 'st.preset === "performance"' "$page" && grep -Fq 'No extra caps' "$page" && echo yes || echo no)"
check "Dynamic screen-on status explains no extra caps" yes "$(grep -Fq 'st.preset === "dynamic" && st.state !== "off"' "$page" && grep -Fq 'No extra caps (screen on)' "$page" && echo yes || echo no)"
check "Dynamic preset uses screen-off caps" yes "$(grep -Fq 'P_OFF_LITTLE_MAX=1017600; P_OFF_BIG_MAX=787200; P_OFF_PRIME_MAX=633600; P_OFF_GPU_MAX=353000000' "$HERE/../module/tune.sh" && echo yes || echo no)"
check "Custom command preserves existing settings" yes "$(grep -Fq 'cfg_put PRESET custom ENABLED 1' "$HERE/../module/tune.sh" && echo yes || echo no)"
check "Reset uses neutral outline with red icon and label only" yes "$(grep -Fq 'class="opt danger-opt" id="resetAll"' "$page" && grep -Fq '.danger-opt{display:flex' "$page" && grep -Fq 'border-color:var(--line);background:var(--surface)' "$page" && grep -Fq '.danger-opt .t{font-size:.91rem;color:var(--danger)}' "$page" && grep -Fq '.danger-opt .reset-icon' "$page" && grep -Fq 'id="resetIcon"' "$page" && echo yes || echo no)"
check "profile and kernel mode labels have minimal inline icons" yes "$(grep -Fq 'class="item-icon"' "$page" && grep -Fq '#presets [data-preset="tilt"] .item-icon{color:var(--icon-orange)}' "$page" && grep -Fq '#kpopts [data-kp="1"] .item-icon{color:var(--icon-green)}' "$page" && echo yes || echo no)"
check "Home status and quick-link icons use semantic accent colors" yes "$(grep -Fq 'tone-purple' "$page" && grep -Fq '#homeKernel .quick-icon{color:var(--icon-purple)}' "$page" && echo yes || echo no)"
check "Kernel profiles are collapsed behind a button" yes "$(grep -Fq 'id="kernelProfilesBtn"' "$page" && grep -Fq 'id="kernelProfilesPanel" class="kernel-panel" style="display:none"' "$page" && echo yes || echo no)"
check "five UI pages are present" yes "$(for id in pageHome pageCpu pageKernel pageMonitor pageSettings; do grep -Fq "id=\"$id\"" "$page" || exit 1; done; echo yes)"
check "fixed bottom navigation exposes all pages" yes "$(grep -Fq 'class="bottom-nav"' "$page" && grep -Fq 'id="navHome"' "$page" && grep -Fq 'id="navCpu"' "$page" && grep -Fq 'id="navKernel"' "$page" && grep -Fq 'id="navMonitor"' "$page" && grep -Fq 'id="navSettings"' "$page" && echo yes || echo no)"
check "live hardware monitor exists above old Monitor status" yes "$(grep -Fq 'id="hwCpuCards"' "$page" && grep -Fq 'id="hwBatteryCard"' "$page" && grep -Fq 'id="hwGpuCard"' "$page" && grep -Fq 'aria-label="Current status"' "$page" && [ "$(grep -n 'id="hwCpuCards"' "$page" | cut -d: -f1)" -lt "$(grep -n 'aria-label="Current status"' "$page" | head -n 1 | cut -d: -f1)" ] && echo yes || echo no)"
check "Home Live Monitoring quick card exists" yes "$(grep -Fq 'id="homeMonitor"' "$page" && grep -Fq 'Live Monitoring<small>CPU, GPU &amp; battery' "$page" && echo yes || echo no)"
check "sampling is visibility-gated and uses one monitor helper" yes "$(grep -Fq 'exec("sh " + BASE + "monitor.sh snapshot")' "$page" && grep -Fq 'currentPage !== "monitor"' "$page" && grep -Fq 'document.addEventListener("visibilitychange"' "$page" && echo yes || echo no)"
check "GPU busy counter pair fallback is supported" yes "$(grep -Fq 'hwCounterValues(data.gpu_busy_counters, 2)' "$page" && echo yes || echo no)"
check "per-CPU fallback deduplicates shared policies" yes "$(grep -Fq 'var unique = [], seenPolicies = {}' "$page" && echo yes || echo no)"
check "sensor-specific temperature and charge thresholds are represented" yes "$(grep -Fq 'kind === "battery" ? 38 : 45' "$page" && grep -Fq 'kind === "battery" ? 45 : 75' "$page" && grep -Fq 'capacity < 20' "$page" && grep -Fq 'capacity < 80' "$page" && echo yes || echo no)"
check "controller source switch is visible and explicit" yes "$(grep -Fq 'id="controlSourceCard"' "$page" && grep -Fq 'id="sourceModuleBtn"' "$page" && grep -Fq 'id="sourceKernelBtn"' "$page" && grep -Fq 'C("switch " + target)' "$page" && echo yes || echo no)"
check "controller switch is enforced in both shell engines" yes "$(grep -Fq 'require_module_controller' "$HERE/../module/tune.sh" && grep -Fq 'sm_source' "$HERE/../module/kp.sh" && echo yes || echo no)"
check "boot applies only the selected control source" yes "$(grep -Fq 'control.sh" init' "$HERE/../module/service.sh" && grep -Fq 'case "$src" in' "$HERE/../module/service.sh" && grep -Fq 'stock-recorded' "$HERE/../module/service.sh" && echo yes || echo no)"
check "controller migration preserves conflict for overlapping legacy selections" yes "$(grep -Fq 'ci_module_active' "$HERE/../module/control.sh" && grep -Fq 'ci_auto' "$HERE/../module/control.sh" && grep -Fq 'ci_source=conflict' "$HERE/../module/control.sh" && echo yes || echo no)"
check "failed handoff can raise the recovery lock" yes "$(grep -Fq 'recovery=1' "$HERE/../module/control.sh" && grep -Fq 'CONTROLLER HANDOFF FAILURE' "$page" && echo yes || echo no)"
check "page navigation remains local" yes "$(grep -Fq 'function showPage(key)' "$page" && grep -Fq 'syncHardwareSampler();' "$page" && echo yes || echo no)"
check "the page is a self-contained offline UI" yes "$(! grep -Eq '<script[^>]+src=|<link[^>]+href=|https?://' "$page" && echo yes || echo no)"
check "Unsupported kernel shows explicit message" yes "$(grep -Fq 'Extra kernel features are not supported by your kernel.' "$page" && grep -Fq 'kernelSupport === "unsupported"' "$page" && echo yes || echo no)"
check "Kernel profile support is determined by kp.sh status mode" yes "$(grep -Fq 'kernelSupport = "supported"' "$page" && grep -Fq 'kernelSupport = "unsupported"' "$page" && echo yes || echo no)"
check "WebUI blocks direct Tilt-to-Saver and Saver-to-Tilt switching" yes "$(grep -Fq 'st.preset === "tilt" && target === "saver"' "$page" && grep -Fq 'st.preset === "saver" && target === "tilt"' "$page" && echo yes || echo no)"
check "WebUI explains Stock or Reset as the required bridge" yes "$(grep -Fq 'Select Stock or Reset everything first' "$page" && echo yes || echo no)"
check "WebUI cooldown starts only after a successful profile action" yes "$(grep -Fq 'succeeded && refreshed && st && st.cfg_error !== "1"' "$page" && grep -Fq 'if (profileAction) startProfileCooldown(notice, noticeKind)' "$page" && echo yes || echo no)"
check "WebUI recognizes kernel-reported frequency mismatches" yes "$(grep -Fq 'function isFrequencyMismatch(text)' "$page" && grep -Fq 'kernel says' "$page" && grep -Fq 'the kernel did not take these limits' "$page" && grep -Fq 'restore refused by the kernel' "$page" && echo yes || echo no)"
check "WebUI preserves engine warn/error lines in recovery notice" yes "$(grep -Fq 'function diagnosticLines(text)' "$page" && grep -Fq 'FREQUENCY RESTORE / APPLY FAILURE' "$page" && echo yes || echo no)"
check "WebUI marks errors as assertive alerts" yes "$(grep -Fq 'm.setAttribute("role", kind === "err" ? "alert" : "status")' "$page" && grep -Fq 'm.setAttribute("aria-live", kind === "err" ? "assertive" : "polite")' "$page" && echo yes || echo no)"
check "Recovery mode locks all controls except Reset everything" yes "$(grep -Fq 'recoveryBlocked = recoveryLock && !isReset' "$page" && grep -Fq 'recoveryLock && cmdLine !== "resetall"' "$page" && echo yes || echo no)"
check "Recovery lock persists across WebUI reloads where storage is available" yes "$(grep -Fq 'window.localStorage.setItem(RECOVERY_LOCK_KEY, "1")' "$page" && grep -Fq 'window.localStorage.getItem(RECOVERY_LOCK_KEY)' "$page" && echo yes || echo no)"
check "Only a clean, refreshed Reset everything clears recovery lock" yes "$(grep -Fq 'cmdLine === "resetall" && succeeded && !frequencyFailure && refreshed && st && st.cfg_error !== "1"' "$page" && grep -Fq 'refreshed && st && st.cfg_error !== "1"' "$page" && echo yes || echo no)"
check "Reset recovery is followed by the eight-second cooldown" yes "$(grep -Fq 'startProfileCooldown("Reset everything succeeded." + (warns.length' "$page" && echo yes || echo no)"
check "Persisted recovery lock is applied before initial async requests" yes "$(grep -Fq 'Apply a persisted recovery lock before the first asynchronous status request.' "$page" && echo yes || echo no)"
check "Readback failure keeps recovery notice visible" yes "$(grep -Fq 'if (recoveryLock) setMsg(recoveryText(), "err")' "$page" && echo yes || echo no)"
check "WebUI starts with status readiness closed" 1 "$(grep -Fc 'statusReady = false' "$page")"
check "WebUI locks non-reset controls until first status succeeds" yes "$(grep -Fq 'initialBlocked = !statusReady && !isReset' "$page" && grep -Fq 'els[i].disabled = disabled || !!bridgeBlocked || initialBlocked || recoveryBlocked' "$page" && echo yes || echo no)"
check "Reset everything is exempt from initial status lock" yes "$(grep -Fq 'var isReset = els[i].id === "resetAll"' "$page" && grep -Fq 'initialBlocked = !statusReady && !isReset' "$page" && echo yes || echo no)"
check "First valid status response sets readiness" yes "$(grep -Fq 'st = kv(a.stdout);' "$page" && grep -Fq 'statusReady = true;' "$page" && echo yes || echo no)"
check "Latest recovery detail has a persistent storage key" yes "$(grep -Fq 'RECOVERY_LATEST_KEY' "$page" && grep -Fq 'getItem(RECOVERY_LATEST_KEY)' "$page" && grep -Fq 'setItem(RECOVERY_LATEST_KEY, recoveryLatest)' "$page" && echo yes || echo no)"
check "Failed reset attempt persists latest recovery details" yes "$(grep -Fq 'Latest Reset everything response:' "$page" && grep -Fq 'persistRecoveryLock();' "$page" && echo yes || echo no)"
# Behaviour of the page's failure detection against the engine's real messages (needs node; CI has it).
if command -v node >/dev/null 2>&1; then
  node "$HERE/webui-test.js" "$page"; check "WebUI behaviour tests (node)" 0 $?
  node "$HERE/webui-dom-test.js" "$page"; check "WebUI start-up lock and stored recovery notice (node, fake DOM)" 0 $?
else
  echo "skip WebUI behaviour tests (node is not installed here; CI runs them)"
fi
rm -rf "$T/real"; mkdir -p "$T/real/module"; cp "$HERE/../build.sh" "$HERE/../CHANGELOG.md" "$T/real/"; cp -r "$HERE/../module/." "$T/real/module/"
( cd "$T/real" && sh build.sh >/dev/null 2>&1 ); check "real repo builds" 0 $?

# A refused build must not leave an earlier build's files behind (they could be uploaded by mistake).
mk "$PROP" "$LOG"; ( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
check "stale test: first build made the files" "yes" "$([ -s "$T/r/dist/update.json" ] && [ -s "$T/r/dist/changelog.md" ] && ls "$T/r/dist"/Kprofiles-Control-*.zip >/dev/null 2>&1 && echo yes || echo no)"
printf '%s' "$PROP" | sed 's/^version=v2.3.4/version=bogus/' > "$T/r/module/module.prop"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 ); rc=$?
check "stale test: bad version is refused" "1" "$rc"
check "stale test: nothing of the earlier build is left" "" "$(ls -A "$T/r/dist")"
mk "$PROP" "$LOG"; ( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
printf '%s' "$PROP" | sed 's/^versionCode=42/versionCode=4x/' > "$T/r/module/module.prop"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
check "stale test: bad versionCode leaves nothing either" "" "$(ls -A "$T/r/dist")"
mk "$PROP" "$LOG"; ( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
printf '# Changelog\n\n## v9.9.9\n- x\n' > "$T/r/CHANGELOG.md"
( cd "$T/r" && sh build.sh >/dev/null 2>&1 )
check "stale test: missing changelog section leaves nothing either" "" "$(ls -A "$T/r/dist")"

[ "$fail" = 0 ] && echo "all tests passed" || { echo "SOME TESTS FAILED"; exit 1; }
