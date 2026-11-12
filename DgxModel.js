// The rules of the manager, with no Quickshell imports so they run under Node (tests/js/DgxModel.test.js).
// A host is an SSH target from `startdgx hosts --json`; its status is the engine's `status --json`, read
// through `startdgx status HOST`; an entry is one model row of that status (the engine's model_record).
// The validation, the start/stop progress curve and the download figures are adapted from Omarchy's agents
// plugin (shell/plugins/agents/Main.qml and Panel.qml), MIT, Copyright (c) David Heinemeier Hansson.

.pragma library

// The engine's unit states: a setup in progress, then systemd's.
var UNITS = ["installing", "active", "activating", "inactive", "failed", "deactivating", "removing"]

// A model's key, "host/model": in pending, setups, marks and the cursor. A target has no "/", a recipe id neither.
function modelKey(host, id) { return host + "/" + id }
function keyHost(key) { return key.substring(0, key.lastIndexOf("/")) }
function keyModel(key) { return key.substring(key.lastIndexOf("/") + 1) }
// A share's own mark, apart from its model's: "host/model#share" in the service's `pending`, so a share neither hides
// what the model is doing (a load, a stop) nor is hidden by it, and no start, stop or removal supersedes it.
function shareKey(host, id) { return modelKey(host, id) + "#share" }

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

// JSON text as a value, or undefined when it isn't JSON.
function parseJson(text) {
  try { return JSON.parse(String(text || "")) } catch (e) { return undefined }
}

// A status document, or null when it isn't one. A unit the engine's list doesn't have (systemd's reloading,
// maintenance, refreshing, ...) is read as inactive, as the engine's own REMOTE_UNITS does for a paired machine's.
function parseStatus(text) {
  const parsed = parseJson(text)
  if (!isPlainObject(parsed) || !isPlainObject(parsed.models)) return null
  for (const id in parsed.models) {
    const entry = parsed.models[id]
    if (!isPlainObject(entry) || entry.recipe !== id || id === "") return null
    if (UNITS.indexOf(entry.unit) < 0) parsed.models[id] = Object.assign({}, entry, { unit: "inactive" })
  }
  return parsed
}

// What a status read says: { status } or { status: null, error }. An answer that can't be read is a failure to say,
// not one to keep quiet about: the machine shows as not answering, with why.
function statusAnswer(code, stdout, stderr, host) {
  if (code !== 0) return { status: null, error: errorLine(stderr, host + " didn't answer") }
  const status = parseStatus(stdout)
  return status ? { status: status } : { status: null, error: host + " sent an unreadable status" }
}

// A click's mark on its model ("host/model" in the service's `pending`): "start", "stop" or "delete" from the moment
// its command runs on the machine until the machine's next answer after it, or "queued start" (stop, delete) while
// it waits its turn behind another command there.
function pendingOf(pending) {
  const s = String(pending || "")
  const queued = s.indexOf("queued ") === 0
  return { kind: queued ? s.substring(7) : s, queued: queued }
}

var QUEUED_WORDS = { start: "start queued", stop: "stop queued", delete: "removal queued" }

// What a model is doing, as one word for the row's colour and dot (`kind`) and the words under its name:
// running, loading, stopping, removing, installing, failed, doesNotFit or stopped. `pending` is a start, stop
// or delete just asked for, which shows once its command runs; the host's answer wins as soon as it has moved on
// (a delete returns only once the model is gone, so it shows until then; of a setup, it is a cancel). One still
// waiting its turn leaves the machine's state as it is, and says it is queued.
function modelState(entry, pending) {
  const p = pendingOf(pending)
  if (p.queued) {
    const now = modelState(entry, "")
    return { kind: now.kind, text: now.text + " · " + (QUEUED_WORDS[p.kind] || p.kind + " queued") }
  }
  pending = p.kind
  const unit = entry.unit
  const error = String(entry.error || "")
  const phase = entry.install ? entry.install.phase : ""
  if (pending === "delete" && unit !== "removing") return { kind: "removing", text: unit === "installing" ? "Cancelling" : "Removing" }
  if (pending === "start" && (unit === "inactive" || unit === "failed")) return { kind: "loading", text: "Loading" }
  if (pending === "stop" && (unit === "active" || unit === "activating")) return { kind: "stopping", text: "Stopping" }
  switch (unit) {
  case "installing":
    if (phase === "failed") return { kind: "failed", text: error || "Setup failed" }
    return { kind: "installing", text: phase === "waiting" ? "Waiting to download" : "Downloading" }
  case "active": return { kind: "running", text: "Running" }
  case "activating": return { kind: "loading", text: "Loading" }
  case "deactivating": return { kind: "stopping", text: "Stopping" }
  case "removing": return { kind: "removing", text: "Removing" }
  case "failed": return { kind: "failed", text: error || "Failed to start" }
  }
  if (error !== "") return { kind: "failed", text: error }
  if (entry.fits === false) return { kind: "doesNotFit", text: String(entry.fit_reason || "") || "Not enough memory" }
  return { kind: "stopped", text: "Stopped" }
}

