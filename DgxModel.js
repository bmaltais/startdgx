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

var QUEUED_WORDS = { start: "start queued", stop: "stop queued", delete: "removal queued", "move-usb": "move queued", "move-nvme": "move queued" }

// What a move shows while it runs, by its mark.
var MOVE_WORDS = { "move-usb": "Moving to USB", "move-nvme": "Moving to NVMe" }

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
  if (MOVE_WORDS[pending] && (unit === "inactive" || unit === "failed")) return { kind: "moving", text: MOVE_WORDS[pending] }
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

// What a model makes, when it isn't text: the engine's `kind` (text, image, video or music). A text model has a context
// to size and agents to run on it; the others have neither.
var KIND_WORDS = { image: "Image", video: "Video", music: "Music" }
function isTextModel(entry) { return !entry || !KIND_WORDS[entry.kind] }

// The facts under a model's name: what it makes (not text), its context, and the memory it took when it last ran (a
// running model's is on its meter).
function modelFacts(entry) {
  const facts = []
  if (!isTextModel(entry)) facts.push(KIND_WORDS[entry.kind] + " model")
  if (Number(entry.ctx) > 0) facts.push(Math.round(Number(entry.ctx) / 1024) + "K context")
  const used = entry.observed ? Number(entry.observed.ram_used_gib) || 0 : 0
  if (used > 0 && entry.unit !== "active") facts.push(Math.round(used) + " GiB")
  return facts.join(" · ")
}

