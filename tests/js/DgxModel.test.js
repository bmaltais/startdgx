const test = require("node:test")
const assert = require("node:assert")
const M = require("./load.js")

// A model row as the engine's model_record shapes it (demo/hosts/spark-a/status.json).
const row = (over) => Object.assign({
  error: "", fits: true, fit_reason: "", shared: false, recipe: "qwen3.8-27b-tensorfold", name: "Qwen3.8 27B", vendor: "qwen",
  runtime: "tensorfold", ctx: 131072, unit: "inactive", sub_state: "dead", port: 11436, endpoint: "http://127.0.0.1:11436/v1",
  observed: { load_seconds: 55, ram_used_gib: 27.9, gpu_used_gib: 0 }, ram_total_gib: 121.6, since_ms: null,
  expected_load_seconds: 6, expected_stop_seconds: 2, expected_remove_seconds: null
}, over)
const statusText = (models, over) => JSON.stringify(Object.assign({ models: models, share_error: "", last: null, ram_total_gib: 121.6, best: null }, over))

test("parseStatus keeps a well-formed status document", () => {
  const s = M.parseStatus(statusText({ "qwen3.8-27b-tensorfold": row() }))
  assert.strictEqual(s.models["qwen3.8-27b-tensorfold"].name, "Qwen3.8 27B")
  assert.strictEqual(s.ram_total_gib, 121.6)
  assert.deepStrictEqual(M.parseStatus(statusText({})).models, {})
})

test("parseStatus refuses what isn't the engine's status", () => {
  assert.strictEqual(M.parseStatus(""), null)
  assert.strictEqual(M.parseStatus("not json"), null)
  assert.strictEqual(M.parseStatus("[]"), null)
  assert.strictEqual(M.parseStatus(JSON.stringify({ models: [] })), null)
  assert.strictEqual(M.parseStatus(JSON.stringify({ models: { a: row({ recipe: "b" }) } })), null, "a row filed under another id")
  assert.strictEqual(M.parseStatus(JSON.stringify({ models: { "qwen3.8-27b-tensorfold": null } })), null)
})

test("modelState says what a model is doing, in the row's words", () => {
  const s = (over, pending) => { const r = M.modelState(row(over), pending); return r.kind + ": " + r.text }
  assert.strictEqual(s({ unit: "active" }), "running: Running")
  assert.strictEqual(s({ unit: "activating" }), "loading: Loading")
  assert.strictEqual(s({ unit: "deactivating" }), "stopping: Stopping")
  assert.strictEqual(s({ unit: "removing" }), "removing: Removing")
  assert.strictEqual(s({ unit: "inactive" }), "stopped: Stopped")
  assert.strictEqual(s({ unit: "failed", error: "The model exited while loading: CUDA error: out of memory" }),
    "failed: The model exited while loading: CUDA error: out of memory")
  assert.strictEqual(s({ unit: "failed" }), "failed: Failed to start")
  assert.strictEqual(s({ unit: "inactive", error: "Port 11436 is taken" }), "failed: Port 11436 is taken", "a start that failed and left it stopped")
  assert.strictEqual(s({ unit: "inactive", fits: false, fit_reason: "Not enough memory" }), "doesNotFit: Not enough memory")
  assert.strictEqual(s({ unit: "inactive", fits: false, fit_reason: "" }), "doesNotFit: Not enough memory")
  assert.strictEqual(s({ unit: "active", fits: false }), "running: Running", "a running model fits by definition")
})

test("modelState shows a setup in progress", () => {
  const setup = (install, over) => M.modelState(row(Object.assign({ unit: "installing", install: install }, over)))
  assert.deepStrictEqual(setup({ phase: "downloading", done_bytes: 1, total_bytes: 10, rate_bytes_s: 5 }), { kind: "installing", text: "Downloading" })
  assert.deepStrictEqual(setup({ phase: "waiting" }), { kind: "installing", text: "Waiting to download" })
  assert.deepStrictEqual(setup({ phase: "failed" }, { error: "No space left on device" }), { kind: "failed", text: "No space left on device" })
  assert.deepStrictEqual(setup({ phase: "failed" }), { kind: "failed", text: "Setup failed" })
})

test("modelState follows a click at once, until the host says otherwise", () => {
  assert.strictEqual(M.modelState(row({ unit: "inactive" }), "start").kind, "loading")
  assert.strictEqual(M.modelState(row({ unit: "failed" }), "start").kind, "loading")
  assert.strictEqual(M.modelState(row({ unit: "active" }), "stop").kind, "stopping")
  assert.strictEqual(M.modelState(row({ unit: "activating" }), "stop").kind, "stopping")
  assert.strictEqual(M.modelState(row({ unit: "active" }), "start").kind, "running", "the host is ahead of the click")
})

test("toggleAction: what the play/pause button does, and when it waits", () => {
  const t = (over, pending) => M.toggleAction(row(over), pending)
  assert.strictEqual(t({ unit: "active" }), "stop")
  assert.strictEqual(t({ unit: "activating" }), "stop", "a load can be stopped")
  assert.strictEqual(t({ unit: "inactive" }), "start")
  assert.strictEqual(t({ unit: "failed", error: "boom" }), "start", "a failed model can be tried again")
  assert.strictEqual(t({ unit: "inactive" }, "start"), "stop", "a start just asked for can be taken back")
  assert.strictEqual(t({ unit: "deactivating" }), null)
  assert.strictEqual(t({ unit: "removing" }), null)
  assert.strictEqual(t({ unit: "installing", install: { phase: "downloading" } }), null)
  assert.strictEqual(t({ unit: "inactive", fits: false }), null, "greyed out: not startable by any route")
  assert.strictEqual(M.startBlocked(row({ unit: "inactive", fits: false })), true)
  assert.strictEqual(M.startBlocked(row({ unit: "active", fits: false })), false)
  assert.strictEqual(M.startBlocked(row({ unit: "inactive" })), false)
  assert.strictEqual(M.startBlocked(row({ unit: "installing", fits: false, install: { phase: "downloading" } })), false, "a setup has no play button to grey out")
  assert.strictEqual(M.startBlocked(row({ unit: "deactivating", fits: false })), false)
})

test("phaseProgress runs to 90% at the expected time, then creeps toward 98%", () => {
  assert.strictEqual(M.phaseProgress(5, 10), 0.45)
  assert.strictEqual(M.phaseProgress(10, 10), 0.9)
  assert.ok(Math.abs(M.phaseProgress(20, 10) - 0.9506) < 0.0001)
  assert.ok(M.phaseProgress(1000, 10) <= 0.98 && M.phaseProgress(1000, 10) > 0.97)
  assert.strictEqual(M.phaseProgress(5, 0), 0)
})

test("download figures, in the decimal units downloads are counted in", () => {
  assert.strictEqual(M.downloadRate(312e6), "312 MB/s")
  assert.strictEqual(M.downloadRate(0), "")
  assert.strictEqual(M.downloadAmount(12.34e9, 40e9), "12.3 of 40.0 GB")
  assert.strictEqual(M.downloadAmount(5, 0), "")
})

test("meter: the bar under a model, and what it measures", () => {
  const now = 1_000_000
  assert.deepStrictEqual(M.meter(row({ unit: "active" }), now), { label: "Memory", fraction: 27.9 / 121.6, value: "28 of 122 GiB" })
  assert.deepStrictEqual(M.meter(row({ unit: "activating", since_ms: now - 3000 }), now), { label: "Loading", fraction: 0.45, value: "" })
  assert.deepStrictEqual(M.meter(row({ unit: "deactivating", since_ms: now - 1000 }), now), { label: "Stopping", fraction: 0.45, value: "" })
  assert.deepStrictEqual(M.meter(row({ unit: "removing", since_ms: now - 5000, expected_remove_seconds: null }), now), { label: "Removing", fraction: 0.45, value: "" }, "a removal with no history takes 10 s")
  assert.deepStrictEqual(M.meter(row({ unit: "inactive" }), now, "start"), { label: "Loading", fraction: 0, value: "" }, "a start just asked for")
  assert.deepStrictEqual(M.meter(row({ unit: "installing", install: { phase: "downloading", done_bytes: 4e9, total_bytes: 10e9, rate_bytes_s: 1.2e9 } }), now),
    { label: "Downloading", fraction: 0.4, value: "1200 MB/s" })
  assert.strictEqual(M.meter(row({ unit: "inactive" }), now), null)
  assert.strictEqual(M.meter(row({ unit: "failed" }), now), null)
  assert.strictEqual(M.meter(row({ unit: "active", observed: null }), now).fraction, 0, "running, not measured yet")
})

test("modelFacts: context, and the memory a stopped model takes once running", () => {
  assert.strictEqual(M.modelFacts(row({ unit: "inactive" })), "128K context · 28 GiB")
  assert.strictEqual(M.modelFacts(row({ unit: "active" })), "128K context", "the meter shows a running model's memory")
  assert.strictEqual(M.modelFacts(row({ unit: "inactive", observed: null, ctx: 262144 })), "256K context")
  assert.strictEqual(M.modelFacts(row({ unit: "installing", ctx: null, observed: null })), "")
})

const profile = { platform: "aarch64-gb10", ram_gib: 121.62, ram_class: 128,
  gpus: [{ vendor: "nvidia", family: "nvidia-gb10", unified: true, memory_gib: 121.62 }] }

test("parseHosts keeps the machines that were added, and refuses anything else", () => {
  const hosts = M.parseHosts(JSON.stringify({ "demo@spark-a": { profile: profile }, "spark-b": { profile: {} } }))
  assert.deepStrictEqual(Object.keys(hosts), ["demo@spark-a", "spark-b"])
  assert.deepStrictEqual(M.parseHosts("{}"), {})
  assert.strictEqual(M.parseHosts("[]"), null)
  assert.strictEqual(M.parseHosts("nope"), null)
  assert.strictEqual(M.parseHosts(JSON.stringify({ "demo@spark-a": "x" })), null)
})

test("hostName and hostLine name a machine the way a person would", () => {
  assert.strictEqual(M.hostName("demo@spark-a"), "spark-a")
  assert.strictEqual(M.hostName("gx10-f5f4"), "gx10-f5f4")
  assert.strictEqual(M.hostLine(profile), "DGX Spark · 128 GB")
  assert.strictEqual(M.hostLine(Object.assign({}, profile, { pair: { host: "spark-a", peer: "spark-b", ram_gib: 121.6 } })), "DGX Spark · 128 GB · cabled to spark-b")
  assert.strictEqual(M.hostLine({ platform: "x86_64", ram_class: 64, gpus: [] }), "x86_64 · 64 GB")
  assert.strictEqual(M.hostLine(null), "")
})

test("errorLine and lastLine: the one line the footer shows", () => {
  assert.strictEqual(M.errorLine("Traceback\nError: demo@spark-c didn't answer in time\n", "x"), "demo@spark-c didn't answer in time")
  assert.strictEqual(M.errorLine("  \n", "The action failed"), "The action failed")
  assert.strictEqual(M.errorLine("usage: startdgx\nstartdgx: error: argument host", "x"), "startdgx: error: argument host")
  assert.strictEqual(M.lastLine("Recipe x: 3 files\nStarted x at http://127.0.0.1:1/v1\n"), "Started x at http://127.0.0.1:1/v1")
  assert.strictEqual(M.lastLine(""), "")
})

test("offlineText says why a machine is away, and since when", () => {
  const now = 100 * 3600e3
  assert.strictEqual(M.offlineText("demo@spark-c didn't answer in time", 0, now), "demo@spark-c didn't answer in time")
  assert.strictEqual(M.offlineText("demo@spark-c didn't answer in time", now - 30e3, now), "demo@spark-c didn't answer in time · last seen just now")
  assert.strictEqual(M.offlineText("", now - 3 * 60e3, now), "Not answering · last seen 3 min ago")
  assert.strictEqual(M.offlineText("x", now - 2 * 3600e3, now), "x · last seen 2 h ago")
  assert.strictEqual(M.offlineText("x", now - 50 * 3600e3, now), "x · last seen 2 d ago")
})

test("modelList: a host's models in name order", () => {
  const s = M.parseStatus(statusText({ b: row({ recipe: "b", name: "Qwen" }), a: row({ recipe: "a", name: "Nemotron" }), c: row({ recipe: "c", name: "" }) }))
  assert.deepStrictEqual(M.modelList(s).map((e) => e.recipe), ["c", "a", "b"], "a model with no name sorts by its id")
  assert.deepStrictEqual(M.modelList(null), [])
})

test("names from a host pass through as they are: the QML draws them as plain text", () => {
  const s = M.parseStatus(statusText({ x: row({ recipe: "x", name: "<img src=x onerror=alert(1)>", error: "<b>bad</b>" }) }))
  assert.strictEqual(M.modelList(s)[0].name, "<img src=x onerror=alert(1)>")
  assert.strictEqual(M.modelState(M.modelList(s)[0]).text, "<b>bad</b>")
})

// One host's state as the service keeps it.
const up = (models, over) => Object.assign({ loaded: true, online: true, error: "", lastSeenMs: 1, status: M.parseStatus(statusText(models)) }, over)
const models = (...rows) => Object.fromEntries(rows.map((r) => [r.recipe, r]))
const a = row({ recipe: "a", name: "A", unit: "active" })
const b = row({ recipe: "b", name: "B", unit: "inactive" })

test("summarize counts machines and models, and picks the bar icon's state", () => {
  const s = M.summarize(["h1", "h2"], { h1: up(models(a, b)), h2: up(models(row({ recipe: "c", unit: "inactive" }))) })
  assert.deepStrictEqual([s.machines, s.offline, s.models, s.running, s.busy, s.failed, s.kind], [2, 0, 3, 1, 0, 0, "running"])
  assert.strictEqual(M.summarize([], {}).kind, "idle")
  assert.strictEqual(M.summarize(["h1"], { h1: up(models(b)) }).kind, "idle")
  assert.strictEqual(M.summarize(["h1"], { h1: up(models(a, row({ recipe: "l", unit: "activating" }))) }).kind, "busy")
  assert.strictEqual(M.summarize(["h1"], { h1: up(models(row({ recipe: "i", unit: "installing", install: { phase: "downloading" } }))) }).kind, "busy")
  assert.strictEqual(M.summarize(["h1"], { h1: up(models(a, row({ recipe: "f", unit: "failed" }))) }).kind, "alert")
  const away = M.summarize(["h1", "h2"], { h1: up(models(a)), h2: up({}, { online: false, error: "x" }) })
  assert.deepStrictEqual([away.offline, away.kind], [1, "alert"])
  assert.strictEqual(M.summarize(["h1"], {}).kind, "idle", "a machine not heard from yet is not an alert")
  assert.strictEqual(M.summarize(["h1"], { h1: up(models(a), { online: false }) }).running, 0, "an away machine's last models don't count as running")
})