// Not enough free memory to start: the play button is greyed out (not hidden, so its reason shows on hover).
function startBlocked(entry) {
  return !!entry && (entry.unit === "inactive" || entry.unit === "failed") && entry.fits === false
}

// What the play/pause button does: "start", "stop", or null while it waits (stopping, removing, a setup, no room,
// a stop or removal waiting its turn). A start waiting its turn can be taken back.
function toggleAction(entry, pending) {
  const p = pendingOf(pending)
  if (p.queued) return p.kind === "start" ? "stop" : null
  const kind = modelState(entry, pending).kind
  if (kind === "running" || kind === "loading") return "stop"
  if (startBlocked(entry)) return null
  if (kind === "stopped" || (kind === "failed" && entry.unit !== "installing")) return "start"
  return null
}

// The key an action's mark and queue entry go under: a share's own, apart from its model's.
function actionKey(host, id, kind) { return kind === "share" || kind === "unshare" ? shareKey(host, id) : modelKey(host, id) }

// What the Tailscale button does, for any model that is set up (sharing stands whether or not it runs; the engine lists a
// shared model on the tailnet in whatever state it is): "share" while private, "unshare" while shared, or null while its
// own click waits, for a model being set up or removed, and once a removal is asked. `sharing` is the share's own mark.
function shareAction(entry, pending, sharing) {
  if (!entry || String(sharing || "") !== "") return null
  if (entry.unit === "installing" || entry.unit === "removing" || pendingOf(pending).kind === "delete") return null
  return entry.shared === true ? "unshare" : "share"
}

// A start or stop runs steadily to 90% at the time the last one took, then keeps creeping toward 98%, so one
// that runs long reads as slow, not stuck.
function phaseProgress(elapsed, expected) {
  if (!(expected > 0)) return 0
  if (elapsed <= expected) return 0.9 * elapsed / expected
  return 0.9 + 0.08 * (1 - Math.exp(-(elapsed - expected) / expected))
}

// A download's speed beside its bar, and how much of it has arrived, in decimal units. Nothing while the speed
// is still zero or the total unknown.
function downloadRate(rate) {
  return rate > 0 ? Math.round(rate / 1e6) + " MB/s" : ""
}

function downloadAmount(done, total) {
  return total > 0 ? (done / 1e9).toFixed(1) + " of " + (total / 1e9).toFixed(1) + " GB" : ""
}

// The bar under a model: { label, fraction (0-1), value } or null when there is none. A download shows how
// much has arrived, a load, stop or removal its progress against how long the last one took, a running model
// its memory out of the host's.
function meter(entry, nowMs, pending) {
  if (pendingOf(pending).queued) pending = ""
  const state = modelState(entry, pending)
  const kind = state.kind
  const elapsed = entry.since_ms ? Math.max(0, (nowMs - Number(entry.since_ms)) / 1000) : 0
  const seconds = function (value, fallback) { return Number(value) > 0 ? Number(value) : fallback }
  switch (kind) {
  case "installing": {
    const install = entry.install || {}
    if (install.phase === "waiting") return { label: "Waiting", fraction: 0, value: "" }
    const total = Number(install.total_bytes) || 0
    return { label: "Downloading", fraction: total > 0 ? (Number(install.done_bytes) || 0) / total : 0, value: downloadRate(Number(install.rate_bytes_s) || 0) }
  }
  case "loading": return { label: "Loading", fraction: phaseProgress(elapsed, seconds(entry.expected_load_seconds, 60)), value: "" }
  case "stopping": return { label: "Stopping", fraction: phaseProgress(elapsed, seconds(entry.expected_stop_seconds, 10)), value: "" }
  case "removing":
    // Asked for, and the machine hasn't begun: nothing to measure yet.
    if (entry.unit !== "removing") return { label: state.text, fraction: 0, value: "" }
    return { label: state.text, fraction: phaseProgress(elapsed, seconds(entry.expected_remove_seconds, 10)), value: "" }
  case "running": {
    const used = entry.observed ? Number(entry.observed.ram_used_gib) || 0 : 0
    const total = Number(entry.ram_total_gib) || 0
    return { label: "Memory", fraction: total > 0 ? Math.min(1, used / total) : 0, value: Math.round(used) + " of " + Math.round(total) + " GiB" }
  }
  }
  return null
}

