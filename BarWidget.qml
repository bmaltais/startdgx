// The optional bar icon: a server that says how the machines are doing, and opens the manager. What it draws
// comes from a file the service keeps up to date (idle, running, busy, alert), because the icon and the
// service are separate instances. Dim when nothing runs, accent while models run or move, red when a machine
// doesn't answer or a model failed.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.bmaltais.startdgx"

  readonly property string statusFile: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/startdgx/status"
  readonly property var kinds: ["idle", "running", "busy", "alert"]
  property string kind: "idle"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: root.statusFile
    // The file does not exist until the service has first looked at the machines (a fresh install): that is "idle", not an error.
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { const k = text().trim(); root.kind = root.kinds.indexOf(k) >= 0 ? k : "idle" }
    onLoadFailed: root.kind = "idle"
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb81\udc8b"   // server  U+F048B
    active: root.kind !== "idle"
    useActiveColor: true
    activeColor: root.kind === "alert" ? Color.urgent : Color.accent
    opacity: root.kind === "idle" ? 0.6 : 1
    onPressed: function (mouse) {
      if (!root.bar) return
      // Right click looks at the machines again; left click opens the manager.
      if (mouse === Qt.RightButton) root.bar.run("omarchy-shell io.github.bmaltais.startdgx refresh")
      else root.bar.run("omarchy-shell io.github.bmaltais.startdgx open")
    }
  }
}