test("subtitle: the manager's count line", () => {
  assert.strictEqual(M.subtitle(M.summarize([], {})), "NO MACHINES ADDED")
  assert.strictEqual(M.subtitle(M.summarize(["h1"], { h1: up(models(b)) })), "1 MACHINE · NOTHING RUNNING")
  assert.strictEqual(M.subtitle(M.summarize(["h1", "h2"], { h1: up(models(a, b)), h2: up({}, { online: false }) })), "2 MACHINES · 1 RUNNING · 1 NOT ANSWERING")
  assert.strictEqual(M.subtitle(M.summarize(["h1"], { h1: up(models(a, row({ recipe: "f", unit: "failed" }), row({ recipe: "g", unit: "failed" }))) })), "1 MACHINE · 1 RUNNING · 2 FAILED")
})

test("pollInterval: quick while you look or something moves, slow otherwise, slower for an away machine", () => {
  assert.strictEqual(M.pollInterval(true, up(models(b))), 2500)
  assert.strictEqual(M.pollInterval(false, up(models(b))), 60000)
  assert.strictEqual(M.pollInterval(false, up(models(row({ recipe: "l", unit: "activating" })))), 2500)
  assert.strictEqual(M.pollInterval(true, up({}, { online: false })), 10000)
  assert.strictEqual(M.pollInterval(false, up({}, { online: false })), 120000)
  assert.strictEqual(M.pollInterval(false, undefined), 2500, "not heard from yet")
})

// The demo's discover fixture (demo/discover.json), as `startdgx discover --json` prints it.
const peers = require("../../demo/discover.json")

test("parsePeers keeps discover's list, and refuses anything else", () => {
  assert.strictEqual(M.parsePeers(JSON.stringify(peers)).length, 8)
  assert.deepStrictEqual(M.parsePeers("[]"), [])
  assert.strictEqual(M.parsePeers("{}"), null)
  assert.strictEqual(M.parsePeers(JSON.stringify([{ name: "x" }])), null, "a peer with no target")
  assert.strictEqual(M.parsePeers("x"), null)
})

test("peerOffer: what the Add machine card offers for each machine of the tailnet", () => {
  const offer = (name, over) => M.peerOffer(Object.assign({}, peers.find((p) => p.name === name), over))
  assert.deepStrictEqual(offer("spark-d"), { action: "add", install: "", text: "DGX Spark · ready to add" })
  assert.deepStrictEqual(offer("spark-e"), { action: "install", install: "install", text: "DGX Spark · not set up yet" })
  assert.deepStrictEqual(offer("spark-c"), { action: null, install: "", text: "ssh: connect to host spark-c port 22: Connection timed out" })
  assert.deepStrictEqual(offer("workstation"), { action: null, install: "", text: "Not a DGX Spark" })
  assert.deepStrictEqual(offer("spark-a", { added: true }), { action: null, install: "", text: "Added" })
  assert.deepStrictEqual(offer("spark-c", { reason: null }), { action: null, install: "", text: "Not answering" })
})

test("peerOffer: a Spark with an engine startdgx didn't install can be added as it is, or installed over it", () => {
  const foreign = peers.find((p) => p.name === "spark-f")
  assert.deepStrictEqual([foreign.engine, foreign.installed], [true, false], "the demo has one")
  assert.deepStrictEqual(M.peerOffer(foreign), { action: "add", install: "replace",
    text: "DGX Spark · an engine startdgx didn't install is here; Install… backs it up first" })
})

test("rows: the keyboard cursor's list, each machine then its models, then Add model on one that answers", () => {
  const r = M.rows(["h1", "h2", "h3", "h4"], { h1: up(models(b, a)), h2: up({}), h3: undefined, h4: up(models(a), { online: false }) })
  assert.deepStrictEqual(r.map((x) => x.kind + ":" + x.host + (x.id ? "/" + x.id : "")),
    ["host:h1", "model:h1/a", "model:h1/b", "add:h1", "host:h2", "add:h2", "host:h3", "host:h4", "model:h4/a"])
})

