// One machine: its name, what it is, whether it answers (and why not), the gear that opens its settings window (logs,
// update, the model store, uninstall, forget), its models and, on a machine that answers, an Add model… row that opens its model picker. The manager owns the cursor and every decision; this file only paints and passes on
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
  property var pending: ({})          // "host/model" -> "start" | "stop" | "delete", "host/model#share" -> "share" | "unshare"
  property real nowMs: 0
  property string cursorKey: ""       // the row under the keyboard cursor: "host", "host/model" or "host#add"
  property var storage: null          // `startdgx storage` (DgxModel.parseStorage), or null until read
  property bool needsSetup: false     // a setup failed for want of the machine's one-time root setup: offer Install…

  signal selectRequested(string key)
  signal actionRequested(var action)
  signal revealRequested(var item)     // the row under the cursor, to scroll into sight

  readonly property bool loaded: !!section.hostState && section.hostState.loaded
  readonly property var update: Model.engineUpdate(section.hostState ? section.hostState.status : null)
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

      ColumnLayout {
        id: headText
        // The lines under the name start under it, clear of the dot.
        readonly property real indent: Style.space(8) + Style.spacing.lg
        Layout.fillWidth: true
        spacing: 0
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          // The dot sits on the name's line, also when lines of status follow it.
          Rectangle {
            Layout.preferredWidth: Style.space(8)
            Layout.preferredHeight: Style.space(8)
            Layout.rightMargin: Style.spacing.lg - Style.spacing.md
            Layout.alignment: Qt.AlignVCenter
            radius: width / 2
            color: !section.loaded ? Util.alpha(Color.foreground, 0.35) : section.away ? Color.urgent : Color.accent
          }
          Text {
            // As wide as the name, and cut when the row is narrower, so it never runs under the gear.
            Layout.fillWidth: true
            Layout.maximumWidth: Math.ceil(implicitWidth)
            textFormat: Text.PlainText
            text: section.machine
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            // Takes what the name leaves.
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            textFormat: Text.PlainText
            // The SSH target, when it says more than the name (a user).
            text: [section.host !== section.machine ? section.host : "", Model.hostLine(section.profile)].filter(function (s) { return s !== "" }).join(" · ")
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        Text {
          Layout.fillWidth: true
          Layout.leftMargin: headText.indent
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
        Text {
          Layout.fillWidth: true
          Layout.leftMargin: headText.indent
          visible: section.update !== null
          textFormat: Text.PlainText
          text: section.update ? section.update.text + ". Update it in the machine's settings." : ""
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
        Text {
          Layout.fillWidth: true
          Layout.leftMargin: headText.indent
          visible: section.needsSetup
          textFormat: Text.PlainText
          text: "A model can't be set up here until the machine has its one-time root setup: Install… in its settings runs it."
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
      }

      // Update, Install, Logs, Uninstall, Forget and the model store are behind the gear.
      Button {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\uf013"
        tooltipText: "Settings…  (g)"
        onClicked: section.actionRequested({ type: "hostSettings", host: section.host })
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
      pending: section.pending[Model.modelKey(section.host, modelData)] || ""
      nowMs: section.nowMs
      away: section.away
      location: Model.locationOf(section.storage, modelData)
      store: section.storage ? section.storage.store : null
      current: section.cursorKey === Model.modelKey(section.host, modelData)
      onCurrentChanged: if (current) section.revealRequested(modelRow)
      onSelectRequested: section.selectRequested(Model.modelKey(section.host, modelRow.modelData))
      onToggleRequested: {
        const action = Model.keyAction("s", { kind: "model", host: section.host, id: modelRow.modelData }, modelRow.entry, modelRow.pending)
        section.selectRequested(Model.modelKey(section.host, modelRow.modelData))
        if (action) section.actionRequested(action)
      }
      onLogsRequested: section.actionRequested({ type: "logs", host: section.host, id: modelRow.modelData })
      onSettingsRequested: {
        section.selectRequested(Model.modelKey(section.host, modelRow.modelData))
        section.actionRequested({ type: "modelSettings", host: section.host, id: modelRow.modelData })
      }
      onRemoveRequested: {
        section.selectRequested(Model.modelKey(section.host, modelRow.modelData))
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
