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
    if (/module\.prop/.test(cmd)) return ok("v3.0.0\n");
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
  process.exit(fail);
})().catch((e) => { console.log("FAIL the test itself crashed: " + (e && e.stack || e)); process.exit(1); });