test("keyAction: a key and the button it matches cannot disagree", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  const host = { kind: "host", host: "h1" }
  assert.deepStrictEqual(M.keyAction("r", null, null), { type: "refresh" })
  assert.deepStrictEqual(M.keyAction("n", null, null), { type: "addMachine" })
  assert.deepStrictEqual(M.keyAction("enter", model, a), { type: "stop", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("s", model, b), { type: "start", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("S", model, b), { type: "start", host: "h1", id: "a" })
  assert.strictEqual(M.keyAction("s", model, row({ unit: "inactive", fits: false })), null, "a greyed-out start")
  assert.deepStrictEqual(M.keyAction("s", model, b, "start"), { type: "stop", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("l", model, a), { type: "logs", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("l", host, null), { type: "logs", host: "h1", id: "" })
  assert.deepStrictEqual(M.keyAction("u", host, null), { type: "uninstall", host: "h1" })
  assert.deepStrictEqual(M.keyAction("f", host, null), { type: "forget", host: "h1" })
  assert.deepStrictEqual(M.keyAction("u", model, a), { type: "uninstall", host: "h1" }, "a model's row acts for its machine")
  assert.strictEqual(M.keyAction("enter", host, null), null)
  assert.strictEqual(M.keyAction("s", null, null), null)
  assert.strictEqual(M.keyAction("x", model, a), null)
})

test("keyAction: a machine that isn't answering has no Start, Stop or Logs, by key either", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  const host = { kind: "host", host: "h1" }
  assert.strictEqual(M.keyAction("s", model, a, "", true), null)
  assert.strictEqual(M.keyAction("enter", model, b, "", true), null)
  assert.strictEqual(M.keyAction("l", model, a, "", true), null)
  assert.strictEqual(M.keyAction("l", host, null, "", true), null)
  assert.deepStrictEqual(M.keyAction("u", host, null, "", true), { type: "uninstall", host: "h1" })
  assert.deepStrictEqual(M.keyAction("f", model, a, "", true), { type: "forget", host: "h1" })
  assert.deepStrictEqual(M.keyAction("r", host, null, "", true), { type: "refresh" })
})

test("alerts: a model that fails is said once, and again if it fails again", () => {
  const failed = row({ recipe: "f", name: "Nemotron", unit: "failed", error: "CUDA error: out of memory" })
  let r = M.alerts(["demo@h1"], { "demo@h1": up(models(a, failed)) }, {})
  assert.deepStrictEqual(r.list, [{ key: "demo@h1/f:CUDA error: out of memory", title: "Nemotron failed on h1", body: "CUDA error: out of memory" }])
  r = M.alerts(["demo@h1"], { "demo@h1": up(models(a, failed)) }, r.announced)
  assert.deepStrictEqual(r.list, [], "not again while it stays failed")
  r = M.alerts(["demo@h1"], { "demo@h1": up(models(a, row({ recipe: "f", unit: "inactive" }))) }, r.announced)
  assert.deepStrictEqual(r.announced, {})
  r = M.alerts(["demo@h1"], { "demo@h1": up(models(a, failed)) }, r.announced)
  assert.strictEqual(r.list.length, 1, "it failed again")
  const setup = row({ recipe: "g", name: "GPT", unit: "installing", install: { phase: "failed" }, error: "No space left" })
  assert.strictEqual(M.alerts(["h1"], { h1: up(models(setup)) }, {}).list[0].title, "GPT could not be set up on h1")
  const away = M.alerts(["h1"], { h1: up(models(failed), { online: false }) }, { "h1/f:CUDA error: out of memory": true })
  assert.deepStrictEqual([away.list, away.announced], [[], { "h1/f:CUDA error: out of memory": true }], "an away machine says nothing new and forgets nothing")
})

test("isAway: a machine that answered no, not one not heard from yet", () => {
  assert.strictEqual(M.isAway(up({}, { online: false })), true)
  assert.strictEqual(M.isAway(up({})), false)
  assert.strictEqual(M.isAway(undefined), false)
  assert.strictEqual(M.isAway({ loaded: false, online: false }), false)
})

// ---- adding and removing models (#6) ----

// A recipe as the engine's recipe_listing shapes it (demo/hosts/spark-a/list.json).
const recipe = (over) => Object.assign({
  id: "qwen3.8-27b-tensorfold", name: "Qwen3.8 27B", summary: "27B dense model, 4-bit.", runtime: "tensorfold", tier: "third-party",
  publisher: "Omacom", vendor: "qwen", architecture: "dense", installed: false, available: true, reason: "", best: false, active: false,
  memory_gib: 95, context: 262144, decode_tok_s: 52.7, prefill_tok_s: 1251.0
}, over)

test("parseRecipes keeps the engine's catalog listing, and refuses anything else", () => {
  const list = M.parseRecipes(JSON.stringify([recipe(), recipe({ id: "nemotron-3.5-bolt-tensorfold", name: "Nemotron 3.5 Bolt" })]))
  assert.deepStrictEqual(list.map((r) => r.id), ["qwen3.8-27b-tensorfold", "nemotron-3.5-bolt-tensorfold"])
  assert.deepStrictEqual(M.parseRecipes("[]"), [])
  assert.strictEqual(M.parseRecipes(""), null)
  assert.strictEqual(M.parseRecipes("{}"), null)
  assert.strictEqual(M.parseRecipes(JSON.stringify([recipe({ id: "" })])), null, "a recipe without an id")
  assert.strictEqual(M.parseRecipes(JSON.stringify([recipe({ id: 7 })])), null)
  assert.strictEqual(M.parseRecipes(JSON.stringify([null])), null)
})

test("recipeOffers: the picker's rows, best first, then what can be set up, then what can't", () => {
  const list = [
    recipe({ id: "glm-pair", name: "GLM-5.3 Flash", available: false, reason: "runtime tensorfold-glm53-pair can't run on nvidia-gb10", memory_gib: null }),
    recipe({ id: "nemotron", name: "Nemotron 3.5 Bolt", installed: true }),
    recipe({ id: "abliterated", name: "Qwen3.8 27B Abliterated" }),
    recipe({ id: "gufo", name: "Qwen3.8 27B", available: false, reason: "" }),
    recipe({ id: "flash", name: "Qwen3.8 Flash Next", best: true }),
    recipe({ id: "being-set-up", name: "Being Set Up" }),
  ]
  const status = { models: { nemotron: row({ recipe: "nemotron" }), "being-set-up": row({ recipe: "being-set-up", unit: "installing", install: { phase: "waiting" } }) } }
  const offers = M.recipeOffers(list, status)
  assert.deepStrictEqual(offers.map((o) => [o.recipe.id, o.action, o.text]), [
    ["flash", "use", "Recommended for this machine"],
    ["abliterated", "use", ""],
    ["being-set-up", null, "Being set up"],
    ["nemotron", null, "On this machine"],
    ["glm-pair", null, "runtime tensorfold-glm53-pair can't run on nvidia-gb10"],
    ["gufo", null, "Can't run on this machine"],
  ])
  assert.strictEqual(offers[0].best, true, "the engine's own best mark is kept")
  assert.strictEqual(offers[1].best, false)
})

test("recipeOffers: a model the engine reports installed is set up, even before its status row arrives", () => {
  const offers = M.recipeOffers([recipe({ id: "a", installed: true })], { models: {} })
  assert.deepStrictEqual([offers[0].action, offers[0].text], [null, "On this machine"])
  assert.deepStrictEqual(M.recipeOffers([recipe({ id: "a" })], null).map((o) => o.action), ["use"], "no status yet")
  assert.deepStrictEqual(M.recipeOffers(null, null), [])
})

test("recipeFacts: what a recipe needs and gives on this machine", () => {
  assert.strictEqual(M.recipeFacts(recipe()), "95 GiB memory · 256K context · 53 TPS")
  assert.strictEqual(M.recipeFacts(recipe({ decode_tok_s: null })), "95 GiB memory · 256K context")
  assert.strictEqual(M.recipeFacts(recipe({ memory_gib: null, context: null, decode_tok_s: null })), "")
})

test("withSetups: a model just asked for shows at once, waiting, until the machine lists it", () => {
  const hs = { loaded: true, online: true, error: "", status: { models: { nemotron: row({ recipe: "nemotron", name: "Nemotron" }) } }, lastSeenMs: 1 }
  const setups = { "h1/flash": recipe({ id: "flash", name: "Qwen3.8 Flash Next", vendor: "qwen" }), "h2/x": recipe({ id: "x" }) }
  const shown = M.withSetups({ h1: hs }, setups)
  const flash = shown.h1.status.models.flash
  assert.deepStrictEqual([flash.recipe, flash.name, flash.vendor, flash.unit, flash.install.phase], ["flash", "Qwen3.8 Flash Next", "qwen", "installing", "waiting"])
  assert.deepStrictEqual(M.modelState(flash), { kind: "installing", text: "Waiting to download" })
  assert.strictEqual(shown.h1.status.models.nemotron.name, "Nemotron", "the machine's own rows stay")
  assert.strictEqual(hs.status.models.flash, undefined, "the state it was given is left alone")
  assert.strictEqual(shown.h2, undefined, "a machine not heard from gets nothing")
  assert.deepStrictEqual(M.rows(["h1"], shown).map((r) => r.id || r.kind), ["host", "nemotron", "flash", "add"], "in name order, as the machine will list it")
  assert.strictEqual(M.summarize(["h1"], shown).busy, 1, "and counts as busy, so the machine is polled quickly")
})

test("withSetups: the machine's own row wins once it has one", () => {
  const real = row({ recipe: "flash", unit: "installing", install: { phase: "downloading", done_bytes: 5, total_bytes: 10, rate_bytes_s: 1 } })
  const hs = { loaded: true, online: true, status: { models: { flash: real } } }
  assert.strictEqual(M.withSetups({ h1: hs }, { "h1/flash": recipe({ id: "flash" }) }).h1.status.models.flash, real)
  assert.strictEqual(M.withSetups({ h1: hs }, {}).h1, hs, "nothing to add leaves the state as it is")
})

test("settleSetups: a setup is forgotten once its machine lists the model", () => {
  const setups = { "h1/flash": recipe({ id: "flash" }), "h1/other": recipe({ id: "other" }), "h2/flash": recipe({ id: "flash" }) }
  const next = M.settleSetups(setups, "h1", { models: { flash: row({ recipe: "flash", unit: "installing" }) } })
  assert.deepStrictEqual(Object.keys(next).sort(), ["h1/other", "h2/flash"])
  assert.strictEqual(M.settleSetups(setups, "h1", { models: {} }), setups, "nothing settled, nothing changed")
})

test("modelState and meter: a removal just asked for shows at once; a setup's is a cancel", () => {
  const now = 1_000_000
  assert.deepStrictEqual(M.modelState(row({ unit: "inactive" }), "delete"), { kind: "removing", text: "Removing" })
  assert.deepStrictEqual(M.modelState(row({ unit: "active" }), "delete"), { kind: "removing", text: "Removing" })
  const setup = row({ unit: "installing", install: { phase: "downloading", done_bytes: 4e9, total_bytes: 10e9, rate_bytes_s: 1e9 } })
  assert.deepStrictEqual(M.modelState(setup, "delete"), { kind: "removing", text: "Cancelling" })
  assert.deepStrictEqual(M.meter(setup, now, "delete"), { label: "Cancelling", fraction: 0, value: "" })
  assert.deepStrictEqual(M.meter(row({ unit: "inactive" }), now, "delete"), { label: "Removing", fraction: 0, value: "" })
  assert.strictEqual(M.toggleAction(row({ unit: "active" }), "delete"), null, "no Stop while it goes")
})

test("removeAction: what Remove does for a model, and when it waits", () => {
  assert.strictEqual(M.removeAction(row({ unit: "inactive" })), "remove")
  assert.strictEqual(M.removeAction(row({ unit: "active" })), "remove", "the engine stops it first")
  assert.strictEqual(M.removeAction(row({ unit: "failed" })), "remove")
  assert.strictEqual(M.removeAction(row({ unit: "inactive", fits: false })), "remove")
  assert.strictEqual(M.removeAction(row({ unit: "installing", install: { phase: "downloading" } })), "cancel")
  assert.strictEqual(M.removeAction(row({ unit: "installing", install: { phase: "failed" } }), ""), "cancel", "a failed setup is cleared the same way")
  assert.strictEqual(M.removeAction(row({ unit: "removing" })), null)
  assert.strictEqual(M.removeAction(row({ unit: "deactivating" })), null, "it waits for a stop to end")
  assert.strictEqual(M.removeAction(row({ unit: "inactive" }), "delete"), null, "asked already")
  assert.strictEqual(M.removeAction(row({ unit: "inactive" }), "start"), null, "a start on its way")
  assert.strictEqual(M.removeAction(null), null)
})

test("sizeText: sizes in the engine's binary units", () => {
  assert.strictEqual(M.sizeText(12.34 * 2 ** 30), "12.3 GiB")
  assert.strictEqual(M.sizeText(300 * 2 ** 20), "300.0 MiB")
  assert.strictEqual(M.sizeText(0), "0.0 MiB")
})

test("removeConfirm: the question, with the space it frees once that is known", () => {
  const m = row({ name: "Qwen3.8 27B", unit: "inactive" })
  assert.deepStrictEqual(M.removeConfirm(m, "demo@spark-a", 47.5 * 2 ** 30), {
    title: "Remove Qwen3.8 27B from spark-a?", button: "Remove", keep: "Keep it",
    body: "This deletes its weights, freeing 47.5 GiB that no other model uses. Setting it up again downloads them again." })
  assert.strictEqual(M.removeConfirm(row({ unit: "active" }), "h", 2 ** 30).body,
    "This stops the model and deletes its weights, freeing 1.0 GiB that no other model uses. Setting it up again downloads them again.")
  assert.strictEqual(M.removeConfirm(m, "h", 0).body, "This deletes it. Its weights are shared with another model, so no space is freed.")
  assert.strictEqual(M.removeConfirm(m, "h", null).body, "This deletes its weights. Asking the machine how much space that frees…")
  const setup = row({ name: "Qwen3.8 Flash Next", unit: "installing", install: { phase: "downloading" } })
  assert.deepStrictEqual(M.removeConfirm(setup, "demo@spark-b", 4.25 * 2 ** 30), {
    title: "Cancel the setup of Qwen3.8 Flash Next on spark-b?", button: "Cancel setup", keep: "Keep going",
    body: "This stops the download and deletes the 4.3 GiB downloaded so far." })
  assert.strictEqual(M.removeConfirm(setup, "h", 0).body, "This stops the setup. Nothing has been downloaded yet.")
})

test("parseRemovePlan: what delete --dry-run --json says a removal frees", () => {
  assert.deepStrictEqual(M.parseRemovePlan(JSON.stringify({ recipe: "a", setting_up: false, bytes: 1024 })), { recipe: "a", setting_up: false, bytes: 1024 })
  assert.strictEqual(M.parseRemovePlan(JSON.stringify({ recipe: "a", bytes: -1 })), null)
  assert.strictEqual(M.parseRemovePlan(JSON.stringify({ recipe: "a", bytes: "1" })), null)
  assert.strictEqual(M.parseRemovePlan("[]"), null)
  assert.strictEqual(M.parseRemovePlan("nope"), null)
})

test("keyAction: a adds a model to the machine, d removes the model under the cursor", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  const add = { kind: "add", host: "h1" }
  const host = { kind: "host", host: "h1" }
  assert.deepStrictEqual(M.keyAction("a", host, null), { type: "addModel", host: "h1" })
  assert.deepStrictEqual(M.keyAction("a", model, a), { type: "addModel", host: "h1" })
  assert.deepStrictEqual(M.keyAction("enter", add, null), { type: "addModel", host: "h1" })
  assert.deepStrictEqual(M.keyAction("d", model, b), { type: "removeModel", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("delete", model, a), { type: "removeModel", host: "h1", id: "a" })
  assert.strictEqual(M.keyAction("d", model, row({ unit: "removing" })), null)
  assert.strictEqual(M.keyAction("d", host, null), null)
  assert.strictEqual(M.keyAction("a", host, null, "", true), null, "a machine that isn't answering has no picker")
  assert.strictEqual(M.keyAction("d", model, b, "", true), null)
  assert.deepStrictEqual(M.keyAction("u", add, null), { type: "uninstall", host: "h1" }, "the Add model row acts for its machine")
})

test("removeConfirm: when the machine can't say how much it frees, the question stands without the figure", () => {
  assert.strictEqual(M.removeConfirm(row({ unit: "inactive" }), "h", null, true).body, "This deletes its weights.")
  assert.strictEqual(M.removeConfirm(row({ unit: "installing", install: { phase: "waiting" } }), "h", null, true).body,
    "This stops the download and deletes what it downloaded.")
})

test("meter: a setup still waiting has an empty bar that says so, and no speed yet", () => {
  assert.deepStrictEqual(M.meter(row({ unit: "installing", install: { phase: "waiting", done_bytes: 0, total_bytes: 0, rate_bytes_s: 1.2e9 } }), 0),
    { label: "Waiting", fraction: 0, value: "" })
})

// ---- a machine's two command slots: a start, and anything else ----

const act = (op, kind, id) => ({ op: op, key: "h1/" + (id || "a"), kind: kind, shows: kind })
// Submit, then launch what can run, as the poller does after each click.
const click = (q, action, entry) => {
  const s = M.submit(q, action, entry || row({ recipe: "a", unit: "inactive" }))
  const l = M.launch(s.queue)
  return { queue: l.queue, run: l.run, dropped: s.dropped }
}

test("a stop runs beside a start that is still loading, and supersedes it", () => {
  let r = click(M.newQueue(), act(1, "start"))
  assert.deepStrictEqual(r.run.map((a) => a.kind), ["start"])
  r = click(r.queue, act(2, "stop"), row({ recipe: "a", unit: "activating" }))
  assert.deepStrictEqual(r.run.map((a) => a.kind), ["stop"], "the stop does not wait for the start to return")
  assert.strictEqual(r.queue.starting.superseded, true, "the start's exit is then not a failure to report")
  assert.deepStrictEqual(M.marks(r.queue, {}), { "h1/a": "stop" }, "Stopping shows once the stop runs")
})

test("a stop waiting behind another command shows as queued, not as Stopping", () => {
  let r = click(M.newQueue(), act(1, "delete", "b"))
  r = click(r.queue, act(2, "stop"), row({ recipe: "a", unit: "active" }))
  assert.deepStrictEqual(r.run, [])
  assert.deepStrictEqual(M.marks(r.queue, {}), { "h1/b": "delete", "h1/a": "queued stop" })
  assert.deepStrictEqual(M.modelState(row({ unit: "active" }), "queued stop"), { kind: "running", text: "Running · stop queued" })
  assert.strictEqual(M.toggleAction(row({ unit: "active" }), "queued stop"), null, "no second stop")
  assert.strictEqual(M.removeAction(row({ unit: "active" }), "queued stop"), null)
  assert.deepStrictEqual(M.meter(row({ unit: "active" }), 0, "queued stop").label, "Memory", "the bar is the machine's")
})

test("a stop of a start still waiting its turn takes it back, and sends nothing", () => {
  let r = click(M.newQueue(), act(1, "start", "b"))
  r = click(r.queue, act(2, "start"))
  assert.deepStrictEqual(M.marks(r.queue, {}), { "h1/b": "start", "h1/a": "queued start" })
  assert.deepStrictEqual(M.modelState(row({ unit: "inactive" }), "queued start"), { kind: "stopped", text: "Stopped · start queued" })
  assert.strictEqual(M.toggleAction(row({ unit: "inactive" }), "queued start"), "stop", "a queued start can be taken back")
  r = click(r.queue, act(3, "stop"), row({ recipe: "a", unit: "inactive" }))
  assert.deepStrictEqual(r.dropped.map((a) => a.op), [2])
  assert.deepStrictEqual(r.run, [])
  assert.deepStrictEqual(M.marks(r.queue, {}), { "h1/b": "start" })
})

test("a removal of a model that is loading stops it first: the engine's remove waits on the lock its start holds", () => {
  let r = click(M.newQueue(), act(1, "start"))
  r = click(r.queue, act(2, "delete"), row({ recipe: "a", unit: "activating" }))
  assert.deepStrictEqual(r.run.map((a) => [a.kind, a.shows]), [["stop", "delete"]])
  assert.strictEqual(r.queue.starting.superseded, true)
  assert.deepStrictEqual(r.queue.others.map((a) => a.kind), ["delete"])
  assert.deepStrictEqual(M.marks(r.queue, {}), { "h1/a": "delete" }, "Removing, from the stop on")
  const f = M.finish(r.queue, "other")
  assert.strictEqual(f.action.kind, "stop")
  assert.deepStrictEqual(M.launch(f.queue).run.map((a) => a.kind), ["delete"])
})

test("starts take turns on their own slot; set up and removal on the other", () => {
  let r = click(M.newQueue(), act(1, "start", "b"))
  r = click(r.queue, act(2, "use", "c"))
  assert.deepStrictEqual(r.run.map((a) => a.kind), ["use"], "a setup is not held up by a load")
  r = click(r.queue, act(3, "start", "d"))
  assert.deepStrictEqual(r.run, [], "one start at a time")
  let f = M.finish(r.queue, "start")
  assert.strictEqual(f.action.key, "h1/b")
  assert.deepStrictEqual(M.launch(f.queue).run.map((a) => a.key), ["h1/d"])
  f = M.finish(M.newQueue(), "start")
  assert.strictEqual(f.action, null, "nothing running, nothing finished")
})

test("a start asked for while that model is being stopped or removed is dropped", () => {
  let r = click(M.newQueue(), act(1, "stop"), row({ recipe: "a", unit: "active" }))
  r = click(r.queue, act(2, "start"))
  assert.deepStrictEqual(r.dropped.map((a) => a.op), [2])
  assert.deepStrictEqual(r.run, [])
})

test("marks: what a click shows until the machine's next answer after it", () => {
  const q = M.newQueue()
  assert.deepStrictEqual(M.marks(q, { "h1/a": { shows: "stop", op: 4 } }), { "h1/a": "stop" }, "a finished stop shows until the status after it")
  const done = { "h1/a": { shows: "stop", op: 4 }, "h1/b": { shows: "start", op: 5 } }
  assert.deepStrictEqual(M.settle(done, [{ key: "h1/a", op: 4 }, { key: "h1/b", op: 3 }]), { "h1/b": { shows: "start", op: 5 } }, "an older action's answer leaves a newer click's mark")
})

test("commandFor: each action's startdgx command and how long it may take", () => {
  assert.deepStrictEqual(M.commandFor("me@h1", act(1, "start")), ["start", "me@h1", "a", "--timeout", "900"])
  assert.deepStrictEqual(M.commandFor("me@h1", act(1, "stop")), ["stop", "me@h1", "a", "--timeout", "120"])
  assert.deepStrictEqual(M.commandFor("me@h1", act(1, "use")), ["use", "--detach", "me@h1", "a", "--timeout", "120"])
  // A removal may first wait for a start ahead of it that holds the engine's lock (900 s), then remove.
  assert.deepStrictEqual(M.commandFor("me@h1", act(1, "delete")), ["delete", "me@h1", "a", "--timeout", "1500"])
})

// ---- sharing a model with the tailnet ----

test("shareAction: what the Tailscale button does, for any model that is set up", () => {
  assert.strictEqual(M.shareAction(row({ unit: "active", shared: false })), "share")
  assert.strictEqual(M.shareAction(row({ unit: "active", shared: true })), "unshare")
  // Sharing is a standing property: a stopped model is shared (and unshared) as well as a running one.
  assert.strictEqual(M.shareAction(row({ unit: "inactive", shared: true })), "unshare")
  assert.strictEqual(M.shareAction(row({ unit: "inactive", fits: false })), "share", "even one that doesn't fit")
  assert.strictEqual(M.shareAction(row({ unit: "failed", error: "CUDA error" })), "share")
  assert.strictEqual(M.shareAction(null), null)
  for (const unit of ["installing", "removing"]) assert.strictEqual(M.shareAction(row({ unit: unit })), null, unit)
  assert.strictEqual(M.shareAction(row({ unit: "active" }), "delete"), null, "a removal under way")
  assert.strictEqual(M.shareAction(row({ unit: "active" }), "queued delete"), null, "and one waiting its turn")
  assert.strictEqual(M.shareAction(row({ unit: "active" }), "stop"), "share", "a stop doesn't matter to it")
  assert.strictEqual(M.shareAction(row({ unit: "active" }), "", "share"), null, "while its own click runs")
  assert.strictEqual(M.shareAction(row({ unit: "active" }), "", "queued unshare"), null)
})

test("a share is its own mark: it never hides what the model is doing, nor its Start and Stop", () => {
  assert.strictEqual(M.shareKey("h1", "a"), "h1/a#share")
  assert.deepStrictEqual(["share", "unshare", "start", "stop", "use", "delete"].map((k) => M.actionKey("h1", "a", k)),
    ["h1/a#share", "h1/a#share", "h1/a", "h1/a", "h1/a", "h1/a"], "only a share goes under its own key")
  const q = M.newQueue()
  const loading = { op: 1, key: "h1/a", kind: "start", shows: "start" }
  const sharing = { op: 2, key: M.shareKey("h1", "a"), kind: "share", shows: "share" }
  let s = M.submit(q, loading, null)
  s = M.launch(s.queue)
  s = M.submit(s.queue, sharing, null)
  assert.deepStrictEqual(s.dropped, [])
  s = M.launch(s.queue)
  assert.deepStrictEqual(M.marks(s.queue, {}), { "h1/a": "start", "h1/a#share": "share" }, "the load keeps its mark")
  // A stop while the share runs supersedes only the start, never the share.
  s = M.submit(s.queue, { op: 3, key: "h1/a", kind: "stop", shows: "stop" }, row({ unit: "activating" }))
  assert.strictEqual(s.queue.sharing.key, "h1/a#share")
  assert.strictEqual(s.queue.starting.superseded, true)
  // A second share click waits its turn, and is told so.
  const again = M.submit(M.launch(M.submit(M.newQueue(), sharing, null).queue).queue, Object.assign({}, sharing, { op: 4, kind: "unshare", shows: "unshare" }), null)
  assert.strictEqual(M.marks(again.queue, {})["h1/a#share"], "queued unshare")
})

test("a removal takes back the model's shares still waiting their turn, and only that model's", () => {
  const sh = (op, id) => ({ op: op, key: M.shareKey("h1", id), kind: "share", shows: "share" })
  let s = M.submit(M.newQueue(), act(1, "use", "z"), null)
  s = M.launch(s.queue)
  s = M.submit(s.queue, sh(5, "z"), null)
  s = M.launch(s.queue)
  s = M.submit(s.queue, sh(2, "a"), null)
  s = M.submit(s.queue, sh(3, "b"), null)
  s = M.submit(s.queue, act(4, "delete"), row({ unit: "inactive" }))
  assert.deepStrictEqual(s.queue.shares.map((a) => a.key), ["h1/b#share"])
  assert.deepStrictEqual(s.queue.others.map((a) => [a.kind, a.key]), [["delete", "h1/a"]])
  assert.deepStrictEqual(s.dropped.map((a) => a.key), [], "a share isn't a start: nothing for the caller to unmark")
  assert.strictEqual(M.marks(s.queue, {})["h1/a#share"], undefined)
})

test("a share has a slot of its own: a long removal doesn't hold it up, and it doesn't hold a stop up", () => {
  let s = M.submit(M.newQueue(), act(1, "delete", "a"), row({ unit: "inactive" }))
  let l = M.launch(s.queue)
  assert.deepStrictEqual(l.run.map((a) => a.kind), ["delete"])
  s = M.submit(l.queue, { op: 2, key: M.shareKey("h1", "b"), kind: "share", shows: "share" }, null)
  l = M.launch(s.queue)
  assert.deepStrictEqual(l.run.map((a) => a.kind), ["share"], "it runs beside the removal")
  assert.strictEqual(l.queue.other.kind, "delete")
  assert.strictEqual(M.finish(l.queue, "share").action.kind, "share")
  assert.strictEqual(M.finish(l.queue, "share").queue.other.kind, "delete", "its end leaves the removal running")
  s = M.submit(l.queue, act(3, "stop", "c"), row({ unit: "active" }))
  assert.deepStrictEqual(s.queue.others.map((a) => a.kind), ["stop"], "a stop waits only for the other slot")
})

test("commandFor: a share and an unshare run share, with --off to stop", () => {
  const share = (kind) => ({ op: 1, key: M.shareKey("me@h1", "a"), kind: kind, shows: kind })
  assert.deepStrictEqual(M.commandFor("me@h1", share("share")), ["share", "me@h1", "a", "--timeout", "120"])
  assert.deepStrictEqual(M.commandFor("me@h1", share("unshare")), ["share", "me@h1", "a", "--off", "--timeout", "120"])
})

test("keyAction: t shares the model under the cursor, or stops sharing it, and a held key acts once", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  assert.deepStrictEqual(M.keyAction("t", model, row({ unit: "active" })), { type: "share", host: "h1", id: "a" })
  assert.deepStrictEqual(M.keyAction("T", model, row({ unit: "inactive", shared: true })), { type: "unshare", host: "h1", id: "a" })
  assert.strictEqual(M.keyAction("t", model, row({ unit: "active" }), "", false, true), null, "held down")
  assert.strictEqual(M.keyAction("t", model, row({ unit: "active" }), "", true), null, "a machine that isn't answering")
  assert.strictEqual(M.keyAction("t", model, row({ unit: "active" }), "", false, false, "share"), null, "its own click runs")
  assert.strictEqual(M.keyAction("t", { kind: "host", host: "h1" }, null), null)
})

test("actionNotice: a share says what the engine said", () => {
  assert.strictEqual(M.actionNotice("share", "Sharing a on your tailnet at https://x/local-ai/a/v1\n"), "Sharing a on your tailnet at https://x/local-ai/a/v1")
})

// ---- the engine's real answers (tests/js/fixtures: `startdgx status` and `list` of a DGX Spark, gx10-f5f4) ----

const fs = require("node:fs")
const path = require("node:path")
const realStatus = fs.readFileSync(path.join(__dirname, "fixtures", "gx10-status.json"), "utf8")
const realList = fs.readFileSync(path.join(__dirname, "fixtures", "gx10-list.json"), "utf8")

test("a real status: parsed, and each model as the row draws it", () => {
  const s = M.parseStatus(realStatus)
  assert.ok(s, "the engine's own status parses")
  assert.deepStrictEqual(M.modelList(s).map((e) => [e.name, M.modelState(e).text, M.toggleAction(e)]), [
    ["Nemotron 3.5 Bolt", "Stopped", "start"],
    ["Qwen3.8 27B", "Stopped", "start"],
    ["Qwen3.8 27B Abliterated", "Running", "stop"],
  ])
  const running = s.models["qwen3.8-27b-abliterated-tensorfold"]
  assert.deepStrictEqual(M.meter(running, 0), { label: "Memory", fraction: 27.9 / 121.6, value: "28 of 122 GiB" })
  assert.strictEqual(M.modelFacts(s.models["nemotron-3.5-bolt-tensorfold"]), "256K context · 31 GiB")
  const h = { "me@gx10": { loaded: true, online: true, status: s } }
  assert.strictEqual(M.subtitle(M.summarize(Object.keys(h), h)), "1 MACHINE · 1 RUNNING")
})

test("a real catalog: the picker's offers on that machine", () => {
  const offers = M.recipeOffers(M.parseRecipes(realList), M.parseStatus(realStatus))
  assert.deepStrictEqual(offers.map((o) => [o.recipe.id, o.action, o.text]), [
    ["qwen3.8-flash-next-tensorfold", "use", "Recommended for this machine"],
    ["nemotron-3.5-bolt-tensorfold", null, "On this machine"],
    ["qwen3.8-27b-tensorfold", null, "On this machine"],
    ["qwen3.8-27b-abliterated-tensorfold", null, "On this machine"],
    ["glm-5.3-flash-tensorfold-pair", null, "runtime tensorfold-glm53-pair can't run on nvidia-gb10"],
    ["qwen3.8-27b-gufo", null, "runtime gufo can't run on nvidia-gb10"],
    ["qwen3.8-flash-next-gufo", null, "runtime gufo can't run on nvidia-gb10"],
  ])
})

test("parseStatus: a unit systemd has and the engine's list doesn't is read as inactive, as the engine's REMOTE_UNITS does", () => {
  for (const unit of ["reloading", "maintenance", "refreshing", "something-new"]) {
    const doc = JSON.parse(realStatus)
    doc.models["qwen3.8-27b-tensorfold"].unit = unit
    const s = M.parseStatus(JSON.stringify(doc))
    assert.ok(s, unit + " keeps the machine's status")
    assert.strictEqual(s.models["qwen3.8-27b-tensorfold"].unit, "inactive", unit)
    assert.strictEqual(s.models["qwen3.8-27b-abliterated-tensorfold"].unit, "active", "the others are left as they are")
  }
})

test("statusAnswer: what a status read says, and an answer that can't be read is said, not swallowed", () => {
  assert.ok(M.statusAnswer(0, realStatus, "", "me@gx10").status)
  assert.deepStrictEqual(M.statusAnswer(0, "half a docu", "", "me@gx10"), { status: null, error: "me@gx10 sent an unreadable status" })
  assert.deepStrictEqual(M.statusAnswer(1, "", "Error: me@gx10 didn't answer in time\n", "me@gx10"), { status: null, error: "me@gx10 didn't answer in time" })
  assert.deepStrictEqual(M.statusAnswer(255, "", "", "me@gx10"), { status: null, error: "me@gx10 didn't answer" })
})

test("setupNeeded: the engine's answer when a machine needs its root setup before a model can be set up", () => {
  // agent_local.py prepare_host, at v0.6.3-dgx.1: printed as "Error: <message>" on stderr, which the CLI passes on.
  const engine = "This machine needs Podman set up as root first: run this same command once in a terminal, where sudo can ask for your password"
  assert.strictEqual(M.setupNeeded(engine), true)
  assert.strictEqual(M.setupNeeded("Run setup once in a terminal"), true, "its short form, as the agents panel shows it")
  assert.strictEqual(M.setupNeeded("me@gx10 didn't answer in time"), false)
  assert.strictEqual(M.setupNeeded(""), false)
})

test("actionNotice: the footer's line after a command, without the engine's pointers to the agents panel and journalctl", () => {
  const unit = "omarchy-agent-local-use-qwen3.8-flash-next-tensorfold.service"
  assert.strictEqual(M.actionNotice("use", "Recipe x: 3 file(s)\nSetting up qwen3.8-flash-next-tensorfold in the background; the agents panel shows its progress, or follow it with: journalctl --user -u " + unit + " -f\n"),
    "Setting up qwen3.8-flash-next-tensorfold in the background")
  assert.strictEqual(M.actionNotice("use", "qwen3.8-flash-next-tensorfold is already being set up; follow it with: journalctl --user -u " + unit + " -f"),
    "qwen3.8-flash-next-tensorfold is already being set up")
  assert.strictEqual(M.actionNotice("stop", "Stopped a"), "Stopped a")
})

test("actionError: the footer's line when a command failed, short when the machine's row says the rest", () => {
  assert.strictEqual(M.actionError("Error: This machine needs Podman set up as root first: run this same command once in a terminal, where sudo can ask for your password\n", "demo@spark-f"),
    "spark-f needs its one-time root setup: Install… on its row runs it")
  assert.strictEqual(M.actionError("Error: Not enough memory\n", "demo@spark-f"), "Not enough memory")
  assert.strictEqual(M.actionError("", "demo@spark-f"), "The action failed")
})

test("a model that doesn't fit is never started, by button or key, even when it failed before", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  for (const over of [{ unit: "failed", fits: false, error: "CUDA error" }, { unit: "inactive", fits: false, error: "Port 11436 is taken" }, { unit: "inactive", fits: false }]) {
    const e = row(over)
    assert.strictEqual(M.startBlocked(e), true, JSON.stringify(over))
    assert.strictEqual(M.toggleAction(e), null, JSON.stringify(over))
    assert.strictEqual(M.keyAction("s", model, e), null, JSON.stringify(over))
    assert.strictEqual(M.keyAction("enter", model, e), null, JSON.stringify(over))
  }
})

