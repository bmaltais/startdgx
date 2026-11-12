// One question at a time to bin/startdgx, the latest one wins (DgxModel's queryAsk): a new question ends the one
// running and is asked once that one has exited, whose answer is then dropped, so a late exit never lands on the
// next card. DgxService has one for each card's question (a catalog, a removal plan, an uninstall plan, the tailnet).
import QtQuick
import Quickshell.Io
import "DgxModel.js" as Model

Item {
  id: query

  property var asked: Model.newQuery()
  // The command for the question wanted.
  property var wantedCommand: []
  // A question runs, or waits for the one before it to end.
  readonly property bool busy: query.asked.running !== null

  // The wanted question's answer (key as asked).
  signal answered(string key, int code, string out, string err)

  function ask(key, command) {
    const r = Model.queryAsk(query.asked, key)
    query.asked = r.query
    query.wantedCommand = command
    if (r.launch !== null) query.begin()
    else if (r.kill) proc.running = false
  }
  // Its card closed: end it, and drop its answer.
  function cancel() {
    const r = Model.queryCancel(query.asked)
    query.asked = r.query
    if (r.kill) proc.running = false
  }
  function begin() {
    proc.command = query.wantedCommand
    proc.running = true
  }

  Process {
    id: proc
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function (code) {
      const r = Model.queryExited(query.asked)
      query.asked = r.query
      if (r.current) query.answered(r.key, code, out.text, err.text)
      // Not from inside this process's own exit.
      if (r.launch !== null) Qt.callLater(query.begin)
    }
  }
}
