// The rules of the manager, with no Quickshell imports so they run under Node (tests/js/DgxModel.test.js).
// A host is an SSH target from `startdgx hosts --json`; its status is the engine's `status --json`, read
// through `startdgx status HOST`; an entry is one model row of that status (the engine's model_record).
// The validation, the start/stop progress curve and the download figures are adapted from Omarchy's agents
// plugin (shell/plugins/agents/Main.qml and Panel.qml), MIT, Copyright (c) David Heinemeier Hansson.

.pragma library

// The engine's unit states: a setup in progress, then systemd's.
var UNITS = ["installing", "active", "activating", "inactive", "failed", "deactivating", "removing"]

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

// A status document, or null when it isn't one: a missing or half-written answer keeps the last good one.
function parseStatus(text) {
  let parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!isPlainObject(parsed) || !isPlainObject(parsed.models)) return null
  for (const id in parsed.models) {
    const entry = parsed.models[id]
    if (!isPlainObject(entry) || entry.recipe !== id || id === "") return null
    if (UNITS.indexOf(entry.unit) < 0) return null
  }
  return parsed
}

// What a model is doing, as one word for the row's colour and dot (`kind`) and the words under its name:
// running, loading, stopping, removing, installing, failed, doesNotFit or stopped. `pending` is a start or
// stop just asked for, which shows at once; the host's answer wins as soon as it has moved on.
function modelState(entry, pending) {
  const unit = entry.unit
  const error = String(entry.error || "")
  const phase = entry.install ? entry.install.phase : ""
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

// What the play/pause button does: "start", "stop", or null while it waits (stopping, removing, a setup, no room).
function toggleAction(entry, pending) {
  const kind = modelState(entry, pending).kind
  if (kind === "running" || kind === "loading") return "stop"
  if (kind === "stopped" || (kind === "failed" && entry.unit !== "installing")) return "start"
  return null
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
  const kind = modelState(entry, pending).kind
  const elapsed = entry.since_ms ? Math.max(0, (nowMs - Number(entry.since_ms)) / 1000) : 0
  const seconds = function (value, fallback) { return Number(value) > 0 ? Number(value) : fallback }
  switch (kind) {
  case "installing": {
    const install = entry.install || {}
    const total = Number(install.total_bytes) || 0
    return { label: "Downloading", fraction: total > 0 ? (Number(install.done_bytes) || 0) / total : 0, value: downloadRate(Number(install.rate_bytes_s) || 0) }
  }
  case "loading": return { label: "Loading", fraction: phaseProgress(elapsed, seconds(entry.expected_load_seconds, 60)), value: "" }
  case "stopping": return { label: "Stopping", fraction: phaseProgress(elapsed, seconds(entry.expected_stop_seconds, 10)), value: "" }
  case "removing": return { label: "Removing", fraction: phaseProgress(elapsed, seconds(entry.expected_remove_seconds, 10)), value: "" }
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
  let parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
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
  let parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!Array.isArray(parsed)) return null
  for (let i = 0; i < parsed.length; i++) {
    const p = parsed[i]
    if (!isPlainObject(p) || typeof p.name !== "string" || typeof p.target !== "string") return null
  }
  return parsed
}

// What the Add machine card offers for a peer: { action: "add" | "install" | null, text }. A Spark with an
// engine can be added (add only asks the engine for its profile); one without is installed, in a terminal.
function peerOffer(peer) {
  if (!peer.reachable) return { action: null, text: String(peer.reason || "") || "Not answering" }
  if (peer.added) return { action: null, text: "Added" }
  if (!peer.spark) return { action: null, text: "Not a DGX Spark" }
  if (peer.engine || peer.installed) {
    return { action: "add", text: peer.installed ? "DGX Spark · ready to add" : "DGX Spark · has an engine startdgx didn't install" }
  }
  return { action: "install", text: "DGX Spark · not set up yet" }
}

// ---- keyboard ----------------------------------------------------------------------------------------

// The manager's rows, top to bottom, for the keyboard cursor: each machine, then its models.
function rows(hostList, hostStates) {
  const out = []
  for (let i = 0; i < hostList.length; i++) {
    const host = hostList[i]
    out.push({ kind: "host", host: host })
    const hs = hostStates[host]
    const list = modelList(hs ? hs.status : null)
    for (let j = 0; j < list.length; j++) out.push({ kind: "model", host: host, id: list[j].recipe })
  }
  return out
}

// A key typed in the manager ("enter" for Return). `row` is the one under the cursor (or null), `entry` its
// model's status row and `pending` a start or stop already asked for. A model's row acts for its machine too.
function keyAction(key, row, entry, pending) {
  const k = String(key).toLowerCase()
  if (k === "r") return { type: "refresh" }
  if (k === "n") return { type: "addMachine" }
  if (!row) return null
  if (k === "u") return { type: "uninstall", host: row.host }
  if (k === "f") return { type: "forget", host: row.host }
  if (k === "l") return { type: "logs", host: row.host, id: row.kind === "model" ? row.id : "" }
  if ((k === "s" || k === "enter") && row.kind === "model" && entry) {
    const action = toggleAction(entry, pending)
    return action ? { type: action, host: row.host, id: row.id } : null
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
      const key = host + "/" + e.recipe + ":" + state.text
      next[key] = true
      if (announced[key]) continue
      const name = String(e.name || e.recipe)
      list.push({ key: key, title: name + (e.unit === "installing" ? " could not be set up on " : " failed on ") + hostName(host), body: state.text })
    }
  }
  return { list: list, announced: next }
}