test("keyAction: f asks before it forgets, and a held key acts once", () => {
  const model = { kind: "model", host: "h1", id: "a" }
  const host = { kind: "host", host: "h1" }
  assert.deepStrictEqual(M.keyAction("f", host, null), { type: "forget", host: "h1" }, "the forget card, not the forgetting")
  for (const key of ["enter", "s", "d", "delete", "f"]) {
    assert.strictEqual(M.keyAction(key, model, b, "", false, true), null, key + " held down")
  }
  assert.deepStrictEqual(M.keyAction("r", host, null, "", false, true), { type: "refresh" }, "a held r only looks again")
})

// `startdgx uninstall HOST --dry-run --json`, as the CLI prints it (tests/cli.sh checks the CLI's side).
const uninstallPlan = (over) => Object.assign({
  host: "me@spark", steps: ["stop the engine's units (omarchy-agent-local-*.service)", "delete the engine ~/.local/share/omarchy-local-ai", "forget me@spark here"],
  kept: ["keep ~/.local/share/omarchy/agent-local (47.5 GiB of model weights; --delete-models deletes them)", "keep the packages podman rsync (the install added them; --remove-packages removes them)"],
  manual: ["on each Omarchy machine paired with me@spark, run: omarchy agent local forget <its tailnet name>"],
  models_bytes: 47.5 * 2 ** 30, packages: ["podman", "rsync"]
}, over)

test("parseUninstallPlan keeps the uninstall's plan, and refuses anything else", () => {
  assert.strictEqual(M.parseUninstallPlan(JSON.stringify(uninstallPlan())).steps.length, 3)
  assert.strictEqual(M.parseUninstallPlan(JSON.stringify(uninstallPlan({ models_bytes: null }))).models_bytes, null)
  assert.strictEqual(M.parseUninstallPlan(JSON.stringify(uninstallPlan({ steps: "x" }))), null)
  assert.strictEqual(M.parseUninstallPlan(JSON.stringify(uninstallPlan({ packages: [1] }))), null)
  assert.strictEqual(M.parseUninstallPlan(JSON.stringify(uninstallPlan({ models_bytes: -1 }))), null)
  assert.strictEqual(M.parseUninstallPlan("Would, on me@spark:"), null)
})

test("uninstallText: the plan as the card shows it, as the CLI's dry run says it", () => {
  assert.strictEqual(M.uninstallText(uninstallPlan()), [
    "stop the engine's units (omarchy-agent-local-*.service)", "delete the engine ~/.local/share/omarchy-local-ai", "forget me@spark here",
    "keep ~/.local/share/omarchy/agent-local (47.5 GiB of model weights; --delete-models deletes them)",
    "keep the packages podman rsync (the install added them; --remove-packages removes them)",
    "", "Left for you to do:", "on each Omarchy machine paired with me@spark, run: omarchy agent local forget <its tailnet name>"].join("\n"))
})

