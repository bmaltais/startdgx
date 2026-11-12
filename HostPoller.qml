// One machine's link to bin/startdgx: its status poller and its three command slots, each with its queue (see
// DgxModel's submit): one for a start, which returns only once its model has loaded (minutes), one for a share, and one
// for a stop, set up or removal, so a Stop never waits for a load to end, nor a share for a removal; and a machine that doesn't answer (an SSH timeout)
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
  // The three slots (a start, a share, anything else) and their queues (DgxModel.newQueue).
  property var queue: Model.newQueue()
  property int lastOp: 0
  // Finished actions whose mark stays until a status read after them: "host/model" -> { shows, op }.
  property var done: ({})
  // Finished actions, [{ key, op }], settled by the poll running now (`settled`) or by the next one (`waiting`,
  // for a poll that began before they finished).
  property var settled: []
  property var waiting: []

  function poll() { if (!statusProc.running) statusProc.running = true }

  function publish() { poller.owner.setMarks(poller.host, Model.marks(poller.queue, poller.done)) }

  // A click: kind is start, stop, use, delete, share or unshare; entry the model's row as drawn.
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
      const proc = l.run[i] === l.queue.starting ? startProc : l.run[i] === l.queue.sharing ? shareProc : otherProc
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
    if (a && !a.superseded) {
      if (code !== 0) {
        poller.owner.error = Model.actionError(err, poller.host)
        poller.owner.actionFailed(a.key, a.kind, Model.errorLine(err, ""))
      } else poller.owner.notice = Model.actionNotice(a.kind, out)
      // A removal's own stop leaves its mark to the removal; a setup has its row instead of a mark.
      if (a.kind === a.shows && a.kind !== "use") {
        const next = Object.assign({}, poller.done)
        next[a.key] = { shows: a.shows, op: a.op }
        poller.done = next
      }
      // Read the machine at once so the row moves on; a poll already on its way began too early to settle it.
      const mark = { key: a.key, op: a.op }
      if (statusProc.running) poller.waiting = poller.waiting.concat([mark])
      else { poller.settled = poller.settled.concat([mark]); statusProc.running = true }
    }
    poller.launchNext()
  }

  Component.onCompleted: poller.poll()

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