// The facts under a model's name: its context, and the memory it took when it last ran (a running model's is on its meter).
function modelFacts(entry) {
  const facts = []
  if (Number(entry.ctx) > 0) facts.push(Math.round(Number(entry.ctx) / 1024) + "K context")
  const used = entry.observed ? Number(entry.observed.ram_used_gib) || 0 : 0
  if (used > 0 && entry.unit !== "active") facts.push(Math.round(used) + " GiB")
  return facts.join(" · ")
}

// ---- machines ----------------------------------------------------------------------------------------

// `startdgx hosts --json`: { target: { profile } }, or null when it isn't that.
function parseHosts(text) {
  const parsed = parseJson(text)
  if (!isPlainObject(parsed)) return null
  for (const host in parsed) if (!isPlainObject(parsed[host])) return null
  return parsed
}

// A target's machine name: demo@spark-a is spark-a.
function hostName(target) {
  const s = String(target || "")
  return s.substring(s.lastIndexOf("@") + 1)
}

// What the machine is, from the profile `add` recorded: "DGX Spark · 128 GB".
function hostLine(profile) {
  if (!isPlainObject(profile)) return ""
  const gpus = Array.isArray(profile.gpus) ? profile.gpus : []
  const spark = /gb10/i.test(String(profile.platform || "")) || gpus.some(function (g) { return /gb10/i.test(String(g && g.family || "")) })
  const parts = [spark ? "DGX Spark" : String(profile.platform || "Linux")]
  if (Number(profile.ram_class) > 0) parts.push(Number(profile.ram_class) + " GB")
  if (isPlainObject(profile.pair) && profile.pair.peer) parts.push("cabled to " + profile.pair.peer)
  return parts.join(" · ")
}

function lines(text) {
  return String(text || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l !== "" })
}

// The last line a command printed: what it did.
function lastLine(stdout) {
  const all = lines(stdout)
  return all.length ? all[all.length - 1] : ""
}

// Why a command failed: its last stderr line, without the CLI's "Error: ".
function errorLine(stderr, fallback) {
  return lastLine(stderr).replace(/^Error: /, "") || fallback
}

function formatAgo(ms) {
  if (ms < 60e3) return "just now"
  if (ms < 3600e3) return Math.floor(ms / 60e3) + " min ago"
  if (ms < 86400e3) return Math.floor(ms / 3600e3) + " h ago"
  return Math.floor(ms / 86400e3) + " d ago"
}

// A machine that answered no (one not heard from yet isn't away).
function isAway(hs) {
  return !!hs && !!hs.loaded && !hs.online
}

// A machine that doesn't answer: why, and when it last did.
function offlineText(error, lastSeenMs, nowMs) {
  const why = String(error || "") || "Not answering"
  return lastSeenMs > 0 ? why + " · last seen " + formatAgo(Math.max(0, nowMs - lastSeenMs)) : why
}

// A host's models, in name order.
function modelList(status) {
  if (!status || !isPlainObject(status.models)) return []
  const out = Object.keys(status.models).map(function (id) { return status.models[id] })
  const label = function (e) { return String(e.name || e.recipe) }
  out.sort(function (a, b) { return label(a).localeCompare(label(b)) })
  return out
}

// ---- the whole picture -----------------------------------------------------------------------------------
// A host's state, as the service keeps it: { loaded, online, error, status, lastSeenMs }. Not loaded is a
// machine not heard from yet; an away one keeps its last good status, drawn dimmed.

var BUSY_KINDS = ["loading", "stopping", "removing", "installing"]

function hostBusy(hs) {
  return !!hs && modelList(hs.status).some(function (e) { return BUSY_KINDS.indexOf(modelState(e).kind) >= 0 })
}

// Counts for the count line, and the bar icon's state: alert (a machine away or a model failed), busy (a model
// loading, stopping, being removed or set up), running, or idle.
function summarize(hostList, hostStates) {
  const s = { machines: hostList.length, offline: 0, models: 0, running: 0, busy: 0, failed: 0, kind: "idle" }
  for (let i = 0; i < hostList.length; i++) {
    const hs = hostStates[hostList[i]]
    if (!hs || !hs.loaded) continue
    if (!hs.online) { s.offline++; continue }
    const list = modelList(hs.status)
    s.models += list.length
    for (let j = 0; j < list.length; j++) {
      const kind = modelState(list[j]).kind
      if (kind === "running") s.running++
      else if (kind === "failed") s.failed++
      else if (BUSY_KINDS.indexOf(kind) >= 0) s.busy++
    }
  }
  s.kind = s.offline > 0 || s.failed > 0 ? "alert" : s.busy > 0 ? "busy" : s.running > 0 ? "running" : "idle"
  return s
}

