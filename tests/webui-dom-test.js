// Behaviour test for the WebUI's start-up lock and stored recovery notice. It runs the page's real inline
// script against a very small fake DOM, a fake localStorage and a fake ksu.exec that the test controls, so
// it checks what the page DOES (which controls are usable, which commands are sent, what is stored), not
// only that certain text exists in the file. Run by tests/build-test.sh when node is installed.
const fs = require("fs");
const vm = require("vm");
const page = process.argv[2];
const src = fs.readFileSync(page, "utf8");
let fail = 0;
const check = (name, ok, extra) => { console.log((ok ? "ok   " : "FAIL ") + name + (ok ? "" : ": " + extra)); if (!ok) fail = 1; };

const body = src.slice(src.indexOf("<body>"), src.indexOf("<script>"));
const script = src.match(/<script>([\s\S]*?)<\/script>/)[1];

class El {
  constructor(doc, tag, attrs) {
    this.doc = doc; this.tagName = String(tag).toUpperCase(); this.attrs = Object.assign({}, attrs || {});
    this.children = []; this.parent = null; this.attached = false; this.listeners = {};
    this.style = {}; this.disabled = false; this.checked = false; this.value = ""; this.title = "";
    this.textContent = ""; this.className = this.attrs["class"] || ""; this.options = this.children;
  }
  get id() { return this.attrs.id; }
  set id(v) { this.attrs.id = String(v); }
  hasClass(c) { return (" " + this.className + " ").indexOf(" " + c + " ") >= 0; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
  hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); }
  removeAttribute(k) { delete this.attrs[k]; }
  set innerHTML(h) { if (h !== "") throw new Error("fake DOM: only innerHTML = \"\" is supported"); this.children.forEach((c) => this.doc.detach(c)); this.children.length = 0; }
  appendChild(c) { c.parent = this; this.children.push(c); if (this.attached) this.doc.attach(c); return c; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  closest() { return this; }
  fire(t) { (this.listeners[t] || []).forEach((f) => f({ target: this })); }
}

