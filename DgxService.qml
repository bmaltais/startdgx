// Everything the manager knows about the machines, and the only thing that runs bin/startdgx. Each added
// machine has its own HostPoller (status poll, and its four command slots: a start, a share, a move or store change, and a stop, use or delete); the machine list,
// adding, forgetting, discovery, a machine's catalog for the model picker, the Add recipe card's check, add and remove, the uninstall and remove plans and the
// terminal launches run here. Results come back through `notice` and
// `error`, and new failures as desktop notifications.
pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import QtQml.Models
import Quickshell
import Quickshell.Io
import "DgxModel.js" as Model

Item {
  id: service

  required property string script
  property bool windowOpen: false

  property bool loaded: false        // the machine list has been read once
  property var hosts: ({})           // `startdgx hosts --json`: target -> { profile }
  readonly property var hostList: Object.keys(service.hosts).sort()
  // target -> { loaded, online, error, status, lastSeenMs }; see DgxModel.
  property var hostState: ({})
  // `startdgx storage` per machine, as last read ("target" -> DgxModel.parseStorage), and why a read failed. A machine whose
  // read fails keeps its last good one.
  property var storage: ({})
  property var storageErrors: ({})
  // `startdgx comfyui list` per machine, as last read ("target" -> the managed installs, DgxModel.parseComfyList). A read that
  // fails keeps the last good one; what is running comes with the status poll, not from here.
  property var comfyui: ({})
  // The Find existing ComfyUI card (`comfyui discover --json`): the machine asked, what it found (null until it answers) and why a
  // look failed.
  property string comfyFindHost: ""
  property var comfyFound: null
  property string comfyFindError: ""
  property bool comfyFoundPartial: false   // the look through the machine was cut short (it takes too long on a slow or synced tree)
  readonly property bool comfyFinding: comfyFindQuery.busy
  // "target/model" -> its click's mark (DgxModel.pendingOf): a start, stop or delete running there or waiting its
  // turn, or done and not answered yet. Each machine's poller publishes its own (`marks`: target -> its map).
  property var marks: ({})
  property var pending: ({})
  // "target/model" -> its recipe (from `list`): a model asked to be set up that its machine doesn't list yet.
  property var setups: ({})
  // Where each machine's models should end up, { host: { recipe id: "usb" } } (`destination`, kept on this computer), and the setups asked for
  // with the model store as destination that haven't finished: when one does, the model is stopped and moved there (Model.moveAfterStep).
  property var destinations: ({})
  property var moveAfter: ({})
  // Setups from the panel whose model is shared on the tailnet when they finish (Model.shareAfterStep).
  property var shareAfter: ({})
  // The host states as drawn: each machine's status with those setups in it, so a model asked for shows at once.
  readonly property var shownState: Model.withSetups(service.hostState, service.setups)

  property string error: ""
  property string notice: ""

  // Adds wait their turn here ({ args }); forgets in their own line (`forgets`, targets), so forgetting a machine
  // never waits behind an add that is timing out on another (the CLI locks hosts.json for each change).
  property var queue: []
  property var forgets: []
  readonly property bool busy: hostsActionProc.running || service.queue.length > 0

  // Discovery, for the Add machine card.
  property var peers: []
  property string peersError: ""
  readonly property bool discovering: discoverQuery.busy

  // The uninstall plan (`uninstall HOST --dry-run --json` with the card's opt-ins), for the uninstall card:
  // planKey is the host and the flags it was asked with.
  property string planHost: ""
  property string planKey: ""
  property var uninstallPlan: null
  property string planError: ""
  readonly property bool planning: planQuery.busy

  // target -> true: a setup there failed because the machine needs its one-time root setup (Model.setupNeeded), so
  // its section offers Install…, until that is launched.
  property var setupNeeded: ({})

  // Failures already told to the desktop; see Model.alerts.
  property var announced: ({})

  // The model picker's catalog (`list HOST`), for one machine at a time.
  property string listHost: ""
  property var recipes: null
  property string recipesError: ""
  readonly property bool listing: listQuery.busy

  // Draft recipe on a search result: the repo being put on recipeHost, the step ("drafting" while the CLI writes the file; the
  // check and the add are then recipeStep), what went wrong before there was a file, and the draft's warnings. The result of
  // the check or add is recipeResult, for the id drafted.
  property string draftRepo: ""
  property string draftStep: ""
  property string draftId: ""
  // The drafted recipe's name and the context its variant is for, which Measure… on the Find card needs.
  property string draftName: ""
  // "estimated" when the add gave the recipe the list's estimate: the add then confirms it, so no measuring run comes first.
  property string draftSource: ""
  property int draftCtx: 0
  property string draftError: ""
  property var draftWarnings: []

  // The plugin's own update (`startdgx self-update`, on this computer): what the last look said (Model.parseSelfUpdate), why it failed, and a look or
  // an update running. An update asks the CLI to restart the shell after it, so a successful one ends this window with it.
  property var selfInfo: null
  property string selfError: ""
  property double selfCheckedMs: 0
  property bool selfUpdating: false
  readonly property bool selfChecking: selfQuery.busy
  readonly property bool selfWaiting: Model.selfUpdateWaiting(service.selfInfo)
  // A look, unless one is running, an update runs, or `soon` (the header's: when the manager opens) and one was made in the last ten minutes.
  function checkSelf(soon) {
    if (service.selfUpdating || selfQuery.busy) return
    if (soon && Date.now() - service.selfCheckedMs < 600000) return
    service.selfError = ""
    selfQuery.ask("self", [service.script, "self-update", "--check", "--json"])
  }
  function updateSelf() {
    if (service.selfUpdating || selfQuery.busy) return
    service.selfError = ""
    service.selfUpdating = true
    selfProc.command = [service.script, "self-update", "--restart", "--json"]
    selfProc.running = true
  }

  // TensorFold's list in the model picker (`tensorfold list --json`, also from this computer): Model.parseTfList's answer, why it failed.
  property var tfList: null
  property string tfError: ""
  property int tfCount: 0
  readonly property bool tfLoading: tfQuery.busy

  // A model's context sizes, for its settings window and the Add recipe card's variants (`variants HOST MODEL --json`): the contexts the recipe has measured, null until read.
  property string variantsHost: ""
  property string variantsId: ""
  property var variants: null
  property string variantsError: ""
  readonly property bool variantsLoading: variantsQuery.busy

  // The Add recipe card: the answer to the last check or add ({ ok, id, errors, message, added }), a failure to ask at all,
  // and what the card is doing (recipeStep: "checking" | "adding" | ""). The machine's own recipes are listed from it.
  property string recipeHost: ""
  property var recipeResult: null
  property string recipeError: ""
  property string recipeStep: ""
  property bool recipeThenAdd: false
  property int recipeSeq: 0
  property var userRecipes: null
  property string userRecipesError: ""
  property string recipeRemoving: ""
  property string recipeRemoveError: ""
  // A write (an add or a removal) is running: the card waits, and nothing kills it.
  readonly property bool recipeWriting: recipeAddProc.running || recipeRemoveProc.running
  readonly property bool recipeBusy: service.draftStep !== "" || service.recipeStep !== "" || service.recipeWriting || service.recipeMeasuring !== "" || service.recipeConfirming !== "" || recipeContextProc.running
  // "host/id" of a measure running (minutes, on the machine; nothing ends it) and the id whose numbers are being confirmed.
  property string recipeMeasuring: ""
  property string recipeConfirming: ""

  // The confirmation card's dry run (`recipe measure HOST ID --ctx N`, which changes nothing): what a measure or a setup
  // of a recipe of yours would download and load, as the engine says it.
  property string runHost: ""
  property string runId: ""
  property int runCtx: 0
  property var runPlan: null
  property string runError: ""
  readonly property bool runPlanning: runQuery.busy

  // The remove card's plan (`delete HOST MODEL --dry-run --json`): what the removal frees, -1 until it is read.
  property string removeHost: ""
  property string removeId: ""
  property real removeBytes: -1
  property string removeError: ""
  readonly property bool removePlanning: removeQuery.busy

  readonly property var summary: Model.summarize(service.hostList, service.shownState, service.pending)
  readonly property var rows: Model.rows(service.hostList, service.shownState, service.comfyui)

  function entry(host, id) {
    const hs = service.shownState[host]
    return hs && hs.status && hs.status.models ? hs.status.models[id] || null : null
  }

  // ---- reads ----------------------------------------------------------------------------------------
  function refreshHosts() { if (!hostsProc.running) hostsProc.running = true }
  function refreshAll() {
    service.refreshHosts()
    for (let i = 0; i < pollers.count; i++) {
      const p = pollers.objectAt(i) as HostPoller
      if (p) p.poll()
    }
  }

  function statusRead(host, status) {
    service.setHostState(host, { loaded: true, online: true, error: "", status: status, lastSeenMs: Date.now() })
    service.setups = Model.settleSetups(service.setups, host, status)
    service.settleMoves(host, status)
    service.settleShares(host, status)
    service.notifyChanges()
  }
  function settleMoves(host, status) {
    const step = Model.moveAfterStep(service.moveAfter, host, status)
    service.moveAfter = step.waiting
    for (const a of step.actions) {
      if (a.type === "stop") service.stop(a.host, a.id)
      else service.move(a.host, a.id, a.to)
    }
  }
  function settleShares(host, status) {
    const step = Model.shareAfterStep(service.shareAfter, host, status)
    service.shareAfter = step.waiting
    for (const a of step.actions) service.share(a.host, a.id, "share")
  }
  function destinationOf(host, id) { return (service.destinations[host] || {})[id] === "usb" ? "usb" : "nvme" }
  function loadDestinations(host) { destQuery.ask(host, [service.script, "destination", host, "--json"]) }
  function setDestination(host, id, to) {
    const all = Object.assign({}, service.destinations)
    const mine = Object.assign({}, all[host] || {})
    if (to === "usb") mine[id] = "usb"; else delete mine[id]
    all[host] = mine
    service.destinations = all
    destSetProc.command = [service.script, "destination", host, id, "--to", to, "--json"]
    destSetProc.running = true
  }
  function storageRead(host, storage, error) {
    const errors = Object.assign({}, service.storageErrors)
    if (storage) {
      const next = Object.assign({}, service.storage)
      next[host] = storage
      service.storage = next
      delete errors[host]
    } else errors[host] = error
    service.storageErrors = errors
  }
  // Start or stop an install, or adopt one the Find card found (the label is optional).
  function comfyAct(host, kind, path, label, stopService) {
    const p = service.poller(host)
    if (!p) return
    // Run a failed install again: where it stopped, with the label it had.
    if (kind === "retry") {
      const found = (service.comfyui[host] || []).filter(function (i) { return i.path === path })[0]
      p.runComfy("install", path, found ? String(found.label || "") : "")
    } else p.runComfy(kind, path, label, stopService)
  }
  // The job asked about for an install (`comfyui job`), by Model.comfyKey: { state, exit_status, log }.
  property var comfyJob: ({})
  function comfyJobRead(host, path, job) {
    const next = Object.assign({}, service.comfyJob)
    next[Model.comfyKey(host, path)] = job
    service.comfyJob = next
  }
  // An install's workflows (`comfyui recipe list`), what each check said, and its health report (`comfyui doctor`), for the install in
  // comfyStatusKey's window (read when it opens, and on a click).
  property string comfyRecipesKey: ""
  property var comfyRecipes: null
  property string comfyRecipesError: ""
  readonly property bool comfyRecipesLoading: comfyRecipesQuery.busy
  property var comfyChecks: ({})
  property string comfyChecking: ""
  property string comfyCheckError: ""
  property string comfyDoctorKey: ""
  property var comfyDoctor: null
  property string comfyDoctorError: ""
  readonly property bool comfyDoctoring: comfyDoctorQuery.busy
  function comfyRecipesFor(host, path) {
    const key = host + "\n" + path
    if (service.comfyRecipesKey !== key) { service.comfyRecipes = null; service.comfyChecks = ({}); service.comfyChecking = "" }
    service.comfyRecipesKey = key
    service.comfyRecipesError = ""
    comfyRecipesQuery.ask(key, [service.script, "comfyui", "recipe", "list", host, "--dir", path, "--json", "--timeout", "120"])
  }
  function comfyRecipeCheck(host, path, name) {
    service.comfyChecking = name
    service.comfyCheckError = ""
    comfyCheckQuery.ask(host + "\n" + path + "\n" + name, [service.script, "comfyui", "recipe", "check", host, name, "--dir", path, "--json", "--timeout", "300"])
  }
  function comfyDoctorFor(host, path) {
    const key = host + "\n" + path
    if (service.comfyDoctorKey !== key) service.comfyDoctor = null
    service.comfyDoctorKey = key
    service.comfyDoctorError = ""
    comfyDoctorQuery.ask(key, [service.script, "comfyui", "doctor", host, "--dir", path, "--json", "--timeout", "300"])
  }
  function cancelComfyWindow() {
    comfyStatusQuery.cancel()
    comfyRecipesQuery.cancel()
    comfyCheckQuery.cancel()
    comfyDoctorQuery.cancel()
    service.comfyChecking = ""
  }

  // The Install ComfyUI card: `comfyui plan --json` for the folder typed ("" for just the disks), the answer for comfyPlanKey.
  property string comfyPlanKey: ""
  property var comfyPlan: null
  property string comfyPlanError: ""
  function comfyPlanFor(host, path) {
    const key = host + "\n" + path
    if (service.comfyPlanKey !== key) service.comfyPlanKey = key
    service.comfyPlanError = ""
    comfyPlanQuery.ask(key, [service.script, "comfyui", "plan", host, "--json", "--timeout", "60"].concat(path !== "" ? ["--dir", path] : []))
  }
  function cancelComfyPlan() { comfyPlanQuery.cancel() }
  // The Start or Stop an install's button and key offer (DgxModel.comfyToggle), for the cursor's keys.
  function comfyToggle(host, path) {
    const installs = service.comfyui[host] || []
    const status = service.shownState[host] ? service.shownState[host].status : null
    const rows = installs.map(function (i) { return Model.comfyRow(i, status) })
    const info = rows.filter(function (r) { return r.path === path })[0]
    return Model.comfyToggle(info, service.pending[Model.comfyKey(host, path)] || "", rows)
  }
  function findComfy(host) {
    if (service.comfyFindHost !== host) service.comfyFound = null
    service.comfyFindHost = host
    service.comfyFindError = ""
    comfyFindQuery.ask(host, [service.script, "comfyui", "discover", host, "--json", "--timeout", "90"])
  }
  function cancelComfyFind() { comfyFindQuery.cancel() }
  // An action on an install ended (done or not): the Find card, if it is open on this machine, shows what changed, and so does the
  // install's window.
  function comfyActed(host, kind, path) {
    if (service.comfyFindHost === host && service.comfyFound !== null) service.findComfy(host)
    if (service.comfyStatusKey === host + "\n" + path) service.comfyStatusFor(host, path)
    // A workflow's job ended (or any): what the checks said is out of date.
    if (kind === "job" || kind === "recipe-install") service.comfyChecks = ({})
  }
  // An install's window: `comfyui status --json` for it (the answer is for comfyStatusKey, until another is asked).
  property string comfyStatusKey: ""
  property var comfyStatus: null
  property string comfyStatusError: ""
  function comfyStatusFor(host, path) {
    const key = host + "\n" + path
    if (service.comfyStatusKey !== key) { service.comfyStatus = null; service.comfyStatusKey = key }
    service.comfyStatusError = ""
    comfyStatusQuery.ask(key, [service.script, "comfyui", "status", host, "--dir", path, "--json", "--timeout", "90"])
  }
  // The row's Open button: ask the install where it listens, then open it as a web app.
  function comfyOpenFor(host, path) {
    service.error = ""
    service.notice = "Opening ComfyUI\u2026"
    comfyOpenQuery.ask(host + "\n" + path, [service.script, "comfyui", "status", host, "--dir", path, "--json", "--timeout", "30"])
  }
  function cancelComfyStatus() { comfyStatusQuery.cancel() }
  function comfyRead(host, installs) {
    if (!installs) return
    const next = Object.assign({}, service.comfyui)
    next[host] = installs
    service.comfyui = next
    // An install the list shows that is not installed yet has a job to read.
    const p = service.poller(host)
    if (p) Qt.callLater(p.pollComfyJobs)
  }
  function statusFailed(host, why) {
    const old = service.hostState[host] || {}
    service.setHostState(host, { loaded: true, online: false, error: why, status: old.status || null, lastSeenMs: old.lastSeenMs || 0 })
  }
  function setHostState(host, value) {
    const next = Object.assign({}, service.hostState)
    next[host] = value
    service.hostState = next
  }

  function setMarks(host, value) {
    if (JSON.stringify(service.marks[host] || {}) === JSON.stringify(value)) return
    const next = Object.assign({}, service.marks)
    if (Object.keys(value).length) next[host] = value
    else delete next[host]
    service.marks = next
    const flat = ({})
    for (const h in next) Object.assign(flat, next[h])
    service.pending = flat
  }

  // Tell the desktop about new failures, each once; not while the manager shows them.
  function notifyChanges() {
    const r = Model.alerts(service.hostList, service.hostState, service.announced)
    service.announced = r.announced
    if (service.windowOpen) return
    for (let i = 0; i < r.list.length; i++) {
      Quickshell.execDetached(Model.notifyCommand(r.list[i]))
    }
  }

  // ---- a machine's models ----------------------------------------------------------------------------
  function poller(host) {
    for (let i = 0; i < pollers.count; i++) {
      const p = pollers.objectAt(i) as HostPoller
      if (p && p.host === host) return p
    }
    return null
  }

  // Each goes to the machine's poller, which runs it on one of its three slots (DgxModel.submit): a start beside
  // anything else, so a Stop never waits for a load. Its row shows the click once the command runs, and says it is
  // queued until then; the machine's next answer after the command replaces it.
  function start(host, id) { service.act(host, "start", id) }
  function stop(host, id) { service.act(host, "stop", id) }
  // Shares a model with the host's tailnet, or stops ("share" or "unshare"): a command of its own, with its own mark
  // (DgxModel.shareKey), so the row keeps showing what the model does.
  function share(host, id, kind) { service.act(host, kind, id) }
  // A removal (or a setup's cancel) returns once the model is gone, after its stop and the deletion of its weights.
  function remove(host, id) { service.act(host, "delete", id) }
  // Copies a stopped model's files to the machine's model store ("usb") or back to its internal disk ("nvme"), which takes minutes.
  function move(host, id, to) {
    const p = service.poller(host)
    if (p) p.run("move", id, service.entry(host, id), { to: to, shows: "move-" + to })
  }
  // The machine's model store: a folder on an external disk, or none. Marked "storage" under "host/" while it runs.
  function setStore(host, path) {
    const p = service.poller(host)
    if (p) p.run("storageSet", "", null, { path: path, shows: "storage" })
  }
  function unsetStore(host) {
    const p = service.poller(host)
    if (p) p.run("storageUnset", "", null, { shows: "storage" })
  }
  function act(host, kind, id) {
    const p = service.poller(host)
    if (p) p.run(kind, id, service.entry(host, id))
  }
  // A setup runs on the machine in a unit of its own (`use --detach`), so the command returns at once and the
  // status poll follows the download. The model shows, waiting, from the click until the machine lists it.
  // `yes`: the person has read what a recipe of theirs downloads (the confirmation card), which the engine wants.
  function use(host, r, yes) {
    const p = service.poller(host)
    if (!p || !r) return
    const next = Object.assign({}, service.setups)
    next[Model.modelKey(host, r.id)] = r
    service.setups = next
    // The store as destination: this setup's model is moved there when it is done.
    if (service.destinationOf(host, r.id) === "usb") {
      const waiting = Object.assign({}, service.moveAfter)
      waiting[Model.modelKey(host, r.id)] = { seen: 0, stopping: false }
      service.moveAfter = waiting
    }
    // Sharing is the default: the model is shared on the tailnet once its setup is done.
    const sharing = Object.assign({}, service.shareAfter)
    sharing[Model.modelKey(host, r.id)] = true
    service.shareAfter = sharing
    p.run("use", r.id, null, yes ? { yes: true } : undefined)
  }
  // The action failed: a setup asked for that never began goes from the list again (a start, stop or delete is
  // settled by the next status read, as on success); one that failed for want of the machine's root setup makes
  // its section offer Install….
  function actionFailed(key, kind, error) {
    if (kind !== "use") return
    const host = Model.keyHost(key)
    if (Model.setupNeeded(error)) service.markSetupNeeded(host, true)
    if (service.shareAfter[key]) {
      const sharing = Object.assign({}, service.shareAfter)
      delete sharing[key]
      service.shareAfter = sharing
    }
    if (!service.setups[key]) return
    const next = Object.assign({}, service.setups)
    delete next[key]
    service.setups = next
  }

  function markSetupNeeded(host, needed) {
    const next = Object.assign({}, service.setupNeeded)
    if (needed) next[host] = true
    else delete next[host]
    service.setupNeeded = next
  }

  // The cards' questions each go through a Query: a new one ends the one running, whose late answer is dropped.
  function listRecipes(host) {
    if (service.listHost !== host) { service.recipes = null; service.listHost = host }
    service.recipesError = ""
    listQuery.ask(host, [service.script, "list", host, "--timeout", "60"])
  }

  function planContext(host, id) {
    const key = Model.modelKey(host, id)
    if (variantsQuery.busy && variantsQuery.asked.wanted === key) return
    service.variantsHost = host
    service.variantsId = id
    service.variants = null
    service.variantsError = ""
    variantsQuery.ask(key, [service.script, "variants", host, id, "--json", "--timeout", "60"])
  }

  // Restarts a model set up with one of its measured contexts (the engine's use --ctx).
  function setContext(host, id, ctx) {
    const p = service.poller(host)
    if (p) p.run("context", id, service.entry(host, id), { ctx: ctx })
  }

  // Validates a recipe file on this computer on the machine (`recipe validate`, which changes nothing) and, when asked and
  // it passes, adds it (`recipe add`). The path is only handed to bin/startdgx, which reads the file.
  function checkRecipe(host, path, thenAdd) {
    if (service.recipeWriting || Model.recipePathProblem(path) !== "") return
    service.recipeHost = host
    service.recipeResult = null
    service.recipeError = ""
    service.recipeThenAdd = thenAdd
    service.recipeStep = "checking"
    service.recipeSeq += 1
    service.recipePathAsked = path.trim()
    recipeQuery.ask(host + "\n" + service.recipeSeq, [service.script].concat(Model.recipeSendCommand("validate", host, service.recipePathAsked)))
  }
  property string recipePathAsked: ""

  function finishRecipe(code, out, err, verb) {
    const r = code === 0 ? Model.parseRecipeResult(out) : null
    if (!r) {
      service.recipeError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
      service.recipeStep = ""
      return
    }
    service.recipeStep = ""
    service.recipeResult = Object.assign({}, r, { added: verb === "add" && r.ok })
    if (verb === "add" && r.ok) {
      service.notice = r.message
      // The picker's catalog and the card's list now have a recipe more.
      if (service.listHost === service.recipeHost) service.recipes = null
      service.loadUserRecipes(service.recipeHost)
      // The add is the person's say-so for an estimate from TensorFold's list: confirm it, so the machine counts the model as fitting.
      if (service.draftSource === "estimated" && r.id === service.draftId) Qt.callLater(function () { service.confirmRecipe(service.recipeHost, r.id) })
      // TensorFold's list says what each machine was given: read it again, for the rows and for the recipe's window.
      service.loadTf(false, service.recipeHost)
    }
  }

  function loadUserRecipes(host) {
    if (service.recipeHost !== host) { service.userRecipes = null; service.recipeHost = host }
    service.userRecipesError = ""
    userRecipesQuery.ask(host, [service.script, "recipe", "list", host, "--json", "--timeout", "60"])
  }

  function planRecipeRun(host, id, ctx) {
    const key = [host, id, ctx].join(" ")
    if (runQuery.busy && runQuery.asked.wanted === key) return
    service.runHost = host
    service.runId = id
    service.runCtx = ctx
    service.runPlan = null
    service.runError = ""
    runQuery.ask(key, [service.script, "recipe", "measure", host, id, "--ctx", String(ctx), "--timeout", "60"])
  }

  // Measures a recipe of yours (`recipe measure --yes`): the machine downloads it, loads it and benches it, which takes
  // minutes. A write: closing the card doesn't end it, and the answer comes as a message.
  function measureRecipe(host, id, ctx) {
    if (service.recipeBusy) return
    service.recipeMeasuring = Model.modelKey(host, id)
    service.error = ""
    service.notice = "Measuring " + id + " on " + Model.hostName(host) + "; the machine is busy for a few minutes"
    recipeMeasureProc.host = host
    recipeMeasureProc.command = [service.script, "recipe", "measure", host, id, "--ctx", String(ctx), "--yes"]
    recipeMeasureProc.running = true
  }

  // Adds a context size to a recipe of yours (`recipe context`): a drafted variant, which Measure… then fills in; or takes one away.
  function addContext(host, id, ctx, remove) {
    if (service.recipeBusy) return
    service.error = ""
    recipeContextProc.host = host
    recipeContextProc.command = [service.script, "recipe", "context", host, id, "--ctx", String(ctx), "--timeout", "60"].concat(remove ? ["--remove"] : [])
    recipeContextProc.running = true
  }

  // Accepts an estimated recipe's numbers (`recipe confirm`): it then counts as fitting.
  function confirmRecipe(host, id) {
    if (service.recipeBusy) return
    service.recipeConfirming = id
    service.recipeRemoveError = ""
    recipeConfirmProc.host = host
    recipeConfirmProc.command = [service.script, "recipe", "confirm", host, id, "--timeout", "60"]
    recipeConfirmProc.running = true
  }

  // Drafts an entry of TensorFold's list for `host` and adds it through the Add recipe path (check, then add): one action. A write: closing
  // the card doesn't end it. Its CLI step names the entry, the rest is the Add recipe path.
  function draftTensorfold(host, row, picked, replace) { service.draftWith(host, row.repo || row.id, Model.tfDraftCommand(host, row.id, picked, row.settings, replace)) }
  function draftWith(host, label, command) {
    if (service.recipeBusy) return
    service.draftRepo = label
    service.draftId = ""
    service.draftSource = ""
    service.draftError = ""
    service.draftWarnings = []
    service.recipeHost = host
    service.recipeResult = null
    service.recipeError = ""
    service.draftStep = "drafting"
    draftProc.command = [service.script].concat(command)
    draftProc.running = true
  }

  function cancelPicker() { tfQuery.cancel() }
  // Reads TensorFold's list; `update` also saves this look, so the next visit says what is new or changed since (the marks in this answer
  // are against the look saved before).
  function loadTf(update, host) {
    service.tfError = ""
    service.tfCount += 1
    tfQuery.ask("tf" + service.tfCount, [service.script].concat(Model.tfListCommand(update, host)))
  }

  function removeRecipe(host, id) {
    if (service.recipeBusy) return
    service.recipeRemoving = id
    service.recipeRemoveError = ""
    recipeRemoveProc.host = host
    recipeRemoveProc.command = [service.script, "recipe", "remove", host, id, "--timeout", "60"]
    recipeRemoveProc.running = true
  }

  function planRemove(host, id) {
    const key = Model.modelKey(host, id)
    // Already asking about this one: its answer is the one wanted.
    if (removeQuery.busy && removeQuery.asked.wanted === key) return
    service.removeHost = host
    service.removeId = id
    service.removeBytes = -1
    service.removeError = ""
    removeQuery.ask(key, [service.script, "delete", host, id, "--dry-run", "--json", "--timeout", "60"])
  }

  // ---- the machine list ------------------------------------------------------------------------------
  function run(args) {
    service.queue = service.queue.concat([{ args: args }])
    service.runNext()
  }
  function runNext() {
    if (hostsActionProc.running || service.queue.length === 0) return
    const next = service.queue[0]
    service.queue = service.queue.slice(1)
    service.error = ""
    service.notice = ""
    hostsActionProc.command = [service.script].concat(next.args)
    hostsActionProc.running = true
  }
  function addHost(target) { service.run(["add", target]) }
  function forget(host) {
    service.forgets = service.forgets.concat([host])
    service.nextForget()
  }
  function nextForget() {
    if (forgetProc.running || service.forgets.length === 0) return
    const host = service.forgets[0]
    service.forgets = service.forgets.slice(1)
    service.error = ""
    service.notice = ""
    forgetProc.command = [service.script, "forget", host]
    forgetProc.running = true
  }

  // `user`: the ssh user on the machines, or "" for this machine's.
  function discover(user) {
    service.peersError = ""
    discoverQuery.ask("discover " + user, [service.script, "discover", "--json"].concat(user ? ["--user", user] : []))
  }
  // The Add machine card closed: its probes end.
  function cancelDiscover() { discoverQuery.cancel() }

  // flags: the opt-ins the plan is asked with (--delete-models, --remove-packages).
  function plan(host, flags) {
    service.planHost = host
    service.planKey = [host].concat(flags).join(" ")
    service.uninstallPlan = null
    service.planError = ""
    planQuery.ask(service.planKey, [service.script, "uninstall", host, "--dry-run", "--json", "--timeout", "60"].concat(flags))
  }

  // Install, uninstall and logs need a person at a terminal (sudo asks for a password there), so they open
  // Omarchy's floating terminal, detached: the launcher runs the terminal in the foreground for as long as it is
  // open, and a Process here would hold it (and kill it on a shell restart). Nothing comes back; in demo mode the
  // launch only prints what it would run, which goes nowhere.
  function launch(verb, host, id, flags) {
    if (verb === "install") service.markSetupNeeded(host, false)
    Quickshell.execDetached([service.script, "launch", verb, host].concat(id ? [id] : [], flags || []))
  }

  // Keeps one poller per added machine; a ListModel, so a machine added or forgotten leaves the others' work alone.
  function syncPollers() {
    const want = service.hostList
    for (let i = hostModel.count - 1; i >= 0; i--) {
      if (want.indexOf(hostModel.get(i).host) < 0) hostModel.remove(i)
    }
    for (let j = 0; j < want.length; j++) {
      let found = false
      for (let k = 0; k < hostModel.count; k++) if (hostModel.get(k).host === want[j]) found = true
      if (!found) hostModel.append({ host: want[j] })
    }
    const next = ({})
    for (let n = 0; n < want.length; n++) if (service.hostState[want[n]]) next[want[n]] = service.hostState[want[n]]
    service.hostState = next
    for (const h in service.marks) if (want.indexOf(h) < 0) service.setMarks(h, {})
    const setups = ({})
    for (const key in service.setups) if (want.indexOf(Model.keyHost(key)) >= 0) setups[key] = service.setups[key]
    service.setups = setups
    // What a forgotten machine's storage said goes with it, so one added again starts clean.
    const storage = ({}), storageErrors = ({})
    for (let m = 0; m < want.length; m++) {
      if (service.storage[want[m]]) storage[want[m]] = service.storage[want[m]]
      if (service.storageErrors[want[m]]) storageErrors[want[m]] = service.storageErrors[want[m]]
    }
    service.storage = storage
    service.storageErrors = storageErrors
    const comfyui = ({})
    for (let m = 0; m < want.length; m++) if (service.comfyui[want[m]]) comfyui[want[m]] = service.comfyui[want[m]]
    service.comfyui = comfyui
    const comfyJob = ({})
    for (const key in service.comfyJob) if (want.indexOf(key.substring(0, key.indexOf("#comfy/"))) >= 0) comfyJob[key] = service.comfyJob[key]
    service.comfyJob = comfyJob
  }

  Component.onCompleted: service.refreshHosts()

  // Machines are added and forgotten in terminals too (install, uninstall), so the list is read again now and then.
  Timer {
    interval: service.windowOpen ? 10000 : 300000
    running: true
    repeat: true
    onTriggered: service.refreshHosts()
  }

  ListModel { id: hostModel }

  Instantiator {
    id: pollers
    model: hostModel
    // `host` comes from the model's role.
    delegate: HostPoller { owner: service }
  }

  Process {
    id: hostsProc
    command: [service.script, "hosts", "--json"]
    stdout: StdioCollector { id: hostsOut; waitForEnd: true }
    onExited: function (code) {
      const hosts = code === 0 ? Model.parseHosts(hostsOut.text) : null
      if (!hosts) return
      // Only a real change replaces the list: each machine's section is rebuilt when it does.
      if (JSON.stringify(hosts) !== JSON.stringify(service.hosts)) service.hosts = hosts
      service.loaded = true
      service.syncPollers()
    }
  }

  Process {
    id: hostsActionProc
    stdout: StdioCollector { id: hostsActionOut; waitForEnd: true }
    stderr: StdioCollector { id: hostsActionErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) service.error = Model.errorLine(hostsActionErr.text, "The action failed")
      else {
        service.notice = Model.lastLine(hostsActionOut.text)
        // An added machine shows as added in the card at once, without asking the tailnet again.
        const args = hostsActionProc.command.slice(1)
        if (args[0] === "add") service.peers = service.peers.map(function (p) { return p.target === args[1] ? Object.assign({}, p, { added: true }) : p })
      }
      service.refreshHosts()
      service.runNext()
    }
  }

  Process {
    id: forgetProc
    stdout: StdioCollector { id: forgetOut; waitForEnd: true }
    stderr: StdioCollector { id: forgetErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) service.error = Model.errorLine(forgetErr.text, "The machine could not be forgotten")
      else service.notice = Model.lastLine(forgetOut.text)
      service.refreshHosts()
      service.nextForget()
    }
  }

  Query {
    id: discoverQuery
    onAnswered: function (key, code, out, err) {
      const peers = code === 0 ? Model.parsePeers(out) : null
      if (peers) service.peers = peers
      else service.peersError = Model.errorLine(err, "The tailnet could not be read")
    }
  }

  Query {
    id: listQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.listHost) return
      const list = code === 0 ? Model.parseRecipes(out) : null
      if (list) service.recipes = list
      else service.recipesError = code === 0 ? "The machine's catalog could not be read" : Model.errorLine(err, "The machine's catalog could not be read")
    }
  }

  Query {
    id: comfyRecipesQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.comfyRecipesKey) return
      const list = code === 0 ? Model.parseComfyRecipes(out) : null
      if (list) service.comfyRecipes = list
      else service.comfyRecipesError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Query {
    id: comfyCheckQuery
    onAnswered: function (key, code, out, err) {
      const at = key.lastIndexOf("\n")
      const name = key.substring(at + 1)
      if (key.substring(0, at) !== service.comfyRecipesKey) return
      service.comfyChecking = ""
      const doc = code === 0 ? Model.parseComfyRecipeCheck(out) : null
      if (doc) {
        const next = Object.assign({}, service.comfyChecks)
        next[name] = doc
        service.comfyChecks = next
      } else service.error = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The check didn't run")
    }
  }

  Query {
    id: comfyDoctorQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.comfyDoctorKey) return
      const doc = code === 0 ? Model.parseComfyDoctor(out) : null
      if (doc) service.comfyDoctor = doc
      else service.comfyDoctorError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The checks didn't run")
    }
  }

  Query {
    id: comfyPlanQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.comfyPlanKey) return
      const plan = code === 0 ? Model.parseComfyPlan(out) : null
      if (plan) service.comfyPlan = plan
      else service.comfyPlanError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Query {
    id: comfyOpenQuery
    onAnswered: function (key, code, out, err) {
      const host = key.split("\n")[0]
      const answer = code === 0 ? Model.parseComfyStatus(out) : null
      const url = Model.comfyUrl(host, answer && answer.status ? answer.status : null)
      if (url !== "") { service.notice = ""; Quickshell.execDetached(Model.webappCommand(url)) }
      else service.error = code !== 0 ? Model.errorLine(err, "The machine didn't say") : Model.comfyOpenProblem(answer)
    }
  }
  Query {
    id: comfyStatusQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.comfyStatusKey) return
      const answer = code === 0 ? Model.parseComfyStatus(out) : null
      if (answer) service.comfyStatus = answer
      else service.comfyStatusError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Query {
    id: comfyFindQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.comfyFindHost) return
      const found = code === 0 ? Model.parseComfyList(out) : null
      if (found) { service.comfyFound = found; service.comfyFoundPartial = Model.comfyListPartial(out) }
      else service.comfyFindError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Query {
    id: variantsQuery
    onAnswered: function (key, code, out, err) {
      if (key !== Model.modelKey(service.variantsHost, service.variantsId)) return
      const found = code === 0 ? Model.parseVariants(out) : null
      if (found) service.variants = found
      else service.variantsError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  // Validating is a question (a new one ends the old); adding and removing are writes, which nothing ends.
  Query {
    id: recipeQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.recipeHost + "\n" + service.recipeSeq) return
      const r = code === 0 ? Model.parseRecipeResult(out) : null
      if (r && r.ok && service.recipeThenAdd) {
        service.recipeStep = "adding"
        recipeAddProc.command = [service.script].concat(Model.recipeSendCommand("add", service.recipeHost, service.recipePathAsked))
        recipeAddProc.running = true
      } else service.finishRecipe(code, out, err, "validate")
    }
  }

  Process {
    id: draftProc
    stdout: StdioCollector { id: draftOut; waitForEnd: true }
    stderr: StdioCollector { id: draftErr; waitForEnd: true }
    onExited: function (code) {
      const d = code === 0 ? Model.parseDraftResult(draftOut.text) : null
      service.draftStep = ""
      if (!d) {
        service.draftError = code === 0 ? "The draft's answer could not be read" : Model.draftErrorText(Model.errorLine(draftErr.text, "The draft did not run"))
        return
      }
      service.draftId = d.id
      service.draftName = d.name
      service.draftSource = d.source
      service.draftCtx = d.ctx
      service.draftWarnings = d.warnings
      service.checkRecipe(service.recipeHost, d.path, true)
    }
  }

  Process {
    id: recipeAddProc
    stdout: StdioCollector { id: recipeAddOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeAddErr; waitForEnd: true }
    onExited: function (code) { service.finishRecipe(code, recipeAddOut.text, recipeAddErr.text, "add") }
  }

  Process {
    id: recipeRemoveProc
    property string host: ""
    stdout: StdioCollector { id: recipeRemoveOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeRemoveErr; waitForEnd: true }
    onExited: function (code) {
      service.recipeRemoving = ""
      if (code !== 0) service.recipeRemoveError = Model.errorLine(recipeRemoveErr.text, "The recipe could not be removed")
      else {
        service.notice = Model.lastLine(recipeRemoveOut.text)
        // The picker, if it is open on this machine, shows the list without it.
        if (service.listHost === recipeRemoveProc.host) { service.recipes = null; service.listRecipes(recipeRemoveProc.host) }
      }
      service.loadUserRecipes(recipeRemoveProc.host)
    }
  }

  Query {
    id: runQuery
    onAnswered: function (key, code, out, err) {
      if (key !== [service.runHost, service.runId, service.runCtx].join(" ")) return
      const plan = code === 0 ? Model.parseMeasurePlan(out) : null
      if (plan) service.runPlan = plan
      else service.runError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Process {
    id: recipeMeasureProc
    property string host: ""
    stdout: StdioCollector { id: recipeMeasureOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeMeasureErr; waitForEnd: true }
    onExited: function (code) {
      service.recipeMeasuring = ""
      if (code !== 0) service.error = Model.errorLine(recipeMeasureErr.text, "The measuring failed")
      else service.notice = Model.lastLine(recipeMeasureOut.text)
      if (service.listHost === recipeMeasureProc.host) service.recipes = null
      service.loadUserRecipes(recipeMeasureProc.host)
      // The machine now runs the recipe at that context: read it again, and the variants on show.
      const p = service.poller(recipeMeasureProc.host)
      if (p) p.poll()
      if (service.variantsId !== "") service.planContext(service.variantsHost, service.variantsId)
    }
  }

  Process {
    id: recipeContextProc
    property string host: ""
    stdout: StdioCollector { id: recipeContextOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeContextErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) service.error = Model.errorLine(recipeContextErr.text, "The context could not be changed")
      else service.notice = Model.lastLine(recipeContextOut.text)
      if (service.listHost === recipeContextProc.host) service.listRecipes(recipeContextProc.host)
      service.loadUserRecipes(recipeContextProc.host)
      if (service.variantsId !== "") service.planContext(service.variantsHost, service.variantsId)
    }
  }

  Process {
    id: recipeConfirmProc
    property string host: ""
    stdout: StdioCollector { id: recipeConfirmOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeConfirmErr; waitForEnd: true }
    onExited: function (code) {
      service.recipeConfirming = ""
      if (code !== 0) service.recipeRemoveError = Model.errorLine(recipeConfirmErr.text, "The numbers could not be confirmed")
      else service.notice = Model.lastLine(recipeConfirmOut.text)
      if (service.listHost === recipeConfirmProc.host) service.listRecipes(recipeConfirmProc.host)
      service.loadUserRecipes(recipeConfirmProc.host)
      if (service.variantsId !== "") service.planContext(service.variantsHost, service.variantsId)
    }
  }

  Query {
    id: selfQuery
    onAnswered: function (key, code, out, err) {
      service.selfCheckedMs = Date.now()
      const d = code === 0 ? Model.parseSelfUpdate(out) : null
      if (d) service.selfInfo = d
      else service.selfError = code === 0 ? "The answer could not be read" : Model.errorLine(err, "The look for an update did not run")
    }
  }

  Process {
    id: selfProc
    stdout: StdioCollector { id: selfOut; waitForEnd: true }
    stderr: StdioCollector { id: selfErr; waitForEnd: true }
    onExited: function (code) {
      service.selfUpdating = false
      const d = code === 0 ? Model.parseSelfUpdate(selfOut.text) : null
      if (!d) { service.selfError = code === 0 ? "The answer could not be read" : Model.errorLine(selfErr.text, "The update did not run"); return }
      service.selfInfo = d
      service.selfCheckedMs = Date.now()
      if (d.restarting) service.notice = "Updated to " + d.commit + ". Restarting the shell…"
    }
  }

  Query {
    id: userRecipesQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.recipeHost) return
      const list = code === 0 ? Model.parseRecipes(out) : null
      if (list) service.userRecipes = Model.userRecipes(list)
      else service.userRecipesError = code === 0 ? "The machine's recipes could not be read" : Model.errorLine(err, "The machine's recipes could not be read")
    }
  }

  Query {
    id: destQuery
    onAnswered: function (key, code, out) {
      const found = code === 0 ? Model.parseJson(out) : null
      if (!found || typeof found !== "object") return
      const all = Object.assign({}, service.destinations)
      all[key] = found
      service.destinations = all
    }
  }
  Process {
    id: destSetProc
    stdout: StdioCollector {}
  }

  Query {
    id: tfQuery
    onAnswered: function (key, code, out, err) {
      if (key !== "tf" + service.tfCount) return
      const list = code === 0 ? Model.parseTfList(out) : null
      if (list) service.tfList = list
      else service.tfError = code === 0 ? "TensorFold's answer could not be read" : Model.errorLine(err, "The list did not load")
    }
  }

  Query {
    id: removeQuery
    onAnswered: function (key, code, out, err) {
      if (key !== Model.modelKey(service.removeHost, service.removeId)) return
      const plan = code === 0 ? Model.parseRemovePlan(out) : null
      if (plan) service.removeBytes = plan.bytes
      else service.removeError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(err, "The machine didn't say")
    }
  }

  Query {
    id: planQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.planKey) return
      const plan = code === 0 ? Model.parseUninstallPlan(out) : null
      if (plan) service.uninstallPlan = plan
      else service.planError = code === 0 ? "The machine's plan could not be read" : Model.errorLine(err, "The uninstall plan could not be read")
    }
  }
}