// The manager's count line, in small capitals: "2 MACHINES · 1 RUNNING · 1 NOT ANSWERING".
function subtitle(s) {
  if (s.machines === 0) return "NO MACHINES ADDED"
  const parts = [s.machines + (s.machines === 1 ? " MACHINE" : " MACHINES")]
  parts.push(s.running > 0 ? s.running + " RUNNING" : "NOTHING RUNNING")
  if (s.busy > 0) parts.push(s.busy + " BUSY")
  if (s.failed > 0) parts.push(s.failed + " FAILED")
  if (s.offline > 0) parts.push(s.offline + " NOT ANSWERING")
  return parts.join(" · ")
}

// How often to ask a host for its status: every 2.5 s while the manager is open or a model on it is moving,
// once a minute otherwise (which keeps the bar icon honest); an away machine costs an SSH timeout per try,
// so it is asked less.
function pollInterval(windowOpen, hs) {
  if (!hs || !hs.loaded) return 2500
  if (!hs.online) return windowOpen ? 10000 : 120000
  return windowOpen || hostBusy(hs) ? 2500 : 60000
}

// ---- adding a machine ----------------------------------------------------------------------------------

// `startdgx discover --json`: a list of peers, each with at least a name and a target, or null.
function parsePeers(text) {
  const parsed = parseJson(text)
  if (!Array.isArray(parsed)) return null
  for (let i = 0; i < parsed.length; i++) {
    const p = parsed[i]
    if (!isPlainObject(p) || typeof p.name !== "string" || typeof p.target !== "string") return null
  }
  return parsed
}

// What the Add machine card offers for a peer: { action, install, text }. `action` is what Enter does ("add",
// "install" or null), `install` the Install… button it has ("install", "replace" for an engine startdgx didn't
// install, which `install --replace-engine` backs up first, or ""). A Spark with startdgx's engine is added (add only
// asks the engine for its profile); one with another engine can be added as it is or installed over; one with none
// is installed, in a terminal.
function peerOffer(peer) {
  const none = function (text) { return { action: null, install: "", text: text } }
  if (!peer.reachable) return none(String(peer.reason || "") || "Not answering")
  if (peer.added) return none("Added")
  if (!peer.spark) return none("Not a DGX Spark")
  if (peer.installed) return { action: "add", install: "", text: "DGX Spark · ready to add" }
  if (peer.engine) {
    return { action: "add", install: "replace", text: "DGX Spark · an engine startdgx didn't install is here; Install… backs it up first" }
  }
  return { action: "install", install: "install", text: "DGX Spark · not set up yet" }
}

// Whether a failed command's error is the engine saying the machine needs its one-time root setup (prepare_host:
// Podman for NVIDIA), which a person must run in a terminal, where sudo can ask: the manager then offers Install….
function setupNeeded(error) {
  const e = String(error || "")
  return e.indexOf("needs Podman set up as root first") >= 0 || e.indexOf("Run setup once in a terminal") >= 0
}

// The footer's line when a command failed: its error, or, when the machine needs its root setup, where to start it
// (the machine's row says the rest).
function actionError(stderr, host) {
  const line = errorLine(stderr, "The action failed")
  return setupNeeded(line) ? hostName(host) + " needs its one-time root setup: Install… on its row runs it" : line
}

// The footer's line after a command: its last line, without the engine's pointers elsewhere (the agents panel, a
// journalctl command), since the row itself follows a setup.
function actionNotice(kind, stdout) {
  const line = lastLine(stdout)
  if (kind !== "use") return line
  return line.replace(/; (the agents panel shows its progress, or )?follow it with: journalctl.*$/, "")
}

// ---- keyboard ----------------------------------------------------------------------------------------

// The manager's rows, top to bottom, for the keyboard cursor: each machine, then its models, then its Add model…
// row (only on a machine that answers: a picker needs its catalog).
function rows(hostList, hostStates) {
  const out = []
  for (let i = 0; i < hostList.length; i++) {
    const host = hostList[i]
    out.push({ kind: "host", host: host })
    const hs = hostStates[host]
    const list = modelList(hs ? hs.status : null)
    for (let j = 0; j < list.length; j++) out.push({ kind: "model", host: host, id: list[j].recipe })
    if (hs && hs.loaded && hs.online) out.push({ kind: "add", host: host })
  }
  return out
}

// The keys that act on a model or machine: held down, they act once, not again on each repeat.
var ONCE_KEYS = ["enter", "s", "d", "delete", "f", "t"]

