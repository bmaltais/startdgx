// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component ProviderSection), MIT,
// Copyright (c) David Heinemeier Hansson: the model's mark and name with its endpoint on hover, the play/pause
// button (greyed out, with the reason, when it doesn't fit), the meter row (downloading, loading, stopping,
// removing, memory) that fills to the end before it changes over, and the error that links to the logs.
// One model on one machine. The manager owns the cursor and every decision; this file only paints and says
// what was asked for. Names and errors come from the host and are drawn as plain text.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

Rectangle {
  id: row

  property var entry: ({})           // the model's row of the host's status
  property string pending: ""        // "start" or "stop" while a click waits for the host
  property real nowMs: 0             // the manager's clock, for the progress bars
  property bool current: false       // under the keyboard cursor
  property bool away: false          // the machine isn't answering: its last known state, dimmed, no actions
  property string location: ""       // where its files are (nvme, usb, both, usb-missing, mixed), "" until the host's storage is read
  property var store: null           // the host's model store ({ path, present }) or null: no store, no location and no move

  signal toggleRequested()
  signal removeRequested()
  signal logsRequested()
  signal settingsRequested()
  signal selectRequested()
  signal updateRequested()

  readonly property var modelState: Model.modelState(row.entry, row.pending)
  readonly property string kind: row.modelState.kind
  readonly property string toggle: Model.toggleAction(row.entry, row.pending) || ""   // "start", "stop" or "" (none)
  // An update the machine's catalog has for it (nothing while it updates, is set up or removed): a link beside the name.
  readonly property var updateOffer: row.away ? null : Model.updateOffer(row.entry, row.pending)
  readonly property bool blocked: Model.startBlocked(row.entry)
  readonly property string removal: Model.removeAction(row.entry, row.pending) || ""   // "remove", "cancel" or "" (none)
  readonly property var bar: Model.meter(row.entry, row.nowMs, row.pending)
  // What it is doing, its context and memory, where its files are (only a host with a store says) and Shared.
  readonly property string line: Model.modelLine(row.entry, row.pending, row.store ? row.location : "")
  readonly property string title: String(row.entry.name || row.entry.recipe || "")
  readonly property bool hot: hover.hovered || row.current

  // When a load or stop ends, its bar fills to the end before the row changes over, rather than vanishing near 90%.
  property string finishing: ""
  onKindChanged: {
    const loaded = row.lastKind === "loading" && row.kind === "running"
    const stopped = row.lastKind === "stopping" && (row.kind === "stopped" || row.kind === "doesNotFit")
    if (loaded || stopped) {
      row.finishing = loaded ? "Loading" : "Stopping"
      finishTimer.restart()
    }
    row.lastKind = row.kind
  }
  property string lastKind: ""
  Component.onCompleted: row.lastKind = row.kind
  Timer { id: finishTimer; interval: Style.duration(450); onTriggered: row.finishing = "" }
  readonly property var shownBar: row.finishing !== "" && !row.away ? { label: row.finishing, fraction: 1, value: "" } : row.bar

  // Flat: no card of its own, a hairline between rows; the hover and the keyboard cursor are what lift a row.
  readonly property bool wide: row.width >= Style.space(600)
  readonly property string stateWord: row.line.split(" \u00b7 ")[0].replace(/\u00a0/g, " ")
  readonly property var columns: Model.modelColumns(row.entry)
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

  // The status dot, beside the words that say the state.
  component StatusDot: Rectangle {
    id: dot
    required property string kind
    required property bool away
    Layout.preferredWidth: Style.space(7)
    Layout.preferredHeight: Style.space(7)
    radius: width / 2
    color: dot.kind === "failed" ? Color.urgent
      : dot.kind === "running" || dot.kind === "loading" || dot.kind === "installing" || dot.kind === "moving" ? Color.accent
      : Util.alpha(Color.foreground, 0.35)
    SequentialAnimation on opacity {
      running: !Style.reduceMotion && !dot.away && (dot.kind === "loading" || dot.kind === "stopping" || dot.kind === "removing" || dot.kind === "installing" || dot.kind === "moving")
      loops: Animation.Infinite
      onRunningChanged: if (!running) dot.opacity = 1
      NumberAnimation { to: 0.25; duration: 500 }
      NumberAnimation { to: 1; duration: 500 }
    }
  }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    onClicked: row.selectRequested()
  }

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xxl
    anchors.rightMargin: Style.spacing.lg
    spacing: Style.space(6)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)

      VendorIcon {
        Layout.alignment: Qt.AlignVCenter
        vendor: String(row.entry.vendor || "")
      }

      ColumnLayout {
        Layout.fillWidth: true
        // On a wide window the facts stay near the name instead of at the far edge; the buttons keep the edge.
        Layout.maximumWidth: row.wide ? Style.space(440) : Number.POSITIVE_INFINITY
        spacing: Style.spacing.xxs

        RowLayout {
         Layout.fillWidth: true
         spacing: Style.spacing.md
         Text {
          id: nameText
          // As wide as the name, so the shared mark sits against it; wraps when the row is narrower.
          Layout.fillWidth: true
          Layout.maximumWidth: Math.ceil(implicitWidth)
          textFormat: Text.PlainText
          text: row.title
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          // The machine's name is the bold one; a model's is plain, so the two levels read apart.
          // The name is the person's to read whole (a recipe of yours is named by you): it wraps, never cuts.
          wrapMode: Text.Wrap
          HoverHandler { id: nameHover }
          PanelToolTip {
            // A setup has no endpoint until its model first starts.
            visible: nameHover.hovered && text !== ""
            text: String(row.entry.endpoint || "") !== "" ? String(row.entry.endpoint) + " · model " + String(row.entry.recipe || "") : ""
          }
         }
         // Shared on the tailnet: a mark, not a word, so the name keeps the line.
         TailscaleMark {
          visible: row.entry.shared === true
          Layout.alignment: Qt.AlignVCenter
          iconSize: Style.space(13)
          color: Tones.muted
          HoverHandler { id: shareHover }
          PanelToolTip { visible: shareHover.hovered; text: "Shared with your tailnet" }
         }
         // Its recipe is retired (engine v0.14.0): it keeps working, so a quiet word, not a warning.
         Text {
          id: retiredText
          visible: text !== ""
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: Model.retiredMark(row.entry)
          color: Tones.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          HoverHandler { id: retiredHover }
          PanelToolTip { visible: retiredHover.hovered; text: Model.RETIRED_DETAIL }
         }
         // An update is waiting: the machine's catalog has moved on from what this model was set up with.
         TextLink {
          visible: row.updateOffer !== null
          Layout.alignment: Qt.AlignVCenter
          text: "Update"
          idleColor: Color.accent
          tooltip: row.updateOffer ? row.updateOffer.detail + ". The model keeps running until the new setup has started." : ""
          onClicked: row.updateRequested()
         }
         // Takes the room, so the name's own width limit doesn't shrink the column.
         Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: !row.wide
          spacing: Style.spacing.md
          StatusDot {
            // Beside the first line: the words wrap on a narrow row.
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Math.max(0, (lineMetrics.height - Style.space(7)) / 2)
            kind: row.kind
            away: row.away
          }
          Text {
            id: lineText
            Layout.fillWidth: true
            textFormat: Text.PlainText
            // A failure's reason has its own line, which links to the logs. A row too narrow for the words takes a
            // second line rather than cut them short beside the buttons; a third is cut, and whole on hover.
            // A break comes before a separator, never after one: the dot sticks to the fact that follows it.
            text: row.line.replace(/ · /g, " \u00b7\u00a0")
            color: row.kind === "failed" ? Color.urgent : Tones.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            FontMetrics { id: lineMetrics; font: lineText.font }
            HoverHandler { id: lineHover }
            PanelToolTip {
              visible: lineHover.hovered && lineText.truncated
              text: row.line
            }
          }
        }
      }

      // Wide: the facts as columns, so a number sits under the same kind of number on every row.
      RowLayout {
        visible: row.wide
        // A layout fills by default; this one is as wide as its column and no wider.
        Layout.fillWidth: false
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(132)
        spacing: Style.spacing.md
        StatusDot { kind: row.kind; away: row.away }
        Text {
          id: stateText
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: row.stateWord
          color: row.kind === "failed" ? Color.urgent : row.kind === "stopped" || row.kind === "doesNotFit" ? Tones.muted : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          HoverHandler { id: stateHover }
          PanelToolTip { visible: stateHover.hovered && stateText.truncated; text: row.stateWord }
        }
      }
      Text {
        visible: row.wide
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(48)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: row.columns.ctx
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.features: { "tnum": 1 }
        HoverHandler { id: ctxHover }
        PanelToolTip { visible: ctxHover.hovered && text !== ""; text: "Context size" }
      }
      Text {
        visible: row.wide
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(64)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: row.columns.size
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.features: { "tnum": 1 }
        HoverHandler { id: sizeHover }
        PanelToolTip { visible: sizeHover.hovered && text !== ""; text: row.kind === "running" ? "Memory it holds" : "Memory it took when it last ran" }
      }
      Text {
        visible: row.wide
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(84)
        textFormat: Text.PlainText
        text: Model.locationShort(row.store ? row.location : "")
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        HoverHandler { id: whereHover }
        PanelToolTip { visible: whereHover.hovered && text !== ""; text: Model.locationText(row.store ? row.location : "") }
      }

      // The room a wide window has left over, between the facts and the buttons.
      Item { visible: row.wide; Layout.fillWidth: true }

      // Everything else about the model (sharing, context size, logs, where its files are) is behind the gear.
      // The gear and the bin appear on the row under the pointer or the cursor (Start and Stop are always there).
      // The three buttons keep their places on every row: one that has nothing to do now is hidden, not taken away,
      // so the others don't move under the pointer and the rows' buttons stay in columns (each is as wide as it is tall,
      // whatever its glyph).
      Button {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: implicitHeight
        visible: !row.away
        opacity: row.hot ? 1 : 0
        foreground: Tones.muted
        iconText: "\uf013"
        tooltipText: row.hot ? "Settings…  (g)" : ""
        onClicked: row.settingsRequested()
      }

      // Remove (or cancel a setup), after a question in a card.
      Button {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: implicitHeight
        visible: !row.away
        opacity: row.removal !== "" && row.hot ? 1 : 0
        enabled: row.removal !== "" && row.hot
        iconText: row.removal === "cancel" ? "\uf00d" : "\uf1f8"
        // No tooltip while it is hidden: one already open would stay, over a button that isn't there.
        tooltipText: row.removal === "" || !row.hot ? "" : row.removal === "cancel" ? "Cancel the setup…  (d)" : "Remove…  (d)"
        // Quiet: a destructive action is never the loudest thing on the row.
        foreground: Tones.muted
        onClicked: row.removeRequested()
      }

      // Start or stop. Greyed out, not disabled, so the reason still shows on hover.
      Button {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: implicitHeight
        visible: !row.away
        enabled: row.toggle !== "" || row.blocked
        iconText: row.toggle === "stop" ? "\udb80\udfe4" : "\udb81\udc0a"
        tooltipText: row.blocked ? String(row.entry.fit_reason || "") || "Not enough memory"
          : row.toggle === "stop" ? "Stop  (s)" : row.toggle === "start" ? "Start  (s)" : ""
        foreground: row.blocked ? Tones.muted : Color.foreground
        opacity: !enabled ? 0 : row.blocked ? 0.5 : 1
        onClicked: if (!row.blocked) row.toggleRequested()
      }
    }

    // Under the model: its download while it is set up, progress while it loads, stops or is removed (against
    // how long that took last time).
    RowLayout {
      Layout.fillWidth: true
      // A running model's memory is in its Memory column and on the machine's bar, so it has no bar of its own;
      // the bar a load or stop just filled stays until it has finished filling.
      visible: row.shownBar !== null && !row.away && (row.kind !== "running" || row.finishing !== "")
      spacing: Style.space(12)
      Text {
        Layout.preferredWidth: Style.space(90)
        textFormat: Text.PlainText
        text: row.shownBar ? row.shownBar.label : ""
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Meter {
        id: meterBar
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        value: row.shownBar ? row.shownBar.fraction : 0
        // How much of a download has arrived, on hover. The bar is a few pixels tall, so its row answers the pointer.
        HoverHandler { id: meterHover }
        PanelToolTip {
          id: amountTip
          visible: meterHover.hovered && amountTip.text !== ""
          text: row.kind === "installing" && Model.modelDownload(row.entry) ? Model.downloadAmount(Number(Model.modelDownload(row.entry).done_bytes) || 0, Number(Model.modelDownload(row.entry).total_bytes) || 0) : ""
        }
      }
      Text {
        // A fixed width, so the bars of all rows end in line.
        Layout.preferredWidth: Style.space(96)
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.shownBar ? row.shownBar.value : ""
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Why it failed, which opens the logs.
    TextLink {
      Layout.fillWidth: true
      visible: row.kind === "failed" && !row.away
      text: row.kind === "failed" ? row.modelState.text : ""
      idleColor: Color.urgent
      hotColor: Color.urgent
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
      tooltip: "Open this model's logs in a terminal  (l)"
      onClicked: row.logsRequested()
    }
  }
}
