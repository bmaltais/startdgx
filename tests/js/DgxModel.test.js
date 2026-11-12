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
  assert.strictEqual(M.parseStatus(JSON.stringify({ models: { "qwen3.8-27b-tensorfold": row({ unit: "exploded" }) } })), null, "an unknown unit")
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
  assert.strictEqual(M.parsePeers(JSON.stringify(peers)).length, 6)
  assert.deepStrictEqual(M.parsePeers("[]"), [])
  assert.strictEqual(M.parsePeers("{}"), null)
  assert.strictEqual(M.parsePeers(JSON.stringify([{ name: "x" }])), null, "a peer with no target")
  assert.strictEqual(M.parsePeers("x"), null)
})

test("peerOffer: what the Add machine card offers for each machine of the tailnet", () => {
  const offer = (name, over) => M.peerOffer(Object.assign({}, peers.find((p) => p.name === name), over))
  assert.deepStrictEqual(offer("spark-d"), { action: "add", text: "DGX Spark · ready to add" })
  assert.deepStrictEqual(offer("spark-e"), { action: "install", text: "DGX Spark · not set up yet" })
  assert.deepStrictEqual(offer("spark-c"), { action: null, text: "ssh: connect to host spark-c port 22: Connection timed out" })
  assert.deepStrictEqual(offer("workstation"), { action: null, text: "Not a DGX Spark" })
  assert.deepStrictEqual(offer("spark-a", { added: true }), { action: null, text: "Added" })
  assert.deepStrictEqual(offer("spark-e", { engine: true }), { action: "add", text: "DGX Spark · has an engine startdgx didn't install" })
  assert.deepStrictEqual(offer("spark-c", { reason: null }), { action: null, text: "Not answering" })
})

test("rows: the keyboard cursor's list, each machine then its models", () => {
  const r = M.rows(["h1", "h2", "h3"], { h1: up(models(b, a)), h2: up({}), h3: undefined })
  assert.deepStrictEqual(r.map((x) => x.kind + ":" + x.host + (x.id ? "/" + x.id : "")), ["host:h1", "model:h1/a", "model:h1/b", "host:h2", "host:h3"])
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
