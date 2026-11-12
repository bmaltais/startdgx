// One machine's link to bin/startdgx: its status poller and its own action queue, so a machine that doesn't
// answer (an SSH timeout) or a start that waits minutes for its model to load never holds up another machine.
// DgxService makes one per added host and keeps what it learns; this file only runs the commands.
import QtQuick
import Quickshell.Io
import "DgxModel.js" as Model

Item {
  id: poller

  required property string host
  required property var owner

  readonly property var hostState: poller.owner.hostState[poller.host]
  // Actions waiting for the one that is running: { args, key, kind }.
  property var queue: []
  // Starts and stops that have finished: their pending mark goes once a status read after them arrives
  // (`settled`, for the poll running now; `waiting`, for one that began before they finished).
  property var settled: []
  property var waiting: []

  function poll() { if (!statusProc.running) statusProc.running = true }

  function run(args, key, kind) {
    poller.queue = poller.queue.concat([{ args: args, key: key, kind: kind }])
    poller.runNext()
  }
  function runNext() {
    if (actionProc.running || poller.queue.length === 0) return
    const next = poller.queue[0]
    poller.queue = poller.queue.slice(1)
    actionProc.key = next.key
    actionProc.command = [poller.owner.script].concat(next.args)
    actionProc.running = true
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
      const done = poller.settled
      poller.settled = poller.waiting
      poller.waiting = []
      if (poller.settled.length > 0) Qt.callLater(poller.poll)
      if (code === 0) {
        const status = Model.parseStatus(statusOut.text)
        // A garbled answer keeps the last good status and says nothing.
        if (status) poller.owner.statusRead(poller.host, status)
      } else {
        poller.owner.statusFailed(poller.host, Model.errorLine(statusErr.text, poller.host + " didn't answer"))
      }
      poller.owner.clearPending(done)
    }
  }

  Process {
    id: actionProc
    property string key: ""
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) poller.owner.error = Model.errorLine(actionErr.text, "The action failed")
      else poller.owner.notice = Model.lastLine(actionOut.text)
      // Read the machine at once so the row moves on; a poll already on its way began too early to settle it.
      if (statusProc.running) poller.waiting = poller.waiting.concat([actionProc.key])
      else { poller.settled = poller.settled.concat([actionProc.key]); statusProc.running = true }
      poller.runNext()
    }
  }
}