// A key typed in the manager ("enter" for Return, "delete" for Delete). `row` is the one under the cursor (or null), `entry` its
// model's status row, `pending` a start or stop already asked for, `away` whether its machine isn't answering (it
// then has no Start, Stop or Logs), `repeat` whether this is the key's auto-repeat, and `sharing` its share's mark. A
// model's row acts for its machine too. Forget, like Uninstall and Remove, opens a card that asks first.
function keyAction(key, row, entry, pending, away, repeat, sharing) {
  const k = String(key).toLowerCase()
  if (repeat && ONCE_KEYS.indexOf(k) >= 0) return null
  if (k === "r") return { type: "refresh" }
  if (k === "n") return { type: "addMachine" }
  if (!row) return null
  if (k === "u") return { type: "uninstall", host: row.host }
  if (k === "f") return { type: "forget", host: row.host }
  if (away) return null
  if (k === "l") return { type: "logs", host: row.host, id: row.kind === "model" ? row.id : "" }
  if (k === "a" || (k === "enter" && row.kind === "add")) return { type: "addModel", host: row.host }
  if ((k === "d" || k === "delete") && row.kind === "model" && removeAction(entry, pending)) return { type: "removeModel", host: row.host, id: row.id }
  if (k === "t" && row.kind === "model" && entry) {
    const share = shareAction(entry, pending, sharing)
    return share ? { type: share, host: row.host, id: row.id } : null
  }
  if ((k === "s" || k === "enter") && row.kind === "model" && entry) {
    const action = toggleAction(entry, pending)
    return action ? { type: action, host: row.host, id: row.id } : null
  }
  return null
}

// ---- a machine's commands ----------------------------------------------------------------------------
// Each machine runs at most three commands at once, each slot with its own queue: a start, which returns only once its
// model has loaded (up to 15 minutes), a share (the engine's own lock, so it never waits for a removal either), and any
// other (stop, set up, remove). So a Stop never waits for a load to end.
// The engine's own lock still orders what it must: its start and remove take it, its stop and `use --detach` don't.
// An action is { op, key, kind, shows }: op numbers the click it comes from, key is "host/model", kind is the command
// (start, stop, use, delete, share, unshare; a share's key is shareKey) and shows the mark its row gets while it runs (a removal's stop shows as the removal).

function newQueue() { return { starting: null, other: null, sharing: null, starts: [], others: [], shares: [] } }

function copyQueue(q) { return { starting: q.starting, other: q.other, sharing: q.sharing, starts: q.starts.slice(), others: q.others.slice(), shares: q.shares.slice() } }

function sameKey(key) { return function (a) { return a.key === key } }

// A click, put in its queue: { queue, dropped }. A stop or removal takes back a start of that model still waiting its
// turn (dropped), and a removal the model's queued shares, and supersedes one that is loading: its exit is then not a failure to report. A removal of a model
// that is loading stops it first, since the engine's remove waits for the lock its start holds. A stop of a model
// whose only start was taken back sends nothing. A start of a model being stopped or removed is dropped.
function submit(q, action, entry) {
  const key = action.key
  const out = copyQueue(q)
  const busy = [out.other].concat(out.others).some(function (a) { return a && a.key === key && (a.kind === "stop" || a.kind === "delete") })
  if (action.kind === "start") {
    if (busy) return { queue: out, dropped: [action] }
    out.starts.push(action)
    return { queue: out, dropped: [] }
  }
  if (action.kind === "stop" || action.kind === "delete") {
    const dropped = out.starts.filter(sameKey(key))
    out.starts = out.starts.filter(function (a) { return a.key !== key })
    // A removal takes back the model's shares still waiting: they would only fail, "isn't set up", once it is gone.
    if (action.kind === "delete") out.shares = out.shares.filter(function (a) { return a.key !== shareKey(keyHost(key), keyModel(key)) })
    const loading = !!out.starting && out.starting.key === key
    if (loading) out.starting = Object.assign({}, out.starting, { superseded: true })
    const unit = entry ? entry.unit : ""
    const runs = unit === "active" || unit === "activating"
    if (action.kind === "stop" && !loading && !runs && dropped.length > 0) return { queue: out, dropped: dropped }
    if (action.kind === "delete" && loading) out.others.push({ op: action.op, key: key, kind: "stop", shows: "delete" })
    out.others.push(action)
    return { queue: out, dropped: dropped }
  }
  if (action.kind === "share" || action.kind === "unshare") out.shares.push(action)
  else out.others.push(action)
  return { queue: out, dropped: [] }
}

// What can begin now, on each free slot: { queue, run }.
function launch(q) {
  const out = copyQueue(q)
  const run = []
  if (!out.starting && out.starts.length) { out.starting = out.starts.shift(); run.push(out.starting) }
  if (!out.other && out.others.length) { out.other = out.others.shift(); run.push(out.other) }
  if (!out.sharing && out.shares.length) { out.sharing = out.shares.shift(); run.push(out.sharing) }
  return { queue: out, run: run }
}

