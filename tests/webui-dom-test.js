// Behaviour test for WebUI startup/recovery and battery-drain persistence. It runs the page's real inline
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
  /* the page listens for visibilitychange: let a test hide and show it */
  doc.visibilityState = "visible"; const visListeners = [];
  doc.addEventListener = (t, f) => { if (t === "visibilitychange") visListeners.push(f); };
  const calls = []; let clock = opts.now === undefined ? 1000000 : opts.now; const intervals = []; const timeouts = [];
  const confirms = [];
  const win = { localStorage: {
    getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); }
  }, confirm: (message) => { confirms.push(String(message)); return opts.confirm === undefined ? true : !!opts.confirm; } };
  const NativeDate = Date;
  const FakeDate = function (value) { return new NativeDate(value === undefined ? clock : value); };
  FakeDate.now = () => clock;
  FakeDate.parse = NativeDate.parse;
  FakeDate.UTC = NativeDate.UTC;
  FakeDate.prototype = NativeDate.prototype;
  const def = (cmd) => {
    if (/module\.prop/.test(cmd)) return ok("v3.1.0\n");
    if (/tune\.sh lists/.test(cmd)) return ok(LISTS);
    if (/tune\.sh status/.test(cmd)) return ok(statusText());
    if (/kp\.sh status/.test(cmd)) return ok("mode=0 auto=N persist=1 support=supported auto_support=supported\n");
    if (/control\.sh status/.test(cmd)) return ok("source=" + (opts.controllerSource || "module") + "\nsource_message=mock controller state\nkernel_support=supported\n");
    if (/control\.sh switch /.test(cmd)) return ok("source=" + cmd.match(/control\.sh switch (module|kernel)/)[1] + "\n");
    if (/monitor\.sh snapshot/.test(cmd)) return ok("schema=1\ndevice=peridot\ncpu_online_list=0-7\ncpu_policy_0_cpus=0 1 2\ncpu_policy_0_affected_cpus=0 1 2\ncpu_policy_0_cur_khz=1017600\ncpu_policy_0_min_khz=595200\ncpu_policy_0_max_khz=1017600\ncpu_policy_3_cpus=3 4 5 6\ncpu_policy_3_affected_cpus=3 4 5 6\ncpu_policy_3_cur_khz=787200\ncpu_policy_3_min_khz=633600\ncpu_policy_3_max_khz=787200\ncpu_policy_7_cpus=7\ncpu_policy_7_affected_cpus=7\ncpu_policy_7_cur_khz=633600\ncpu_policy_7_min_khz=633600\ncpu_policy_7_max_khz=633600\nstat_cpu0=1 2 3 4 5 6 7 8 0 0\nstat_cpu1=1 2 3 4 5 6 7 8 0 0\nstat_cpu2=1 2 3 4 5 6 7 8 0 0\nstat_cpu3=1 2 3 4 5 6 7 8 0 0\nstat_cpu4=1 2 3 4 5 6 7 8 0 0\nstat_cpu5=1 2 3 4 5 6 7 8 0 0\nstat_cpu6=1 2 3 4 5 6 7 8 0 0\nstat_cpu7=1 2 3 4 5 6 7 8 0 0\nthermal_1_type=cpu-0-0-0\nthermal_1_raw=37000\nthermal_2_type=cpu-1-0-0\nthermal_2_raw=50000\nthermal_3_type=cpu-2-0-0\nthermal_3_raw=75000\nthermal_4_type=gpuss-0\nthermal_4_raw=33000\ngpu_cur_hz=684000000\ngpu_min_hz=255000000\ngpu_max_hz=736000000\ngpu_busy_pct=27 %\nbattery_status=Discharging\nbattery_capacity=68\nbattery_current_now=-400000\nbattery_voltage_now=4084000\nbattery_power_now=2000000\nbattery_temp=306\nbattery_charge_counter=2891000\nbattery_charge_full=4425000\n");
    if (/monitor\.sh screen/.test(cmd)) return ok("screen_state=off\nbattery_status=Discharging\nbattery_capacity=68\nbattery_charge_counter=2891000\nbattery_charge_full=4425000\n");
    return ok("ok\n");
  };
  const ctx = vm.createContext({
    window: win, document: doc, console,
    ksu: { exec(cmd, o, cb) { calls.push(cmd); Promise.resolve((opts.handler || def)(cmd, def)).then((r) => win[cb](r.errno, r.stdout, r.stderr)); } },
    Date: FakeDate,
    setInterval: (f, ms) => { intervals.push(f); return intervals.length; }, clearInterval: (id) => { intervals[id - 1] = null; },
    setTimeout: (f, ms) => { timeouts.push({ f, at: clock + ms }); return timeouts.length; }, clearTimeout: (id) => { if (timeouts[id - 1]) timeouts[id - 1].f = null; },
  });
  vm.runInContext(script, ctx);
  const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };
  const c = {
    doc, store, calls, confirms, flush,
    el: (id) => doc.getElementById(id),
    usable: () => doc.querySelectorAll(".opt, input, select").filter((e) => !e.disabled && e.id !== "resetAll" && !e.hasClass("retry")),
    msg: () => doc.getElementById("msg").textContent,
    advance: async (ms) => { clock += ms; intervals.forEach((f) => f && f()); timeouts.filter((t) => t.f && t.at <= clock).forEach((t) => { const f = t.f; t.f = null; f(); }); await flush(); },
    sent: (re) => calls.filter((x) => re.test(x)).length,
    setVisible: async (v) => { doc.visibilityState = v ? "visible" : "hidden"; visListeners.forEach((f) => f()); await flush(); },
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
    const c = await load({ controllerSource: "kernel" });
    for (const preset of ["performance", "custom", "dynamic"]) {
      check("new profile button exists: " + preset, c.doc.all.some((e) => e.getAttribute("data-preset") === preset), "missing");
    }
    check("Reset everything uses the outlined danger-action style", c.el("resetAll").hasClass("danger-opt"), c.el("resetAll").className);
    check("Reset button includes its own reset icon", !!c.el("resetIcon"), "missing reset SVG");
    check("Reset button exposes a clear accessible label", c.el("resetAll").getAttribute("aria-label") === "Reset everything", c.el("resetAll").getAttribute("aria-label"));
    check("kernel profiles section starts collapsed", c.el("kernelProfilesPanel").style.display === "none", c.el("kernelProfilesPanel").style.display);
    check("supported kernel enables its profile button", c.el("kernelProfilesBtn").disabled === false, "disabled");
    check("all four standard Kprofiles mode choices remain available", c.doc.all.filter((e) => e.hasAttribute("data-kp")).length === 4 && !!c.doc.all.find((e) => e.getAttribute("data-kp") === "2"), "wrong choice count or missing Balanced mode");
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
    const perf = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 1, screenoff: 0, preset: "performance", daemon: 0 })) : def(cmd)) });
    check("Performance reports that the screen watcher is not needed", perf.el("sDaemon").textContent === "Not needed" && perf.el("homeWatcher").textContent === "Not needed", perf.el("sDaemon").textContent + "/" + perf.el("homeWatcher").textContent);
    const heldOn = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 1, screenoff: 0, preset: "custom", daemon: 1, watcher_needed: 1 })) : def(cmd)) });
    check("screen-on caps without screen-off caps still show the watcher as Running", heldOn.el("sDaemon").textContent === "Running", heldOn.el("sDaemon").textContent);
    const heldOnStopped = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 1, screenoff: 0, preset: "custom", daemon: 0, watcher_needed: 1 })) : def(cmd)) });
    check("held screen-on caps with the watcher down show Stopped, not Not needed", heldOnStopped.el("sDaemon").textContent === "Stopped", heldOnStopped.el("sDaemon").textContent);
    const stopped = await load({ handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 1, screenoff: 1, daemon: 0 })) : def(cmd)) });
    check("required but stopped screen watcher remains visible as a problem", stopped.el("sDaemon").textContent === "Stopped", stopped.el("sDaemon").textContent);
    const kernel = await load({ controllerSource: "kernel", handler: (cmd, def) => (/tune\.sh status/.test(cmd) ? ok(statusText({ enabled: 1, screenoff: 1, daemon: 0 })) : def(cmd)) });
    check("kernel-owned tuning reports the module watcher as released", kernel.el("sDaemon").textContent === "Released" && kernel.el("homeWatcher").textContent === "Released", kernel.el("sDaemon").textContent + "/" + kernel.el("homeWatcher").textContent);
  }
  // 10. Kernel profile section: the other states, and what the three choices send
  {
    const c = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? { errno: 1, stdout: "", stderr: "kp.sh: not found" } : def(cmd)) });
    check("kernel status unreadable: the button is locked", c.el("kernelProfilesBtn").disabled === true, "enabled");
    check("kernel status unreadable: it is not called unsupported", c.el("kernelUnsupported").style.display === "none", c.el("kernelUnsupported").style.display);
    check("kernel status unreadable: the retry hint is shown", c.el("kernelUnknown").style.display === "block", c.el("kernelUnknown").style.display);
    check("kernel status unreadable: the modes stay hidden", c.el("kernelProfilesPanel").style.display === "none", c.el("kernelProfilesPanel").style.display);
    const u = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? ok("mode=? auto=? persist=1 support=unsupported auto_support=unsupported\n") : def(cmd)) });
    check("unsupported: the explicit support field is honored", u.el("kernelUnsupported").style.display === "block", u.el("kernelUnsupported").style.display);
    check("unsupported: the exact message is on the page and shown", /id="kernelUnsupported"[^>]*>Extra kernel features are not supported by your kernel\./.test(src) && u.el("kernelUnsupported").style.display === "block", u.el("kernelUnsupported").style.display);
    check("unsupported: the unknown-state hint is not shown", u.el("kernelUnknown").style.display === "none", u.el("kernelUnknown").style.display);
    u.el("kernelProfilesBtn").fire("click");
    check("unsupported: tapping the locked button opens nothing", u.el("kernelProfilesPanel").style.display === "none", u.el("kernelProfilesPanel").style.display);
    clickKp(u, 1); u.el("swKpPersist").fire("change"); await u.flush();
    check("unsupported: a kernel choice or the persist switch sends nothing, even if a tap gets through", u.sent(/kp\.sh (mode|persist)/) === 0, u.calls.join(" | "));
    check("unsupported: the page says nothing was changed", /not supported by your kernel, so nothing was changed/.test(u.msg()), u.msg());
    const unknownSupport = await load({ handler: (cmd, def) => (/kp\.sh status/.test(cmd) ? ok("mode=? auto=? persist=1 support=unknown auto_support=unknown\n") : def(cmd)) });
    check("present but unreadable Kprofiles interface remains unconfirmed", unknownSupport.el("kernelUnknown").style.display === "block" && unknownSupport.el("kernelUnsupported").style.display === "none", unknownSupport.el("kernelUnknown").style.display + "/" + unknownSupport.el("kernelUnsupported").style.display);
    clickKp(unknownSupport, 1); await unknownSupport.flush();
    check("unconfirmed Kprofiles interface sends no command", unknownSupport.sent(/kp\.sh mode/) === 0, unknownSupport.calls.join(" | "));
    let simulatedKernelMode = "0";
    const s = await load({ controllerSource: "kernel", handler: (cmd, def) => {
      const modeCall = cmd.match(/kp\.sh mode ([0-3])/);
      if (modeCall) {
        simulatedKernelMode = modeCall[1];
        return ok("mode=" + simulatedKernelMode + " auto=N persist=1 support=supported auto_support=supported\n");
      }
      if (/kp\.sh status/.test(cmd)) return ok("mode=" + simulatedKernelMode + " auto=N persist=1 support=supported auto_support=supported\n");
      return def(cmd);
    } });
    s.el("kernelProfilesBtn").fire("click"); await s.flush();
    check("supported: the unsupported message is hidden", s.el("kernelUnsupported").style.display === "none", s.el("kernelUnsupported").style.display);
    clickKp(s, 1); await s.flush();
    check("supported: Battery sends mode 1", s.sent(/kp\.sh mode 1/) === 1, s.calls.join(" | "));
    await s.advance(9000); clickKp(s, 2); await s.flush();
    check("supported: Balanced sends mode 2", s.sent(/kp\.sh mode 2/) === 1, s.calls.join(" | "));
    await s.advance(9000);
    check("mode 2 is highlighted as Balanced, not None", s.doc.all.find((e) => e.getAttribute("data-kp") === "2").getAttribute("aria-checked") === "true", "Balanced is not active");
    clickKp(s, 3); await s.flush();
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
  // 11. Controller source is explicit, engine-backed and independent of saved preset choices.
  {
    const c = await load({ controllerSource: "module" });
    check("Module source keeps the module preset as the current profile", c.el("homeProfileEyebrow").textContent === "Current profile" && c.el("homePreset").textContent === "Stock", c.el("homeProfileEyebrow").textContent + " / " + c.el("homePreset").textContent);
    check("Module source reports the module as active", c.el("homeActiveBadge").textContent === "Module on", c.el("homeActiveBadge").textContent);
    check("control source card is visible when Kprofiles is supported", c.el("controlSourceCard").style.display === "block", c.el("controlSourceCard").style.display);
    check("Module presets is selected in Module mode", c.el("sourceModuleBtn").getAttribute("aria-pressed") === "true", c.el("sourceModuleBtn").getAttribute("aria-pressed"));
    check("kernel controls are locked while Module presets owns tuning", c.doc.all.filter((e) => e.hasAttribute("data-kp")).every((e) => e.disabled), "a kernel option is enabled");
    check("preset controls remain available while Module presets owns tuning", c.doc.all.filter((e) => e.hasAttribute("data-preset")).every((e) => !e.disabled), "a preset is disabled");
  }
  {
    const c = await load({ controllerSource: "kernel", handler: (cmd, def) => {
      if (/tune\.sh status/.test(cmd)) return ok(statusText({ preset: "tilt", enabled: 1 }));
      if (/kp\.sh status/.test(cmd)) return ok("mode=2 auto=N persist=1 support=supported auto_support=supported\n");
      return def(cmd);
    } });
    check("Kernel source changes the hero label to Kernel profile", c.el("homeProfileEyebrow").textContent === "Kernel profile", c.el("homeProfileEyebrow").textContent);
    check("Kernel source shows the actual current kernel mode, not the saved Battery tilt preset", c.el("homePreset").textContent === "Balanced", c.el("homePreset").textContent);
    check("Kernel source badge does not claim Module on", c.el("homeActiveBadge").textContent === "Kernel active", c.el("homeActiveBadge").textContent);
    check("saved module preset is identified as inactive", /Saved module preset: Battery tilt \(not controlling CPU\/GPU limits\)/.test(c.el("homePresetHint").textContent), c.el("homePresetHint").textContent);
  }
  {
    let source = "conflict";
    const c = await load({ controllerSource: "conflict", handler: (cmd, def) => {
      if (/control\.sh status/.test(cmd)) return ok("source=" + source + "\nsource_message=Choose one controller\nkernel_support=supported\n");
      const m = cmd.match(/control\.sh switch (module|kernel)/);
      if (m) { source = m[1]; return ok("source=" + source + "\n"); }
      return def(cmd);
    } });
    check("legacy overlap is shown as a controller conflict", c.el("controlSourceConflict").style.display === "block", c.el("controlSourceConflict").style.display);
    check("conflict locks both tuning controllers until a choice", c.doc.all.filter((e) => e.hasAttribute("data-preset") || e.hasAttribute("data-kp")).every((e) => e.disabled), "a tuning control is enabled");
    c.el("sourceModuleBtn").fire("click"); await c.flush(); await c.advance(9000);
    check("choosing Module presets issues an explicit handoff command", c.sent(/control\.sh switch module/) === 1, c.calls.join(" | "));
    check("successful conflict resolution selects Module presets", c.el("sourceModuleBtn").getAttribute("aria-pressed") === "true", c.el("sourceModuleBtn").getAttribute("aria-pressed"));
    check("successful conflict resolution unlocks module presets", c.doc.all.filter((e) => e.hasAttribute("data-preset")).every((e) => !e.disabled), "a preset remains disabled");
  }
  // 12. navigation is local; Monitor is the default route and the dock keeps all destinations accessible.
  {
    const c = await load();
    const before = c.calls.length;
    check("navigation starts on Monitor", c.el("pageMonitor").style.display === "block" && c.el("navMonitor").getAttribute("aria-current") === "page", "Monitor not active");
    check("dock is a floating rounded navigation surface", /\.bottom-nav-inner\{[^}]*border-radius:23px/.test(src) && /backdrop-filter:blur\(18px\)/.test(src), "modern dock styling not found");
    check("dock order is Monitor, CPU & GPU, Home, Kernel, Settings", src.indexOf('id="navMonitor"') < src.indexOf('id="navCpu"') && src.indexOf('id="navCpu"') < src.indexOf('id="navHome"') && src.indexOf('id="navHome"') < src.indexOf('id="navKernel"') && src.indexOf('id="navKernel"') < src.indexOf('id="navSettings"'), "navigation order does not match proposal");
    check("battery appears before CPU and GPU telemetry", src.indexOf('id="hwBatteryCard"') < src.indexOf('id="hwCpuCards"') && src.indexOf('id="hwCpuCards"') < src.indexOf('id="hwGpuCard"'), "hardware card order is wrong");
    check("active and idle cards render independent average-current metrics", /id="hwBatteryActiveDrain"/.test(src) && /id="hwBatteryIdleDrain"/.test(src) && /Whole-cycle average/.test(src) && /safeCurrentStats/.test(src), "independent cycle-average rendering is missing");
    check("active and idle main values are never rendered as legacy percent-per-hour rates", /hwFormatNumber\(hwLastActiveRate\.rate/.test(src) === false && /hwFormatNumber\(hwLastIdleRate\.rate/.test(src) === false, "legacy rate was used as the primary value");
    check("screen-on and screen-off time cards are present", /id="hwBatteryScreenOnTime"/.test(src) && /id="hwBatteryScreenOffTime"/.test(src), "screen time cards are missing");
    check("screen time is described as battery-discharge-only", /screen-on\/off time[\s\S]{0,180}while discharging/i.test(src), "screen time collection scope is unclear");
    const routes = [
      ["navCpu", "pageCpu", "cpu"],
      ["navHome", "pageHome", "home"],
      ["navKernel", "pageKernel", "kernel"],
      ["navSettings", "pageSettings", "settings"],
      ["navMonitor", "pageMonitor", "monitor"]
    ];
    for (const [navId, pageId, key] of routes) {
      c.el(navId).fire("click");
      check("navigation opens " + key, c.el(pageId).style.display === "block" && c.el(navId).getAttribute("aria-current") === "page", "page/nav not active");
      const visible = ["pageHome", "pageCpu", "pageKernel", "pageMonitor", "pageSettings"].filter((id) => c.el(id).style.display === "block");
      check("navigation leaves exactly one page visible after " + key, visible.length === 1 && visible[0] === pageId, visible.join(","));
      await c.flush();
    }
    check("entering Monitor starts one additional read-only hardware sample", c.calls.length === before + 1 && c.sent(/monitor\.sh snapshot/) === 2, "before=" + before + " after=" + c.calls.length + " calls=" + c.calls.join(" | "));
    check("live monitor shows all three POCO F6 CPU policies", c.el("hwCpuCards").children.length === 3, "cards=" + c.el("hwCpuCards").children.length);
    check("live monitor includes GPU and battery cards", !!c.el("hwGpuCard") && !!c.el("hwBatteryCard"), "missing card");
    const monitorPageSource = src.slice(src.indexOf('id="pageMonitor"'), src.indexOf('id="pageSettings"', src.indexOf('id="pageMonitor"')));
    check("How to read explainer is removed from Monitor", !/How to read this/.test(monitorPageSource), "explainer still appears");
    check("CPU current frequency is displayed independently", c.el("hwCpuFrequency_0").textContent === "1018 MHz", c.el("hwCpuFrequency_0").textContent);
    check("CPU utilization always occupies a separate non-wrapping value", c.el("hwCpuUtilization_0").textContent === "—%" && /hw-usage/.test(src) && /white-space:nowrap;overflow-wrap:normal/.test(src), c.el("hwCpuUtilization_0").textContent);
    check("CPU active min/max limits, not hardware maxima, are displayed", c.el("hwCpuMin_0").textContent === "595.2 MHz" && c.el("hwCpuMax_0").textContent === "1017.6 MHz", c.el("hwCpuMin_0").textContent + " / " + c.el("hwCpuMax_0").textContent);
    check("temperature badge uses blue Normal below 38C", c.el("hwCpuStatus_0").textContent === "Normal" && c.el("hwCpuStatus_0").className.indexOf("hw-temp-normal") >= 0, c.el("hwCpuStatus_0").className);
    check("temperature badge uses yellow Warm at 50C SoC temperature", c.el("hwCpuStatus_1").textContent === "Warm" && c.el("hwCpuStatus_1").className.indexOf("hw-temp-warm") >= 0, c.el("hwCpuStatus_1").className);
    check("temperature badge uses red Hot at 75C SoC temperature", c.el("hwCpuStatus_2").textContent === "Hot" && c.el("hwCpuStatus_2").className.indexOf("hw-temp-hot") >= 0, c.el("hwCpuStatus_2").className);
    const warmSoc45 = await load({ handler: (cmd, def) => { const r = def(cmd); return /monitor\.sh snapshot/.test(cmd) ? ok(r.stdout.replace("thermal_3_raw=75000", "thermal_3_raw=45000")) : r; } });
    warmSoc45.el("navMonitor").fire("click"); await warmSoc45.flush();
    check("45C SoC temperature is Warm rather than a false Hot alert", warmSoc45.el("hwCpuStatus_2").textContent === "Warm", warmSoc45.el("hwCpuStatus_2").textContent);
    check("GPU frequency and utilization are displayed in separately labelled values", c.el("hwGpuFrequency").textContent === "684 MHz" && c.el("hwGpuUtilization").textContent === "27%" && c.el("hwGpuMin").textContent === "255 MHz" && c.el("hwGpuMax").textContent === "736 MHz", c.el("hwGpuFrequency").textContent + " / " + c.el("hwGpuUtilization").textContent);
    check("GPU frequency, utilization and temperature labels match their value fields", /<div class="hw-label">Frequency<\/div><div class="hw-value" id="hwGpuFrequency">/.test(src) && /<div class="hw-label">Utilization<\/div><div class="hw-value" id="hwGpuUtilization">/.test(src) && /<div class="hw-label">Temperature<\/div><div class="hw-value hw-temperature-value" id="hwGpuTemperature">/.test(src), "GPU metric label mismatch");
    check("compact card sizing applies equally to nested CPU cards and the GPU card", /\.hw-hardware-grid \.hw-card\{min-width:0;margin:0;padding:12px;border-radius:15px\}/.test(src) && !/\.hw-hardware-grid>\.hw-card\{/.test(src), "GPU-only sizing selector remains");
    check("battery charge uses its own state and color class", c.el("hwBatteryStatus").textContent === "Normal" && c.el("hwBatteryStatus").className.indexOf("hw-charge-normal") >= 0, c.el("hwBatteryStatus").className);
    check("battery temperature has its own temperature badge", c.el("hwBatteryTempStatus").textContent === "Normal" && c.el("hwBatteryTemperature").textContent === "30.6°C", c.el("hwBatteryTempStatus").textContent + " / " + c.el("hwBatteryTemperature").textContent);
    const warmBattery = await load({ handler: (cmd, def) => { const r = def(cmd); return /monitor\.sh snapshot/.test(cmd) ? ok(r.stdout.replace("battery_temp=306", "battery_temp=400")) : r; } });
    warmBattery.el("navMonitor").fire("click"); await warmBattery.flush();
    check("battery temp remains Warm at 40C", warmBattery.el("hwBatteryTempStatus").textContent === "Warm", warmBattery.el("hwBatteryTempStatus").textContent);
    const hotBattery = await load({ handler: (cmd, def) => { const r = def(cmd); return /monitor\.sh snapshot/.test(cmd) ? ok(r.stdout.replace("battery_temp=306", "battery_temp=450")) : r; } });
    hotBattery.el("navMonitor").fire("click"); await hotBattery.flush();
    check("battery temp becomes Hot at 45C", hotBattery.el("hwBatteryTempStatus").textContent === "Hot", hotBattery.el("hwBatteryTempStatus").textContent);
    check("battery power prefers the kernel-reported power_now value", c.el("hwBatteryPower").textContent === "2 W", c.el("hwBatteryPower").textContent);
    c.el("homeProfiles").fire("click");
    check("Home quick access opens CPU and GPU", c.el("pageCpu").style.display === "block", c.el("pageCpu").style.display);
    c.el("topSettings").fire("click");
    check("header gear opens Settings", c.el("pageSettings").style.display === "block", c.el("pageSettings").style.display);
    c.el("homeMonitor").fire("click"); await c.flush();
    check("Home Live Monitoring card opens Monitor", c.el("pageMonitor").style.display === "block", c.el("pageMonitor").style.display);
    check("Home Live Monitoring card starts the same sampler", c.sent(/monitor\.sh snapshot/) === 3, "samples=" + c.sent(/monitor\.sh snapshot/));
    c.el("navHome").fire("click");
    c.el("homeOpenMonitor").fire("click"); await c.flush();
    check("Home Details shortcut still opens Monitor", c.el("pageMonitor").style.display === "block", c.el("pageMonitor").style.display);
    check("Monitor navigation starts a fresh sample after Home shortcuts", c.sent(/monitor\.sh snapshot/) === 4, "samples=" + c.sent(/monitor\.sh snapshot/));
  }
  // 12. vendor-independent GPU counter fallback and battery charge thresholds
  {
    let snapshotCount = 0;
    const g = await load({ handler: (cmd, def) => {
      const result = def(cmd);
      if (/monitor\.sh snapshot/.test(cmd)) {
        snapshotCount++;
        const counters = snapshotCount === 1 ? "100 200" : "150 300";
        return ok(result.stdout.replace("gpu_busy_pct=27 %\n", "gpu_busy_counters=" + counters + "\n"));
      }
      return result;
    }});
    g.el("navMonitor").fire("click"); await g.flush();
    check("GPU busy counter fallback waits for a second sample", g.el("hwGpuFrequency").textContent === "684 MHz" && g.el("hwGpuUtilization").textContent === "—%", g.el("hwGpuFrequency").textContent + " / " + g.el("hwGpuUtilization").textContent);
    await g.advance(5000);
    check("GPU busy counter fallback calculates utilization from delta", g.el("hwGpuFrequency").textContent === "684 MHz" && g.el("hwGpuUtilization").textContent === "50%", g.el("hwGpuFrequency").textContent + " / " + g.el("hwGpuUtilization").textContent);
    g.el("navHome").fire("click");

    const powerFallback = await load({ handler: (cmd, def) => {
      const result = def(cmd);
      if (/monitor\.sh snapshot/.test(cmd)) return ok(result.stdout.replace("battery_power_now=2000000\n", ""));
      return result;
    }});
    powerFallback.el("navMonitor").fire("click"); await powerFallback.flush();
    check("battery power falls back to current × voltage when power_now is missing", powerFallback.el("hwBatteryPower").textContent === "1.63 W", powerFallback.el("hwBatteryPower").textContent);
    powerFallback.el("navHome").fire("click");

    const powerMismatch = await load({ handler: (cmd, def) => {
      const result = def(cmd);
      if (/monitor\.sh snapshot/.test(cmd)) return ok(result.stdout
        .replace("battery_current_now=-400000", "battery_current_now=-165000")
        .replace("battery_voltage_now=4084000", "battery_voltage_now=4084000")
        .replace("battery_power_now=2000000", "battery_power_now=10000000"));
      return result;
    }});
    powerMismatch.el("navMonitor").fire("click"); await powerMismatch.flush();
    check("battery power sanity check rejects a >4x power_now mismatch", powerMismatch.el("hwBatteryPower").textContent === "0.67 W", powerMismatch.el("hwBatteryPower").textContent);
    powerMismatch.el("navHome").fire("click");

    for (const [capacity, label, cls] of [[19, "Low battery", "hw-charge-low"], [20, "Normal", "hw-charge-normal"], [80, "Nearly full", "hw-charge-full"]]) {
      const b = await load({ handler: (cmd, def) => {
        const result = def(cmd);
        if (/monitor\.sh snapshot/.test(cmd)) return ok(result.stdout.replace("battery_capacity=68", "battery_capacity=" + capacity));
        return result;
      }});
      b.el("navMonitor").fire("click"); await b.flush();
      check("battery charge threshold at " + capacity + "%", b.el("hwBatteryStatus").textContent === label && b.el("hwBatteryStatus").className.indexOf(cls) >= 0, b.el("hwBatteryStatus").textContent + " / " + b.el("hwBatteryStatus").className);
      b.el("navHome").fire("click");
    }
  }
  // Drain rates are now generated by the persistent daemon; the WebUI only displays durable cache results.
  {
    const disk = { active_rate: "4.2", active_time: "1700000000000", idle_rate: "1.8", idle_time: "1700000000000", active_charge_uah: "222222.222222", active_current_ms: "2000000", idle_charge_uah: "44444.444444", idle_current_ms: "2000000", effective_capacity_uah: "4425000", screen_on_ms: "3600000", screen_off_ms: "5400000", monitor_enabled: "1", sampling_interval: "30", reset_on_charging: "1", generation: "0", reset_time: "0", last_charger: "disconnected" };
    const handler = (cmd, def) => {
      if (/monitor-cache\.sh get/.test(cmd)) return ok(Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n");
      return def(cmd);
    };
    const c = await load({ now: 1700000005000, handler });
    await c.flush();
    check("background daemon cache restores active average current without foreground sampling", c.el("hwBatteryActiveDrain").textContent === "400 mA", c.el("hwBatteryActiveDrain").textContent);
    check("background daemon cache restores idle average current independently", c.el("hwBatteryIdleDrain").textContent === "80 mA", c.el("hwBatteryIdleDrain").textContent);
    check("active card labels whole-cycle average and optional rate", /Whole-cycle average/.test(c.el("hwBatteryActiveSub").textContent) && /Estimated drain 9%\/h/.test(c.el("hwBatteryActiveSub").textContent), c.el("hwBatteryActiveSub").textContent);
    check("idle card uses its own capacity conversion", /Estimated drain 1.8%\/h/.test(c.el("hwBatteryIdleSub").textContent), c.el("hwBatteryIdleSub").textContent);
    check("saved screen-on time is restored from the persistent cache", c.el("hwBatteryScreenOnTime").textContent === "1h 0m", c.el("hwBatteryScreenOnTime").textContent);
    check("saved screen-off time is restored independently", c.el("hwBatteryScreenOffTime").textContent === "1h 30m", c.el("hwBatteryScreenOffTime").textContent);
    check("legacy percentage rates are not used as the primary average-current value", c.el("hwBatteryActiveDrain").textContent.indexOf("%/h") < 0 && c.el("hwBatteryIdleDrain").textContent.indexOf("%/h") < 0, c.el("hwBatteryActiveDrain").textContent + " / " + c.el("hwBatteryIdleDrain").textContent);
    check("WebUI does not create screen-off sampling baselines", !c.store.has("kprofiles-ui-monitor-idle-baseline-v1"), Array.from(c.store.keys()).join(","));
  }
  // Malformed or physically implausible data on one side is not used; the other state remains independent.
  {
    const disk = { active_charge_uah: "999999999999", active_current_ms: "1", idle_charge_uah: "22.222222", idle_current_ms: "1000", effective_capacity_uah: "4425000", screen_on_ms: "10", screen_off_ms: "10", generation: "0", monitor_enabled: "1", sampling_interval: "30", reset_on_charging: "1" };
    const c = await load({ handler: (cmd, def) => (/monitor-cache\.sh get/.test(cmd) ? ok(Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n") : def(cmd)) });
    await c.flush();
    check("physically implausible active current is not displayed", c.el("hwBatteryActiveDrain").textContent === "Collecting data", c.el("hwBatteryActiveDrain").textContent);
    check("valid idle current remains visible when active current data is invalid", c.el("hwBatteryIdleDrain").textContent === "80 mA", c.el("hwBatteryIdleDrain").textContent);
    check("an invalid active metric cannot contaminate the idle metric", /Whole-cycle average/.test(c.el("hwBatteryIdleSub").textContent) && c.el("hwBatteryIdleSub").textContent.indexOf("Collecting data") < 0, c.el("hwBatteryIdleSub").textContent);
  }
  {
    const c = await load({ handler: (cmd, def) => (/control\.sh status/.test(cmd) ? { errno: 1, stdout: "", stderr: "sh: control.sh: not found" } : def(cmd)) });
    check("controller status unreadable: shown as Unknown, not as Module presets", c.el("controlSourcePill").textContent === "Unknown", c.el("controlSourcePill").textContent);
    check("controller status unreadable: the CPU/GPU profile buttons stay locked", c.usable().filter((e) => e.hasAttribute("data-preset")).length === 0, "a profile button is usable");
    check("controller status unreadable: Reset everything stays available", c.el("resetAll").disabled === false, "Reset is disabled");
    const empty = await load({ handler: (cmd, def) => (/control\.sh status/.test(cmd) ? ok("") : def(cmd)) });
    check("empty controller response is Unknown, not assumed Module presets", empty.el("controlSourcePill").textContent === "Unknown", empty.el("controlSourcePill").textContent);
    check("empty controller response keeps tuning profiles locked", empty.doc.all.filter((e) => e.hasAttribute("data-preset") || e.hasAttribute("data-kp")).every((e) => e.disabled), "a tuning control was enabled");
    const legacy = await load({ handler: (cmd, def) => (/control\.sh status/.test(cmd) ? ok("source=legacy\nsource_message=not initialized\n") : def(cmd)) });
    check("legacy controller state is a choice conflict, not Module presets", legacy.el("controlSourcePill").textContent === "Choose one" && legacy.el("controlSourceConflict").style.display === "block", legacy.el("controlSourcePill").textContent);
    check("legacy conflict leaves controller choices available for explicit resolution", !legacy.el("sourceModuleBtn").disabled && !legacy.el("sourceKernelBtn").disabled, "controller choice buttons are disabled");
  }
  {
    const now = 1005000;
    const c = await load({ now, storage: {
      "kprofiles-ui-monitor-active-rate-v1": JSON.stringify({ rate: 4.2, t: 1000000 }),
      "kprofiles-ui-monitor-idle-rate-v1": JSON.stringify({ rate: 1.8, t: 1000000 })
    }});
    c.el("navMonitor").fire("click"); await c.flush();
    check("legacy localStorage rate is not mislabelled as average current", c.el("hwBatteryActiveDrain").textContent === "Collecting data", c.el("hwBatteryActiveDrain").textContent);
    check("legacy active rate is shown only as secondary context", /previous rate 4.2%\/h/.test(c.el("hwBatteryActiveSub").textContent), c.el("hwBatteryActiveSub").textContent);
    check("legacy idle rate is not mislabelled as average current", c.el("hwBatteryIdleDrain").textContent === "Collecting data", c.el("hwBatteryIdleDrain").textContent);
  }
  // Durable cache must restore the last real rates even when a manager WebView starts with empty localStorage.
  {
    const disk = { active_rate: "4.2", active_time: "1000000", idle_rate: "1.8", idle_time: "1000000" };
    const handler = (cmd, def) => {
      if (/monitor-cache\.sh get/.test(cmd)) return ok(Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n");
      if (/monitor-cache\.sh set-(active|idle)/.test(cmd)) {
        const m = cmd.match(/set-(active|idle) ([0-9.]+) ([0-9]+)/);
        if (m) { disk[m[1] + "_rate"] = m[2]; disk[m[1] + "_time"] = m[3]; }
        return ok("");
      }
      return def(cmd);
    };
    const first = await load({ now: 1005000, handler });
    await first.flush();
    first.el("navMonitor").fire("click"); await first.flush();
    check("rate-only durable cache does not fabricate an active mA average", first.el("hwBatteryActiveDrain").textContent === "Collecting data", first.el("hwBatteryActiveDrain").textContent);
    check("rate-only durable cache does not fabricate an idle mA average", first.el("hwBatteryIdleDrain").textContent === "Collecting data", first.el("hwBatteryIdleDrain").textContent);
    const reopened = await load({ now: 1006000, handler });
    await reopened.flush();
    reopened.el("navMonitor").fire("click"); await reopened.flush();
    check("legacy active rate remains secondary after reopening the WebUI", /previous rate 4.2%\/h/.test(reopened.el("hwBatteryActiveSub").textContent), reopened.el("hwBatteryActiveSub").textContent);
    check("legacy idle rate remains secondary after reopening the WebUI", /previous rate 1.8%\/h/.test(reopened.el("hwBatteryIdleSub").textContent), reopened.el("hwBatteryIdleSub").textContent);
  }
  // A failed durable-cache read must not look like fresh zero totals or silently imply a reset.
  {
    const c = await load({ handler: (cmd, def) => (/monitor-cache\.sh get/.test(cmd) ? { errno: 1, stdout: "", stderr: "cache read failed" } : def(cmd) ) });
    await c.flush();
    check("failed cache read shows screen-on time as Unavailable, not 0m", c.el("hwBatteryScreenOnTime").textContent === "Unavailable", c.el("hwBatteryScreenOnTime").textContent);
    check("failed cache read shows screen-off time as Unavailable, not 0m", c.el("hwBatteryScreenOffTime").textContent === "Unavailable", c.el("hwBatteryScreenOffTime").textContent);
    check("failed cache read does not claim the drain data is still collecting", c.el("hwBatteryActiveDrain").textContent === "Unavailable" && c.el("hwBatteryIdleDrain").textContent === "Unavailable", c.el("hwBatteryActiveDrain").textContent + " / " + c.el("hwBatteryIdleDrain").textContent);
  }
  // Settings are stored in the durable cache and manual reset clears only drain data.
  {
    const disk = { active_rate: "4.2", active_time: "1700000000000", idle_rate: "1.8", idle_time: "1700000000000", screen_on_ms: "3600000", screen_off_ms: "5400000", monitor_enabled: "1", sampling_interval: "30", reset_on_charging: "1", generation: "0", reset_time: "0", last_charger: "disconnected" };
    const serialize = () => Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n";
    const handler = (cmd, def) => {
      if (/monitor-cache\.sh get/.test(cmd)) return ok(serialize());
      let m;
      if ((m = cmd.match(/monitor-cache\.sh set-enabled ([01])/))) { disk.monitor_enabled = m[1]; return ok(""); }
      if ((m = cmd.match(/monitor-cache\.sh set-interval (15|30|60)/))) { disk.sampling_interval = m[1]; return ok(""); }
      if ((m = cmd.match(/monitor-cache\.sh set-reset-on-charging ([01])/))) { disk.reset_on_charging = m[1]; return ok(""); }
      if (/monitor-cache\.sh reset-screen-on-time/.test(cmd)) {
        disk.screen_on_ms = "0";
        disk.generation = String(Number(disk.generation) + 1); disk.reset_time = "1700000006000"; return ok("");
      }
      if (/monitor-cache\.sh reset-data/.test(cmd)) {
        disk.active_rate = ""; disk.active_time = ""; disk.idle_rate = ""; disk.idle_time = "";
        disk.screen_on_ms = "0"; disk.screen_off_ms = "0";
        disk.active_charge_uah = "0"; disk.active_current_ms = "0"; disk.idle_charge_uah = "0"; disk.idle_current_ms = "0"; disk.effective_capacity_uah = "";
        disk.generation = String(Number(disk.generation) + 1); disk.reset_time = "1700000006000"; return ok("");
      }
      return def(cmd);
    };
    const c = await load({ now: 1700000005000, handler });
    await c.flush();
    check("Battery Monitor settings default to 30 seconds", c.el("bmInterval30").getAttribute("aria-pressed") === "true" && c.el("bmIntervalLabel").textContent === "Current: 30 seconds", c.el("bmIntervalLabel").textContent);
    check("reset-on-charging defaults ON", c.el("bmResetChargeToggle").checked === true, String(c.el("bmResetChargeToggle").checked));
    c.el("bmInterval60").fire("click"); await c.flush();
    check("60-second interval is persisted", disk.sampling_interval === "60" && c.el("bmInterval60").getAttribute("aria-pressed") === "true", serialize());
    c.el("bmMonitorToggle").checked = false; c.el("bmMonitorToggle").fire("change"); await c.flush();
    check("background monitoring toggle persists OFF", disk.monitor_enabled === "0", serialize());
    c.el("bmResetChargeToggle").checked = false; c.el("bmResetChargeToggle").fire("change"); await c.flush();
    check("reset-on-charging toggle persists OFF", disk.reset_on_charging === "0", serialize());
    check("SOT reset button exists in Settings and on the SOT card", !!c.el("bmResetSot") && !!c.el("hwResetSotMini"), "one or both SOT reset buttons missing");
    c.el("bmResetSot").fire("click"); await c.flush();
    check("SOT-only reset asks for confirmation", c.confirms.length === 1 && /Only the saved screen-on time/.test(c.confirms[0]), c.confirms.join(" | "));
    check("SOT-only reset clears the on-time display", disk.screen_on_ms === "0" && c.el("hwBatteryScreenOnTime").textContent === "0m", disk.screen_on_ms + "/" + c.el("hwBatteryScreenOnTime").textContent);
    check("SOT-only reset preserves screen-off time and drain rates", disk.screen_off_ms === "5400000" && disk.active_rate === "4.2" && disk.idle_rate === "1.8", serialize());
    check("SOT-only reset uses the generation guard", disk.generation === "1", disk.generation);
    c.el("bmResetData").fire("click"); await c.flush();
    check("manual Reset data asks for confirmation", c.confirms.length === 2 && /Android battery statistics/.test(c.confirms[1]), c.confirms.join(" | "));
    check("manual Reset clears both saved drain rates and timestamps", !disk.active_rate && !disk.active_time && !disk.idle_rate && !disk.idle_time && c.el("hwBatteryActiveDrain").textContent === "Collecting data" && c.el("hwBatteryIdleDrain").textContent === "Collecting data", serialize());
    check("manual Reset also clears both screen-time totals", disk.screen_on_ms === "0" && disk.screen_off_ms === "0" && c.el("hwBatteryScreenOnTime").textContent === "0m" && c.el("hwBatteryScreenOffTime").textContent === "0m", serialize());
    check("manual Reset increments cache generation to prevent stale writes", disk.generation === "2", disk.generation);
    check("manual Reset preserves monitor preferences", disk.monitor_enabled === "0" && disk.sampling_interval === "60" && disk.reset_on_charging === "0", serialize());
  }
  {
    const disk = { active_rate: "4.2", active_time: "1700000000000", idle_rate: "1.8", idle_time: "1700000000000", screen_on_ms: "3600000", screen_off_ms: "5400000", monitor_enabled: "1", sampling_interval: "30", reset_on_charging: "1", generation: "0", reset_time: "0", last_charger: "disconnected" };
    const handler = (cmd, def) => {
      if (/monitor-cache\.sh get/.test(cmd)) return ok(Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n");
      if (/monitor-cache\.sh reset-data/.test(cmd)) return { errno: 1, stdout: "", stderr: "write denied" };
      return def(cmd);
    };
    const c = await load({ now: 1700000005000, confirm: false, handler });
    await c.flush();
    c.el("bmResetData").fire("click"); await c.flush();
    check("cancelled manual Reset sends no reset command", c.sent(/monitor-cache\.sh reset-data/) === 0, c.calls.join(" | "));
    c.el("hwResetSotMini").fire("click"); await c.flush();
    check("cancelled SOT-card Reset sends no reset command", c.sent(/monitor-cache\.sh reset-screen-on-time/) === 0, c.calls.join(" | "));
    check("cancelled manual Reset does not fabricate a current average", c.el("hwBatteryActiveDrain").textContent === "Collecting data", c.el("hwBatteryActiveDrain").textContent);
  }
  // The compact SOT-card reset button uses the same isolated reset path as Settings.
  {
    const disk = { active_rate: "4.2", active_time: "1700000000000", idle_rate: "1.8", idle_time: "1700000000000", screen_on_ms: "3600000", screen_off_ms: "5400000", monitor_enabled: "1", sampling_interval: "30", reset_on_charging: "1", generation: "0", reset_time: "0", last_charger: "disconnected" };
    const serialize = () => Object.keys(disk).map((k) => k + "=" + disk[k]).join("\n") + "\n";
    const handler = (cmd, def) => {
      if (/monitor-cache\.sh get/.test(cmd)) return ok(serialize());
      if (/monitor-cache\.sh reset-screen-on-time/.test(cmd)) {
        disk.screen_on_ms = "0"; disk.generation = String(Number(disk.generation) + 1); return ok("");
      }
      return def(cmd);
    };
    const c = await load({ now: 1700000005000, handler }); await c.flush();
    c.el("hwResetSotMini").fire("click"); await c.flush();
    check("SOT-card Reset successfully invokes the isolated reset command", c.sent(/monitor-cache\.sh reset-screen-on-time/) === 1, c.calls.join(" | "));
    check("SOT-card Reset clears only screen-on total", disk.screen_on_ms === "0" && c.el("hwBatteryScreenOnTime").textContent === "0m" && disk.screen_off_ms === "5400000", serialize());
    check("SOT-card Reset leaves valid active/idle rates intact", disk.active_rate === "4.2" && disk.idle_rate === "1.8", serialize());
  }
  // Frequency selectors are read-only for built-in profiles; Custom stages edits and submits one batch.
  {
    const ph = livePhone("tilt");
    const c = await load({ handler: ph.handler }); await c.flush();
    const pickerIds = ["sel-on-little-min", "sel-on-little-max", "sel-off-gpu-max"];
    check("built-in preset locks frequency selectors", pickerIds.every((id) => c.el(id).disabled), pickerIds.map((id) => id + "=" + c.el(id).disabled).join(","));
    check("Save & Apply stays disabled under built-in presets", c.el("saveApplyCustom").disabled === true, String(c.el("saveApplyCustom").disabled));
    clickPreset(c, "custom"); await c.flush(); await c.advance(9000);
    check("Custom unlocks frequency selectors after the profile cooldown", pickerIds.every((id) => !c.el(id).disabled), pickerIds.map((id) => id + "=" + c.el(id).disabled).join(","));
    const cfgBefore = c.sent(/tune\.sh cfg /);
    c.el("sel-on-little-max").value = "787200"; c.el("sel-on-little-max").fire("change"); await c.flush();
    check("editing a selector does not apply it immediately", c.sent(/tune\.sh cfg /) === cfgBefore && c.sent(/tune\.sh custom-save/) === 0, c.calls.filter((x) => /tune\.sh (cfg|custom-save)/.test(x)).join(" | "));
    check("pending edits enable Save & Apply", c.el("saveApplyCustom").disabled === false && /Unsaved custom changes/.test(c.el("customDraftStatus").textContent), c.el("customDraftStatus").textContent);
    c.el("saveApplyCustom").fire("click"); await c.flush();
    const batch = c.calls.find((x) => /tune\.sh custom-save /.test(x)) || "";
    const batchArgs = batch.replace(/^.*tune\.sh custom-save /, "").trim().split(/\s+/);
    check("Save & Apply sends one batch containing all 16 key/value pairs", !!batch && batchArgs.length === 32, "arg count=" + batchArgs.length + " command=" + batch);
    check("Save & Apply submits the staged value and Default values", /ON_LITTLE_MAX 787200/.test(batch) && /OFF_GPU_MAX -/.test(batch), batch);
    check("successful batch clears the unsaved state", c.el("saveApplyCustom").disabled === true && !/Unsaved custom changes/.test(c.el("customDraftStatus").textContent), c.el("customDraftStatus").textContent);
  }
  {
    const ph = livePhone("tilt");
    const c = await load({ handler: ph.handler, confirm: false }); await c.flush();
    clickPreset(c, "custom"); await c.flush(); await c.advance(9000);
    c.el("sel-on-big-max").value = "2188800"; c.el("sel-on-big-max").fire("change"); await c.flush();
    const before = c.sent(/tune\.sh preset performance/);
    clickPreset(c, "performance"); await c.flush();
    check("switching profile asks before discarding unsaved custom edits", c.confirms.some((m) => /Discard unsaved Custom frequency edits/.test(m)), c.confirms.join(" | "));
    check("cancelled profile switch preserves Custom and its draft", ph.s.preset === "custom" && c.sent(/tune\.sh preset performance/) === before && /Unsaved custom changes/.test(c.el("customDraftStatus").textContent), ph.s.preset + "/" + c.calls.join(" | "));
  }
  process.exit(fail);
})().catch((e) => { console.log("FAIL the test itself crashed: " + (e && e.stack || e)); process.exit(1); });
