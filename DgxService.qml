// Everything the manager knows about the machines, and the only thing that runs bin/startdgx. Each added
// machine has its own HostPoller (status poll, and its two command slots: a start, and a stop, use or delete); the machine list,
// adding, forgetting, discovery, a machine's catalog for the model picker, the uninstall and remove plans and the
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

  // The machine-list actions (add, forget) wait their turn here: { args }.
  property var queue: []
  readonly property bool busy: hostsActionProc.running || service.queue.length > 0

  // Discovery, for the Add machine card.
  property var peers: []
  property string peersError: ""
  readonly property bool discovering: discoverProc.running

  // The uninstall plan (`uninstall HOST --dry-run`), for the uninstall card.
  property string planHost: ""
  property string planText: ""
  property string planError: ""
  readonly property bool planning: planProc.running

  // target -> true: a setup there failed because the machine needs its one-time root setup (Model.setupNeeded), so
  // its section offers Install…, until that is launched.
  property var setupNeeded: ({})

  // Failures already told to the desktop; see Model.alerts.
  property var announced: ({})

  // The model picker's catalog (`list HOST`), for one machine at a time.
  property string listHost: ""
  property var recipes: null
  property string recipesError: ""
  readonly property bool listing: listProc.running

  // The remove card's plan (`delete HOST MODEL --dry-run --json`): what the removal frees, -1 until it is read.
  property string removeHost: ""
  property string removeId: ""
  property real removeBytes: -1
  property string removeError: ""
  readonly property bool removePlanning: removeProc.running

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
      Quickshell.execDetached(["notify-send", "--app-name=StartDGX", "--urgency=critical", r.list[i].title, r.list[i].body])
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

  // Each goes to the machine's poller, which runs it on one of its two slots (DgxModel.submit): a start beside
  // anything else, so a Stop never waits for a load. Its row shows the click once the command runs, and says it is
  // queued until then; the machine's next answer after the command replaces it.
  function start(host, id) { service.act(host, "start", id) }
  function stop(host, id) { service.act(host, "stop", id) }
  // A removal (or a setup's cancel) returns once the model is gone, after its stop and the deletion of its weights.
  function remove(host, id) { service.act(host, "delete", id) }
  function act(host, kind, id) {
    const p = service.poller(host)
    if (p) p.run(kind, id, service.entry(host, id))
  }
  // A setup runs on the machine in a unit of its own (`use --detach`), so the command returns at once and the
  // status poll follows the download. The model shows, waiting, from the click until the machine lists it.
  function use(host, r) {
    const p = service.poller(host)
    if (!p || !r) return
    const next = Object.assign({}, service.setups)
    next[host + "/" + r.id] = r
    service.setups = next
    p.run("use", r.id, null)
  }
  // The action failed: a setup asked for that never began goes from the list again (a start, stop or delete is
  // settled by the next status read, as on success); one that failed for want of the machine's root setup makes
  // its section offer Install….
  function actionFailed(key, kind, error) {
    if (kind !== "use") return
    const host = key.substring(0, key.lastIndexOf("/"))
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

  function listRecipes(host) {
    if (service.listHost !== host) { service.recipes = null; service.listHost = host }
    service.recipesError = ""
    listProc.running = false
    listProc.command = [service.script, "list", host, "--timeout", "60"]
    listProc.running = true
  }

  function planRemove(host, id) {
    // Already asking about this one: a second ask would kill the first, whose exit would then read as a failure.
    if (removeProc.running && service.removeHost === host && service.removeId === id) return
    service.removeHost = host
    service.removeId = id
    service.removeBytes = -1
    service.removeError = ""
    removeProc.running = false
    removeProc.command = [service.script, "delete", host, id, "--dry-run", "--json", "--timeout", "60"]
    removeProc.running = true
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
  function forget(host) { service.run(["forget", host]) }

  // `user`: the ssh user on the machines, or "" for this machine's.
  function discover(user) {
    if (discoverProc.running) return
    service.peersError = ""
    discoverProc.command = [service.script, "discover", "--json"].concat(user ? ["--user", user] : [])
    discoverProc.running = true
  }

  function plan(host) {
    service.planHost = host
    service.planText = ""
    service.planError = ""
    planProc.running = false
    planProc.command = [service.script, "uninstall", host, "--dry-run", "--timeout", "60"]
    planProc.running = true
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
    for (const key in service.setups) if (want.indexOf(key.substring(0, key.lastIndexOf("/"))) >= 0) setups[key] = service.setups[key]
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
    id: discoverProc
    stdout: StdioCollector { id: discoverOut; waitForEnd: true }
    stderr: StdioCollector { id: discoverErr; waitForEnd: true }
    onExited: function (code) {
      const peers = code === 0 ? Model.parsePeers(discoverOut.text) : null
      if (peers) service.peers = peers
      else service.peersError = Model.errorLine(discoverErr.text, "The tailnet could not be read")
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function (code) {
      const list = code === 0 ? Model.parseRecipes(listOut.text) : null
      if (list) service.recipes = list
      else service.recipesError = code === 0 ? "The machine's catalog could not be read" : Model.errorLine(listErr.text, "The machine's catalog could not be read")
    }
  }

  Process {
    id: removeProc
    stdout: StdioCollector { id: removeOut; waitForEnd: true }
    stderr: StdioCollector { id: removeErr; waitForEnd: true }
    onExited: function (code) {
      const plan = code === 0 ? Model.parseRemovePlan(removeOut.text) : null
      if (plan) service.removeBytes = plan.bytes
      else service.removeError = code === 0 ? "The machine's answer could not be read" : Model.errorLine(removeErr.text, "The machine didn't say")
    }
  }

  Process {
    id: planProc
    stdout: StdioCollector { id: planOut; waitForEnd: true }
    stderr: StdioCollector { id: planErr; waitForEnd: true }
    onExited: function (code) {
      if (code === 0) service.planText = String(planOut.text || "").trim()
      else service.planError = Model.errorLine(planErr.text, "The uninstall plan could not be read")
    }
  }
}
