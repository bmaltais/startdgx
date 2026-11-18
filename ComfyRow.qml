// One ComfyUI install on one machine: a dot (accent while it runs), its name with its folder under it, what it is doing, its
// version and the memory it holds, and a Start or Stop button. The manager owns the cursor and every decision, this file only
// paints and says what was asked for. Names and paths come from the host and are drawn as plain text.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Rectangle {
  id: row

  property var info: ({})           // DgxModel.comfyRow(): { path, name, state, version, note, gib }
  property bool current: false      // under the keyboard cursor
  property bool away: false         // the machine isn't answering: its last known state, dimmed
  property string pending: ""       // "start" or "stop" while a click waits for the host (DgxModel.comfyMarks)
  property var toggle: ({ action: "", reason: "" })   // DgxModel.comfyToggle(): what the button does, or why it can't

  signal selectRequested()
  signal toggleRequested()

  readonly property bool running: row.info.state === "running"
  readonly property bool hot: hover.hovered || row.current
  readonly property bool busy: row.pending !== ""
  readonly property string stateWord: row.pending === "start" ? "Starting" : row.pending === "stop" ? "Stopping" : row.pending === "adopt" ? "Adding"
    : row.running ? "Running" : row.info.state === "unfinished" ? "Not installed" : row.info.state === "missing" ? "Folder gone"
    : row.info.state === "unsupported" ? "Not managed" : "Stopped"

  implicitHeight: body.implicitHeight + Style.spacing.md * 2
  radius: Math.max(Style.cornerRadius, Style.space(6))
  color: row.hot ? Util.alpha(Color.foreground, 0.06) : "transparent"
  border.width: Style.normalBorderWidth
  border.color: row.current ? Util.alpha(Color.accent, 0.7) : "transparent"
  opacity: row.away ? 0.55 : 1

  Rectangle {
    visible: !row.hot
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: Style.spacing.xxl
    height: 1
    color: Util.alpha(Color.foreground, 0.08)
  }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    onClicked: row.selectRequested()
  }

  RowLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xxl
    anchors.rightMargin: Style.spacing.lg
    spacing: Style.space(10)

    Rectangle {
      id: dot
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: Style.space(7)
      Layout.preferredHeight: Style.space(7)
      radius: width / 2
      color: row.running || row.busy ? Color.accent : Util.alpha(Color.foreground, 0.35)
      SequentialAnimation on opacity {
        running: !Style.reduceMotion && row.busy && !row.away
        loops: Animation.Infinite
        onRunningChanged: if (!running) dot.opacity = 1
        NumberAnimation { to: 0.25; duration: 500 }
        NumberAnimation { to: 1; duration: 500 }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxs
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: String(row.info.name || "")
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        // Why a row can't be used as it is takes the folder's place: that is what needs reading.
        text: row.info.note ? String(row.info.note) : String(row.info.path || "")
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        // The end of a path is what tells installs apart.
        elide: row.info.note ? Text.ElideRight : Text.ElideLeft
        HoverHandler { id: pathHover }
        PanelToolTip {
          visible: pathHover.hovered
          text: String(row.info.path || "")
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      text: row.stateWord
      color: row.running || row.busy ? Color.foreground : Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      visible: String(row.info.version || "") !== ""
      textFormat: Text.PlainText
      text: String(row.info.version || "")
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.features: { "tnum": 1 }
    }
    Text {
      visible: row.running && row.info.gib > 0
      textFormat: Text.PlainText
      text: Math.round(row.info.gib) + " GiB"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.features: { "tnum": 1 }
    }
    // Start or Stop; greyed out, with the reason, while another install runs (they share the machine's memory).
    Button {
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: implicitHeight
      visible: !row.away
      enabled: row.toggle.action !== "" || row.toggle.reason !== ""
      iconText: row.toggle.action === "stop" ? "\udb80\udfe4" : "\udb81\udc0a"
      tooltipText: row.toggle.reason !== "" ? row.toggle.reason : row.toggle.action === "stop" ? "Stop  (s)" : row.toggle.action === "start" ? "Start  (s)" : ""
      foreground: row.toggle.reason !== "" ? Color.muted : Color.foreground
      opacity: !enabled ? 0 : row.toggle.reason !== "" ? 0.5 : 1
      onClicked: if (row.toggle.reason === "") row.toggleRequested()
    }
  }
}
