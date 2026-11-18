// One machine's link to bin/startdgx: its status poller and its four command slots, each with its queue (see
// DgxModel's submit): one for a start, which returns only once its model has loaded (minutes), one for a share, one for a move (minutes of copying) or a change of the model store, and one
// for a stop, set up or removal, so a Stop never waits for a load or a copy to end, nor a share for a removal; and a machine that doesn't answer (an SSH timeout)
// never holds up another machine. DgxService makes one per added host and keeps what it learns; this file only
// runs the commands, and tells the service each model's mark (DgxModel.marks) whenever it changes.
import QtQuick
import Quickshell.Io
import "DgxModel.js" as Model

Item {
  id: poller

  required property string host
  required property var owner

  // As drawn, with the setups just asked for: one of those makes the machine busy, so it is polled quickly.
  readonly property var hostState: poller.owner.shownState[poller.host]
  // The four slots (a start, a share, a move or store change, anything else) and their queues (DgxModel.newQueue).
  property var queue: Model.newQueue()
  property int lastOp: 0
  // Finished actions whose mark stays until a status read after them: "host/model" -> { shows, op }.
  property var done: ({})
  // Finished actions, [{ key, op }], settled by the poll running now (`settled`) or by the next one (`waiting`,
  // for a poll that began before they finished).
  property var settled: []
  property var waiting: []

  function poll() { if (!statusProc.running) statusProc.running = true }
  // Where the models' files are changes only on a move or a store change, so it is read while the window is open
  // (and a machine answers), and once more right after one of those ends.
  // Never for a machine that hasn't answered yet or isn't answering now.
  readonly property bool answering: !!poller.hostState && poller.hostState.loaded && poller.hostState.online
  property bool storageAsked: false
  // Finished moves and store changes, [{ key, op }], settled by the storage read running now (`storageSettled`) or by the
  // next one (`storageWaiting`, for a read that began before they finished): their mark stays until a read after them.
  property var storageSettled: []
  property var storageWaiting: []
  function pollStorage() {
    if (!poller.answering) return
    poller.storageAsked = true
    if (!storageProc.running) storageProc.running = true
    poller.pollComfy()
  }
  // The managed ComfyUI installs change only when one is adopted, installed or forgotten, so they are read with the storage
  // (while the window is open, every 30 s): a host script that looks at each install's folder. A machine without any answers quickly.
  function pollComfy() {
    if (poller.answering && !comfyProc.running) comfyProc.running = true
  }

  // The ComfyUI actions of this machine, one at a time and apart from the models' slots (an install is named by its folder,
  // and a start or stop takes seconds, not a model's minutes): [{ kind, path, label }], the first one running; and the starts
  // and stops that have finished but not yet shown in the status ([{ kind, path, until }], DgxModel.comfyMarks).
  property var comfyJobs: []
  property var comfySettling: []

  function publish() {
    const status = poller.hostState ? poller.hostState.status : null
    const c = Model.comfyMarks(poller.host, poller.comfyJobs, poller.comfySettling, status, Date.now())
    poller.comfySettling = c.settling
    poller.owner.setMarks(poller.host, Object.assign({}, Model.marks(poller.queue, poller.done), c.marks))
  }

  // Jobs (an install or update) run on the machine on their own, so they are asked about: `comfyui job` for each install not yet installed
  // and each one a job was started on this session, every few seconds while the window is open (DgxModel.comfyWatchPaths).
  property var comfyStarted: []
  property var comfyJobQueue: []
  function pollComfyJobs() {
    if (!poller.answering || comfyJobProc.running) return
    poller.comfyJobQueue = Model.comfyWatchPaths(poller.owner.comfyui[poller.host] || [], poller.comfyStarted)
    poller.askNextJob()
  }
  function askNextJob() {
    if (poller.comfyJobQueue.length === 0) return
    comfyJobProc.command = [poller.owner.script, "comfyui", "job", poller.host, "--dir", poller.comfyJobQueue[0], "--json", "--timeout", "60"]
    comfyJobProc.running = true
  }

  // A click on an install: kind is start, stop, autostart-on, autostart-off, install, adopt (the label names an adopted or new one in the panel)
  // or forget (`stopService` also removes its background service).
  function runComfy(kind, path, label, stopService) {
    poller.comfyJobs = poller.comfyJobs.concat([{ kind: kind, path: path, label: label || "", stopService: !!stopService }])
    poller.publish()
    poller.launchComfy()
  }
  function launchComfy() {
    if (comfyActProc.running || poller.comfyJobs.length === 0) return
    comfyActProc.command = [poller.owner.script].concat(Model.comfyCommand(poller.host, poller.comfyJobs[0]))
    comfyActProc.running = true
  }

  // A click: kind is start, stop, use, delete, share, unshare, move, storageSet or storageUnset; entry the model's row as drawn.
  // `extra` is what the command needs besides (a context's size). A context change shows as a setup does: no mark of its own.
  function run(kind, id, entry, extra) {
    poller.lastOp += 1
    const action = Object.assign({ op: poller.lastOp, key: Model.actionKey(poller.host, id, kind), kind: kind, shows: kind === "context" ? "use" : kind }, extra || {})
    const s = Model.submit(poller.queue, action, entry)
    poller.queue = s.queue
    poller.launchNext()
  }
  function launchNext() {
    const l = Model.launch(poller.queue)
    poller.queue = l.queue
    for (let i = 0; i < l.run.length; i++) {
      const proc = l.run[i] === l.queue.starting ? startProc : l.run[i] === l.queue.sharing ? shareProc : l.run[i] === l.queue.moving ? moveProc : otherProc
      proc.command = [poller.owner.script].concat(Model.commandFor(poller.host, l.run[i]))
      proc.running = true
    }
    poller.publish()
  }
  // A slot's command ended. A start a stop or removal superseded says nothing: the machine's next answer shows how
  // it ended.
  function ended(slot, code, out, err) {
    const f = Model.finish(poller.queue, slot)
    poller.queue = f.queue
    const a = f.action
    const storageKind = !!a && Model.MOVE_KINDS.indexOf(a.kind) >= 0
    if (a && !a.superseded) {
      if (code !== 0) {
        poller.owner.error = Model.actionError(err, poller.host)
        poller.owner.actionFailed(a.key, a.kind, Model.errorLine(err, ""))
      } else poller.owner.notice = Model.actionNotice(a.kind, out)
      // A removal's own stop leaves its mark to the removal; a setup has its row instead of a mark.
      if (storageKind || (a.kind === a.shows && a.kind !== "use")) {
        const next = Object.assign({}, poller.done)
        next[a.key] = { shows: a.shows, op: a.op }
        poller.done = next
      }
      // Read the machine at once so the row moves on; a poll already on its way began too early to settle it. A move or
      // store change changes what storage says, not the status, so its mark waits for the storage read.
      const mark = { key: a.key, op: a.op }
      if (storageKind) {
        if (storageProc.running) poller.storageWaiting = poller.storageWaiting.concat([mark])
        else { poller.storageSettled = poller.storageSettled.concat([mark]); poller.storageAsked = true; storageProc.running = true }
      } else if (statusProc.running) poller.waiting = poller.waiting.concat([mark])
      else { poller.settled = poller.settled.concat([mark]); statusProc.running = true }
    }
    poller.launchNext()
  }

  Component.onCompleted: poller.poll()

  Connections {
    target: poller.owner
    function onWindowOpenChanged() { if (poller.owner.windowOpen) poller.pollStorage() }
  }
  // Also once the machine first answers while the window is open.
  Connections {
    target: poller
    function onHostStateChanged() {
      if (!poller.answering) poller.storageAsked = false
      else if (poller.owner.windowOpen && !poller.storageAsked) poller.pollStorage()
    }
  }
  Timer {
    interval: 30000
    running: poller.owner.windowOpen
    repeat: true
    onTriggered: poller.pollStorage()
  }

  Timer {
    interval: Model.pollInterval(poller.owner.windowOpen, poller.hostState)
    running: true
    repeat: true
    onTriggered: poller.poll()
  }

  Process {
    id: statusProc
    // Never longer than a poll: an away machine fails after its SSH connect timeout (10 s).
    command: [poller.owner.script, "status", poller.host, "--timeout", "15"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function (code) {
      const answered = poller.settled
      poller.settled = poller.waiting
      poller.waiting = []
      if (poller.settled.length > 0) Qt.callLater(poller.poll)
      // An answer that can't be read shows the machine as not answering, with why, keeping its last good status.
      const answer = Model.statusAnswer(code, statusOut.text, statusErr.text, poller.host)
      if (answer.status) poller.owner.statusRead(poller.host, answer.status)
      else poller.owner.statusFailed(poller.host, answer.error)
      poller.done = Model.settle(poller.done, answered)
      poller.publish()
    }
  }

  Process {
    id: storageProc
    command: [poller.owner.script, "storage", poller.host, "--json", "--timeout", "30"]
    stdout: StdioCollector { id: storageOut; waitForEnd: true }
    stderr: StdioCollector { id: storageErr; waitForEnd: true }
    onExited: function (code) {
      const answered = poller.storageSettled
      poller.storageSettled = poller.storageWaiting
      poller.storageWaiting = []
      if (poller.storageSettled.length > 0) Qt.callLater(poller.pollStorage)
      const answer = Model.storageAnswer(code, storageOut.text, storageErr.text, poller.host)
      poller.owner.storageRead(poller.host, answer.storage, answer.error || "")
      poller.done = Model.settle(poller.done, answered)
      poller.publish()
    }
  }

  Process {
    id: comfyProc
    command: [poller.owner.script, "comfyui", "list", poller.host, "--json", "--timeout", "30"]
    stdout: StdioCollector { id: comfyOut; waitForEnd: true }
    stderr: StdioCollector { id: comfyErr; waitForEnd: true }
    // A failed read is not shown: the installs keep their last good list, and the machine's own status says if it is away.
    onExited: function (code) { poller.owner.comfyRead(poller.host, Model.comfyAnswer(code, comfyOut.text, comfyErr.text, poller.host).installs) }
  }

  Timer {
    interval: 4000
    running: poller.owner.windowOpen
    repeat: true
    onTriggered: poller.pollComfyJobs()
  }
  Process {
    id: comfyJobProc
    stdout: StdioCollector { id: comfyJobOut; waitForEnd: true }
    stderr: StdioCollector { id: comfyJobErr; waitForEnd: true }
    onExited: function (code) {
      const path = poller.comfyJobQueue[0]
      poller.comfyJobQueue = poller.comfyJobQueue.slice(1)
      const job = code === 0 ? Model.parseComfyJob(comfyJobOut.text) : null
      if (job) {
        poller.owner.comfyJobRead(poller.host, path, job)
        // A job we started has ended: the install is (or is not) installed now, which the list says.
        if (job.state !== "running" && poller.comfyStarted.indexOf(path) >= 0) {
          poller.comfyStarted = poller.comfyStarted.filter(function (p) { return p !== path })
          poller.pollComfy()
          poller.poll()
          // The install's window, if open, shows what the job changed.
          poller.owner.comfyActed(poller.host, "job", path)
        }
      }
      Qt.callLater(poller.askNextJob)
    }
  }
  Process {
    id: comfyActProc
    stdout: StdioCollector { id: comfyActOut; waitForEnd: true }
    stderr: StdioCollector { id: comfyActErr; waitForEnd: true }
    onExited: function (code) {
      const job = poller.comfyJobs[0]
      poller.comfyJobs = poller.comfyJobs.slice(1)
      if (code !== 0) poller.owner.error = Model.actionError(comfyActErr.text, poller.host)
      else {
        poller.owner.notice = Model.actionNotice("comfyui", comfyActOut.text)
        // A started or stopped ComfyUI shows in the status seconds later: its mark stays until it does.
        if (job.kind === "install" || job.kind === "update" || job.kind === "update-comfyui") poller.comfyStarted = poller.comfyStarted.concat([job.path])
        const shown = Model.comfyMark(job.kind)
        if (shown === "start" || shown === "stop") poller.comfySettling = poller.comfySettling.concat([{ kind: shown, path: job.path, until: Date.now() + 30000 }])
      }
      poller.owner.comfyActed(poller.host, job.kind, job.path)
      poller.publish()
      // What the action changed: the status (running), and the list (adopted).
      poller.poll()
      poller.pollComfy()
      if (job.kind === "install" || job.kind === "update" || job.kind === "update-comfyui") Qt.callLater(poller.pollComfyJobs)
      Qt.callLater(poller.launchComfy)
    }
  }

  Process {
    id: moveProc
    stdout: StdioCollector { id: moveOut; waitForEnd: true }
    stderr: StdioCollector { id: moveErr; waitForEnd: true }
    onExited: function (code) { poller.ended("move", code, moveOut.text, moveErr.text) }
  }

  Process {
    id: startProc
    stdout: StdioCollector { id: startOut; waitForEnd: true }
    stderr: StdioCollector { id: startErr; waitForEnd: true }
    onExited: function (code) { poller.ended("start", code, startOut.text, startErr.text) }
  }

  Process {
    id: shareProc
    stdout: StdioCollector { id: shareOut; waitForEnd: true }
    stderr: StdioCollector { id: shareErr; waitForEnd: true }
    onExited: function (code) { poller.ended("share", code, shareOut.text, shareErr.text) }
  }

  Process {
    id: otherProc
    stdout: StdioCollector { id: otherOut; waitForEnd: true }
    stderr: StdioCollector { id: otherErr; waitForEnd: true }
    onExited: function (code) { poller.ended("other", code, otherOut.text, otherErr.text) }
  }
}