// The line under a model's name, the most telling first, so that what a narrow row drops is the least: what it is
// doing (a failure's reason has a line of its own), its context and memory, where its files are (`location`, only on a
// machine with a model store) and whether it is shared. Each fact keeps its words together (no-break spaces), so a row
// that wraps the line breaks it between facts.
function modelLine(entry, pending, location) {
  const state = modelState(entry, pending)
  const facts = modelFacts(entry).split(" · ").concat([locationText(location), entry.shared === true ? "Shared" : ""])
    .filter(function (s) { return s !== "" }).map(function (s) { return s.replace(/ /g, "\u00a0") })
  return [state.kind === "failed" ? (entry.unit === "installing" ? "Setup failed" : "Failed") : state.text].concat(facts).join(" · ")
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

var BUSY_KINDS = ["loading", "stopping", "removing", "installing", "moving"]

function hostBusy(hs) {
  return !!hs && modelList(hs.status).some(function (e) { return BUSY_KINDS.indexOf(modelState(e).kind) >= 0 })
}

// Counts for the count line, and the bar icon's state: alert (a machine away or a model failed), busy (a model
// loading, stopping, being removed or set up), running, or idle.
// `pending` (optional): the models' marks, so a model being moved counts as busy.
function summarize(hostList, hostStates, pending) {
  const s = { machines: hostList.length, offline: 0, models: 0, running: 0, busy: 0, failed: 0, kind: "idle" }
  for (let i = 0; i < hostList.length; i++) {
    const hs = hostStates[hostList[i]]
    if (!hs || !hs.loaded) continue
    if (!hs.online) { s.offline++; continue }
    const list = modelList(hs.status)
    s.models += list.length
    for (let j = 0; j < list.length; j++) {
      const kind = modelState(list[j], pending ? pending[modelKey(hostList[i], list[j].recipe)] : "").kind
      if (kind === "running") s.running++
      else if (kind === "failed") s.failed++
      else if (BUSY_KINDS.indexOf(kind) >= 0) s.busy++
    }
  }
  s.kind = s.offline > 0 || s.failed > 0 ? "alert" : s.busy > 0 ? "busy" : s.running > 0 ? "running" : "idle"
  return s
}

// The manager's count line, in sentence case: "2 machines · 1 running · 1 not answering". Its parts, so the one
// that needs attention (a failure, a machine not answering) can be drawn apart from the rest.
function summaryParts(s) {
  if (s.machines === 0) return [{ text: "No machines added", alert: false }]
  const parts = [{ text: s.machines + (s.machines === 1 ? " machine" : " machines"), alert: false }]
  parts.push({ text: s.running > 0 ? s.running + " running" : "nothing running", alert: false })
  if (s.busy > 0) parts.push({ text: s.busy + " busy", alert: false })
  if (s.failed > 0) parts.push({ text: s.failed + " failed", alert: true })
  if (s.offline > 0) parts.push({ text: s.offline + " not answering", alert: true })
  return parts
}

function subtitle(s) {
  return summaryParts(s).map(function (p) { return p.text }).join(" \u00b7 ")
}

// A machine's memory, the thing a DGX Spark runs out of: { total, used, free, other, segments: [{ id, name, gib, other? }] }
// in GiB, one segment per running model (what it holds now) and, when the host reports what is available
// (`ram_available_gib`, its MemAvailable), a segment for the model that is loading (what the machine holds beyond the
// running ones, up to what it needs) and one "Other programs" segment for what the machine uses beyond those models: a
// model loaded through ComfyUI, a download. Under the desktop's reserve (RESERVE_GIB) it is just the desktop, and no
// segment. It is the same figure the engine checks before it starts a model. A running ComfyUI has a segment of its own
// (`comfy: true`) between the models and the rest. null while the machine's total is unknown.
function hostMemory(status, profile) {
  const total = Number(status && status.ram_total_gib) || 0
  if (!(total > 0)) return null
  const segments = []
  let models = 0
  const list = modelList(status)
  for (let i = 0; i < list.length; i++) {
    const e = list[i]
    const gib = e.unit === "active" && e.observed ? Number(e.observed.ram_used_gib) || 0 : 0
    if (gib <= 0) continue
    segments.push({ id: String(e.recipe), name: String(e.name || e.recipe), gib: gib })
    models += gib
  }
  // A running ComfyUI is ours too (the status poll reads its process's resident memory): its own segment, not other programs'.
  let comfy = 0
  const running = comfyRunning(status)
  for (const path in running) {
    const gib = running[path] / 1024
    if (!(gib > 0)) continue
    segments.push({ id: "comfyui:" + path, name: "ComfyUI", gib: gib, comfy: true })
    models += gib
    comfy += gib
  }
  const available = status && status.ram_available_gib
  const held = available === undefined || available === null || !isFinite(Number(available)) ? models : Math.max(models, total - Number(available))
  // What the machine holds beyond the running models goes first to the one that is loading (it takes its memory as it
  // loads, before it counts as running), up to what it needs when that is known.
  let loading = null
  let loadingGib = 0
  for (let i = 0; i < list.length && held > models; i++) {
    const e = list[i]
    if (e.unit !== "activating") continue
    const need = e.observed ? Number(e.observed.ram_used_gib) || 0 : 0
    loadingGib = need > 0 ? Math.min(held - models, need) : held - models
    if (loadingGib < RESERVE_GIB) { loadingGib = 0; continue }
    loading = e
    segments.push({ id: String(e.recipe), name: String(e.name || e.recipe), gib: loadingGib, loading: true })
    break
  }
  const beyond = held - models - loadingGib
  const other = beyond >= RESERVE_GIB ? beyond : 0
  if (other > 0) segments.push({ id: "other", name: "Other programs", gib: other, other: true })
  const used = Math.min(models + loadingGib + other, total)
  return { total: total, used: used, free: total - used, other: other, comfy: comfy, loading: loading ? String(loading.name || loading.recipe) : "", segments: segments }
}

// What the memory bar says: "28 of 122 GiB in use", the model that is loading, the part nothing of ours holds, or that nothing is loaded.
function memoryText(mem) {
  if (!mem) return ""
  if (mem.segments.length === 0) return "Nothing loaded \u00b7 " + Math.round(mem.total) + " GiB free"
  const text = Math.round(mem.used) + " of " + Math.round(mem.total) + " GiB in use"
  const parts = [text]
  if (mem.comfy > 0) parts.push("ComfyUI " + Math.round(mem.comfy) + " GiB")
  if (mem.loading) parts.push(mem.loading + " loading")
  if (mem.other > 0) parts.push(Math.round(mem.other) + " GiB by other programs")
  return parts.join(" \u00b7 ")
}

// A model's numbers as columns, so rows line up: its context ("256K") and the memory it holds or last held ("31 GiB"),
// "" for one it doesn't have.
function modelColumns(entry) {
  const ctx = Number(entry.ctx) > 0 ? Math.round(Number(entry.ctx) / 1024) + "K" : ""
  const used = entry.observed ? Number(entry.observed.ram_used_gib) || 0 : 0
  return { ctx: ctx, size: used > 0 ? Math.round(used) + " GiB" : "" }
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
// row (only on a machine that answers: a picker needs its catalog), then its ComfyUI installs (`comfy`: host -> the
// installs `comfyui list` last said) and the row that finds more (only on a machine that answers).
function rows(hostList, hostStates, comfy) {
  const out = []
  for (let i = 0; i < hostList.length; i++) {
    const host = hostList[i]
    out.push({ kind: "host", host: host })
    const hs = hostStates[host]
    const list = modelList(hs ? hs.status : null)
    for (let j = 0; j < list.length; j++) out.push({ kind: "model", host: host, id: list[j].recipe })
    if (hs && hs.loaded && hs.online) out.push({ kind: "add", host: host })
    const installs = comfy && comfy[host] ? comfy[host] : []
    for (let j = 0; j < installs.length; j++) out.push({ kind: "comfy", host: host, id: String(installs[j].path) })
    if (hs && hs.loaded && hs.online) { out.push({ kind: "comfyinstall", host: host }); out.push({ kind: "comfyfind", host: host }) }
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
  if (k === "g") return row.kind === "model" ? { type: "modelSettings", host: row.host, id: row.id } : row.kind === "comfy" ? { type: "comfySettings", host: row.host, path: row.id } : { type: "hostSettings", host: row.host }
  if (k === "l") return { type: "logs", host: row.host, id: row.kind === "model" ? row.id : "" }
  if (k === "enter" && row.kind === "comfyfind") return { type: "findComfy", host: row.host }
  if (k === "enter" && row.kind === "comfyinstall") return { type: "installComfy", host: row.host }
  if (k === "a" || (k === "enter" && row.kind === "add")) return { type: "addModel", host: row.host }
  if (k === "e") return { type: "addRecipe", host: row.host }
  if (k === "c" && row.kind === "model" && contextAction(entry, pending)) return { type: "modelSettings", host: row.host, id: row.id, page: "Context" }
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

function newQueue() { return { starting: null, other: null, sharing: null, moving: null, starts: [], others: [], shares: [], moves: [] } }

function copyQueue(q) { return { starting: q.starting, other: q.other, sharing: q.sharing, moving: q.moving, starts: q.starts.slice(), others: q.others.slice(), shares: q.shares.slice(), moves: q.moves.slice() } }

function sameKey(key) { return function (a) { return a.key === key } }

// A click, put in its queue: { queue, dropped }. A stop or removal takes back a start of that model still waiting its
// turn (dropped), and a removal the model's queued shares, and supersedes one that is loading: its exit is then not a failure to report. A removal of a model
// that is loading stops it first, since the engine's remove waits for the lock its start holds. A stop of a model
// whose only start was taken back sends nothing. A start of a model being stopped or removed is dropped.
function submit(q, action, entry) {
  const key = action.key
  const out = copyQueue(q)
  const busy = [out.other, out.moving].concat(out.others, out.moves).some(function (a) { return a && a.key === key && (a.kind === "stop" || a.kind === "delete" || a.kind === "move") })
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
  else if (MOVE_KINDS.indexOf(action.kind) >= 0) out.moves.push(action)
  else out.others.push(action)
  return { queue: out, dropped: [] }
}

// A move copies tens of GB (minutes to an hour), so it has a slot of its own: another model's stop or removal never waits
// for it. A change of the model store goes on the same slot, behind the moves it must not overtake.
var MOVE_KINDS = ["move", "storageSet", "storageUnset"]

// What can begin now, on each free slot: { queue, run }.
function launch(q) {
  const out = copyQueue(q)
  const run = []
  if (!out.starting && out.starts.length) { out.starting = out.starts.shift(); run.push(out.starting) }
  if (!out.other && out.others.length) { out.other = out.others.shift(); run.push(out.other) }
  if (!out.sharing && out.shares.length) { out.sharing = out.shares.shift(); run.push(out.sharing) }
  if (!out.moving && out.moves.length) { out.moving = out.moves.shift(); run.push(out.moving) }
  return { queue: out, run: run }
}

// A slot's command ended ("start", "share", "move" or "other"): { queue, action } with the action that ran there, or null.
function finish(q, slot) {
  const field = slot === "start" ? "starting" : slot === "share" ? "sharing" : slot === "move" ? "moving" : "other"
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
  ;[q.starting, q.other, q.sharing, q.moving].forEach(function (a) {
    if (a && !a.superseded) { out[a.key] = a.shows; runningOp[a.key] = a.op }
  })
  q.starts.concat(q.others, q.shares, q.moves).forEach(function (a) {
    if (a.shows === "use" || runningOp[a.key] === a.op) return
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
  // --yes only for a setup the person confirmed (a recipe of theirs): the engine refuses one without it.
  case "use": return ["use", "--detach", host, id].concat(action.yes ? ["--yes"] : [], ["--timeout", "120"])
  case "context": return ["use", "--detach", host, id, "--ctx", String(action.ctx), "--timeout", "120"]
  case "delete": return ["delete", host, id, "--timeout", "1500"]
  // The engine publishes the model's route with tailscale serve, which can take a while.
  case "share": return ["share", host, id, "--timeout", "120"]
  case "unshare": return ["share", host, id, "--off", "--timeout", "120"]
  // Copying a big model over USB takes minutes: 35 GB is about 25 s each way at the disk's speed, plus checking it.
  case "move": return ["move", host, id, "--to", action.to, "--timeout", "3600"]
  case "storageSet": return ["storage", host, "--set", action.path, "--timeout", "60"]
  case "storageUnset": return ["storage", host, "--unset", "--timeout", "60"]
  }
  return null
}

// ---- the model store ------------------------------------------------------------------------------------

// `startdgx storage HOST --json`: { store: { path, present } | null, disks, models: [{ id, location, bytes }] }, or
// null when it isn't that. A model's location is nvme, usb, both, usb-missing (its store isn't mounted) or mixed.
function parseStorage(text) {
  const storage = parseJson(text)
  return isPlainObject(storage) && Array.isArray(storage.disks) && Array.isArray(storage.models) && "store" in storage ? storage : null
}

// What a storage read says: { storage } or { storage: null, error }.
function storageAnswer(code, stdout, stderr, host) {
  if (code !== 0) return { storage: null, error: errorLine(stderr, host + " didn't answer") }
  const storage = parseStorage(stdout)
  return storage ? { storage: storage } : { storage: null, error: host + " sent an unreadable storage answer" }
}

// The card's disk list: each disk the host could keep a store on, with room and, when it can't, why.
function diskRows(storage) {
  if (!storage) return []
  const store = storage.store ? String(storage.store.path) : ""
  return storage.disks.map(function (d) {
    const bus = d.bus ? String(d.bus).toUpperCase() + " " : ""
    const mount = String(d.mount)
    return {
      mount: mount, usable: !!d.usable, reason: String(d.reason || ""),
      text: mount + " · " + bus + d.fstype + " · " + sizeText(d.free) + " free of " + sizeText(d.size),
      inUse: store !== "" && (store === mount || store.indexOf(mount + "/") === 0)
    }
  })
}

function storageSummary(storage) {
  if (!storage) return ""
  if (!storage.store) return "Models stay on the internal disk"
  return "Store: " + storage.store.path + (storage.store.present ? "" : " (disk not mounted)")
}

function storagePathProblem(path) {
  const p = String(path).trim()
  if (p === "") return "Type the folder on the machine"
  if (/[\r\n]/.test(p)) return "The path must be one line"
  if (p.charAt(0) !== "/") return "The path must start with /"
  return ""
}

function locationOf(storage, id) {
  const models = storage ? storage.models : []
  for (let i = 0; i < models.length; i++) if (models[i].id === id) return String(models[i].location)
  return ""
}

var LOCATION_WORDS = { nvme: "On NVMe", usb: "On USB", both: "On NVMe and USB", "usb-missing": "USB disk missing", mixed: "Partly on USB" }

// The same, short enough for a column.
var LOCATION_SHORT = { nvme: "NVMe", usb: "USB", both: "NVMe + USB", "usb-missing": "USB missing", mixed: "Part USB" }

function locationShort(location) { return LOCATION_SHORT[location] || "" }

function locationText(location) { return LOCATION_WORDS[location] || "" }

// Only a model whose files nothing has open moves, and only to or from a store whose disk is mounted. A model on both
// disks is offered the one thing that helps, freeing the NVMe; a split one either way.
var MOVE_BUSY = { active: 1, activating: 1, deactivating: 1, installing: 1, removing: 1 }

function moveOffers(location, unit, store) {
  if (!store || !store.present || MOVE_BUSY[unit]) return []
  const toUsb = { to: "usb", label: "Move to USB" }, toNvme = { to: "nvme", label: "Move to NVMe" }
  switch (location) {
  case "nvme": return [toUsb]
  case "usb": return [toNvme]
  case "both": return [{ to: "usb", label: "Free NVMe space" }]
  case "mixed": return [toUsb, toNvme]
  }
  return []
}

// ---- the gear panels -------------------------------------------------------------------------------------
// A machine's panel and a model's panel are pages of fields for the settings window (SettingsWindow.qml): the rows keep
// to a name, a status and a few buttons, and what else there is to do or set sits behind the gear. These build the pages
// from what the manager knows; hostChange and modelChange say what a click in a panel asks for.

var STORE_FOLDER = "/startdgx-models"

// Models whose files are linked into the model store (not one that only has a spare copy there): switching stores under
// them would strand those files, and the machine refuses it.
function linkedCount(storage) {
  return storage ? storage.models.filter(function (m) { return m.location !== "nvme" && m.location !== "both" }).length : 0
}

// ---- the plugin's own update (`startdgx self-update --json`) ------------------------------------------------------
// { managed, why, commit, subject, behind, changes: [subject], dirty, updated, restarting }, or null when it isn't that.
function parseSelfUpdate(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || typeof p.managed !== "boolean" || !Array.isArray(p.changes)) return null
  return { managed: p.managed, why: String(p.why || ""), commit: String(p.commit || ""), subject: String(p.subject || ""), behind: Number(p.behind) > 0 ? Number(p.behind) : 0,
           changes: p.changes.map(String), dirty: p.dirty === true, updated: p.updated === true, restarting: p.restarting === true }
}

// Whether an update is waiting: the header's gear says so.
function selfUpdateWaiting(info) { return !!info && info.managed && info.behind > 0 }

// The StartDGX window's one page. c: { info (parseSelfUpdate or null), error, checking, updating }.
function appPages(c) {
  const info = c.info
  const fields = []
  const busy = c.checking || c.updating
  fields.push({ key: "installed", type: "info", label: "Installed", hint: info && info.commit !== "" ? info.commit + (info.subject !== "" ? " · " + info.subject : "") : c.error !== "" || !info ? "Not known yet." : "Not a git checkout." })
  if (c.error !== "") fields.push({ key: "problem", type: "info", label: "The update", hint: c.error, note: { kind: "bad", text: c.error } })
  if (info && !info.managed) {
    fields.push({ key: "unmanaged", type: "info", label: "Updating", hint: info.why })
  } else if (info && info.dirty && info.behind > 0) {
    fields.push({ key: "dirty", type: "info", label: "Update available", hint: info.behind + " newer change" + (info.behind === 1 ? "" : "s") + ", but this folder has local edits, so it won't be touched. Discard or stash them first." })
  } else if (info && info.behind > 0) {
    const more = info.behind > info.changes.length ? " (and " + (info.behind - info.changes.length) + " more)" : ""
    fields.push({ key: "update", type: "action", label: "Update available", button: c.updating ? "Updating…" : "Update…", disabled: busy,
      hint: info.behind + " newer change" + (info.behind === 1 ? "" : "s") + ": " + info.changes.join("; ") + more + ". Updating restarts the shell: the bar and this window go for a few seconds." })
  } else if (info) {
    fields.push({ key: "check", type: "action", label: "Up to date", button: c.checking ? "Looking…" : "Check again", disabled: busy, hint: "StartDGX is at the latest version of its repository." })
  } else if (!c.error) {
    fields.push({ key: "check", type: "info", label: "Looking for updates", hint: "Asking the plugin's repository…" })
  }
  if (c.error !== "" && !c.checking) fields.push({ key: "check", type: "action", label: "Try again", button: "Check", disabled: busy, hint: "Look for an update again." })
  return [{ title: "StartDGX", fields: fields }]
}

// What a click in that window asks for, as a dispatch action, or null.
function appChange(key) {
  if (key === "update") return { type: "selfUpdate" }
  if (key === "check") return { type: "selfCheck" }
  return null
}

// c: { machine, update (engineUpdate), needsSetup, storage (parseStorage or null), readError, busy (a store change waits),
// fugue (fugueHelperPage's input, or absent: the machine doesn't answer, so there is no Fugue helper page) }
function hostPages(c) {
  const general = []
  if (c.needsSetup) general.push({ key: "setup", type: "action", label: "Set up this machine", button: "Install…",
    hint: "A model can't be set up here until the machine has its one-time root setup. This runs it in a terminal, where sudo asks for the password; an engine startdgx didn't install is backed up first." })
  else if (c.update) general.push({ key: "update", type: "action", label: "Update the engine", button: "Update…",
    hint: c.update.text })
  general.push({ key: "logs", type: "action", label: "Logs", button: "Open…", hint: "Open the logs of the model started last, in a terminal." })

  const storage = c.storage
  const linked = linkedCount(storage)
  const wait = c.busy || !storage || linked > 0
  const options = [{ value: "", label: "Internal disk only" }]
  const unusable = []
  const disks = diskRows(storage)
  for (let i = 0; i < disks.length; i++) {
    const d = storage.disks[i]
    if (d.usable) options.push({ value: disks[i].mount, label: disks[i].mount + " · " + (d.bus ? String(d.bus).toUpperCase() + " " : "") + d.fstype + " · " + sizeText(d.free) + " free" })
    else unusable.push(disks[i].mount + " (" + disks[i].reason + ")")
  }
  const note = linked > 0 ? { kind: "bad", text: linked + " model" + (linked === 1 ? " has" : "s have") + " files on the store. Move " + (linked === 1 ? "it" : "them") + " back to the internal disk (Move to NVMe, in the model's panel) before changing or removing the store." }
    : !storage ? (c.readError ? { kind: "bad", text: c.readError } : { kind: "muted", text: "Asking the machine…" })
    : unusable.length ? { kind: "muted", text: "Not usable: " + unusable.join("; ") }
    : null
  const store = { key: "store", type: "choice", stacked: true, label: "Model store",
    hint: "An external disk for model files. Choosing one moves nothing: each model has its own Move to USB in its panel, which copies it, checks it and frees the internal disk. A model on the store loads from there, a little slower." }
  const folder = { key: "folder", type: "text", label: "Or a folder of your own", placeholder: "/media/you/disk/models",
    hint: "An absolute path on the machine, on an external disk. Press Enter to use it." }
  store.options = options
  if (note) store.note = note
  if (wait) { store.disabled = true; folder.disabled = true }

  const pages = [
    { title: "General", fields: general },
    { title: "Storage", fields: [store, folder] }]
  if (c.fugue) pages.push(fugueHelperPage(c.fugue))
  pages.push(
    { title: "Machine", fields: [
      { key: "uninstall", type: "action", label: "Uninstall the engine", button: "Uninstall…", hint: "See what uninstalling would change on the machine, then do it in a terminal." },
      { key: "forget", type: "action", label: "Forget this machine", button: "Forget…", hint: "Take it off this list. Nothing on the machine changes, and Add machine can add it again." }] })
  return pages
}

// ---- Fugue's helper on a machine (the page "Fugue helper" of its settings window) ------------------------------------------
// startdgx fugue-helper: Fugue's `fugue-helper --serve-http` on the machine, which runs Fugue's image stages for a Fugue on this computer.

// The one place that says where a published helper build is. No build exists yet (Fugue issue #104): while `url` is empty the page shows
// the command to run by hand. When a build is published, fill both in (an https URL and the sha256 of the file at it); the page then shows
// an Install… button, which runs `fugue-helper install HOST --from URL --sha256 SHA256 --start`.
var FUGUE_HELPER_BUILD = { url: "", sha256: "" }
var FUGUE_PROVIDER_HINT = "Paste it into Fugue's providers.json (Settings > Providers); the key is a secret."

// The command a person runs by hand to install the helper (HOST as the panel knows the machine, quoted for a shell when it needs it).
function fugueHelperInstallText(host) {
  const h = /^[A-Za-z0-9@._:-]+$/.test(String(host)) ? String(host) : "'" + String(host).replace(/'/g, "'\\''") + "'"
  return "startdgx fugue-helper install " + h + " --from FILE --start"
}

// The command line of a fugue-helper verb. Always --json, and never anything that holds the key: provider's answer comes back on stdout.
function fugueHelperCommand(script, host, verb, extra) {
  return [script, "fugue-helper", verb, host, "--json"].concat(extra || [])
}
// The extra arguments of the Install… button, once FUGUE_HELPER_BUILD says where the build is.
function fugueHelperInstallArgs(build) {
  return ["--from", String(build.url), "--sha256", String(build.sha256), "--start"]
}

// `fugue-helper status --json` as an object, or null when it isn't one the panel can read (no key is in it).
function parseFugueHelperStatus(text) {
  const parsed = parseJson(text)
  return isPlainObject(parsed) && typeof parsed.installed === "boolean" ? parsed : null
}

// Fugue's providers.json entry from `fugue-helper provider --json`, as the text to put on the clipboard (compact JSON), or "" when it
// isn't a usable entry. The text holds the key: whoever calls this puts it on the clipboard and nowhere else.
function fugueProviderEntry(text) {
  const e = parseJson(text)
  if (!isPlainObject(e) || e.type !== "fugue-helper") return ""
  if (typeof e.name !== "string" || typeof e.address !== "string" || typeof e.key !== "string" || e.key === "" || e.address === "") return ""
  return JSON.stringify({ name: e.name, type: e.type, address: e.address, key: e.key })
}

// "unknown" (not read yet, or couldn't be), "none" (not installed), "off", "running".
function fugueHelperState(status) {
  if (!status) return "unknown"
  if (!status.installed) return "none"
  return status.active ? "running" : "off"
}

// c: { host, status (parseFugueHelperStatus or null), error (why the last read or action failed, or ""), busy ("" or "on", "off", "install",
// "copy": what is running), reading (a status read is running), copied (the entry went to the clipboard) }
function fugueHelperPage(c) {
  const state = fugueHelperState(c.status)
  const working = c.busy !== ""
  const fields = [{ key: "fugueAbout", type: "info", label: "What it is",
    hint: "Runs Fugue's image stages (encode, sample, decode) on this machine, for a Fugue on your computer." }]
  const note = c.error !== "" ? { kind: "bad", text: c.error } : null
  if (state === "unknown") {
    fields.push({ key: "fugueState", type: "info", label: "Status",
      hint: c.reading ? "Asking the machine…" : "Not known: the machine's answer couldn't be read.", note: note || undefined })
    return { title: "Fugue helper", fields: fields }
  }
  if (state === "none") {
    const hint = c.status.managed ? "Not installed: its binary or unit is missing. Install it again to repair it." : "Not installed."
    fields.push({ key: "fugueState", type: "info", label: "Status", hint: hint, note: note || undefined })
    if (FUGUE_HELPER_BUILD.url !== "") {
      fields.push({ key: "fugueInstall", type: "action", label: "Install the helper", button: c.busy === "install" ? "Installing…" : "Install…", disabled: working,
        hint: "Downloads the helper to the machine, sets it up as a user service and starts it." })
    } else {
      fields.push({ key: "fugueInstallCommand", type: "command", label: "Install it from a terminal", value: fugueHelperInstallText(c.host),
        hint: "No published helper build exists yet (Fugue issue #104). Run this in a terminal on this computer, with FILE a built fugue-helper-cuda or a .tar.zst or .tar.gz holding it." })
    }
    return { title: "Fugue helper", fields: fields }
  }
  const where = c.status.address ? " at " + c.status.address : ""
  fields.push({ key: "fugueState", type: "info", label: "Status",
    hint: (state === "running" ? "Running" + where : "Installed, off" + where) + (c.status.enabled ? "; starts at boot." : "."), note: note || undefined })
  fields.push({ key: "fugueHelper", type: "bool", label: "Run the helper", disabled: working,
    hint: "On starts it now and at every boot; off stops it." })
  const copy = { key: "fugueCopy", type: "action", label: "Fugue provider entry", button: c.busy === "copy" ? "Copying…" : "Copy Fugue provider entry", disabled: working, hint: FUGUE_PROVIDER_HINT }
  if (c.copied && c.error === "") copy.note = { kind: "ok", text: "Copied to the clipboard. The key is not shown here." }
  fields.push(copy)
  return { title: "Fugue helper", fields: fields }
}

// What the Fugue helper page's controls show.
function fugueHelperValues(status) {
  return { fugueHelper: fugueHelperState(status) === "running" }
}

// What the machine's panel shows in its controls: the disk the store is on (one this plugin made), or else the folder.
function hostValues(storage, fugueStatus) {
  const path = storage && storage.store ? String(storage.store.path) : ""
  const helper = fugueHelperValues(fugueStatus || null)
  if (path === "") return Object.assign({ store: "", folder: "" }, helper)
  const disks = storage.disks.filter(function (d) { return path === d.mount + STORE_FOLDER })
  return Object.assign(disks.length ? { store: String(disks[0].mount), folder: "" } : { store: "", folder: path }, helper)
}

// What a click in the machine's panel asks for: { action } (null: nothing to do) and, when what was typed won't do, { error }.
function hostChange(host, key, value, storage) {
  const current = storage && storage.store ? String(storage.store.path) : ""
  switch (key) {
  case "logs": return { action: { type: "logs", host: host, id: "" } }
  case "update": return { action: { type: "install", host: host, replace: false } }
  case "setup": return { action: { type: "install", host: host, replace: true } }
  case "uninstall": return { action: { type: "uninstall", host: host } }
  case "forget": return { action: { type: "forget", host: host } }
  case "fugueHelper": return { action: { type: "fugueHelper", host: host, verb: value === true ? "on" : "off" } }
  case "fugueCopy": return { action: { type: "fugueCopy", host: host } }
  case "fugueInstall": return { action: FUGUE_HELPER_BUILD.url === "" ? null : { type: "fugueHelper", host: host, verb: "install", extra: fugueHelperInstallArgs(FUGUE_HELPER_BUILD) } }
  case "store": {
    if (value === "") return { action: current === "" ? null : { type: "storageUnset", host: host } }
    const path = String(value) + STORE_FOLDER
    return { action: path === current ? null : { type: "storageSet", host: host, path: path } }
  }
  case "folder": {
    const path = String(value).trim()
    if (path === "") return { action: null }
    const problem = storagePathProblem(path)
    if (problem !== "") return { action: null, error: problem }
    return { action: path === current ? null : { type: "storageSet", host: host, path: path } }
  }
  }
  return { action: null }
}

// c: { entry, pending, sharing, store ({ path, present } or null), location, choices (contextChoices), variantsLoading,
// variantsError, away }
function modelPages(c) {
  const share = { key: "share", type: "bool", label: "Share on my tailnet", hint: "Omarchy on your other machines lists this model while it is shared." }
  if (!shareAction(c.entry, c.pending, c.sharing)) share.disabled = true
  const general = [share]
  if (c.entry.unit !== "installing") general.push({ key: "logs", type: "action", label: "Logs", button: "Open…", hint: "Open this model's logs in a terminal." })
  const pages = [{ title: "General", fields: general }]

  // The page is there for any model that is set up, also while it restarts with a new size (dimmed then), so the
  // window doesn't change pages under the person who just chose one.
  if (CONTEXT_UNITS[c.entry.unit] && isTextModel(c.entry)) {
    const fitting = c.choices.filter(function (x) { return x.fits })
    const skipped = c.choices.filter(function (x) { return !x.fits }).map(function (x) { return x.label + ": " + x.text + "." })
    const now = Number(c.entry.ctx) > 0 ? Math.round(Number(c.entry.ctx) / 1024) + "K" : ""
    const offered = fitting.some(function (x) { return x.current })
    const restart = "Choosing one restarts the model with it, which interrupts requests in flight (a stopped model starts)."
    const needs = function (x) { return (x.source === "estimated" ? "about " : "") + x.need + " GiB" }
    let ctx
    if (fitting.length > 1 || (fitting.length === 1 && !offered)) {
      ctx = { key: "ctx", type: "choice", stacked: true, label: "Context size",
        hint: "The sizes the recipe has measured, each with the memory it needs. " + restart,
        options: fitting.map(function (x) { return { value: x.ctx, label: x.label + " · " + needs(x) } }) }
    } else {
      // The one size it already runs with is not a choice, and none is nothing to choose from: say so instead of a
      // lone button. (Stacked like the choice it may turn into once the machine has answered, so the row keeps its layout.)
      ctx = { key: "ctx", type: "info", stacked: true, label: "Context size", hint: fitting.length === 1
        ? fitting[0].label + ", which needs " + needs(fitting[0]) + " of memory. It is the only size "
          + (skipped.length ? "that fits this machine" : "the recipe has measured") + ", so there is nothing to choose."
        : c.choices.length ? "None of the sizes the recipe has measured fits this machine."
        : "The sizes the recipe has measured." }
    }
    const notes = []
    // The size in use is not among the segments (it no longer fits, or the recipe dropped it): say which it is.
    if (c.choices.length && !offered && now !== "") notes.push("It runs with " + now + " now, which is not offered.")
    if (skipped.length) notes.push("Not offered. " + skipped.join(" "))
    if (c.variantsError !== "" && c.choices.length === 0) ctx.note = { kind: "bad", text: c.variantsError }
    else if (c.variantsLoading && c.choices.length === 0) ctx.note = { kind: "muted", text: "Asking the machine which sizes it has measured…" }
    else if (notes.length) ctx.note = { kind: "muted", text: notes.join(" ") }
    if (c.away || !contextAction(c.entry, c.pending)) ctx.disabled = true
    pages.push({ title: "Context", fields: [ctx] })
  }

  if (c.store) {
    const where = { key: "where", type: "info", label: "Location", hint: locationText(c.location) }
    const offers = c.away || c.pending !== "" || c.sharing !== "" ? [] : moveOffers(c.location, c.entry.unit, c.store)
    const fields = [where]
    if (offers.length === 0) where.note = { kind: "muted", text: !c.store.present ? "The model store's disk isn't mounted." : "A model can only be moved while it is stopped." }
    for (let i = 0; i < offers.length; i++) {
      fields.push({ key: "move-" + offers[i].to, type: "action", label: offers[i].label, button: "Move", hint: MOVE_HINTS[c.location + ">" + offers[i].to] || MOVE_HINTS[offers[i].to] })
    }
    pages.push({ title: "Storage", fields: fields })
  }
  return pages
}

// A model that is set up: at rest, or between two states of a start or stop.
var CONTEXT_UNITS = { active: 1, inactive: 1, failed: 1, activating: 1, deactivating: 1 }

var MOVE_HINTS = {
  usb: "Copy the weights to the model store, check them, and free the internal disk.",
  nvme: "Copy the weights back to the internal disk and leave the model store.",
  "both>usb": "The store already has a copy: this frees the internal disk's."
}

function modelValues(entry) {
  return { share: !!entry && entry.shared === true, ctx: entry ? Number(entry.ctx) : 0 }
}

// What a click in a model's panel asks for, as a dispatch action, or null. `entry` is the model's row.
function modelChange(host, id, key, value, entry) {
  // The size already in use asks for nothing: sending it again would restart the model for no change.
  if (key === "ctx" && entry && Number(value) === Number(entry.ctx)) return null
  switch (key) {
  case "share": return { type: value ? "share" : "unshare", host: host, id: id }
  case "logs": return { type: "logs", host: host, id: id }
  case "ctx": return { type: "setContext", host: host, id: id, ctx: Number(value) }
  case "move-usb": return { type: "move", host: host, id: id, to: "usb" }
  case "move-nvme": return { type: "move", host: host, id: id, to: "nvme" }
  }
  return null
}

// ---- a recipe's settings -----------------------------------------------------------------------------------
// The gear on a row of the model picker: the pages of its window. A recipe of yours can be changed (a context size added,
// a variant measured or confirmed, the recipe removed); a curated one only shown. `c`: { recipe (the listing's row), variants
// (`variants --json`, null until read), loading, error, busy (another recipe write is running) }.

// The context sizes a recipe can be given, by the choice that adds one.
var CONTEXT_SIZES = [32768, 65536, 131072, 196608, 262144]

function recipePages(c) {
  const r = c.recipe
  const mine = isUserRecipe(r)
  const run = tfRunFields(c)
  const fields = []
  const rows = c.variants ? variantRows(c.variants) : []
  if (!c.variants) fields.push({ key: "loading", type: "info", label: "Context sizes", hint: "The sizes the recipe has, and where each one's numbers come from.",
    note: c.error ? { kind: "bad", text: c.error } : { kind: "muted", text: c.loading ? "Asking the machine for its context sizes…" : "Not read yet." } })
  for (let i = 0; i < rows.length; i++) {
    const v = rows[i]
    const label = v.label + " · " + v.source
    if (mine && v.source !== "measured") fields.push({ key: "measure-" + v.ctx, type: "action", label: label, hint: v.text, button: "Measure…", disabled: c.busy })
    else fields.push({ key: "size-" + i, type: "info", label: label, hint: v.text })
  }
  const unconfirmed = rows.some(function (v) { return v.source === "estimated" && !v.confirmed })
  if (mine && unconfirmed) fields.push({ key: "confirm", type: "action", label: "Confirm the estimated numbers", button: "Confirm", disabled: c.busy,
    hint: "Accept the numbers you gave as they are: the estimated sizes then count as fitting, without being measured." })
  if (mine && c.variants) {
    const have = rows.map(function (v) { return v.ctx })
    const options = CONTEXT_SIZES.filter(function (n) { return have.indexOf(n) < 0 }).map(function (n) { return { value: n, label: Math.round(n / 1024) + "K" } })
    if (options.length) fields.push({ key: "add-ctx", type: "choice", stacked: true, label: "Add a context size", options: options, disabled: c.busy,
      hint: "A new size starts drafted, with the numbers of the biggest one as placeholders, and never counts as fitting until Measure… has loaded the model with it and written the real ones." })
  }

  // Not the only size, and not while a model is set up from the recipe (the engine refuses then).
  const sizes = rows.map(function (v) { return v.ctx }).filter(function (n, i, a) { return a.indexOf(n) === i })
  if (mine && c.variants && sizes.length > 1 && c.recipe.installed !== true) fields.push({ key: "remove-ctx", type: "choice", stacked: true, label: "Remove a context size", disabled: c.busy,
    options: sizes.map(function (n) { return { value: n, label: Math.round(n / 1024) + "K" } }),
    hint: "Takes the size out of the recipe, with any numbers measured for it. The recipe keeps at least one size." })

  const general = [
    { key: "name", type: "info", label: "Name", hint: String(r.name || r.id) },
    { key: "what", type: "info", label: "Runtime", hint: String(r.runtime || "") + (r.vendor ? " · " + r.vendor : "") + (mine ? " · yours" : " · ships with the engine") },
    { key: "summary", type: "info", label: "About", hint: String(r.summary || "") }
  ]
  if (mine) general.push({ key: "fix", type: "action", label: "Fix with an agent", button: "Fix…", disabled: c.busy,
    hint: "Opens a terminal with an agent that finds what is wrong with this recipe (a file the repo doesn't have, say) and puts the fixed one back. It asks before any download or measuring run." })
  if (mine && r.installed !== true) general.push({ key: "remove", type: "action", label: "Remove recipe", button: "Remove", danger: true, disabled: c.busy,
    hint: "Take it off this machine's list. Nothing else is deleted: its file is still on this computer." })
  else if (mine) general.push({ key: "remove-note", type: "info", label: "Remove recipe", hint: "A model is set up from it on this machine: remove the model first." })
  const pages = [{ title: "Contexts", fields: fields }, { title: "General", fields: general }]
  const where = destinationFields(c)
  return (run.length ? [{ title: "Run", fields: run }] : []).concat(where.length ? [{ title: "Storage", fields: where }] : [], pages)
}

// Where the files of a model not downloaded yet should end up, on a machine that has a model store. The engine downloads to the internal
// disk, so the choice is acted on when the setup finishes: the panel moves the model to the store then (`move`), which needs the room on
// the internal disk meanwhile. `c.store` is the machine's model store ({ path, present }) or null; `c.destination` is "usb" or "nvme".
function destinationFields(c) {
  if (!c.store || !c.store.path) return []
  if (c.recipe.installed === true) return [{ key: "dest-note", type: "info", label: "Download to", hint: "A model is set up from this recipe: its files are where they are. Move them in the model's own settings (Storage)." }]
  return [{ key: "dest", type: "choice", stacked: true, label: "Download to", disabled: c.busy === true,
    options: [{ value: "nvme", label: "Internal disk" }, { value: "usb", label: "Model store" }],
    hint: "Model store: " + c.store.path + (c.store.present === false ? " (not mounted)" : "") + ". The download goes to the internal disk first and moves to the store when it is done, once the model has stopped: the disk needs room for the model until then, and the model is left stopped on the store." }]
}

// A recipe added from TensorFold's list: the three choices tensorfold.dev offers for it, in its own window, with what it was given picked.
// `c.tf` is the list's row for it (`added` says what the machine was given); changing one writes the recipe again (tfDraftCommand), which the
// engine refuses while a model is set up from it. The numbers stay TensorFold's estimate for its defaults; Contexts has the optional Measure….
function tfRunFields(c) {
  const row = c.tf
  if (!row || !row.settings || !row.added) return []
  const locked = c.recipe.installed === true
  const off = locked || c.busy === true
  const names = [{ key: "context", name: "contexts", label: "Context" }, { key: "parallel", name: "requests", label: "Requests at once" }, { key: "input", name: "inputs", label: "Input" }]
  const hints = { context: "How much text the model keeps in view. More takes more memory.", parallel: "How many requests it serves at the same time.", input: "Whether it reads images too." }
  const fields = names.map(function (n) {
    return { key: "tf-" + n.key, type: "choice", stacked: true, label: n.label, hint: hints[n.key], disabled: off,
             options: row.settings[n.name].map(function (v) { return { value: v, label: tfChoiceLabel(n.key, v) } }) }
  })
  fields.push({ key: "tf-note", type: "info", label: "Memory", hint: "TensorFold's figure is for its default settings; the others are close, not measured. Measure… (Contexts) finds the real numbers." })
  if (locked) fields.push({ key: "tf-locked", type: "info", label: "Changing these", hint: "A model is set up from this recipe: remove the model first." })
  else if (row.outdated) fields.push({ key: "tf-update", type: "action", label: "Update available", button: "Update", disabled: c.busy === true,
    hint: "TensorFold has moved on since this was added. Update adds it again from the current list, with these choices." })
  return fields
}

// The values for a recipe's window: the choices the machine was given, where there are any.
function recipeValues(c) {
  const a = c && c.tf && c.tf.added
  const values = { dest: c && c.destination === "usb" ? "usb" : "nvme" }
  if (a) Object.assign(values, { "tf-context": a.context, "tf-parallel": a.parallel, "tf-input": a.input })
  return values
}

// The list's row for a recipe of this machine that was added from it, or null.
function tfAddedRow(list, recipeId) {
  const rows = list && Array.isArray(list.rows) ? list.rows : []
  return rows.filter(function (r) { return r.added && r.added.recipeId === recipeId })[0] || null
}

// What a click in a recipe's window asks for, as a dispatch action, or null. Curated recipes ask for nothing.
function recipeChange(host, r, key, value, tf) {
  if (key === "dest") return value === "usb" || value === "nvme" ? { type: "setDestination", host: host, id: r.id, to: value } : null
  if (!isUserRecipe(r)) return null
  if (key.indexOf("tf-") === 0 && tf && tf.added) {
    const now = tfAddedChoices(tf)
    if (key === "tf-update") return { type: "tfChange", host: host, row: tf, choices: now }
    const k = key.substring(3)
    if (["context", "parallel", "input"].indexOf(k) < 0 || String(now[k]) === String(value)) return null
    return { type: "tfChange", host: host, row: tf, choices: Object.assign({}, now, { [k]: value }) }
  }
  if (key.indexOf("measure-") === 0) return { type: "measureRecipe", host: host, recipe: r, ctx: Number(key.substring(8)) }
  if (key === "confirm") return { type: "confirmRecipe", host: host, id: r.id }
  if (key === "add-ctx") return { type: "addContext", host: host, id: r.id, ctx: Number(value) }
  if (key === "remove-ctx") return { type: "removeContext", host: host, id: r.id, ctx: Number(value) }
  if (key === "fix") return { type: "fixRecipe", host: host, id: r.id }
  if (key === "remove") return { type: "removeRecipeNow", host: host, id: r.id }
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
// (`best`) is marked; the rows are in name order, and a build this machine can't run is left out when the same model has a build it can.
function recipeOffers(list, status) {
  const models = status && isPlainObject(status.models) ? status.models : {}
  let offers = (Array.isArray(list) ? list : []).map(function (r) {
    const entry = models[r.id]
    const best = r.best === true
    if (entry) return { recipe: r, action: null, text: entry.unit === "installing" ? "Being set up" : "On this machine", best: best }
    if (r.installed === true) return { recipe: r, action: null, text: "On this machine", best: best }
    if (r.available !== true || recipeSource(r) === "drafted") return { recipe: r, action: null, text: String(r.reason || "") || (recipeSource(r) === "drafted" ? DRAFTED_TEXT : "Can't run on this machine"), best: best, blocked: r.available !== true }
    // A recipe of yours downloads what it names and runs it: the engine wants --yes, which the panel sends only after the
    // person has seen the download (its dry run, which needs the context). Without one there is nothing to show.
    if (isUserRecipe(r) && !(Number(r.context) > 0)) return { recipe: r, action: null, text: "Its context is unknown, so its download can't be shown yet", best: best }
    return { recipe: r, action: "use", confirm: isUserRecipe(r), text: best ? "Recommended for this machine" : "", best: best }
  })
  const label = function (o) { return String(o.recipe.name || o.recipe.id) }
  // One model often has a build for each kind of machine (the same name for an AMD runtime and an NVIDIA one): a build this machine
  // can't run is dropped when another of the same name is usable here (or set up here), so the model is listed once.
  const usable = {}
  offers.forEach(function (o) { if (!o.blocked) usable[label(o)] = true })
  offers = offers.filter(function (o) { return !o.blocked || !usable[label(o)] })
  // By name: each row says where it stands (set up, on this machine, can't run), so the list is not grouped by that.
  offers.sort(function (a, b) { return label(a).localeCompare(label(b), undefined, { sensitivity: "base", numeric: true }) || a.recipe.id.localeCompare(b.recipe.id) })
  return offers.map(function (o) { return { recipe: o.recipe, action: o.action, confirm: o.confirm === true, text: o.text, best: o.best } })
}

// ---- user recipes ----------------------------------------------------------------------------------------
// A user recipe is one the person added (the engine marks it `user`); a curated one ships with the engine. A variant's
// (and a listing row's) `source` says where its numbers come from: measured (the default, and what every curated recipe
// has), estimated, or drafted, which never counts as fitting.

var DRAFTED_TEXT = "Drafted: its numbers are not measured yet, so it is not yet fitting"

// "measured" when none is given; a word we don't know is treated as the cautious one, drafted.
function recipeSource(r) {
  const s = r && r.source !== undefined && r.source !== null && r.source !== "" ? String(r.source) : "measured"
  return s === "measured" || s === "estimated" ? s : "drafted"
}

function isUserRecipe(r) { return !!r && r.user === true }

// The marks a recipe wears in the picker and the Add recipe card: "yours", then where its numbers come from when that isn't
// measured. Curated recipes wear none.
function recipeMarks(r) {
  const marks = []
  if (!isUserRecipe(r)) return marks
  marks.push("yours")
  const s = recipeSource(r)
  if (s === "estimated") marks.push("estimated")
  else if (s === "drafted") marks.push("drafted, not yet fitting")
  return marks
}

// Where a recipe in the picker comes from: the engine's own ("omarchy"), TensorFold's list ("tensorfold": added from it, which
// the saved record of this machine says), or yours ("custom": a file you added). `tf` is the parsed TensorFold list or null.
function recipeOrigin(r, tf) {
  if (!isUserRecipe(r)) return "omarchy"
  return tfAddedRow(tf, r.id) ? "tensorfold" : "custom"
}
var ORIGIN_WORDS = { omarchy: "Omarchy local AI", tensorfold: "TensorFold", custom: "Custom" }
function originWords(origin) { return ORIGIN_WORDS[origin] || "" }

// The picker's search box filters its rows: every word typed must be somewhere in a row's text, whatever the case.
function pickerWords(text) { return String(text || "").toLowerCase().split(/\s+/).filter(function (w) { return w !== "" }) }
function pickerMatches(haystack, words) {
  const h = String(haystack).toLowerCase()
  return words.every(function (w) { return h.indexOf(w) >= 0 })
}
function filterOffers(offers, text, tf) {
  const words = pickerWords(text)
  if (words.length === 0) return offers
  return offers.filter(function (o) {
    const r = o.recipe
    return pickerMatches([r.name, r.id, r.vendor, originWords(recipeOrigin(r, tf))].join(" "), words)
  })
}
function filterTfRows(rows, text) {
  const words = pickerWords(text)
  if (words.length === 0) return rows
  return rows.filter(function (r) { return pickerMatches([r.name, r.id, r.format, ORIGIN_WORDS.tensorfold].join(" "), words) })
}

function userRecipes(list) { return (Array.isArray(list) ? list : []).filter(isUserRecipe) }

// `startdgx recipe validate|add HOST FILE --json`: { ok, id, errors, message }, or null when it isn't that. A rejection
// has to say why.
function parseRecipeResult(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || typeof p.ok !== "boolean" || !Array.isArray(p.errors)) return null
  const errors = p.errors.map(String).filter(function (e) { return e !== "" })
  if (!p.ok && errors.length === 0) return null
  return { ok: p.ok, id: String(p.id || ""), errors: errors, message: String(p.message || "") }
}

// The CLI's arguments to validate or add the recipe file at `path`: after `--`, so a path that starts with - is a path.
function recipeSendCommand(verb, host, path) {
  return ["recipe", verb, host, "--json", "--timeout", "60", "--", String(path).trim()]
}

// What is wrong with the path typed, before the machine is asked; "" when nothing.
function recipePathProblem(path) {
  const p = String(path || "").trim()
  if (p === "") return "Type the path to a recipe file on this computer."
  if (!/\.toml$/.test(p)) return "A recipe file ends in .toml, and its name (without it) is the recipe's id."
  return ""
}

// What can be done with a variant of a user recipe: measure it (a drafted or estimated one; the engine runs it and records
// what it showed), or confirm an estimated one's numbers (it then counts as fitting). A measured one needs neither.
function variantActions(v) {
  const source = recipeSource(v)
  return source === "measured" ? [] : source === "estimated" ? (v.confirmed === true ? ["measure"] : ["confirm", "measure"]) : ["measure"]
}

// The picker's Measure… on a recipe of yours whose numbers aren't measured and that isn't on the machine yet: the context
// to measure at (the listing row's own), or 0 when the row doesn't say, which sends the person to Add recipe…'s variants.
// null when there is nothing to measure.
function pickerMeasureCtx(r) {
  if (!isUserRecipe(r) || r.installed === true) return null
  // The engine lists no source and no context for a recipe none of whose variants fits (a draft's only variant, say):
  // it may be unmeasured, so the variants are the place to see.
  const unsaid = (r.source === undefined || r.source === null || r.source === "") && r.available === false
  if (recipeSource(r) === "measured" && !unsaid) return null
  return Number(r.context) > 0 ? Number(r.context) : 0
}

// `startdgx recipe measure HOST ID --ctx N` without --yes: the engine's dry run, as lines (what it would download and
// load), without its closing "Nothing was changed", which the card says its own way; or null when it said nothing.
function parseMeasurePlan(text) {
  const all = lines(text).filter(function (l) { return l.indexOf("Nothing was changed") !== 0 })
  return all.length ? all : null
}

// The lines the confirmation card shows. The machine's dry run is a measuring run's plan; for a plain set-up only what it downloads and
// loads applies (the bench and the lock are the measuring run's), and it starts if there is room. Falls back to every line when it
// can't tell which those are.
function runPlanLines(plan, mode) {
  const all = Array.isArray(plan) ? plan : []
  if (mode !== "setup") return all
  const kept = all.filter(function (l) { return /^(download|load):/i.test(String(l)) })
  return kept.length === 0 ? all : kept.concat(["then: it starts if there is room for it"])
}

// The confirmation card's words, for a measure or a setup of `r` at `ctx` on `host`: { title, body, button }.
function recipeRunWords(mode, r, ctx, host) {
  const name = String(r.name || r.id)
  const size = Math.round(Number(ctx) / 1024) + "K"
  const runs = "A recipe of yours downloads what it names and runs it on " + host + ". Read what it will do, then say go."
  return mode === "measure"
    ? { title: "Measure " + name + " at " + size + "?", button: "Download and measure",
        body: runs + " Measuring loads it at this context, benches it for a few minutes and records the memory and speed it showed; a model that runs there is restarted." }
    : { title: "Set up " + name + " on " + host + "?", button: "Download and set up", body: runs }
}

// "128K measured · 64K drafted": a recipe's variants and where each one's numbers come from.
function variantsText(variants) {
  return (Array.isArray(variants) ? variants : []).map(function (v) { return Math.round(Number(v.ctx) / 1024) + "K " + recipeSource(v) }).join(" · ")
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

// A setup that was asked for with the model store as its destination: what to do as each status read comes in. `waiting` is { "host/id":
// { seen } }. While it downloads there is nothing to do; when it has finished and the model runs, stop it; once it has been stopped on two
// reads in a row (the engine may be about to start it), move it. A setup that failed is dropped. -> { waiting, actions: [{ type, host, id }] }.
function moveAfterStep(waiting, host, status) {
  const models = status && isPlainObject(status.models) ? status.models : {}
  const next = Object.assign({}, waiting)
  const actions = []
  for (const key in waiting) {
    if (key.indexOf(host + "/") !== 0) continue
    const id = key.substring(host.length + 1)
    const e = models[id]
    if (!e) continue
    const unit = e.unit
    if (unit === "installing") {
      if (e.install && e.install.phase === "failed") delete next[key]
      else next[key] = { seen: 0, stopping: false }
    } else if (unit === "active" || unit === "activating") {
      if (!waiting[key].stopping) { actions.push({ type: "stop", host: host, id: id }); next[key] = { seen: 0, stopping: true } }
    } else if (unit === "inactive" || unit === "failed") {
      const seen = (waiting[key].seen || 0) + 1
      if (seen >= 2) { actions.push({ type: "move", host: host, id: id, to: "usb" }); delete next[key] }
      else next[key] = { seen: seen, stopping: waiting[key].stopping }
    }
  }
  return { waiting: next, actions: actions }
}

// A setup asked for from the panel is shared on the tailnet once it has finished downloading (sharing is on by default; the
// model's gear turns it off). `waiting` is { "host/id": true }. A model the machine lists with its setup done (any unit but
// installing) is shared, once; a setup that failed is dropped, and so is one already shared. -> { waiting, actions: [{ type, host, id }] }.
function shareAfterStep(waiting, host, status) {
  const models = status && isPlainObject(status.models) ? status.models : {}
  const next = Object.assign({}, waiting)
  const actions = []
  for (const key in waiting) {
    if (key.indexOf(host + "/") !== 0) continue
    const id = key.substring(host.length + 1)
    const e = models[id]
    if (!e || e.unit === "installing" && !(e.install && e.install.phase === "failed")) continue
    delete next[key]
    if (e.unit !== "installing" && e.shared !== true) actions.push({ type: "share", host: host, id: id })
  }
  return { waiting: next, actions: actions }
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

// ---- a model's context -----------------------------------------------------------------------------------

// The memory the engine keeps free for the desktop beside a model (its RESERVE_GIB).
var RESERVE_GIB = 8

// `startdgx variants HOST MODEL --json`: [{ ctx, peak_ram_gib, peak_gpu_gib }], the contexts the recipe has
// measured, largest first (and at one context the one that needs the most first, the engine's own order); or null.
function parseVariants(text) {
  const parsed = parseJson(text)
  if (!Array.isArray(parsed) || parsed.length === 0) return null
  for (let i = 0; i < parsed.length; i++) {
    const v = parsed[i]
    if (!isPlainObject(v) || !(Number(v.ctx) > 0) || !(Number(v.peak_ram_gib) > 0)) return null
  }
  return parsed.slice().sort(function (a, b) { return b.ctx - a.ctx || b.peak_ram_gib - a.peak_ram_gib })
}

// One variant as a row: { ctx, label, need, text, fits, current, source, confirmed }. It fits as the engine's `fits`
// says: its memory and the desktop's reserve are within the machine's (ramTotalGib; 0 when unknown, which leaves it to
// the engine, whose own check refuses what doesn't fit and keeps the old setup), its numbers are not a draft, and an
// estimated one has been confirmed. (The engine also checks GPU-addressable memory, which the status doesn't carry.)
function variantChoice(v, currentCtx, ramTotalGib) {
  const need = Number(v.peak_ram_gib)
  const source = recipeSource(v)
  const confirmed = v.confirmed === true
  const room = !(ramTotalGib > 0) || need + RESERVE_GIB <= ramTotalGib
  return {
    ctx: v.ctx, label: Math.round(v.ctx / 1024) + "K", need: need, fits: room && source !== "drafted" && (source !== "estimated" || confirmed),
    current: v.ctx === Number(currentCtx), source: source, confirmed: confirmed,
    text: source === "drafted" ? "Needs about " + need + " GiB of memory. " + DRAFTED_TEXT
      : !room ? "Needs " + need + " GiB of memory and " + RESERVE_GIB + " GiB for the desktop; this machine has " + Math.round(ramTotalGib)
      : source === "estimated" ? "Estimated to need " + need + " GiB of memory, not measured" + (confirmed ? "; you confirmed it" : "; Confirm it before it can run")
      : "Needs " + need + " GiB of memory"
  }
}

// Every variant of a recipe, as its file has them (the Add recipe card's list): two at one context are two rows.
function variantRows(variants) {
  return variants.map(function (v) { return variantChoice(v, 0, 0) })
}

// The context sizes a model can be given: one choice per context, largest first. A recipe may measure a context more
// than once (a bigger setup for a bigger machine), and `use --ctx` names only the context: the engine then takes the
// variant that needs the most memory and still fits, or refuses with the smallest one's reason (its pick_variant). So
// each choice carries the numbers of the variant the engine would run.
function contextChoices(variants, currentCtx, ramTotalGib) {
  const groups = {}, order = []
  for (let i = 0; i < variants.length; i++) {
    const c = variantChoice(variants[i], currentCtx, ramTotalGib)
    if (!groups[c.ctx]) { groups[c.ctx] = []; order.push(c.ctx) }
    groups[c.ctx].push(c)
  }
  return order.sort(function (a, b) { return b - a }).map(function (ctx) {
    const same = groups[ctx].sort(function (a, b) { return b.need - a.need })
    return same.filter(function (c) { return c.fits })[0] || same[same.length - 1]
  })
}

// "context" when the model's context can be changed now: it is set up and at rest (running, stopped or failed),
// with no click of its own waiting. The engine restarts a running model with the new context, and starts a stopped one.
function contextAction(entry, pending) {
  if (!entry || pending || !isTextModel(entry)) return null
  return ["active", "inactive", "failed"].indexOf(entry.unit) >= 0 ? "context" : null
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

// ---- updating the engine ---------------------------------------------------------------------------------------

// What a machine's status says of its engine: `engine_update` is {from, to} when the engine startdgx installed there
// is an older release than the one this plugin pins (the CLI decides, from the host's manifest). Returns
// {from, to, text}, or null.
function engineUpdate(status) {
  const update = status && isPlainObject(status.engine_update) ? status.engine_update : null
  if (!update || typeof update.from !== "string" || typeof update.to !== "string") return null
  return { from: update.from, to: update.to, text: "Engine " + update.from + "; " + update.to + " is available" }
}

// `startdgx uninstall HOST --dry-run --json`: { host, steps, kept, manual, models_bytes, packages }, or null.
function parseUninstallPlan(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || !stringList(p.steps) || !stringList(p.kept) || !stringList(p.manual) || !stringList(p.packages)) return null
  if (p.models_bytes !== null && !(typeof p.models_bytes === "number" && p.models_bytes >= 0)) return null
  if (p.recipes !== undefined && !(typeof p.recipes === "number" && p.recipes >= 0)) return null
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
  if (typeof plan.recipes === "number" && plan.recipes > 0) {
    out.push({ flag: "--delete-recipes", label: "Also delete the recipes you added",
      description: plan.recipes + (plan.recipes === 1 ? " recipe is" : " recipes are") + " kept otherwise. Adding one again needs its file." })
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

// ---- Draft recipe on a result -------------------------------------------------------------------------------
// One action puts a model on a machine: `recipe draft` writes the file (asked with --host, so an id the machine already has is
// refused before anything is written), then the Add recipe path (`recipe add`) validates and adds it. Never a fit verdict:
// the variant is drafted until a measuring run (docs/adr/0001).

// `recipe draft --json`: { id, path, warnings }, or null when it isn't a successful draft. Failures are `Error:` on stderr.
function parseDraftResult(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || p.ok !== true || typeof p.id !== "string" || p.id === "" || typeof p.path !== "string" || p.path === "") return null
  if (!Array.isArray(p.warnings)) return null
  return { id: p.id, path: p.path, source: p.source === "estimated" ? "estimated" : "drafted", name: typeof p.name === "string" && p.name !== "" ? p.name : p.id, ctx: Number(p.ctx) > 0 ? Number(p.ctx) : 0,
           warnings: p.warnings.map(String).filter(function (w) { return w !== "" }) }
}

// What the card says while a step runs: "drafting" (the CLI), "checking" and "adding" (the machine's engine).
function draftStatus(step, host, repo) {
  if (step === "drafting") return "Writing the recipe for " + repo + "…"
  if (step === "checking") return "Asking " + hostName(host) + " to check the draft…"
  if (step === "adding") return "Adding the draft to " + hostName(host) + "…"
  return ""
}

// The CLI's failure line for the card, which has no --id to offer: an id clash ends at what the machine has; a draft file left by
// an earlier try says to delete it.
function draftErrorText(line) {
  return String(line).replace(/: pick another id with --id, or delete the file$/, ": delete the file to draft it again").replace(/: pick another id with --id$/, "").replace(/, or pick another id with --id$/, "")
}

function draftDone(host, id, source) {
  return source === "estimated"
    ? id + " is in the list above. Nothing is downloaded until you set it up; its gear changes context, requests at once and input."
    : id + " is on " + hostName(host) + " but not measured yet, so it can't run. Measure… downloads it and tests it there; after that it is a model like the others."
}

// ---- TensorFold's list on the Find card ---------------------------------------------------------------------------------------
// `startdgx tensorfold list --json` ({ first_look, recipes: [{ id, name, format, estimate_gb, repo, draftable, reason, status }] }), read
// from this computer like the Hugging Face search. Its memory figure is the list's estimate, so a draft from a row is `drafted` and
// never fits until a measuring run (docs/adr/0001). `status` says what the last saved look didn't have: "new" or "changed".

// The choices an entry offers, { defaults: { context, parallel, input }, contexts, requests, inputs }, or null (the CLI has checked them;
// this only keeps the card from reading what isn't there).
function tfSettings(x) {
  if (!isPlainObject(x) || !isPlainObject(x.defaults) || !Array.isArray(x.contexts) || !Array.isArray(x.requests) || !Array.isArray(x.inputs)) return null
  if (x.contexts.length === 0 || x.requests.length === 0 || x.inputs.length === 0) return null
  return { defaults: { context: Number(x.defaults.context), parallel: Number(x.defaults.parallel), input: String(x.defaults.input) },
           contexts: x.contexts.map(Number), requests: x.requests.map(Number), inputs: x.inputs.map(String) }
}

function parseTfList(text) {
  const p = parseJson(text)
  if (!isPlainObject(p) || !Array.isArray(p.recipes)) return null
  const rows = []
  for (let i = 0; i < p.recipes.length; i++) {
    const r = p.recipes[i]
    if (!isPlainObject(r) || typeof r.id !== "string" || r.id === "" || typeof r.name !== "string") return null
    rows.push({ id: r.id, name: r.name, format: String(r.format || ""), estimate: Number(r.estimate_gb) > 0 ? Number(r.estimate_gb) : 0,
                settings: tfSettings(r.settings),
                added: isPlainObject(r.added) && typeof r.added.recipe_id === "string" ? { recipeId: r.added.recipe_id, revision: String(r.added.revision || ""),
                  context: Number(r.added.context) || 0, parallel: Number(r.added.parallel) || 0, input: String(r.added.input || "") } : null,
                outdated: r.outdated === true,
                repo: typeof r.repo === "string" ? r.repo : "", recipeId: typeof r.recipe_id === "string" ? r.recipe_id : "", draftable: r.draftable === true, reason: String(r.reason || ""),
                status: r.status === "new" || r.status === "changed" ? r.status : "" })
  }
  return { firstLook: p.first_look === true, rows: rows }
}

// The CLI's arguments: the list, or the list and the look saved ("Mark as seen").
function tfListCommand(update, host) {
  return ["tensorfold", "list", "--json"].concat(update ? ["--update"] : [], host ? ["--host", host] : [])
}

// The CLI's arguments to draft an entry for `host`, the entry after `--`. `choices` ({ context, parallel, input }, any of them) are
// sent only where they differ from what the entry defaults to, so an untouched entry is drafted exactly as before.
function tfDraftCommand(host, entry, choices, settings, replace) {
  const args = []
  const d = settings ? settings.defaults : null
  if (choices && d) {
    if (choices.context !== undefined && Number(choices.context) !== d.context) args.push("--context", String(choices.context))
    if (choices.parallel !== undefined && Number(choices.parallel) !== d.parallel) args.push("--parallel", String(choices.parallel))
    if (choices.input !== undefined && String(choices.input) !== d.input) args.push("--input", String(choices.input))
  }
  // --estimated: the list's estimate is the variant's numbers and the add confirms them, so the model can be set up without a measuring run.
  return ["tensorfold", "draft", "--host", host, "--json", "--estimated"].concat(args, replace ? ["--replace"] : [], ["--", String(entry)])
}

// What a choice reads as on the card: "16K", "2", "Text + images".
var TF_INPUT_NAMES = { text: "Text only", images: "Text + images", video: "Text + images + video" }
function tfChoiceLabel(key, value) {
  if (key === "context") return Math.round(Number(value) / 1024) + "K"
  if (key === "input") return TF_INPUT_NAMES[value] || String(value)
  return String(value)
}

// The values to show for an entry: its defaults, with what the person picked on top.
function tfValues(settings, picked) {
  if (!settings) return null
  return { context: picked && picked.context !== undefined ? picked.context : settings.defaults.context,
           parallel: picked && picked.parallel !== undefined ? picked.parallel : settings.defaults.parallel,
           input: picked && picked.input !== undefined ? picked.input : settings.defaults.input }
}

// Whether the picked values differ from the defaults.
function tfCustomized(settings, picked) {
  const v = tfValues(settings, picked)
  return !!v && (v.context !== settings.defaults.context || v.parallel !== settings.defaults.parallel || v.input !== settings.defaults.input)
}

// The list as the card shows it: the rows that can be added, and the ones that can't yet (collapsed into one line until asked for).
function tfSplit(list) {
  const rows = list ? list.rows : []
  return { ready: rows.filter(function (r) { return r.draftable }), blocked: rows.filter(function (r) { return !r.draftable }) }
}

function tfBlockedText(blocked) {
  return blocked.length === 0 ? "" : blocked.length + " more can't be added yet"
}

// Where a Find row stands on the machine, from the machine's recipe list (`startdgx list`, the picker's rows) and its status:
// { state: "" | "ready" | "unmeasured" | "nofit" | "on", measured, measureCtx, recipe } . "" means it can be added; "ready" is added and the machine
// counts it as fitting (measured, or an estimate that was confirmed: `measured` says which), so Set up… is the next step and Measure… (the
// ctx is the row's own) an optional way to replace an estimate; "unmeasured" is added but its numbers don't count yet (a draft: it has to be
// measured); "nofit" is added and measured, and doesn't fit this machine; "on" is a model of the machine already (set up or being set up).
// `recipes` is null while the list is being read.
function findState(recipeId, recipes, status) {
  const none = { state: "", measured: false, measureCtx: 0, recipe: null }
  if (!recipeId || !Array.isArray(recipes)) return none
  const r = recipes.filter(function (x) { return x && x.id === recipeId })[0]
  if (!r) return none
  const models = status && isPlainObject(status.models) ? status.models : {}
  const measured = recipeSource(r) === "measured"
  if (models[recipeId] || r.installed === true) return { state: "on", measured: measured, measureCtx: 0, recipe: r }
  if (r.available === true) return { state: "ready", measured: measured, measureCtx: measured ? 0 : Math.max(0, Number(r.context) || 0), recipe: r }
  const ctx = pickerMeasureCtx(r)
  return ctx === null ? { state: "nofit", measured: true, measureCtx: 0, recipe: r } : { state: "unmeasured", measured: false, measureCtx: ctx, recipe: r }
}

function findStateText(s) {
  return s.state === "on" ? "Already on this machine" : s.state === "ready" ? (s.measured ? "Added \u00b7 measured" : "In the model list")
    : s.state === "unmeasured" ? "Added, not measured yet" : s.state === "nofit" ? "Added, but it doesn't fit this machine" : ""
}

// What Update does for a row the machine already has: { kind: "" | "update" | "blocked", confirm, text }. The list has moved on from what the
// machine was given (`outdated`, from the record `tensorfold draft --host` keeps). A draft is replaced at once; a measured recipe's
// measurement is lost, so it asks first (`confirm`); a model set up from the recipe can't be replaced, so it says to remove that first.
function tfUpdatePlan(row, st) {
  if (!row || !row.outdated || !st || st.state === "") return { kind: "", confirm: false, text: "" }
  if (st.state === "on") return { kind: "blocked", confirm: false, text: "Update available: remove the model first" }
  return { kind: "update", confirm: st.measured === true && st.state !== "unmeasured", text: "Update available" }
}

// The choices an update gives the machine again: what it was given before, as the picks the draft command compares with the defaults.
function tfAddedChoices(row) {
  return row && row.added ? { context: row.added.context, parallel: row.added.parallel, input: row.added.input } : null
}

// A row's one-line state, with "update available" where the list has moved on.
function tfStateText(row, st) {
  const base = findStateText(st)
  const plan = tfUpdatePlan(row, st)
  return plan.kind === "update" ? (st.state === "unmeasured" ? "Added, not measured \u00b7 update available" : "Added \u00b7 update available") : plan.kind === "blocked" ? "On this machine \u00b7 update available" : base
}

// What the model picker shows under the machine's own recipes, from TensorFold's list: the entries that can be added and aren't on the machine's
// list yet, and one line about those that can't be added yet. `recipes` is the machine's recipe list (null while read).
function tfOffers(list, recipes, status) {
  const parts = tfSplit(list)
  const rows = parts.ready.filter(function (r) { return findState(r.recipeId, recipes, status).state === "" })
  return { rows: rows, blockedText: parts.blocked.length === 0 ? "" : parts.blocked.length + " more TensorFold " + (parts.blocked.length === 1 ? "entry needs" : "entries need") + " a runtime this engine doesn't have yet." }
}

// A row's facts, as plain text: the format and the list's memory estimate (an estimate, never a fit).
function tfRowText(row) {
  const memory = row.estimate > 0 ? Math.round(row.estimate * 10) / 10 + " GB estimated by TensorFold" : "no memory estimate"
  return (row.format !== "" ? row.format + " \u00b7 " : "") + memory
}

// What a row can't do, as the reason the card shows beside it: "" when it can be drafted.
function tfRowNote(row) {
  return row.draftable ? "" : row.reason !== "" ? row.reason : "Can't be drafted"
}

// The line under the heading once the list is read: how many, and how many are new or changed since the saved look.
function tfSummary(list) {
  if (!list) return ""
  const fresh = list.rows.filter(function (r) { return r.status !== "" }).length
  const base = list.rows.length + (list.rows.length === 1 ? " MODEL" : " MODELS") + " FOR ONE DGX SPARK"
  return base + (fresh > 0 ? " \u00b7 " + fresh + " NEW OR CHANGED" : "")
}

// ---- With an agent… on a result -------------------------------------------------------------------------------
// The agent runs in Omarchy's terminal through `startdgx launch author HOST REPO`, so the draft's errors and the agent show
// there; the panel sends nothing else and never an agent command of its own (it is the CLI's config).
var AUTHOR_TEXT = "With an agent…"
var REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

// What launch takes for `repo`, or null when it is not an OWNER/NAME repo.
function authorLaunch(host, repo) {
  if (typeof repo !== "string" || !REPO_RE.test(repo) || repo.split("/").some(function (part) { return /^\.+$/.test(part) })) return null
  return { verb: "author", host: host, id: repo }
}

function authorHint() {
  return "Opens a terminal with an agent that finishes this recipe. It asks before any download or measuring run."
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

// ---- the window's titlebar --------------------------------------------------------------------
// In Omarchy's window mode a floating window carries a titlebar (the hyprbars plugin, drawn by omarchy-hyprland-titlebars)
// with its own close button, so the window's corner X would be a second one. The titlebar shows when the window floats,
// is tagged as being on a floating workspace, and the plugin is loaded (without it nothing would close the window).
// `clientsJson` is `hyprctl clients -j` and `pluginsText` is `hyprctl plugin list`.
var TITLEBAR_TAG = "omarchy-floating-workspace"
var TITLEBAR_EVENTS = ["changefloatingmode", "movewindowv2", "configreloaded", "openwindow"]

function hasTitlebar(clientsJson, pluginsText, title, wmClass) {
  if (!/hyprbars/i.test(pluginsText || "")) return false
  var clients
  try { clients = JSON.parse(clientsJson) } catch (e) { return false }
  if (!Array.isArray(clients)) return false
  return clients.some(function (c) {
    // A rule's tag arrives as "name*"; the star only says where it came from.
    return c.title === title && c.class === wmClass && c.floating === true
      && (c.tags || []).some(function (t) { return String(t).replace(/\*$/, "") === TITLEBAR_TAG })
  })
}

// ---- ComfyUI installs --------------------------------------------------------------------------------------
// `startdgx comfyui list --json` (the installs startdgx manages on a machine) and, from the status poll, which of them runs.

// The last line of a job's log, "" for none.
function lastLogLine(job) {
  const log = job && Array.isArray(job.log) ? job.log : []
  for (let i = log.length - 1; i >= 0; i--) if (String(log[i]).trim() !== "") return String(log[i]).trim()
  return ""
}

// A ComfyUI row's key, for the cursor and the marks: a path has slashes, so it can't be told from a model's "host/id".
function comfyKey(host, path) { return host + "#comfy/" + path }

// The installs `comfyui list` sent, or null when the answer isn't one.
function parseComfyList(text) {
  const parsed = parseJson(text)
  if (!isPlainObject(parsed) || !Array.isArray(parsed.installs)) return null
  for (let i = 0; i < parsed.installs.length; i++) {
    const item = parsed.installs[i]
    if (!isPlainObject(item) || typeof item.path !== "string" || item.path === "") return null
  }
  return parsed.installs
}

function comfyAnswer(code, stdout, stderr, host) {
  if (code !== 0) return { installs: null, error: errorLine(stderr, host + " didn't answer") }
  const installs = parseComfyList(stdout)
  return installs ? { installs: installs } : { installs: null, error: host + " sent an unreadable ComfyUI answer" }
}

// The running managed installs the status poll saw, { path: MiB }.
function comfyRunning(status) {
  const out = {}
  const list = status && Array.isArray(status.comfyui) ? status.comfyui : []
  for (let i = 0; i < list.length; i++) {
    const item = list[i]
    if (isPlainObject(item) && typeof item.path === "string") out[item.path] = Number(item.rss_mib) || 0
  }
  return out
}

// Where the running managed installs listen, as the status poll read it off each process: { path: { port, bind } }.
function comfyListening(status) {
  const out = {}
  const list = status && Array.isArray(status.comfyui) ? status.comfyui : []
  for (let i = 0; i < list.length; i++) {
    const item = list[i]
    if (isPlainObject(item) && typeof item.path === "string" && Number(item.port) > 0) out[item.path] = { port: Number(item.port), bind: String(item.bind || "") }
  }
  return out
}

// What a ComfyUI install's row shows: { path, name, state, version, note, gib }. `state` is running, stopped, or one
// that can't run: unfinished (its ComfyUI isn't installed yet), missing (its folder is gone), unsupported (a foreign
// folder). `note` says why such a row, or an install too old for startdgx to read, can't be used as it is.
function comfyRow(install, status, job, host) {
  const path = String(install.path)
  const tool = isPlainObject(install.tool) ? install.tool : {}
  const rss = comfyRunning(status)[path]
  const name = String(install.label || "") || path.replace(/\/+$/, "").split("/").pop() || path
  const version = tool.tag ? String(tool.tag) : tool.branch ? String(tool.branch) + (tool.dirty ? " \u00b7 changed" : "") : String(tool.commit || "")
  let state = "stopped"
  let note = ""
  if (install.present === false) { state = "missing"; note = "Its folder is gone" }
  else if (install.kind && install.kind !== "dgx-comfyui") { state = "unsupported"; note = "Not a dgx-comfyui folder" }
  else if (install.installed === false) { state = "unfinished"; note = "ComfyUI isn't installed in it yet" }
  else if (rss !== undefined) state = "running"
  if (state !== "missing" && state !== "unsupported" && install.json_capable === false) note = "Too old for startdgx to read: update it"
  // A job on it (`comfyui job`): running, it is installing or updating, and says the last thing its log said; a failed install
  // says so and can be run again, where it stopped.
  const work = job && job.state === "running" ? (install.installed === false ? "Installing" : job.kind === "recipe" ? "Installing workflow" : "Updating") : ""
  if (work !== "") { state = "working"; note = lastLogLine(job) || work + "\u2026" }
  else if (job && job.state === "failed" && install.installed === false) { state = "failed"; note = "The install failed" + (lastLogLine(job) ? ": " + lastLogLine(job) : "") }
  // Where a running one is reached from this machine ("" when unknown, or it listens on the machine itself): the poll read it off the process.
  const seen = state === "running" ? comfyListening(status)[path] : undefined
  const url = seen && host ? comfyUrl(host, seen) : ""
  return { path: path, name: name, state: state, work: work, version: version, note: note, gib: rss !== undefined ? rss / 1024 : 0, url: url,
           tool: { tag: String(tool.tag || ""), branch: String(tool.branch || ""), dirty: !!tool.dirty, unpushed: Number(tool.unpushed) || 0 } }
}

// A machine's ComfyUI line under its name: "2 ComfyUI installs, one running", or "" for none.
function comfySummary(rows) {
  if (rows.length === 0) return ""
  const running = rows.filter(function (r) { return r.state === "running" }).length
  return rows.length + (rows.length === 1 ? " install" : " installs") + (running > 0 ? ", " + running + " running" : "")
}

// A ComfyUI install's Start or Stop: { action: "start" | "stop" | "", reason }. `info` is its comfyRow, `pending` its mark
// (a click already waits), `rows` the machine's comfyRows. One ComfyUI runs at a time on a machine (they share its memory), so
// a stopped install can't start while another runs: no button, and `reason` says which to stop.
function comfyToggle(info, pending, rows) {
  if (!info || String(pending || "") !== "") return { action: "", reason: "" }
  if (info.state === "running") return { action: "stop", reason: "" }
  if (info.state === "failed") return { action: "retry", reason: "" }
  if (info.state !== "stopped") return { action: "", reason: "" }
  const other = (rows || []).filter(function (r) { return r.state === "running" && r.path !== info.path })[0]
  return other ? { action: "", reason: "ComfyUI in " + other.name + " is running: stop it first" } : { action: "start", reason: "" }
}

// The key that starts or stops the install under the cursor (Enter or s), or null.
function comfyKeyAction(key, row, toggle, repeat) {
  const k = String(key).toLowerCase()
  if (!row || row.kind !== "comfy" || repeat || !toggle || !toggle.action) return null
  // `o` opens a running one (its Stop is what offers).
  if (k === "o") return toggle.action === "stop" ? { type: "comfyOpenAt", host: row.host, path: row.id } : null
  if (k !== "s" && k !== "enter") return null
  return { type: "comfyToggle", host: row.host, path: row.id, kind: toggle.action }
}

// The command for a ComfyUI action ({ kind, path, label }): start, stop, adopt.
function comfyCommand(host, job) {
  switch (job.kind) {
  case "start": return ["comfyui", "start", host, "--dir", job.path, "--timeout", "120"]
  case "stop": return ["comfyui", "stop", host, "--dir", job.path, "--timeout", "120"]
  case "install": return ["comfyui", "install", host, "--dir", job.path].concat(job.label ? ["--label", job.label] : [], ["--timeout", "120"])
  // The label is the workflow's name here.
  case "recipe-install": return ["comfyui", "recipe", "install", host, job.label, "--dir", job.path, "--timeout", "120"]
  case "update": return ["comfyui", "update", host, "--dir", job.path, "--timeout", "120"]
  case "update-comfyui": return ["comfyui", "update", host, "--dir", job.path, "--comfyui", "--timeout", "120"]
  case "adopt": return ["comfyui", "adopt", host, "--dir", job.path].concat(job.label ? ["--label", job.label] : [], ["--timeout", "60"])
  // `autostart on` runs it as a background service and starts it now; `off` removes the service, which stops it.
  case "autostart-on": return ["comfyui", "autostart", host, "on", "--dir", job.path, "--timeout", "120"]
  case "autostart-off": return ["comfyui", "autostart", host, "off", "--dir", job.path, "--timeout", "120"]
  case "forget": return ["comfyui", "forget", host, "--dir", job.path].concat(job.stopService ? ["--stop-service"] : [], ["--timeout", "60"])
  }
  return null
}

// What a ComfyUI action shows on its row: the service switch starts or stops it, as Start and Stop do.
function comfyMark(kind) { return kind === "autostart-on" ? "start" : kind === "autostart-off" ? "stop" : kind === "update-comfyui" ? "update" : kind === "recipe-install" ? "recipe" : kind }

// The marks of a machine's ComfyUI actions, "host#comfy/path" -> start | stop | adopt | forget: the ones running or waiting (`jobs`,
// [{ kind, path }]), and a start or stop that has finished until the status poll shows it took (the process takes seconds to
// show or go), at most 30 s (`settling`, [{ kind, path, until }]). { marks, settling }, the settling ones still to wait for.
function comfyMarks(host, jobs, settling, status, now) {
  const marks = {}
  for (let i = 0; i < jobs.length; i++) if (!(comfyKey(host, jobs[i].path) in marks)) marks[comfyKey(host, jobs[i].path)] = comfyMark(jobs[i].kind)
  const running = comfyRunning(status)
  const keep = []
  for (let i = 0; i < settling.length; i++) {
    const s = settling[i]
    const up = s.path in running
    if (now > s.until || (s.kind === "start" && up) || (s.kind === "stop" && !up)) continue
    keep.push(s)
    if (!(comfyKey(host, s.path) in marks)) marks[comfyKey(host, s.path)] = s.kind
  }
  return { marks: marks, settling: keep }
}

// What the Find existing card lists, from `comfyui discover`: { path, name, text, offer, managed }. `offer` is "adopt" for a
// dgx-comfyui folder startdgx doesn't manage yet, "" for one it does and for a ComfyUI it can't manage.
function comfyFindRows(installs) {
  return installs.map(function (i) {
    const row = comfyRow(i, null)
    const sources = Array.isArray(i.sources) ? i.sources : []
    const bits = []
    if (i.kind !== "dgx-comfyui") bits.push(String(i.reason || "Not a dgx-comfyui folder"))
    else {
      if (row.version) bits.push(row.version)
      if (i.installed === false) bits.push("ComfyUI isn't installed in it yet")
      if (i.json_capable === false) bits.push("older than startdgx reads")
      if (sources.indexOf("process") >= 0) bits.push("running now")
      else if (sources.indexOf("service") >= 0) bits.push("starts at boot")
    }
    return { path: String(i.path), name: row.name, text: bits.join(" \u00b7 "), managed: !!i.managed,
             offer: i.kind === "dgx-comfyui" && !i.managed && i.present !== false ? "adopt" : "" }
  })
}

// ---- a ComfyUI install's settings window -----------------------------------------------------------------------

// `comfyui status --json`: { install, status, too_old, running_elsewhere, job, update } or null. `status` is the install's own
// `dgx-comfyui.sh status --json` (null for one too old to speak it).
function parseComfyStatus(text) {
  const parsed = parseJson(text)
  return isPlainObject(parsed) && isPlainObject(parsed.install) ? parsed : null
}

// Where ComfyUI is reached from another machine, or "" when it listens on the machine only (127.0.0.1) or isn't known.
function comfyUrl(host, status) {
  if (!status || !(Number(status.port) > 0)) return ""
  const bind = String(status.bind || "")
  if (bind === "127.0.0.1" || bind === "localhost" || bind === "::1") return ""
  return "http://" + hostName(host) + ":" + Number(status.port) + "/"
}

// ComfyUI's page as a web app (Omarchy's chromeless browser window); xdg-open where the launcher or a Chromium browser is missing.
// The URL is an argument, never part of the script text.
function webappCommand(url) {
  return ["sh", "-c", 'if command -v omarchy-launch-webapp >/dev/null 2>&1; then omarchy-launch-webapp "$1" || xdg-open "$1"; else xdg-open "$1"; fi', "sh", String(url)]
}

// Why a running install can't be opened from the machine this panel is on, or "" when it can (`comfyui status` answered).
function comfyOpenProblem(answer) {
  if (!answer || !answer.status) return "ComfyUI didn't say where it listens"
  return comfyUrl("", answer.status) === "" ? "ComfyUI listens on the machine itself (" + String(answer.status.bind || "") + "), not on the network" : ""
}

// The pages of an install's window. `c`: { host, info (its comfyRow), answer (comfyStatus, or null while it is read), error, pending }.
function comfyPages(c) {
  const info = c.info
  const st = c.answer && c.answer.status ? c.answer.status : null
  const url = comfyUrl(c.host, st)
  const running = info.state === "running"
  const busy = String(c.pending || "") !== ""
  const general = []
  general.push({ key: "state", type: "info", label: "Status", hint: c.error ? c.error
    : !c.answer ? "Reading…"
    : running ? "Running" + (info.gib > 0 ? " · " + Math.round(info.gib) + " GiB" : "") + (st && Number(st.port) > 0 ? " · port " + Number(st.port) : "")
    : info.note !== "" ? info.note : "Stopped" })
  const openReason = !running ? "Start it first." : url === "" ? "It listens on the machine itself (" + String(st ? st.bind : "") + "); open it there, or set it to listen on the network." : ""
  general.push({ key: "open", type: "action", label: "Open ComfyUI", button: "Open", disabled: openReason !== "",
    hint: openReason !== "" ? openReason : url })
  general.push({ key: "service", type: "bool", label: "Keep running in the background", disabled: busy || info.state === "unfinished" || info.state === "missing" || info.state === "unsupported" || !!(c.answer && c.answer.too_old),
    hint: "Runs ComfyUI as a service that starts when the machine boots. Turning it on starts it now; turning it off stops it." })
  const facts = []
  facts.push({ key: "folder", type: "info", label: "Folder", hint: info.path })
  const up = comfyUpdatePlan(info, c.answer, c.pending)
  if (info.version) facts.push({ key: "tool", type: "info", label: "dgx-comfyui", hint: info.version + (c.answer && c.answer.update ? " \u00b7 " + c.answer.update.from + " \u2192 " + c.answer.update.to + " is available" : "") })
  // Update is something to do, so it is on Manage with Forget; About only says things.
  const manage = []
  if (up.target !== "" || up.hint !== "") manage.push({ key: "update", type: "action", label: "Update dgx-comfyui", button: "Update", disabled: up.action === "", hint: up.hint })
  if (st && st.comfy && st.comfy.version) facts.push({ key: "comfy", type: "info", label: "ComfyUI", hint: String(st.comfy.version) + (st.comfy.newer_release ? " \u00b7 " + st.comfy.newer_release + " is out" : "") })
  if (st && st.comfy && st.comfy.newer_release) {
    const upc = comfyUpdatePlan(info, c.answer, c.pending, true)
    manage.push({ key: "update-comfyui", type: "action", label: "Update ComfyUI", button: "Update", disabled: upc.action === "", hint: upc.action === "" ? upc.hint : st.comfy.newer_release + " is out. It updates ComfyUI and its nodes, and takes a few minutes." })
  }
  if (st && Number(st.models_bytes) > 0) facts.push({ key: "models", type: "info", label: "Models", hint: sizeText(Number(st.models_bytes)) + (Number(st.disk_free_bytes) > 0 ? " · " + sizeText(Number(st.disk_free_bytes)) + " free" : "") })
  manage.push({ key: "forget", type: "action", label: "Forget this install", button: "Forget\u2026", danger: true, disabled: busy,
    hint: "startdgx stops managing it. The folder, its models and workflows stay as they are, and Find existing ComfyUI\u2026 can adopt it again." })
  const pages = [{ title: "General", fields: general }]
  if (c.workflows) pages.push({ title: "Workflows", fields: comfyWorkflowFields(c) })
  if (c.health) pages.push({ title: "Health", fields: comfyHealthFields(c) })
  pages.push({ title: "About", fields: facts }, { title: "Manage", fields: manage })
  return pages
}

function comfyValues(answer) {
  const st = answer && answer.status ? answer.status : null
  return { service: !!(st && st.service && st.service.enabled === "enabled") }
}

// What Update does for an install, and why not: { action: "update" | "", target, hint }. `answer` is `comfyui status` (its `update`
// is { from, to } for a release older than the pin, `pinned` the release startdgx moves to, `too_old` for an install that can't
// speak JSON). Only a clean checkout moves (the CLI's rule): uncommitted changes or unpushed commits are somebody's work, so startdgx
// gives the git commands instead. One on a branch moves too: the branch stays, and the hint says how to go back. `comfy` is the ComfyUI update, which has the same conditions.
function comfyUpdatePlan(info, answer, pending, comfy) {
  const none = function (hint) { return { action: "", target: "", hint: hint } }
  if (!answer) return none("")
  const pinned = String(answer.pinned || "")
  const target = answer.update ? String(answer.update.to) : answer.too_old && pinned !== "" ? pinned : ""
  if (!comfy && target === "") return none(info.version ? "Up to date (" + info.version + ")" : "")
  const where = pinned !== "" ? pinned : target
  const git = "git -C " + info.path + " fetch --tags && git -C " + info.path + " checkout " + where
  if (info.state === "working" || String(pending || "") !== "") return { action: "", target: target, hint: "A job is running on it." }
  if (info.state === "unfinished" || info.state === "missing" || info.state === "unsupported") return none("")
  if (info.state === "running") return { action: "", target: target, hint: "Stop it first: an update changes what it runs." }
  const t = info.tool || {}
  const why = t.dirty ? "It has uncommitted changes." : t.unpushed > 0 ? "It has commits that aren't pushed." : ""
  if (why !== "") return { action: "", target: target, hint: why + " startdgx won't move it. To move it yourself: " + git }
  // A clean checkout on a branch moves too (the branch stays); the hint says how to go back.
  const back = t.branch ? " It is on the branch " + t.branch + ": it moves to " + where + " and stays there; git -C " + info.path + " checkout " + t.branch + " goes back." : ""
  return { action: comfy ? "update-comfyui" : "update", target: target, hint: comfy ? "" : (answer.update ? answer.update.from + " \u2192 " + answer.update.to + ". " : "") + "It updates dgx-comfyui and runs its install again, which takes a few minutes. Your models and workflows stay." + back }
}

// What a click in an install's window asks for: an action for the service, or null.
function comfyChange(host, info, answer, key, value) {
  switch (key) {
  case "open": {
    const url = comfyUrl(host, answer && answer.status ? answer.status : null)
    return url === "" ? null : { type: "comfyOpen", url: url }
  }
  case "service": return { type: "comfyToggle", host: host, path: info.path, kind: value ? "autostart-on" : "autostart-off" }
  case "forget": return { type: "comfyForget", host: host, path: info.path }
  case "doctor": return { type: "comfyDoctor", host: host, path: info.path }
  case "update": case "update-comfyui": {
    const plan = comfyUpdatePlan(info, answer, "", key === "update-comfyui")
    return plan.action === "" ? null : { type: "comfyToggle", host: host, path: info.path, kind: plan.action }
  }
  }
  if (key.indexOf("wf-") === 0) return comfyWorkflowChange(host, info, key)
  return null
}

// ---- installing ComfyUI -----------------------------------------------------------------------------------------

// `comfyui plan --json`: { places: [{ mount, fstype, free_bytes }], home, min_free_bytes, problems, path?, free_bytes? } or null.
function parseComfyPlan(text) {
  const parsed = parseJson(text)
  return isPlainObject(parsed) && Array.isArray(parsed.places) && Array.isArray(parsed.problems) ? parsed : null
}

// What is wrong with a folder, in words: one line, "" when nothing is.
function comfyProblemText(plan) {
  if (!plan || !Array.isArray(plan.problems) || plan.problems.length === 0) return ""
  const words = {
    exists_not_empty: "That folder isn't empty. Pick a new one, or an empty one.",
    inside_managed: "That is inside an install startdgx already manages.",
    not_writable: "startdgx can't write there.",
    too_small: "It needs " + sizeText(Number(plan.min_free_bytes) || 0) + " free; there is " + sizeText(Number(plan.free_bytes) || 0) + "."
  }
  return plan.problems.map(function (p) { return words[p] || String(p) }).join(" ")
}

// The disks to offer as a place for the folder: { text, folder } for each, the folder being where an install goes on it ("/" is the
// home folder's disk, so its install goes in the home folder).
var COMFY_FOLDER = "dgx-comfyui"
function comfyFolderChoices(plan) {
  if (!plan) return []
  const home = String(plan.home || "")
  return plan.places.map(function (p) {
    const mount = String(p.mount)
    const base = mount === "/" && home !== "" ? home : mount.replace(/\/+$/, "")
    return { text: mount + "  \u00b7  " + sizeText(Number(p.free_bytes) || 0) + " free", folder: base + "/" + COMFY_FOLDER }
  })
}

// Whether the folder typed can be installed into, from a plan for exactly that folder: ready, and why not.
function comfyInstallReady(plan, typed) {
  if (String(typed || "").trim() === "") return { ready: false, text: "" }
  if (!plan || plan.path === undefined) return { ready: false, text: "Checking\u2026" }
  const problem = comfyProblemText(plan)
  return problem !== "" ? { ready: false, text: problem } : { ready: true, text: "Free to use \u00b7 " + sizeText(Number(plan.free_bytes) || 0) + " free" }
}

// The installs of a machine whose job is worth asking about: one not installed yet, and any a job was started on this session.
function comfyWatchPaths(installs, started) {
  const out = []
  const seen = {}
  for (let i = 0; i < installs.length; i++) {
    const path = String(installs[i].path)
    if ((installs[i].installed === false || started.indexOf(path) >= 0) && !seen[path]) { seen[path] = true; out.push(path) }
  }
  return out
}

// `comfyui job --json`: { path, state, exit_status, log } or null.
function parseComfyJob(text) {
  const parsed = parseJson(text)
  return isPlainObject(parsed) && typeof parsed.state === "string" ? parsed : null
}

// ---- ComfyUI workflows (recipes) and the health report ---------------------------------------------------------

// `comfyui recipe list --json`: the workflows ({ name, valid, title, description, models, total_bytes, nodes }) or null.
function parseComfyRecipes(text) {
  const parsed = parseJson(text)
  if (!isPlainObject(parsed) || !Array.isArray(parsed.recipes)) return null
  for (let i = 0; i < parsed.recipes.length; i++) if (!isPlainObject(parsed.recipes[i]) || typeof parsed.recipes[i].name !== "string") return null
  return parsed.recipes
}

// `comfyui recipe check --json`: the check of one workflow (its models with their state, its nodes, what is left to download), or null.
function parseComfyRecipeCheck(text) {
  const parsed = parseJson(text)
  const r = isPlainObject(parsed) ? parsed.recipe : null
  return isPlainObject(r) && Array.isArray(r.models) ? r : null
}

// What a checked workflow needs, in words, and whether it can be installed: { text, action: "install" | "", problem }.
function comfyRecipePlan(doc) {
  const models = Array.isArray(doc.models) ? doc.models : []
  const nodes = Array.isArray(doc.nodes) ? doc.nodes : []
  const gated = models.filter(function (m) { return m.state === "missing" && m.source && !m.source.ok && m.source.problem === "gated" })
  if (gated.length > 0) {
    const need = gated[0].source.detail && gated[0].source.detail[0] ? String(gated[0].source.detail[0]) : "a token"
    return { text: gated[0].file + " is gated: it needs " + need + ". startdgx never stores a token: put " + need + "=\u2026 in ~/.config/startdgx/comfyui.env on the machine (chmod 600) and check again.", action: "", problem: true }
  }
  const gone = models.filter(function (m) { return m.state === "missing" && m.source && !m.source.ok })
  if (gone.length > 0) return { text: gone[0].file + " can't be fetched (" + String(gone[0].source.problem || "gone") + "): the workflow is out of date.", action: "", problem: true }
  const bad = models.filter(function (m) { return m.state === "size" || m.state === "hash" }).map(function (m) { return m.file })
  if (bad.length > 0) return { text: bad.join(", ") + " on disk doesn't match the workflow; startdgx leaves it alone.", action: "", problem: true }
  const missing = models.filter(function (m) { return m.state === "missing" }).length
  const nodesMissing = nodes.filter(function (n) { return n.installed === false }).length
  if (missing === 0 && nodesMissing === 0) return { text: "Installed: all " + models.length + " models and " + nodes.length + " nodes are there.", action: "", problem: false }
  const parts = []
  if (missing > 0) parts.push(missing + " of " + models.length + " models to download (" + sizeText(Number(doc.download_bytes) || 0) + ")")
  if (nodesMissing > 0) parts.push(nodesMissing + (nodesMissing === 1 ? " node" : " nodes") + " to install")
  return { text: "Needs " + parts.join(" and ") + ".", action: "install", problem: false }
}

// One workflow's line before it is checked: "3 models \u00b7 18.2 GiB \u00b7 2 nodes".
function comfyRecipeSummary(r) {
  const parts = [r.models + (r.models === 1 ? " model" : " models"), sizeText(Number(r.total_bytes) || 0)]
  if (Number(r.nodes) > 0) parts.push(r.nodes + (r.nodes === 1 ? " node" : " nodes"))
  return parts.join(" \u00b7 ")
}

// The Workflows page's fields: one action per workflow. `c.workflows`: { list, error, loading, checks: { name: check }, checking: name, installable, reason }.
function comfyWorkflowFields(c) {
  const w = c.workflows
  if (w.installable === false) return [{ key: "wf-no", type: "info", label: "Workflows", hint: w.reason || "Not available for this install." }]
  if (w.error) return [{ key: "wf-error", type: "info", label: "Workflows", hint: w.error }]
  if (w.loading || !w.list) return [{ key: "wf-wait", type: "info", label: "Workflows", hint: "Reading\u2026" }]
  if (w.list.length === 0) return [{ key: "wf-none", type: "info", label: "Workflows", hint: "This install has no workflow recipes." }]
  const busy = String(c.pending || "") !== "" || c.info.state === "working"
  return w.list.map(function (r) {
    const check = w.checks ? w.checks[r.name] : null
    const title = String(r.title || r.name)
    if (r.valid === false) return { key: "wf-check:" + r.name, type: "info", label: title, hint: "This recipe isn't valid." }
    if (!check) return { key: "wf-check:" + r.name, type: "action", label: title, button: w.checking === r.name ? "Checking\u2026" : "Check", disabled: w.checking !== "" || busy,
      hint: comfyRecipeSummary(r) + (r.description ? " \u00b7 " + r.description : "") }
    const plan = comfyRecipePlan(check)
    if (plan.action === "install") return { key: "wf-install:" + r.name, type: "action", label: title, button: "Install", disabled: busy, hint: plan.text }
    return { key: "wf-check:" + r.name, type: "info", label: title, hint: plan.text }
  })
}

// What a click on a Workflows field asks for: a check of one, or its install.
function comfyWorkflowChange(host, info, key) {
  const at = key.indexOf(":")
  const kind = key.substring(0, at)
  const name = key.substring(at + 1)
  if (kind === "wf-check") return { type: "comfyRecipeCheck", host: host, path: info.path, name: name }
  if (kind === "wf-install") return { type: "comfyRecipeInstall", host: host, path: info.path, name: name }
  return null
}

// `comfyui doctor --json`: the report ({ healthy, problems, changes, items }) or null.
function parseComfyDoctor(text) {
  const parsed = parseJson(text)
  const d = isPlainObject(parsed) ? parsed.doctor : null
  return isPlainObject(d) && Array.isArray(d.items) ? d : null
}

// The Health page's fields: run the checks, then what they said. `c.health`: { available, reason, running, error, doc }.
function comfyHealthFields(c) {
  const h = c.health
  const fields = [{ key: "doctor", type: "action", label: "Check this install", button: h.running ? "Checking\u2026" : "Run checks", disabled: h.running || !h.available,
    hint: h.available ? "dgx-comfyui's own checks of every part: the host, the stack, the models. They change nothing." : h.reason }]
  if (h.error) fields.push({ key: "doctor-error", type: "info", label: "Not read", hint: h.error })
  if (h.doc) {
    fields.push({ key: "doctor-summary", type: "info", label: h.doc.healthy ? "Healthy" : String(h.doc.problems) + (h.doc.problems === 1 ? " problem" : " problems"), hint: "" })
    const words = { ok: "OK", warn: "Warning", bad: "Problem", info: "Note", did: "Changed" }
    h.doc.items.forEach(function (item, i) {
      if (item.level === "log") fields.push({ key: "doctor-" + i, type: "info", label: String(item.text), hint: "" })
      else fields.push({ key: "doctor-" + i, type: "info", label: words[item.level] || String(item.level), hint: String(item.text) })
    })
  }
  return fields
}

// The look through the machine that found these installs was cut short (`partial`).
function comfyListPartial(text) {
  const parsed = parseJson(text)
  return isPlainObject(parsed) && parsed.partial === true
}

// What a started ComfyUI action runs as a job, for the row's wording: install, update or recipe (a workflow), "" for the rest.
function comfyJobKind(kind) {
  return kind === "install" ? "install" : kind === "update" || kind === "update-comfyui" ? "update" : kind === "recipe-install" ? "recipe" : ""
}