test("uninstallChoices: what the card lets you opt into, off by default, with what it costs", () => {
  assert.deepStrictEqual(M.uninstallChoices(uninstallPlan()), [
    { flag: "--delete-models", label: "Also delete the model weights", description: "Frees 47.5 GiB. Setting a model up again downloads it again." },
    { flag: "--remove-packages", label: "Also remove the packages the install added", description: "podman, rsync. Anything else on the machine that uses them stops working; python3 always stays." },
  ])
  assert.deepStrictEqual(M.uninstallChoices(uninstallPlan({ models_bytes: null, packages: [] })), [], "nothing to opt into")
})

test("notifyCommand: an alert as notify-send's arguments, with -- before them and the body's markup escaped", () => {
  assert.deepStrictEqual(M.notifyCommand({ title: "-x <b> failed on h1", body: "CUDA <error> & co" }),
    ["notify-send", "--app-name=StartDGX", "--urgency=critical", "--", "-x <b> failed on h1", "CUDA &lt;error&gt; &amp; co"])
})

// ---- a query: one question at a time to bin/startdgx, the latest one wins ----

test("a query asked something new while it runs: the old one's late exit is dropped, then the new one is asked", () => {
  // The remove card for model a, then at once for model b: a's ask is killed, and its exit (a failure) arrives after.
  let r = M.queryAsk(M.newQuery(), "h1/a")
  assert.deepStrictEqual([r.launch, r.kill], ["h1/a", false])
  r = M.queryAsk(r.query, "h1/b")
  assert.deepStrictEqual([r.launch, r.kill], [null, true], "the old one is killed, and the new one waits for its exit")
  let e = M.queryExited(r.query)
  assert.deepStrictEqual([e.key, e.current, e.launch], ["h1/a", false, "h1/b"], "a's exit says nothing about b")
  e = M.queryExited(e.query)
  assert.deepStrictEqual([e.key, e.current, e.launch], ["h1/b", true, null], "b's own answer is read")
  assert.strictEqual(e.query.running, null)
})

test("a query: the same question again while it runs waits for that answer; after it, it is asked again", () => {
  let r = M.queryAsk(M.newQuery(), "h1")
  r = M.queryAsk(r.query, "h1")
  assert.deepStrictEqual([r.launch, r.kill], [null, false])
  const e = M.queryExited(r.query)
  assert.strictEqual(e.current, true)
  assert.strictEqual(M.queryAsk(e.query, "h1").launch, "h1", "looking again asks again")
})

test("a query cancelled (its card closed) ends, and its answer is dropped", () => {
  let r = M.queryAsk(M.newQuery(), "discover")
  const c = M.queryCancel(r.query)
  assert.strictEqual(c.kill, true)
  const e = M.queryExited(c.query)
  assert.deepStrictEqual([e.current, e.launch], [false, null])
  assert.strictEqual(M.queryCancel(M.newQuery()).kill, false, "nothing running, nothing to end")
})

test("modelKey, keyHost and keyModel: a model's key, the one form pending, setups and the cursor share", () => {
  assert.strictEqual(M.modelKey("demo@spark-a", "qwen3.8-27b-tensorfold"), "demo@spark-a/qwen3.8-27b-tensorfold")
  assert.strictEqual(M.keyHost("demo@spark-a/qwen3.8-27b-tensorfold"), "demo@spark-a")
  assert.strictEqual(M.keyModel("demo@spark-a/qwen3.8-27b-tensorfold"), "qwen3.8-27b-tensorfold")
})

test("a superseded start still loading never shows again once the stop that superseded it has finished", () => {
  let r = click(M.newQueue(), act(1, "start"))
  r = click(r.queue, act(2, "stop"), row({ recipe: "a", unit: "activating" }))
  const f = M.finish(r.queue, "other")
  assert.strictEqual(f.action.kind, "stop")
  assert.ok(f.queue.starting, "the start's ssh hasn't returned yet")
  assert.deepStrictEqual(M.marks(f.queue, { "h1/a": { shows: "stop", op: 2 } }), { "h1/a": "stop" })
  assert.deepStrictEqual(M.marks(f.queue, {}), {}, "and once that has settled, the machine's own state")
})

test("a query: asking again for what was just killed waits for the killed one's exit, then asks it anew", () => {
  let r = M.queryAsk(M.newQuery(), "A")
  r = M.queryAsk(r.query, "B")
  r = M.queryAsk(r.query, "A")
  assert.deepStrictEqual([r.launch, r.kill], [null, false], "the old A is already being ended")
  let e = M.queryExited(r.query)
  assert.deepStrictEqual([e.current, e.launch], [false, "A"], "the killed A's exit is not A's answer")
  e = M.queryExited(e.query)
  assert.deepStrictEqual([e.current, e.launch], [true, null])
})

test("a query cancelled, then asked the same again (Esc, then n): the killed run's exit is dropped and it runs anew", () => {
  let r = M.queryAsk(M.newQuery(), "discover ")
  r = M.queryCancel(r.query)
  r = M.queryAsk(r.query, "discover ")
  assert.deepStrictEqual([r.launch, r.kill], [null, false])
  let e = M.queryExited(r.query)
  assert.deepStrictEqual([e.current, e.launch], [false, "discover "])
  e = M.queryExited(e.query)
  assert.strictEqual(e.current, true)
})

test("engineUpdate reads the update the CLI found for a machine's engine", () => {
  const status = (update) => M.parseStatus(statusText({}, { engine_update: update }))
  assert.deepStrictEqual(M.engineUpdate(status({ from: "v0.6.3-dgx.1", to: "v0.6.3-dgx.2" })),
    { from: "v0.6.3-dgx.1", to: "v0.6.3-dgx.2", text: "Engine v0.6.3-dgx.1; v0.6.3-dgx.2 is available" })
  assert.strictEqual(M.engineUpdate(M.parseStatus(statusText({}))), null)
  assert.strictEqual(M.engineUpdate(null), null)
  assert.strictEqual(M.engineUpdate(status({ from: "v1", to: 2 })), null)
  assert.strictEqual(M.engineUpdate(status("v0.6.3-dgx.2")), null)
})

test("parseVariants reads the measured contexts, largest first, and refuses the rest", () => {
  const v = M.parseVariants(JSON.stringify([{ ctx: 65536, peak_ram_gib: 60, peak_gpu_gib: 58 }, { ctx: 262144, peak_ram_gib: 91.5, peak_gpu_gib: 90 }]))
  assert.deepStrictEqual(v.map((x) => x.ctx), [262144, 65536])
  assert.strictEqual(M.parseVariants(""), null)
  assert.strictEqual(M.parseVariants("{}"), null)
  assert.strictEqual(M.parseVariants("[]"), null)
  assert.strictEqual(M.parseVariants(JSON.stringify([{ ctx: "x", peak_ram_gib: 1 }])), null)
})

test("contextChoices: what each measured context needs, whether it fits and which one runs", () => {
  const v = [{ ctx: 262144, peak_ram_gib: 91.5, peak_gpu_gib: 90 }, { ctx: 131072, peak_ram_gib: 70, peak_gpu_gib: 68 }, { ctx: 65536, peak_ram_gib: 40, peak_gpu_gib: 38 }]
  const c = M.contextChoices(v, 131072, 96)
  assert.deepStrictEqual(c.map((x) => x.label), ["256K", "128K", "64K"])
  assert.deepStrictEqual(c.map((x) => x.fits), [false, true, true])
  assert.deepStrictEqual(c.map((x) => x.current), [false, true, false])
  assert.strictEqual(c[0].text, "Needs 91.5 GiB of memory and 8 GiB for the desktop; this machine has 96")
  assert.strictEqual(c[1].text, "Needs 70 GiB of memory")
  // A machine whose memory isn't known leaves every choice to the engine, which refuses what doesn't fit.
  assert.deepStrictEqual(M.contextChoices(v, 0, 0).map((x) => x.fits), [true, true, true])
})

test("contextAction: a model that is set up can change its context, unless it is being set up, removed or changed", () => {
  assert.strictEqual(M.contextAction(row({ unit: "active" }), ""), "context")
  assert.strictEqual(M.contextAction(row({ unit: "inactive" }), ""), "context")
  assert.strictEqual(M.contextAction(row({ unit: "failed" }), ""), "context")
  assert.strictEqual(M.contextAction(row({ unit: "installing" }), ""), null)
  assert.strictEqual(M.contextAction(row({ unit: "removing" }), ""), null)
  assert.strictEqual(M.contextAction(row({ unit: "active" }), "stop"), null)
  assert.strictEqual(M.contextAction(null, ""), null)
})

test("the c key opens a model's settings on the Context page, and the command a choice sends carries the context", () => {
  const model = { host: "h1", kind: "model", id: "a" }
  assert.deepStrictEqual(M.keyAction("c", model, row({ unit: "active" }), "", false, false, ""), { type: "modelSettings", host: "h1", id: "a", page: "Context" })
  assert.strictEqual(M.keyAction("c", model, row({ unit: "installing" }), "", false, false, ""), null)
  assert.strictEqual(M.keyAction("c", { host: "h1", kind: "host" }, null, "", false, false, ""), null)
  assert.deepStrictEqual(M.commandFor("h1", { key: "h1/a", kind: "context", ctx: 65536 }), ["use", "--detach", "h1", "a", "--ctx", "65536", "--timeout", "120"])
})

// ---- user recipes ----------------------------------------------------------------------------------------

test("recipeSource: a row without one is measured, a drafted or unknown one never counts as fitting", () => {
  assert.strictEqual(M.recipeSource({ id: "a" }), "measured")
  assert.strictEqual(M.recipeSource({ id: "a", source: "estimated" }), "estimated")
  assert.strictEqual(M.recipeSource({ id: "a", source: "drafted" }), "drafted")
  assert.strictEqual(M.recipeSource({ id: "a", source: "guessed" }), "drafted", "an unrecognised word is the cautious one")
})

test("the real host's catalog (no user, no source) reads as curated and measured", () => {
  const list = M.parseRecipes(require("node:fs").readFileSync(require("node:path").join(__dirname, "fixtures", "gx10-list.json"), "utf8"))
  assert.ok(list.length > 0)
  for (const r of list) {
    assert.strictEqual(M.isUserRecipe(r), false)
    assert.strictEqual(M.recipeSource(r), "measured")
  }
})

test("recipeOffers: a drafted recipe is not yet fitting even if the engine says it is available", () => {
  const r = { id: "mine", name: "Mine", user: true, source: "drafted", available: true, installed: false, best: false }
  const o = M.recipeOffers([r], { models: {} })[0]
  assert.strictEqual(o.action, null)
  assert.match(o.text, /not yet fitting/)
})

test("recipeOffers: an estimated or measured user recipe that is available can be set up", () => {
  const r = { id: "mine", name: "Mine", user: true, source: "measured", available: true, installed: false, best: false, context: 65536 }
  assert.strictEqual(M.recipeOffers([r], { models: {} })[0].action, "use")
})

test("recipeMarks: yours, and the source of a user recipe's numbers", () => {
  assert.deepStrictEqual(M.recipeMarks({ id: "a" }), [])
  assert.deepStrictEqual(M.recipeMarks({ id: "a", user: true, source: "measured" }), ["yours"])
  assert.deepStrictEqual(M.recipeMarks({ id: "a", user: true, source: "estimated" }), ["yours", "estimated"])
  assert.deepStrictEqual(M.recipeMarks({ id: "a", user: true, source: "drafted" }), ["yours", "drafted, not yet fitting"])
})

test("userRecipes keeps only the user's", () => {
  const list = [{ id: "a", user: false }, { id: "b", user: true }, { id: "c" }]
  assert.deepStrictEqual(M.userRecipes(list).map((r) => r.id), ["b"])
  assert.deepStrictEqual(M.userRecipes(null), [])
})

test("parseRecipeResult reads the CLI's validate and add answers", () => {
  assert.deepStrictEqual(M.parseRecipeResult(JSON.stringify({ ok: true, id: "mine", errors: [], message: "Recipe mine is valid" })),
    { ok: true, id: "mine", errors: [], message: "Recipe mine is valid" })
  const bad = M.parseRecipeResult(JSON.stringify({ ok: false, id: "mine", errors: ["recipes/mine: no name", "recipes/mine: no runtime"], message: "" }))
  assert.strictEqual(bad.ok, false)
  assert.strictEqual(bad.errors.length, 2)
  assert.strictEqual(M.parseRecipeResult("nope"), null)
  assert.strictEqual(M.parseRecipeResult(JSON.stringify({ ok: false, errors: [] })), null, "a rejection with no reason is not an answer")
  assert.strictEqual(M.parseRecipeResult(JSON.stringify({ ok: "yes", errors: [] })), null)
})

test("recipePathProblem: says what is wrong with a path before asking the machine", () => {
  assert.match(M.recipePathProblem(""), /path/i)
  assert.match(M.recipePathProblem("notes.txt"), /\.toml/)
  assert.strictEqual(M.recipePathProblem("~/recipes/mine.toml"), "")
  assert.strictEqual(M.recipePathProblem("  /x/mine.toml  "), "")
})

test("variantsText names each context with its source", () => {
  assert.strictEqual(M.variantsText([{ ctx: 131072, source: "measured" }, { ctx: 65536, source: "drafted" }, { ctx: 32768 }]),
    "128K measured · 64K drafted · 32K measured")
  assert.strictEqual(M.variantsText([]), "")
})

test("parseVariants keeps a variant's source; contextChoices marks drafted as not fitting and estimated as such", () => {
  const v = M.parseVariants(JSON.stringify([
    { ctx: 131072, peak_ram_gib: 40, peak_gpu_gib: 38, source: "measured" },
    { ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 28, source: "drafted" },
    { ctx: 32768, peak_ram_gib: 20, peak_gpu_gib: 18, source: "estimated" },
    { ctx: 16384, peak_ram_gib: 10, peak_gpu_gib: 8 }]))
  const c = M.contextChoices(v, 0, 128)
  assert.deepStrictEqual(c.map((x) => x.source), ["measured", "drafted", "estimated", "measured"])
  assert.deepStrictEqual(c.map((x) => x.fits), [true, false, false, true], "an estimated variant fits only once confirmed, as the engine says")
  assert.match(c[1].text, /not yet fitting/)
  assert.match(c[2].text, /Confirm it before it can run/)
  assert.match(c[2].text, /Estimated/)
})

