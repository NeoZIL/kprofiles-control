// Behaviour test for the WebUI's failure detection, run by tests/build-test.sh when node is installed.
// It takes isFrequencyMismatch() out of the real page and feeds it the engine's own wording, because a
// wrong answer here either hides a refused limit (the page says nothing) or locks the page for a harmless
// warning (and the lock is stored, so it survives a reload).
const fs = require("fs");
const page = process.argv[2];
const src = fs.readFileSync(page, "utf8");
let fail = 0;
const check = (name, ok, extra) => { console.log((ok ? "ok   " : "FAIL ") + name + (ok ? "" : ": " + extra)); if (!ok) fail = 1; };

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
    [false, "empty output",                          ""],
  ];
  for (const [want, name, text] of cases) check((want ? "locks on: " : "does not lock on: ") + name, fn(text) === want, "got " + fn(text));
}
process.exit(fail);
