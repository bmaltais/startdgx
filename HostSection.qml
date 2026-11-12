// One machine: its name, what it is, whether it answers (and why not), its quiet actions (Logs, Uninstall…,
// Forget), its models and, on a machine that answers, an Add model… row that opens its model picker. The manager owns the cursor and every decision; this file only paints and passes on
// what was asked for, as the same actions the keys make (DgxModel.keyAction).
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

ColumnLayout {
  id: section

  property string host: ""
  property var profile: ({})
  property var hostState: null        // { loaded, online, error, status, lastSeenMs }, or null before the first answer
  property var pending: ({})          // "host/model" -> "start" | "stop" | "delete"
  property real nowMs: 0
  property string cursorKey: ""       // the row under the keyboard cursor: "host", "host/model" or "host#add"

  signal selectRequested(string key)
  signal actionRequested(var action)
  signal revealRequested(var item)     // the row under the cursor, to scroll into sight

  readonly property bool loaded: !!section.hostState && section.hostState.loaded
  readonly property bool away: Model.isAway(section.hostState)
  readonly property var entries: Model.modelList(section.hostState ? section.hostState.status : null)
  // The rows are made per model id and kept across polls (a new list would rebuild them, and lose a bar that
  // is filling to its end), so the list is only replaced when the ids change.
  property var ids: []
  function syncIds() {
    const next = section.entries.map(function (e) { return e.recipe })
    if (next.join("\n") !== section.ids.join("\n")) section.ids = next
  }
  onEntriesChanged: section.syncIds()
  Component.onCompleted: section.syncIds()
  function entryOf(id) {
    const status = section.hostState ? section.hostState.status : null
    return status && status.models && status.models[id] ? status.models[id] : ({ recipe: id, unit: "inactive" })
  }
  readonly property bool headCurrent: section.cursorKey === section.host
  readonly property string machine: Model.hostName(section.host)

  spacing: Style.spacing.md

  // The machine's own row.
  Rectangle {
    id: head
    Layout.fillWidth: true
    implicitHeight: headBody.implicitHeight + Style.spacing.md * 2
    radius: Math.max(Style.cornerRadius, Style.space(6))
    color: headHover.hovered || section.headCurrent ? Util.alpha(Color.foreground, 0.06) : "transparent"
    border.width: Style.normalBorderWidth
    border.color: section.headCurrent ? Util.alpha(Color.accent, 0.7) : "transparent"
    HoverHandler { id: headHover }
    readonly property bool lit: section.headCurrent
    onLitChanged: if (lit) section.revealRequested(head)
    MouseArea { anchors.fill: parent; onClicked: section.selectRequested(section.host) }

    RowLayout {
      id: headBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.md
      anchors.rightMargin: Style.spacing.md
      spacing: Style.spacing.lg

      Rectangle {
        Layout.preferredWidth: Style.space(8)
        Layout.preferredHeight: Style.space(8)
        Layout.alignment: Qt.AlignVCenter
        radius: width / 2
        color: !section.loaded ? Util.alpha(Color.foreground, 0.35) : section.away ? Color.urgent : Color.accent
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: section.machine
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            // The SSH target, when it says more than the name (a user).
            text: [section.host !== section.machine ? section.host : "", Model.hostLine(section.profile)].filter(function (s) { return s !== "" }).join("  ·  ")
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: !section.loaded ? "Asking the machine…"
            : section.away ? Model.offlineText(section.hostState.error, section.hostState.lastSeenMs, section.nowMs)
            : section.entries.length === 0 ? "No models set up yet" : ""
          color: section.away ? Color.urgent : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
      }

      TextLink {
        Layout.alignment: Qt.AlignVCenter
        visible: section.loaded && !section.away
        text: "Logs…"
        tooltip: "Open the logs of the model started last, in a terminal  (l)"
        onClicked: section.actionRequested({ type: "logs", host: section.host, id: "" })
      }
      TextLink {
        Layout.alignment: Qt.AlignVCenter
        text: "Uninstall…"
        tooltip: "See what uninstalling the engine from " + section.machine + " would change, then do it in a terminal  (u)"
        onClicked: section.actionRequested({ type: "uninstall", host: section.host })
      }
      TextLink {
        Layout.alignment: Qt.AlignVCenter
        text: "Forget"
        tooltip: "Take " + section.machine + " off this list; nothing on it changes  (f)"
        onClicked: section.actionRequested({ type: "forget", host: section.host })
      }
    }
  }

  // Its models; an away machine's last known ones, dimmed.
  Repeater {
    model: section.ids
    delegate: ModelRow {
      id: modelRow
      required property string modelData
      Layout.fillWidth: true
      Layout.leftMargin: Style.spacing.xxl
      entry: section.entryOf(modelData)
      pending: section.pending[section.host + "/" + modelData] || ""
      nowMs: section.nowMs
      away: section.away
      current: section.cursorKey === section.host + "/" + modelData
      onCurrentChanged: if (current) section.revealRequested(modelRow)
      onSelectRequested: section.selectRequested(section.host + "/" + modelRow.modelData)
      onToggleRequested: {
        const action = Model.keyAction("s", { kind: "model", host: section.host, id: modelRow.modelData }, modelRow.entry, modelRow.pending)
        section.selectRequested(section.host + "/" + modelRow.modelData)
        if (action) section.actionRequested(action)
      }
      onLogsRequested: section.actionRequested({ type: "logs", host: section.host, id: modelRow.modelData })
      onRemoveRequested: {
        section.selectRequested(section.host + "/" + modelRow.modelData)
        section.actionRequested({ type: "removeModel", host: section.host, id: modelRow.modelData })
      }
    }
  }

  // Add model…: opens the machine's model picker. Only on a machine that answers, which has a catalog to show.
  Rectangle {
    id: addRow
    readonly property bool current: section.cursorKey === section.host + "#add"
    visible: section.loaded && !section.away
    Layout.fillWidth: true
    Layout.leftMargin: Style.spacing.xxl
    implicitHeight: addText.implicitHeight + Style.spacing.md * 2
    radius: Math.max(Style.cornerRadius, Style.space(6))
    color: addHover.hovered || addRow.current ? Util.alpha(Color.foreground, 0.06) : "transparent"
    border.width: Style.normalBorderWidth
    border.color: addRow.current ? Util.alpha(Color.accent, 0.7) : Util.alpha(Color.foreground, 0.10)
    onCurrentChanged: if (current) section.revealRequested(addRow)
    HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
      anchors.fill: parent
      onClicked: {
        section.selectRequested(section.host + "#add")
        section.actionRequested({ type: "addModel", host: section.host })
      }
    }
    Text {
      id: addText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.xxl
      anchors.rightMargin: Style.spacing.lg
      textFormat: Text.PlainText
      text: "+  Add model…"
      color: addHover.hovered || addRow.current ? Color.foreground : Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    PanelToolTip {
      visible: addHover.hovered
      text: "Choose a model from " + section.machine + "'s catalog and set it up there  (a)"
    }
  }
}