test("keyAction: e adds a recipe to the machine", () => {
  assert.deepStrictEqual(M.keyAction("e", { kind: "host", host: "u@h" }, null, "", false, false), { type: "addRecipe", host: "u@h" })
  assert.strictEqual(M.keyAction("e", { kind: "host", host: "u@h" }, null, "", true, false), null, "not on a machine that doesn't answer")
})

// ---- measuring, confirming and setting up a user recipe -------------------------------------------------------

test("variantActions: a drafted variant can be measured, an estimated one confirmed or measured, a measured one neither", () => {
  assert.deepStrictEqual(M.variantActions({ source: "drafted" }), ["measure"])
  assert.deepStrictEqual(M.variantActions({ source: "estimated" }), ["confirm", "measure"])
  assert.deepStrictEqual(M.variantActions({ source: "measured" }), [])
  assert.deepStrictEqual(M.variantActions({}), [])
  assert.deepStrictEqual(M.variantActions({ source: "guessed" }), ["measure"], "an unrecognised source is drafted")
})

test("recipeOffers: setting up a user recipe asks first, a curated one doesn't", () => {
  const mine = { id: "mine", name: "Mine", user: true, source: "measured", available: true, installed: false, best: false, context: 65536 }
  const theirs = { id: "theirs", name: "Theirs", available: true, installed: false, best: false, context: 65536 }
  const [a, b] = M.recipeOffers([mine, theirs], { models: {} })
  assert.deepStrictEqual([a.recipe.id, a.action, a.confirm], ["mine", "use", true])
  assert.deepStrictEqual([b.recipe.id, b.action, b.confirm], ["theirs", "use", false])
})

test("recipeOffers: a user recipe whose context is unknown can't show its download, so it isn't offered", () => {
  const o = M.recipeOffers([{ id: "mine", name: "Mine", user: true, source: "measured", available: true, installed: false, best: false }], { models: {} })[0]
  assert.strictEqual(o.action, null)
  assert.match(o.text, /download/)
})

test("parseMeasurePlan: the engine's dry-run lines, without its closing 'nothing was changed'", () => {
  const text = "Measure mine at context 65536 (now a drafted variant)\n  download: 3.5 GiB to download (3.5 GiB in 2 file(s))\n  load: Mine on tensorfold\nNothing was changed. Run again with --yes to do it.\n"
  assert.deepStrictEqual(M.parseMeasurePlan(text), ["Measure mine at context 65536 (now a drafted variant)", "download: 3.5 GiB to download (3.5 GiB in 2 file(s))", "load: Mine on tensorfold"])
  assert.strictEqual(M.parseMeasurePlan(""), null)
  assert.strictEqual(M.parseMeasurePlan("Nothing was changed. Run again with --yes to do it."), null)
})

test("recipeRunWords: what the confirmation card says for a measure and for a setup", () => {
  const measure = M.recipeRunWords("measure", { id: "mine", name: "Mine" }, 65536, "spark-a")
  assert.match(measure.title, /Measure Mine/)
  assert.match(measure.title, /64K/)
  assert.strictEqual(measure.button, "Download and measure")
  assert.match(measure.body, /runs it/i)
  const setup = M.recipeRunWords("setup", { id: "mine", name: "Mine" }, 65536, "spark-a")
  assert.match(setup.title, /Set up Mine/)
  assert.strictEqual(setup.button, "Download and set up")
})

test("commandFor: a setup the person confirmed passes --yes to use, and one that wasn't doesn't", () => {
  const act = (extra) => Object.assign({ op: 1, key: "me@h1/a", kind: "use", shows: "use" }, extra)
  assert.deepStrictEqual(M.commandFor("me@h1", act({ yes: true })), ["use", "--detach", "me@h1", "a", "--yes", "--timeout", "120"])
  assert.deepStrictEqual(M.commandFor("me@h1", act({})), ["use", "--detach", "me@h1", "a", "--timeout", "120"])
})

test("uninstallChoices: your recipes are an opt-in only when there are some, and say they go with it", () => {
  const withRecipes = M.uninstallChoices(uninstallPlan({ recipes: 2 }))
  const c = withRecipes.find((x) => x.flag === "--delete-recipes")
  assert.ok(c)
  assert.match(c.label, /recipes/)
  assert.match(c.description, /2/)
  assert.strictEqual(M.uninstallChoices(uninstallPlan({ recipes: 0 })).some((x) => x.flag === "--delete-recipes"), false)
  assert.strictEqual(M.uninstallChoices(uninstallPlan()).some((x) => x.flag === "--delete-recipes"), false, "a plan from an older CLI has no count")
})

test("a confirmed estimated variant says so, and offers only Measure", () => {
  assert.deepStrictEqual(M.variantActions({ source: "estimated", confirmed: true }), ["measure"])
  assert.deepStrictEqual(M.variantActions({ source: "estimated", confirmed: false }), ["confirm", "measure"])
  const c = M.contextChoices([{ ctx: 65536, peak_ram_gib: 20, peak_gpu_gib: 18, source: "estimated", confirmed: true },
    { ctx: 32768, peak_ram_gib: 10, peak_gpu_gib: 9, source: "estimated" }], 0, 128)
  assert.match(c[0].text, /you confirmed it/)
  assert.doesNotMatch(c[1].text, /you confirmed it/)
  assert.deepStrictEqual(c.map((x) => x.fits + " " + x.confirmed), ["true true", "false false"])
  assert.deepStrictEqual(M.variantRows([{ ctx: 65536, peak_ram_gib: 20, peak_gpu_gib: 18, source: "estimated", confirmed: true }]).map(M.variantActions), [["measure"]], "the recipe's list offers no Confirm on a confirmed one")
})

test("recipeSendCommand: the typed path comes after --, so one that starts with - is a path, not an option", () => {
  assert.deepStrictEqual(M.recipeSendCommand("validate", "me@h1", "-x.toml"), ["recipe", "validate", "me@h1", "--json", "--timeout", "60", "--", "-x.toml"])
  assert.deepStrictEqual(M.recipeSendCommand("add", "me@h1", "  ~/a b.toml "), ["recipe", "add", "me@h1", "--json", "--timeout", "60", "--", "~/a b.toml"])
})

test("parseMeasurePlan keeps the engine's up-front note that other commands wait for the measure", () => {
  const note = "while it runs, every other omarchy agent local command waits for it (the agents panel's start and stop too): typically 10 minutes"
  const plan = M.parseMeasurePlan("Measure mine at context 65536 (now a drafted variant)\n  download: 3.5 GiB to download\n  " + note + "\n  then: restarts the model\nNothing was changed. Run again with --yes to do it.\n")
  assert.ok(plan.includes(note))
  assert.strictEqual(plan.length, 4)
})

// ---- Find on Hugging Face (`hf search --json`) ----
const hfRow = (over) => Object.assign({ repo: "TensorFold/Qwen3.8-27B-MLX-4bit", params: 27356728560, size_bytes: 16074529674,
  license: "apache-2.0", base_model: "Qwen/Qwen3.8-27B", label: null }, over)
const hfRows = [hfRow(), hfRow({ repo: "daguoagi/Huihui-Qwen3.8-27B-abliterated-MLX-4bit", label: "abliterated" }),
  hfRow({ repo: "someone/Gemma-4-31B-uncensored-MLX-4bit", label: "uncensored", license: null, base_model: null, params: null, size_bytes: null })]

test("parseHfRows keeps the CLI's rows and refuses what isn't a list of them", () => {
  assert.strictEqual(M.parseHfRows(JSON.stringify(hfRows)).length, 3)
  assert.deepStrictEqual(M.parseHfRows("[]"), [])
  assert.strictEqual(M.parseHfRows(""), null)
  assert.strictEqual(M.parseHfRows("{}"), null)
  assert.strictEqual(M.parseHfRows(JSON.stringify([{ params: 1 }])), null)
})

test("hfShown hides the labelled rows with the toggle off and keeps the order", () => {
  assert.deepStrictEqual(M.hfShown(hfRows, true).map((r) => r.repo), hfRows.map((r) => r.repo))
  assert.deepStrictEqual(M.hfShown(hfRows, false).map((r) => r.repo), ["TensorFold/Qwen3.8-27B-MLX-4bit"])
  assert.deepStrictEqual(M.hfShown(null, false), [])
})

test("hfDerivativeCount counts the labelled rows, for the toggle's words", () => {
  assert.strictEqual(M.hfDerivativeCount(hfRows), 2)
  assert.strictEqual(M.hfDerivativeCount([hfRow()]), 0)
  assert.strictEqual(M.hfDerivativeCount(null), 0)
})

test("hfToggleText says what the toggle does and how many rows it holds", () => {
  assert.strictEqual(M.hfToggleText(hfRows, true), "Hide abliterated and uncensored (2)")
  assert.strictEqual(M.hfToggleText(hfRows, false), "Show abliterated and uncensored (2)")
  assert.strictEqual(M.hfToggleText([hfRow()], true), "")
})