// A slot's command ended ("start", "share" or "other"): { queue, action } with the action that ran there, or null.
function finish(q, slot) {
  const field = slot === "start" ? "starting" : slot === "share" ? "sharing" : "other"
  const out = Object.assign({}, q)
  const action = q[field] || null
  out[field] = null
  return { queue: out, action: action }
}

// Each model's mark, "host/model" -> its pending string: what runs shows its `shows` (a superseded start never does:
// the stop or removal that superseded it has its own), what waits "queued <kind>" (unless it belongs to the click that
// runs), and `done` ("host/model" -> { shows, op }, the finished actions whose machine hasn't answered since) shows
// until it has.
function marks(q, done) {
  const out = {}
  const runningOp = {}
  for (const key in done) out[key] = done[key].shows
  ;[q.starting, q.other, q.sharing].forEach(function (a) {
    if (a && !a.superseded) { out[a.key] = a.shows; runningOp[a.key] = a.op }
  })
  q.starts.concat(q.others, q.shares).forEach(function (a) {
    if (a.kind === "use" || runningOp[a.key] === a.op) return
    out[a.key] = "queued " + a.shows
  })
  return out
}

// The finished actions' marks once a status read after them has arrived (`answered`: [{ key, op }]): each goes,
// unless a newer click on that model has put its own there.
function settle(done, answered) {
  const out = Object.assign({}, done)
  for (let i = 0; i < answered.length; i++) {
    const a = answered[i]
    if (out[a.key] && out[a.key].op === a.op) delete out[a.key]
  }
  return out
}