function makeDom() {
  const doc = {
    all: [],
    attach(e) { e.attached = true; this.all.push(e); e.children.forEach((c) => this.attach(c)); },
    detach(e) { e.attached = false; const i = this.all.indexOf(e); if (i >= 0) this.all.splice(i, 1); e.children.forEach((c) => this.detach(c)); },
    getElementById(id) { return this.all.find((e) => e.attrs.id === id) || null; },
    createElement(tag) { return new El(this, tag); },
    querySelectorAll(sel) {
      if (sel === ".opt, input, select") return this.all.filter((e) => e.hasClass("opt") || e.tagName === "INPUT" || e.tagName === "SELECT");
      if (sel === "#presets .opt") return this.all.filter((e) => e.hasAttribute("data-preset"));
      if (sel === "#kpopts .opt") return this.all.filter((e) => e.hasAttribute("data-kp"));
      throw new Error("fake DOM: selector not supported: " + sel);
    },
  };
  const re = /<(\w+)((?:\s+[\w:-]+(?:="[^"]*")?)*)\s*\/?>/g; let m;
  while ((m = re.exec(body))) {
    const attrs = {}; const ar = /([\w:-]+)(?:="([^"]*)")?/g; let a;
    while ((a = ar.exec(m[2]))) attrs[a[1]] = a[2] === undefined ? "" : a[2];
    const tag = m[1].toLowerCase();
    if (attrs.id || /(^|\s)opt(\s|$)/.test(attrs["class"] || "") || tag === "input" || tag === "select" || tag === "button") doc.attach(new El(doc, tag, attrs));
  }
  return doc;
}

const LISTS = "little=364800 595200 787200 2016000\nbig=480000 633600 2188800 2572800\nprime=480000 633600 2457600 2668800\ngpu=255000000 736000000 900000000\n";
function statusText(over) {
  const o = Object.assign({ enabled: 1, screenoff: 1, preset: "stock", screen: "on", state: "on", daemon: 1 }, over || {});
  return Object.keys(o).map((k) => k + "=" + o[k]).join("\n") + "\ncur_big_min=633600\ncur_big_max=2572800\n";
}
const ok = (stdout) => ({ errno: 0, stdout: stdout || "", stderr: "" });

// load(): runs the page. opts.storage seeds localStorage; opts.handler(cmd) answers every ksu.exec call (an object,
// or a promise the test settles later); the default answers like a healthy phone.
async function load(opts) {
  opts = opts || {};
  const doc = makeDom(); const store = new Map(Object.entries(opts.storage || {}));
  const calls = []; let clock = 1000000; const intervals = []; const timeouts = [];
  const win = { localStorage: {
    getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); } } };
  const def = (cmd) => {
    if (/module\.prop/.test(cmd)) return ok("v3.1.0\n");
    if (/tune\.sh lists/.test(cmd)) return ok(LISTS);
    if (/tune\.sh status/.test(cmd)) return ok(statusText());
    if (/kp\.sh status/.test(cmd)) return ok("mode=0 auto=N persist=1\n");
    return ok("ok\n");
  };
  const ctx = vm.createContext({
    window: win, document: doc, console,
    ksu: { exec(cmd, o, cb) { calls.push(cmd); Promise.resolve((opts.handler || def)(cmd, def)).then((r) => win[cb](r.errno, r.stdout, r.stderr)); } },
    Date: { now: () => clock },
    setInterval: (f, ms) => { intervals.push(f); return intervals.length; }, clearInterval: (id) => { intervals[id - 1] = null; },
    setTimeout: (f, ms) => { timeouts.push({ f, at: clock + ms }); return timeouts.length; }, clearTimeout: (id) => { if (timeouts[id - 1]) timeouts[id - 1].f = null; },
  });
  vm.runInContext(script, ctx);
  const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };
  const c = {
    doc, store, calls, flush,
    el: (id) => doc.getElementById(id),
    usable: () => doc.querySelectorAll(".opt, input, select").filter((e) => !e.disabled && e.id !== "resetAll" && !e.hasClass("retry")),
    msg: () => doc.getElementById("msg").textContent,
    advance: async (ms) => { clock += ms; intervals.forEach((f) => f && f()); timeouts.filter((t) => t.f && t.at <= clock).forEach((t) => { const f = t.f; t.f = null; f(); }); await flush(); },
    sent: (re) => calls.filter((x) => re.test(x)).length,
  };
  await flush();
  return c;
}
const deferred = () => { let res; const p = new Promise((r) => { res = r; }); return { p, res }; };

