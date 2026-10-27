// Behaviour test for the WebUI's failure detection, run by tests/build-test.sh when node is installed.
// It takes isFrequencyMismatch() out of the real page and feeds it the engine's own wording, because a
// wrong answer here either hides a refused limit (the page says nothing) or locks the page for a harmless
// warning (and the lock is stored, so it survives a reload).
const fs = require("fs");
const page = process.argv[2];
const src = fs.readFileSync(page, "utf8");
let fail = 0;
const check = (name, ok, extra) => { console.log((ok ? "ok   " : "FAIL ") + name + (ok ? "" : ": " + extra)); if (!ok) fail = 1; };

// UI safeguards that do not require a browser or a live KernelSU manager.
check("status readiness gate starts closed", /statusReady = false/.test(src), "initial status can still be unknown");
check("non-reset controls are disabled until status is ready", /initialBlocked = !statusReady && !isReset/.test(src), "initial loading lock missing");
check("Reset everything remains available while initial status is unknown", /initialBlocked = !statusReady && !isReset/.test(src) && /var isReset = els\[i\]\.id === "resetAll"/.test(src), "reset should be exempt from initial loading lock");
check("first valid status response opens readiness gate", /st = kv\(a\.stdout\);\s*statusReady = true;/.test(src), "status-ready flag is not set after valid status");
check("latest recovery detail has its own storage key", /RECOVERY_LATEST_KEY/.test(src) && /getItem\(RECOVERY_LATEST_KEY\)/.test(src) && /setItem\(RECOVERY_LATEST_KEY, recoveryLatest\)/.test(src), "latest recovery error is not loaded and saved");
check("latest reset failure persists recovery details", /recoveryLatest = resetDetails[\s\S]{0,260}persistRecoveryLock\(\);/.test(src), "failed reset details are not persisted");
check("request exception persists recovery details", /request failed before recovery could be confirmed[\s\S]{0,120}persistRecoveryLock\(\);/.test(src), "request failure details are not persisted");
check("CPU current frequency formatter includes MHz", /function hwFormatCpuCurrent\(khz\)[\s\S]{0,180}\+ \" MHz\"/.test(src), "CPU current frequency unit is missing");
check("GPU current frequency formatter includes MHz", /function hwFormatGpuCurrent\(hz\)[\s\S]{0,180}\+ \" MHz\"/.test(src), "GPU current frequency unit is missing");
check("Monitor explains CPU utilization math at the bottom", /change in total CPU counters[\s\S]{0,140}idle and I\/O-wait counters/.test(src), "CPU utilization formula is missing");
check("Monitor distinguishes utilization from frequency/max percentage", /percentage in brackets is utilization, not frequency as a percentage of maximum/.test(src), "percentage explanation is ambiguous");
check("Home banner uses the actual kernel mode when Kernel profile owns tuning", /controllerSource === \"kernel\"[\s\S]{0,700}kernelModeLabel\(\)/.test(src), "current profile banner remains tied to the module preset");

// every inline script must at least parse
const scripts = [...src.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
check("the page has an inline script", scripts.length > 0, "none found");
scripts.forEach((m, i) => { try { new Function(m[1]); check("inline script " + i + " parses", true); } catch (e) { check("inline script " + i + " parses", false, e.message); } });

const m = src.match(/function isFrequencyMismatch\(text\) \{[\s\S]*?\n  \}\n/);
check("isFrequencyMismatch is in the page", !!m, "not found");
if (m) {
  const fn = new Function(m[0] + "return isFrequencyMismatch;")();
  const cases = [
    // a refused or unrestorable frequency: the page must lock to Reset everything
    [true,  "kernel refused write, empty reading",   "warn: big max wanted 2188800, kernel says "],
    [true,  "kernel reports another value",          "warn: big max wanted 2188800, kernel says 2572800"],
    [true,  "own value could not be put back",       "warn: could not put the phone's own value back for: big_max; it stays marked as changed so a later Stock or Apply tries again"],
    [true,  "control gone after it was capped",      "warn: the big controls are gone, but this module changed: big_max earlier, so the phone's own value could not be put back; it stays marked as changed"],
    [true,  "kernel did not take the limits",        "error: the kernel did not take these limits: big_max gpu_max (see the warnings above); the other limits are in place"],
    [true,  "not every limit applied",               "error: not every limit could be applied (see the messages above)"],
    [true,  "restore failed summary",                "error: some of the phone's own values could not be put back (see the warning above); your settings and the recorded values are kept"],
    [true,  "restore refused (log wording)",         "restore refused by the kernel for: big_max (kept marked, will be retried)"],
    // harmless messages: they must NOT lock the page
    [false, "marker could not be cleared",           "warn: big_min is back, but its changed-marker could not be cleared; it will be checked again next time"],
    [false, "hardware not present",                  "warn: gpu controls not found on this phone"],
    [false, "preset value not available",            "warn: preset value 1 is not available for big on this phone, skipped"],
    [false, "boot could not read a node",            "warn: could not read these frequency values at boot: big_max (an earlier record is kept if there is one)"],
    [false, "own limits not recorded yet",           "warn: the phone's own value is not recorded for: big_max, so Stock cannot put it back until the next reboot"],
    [false, "kernel profile node not standard (left alone)", "warn: the kernel profile cannot be read or has a value this module does not know, so it was left as it is; if it holds the limits down, set it to None with the tool that provides it"],
    [false, "kernel profile write refused",          "error: the kernel profile could not be set to None: wrote 0 but the kernel reports 1"],
    [false, "empty output",                          ""],
  ];
  for (const [want, name, text] of cases) check((want ? "locks on: " : "does not lock on: ") + name, fn(text) === want, "got " + fn(text));
}
process.exit(fail);