// The startdgx command an action runs, with how long it may take: a start returns once its model has loaded; a
// removal may first wait for a start ahead of it that holds the engine's lock (900 s), then removes, and a killed
// ssh could leave it half done.
function commandFor(host, action) {
  const id = keyModel(action.key).replace(/#share$/, "")
  switch (action.kind) {
  case "start": return ["start", host, id, "--timeout", "900"]
  case "stop": return ["stop", host, id, "--timeout", "120"]
  case "use": return ["use", "--detach", host, id, "--timeout", "120"]
  case "delete": return ["delete", host, id, "--timeout", "1500"]
  // The engine publishes the model's route with tailscale serve, which can take a while.
  case "share": return ["share", host, id, "--timeout", "120"]
  case "unshare": return ["share", host, id, "--off", "--timeout", "120"]
  }
  return null
}

// ---- notifications -------------------------------------------------------------------------------------

// New failures to tell the desktop about, each once: a model that failed or a setup that did, keyed by its
// error so a different failure is said too. `announced` is what was said and is still true; a machine that
// is away keeps its keys, since nothing is known about it.
function alerts(hostList, hostStates, announced) {
  const list = []
  const next = {}
  for (let i = 0; i < hostList.length; i++) {
    const host = hostList[i]
    const hs = hostStates[host]
    if (!hs || !hs.loaded) continue
    if (!hs.online) {
      for (const key in announced) if (key.indexOf(host + "/") === 0) next[key] = true
      continue
    }
    const entries = modelList(hs.status)
    for (let j = 0; j < entries.length; j++) {
      const e = entries[j]
      const state = modelState(e)
      if (state.kind !== "failed") continue
      const key = modelKey(host, e.recipe) + ":" + state.text
      next[key] = true
      if (announced[key]) continue
      const name = String(e.name || e.recipe)
      list.push({ key: key, title: name + (e.unit === "installing" ? " could not be set up on " : " failed on ") + hostName(host), body: state.text })
    }
  }
  return { list: list, announced: next }
}

// ---- adding and removing models ----------------------------------------------------------------------

// `startdgx list HOST`: the engine's catalog for that machine (recipe_listing), a list of recipes each with an id,
// or null when it isn't that.
function parseRecipes(text) {
  const parsed = parseJson(text)
  if (!Array.isArray(parsed)) return null
  for (let i = 0; i < parsed.length; i++) {
    const r = parsed[i]
    if (!isPlainObject(r) || typeof r.id !== "string" || r.id === "") return null
  }
  return parsed
}

// The model picker's rows for one machine: every recipe of its catalog, with what the picker offers for it:
// { recipe, action: "use" | null, text, best }. A recipe the machine can run and doesn't have yet can be set up
// ("use"); one it has (or is setting up) says so; one it can't run says why. The engine's recommendation
// (`best`) comes first, then what can be set up, what is set up, and what can't run, each in name order.
function recipeOffers(list, status) {
  const models = status && isPlainObject(status.models) ? status.models : {}
  const offers = (Array.isArray(list) ? list : []).map(function (r) {
    const entry = models[r.id]
    const best = r.best === true
    if (entry) return { recipe: r, action: null, text: entry.unit === "installing" ? "Being set up" : "On this machine", best: best, rank: entry.unit === "installing" ? 2 : 3 }
    if (r.installed === true) return { recipe: r, action: null, text: "On this machine", best: best, rank: 3 }
    if (r.available !== true) return { recipe: r, action: null, text: String(r.reason || "") || "Can't run on this machine", best: best, rank: 4 }
    return { recipe: r, action: "use", text: best ? "Recommended for this machine" : "", best: best, rank: best ? 0 : 1 }
  })
  const label = function (o) { return String(o.recipe.name || o.recipe.id) }
  offers.sort(function (a, b) { return a.rank - b.rank || label(a).localeCompare(label(b)) || a.recipe.id.localeCompare(b.recipe.id) })
  return offers.map(function (o) { return { recipe: o.recipe, action: o.action, text: o.text, best: o.best } })
}

// The facts under a recipe in the picker: the memory it takes, its context and its speed, measured on this machine class.
function recipeFacts(r) {
  const facts = []
  if (Number(r.memory_gib) > 0) facts.push(Math.round(Number(r.memory_gib)) + " GiB memory")
  if (Number(r.context) > 0) facts.push(Math.round(Number(r.context) / 1024) + "K context")
  if (Number(r.decode_tok_s) > 0) facts.push(Math.round(Number(r.decode_tok_s)) + " TPS")
  return facts.join(" · ")
}

// A model being set up, as the machine will list it once its setup has begun, for a recipe just asked for: the
// row shows at once, waiting, rather than after the command and the next poll.
function setupRow(r) {
  return { error: "", fits: true, fit_reason: "", recipe: r.id, name: String(r.name || r.id), vendor: String(r.vendor || ""),
    runtime: "", image: "", ctx: null, unit: "installing", sub_state: "", result: "", port: null, endpoint: "", observed: null,
    since_ms: null, expected_load_seconds: null, expected_stop_seconds: null, expected_remove_seconds: null,
    install: { phase: "waiting", done_bytes: 0, total_bytes: 0, rate_bytes_s: 0 } }
}

// The host states as the manager draws them: each machine's status with the setups just asked for on it
// ("host/model" -> its recipe) that it doesn't list yet. A machine not heard from is left as it is.
function withSetups(hostStates, setups) {
  let out = hostStates
  for (const key in setups) {
    const host = keyHost(key)
    const id = keyModel(key)
    const hs = out[host]
    if (!hs || !hs.status || !isPlainObject(hs.status.models) || hs.status.models[id]) continue
    const models = Object.assign({}, hs.status.models)
    models[id] = setupRow(setups[key])
    if (out === hostStates) out = Object.assign({}, hostStates)
    out[host] = Object.assign({}, hs, { status: Object.assign({}, hs.status, { models: models }) })
  }
  return out
}

// The setups still waiting to show, once `host` has answered with `status`: those it lists now are its own.
function settleSetups(setups, host, status) {
  const models = status && isPlainObject(status.models) ? status.models : {}
  let out = setups
  for (const key in setups) {
    if (key.indexOf(host + "/") !== 0 || !models[key.substring(host.length + 1)]) continue
    if (out === setups) out = Object.assign({}, setups)
    delete out[key]
  }
  return out
}

// What a model's Remove does: "remove" (stop it if it runs, delete its weights), "cancel" (stop a setup and delete
// what it downloaded; a failed setup is cleared the same way), or null while it waits: being removed, stopping,
// or a click on its way.
function removeAction(entry, pending) {
  if (!entry || pending) return null
  if (entry.unit === "installing") return "cancel"
  if (entry.unit === "removing" || entry.unit === "deactivating") return null
  return "remove"
}

// A size in the engine's binary units, as its own messages give them.
function sizeText(bytes) {
  const n = Number(bytes) || 0
  return n >= 1073741824 ? (n / 1073741824).toFixed(1) + " GiB" : (n / 1048576).toFixed(1) + " MiB"
}

// The remove card's words for a model on a machine: { title, body, button, keep }. `bytes` is what the removal
// frees (`delete --dry-run`), or null until the machine has said; `unknown` when it couldn't say, which leaves the
// question without the figure (the removal can still go ahead).
function removeConfirm(entry, host, bytes, unknown) {
  const name = String(entry.name || entry.recipe || "")
  const known = bytes !== null && bytes !== undefined
  if (removeAction(entry) === "cancel") {
    return { title: "Cancel the setup of " + name + " on " + hostName(host) + "?", button: "Cancel setup", keep: "Keep going",
      body: !known ? "This stops the download and deletes what it downloaded." + (unknown ? "" : " Asking the machine how much that is…")
        : bytes > 0 ? "This stops the download and deletes the " + sizeText(bytes) + " downloaded so far."
        : "This stops the setup. Nothing has been downloaded yet." }
  }
  const stops = entry.unit === "active" || entry.unit === "activating" ? "This stops the model and deletes its weights" : "This deletes its weights"
  return { title: "Remove " + name + " from " + hostName(host) + "?", button: "Remove", keep: "Keep it",
    body: !known ? stops + "." + (unknown ? "" : " Asking the machine how much space that frees…")
      : bytes > 0 ? stops + ", freeing " + sizeText(bytes) + " that no other model uses. Setting it up again downloads them again."
      : (entry.unit === "active" || entry.unit === "activating" ? "This stops the model and deletes it." : "This deletes it.")
        + " Its weights are shared with another model, so no space is freed." }
}

// `startdgx delete HOST MODEL --dry-run --json`: { recipe, setting_up, bytes } (what the removal frees), or null.
function parseRemovePlan(text) {
  const parsed = parseJson(text)
  if (!isPlainObject(parsed) || typeof parsed.recipe !== "string" || typeof parsed.bytes !== "number" || !(parsed.bytes >= 0)) return null
  return parsed
}

// ---- uninstalling ------------------------------------------------------------------------------------------

function stringList(value) {
  return Array.isArray(value) && value.every(function (s) { return typeof s === "string" })
}

// `startdgx uninstall HOST --dry-run --json`: { host, steps, kept, manual, models_bytes, packages }, or null.
function parseUninstallPlan(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || !stringList(p.steps) || !stringList(p.kept) || !stringList(p.manual) || !stringList(p.packages)) return null
  if (p.models_bytes !== null && !(typeof p.models_bytes === "number" && p.models_bytes >= 0)) return null
  return p
}

