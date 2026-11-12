// Everything the manager knows about the machines, and the only thing that runs bin/startdgx. Each added
// machine has its own HostPoller (status poll and start/stop queue); the machine list, adding, forgetting,
// discovery, the uninstall plan and the terminal launches run here. Results come back through `notice` and
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
  // "target/model" -> "start" | "stop": a click the machine has not answered yet.
  property var pending: ({})

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

  // Failures already told to the desktop; see Model.alerts.
  property var announced: ({})

  readonly property var summary: Model.summarize(service.hostList, service.hostState)
  readonly property var rows: Model.rows(service.hostList, service.hostState)

  function entry(host, id) {
    const hs = service.hostState[host]
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

  function setPending(key, kind) {
    const next = Object.assign({}, service.pending)
    next[key] = kind
    service.pending = next
  }
  function clearPending(keys) {
    if (keys.length === 0) return
    const next = Object.assign({}, service.pending)
    for (let i = 0; i < keys.length; i++) delete next[keys[i]]
    service.pending = next
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

  // The row shows the click at once; the machine's next answer after the command replaces it. A start returns
  // once the model has loaded, which can take minutes, so it gets a long timeout.
  function start(host, id) {
    const p = service.poller(host)
    if (!p) return
    service.setPending(host + "/" + id, "start")
    p.run(["start", host, id, "--timeout", "900"], host + "/" + id, "start")
  }
  function stop(host, id) {
    const p = service.poller(host)
    if (!p) return
    service.setPending(host + "/" + id, "stop")
    p.run(["stop", host, id, "--timeout", "120"], host + "/" + id, "stop")
  }
  // #6 adds `use HOST MODEL --detach` (set a model up; status shows the download) and `delete HOST MODEL` here,
  // run through the host's poller like start and stop, with `list HOST` read when the model picker opens.

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

  function discover() {
    if (discoverProc.running) return
    service.peersError = ""
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
  function launch(verb, host, id) {
    Quickshell.execDetached([service.script, "launch", verb, host].concat(id ? [id] : []))
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
    command: [service.script, "discover", "--json"]
    stdout: StdioCollector { id: discoverOut; waitForEnd: true }
    stderr: StdioCollector { id: discoverErr; waitForEnd: true }
    onExited: function (code) {
      const peers = code === 0 ? Model.parsePeers(discoverOut.text) : null
      if (peers) service.peers = peers
      else service.peersError = Model.errorLine(discoverErr.text, "The tailnet could not be read")
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