test("hfMemoryLine gives plain facts and never a verdict", () => {
  assert.strictEqual(M.hfMemoryLine(hfRow({ size_bytes: 16.5 * 2 ** 30 }), 128), "weights 16.5 GiB; this host has 128 GiB")
  assert.strictEqual(M.hfMemoryLine(hfRow({ size_bytes: 15.4 * 2 ** 30 }), 121.6), "weights 15.4 GiB; this host has 122 GiB")
  assert.strictEqual(M.hfMemoryLine(hfRow(), 0), "weights 15.0 GiB")
  assert.strictEqual(M.hfMemoryLine(hfRow({ size_bytes: null }), 128), "weights size unknown; this host has 128 GiB")
  // Even a model far bigger than the host only gets the two numbers.
  const huge = M.hfMemoryLine(hfRow({ size_bytes: 500 * 2 ** 30 }), 128)
  assert.strictEqual(huge, "weights 500.0 GiB; this host has 128 GiB")
  assert.ok(!/fit|enough|too|won't|will|can/i.test(huge))
})

test("hfRowText is the facts under a repo's name, in the order the CLI prints them", () => {
  assert.strictEqual(M.hfRowText(hfRow()), "27.4B · apache-2.0 · from Qwen/Qwen3.8-27B")
  assert.strictEqual(M.hfRowText(hfRows[2]), "license unknown")
  assert.strictEqual(M.hfRowText(hfRow({ params: null, base_model: null })), "apache-2.0")
})

test("hfLabel is the mark on a derivative and nothing on the rest", () => {
  assert.strictEqual(M.hfLabel(hfRows[1]), "abliterated")
  assert.strictEqual(M.hfLabel(hfRow()), "")
})

test("hfSearchCommand hands the query after --, so a query starting with - is a query", () => {
  assert.deepStrictEqual(M.hfSearchCommand("  qwen "), ["hf", "search", "--json", "--", "qwen"])
  assert.deepStrictEqual(M.hfSearchCommand("-x"), ["hf", "search", "--json", "--", "-x"])
})

// ---- Draft recipe on a search result (`recipe draft --host HOST --json`, then the Add recipe path) ----
const draftJson = (over) => JSON.stringify(Object.assign({ ok: true, id: "qwen3.8-27b-mlx-4bit-tensorfold", repo: "TensorFold/Qwen3.8-27B-MLX-4bit",
  path: "/home/me/.local/state/startdgx/drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml", revision: "948c129", license: "apache-2.0",
  weights_bytes: 16074529674, placeholder_gib: 15, source: "drafted", warnings: [] }, over))

test("draftCommand asks the host about the id, so a clash is refused before anything is written, and the repo comes after --", () => {
  assert.deepStrictEqual(M.draftCommand("me@dgx", "TensorFold/Qwen3.8-27B-MLX-4bit"),
    ["recipe", "draft", "--host", "me@dgx", "--json", "--", "TensorFold/Qwen3.8-27B-MLX-4bit"])
})

test("parseDraftResult keeps the file to add and the warnings, and refuses what isn't a draft", () => {
  const d = M.parseDraftResult(draftJson({ warnings: ["License 'llama3' may restrict use: read its terms before you use it", ""] }))
  assert.strictEqual(d.id, "qwen3.8-27b-mlx-4bit-tensorfold")
  assert.strictEqual(d.path, "/home/me/.local/state/startdgx/drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml")
  assert.deepStrictEqual(d.warnings, ["License 'llama3' may restrict use: read its terms before you use it"])
  assert.deepStrictEqual(M.parseDraftResult(draftJson()).warnings, [])
  assert.strictEqual(M.parseDraftResult(""), null)
  assert.strictEqual(M.parseDraftResult("[]"), null)
  assert.strictEqual(M.parseDraftResult(draftJson({ ok: false })), null)
  assert.strictEqual(M.parseDraftResult(draftJson({ path: "" })), null)
  assert.strictEqual(M.parseDraftResult(draftJson({ id: undefined })), null)
  assert.strictEqual(M.parseDraftResult(draftJson({ warnings: "x" })), null)
})

test("draftStatus says which step runs, and the outcome in words that call the recipe drafted and not yet fitting", () => {
  assert.strictEqual(M.draftStatus("drafting", "me@dgx", "A/B"), "Drafting A/B…")
  assert.strictEqual(M.draftStatus("checking", "me@dgx", "A/B"), "Asking dgx to check the draft…")
  assert.strictEqual(M.draftStatus("adding", "me@dgx", "A/B"), "Adding the draft to dgx…")
  assert.strictEqual(M.draftStatus("", "me@dgx", "A/B"), "")
  assert.match(M.draftDone("me@dgx", "my-id"), /my-id.*dgx.*drafted, not yet fitting.*Measure/)
})

test("draftErrorText drops the CLI's --id advice, which the card can't act on", () => {
  assert.strictEqual(M.draftErrorText("demo@spark-a already has a recipe 'x' (curated or yours): pick another id with --id"), "demo@spark-a already has a recipe 'x' (curated or yours)")
  assert.strictEqual(M.draftErrorText("/d/x.toml already exists: pick another id with --id, or delete the file"), "/d/x.toml already exists: delete the file to draft it again")
  assert.strictEqual(M.draftErrorText("Hugging Face did not answer"), "Hugging Face did not answer")
})

test("authorLaunch opens a terminal on the repo through launch, so the draft's errors and the agent show there", () => {
  assert.deepStrictEqual(M.authorLaunch("me@dgx", "TensorFold/Qwen3.8-27B-MLX-4bit"), { verb: "author", host: "me@dgx", id: "TensorFold/Qwen3.8-27B-MLX-4bit" })
})

test("authorLaunch refuses what is not an OWNER/NAME repo, as the CLI does", () => {
  for (const repo of ["", "notarepo", "../x/y", "a/b/c", "-x y/z", "a/..", null, undefined]) assert.strictEqual(M.authorLaunch("me@dgx", repo), null, String(repo))
})

test("the agent pill says an agent opens in a terminal and that downloads and measuring runs wait for the person", () => {
  assert.strictEqual(M.AUTHOR_TEXT, "With an agent…")
  assert.match(M.authorHint(), /terminal/)
  assert.match(M.authorHint(), /asks before any download or measuring run/)
  assert.doesNotMatch(M.authorHint(), /fits?\b/i)
})

// ---- the model store: where a model's weights are, and what can be moved ----

const store = (present) => ({ path: "/media/usb/startdgx-models", present: present })

test("parseStorage: startdgx storage --json, or null when it isn't that", () => {
  const text = JSON.stringify({ store: store(true), disks: [], models: [{ id: "a", location: "usb", bytes: 5 }] })
  assert.deepStrictEqual(M.parseStorage(text).models, [{ id: "a", location: "usb", bytes: 5 }])
  assert.strictEqual(M.parseStorage("nope"), null)
  assert.strictEqual(M.parseStorage('{"store":null,"disks":[]}'), null, "no models list: not an answer startdgx gives")
})

test("locationOf: where one model's weights are, or nothing when it isn't listed", () => {
  const storage = M.parseStorage(JSON.stringify({ store: null, disks: [], models: [{ id: "a", location: "both", bytes: 1 }] }))
  assert.strictEqual(M.locationOf(storage, "a"), "both")
  assert.strictEqual(M.locationOf(storage, "b"), "")
  assert.strictEqual(M.locationOf(null, "a"), "")
})

test("locationText: the words under a model for where its weights are", () => {
  assert.strictEqual(M.locationText("nvme"), "On NVMe")
  assert.strictEqual(M.locationText("usb"), "On USB")
  assert.strictEqual(M.locationText("both"), "On NVMe and USB")
  assert.strictEqual(M.locationText("usb-missing"), "USB disk missing")
  assert.strictEqual(M.locationText("mixed"), "Partly on USB")
  assert.strictEqual(M.locationText(""), "")
})

test("moveOffers: what a model's card may offer, and nothing without a mounted store or while it runs", () => {
  const offers = (location, unit, s) => M.moveOffers(location, unit, s).map((o) => o.to + ":" + o.label)
  assert.deepStrictEqual(offers("nvme", "inactive", store(true)), ["usb:Move to USB"])
  assert.deepStrictEqual(offers("usb", "inactive", store(true)), ["nvme:Move to NVMe"])
  assert.deepStrictEqual(offers("both", "inactive", store(true)), ["usb:Free NVMe space"])
  assert.deepStrictEqual(offers("mixed", "inactive", store(true)), ["usb:Move to USB", "nvme:Move to NVMe"])
  assert.deepStrictEqual(offers("usb-missing", "inactive", store(false)), [])
  assert.deepStrictEqual(offers("nvme", "inactive", store(false)), [], "a store whose disk isn't mounted offers nothing")
  assert.deepStrictEqual(offers("nvme", "inactive", null), [], "no store set: the feature isn't there")
  for (const unit of ["active", "activating", "deactivating", "installing", "removing"]) {
    assert.deepStrictEqual(offers("nvme", unit, store(true)), [], unit + " can't be moved")
  }
})

test("commandFor: a move runs move, to the disk asked for, with room for a big copy", () => {
  const move = (to) => ({ op: 1, key: "me@h1/a", kind: "move", to: to, shows: "move" })
  assert.deepStrictEqual(M.commandFor("me@h1", move("usb")), ["move", "me@h1", "a", "--to", "usb", "--timeout", "3600"])
  assert.deepStrictEqual(M.commandFor("me@h1", move("nvme")), ["move", "me@h1", "a", "--to", "nvme", "--timeout", "3600"])
})

// ---- the model store panel -------------------------------------------------------------------------------

test("modelState: a move shows its words while it runs, and queued behind another command", () => {
  assert.deepStrictEqual(M.modelState(row({ unit: "inactive" }), "move-usb"), { kind: "moving", text: "Moving to USB" })
  assert.deepStrictEqual(M.modelState(row({ unit: "inactive" }), "move-nvme"), { kind: "moving", text: "Moving to NVMe" })
  assert.deepStrictEqual(M.modelState(row({ unit: "inactive" }), "queued move-usb"), { kind: "stopped", text: "Stopped · move queued" })
  assert.strictEqual(M.modelState(row({ unit: "removing" }), "move-usb").kind, "removing", "the machine's own state wins")
  assert.strictEqual(M.modelState(row({ unit: "active" }), "move-usb").kind, "running")
})

test("a model being moved can't be started, stopped, removed or moved again", () => {
  assert.strictEqual(M.toggleAction(row({ unit: "inactive" }), "move-usb"), null)
  assert.strictEqual(M.toggleAction(row({ unit: "inactive" }), "queued move-usb"), null)
  assert.strictEqual(M.removeAction(row({ unit: "inactive" }), "move-usb"), null)
  assert.strictEqual(M.keyAction("s", { kind: "model", host: "h", id: "m" }, row({ unit: "inactive" }), "move-usb"), null)
})

test("hostBusy: a host moving a model polls quickly", () => {
  assert.ok(M.BUSY_KINDS.indexOf("moving") >= 0)
})

test("submit: a move has a slot of its own, so another model's stop never waits for the copy", () => {
  const move = { op: 1, key: "h/m", kind: "move", to: "usb", shows: "move-usb" }
  const s = M.submit(M.newQueue(), move, row())
  assert.deepStrictEqual(s.queue.moves, [move])
  const l = M.launch(s.queue)
  assert.deepStrictEqual(l.run, [move])
  assert.strictEqual(l.queue.moving, move)
  const stop = { op: 2, key: "h/other", kind: "stop", shows: "stop" }
  const t = M.submit(l.queue, stop, row({ recipe: "other", unit: "active" }))
  assert.deepStrictEqual(M.launch(t.queue).run, [stop], "the stop runs while the move copies")
  assert.deepStrictEqual(M.marks(l.queue, {}), { "h/m": "move-usb" })
  assert.strictEqual(M.finish(l.queue, "move").action, move)
  assert.strictEqual(M.finish(l.queue, "move").queue.moving, null)
})

test("submit: a start of a model that is being moved is dropped", () => {
  const move = { op: 1, key: "h/m", kind: "move", to: "usb", shows: "move-usb" }
  const start = { op: 2, key: "h/m", kind: "start", shows: "start" }
  const queued = M.submit(M.submit(M.newQueue(), move, row()).queue, start, row())
  assert.deepStrictEqual(queued.dropped, [start], "behind a queued move")
  const running = M.submit(M.launch(M.submit(M.newQueue(), move, row()).queue).queue, start, row())
  assert.deepStrictEqual(running.dropped, [start], "behind a running one")
  assert.deepStrictEqual(running.queue.starts, [])
})

test("submit: store changes wait behind moves, on the same slot", () => {
  const move = { op: 1, key: "h/m", kind: "move", to: "usb", shows: "move-usb" }
  const unset = { op: 2, key: "h/", kind: "storageUnset", shows: "storage" }
  const q = M.submit(M.launch(M.submit(M.newQueue(), move, row()).queue).queue, unset, null).queue
  assert.deepStrictEqual(q.moves, [unset])
  assert.deepStrictEqual(M.launch(q).run, [])
  assert.strictEqual(M.marks(q, {})["h/"], "queued storage")
})

test("summarize: a model being moved counts as busy, from its mark", () => {
  const hs = up(models(row({ recipe: "m", unit: "inactive" })))
  assert.strictEqual(M.summarize(["h"], { h: hs }, { "h/m": "move-usb" }).busy, 1)
  assert.strictEqual(M.summarize(["h"], { h: hs }, { "h/m": "move-usb" }).kind, "busy")
  assert.strictEqual(M.summarize(["h"], { h: hs }, {}).busy, 0)
  assert.strictEqual(M.summarize(["h"], { h: hs }).busy, 0, "marks are optional")
})

test("commandFor: storage set and unset", () => {
  assert.deepStrictEqual(M.commandFor("h", { kind: "storageSet", key: "h/", path: "/mnt/u/models" }), ["storage", "h", "--set", "/mnt/u/models", "--timeout", "60"])
  assert.deepStrictEqual(M.commandFor("h", { kind: "storageUnset", key: "h/" }), ["storage", "h", "--unset", "--timeout", "60"])
})

test("storageAnswer: the host's storage, or why not", () => {
  const ok = JSON.stringify({ store: null, disks: [], models: [] })
  assert.deepStrictEqual(M.storageAnswer(0, ok, "", "h"), { storage: { store: null, disks: [], models: [] } })
  assert.deepStrictEqual(M.storageAnswer(1, "", "Error: nope\n", "h"), { storage: null, error: "nope" })
  assert.deepStrictEqual(M.storageAnswer(0, "junk", "", "h"), { storage: null, error: "h sent an unreadable storage answer" })
})

test("diskRows: each disk with its free space, an unusable one with its reason", () => {
  const storage = { store: { path: "/m/u/models", present: true }, models: [], disks: [
    { mount: "/m/u", bus: "usb", fstype: "ext4", size: 2e12, free: 1.5e12, usable: true, reason: "" },
    { mount: "/m/v", bus: "usb", fstype: "ntfs", size: 5e11, free: 1e11, usable: false, reason: "NTFS can't hold the models" }] }
  assert.deepStrictEqual(M.diskRows(storage), [
    { mount: "/m/u", text: "/m/u · USB ext4 · 1397.0 GiB free of 1862.6 GiB", usable: true, reason: "", inUse: true },
    { mount: "/m/v", text: "/m/v · USB ntfs · 93.1 GiB free of 465.7 GiB", usable: false, reason: "NTFS can't hold the models", inUse: false }])
  assert.deepStrictEqual(M.diskRows(null), [])
})

test("storageSummary: the store in words", () => {
  assert.strictEqual(M.storageSummary(null), "")
  assert.strictEqual(M.storageSummary({ store: null, disks: [], models: [] }), "Models stay on the internal disk")
  assert.strictEqual(M.storageSummary({ store: { path: "/m/u/models", present: true }, disks: [], models: [] }), "Store: /m/u/models")
  assert.strictEqual(M.storageSummary({ store: { path: "/m/u/models", present: false }, disks: [], models: [] }), "Store: /m/u/models (disk not mounted)")
})

test("storagePathProblem: a custom store path must be absolute", () => {
  assert.strictEqual(M.storagePathProblem("/mnt/u/models"), "")
  assert.strictEqual(M.storagePathProblem(" /mnt/u/models "), "")
  assert.strictEqual(M.storagePathProblem(""), "Type the folder on the machine")
  assert.strictEqual(M.storagePathProblem("models"), "The path must start with /")
  assert.strictEqual(M.storagePathProblem("/a\nb"), "The path must be one line")
})

// ---- the gear panels ------------------------------------------------------------------------------------

const keysOf = (pages) => pages.map((p) => p.title + ":" + p.fields.map((f) => f.key).join(","))
const storeOf = (path, present) => ({ store: path ? { path: path, present: present !== false } : null, models: [],
  disks: [{ mount: "/m/u", bus: "usb", fstype: "ext4", size: 2e12, free: 1e12, usable: true, reason: "" },
          { mount: "/m/v", bus: "usb", fstype: "ntfs", size: 5e11, free: 1e11, usable: false, reason: "NTFS can't hold the models" }] })

test("hostPages: General, Storage and Machine, each with only what applies", () => {
  const base = { machine: "spark-a", update: null, needsSetup: false, storage: null, readError: "", busy: false }
  assert.deepStrictEqual(keysOf(M.hostPages(base)), ["General:logs", "Storage:store,folder", "Machine:uninstall,forget"])
  const update = { from: "v1", to: "v2", text: "Engine v1; v2 is available" }
  assert.deepStrictEqual(M.hostPages(Object.assign({}, base, { update: update }))[0].fields.map((f) => f.key), ["update", "logs"])
  assert.strictEqual(M.hostPages(Object.assign({}, base, { update: update }))[0].fields[0].hint, "Engine v1; v2 is available")
  assert.deepStrictEqual(M.hostPages(Object.assign({}, base, { needsSetup: true }))[0].fields.map((f) => f.key), ["setup", "logs"])
  assert.strictEqual(M.hostPages(base)[2].fields.some((f) => f.danger), false, "both open a card that asks, so neither is loud")
})

test("hostPages: the model store is a choice among the usable disks, and waits while it can't change", () => {
  const base = { machine: "m", update: null, needsSetup: false, readError: "", busy: false }
  let f = M.hostPages(Object.assign({}, base, { storage: storeOf(null) }))[1].fields[0]
  assert.deepStrictEqual(f.options, [{ value: "", label: "Internal disk only" }, { value: "/m/u", label: "/m/u · USB ext4 · 931.3 GiB free" }])
  assert.strictEqual(f.disabled, undefined)
  assert.ok(/Not usable: \/m\/v/.test(f.note.text) && /NTFS/.test(f.note.text))
  const withModels = storeOf("/m/u/startdgx-models")
  withModels.models = [{ id: "a", location: "usb", bytes: 1 }, { id: "b", location: "both", bytes: 1 }, { id: "c", location: "nvme", bytes: 1 }]
  f = M.hostPages(Object.assign({}, base, { storage: withModels }))[1].fields[0]
  assert.strictEqual(f.disabled, true)
  assert.strictEqual(f.note.kind, "bad")
  assert.ok(/1 model has files on the store/.test(f.note.text), f.note.text)
  assert.strictEqual(M.hostPages(Object.assign({}, base, { storage: storeOf(null), busy: true }))[1].fields[0].disabled, true)
  const unread = M.hostPages(Object.assign({}, base, { storage: null, readError: "h didn't answer" }))[1].fields[0]
  assert.strictEqual(unread.disabled, true)
  assert.deepStrictEqual(unread.note, { kind: "bad", text: "h didn't answer" })
  assert.deepStrictEqual(M.hostPages(Object.assign({}, base, { storage: null }))[1].fields[0].note, { kind: "muted", text: "Asking the machine…" })
})

test("hostValues: the disk in use, and the folder of your own", () => {
  assert.deepStrictEqual(M.hostValues(storeOf(null)), { store: "", folder: "" })
  assert.deepStrictEqual(M.hostValues(storeOf("/m/u/startdgx-models")), { store: "/m/u", folder: "" })
  assert.deepStrictEqual(M.hostValues(storeOf("/m/u/mine")), { store: "", folder: "/m/u/mine" })
  assert.deepStrictEqual(M.hostValues(null), { store: "", folder: "" })
})

test("hostChange: what a click in the machine's panel asks for", () => {
  const h = "me@spark-a"
  assert.deepStrictEqual(M.hostChange(h, "logs", true, null), { action: { type: "logs", host: h, id: "" } })
  assert.deepStrictEqual(M.hostChange(h, "update", true, null), { action: { type: "install", host: h, replace: false } })
  assert.deepStrictEqual(M.hostChange(h, "setup", true, null), { action: { type: "install", host: h, replace: true } })
  assert.deepStrictEqual(M.hostChange(h, "uninstall", true, null), { action: { type: "uninstall", host: h } })
  assert.deepStrictEqual(M.hostChange(h, "forget", true, null), { action: { type: "forget", host: h } })
  assert.deepStrictEqual(M.hostChange(h, "store", "/m/u", storeOf(null)), { action: { type: "storageSet", host: h, path: "/m/u/startdgx-models" } })
  assert.deepStrictEqual(M.hostChange(h, "store", "", storeOf("/m/u/startdgx-models")), { action: { type: "storageUnset", host: h } })
  assert.deepStrictEqual(M.hostChange(h, "store", "/m/u", storeOf("/m/u/startdgx-models")), { action: null }, "the disk already in use")
  assert.deepStrictEqual(M.hostChange(h, "store", "", storeOf(null)), { action: null }, "no store to remove")
  assert.deepStrictEqual(M.hostChange(h, "folder", " /m/u/mine ", storeOf(null)), { action: { type: "storageSet", host: h, path: "/m/u/mine" } })
  assert.deepStrictEqual(M.hostChange(h, "folder", "mine", storeOf(null)), { action: null, error: "The path must start with /" })
  assert.deepStrictEqual(M.hostChange(h, "folder", "", storeOf(null)), { action: null }, "an emptied box asks nothing")
})

test("modelPages: share, logs, context sizes and where the files are", () => {
  const entry = row({ unit: "inactive", shared: false, ctx: 131072 })
  const choices = M.contextChoices([{ ctx: 131072, peak_ram_gib: 40, source: "measured" }, { ctx: 262144, peak_ram_gib: 200, source: "measured" }], 131072, 121.6)
  const c = { entry: entry, pending: "", sharing: "", store: null, location: "", choices: choices, variantsLoading: false, variantsError: "", away: false }
  assert.deepStrictEqual(keysOf(M.modelPages(c)), ["General:share,logs", "Context:ctx"], "no store: no Storage page")
  const ctx = M.modelPages(c)[1].fields[0]
  assert.strictEqual(ctx.type, "info", "one size that fits is not a choice")
  assert.strictEqual(ctx.hint, "128K, which needs 40 GiB of memory. It is the only size that fits this machine, so there is nothing to choose.")
  assert.ok(/^Not offered\. 256K: Needs 200 GiB/.test(ctx.note.text), "and the ones that don't fit say why")
  const s = M.modelPages(Object.assign({}, c, { store: { path: "/m/u/x", present: true }, location: "nvme" }))
  assert.deepStrictEqual(keysOf(s), ["General:share,logs", "Context:ctx", "Storage:where,move-usb"])
  assert.strictEqual(s[2].fields[0].hint, "On NVMe")
  assert.strictEqual(s[2].fields[1].label, "Move to USB")
  const running = M.modelPages(Object.assign({}, c, { entry: row({ unit: "active" }), store: { path: "/m/u/x", present: true }, location: "nvme" }))
  assert.deepStrictEqual(keysOf(running)[2], "Storage:where", "a running model can't be moved")
  assert.ok(/stopped/.test(running[2].fields[0].note.text))
  assert.strictEqual(M.modelPages(Object.assign({}, c, { entry: row({ unit: "active", shared: true }) }))[0].fields[0].disabled, undefined)
  assert.strictEqual(M.modelPages(Object.assign({}, c, { sharing: "share" }))[0].fields[0].disabled, true, "its own click is waiting")
  assert.strictEqual(M.modelPages(Object.assign({}, c, { pending: "start" }))[1].fields[0].disabled, true)
  assert.deepStrictEqual(M.modelPages(Object.assign({}, c, { choices: [], variantsLoading: true }))[1].fields[0].note, { kind: "muted", text: "Asking the machine which sizes it has measured…" })
  assert.deepStrictEqual(M.modelPages(Object.assign({}, c, { choices: [], variantsError: "no recipe" }))[1].fields[0].note, { kind: "bad", text: "no recipe" })
})

test("modelValues and modelChange", () => {
  assert.deepStrictEqual(M.modelValues(row({ shared: true, ctx: 131072 })), { share: true, ctx: 131072 })
  const h = "me@spark-a", id = "qwen3.8-27b-tensorfold"
  assert.deepStrictEqual(M.modelChange(h, id, "share", true), { type: "share", host: h, id: id })
  assert.deepStrictEqual(M.modelChange(h, id, "share", false), { type: "unshare", host: h, id: id })
  assert.deepStrictEqual(M.modelChange(h, id, "logs", true), { type: "logs", host: h, id: id })
  assert.deepStrictEqual(M.modelChange(h, id, "ctx", 262144), { type: "setContext", host: h, id: id, ctx: 262144 })
  assert.deepStrictEqual(M.modelChange(h, id, "move-usb", true), { type: "move", host: h, id: id, to: "usb" })
  assert.deepStrictEqual(M.modelChange(h, id, "move-nvme", true), { type: "move", host: h, id: id, to: "nvme" })
  assert.strictEqual(M.modelChange(h, id, "nonsense", true), null)
})

test("keyAction: g opens the settings of the machine or the model under the cursor", () => {
  assert.deepStrictEqual(M.keyAction("g", { kind: "host", host: "h" }, null, "", false, false), { type: "hostSettings", host: "h" })
  assert.deepStrictEqual(M.keyAction("g", { kind: "model", host: "h", id: "m" }, row(), "", false, false), { type: "modelSettings", host: "h", id: "m" })
  assert.deepStrictEqual(M.keyAction("g", { kind: "add", host: "h" }, null, "", false, false), { type: "hostSettings", host: "h" })
  assert.strictEqual(M.keyAction("g", { kind: "host", host: "h" }, null, "", true, false), null, "an away machine has none")
})

// ---- one choice per context, and a row's line ----

// The engine's recipe nemotron-3.5-bolt-tensorfold: two variants at one context, a bigger setup and one for 64 GB.
const twice = [{ ctx: 262144, peak_ram_gib: 40, peak_gpu_gib: 40 }, { ctx: 262144, peak_ram_gib: 54, peak_gpu_gib: 54 }]

test("contextChoices: a context measured twice is one choice, with the numbers of the variant the engine runs", () => {
  // `use --ctx` picks, at that context, the variant that needs the most and still fits (the engine's pick_variant).
  const big = M.contextChoices(M.parseVariants(JSON.stringify(twice)), 262144, 121.6)
  assert.deepStrictEqual(big.map((x) => x.label + " " + x.need + " " + x.fits + " " + x.current), ["256K 54 true true"])
  const small = M.contextChoices(twice, 262144, 60)
  assert.deepStrictEqual(small.map((x) => x.label + " " + x.need + " " + x.fits), ["256K 40 true"], "a 64 GB machine falls back to the smaller one")
  const none = M.contextChoices(twice, 0, 32)
  assert.deepStrictEqual(none.map((x) => x.need + " " + x.fits), ["40 false"], "nothing fits: the smallest one's reason, as the engine gives")
  assert.match(none[0].text, /^Needs 40 GiB of memory and 8 GiB for the desktop/)
  assert.deepStrictEqual(M.contextChoices(twice, 0, 0).map((x) => x.need), [54], "memory unknown: the engine's first try")
  const mixed = M.contextChoices(twice.concat([{ ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 30 }, { ctx: 524288, peak_ram_gib: 90, peak_gpu_gib: 90 }]), 65536, 121.6)
  assert.deepStrictEqual(mixed.map((x) => x.label), ["512K", "256K", "64K"], "largest first, each once")
  // A drafted variant never fits, so a measured one at the same context is the one that runs.
  const drafted = M.contextChoices([{ ctx: 65536, peak_ram_gib: 50, peak_gpu_gib: 50, source: "drafted" }, { ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 30 }], 0, 121.6)
  assert.deepStrictEqual(drafted.map((x) => x.need + " " + x.source), ["30 measured"])
})

test("variantRows: a recipe's own list keeps every variant", () => {
  assert.deepStrictEqual(M.variantRows(M.parseVariants(JSON.stringify(twice))).map((x) => x.label + " " + x.need), ["256K 54", "256K 40"])
})

test("modelPages: the Context page offers a choice only when there is one to make", () => {
  const entry = row({ unit: "inactive", ctx: 262144 })
  const page = (variants, ram, over) => M.modelPages(Object.assign({ entry: entry, pending: "", sharing: "", store: null, location: "",
    choices: M.contextChoices(variants, entry.ctx, ram), variantsLoading: false, variantsError: "", away: false }, over))[1].fields[0]
  const one = page(twice, 121.6)
  assert.strictEqual(one.type, "info")
  assert.strictEqual(one.hint, "256K, which needs 54 GiB of memory. It is the only size the recipe has measured, so there is nothing to choose.")
  assert.strictEqual(one.note, undefined)
  const many = page(twice.concat([{ ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 30, source: "estimated", confirmed: true }]), 121.6)
  assert.strictEqual(many.type, "choice")
  assert.deepStrictEqual(many.options, [{ value: 262144, label: "256K · 54 GiB" }, { value: 65536, label: "64K · about 30 GiB" }], "each once, with what it needs")
  assert.strictEqual(M.modelValues(entry).ctx, many.options[0].value, "the size in use is the option that is lit")
  const none = page(twice, 32)
  assert.strictEqual(none.type, "info")
  assert.strictEqual(none.hint, "None of the sizes the recipe has measured fits this machine.")
  assert.match(none.note.text, /^It runs with 256K now, which is not offered\. Not offered\. 256K: Needs 40 GiB/)
  assert.strictEqual(page([], 121.6, { variantsLoading: true }).type, "info", "nothing to choose from while the machine is asked")
})

test("modelLine: state first, then context and memory, where the files are and Shared", () => {
  // Each fact's own spaces are no-break ones, so a wrapped line breaks between facts.
  const line = (entry, pending, location) => M.modelLine(entry, pending, location).replace(/\u00a0/g, "_")
  assert.strictEqual(line(row({ unit: "active", shared: true }), "", "usb"), "Running · 128K_context · On_USB · Shared")
  assert.strictEqual(line(row({ unit: "inactive" }), "", ""), "Stopped · 128K_context · 28_GiB", "no store: no location")
  assert.strictEqual(line(row({ unit: "inactive", fits: false, fit_reason: "Not enough memory" }), "", "both"), "Not enough memory · 128K_context · 28_GiB · On_NVMe_and_USB")
  assert.strictEqual(line(row({ unit: "failed", error: "CUDA error", shared: true }), "", "nvme"), "Failed · 128K_context · 28_GiB · On_NVMe · Shared", "the reason has its own line")
  assert.strictEqual(line(row({ unit: "installing", ctx: null, observed: null, install: { phase: "failed" }, error: "x" }), "", ""), "Setup failed")
  assert.strictEqual(line(row({ unit: "inactive" }), "move-usb", "nvme"), "Moving to USB · 128K_context · 28_GiB · On_NVMe")
  assert.strictEqual(line(row({ unit: "active" }), "queued stop", ""), "Running · stop queued · 128K_context")
})

test("the Context page: the size in use asks for nothing, and a model on a size no longer offered can still choose", () => {
  const h = "me@spark-a", id = "a"
  assert.strictEqual(M.modelChange(h, id, "ctx", 131072, row({ ctx: 131072 })), null, "the lit segment restarts nothing")
  assert.deepStrictEqual(M.modelChange(h, id, "ctx", 65536, row({ ctx: 131072 })), { type: "setContext", host: h, id: id, ctx: 65536 })
  const page = (entry, variants, ram, over) => M.modelPages(Object.assign({ entry: entry, pending: "", sharing: "", store: null, location: "",
    choices: M.contextChoices(variants, entry.ctx, ram), variantsLoading: false, variantsError: "", away: false }, over))
  // It runs 256K, which no longer fits; 64K does: one segment, not lit, and a note that says what runs now.
  const v = [{ ctx: 262144, peak_ram_gib: 200, peak_gpu_gib: 200 }, { ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 30 }]
  const stray = page(row({ unit: "active", ctx: 262144 }), v, 121.6)[1].fields[0]
  assert.strictEqual(stray.type, "choice")
  assert.deepStrictEqual(stray.options, [{ value: 65536, label: "64K · 30 GiB" }])
  assert.match(stray.note.text, /^It runs with 256K now, which is not offered\. Not offered\. 256K: /)
  // An unconfirmed estimate is not offered, and a measured variant at the same context is the one that runs.
  const est = M.contextChoices([{ ctx: 65536, peak_ram_gib: 50, peak_gpu_gib: 50, source: "estimated" }, { ctx: 65536, peak_ram_gib: 30, peak_gpu_gib: 30 }], 0, 121.6)
  assert.deepStrictEqual(est.map((x) => x.need + " " + x.source), ["30 measured"])
  // The page stays while the model restarts with the new size, dimmed; and is dimmed on a machine that isn't answering.
  const loading = page(row({ unit: "activating", ctx: 65536 }), v, 121.6)
  assert.strictEqual(loading[1].title, "Context")
  assert.strictEqual(loading[1].fields[0].disabled, true)
  assert.strictEqual(page(row({ unit: "inactive", ctx: 65536 }), v, 121.6, { away: true })[1].fields[0].disabled, true)
  assert.strictEqual(page(row({ unit: "installing", ctx: null }), v, 121.6).length, 1, "a setup has no Context page yet")
  assert.strictEqual(page(row({ unit: "inactive" }), [], 121.6, { variantsError: "no recipe" })[1].fields[0].hint, "The sizes the recipe has measured.")
})