// The plan as the uninstall card shows it: what it does, what it keeps, then what is left for you.
function uninstallText(plan) {
  return plan.steps.concat(plan.kept, ["", "Left for you to do:"], plan.manual).join("\n")
}

// What the uninstall card lets you opt into, each off by default and only where it would do something: deleting the
// model weights (--delete-models) and removing the packages the install added (--remove-packages).
function uninstallChoices(plan) {
  const out = []
  if (plan.models_bytes !== null && plan.models_bytes > 0) {
    out.push({ flag: "--delete-models", label: "Also delete the model weights", description: "Frees " + sizeText(plan.models_bytes) + ". Setting a model up again downloads it again." })
  }
  if (plan.packages.length > 0) {
    out.push({ flag: "--remove-packages", label: "Also remove the packages the install added",
      description: plan.packages.join(", ") + ". Anything else on the machine that uses them stops working; python3 always stays." })
  }
  return out
}

// An alert as the notify-send command that says it: `--` first, so a title from a host that starts with a dash isn't
// read as an option, and the body's markup characters escaped, since notification servers read the body as markup.
function notifyCommand(alert) {
  const body = String(alert.body).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  return ["notify-send", "--app-name=StartDGX", "--urgency=critical", "--", String(alert.title), body]
}

// ---- a query ----------------------------------------------------------------------------------------------
// One question at a time to bin/startdgx (a catalog, an uninstall or removal plan, the tailnet), identified by a key.
// A new question kills the one that runs and waits for its exit before it is asked: the killed one's exit can come
// after a restart would have begun, and would then read as the new one's answer (an error on the next card).
// { running: the key whose process runs, or null; wanted: the key whose answer is wanted, or null; killed: whether
// the one that runs has been ended, whose answer is then never the one wanted, even for the same key }.

function newQuery() { return { running: null, wanted: null, killed: false } }

// Ask `key`: { query, launch: the key to start now or null, kill: whether to end the one that runs }.
function queryAsk(q, key) {
  if (q.running === null) return { query: { running: key, wanted: key, killed: false }, launch: key, kill: false }
  const kill = !q.killed && q.running !== key
  return { query: { running: q.running, wanted: key, killed: q.killed || kill }, launch: null, kill: kill }
}

// The answer is no longer wanted (its card closed).
function queryCancel(q) {
  const kill = q.running !== null && !q.killed
  return { query: { running: q.running, wanted: null, killed: q.killed || kill }, kill: kill }
}

// The process ended: { query, key: what it was asked, current: whether its answer is the one wanted, launch: the key
// to ask next or null }.
function queryExited(q) {
  const current = q.running !== null && !q.killed && q.running === q.wanted
  const next = !current && q.wanted !== null ? q.wanted : null
  return { query: { running: next, wanted: current ? null : q.wanted, killed: false }, key: q.running, current: current, launch: next }
}