(async () => {
  // 1. the first status answer has not arrived: the grid has been built, and still nothing but Reset is usable
  {
    const st = deferred();
    const c = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? st.p : def(cmd)) });
    const selects = c.doc.all.filter((e) => e.tagName === "SELECT").length;
    check("start-up: the pickers have been built while status is pending", selects === 16, "selects: " + selects);
    check("start-up: nothing but Reset everything is usable before the first status", c.usable().length === 0, "usable: " + c.usable().map((e) => e.id || e.tagName).join(","));
    check("start-up: Reset everything is usable", c.el("resetAll").disabled === false, "disabled");
    // a tap or toggle that still reaches a handler must not send a command to the engine
    c.el("swEnabled").fire("change"); c.el("swScreenOff").fire("change"); c.el("presets").fire("click"); c.el("kpopts").fire("click");
    const picker = c.doc.all.find((e) => e.tagName === "SELECT"); picker.value = "787200"; picker.fire("change");
    await c.flush();
    check("start-up: no command except Reset reaches the engine before status", c.sent(/tune\.sh (cfg|preset|apply)|kp\.sh (mode|persist)/) === 0, c.calls.join(" | "));
    st.res(ok(statusText()));
    await c.flush();
    check("start-up: the controls open after the first status", c.usable().length > 0, "still locked");
  }
  // 2. the first status fails: the page retries by itself, and offers a button when that is not enough
  {
    let failing = true;
    const c = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) && failing ? { errno: 1, stdout: "", stderr: "not ready" } : def(cmd)) });
    check("failed first status: the controls stay locked", c.usable().length === 0, "usable: " + c.usable().length);
    check("failed first status: the page says why", /not ready/.test(c.msg()), c.msg());
    failing = false;
    await c.advance(3000);
    check("failed first status: a retry opens the controls without a reset", c.usable().length > 0, "still locked");
    check("failed first status: nothing was reset on the way", c.sent(/resetall/) === 0, c.calls.join(" | "));
  }
  {
    let failing = true;
    const c = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) && failing ? { errno: 1, stdout: "", stderr: "not ready" } : def(cmd)) });
    for (let i = 0; i < 6; i++) await c.advance(3000);
    const btn = c.el("retryLoad");
    check("status keeps failing: a Try again button appears", !!btn && btn.style.display === "block", btn ? "display=" + btn.style.display : "no button");
    check("status keeps failing: the controls are still locked", c.usable().length === 0, "usable: " + c.usable().length);
    failing = false;
    if (btn) { btn.fire("click"); await c.flush(); }
    check("Try again opens the controls once status works", c.usable().length > 0, "still locked");
    check("Try again hides the button", !btn || btn.style.display === "none", btn && btn.style.display);
  }
  // 3. the lists cannot be read at all: that must not leave the page locked either
  {
    let failing = true;
    const c = await load({ handler: (cmd, def) => (/tune\.sh lists/.test(cmd) && failing ? { errno: 1, stdout: "", stderr: "no lists" } : def(cmd)) });
    check("lists unreadable: the controls stay locked", c.usable().length === 0, "usable: " + c.usable().length);
    failing = false;
    await c.advance(3000);
    check("lists unreadable: a retry builds the pickers and opens the controls", c.usable().length > 0, "usable: " + c.usable().length);
  }
  // 4. the Tilt / Saver rule still holds once status is known
  {
    const c = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ preset: "tilt" })) : def(cmd)) });
    const by = (p) => c.doc.all.find((e) => e.getAttribute("data-preset") === p);
    check("tilt active: Battery saver is blocked", by("saver").disabled === true, "enabled");
    check("tilt active: Stock is available", by("stock").disabled === false, "disabled");
  }
  // 5. a stored recovery lock: shown at once, Reset is the only way out, the latest failure survives reloads
  const LOCK = { "kprofiles-ui-frequency-recovery-v1": "1", "kprofiles-ui-frequency-recovery-message-v1": "FREQUENCY RESTORE / APPLY FAILURE\noriginal",
                 "kprofiles-ui-frequency-recovery-latest-v1": "Latest Reset everything response:\nerror: some of the phone's own values could not be put back" };
  {
    const c = await load({ storage: LOCK });
    check("stored lock: the original message is shown after a reload", /original/.test(c.msg()), c.msg());
    check("stored lock: the latest failure is shown after a reload", /could not be put back/.test(c.msg()), c.msg());
    check("stored lock: only Reset everything is usable", c.usable().length === 0 && c.el("resetAll").disabled === false, "usable: " + c.usable().length);
  }
  {
    const c = await load({ storage: LOCK, handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? { errno: 1, stdout: "", stderr: "x" } : def(cmd)) });
    check("stored lock and no status: Reset everything is still usable", c.el("resetAll").disabled === false, "disabled");
  }
  {
    let reset = "fail";
    const c = await load({ storage: LOCK, handler: (cmd, def) => {
      if (/tune\.sh resetall/.test(cmd)) return reset === "fail" ? ok("warn: big max wanted 2572800, kernel says 2188800\nerror: some of the phone's own values could not be put back (see above)\n") : ok("ok\n");
      return def(cmd);
    } });
    c.el("resetAll").fire("click"); await c.flush();
    const latest = c.store.get("kprofiles-ui-frequency-recovery-latest-v1") || "";
    check("a failed Reset keeps the lock", c.store.get("kprofiles-ui-frequency-recovery-v1") === "1", "lock: " + c.store.get("kprofiles-ui-frequency-recovery-v1"));
    check("a failed Reset stores its own response", /Latest Reset everything response/.test(latest) && /kernel says 2188800/.test(latest), latest);
    check("a failed Reset shows it on the page", /kernel says 2188800/.test(c.msg()), c.msg());
    // reload: the stored detail comes back
    const again = await load({ storage: Object.fromEntries(c.store) });
    check("after a reload the stored failed-Reset response is shown", /kernel says 2188800/.test(again.msg()), again.msg());
    // a verified recovery clears everything that was stored
    reset = "ok"; await c.advance(0);
    c.el("resetAll").fire("click"); await c.flush();
    check("a clean Reset clears the lock", c.store.has("kprofiles-ui-frequency-recovery-v1") === false, "still stored");
    check("a clean Reset clears the stored message", c.store.has("kprofiles-ui-frequency-recovery-message-v1") === false, "still stored");
    check("a clean Reset clears the stored latest response", c.store.has("kprofiles-ui-frequency-recovery-latest-v1") === false, "still stored");
  }
  // 6. The new profile choices exist, and the kernel section starts collapsed when supported.
  {
    const c = await load();
    for (const preset of ["performance", "custom", "dynamic"]) {
      check("new profile button exists: " + preset, c.doc.all.some((e) => e.getAttribute("data-preset") === preset), "missing");
    }
    check("Reset everything uses the outlined danger-action style", c.el("resetAll").hasClass("danger-opt"), c.el("resetAll").className);
    check("Reset button includes its own reset icon", !!c.el("resetIcon"), "missing reset SVG");
    check("Reset button exposes a clear accessible label", c.el("resetAll").getAttribute("aria-label") === "Reset everything", c.el("resetAll").getAttribute("aria-label"));
    check("kernel profiles section starts collapsed", c.el("kernelProfilesPanel").style.display === "none", c.el("kernelProfilesPanel").style.display);
    check("supported kernel enables its profile button", c.el("kernelProfilesBtn").disabled === false, "disabled");
    check("the three existing kernel profile choices remain available", c.doc.all.filter((e) => e.hasAttribute("data-kp")).length === 3, "wrong choice count");
    c.el("kernelProfilesBtn").fire("click");
    check("tap expands supported kernel profiles", c.el("kernelProfilesPanel").style.display === "block" && c.el("kernelProfilesBtn").getAttribute("aria-expanded") === "true", c.el("kernelProfilesPanel").style.display);
  }
  // 7. Unsupported kernel: keep only the disabled top-level button and an explicit message; hide the modes.
  {
    const c = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? ok("mode=? auto=? persist=1\n") : def(cmd)) });
    check("unsupported kernel disables the kernel profiles button", c.el("kernelProfilesBtn").disabled === true, "button enabled");
    check("unsupported kernel hides the three modes", c.el("kernelProfilesPanel").style.display === "none", c.el("kernelProfilesPanel").style.display);
    check("unsupported kernel shows the support notice", c.el("kernelUnsupported").style.display === "block", c.el("kernelUnsupported").style.display);
    check("unsupported kernel disables each kernel mode control", c.doc.all.filter((e) => e.hasAttribute("data-kp")).every((e) => e.disabled), "a kernel option remained enabled");
    check("unsupported kernel disables kernel persistence", c.el("swKpPersist").disabled === true, "enabled");
  }
  // 8. The Stock/Reset bridge between Battery tilt and Battery saver holds through the other profiles too.
  const clickPreset = (c, name) => { const b = c.doc.all.find((e) => e.getAttribute("data-preset") === name); (c.el("presets").listeners.click || []).forEach((f) => f({ target: b })); };
  const clickKp = (c, mode) => { const b = c.doc.all.find((e) => e.getAttribute("data-kp") === String(mode)); (c.el("kpopts").listeners.click || []).forEach((f) => f({ target: b })); };
  const BRIDGE_KEY = "kprofiles-ui-tilt-saver-bridge-v1";
  // a phone whose preset really changes when a preset command is sent
  const livePhone = (first, extra) => {
    const s = { preset: first };
    return { s, handler: (cmd, def) => {
      const m = cmd.match(/tune\.sh preset (\w+)/);
      if (m) { s.preset = m[1]; return ok("ok\n"); }
      if (/tune\.sh resetall/.test(cmd)) { s.preset = "stock"; return ok("ok\n"); }
      if (/tune\.sh status/.test(cmd)) return ok(statusText(Object.assign({ preset: s.preset, enabled: s.preset === "stock" ? 0 : 1 }, extra || {})));
      return def(cmd);
    } };
  };
  for (const [from, to, via] of [["tilt", "saver", "performance"], ["tilt", "saver", "custom"], ["tilt", "saver", "dynamic"], ["saver", "tilt", "performance"], ["saver", "tilt", "custom"], ["saver", "tilt", "dynamic"]]) {
    const ph = livePhone(from);
    const c = await load({ handler: ph.handler });
    clickPreset(c, to); await c.flush();
    check(from + " -> " + to + " directly is refused", c.sent(new RegExp("preset " + to)) === 0, c.calls.join(" | "));
    clickPreset(c, via); await c.flush(); await c.advance(9000);
    check(from + " -> " + via + " is allowed", ph.s.preset === via, "preset is " + ph.s.preset);
    check(from + " -> " + via + ": the bridge origin is remembered", c.store.get(BRIDGE_KEY) === from, String(c.store.get(BRIDGE_KEY)));
    clickPreset(c, to); await c.flush();
    check(from + " -> " + via + " -> " + to + " does not get around Stock", c.sent(new RegExp("preset " + to)) === 0 && ph.s.preset === via, c.calls.join(" | "));
    check(from + " -> " + via + " -> " + to + ": the page says why", /Direct switching/.test(c.msg()), c.msg());
    clickPreset(c, from); await c.flush(); await c.advance(9000);
    check(from + " -> " + via + " -> " + from + " (same side) is fine", ph.s.preset === from, "preset is " + ph.s.preset);
    clickPreset(c, via); await c.flush(); await c.advance(9000);
    clickPreset(c, "stock"); await c.flush(); await c.advance(9000);
    check("Stock clears the bridge origin", !c.store.has(BRIDGE_KEY), String(c.store.get(BRIDGE_KEY)));
    clickPreset(c, to); await c.flush();
    check("after Stock, " + to + " is allowed", ph.s.preset === to, "preset is " + ph.s.preset);
  }
  {
    // Reset everything clears the bridge as well
    const ph = livePhone("tilt");
    const c = await load({ handler: ph.handler });
    clickPreset(c, "performance"); await c.flush(); await c.advance(9000);
    c.el("resetAll").fire("click"); await c.flush(); await c.advance(9000);
    check("Reset everything clears the bridge origin", !c.store.has(BRIDGE_KEY), String(c.store.get(BRIDGE_KEY)));
    clickPreset(c, "saver"); await c.flush();
    check("after Reset everything, saver is allowed", ph.s.preset === "saver", "preset is " + ph.s.preset);
  }
  {
    // the origin survives a reload of the page
    const ph = livePhone("performance");
    const c = await load({ handler: ph.handler, storage: { [BRIDGE_KEY]: "tilt" } });
    clickPreset(c, "saver"); await c.flush();
    check("a stored bridge origin still blocks after a reload", c.sent(/preset saver/) === 0, c.calls.join(" | "));
    const c2 = await load({ handler: livePhone("performance").handler, storage: { [BRIDGE_KEY]: "nonsense" } });
    clickPreset(c2, "saver"); await c2.flush();
    check("a corrupt stored origin is ignored", c2.sent(/preset saver/) === 1, c2.calls.join(" | "));
    const c3 = await load({ handler: livePhone("stock").handler, storage: { [BRIDGE_KEY]: "tilt" } });
    check("a stored origin is dropped when the phone is on Stock", !c3.store.has(BRIDGE_KEY), String(c3.store.get(BRIDGE_KEY)));
  }
  // 9. Status wording for the new profiles
  {
    const c = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ preset: "performance" })) : def(cmd)) });
    check("Performance preset says there are no extra caps", c.el("sActive").textContent === "No extra caps", c.el("sActive").textContent);
    check("Performance is the highlighted CPU/GPU preset", c.doc.all.find((e) => e.getAttribute("data-preset") === "performance").getAttribute("aria-checked") === "true", "not highlighted");
    const d1 = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ preset: "dynamic", state: "on" })) : def(cmd)) });
    check("Dynamic with the screen on says no extra caps", d1.el("sActive").textContent === "No extra caps (screen on)", d1.el("sActive").textContent);
    const d2 = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ preset: "dynamic", state: "off", screen: "off" })) : def(cmd)) });
    check("Dynamic with the screen off says the screen-off set is active", d2.el("sActive").textContent === "Screen-off set", d2.el("sActive").textContent);
    const cu = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ preset: "custom" })) : def(cmd)) });
    check("Custom is highlighted and its note is shown", cu.doc.all.find((e) => e.getAttribute("data-preset") === "custom").getAttribute("aria-checked") === "true" && cu.el("customNote").style.display === "block", "custom not shown");
    const nt = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 0, preset: "stock" })) : def(cmd)) });
    check("Not active when the module is off", nt.el("sActive").textContent === "Not active", nt.el("sActive").textContent);
  }
  // 10. Kernel profile section: the other states, and what the three choices send
  {
    const c = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? { errno: 1, stdout: "", stderr: "kp.sh: not found" } : def(cmd)) });
    check("kernel status unreadable: the button is locked", c.el("kernelProfilesBtn").disabled === true, "enabled");
    check("kernel status unreadable: it is not called unsupported", c.el("kernelUnsupported").style.display === "none", c.el("kernelUnsupported").style.display);
    check("kernel status unreadable: the retry hint is shown", c.el("kernelUnknown").style.display === "block", c.el("kernelUnknown").style.display);
    check("kernel status unreadable: the modes stay hidden", c.el("kernelProfilesPanel").style.display === "none", c.el("kernelProfilesPanel").style.display);
    const u = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? ok("mode=? auto=? persist=1\n") : def(cmd)) });
    check("unsupported: the exact message is on the page and shown", /id="kernelUnsupported"[^>]*>Extra kernel features are not supported by your kernel\./.test(src) && u.el("kernelUnsupported").style.display === "block", u.el("kernelUnsupported").style.display);
    check("unsupported: the unknown-state hint is not shown", u.el("kernelUnknown").style.display === "none", u.el("kernelUnknown").style.display);
    u.el("kernelProfilesBtn").fire("click");
    check("unsupported: tapping the locked button opens nothing", u.el("kernelProfilesPanel").style.display === "none", u.el("kernelProfilesPanel").style.display);
    clickKp(u, 1); u.el("swKpPersist").fire("change"); await u.flush();
    check("unsupported: a kernel choice or the persist switch sends nothing, even if a tap gets through", u.sent(/kp\.sh (mode|persist)/) === 0, u.calls.join(" | "));
    check("unsupported: the page says nothing was changed", /not supported by your kernel, so nothing was changed/.test(u.msg()), u.msg());
    const s = await load();
    s.el("kernelProfilesBtn").fire("click"); await s.flush();
    check("supported: the unsupported message is hidden", s.el("kernelUnsupported").style.display === "none", s.el("kernelUnsupported").style.display);
    clickKp(s, 1); await s.flush();
    check("supported: Battery sends mode 1", s.sent(/kp\.sh mode 1/) === 1, s.calls.join(" | "));
    clickKp(s, 3); await s.flush(); await s.advance(9000);
    check("supported: Performance sends mode 3", s.sent(/kp\.sh mode 3/) === 1, s.calls.join(" | "));
    check("the section stays open after a kernel change", s.el("kernelProfilesPanel").style.display === "block", s.el("kernelProfilesPanel").style.display);
    s.el("kernelProfilesBtn").fire("click");
    check("tapping again collapses it", s.el("kernelProfilesPanel").style.display === "none", s.el("kernelProfilesPanel").style.display);
    // support disappears on a later refresh (for example after a status retry): the section closes and locks
    let gone = false;
    const g = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) && gone ? ok("mode=? auto=? persist=1\n") : def(cmd)) });
    g.el("kernelProfilesBtn").fire("click");
    gone = true; clickPreset(g, "performance"); await g.flush();
    check("support lost: the open section closes", g.el("kernelProfilesPanel").style.display === "none" && g.el("kernelProfilesBtn").disabled === true, g.el("kernelProfilesPanel").style.display);
    // a stored recovery lock keeps the kernel section shut too
    const r = await load({ storage: { "kprofiles-ui-frequency-recovery-v1": "1", "kprofiles-ui-frequency-recovery-message-v1": "x" } });
    check("recovery lock: the kernel section button is locked", r.el("kernelProfilesBtn").disabled === true, "enabled");
    check("recovery lock: kernel choices are locked", r.doc.all.filter((e) => e.hasAttribute("data-kp")).every((e) => e.disabled), "a choice is enabled");
  }
  // 11. the five-page UI navigates locally and does not issue shell commands
  {
    const c = await load();
    const before = c.calls.length;
    check("navigation starts on Home", c.el("pageHome").style.display === "block" && c.el("navHome").getAttribute("aria-current") === "page", "Home not active");
    const routes = [
      ["navCpu", "pageCpu", "cpu"],
      ["navKernel", "pageKernel", "kernel"],
      ["navMonitor", "pageMonitor", "monitor"],
      ["navSettings", "pageSettings", "settings"],
      ["navHome", "pageHome", "home"]
    ];
    routes.forEach(([navId, pageId, key]) => {
      c.el(navId).fire("click");
      check("navigation opens " + key, c.el(pageId).style.display === "block" && c.el(navId).getAttribute("aria-current") === "page", "page/nav not active");
      const visible = ["pageHome", "pageCpu", "pageKernel", "pageMonitor", "pageSettings"].filter((id) => c.el(id).style.display === "block");
      check("navigation leaves exactly one page visible after " + key, visible.length === 1 && visible[0] === pageId, visible.join(","));
    });
    c.el("homeProfiles").fire("click");
    check("Home quick access opens CPU and GPU", c.el("pageCpu").style.display === "block", c.el("pageCpu").style.display);
    c.el("topSettings").fire("click");
    check("header gear opens Settings", c.el("pageSettings").style.display === "block", c.el("pageSettings").style.display);
    c.el("homeOpenMonitor").fire("click");
    check("Home details shortcut opens Monitor", c.el("pageMonitor").style.display === "block", c.el("pageMonitor").style.display);
    check("page navigation issues no shell commands", c.calls.length === before, "before=" + before + " after=" + c.calls.length);
  }
  process.exit(fail);
})().catch((e) => { console.log("FAIL the test itself crashed: " + (e && e.stack || e)); process.exit(1); });
