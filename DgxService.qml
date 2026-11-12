// Everything the manager knows about the machines, and the only thing that runs bin/startdgx. Each added
// machine has its own HostPoller (status poll, and its three command slots: a start, a share, and a stop, use or delete); the machine list,
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
  // "target/model" -> its click's mark (DgxModel.pendingOf): a start, stop or delete running there or waiting its
  // turn, or done and not answered yet. Each machine's poller publishes its own (`marks`: target -> its map).
  property var marks: ({})
  property var pending: ({})
  // "target/model" -> its recipe (from `list`): a model asked to be set up that its machine doesn't list yet.
  property var setups: ({})
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

  // The Find on Hugging Face card (`hf search --json`, run on this computer): the rows of the last search, why it failed, and the query
  // it was asked ("" before the first). A search touches no machine.
  property var hfRows: null
  property string hfError: ""
  property string hfAsked: ""
  readonly property bool hfSearching: hfQuery.busy

  // The context card's choices (`variants HOST MODEL --json`): the contexts the recipe has measured, null until read.
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
  readonly property bool recipeBusy: service.recipeStep !== "" || service.recipeWriting || service.recipeMeasuring !== "" || service.recipeConfirming !== ""
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

  readonly property var summary: Model.summarize(service.hostList, service.shownState)
  readonly property var rows: Model.rows(service.hostList, service.shownState)

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
    service.notifyChanges()
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
    p.run("use", r.id, null, yes ? { yes: true } : undefined)
  }
  // The action failed: a setup asked for that never began goes from the list again (a start, stop or delete is
  // settled by the next status read, as on success); one that failed for want of the machine's root setup makes
  // its section offer Install….
  function actionFailed(key, kind, error) {
    if (kind !== "use") return
    const host = Model.keyHost(key)
    if (Model.setupNeeded(error)) service.markSetupNeeded(host, true)
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

  // Accepts an estimated recipe's numbers (`recipe confirm`): it then counts as fitting.
  function confirmRecipe(host, id) {
    if (service.recipeBusy) return
    service.recipeConfirming = id
    service.recipeRemoveError = ""
    recipeConfirmProc.host = host
    recipeConfirmProc.command = [service.script, "recipe", "confirm", host, id, "--timeout", "60"]
    recipeConfirmProc.running = true
  }

  function searchHf(query) {
    service.hfAsked = query.trim()
    service.hfError = ""
    hfQuery.ask(service.hfAsked, [service.script].concat(Model.hfSearchCommand(query)))
  }
  function cancelHf() { hfQuery.cancel() }

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
        if (service.listHost === recipeRemoveProc.host) service.recipes = null
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
    id: recipeConfirmProc
    property string host: ""
    stdout: StdioCollector { id: recipeConfirmOut; waitForEnd: true }
    stderr: StdioCollector { id: recipeConfirmErr; waitForEnd: true }
    onExited: function (code) {
      service.recipeConfirming = ""
      if (code !== 0) service.recipeRemoveError = Model.errorLine(recipeConfirmErr.text, "The numbers could not be confirmed")
      else service.notice = Model.lastLine(recipeConfirmOut.text)
      if (service.listHost === recipeConfirmProc.host) service.recipes = null
      service.loadUserRecipes(recipeConfirmProc.host)
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
    id: hfQuery
    onAnswered: function (key, code, out, err) {
      if (key !== service.hfAsked) return
      const rows = code === 0 ? Model.parseHfRows(out) : null
      if (rows) service.hfRows = rows
      else service.hfError = code === 0 ? "Hugging Face's answer could not be read" : Model.errorLine(err, "The search did not run")
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
