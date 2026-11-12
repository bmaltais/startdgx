// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component ProviderSection), MIT,
// Copyright (c) David Heinemeier Hansson: the model's mark and name with its endpoint on hover, the play/pause
// button (greyed out, with the reason, when it doesn't fit), the meter row (downloading, loading, stopping,
// removing, memory) that fills to the end before it changes over, and the error that links to the logs.
// One model on one machine. The manager owns the cursor and every decision; this file only paints and says
// what was asked for. Names and errors come from the host and are drawn as plain text.
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

  signal toggleRequested()
  signal logsRequested()
  signal removeRequested()
  signal selectRequested()

  readonly property var modelState: Model.modelState(row.entry, row.pending)
  readonly property string kind: row.modelState.kind
  readonly property string toggle: Model.toggleAction(row.entry, row.pending) || ""   // "start", "stop" or "" (none)
  readonly property bool blocked: Model.startBlocked(row.entry)
  readonly property string removal: Model.removeAction(row.entry, row.pending) || ""   // "remove", "cancel" or "" (none)
  readonly property var bar: Model.meter(row.entry, row.nowMs, row.pending)
  readonly property string facts: Model.modelFacts(row.entry)
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

  implicitHeight: body.implicitHeight + Style.spacing.lg * 2
  radius: Math.max(Style.cornerRadius, Style.space(6))
  color: Util.alpha(Color.foreground, row.hot ? 0.10 : 0.05)
  border.width: Style.normalBorderWidth
  border.color: row.current ? Util.alpha(Color.accent, 0.7) : Util.alpha(Color.foreground, 0.06)
  opacity: row.away ? 0.55 : 1

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
        spacing: Style.spacing.xxs

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: String(row.entry.name || row.entry.recipe || "")
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          HoverHandler { id: nameHover }
          PanelToolTip {
            // A setup has no endpoint until its model first starts.
            visible: nameHover.hovered && String(row.entry.endpoint || "") !== ""
            text: String(row.entry.endpoint || "") + " · model " + String(row.entry.recipe || "")
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Rectangle {
            id: dot
            Layout.preferredWidth: Style.space(7)
            Layout.preferredHeight: Style.space(7)
            radius: width / 2
            color: row.kind === "failed" ? Color.urgent
              : row.kind === "running" || row.kind === "loading" || row.kind === "installing" ? Color.accent
              : Util.alpha(Color.foreground, 0.35)
            SequentialAnimation on opacity {
              running: !row.away && (row.kind === "loading" || row.kind === "stopping" || row.kind === "removing" || row.kind === "installing")
              loops: Animation.Infinite
              onRunningChanged: if (!running) dot.opacity = 1
              NumberAnimation { to: 0.25; duration: 500 }
              NumberAnimation { to: 1; duration: 500 }
            }
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            // A failure's reason has its own line, which links to the logs.
            text: (row.kind === "failed" ? (row.entry.unit === "installing" ? "Setup failed" : "Failed") : row.modelState.text)
              + (row.facts !== "" ? "  ·  " + row.facts : "")
            color: row.kind === "failed" ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }

      // Opens this model's logs in a terminal.
      Button {
        Layout.alignment: Qt.AlignVCenter
        visible: !row.away && row.entry.unit !== "installing"
        iconText: "\udb80\udd8d"
        tooltipText: "Logs…  (l)"
        onClicked: row.logsRequested()
      }

      // Remove (or cancel a setup), after a question in a card.
      Button {
        Layout.alignment: Qt.AlignVCenter
        visible: !row.away && row.removal !== ""
        iconText: row.removal === "cancel" ? "\uf00d" : "\uf1f8"
        tooltipText: row.removal === "cancel" ? "Cancel the setup…  (d)" : "Remove…  (d)"
        // Quiet: a destructive action is never the loudest thing on the row.
        foreground: Color.muted
        onClicked: row.removeRequested()
      }

      // Start or stop. Greyed out, not disabled, so the reason still shows on hover.
      Button {
        id: toggleButton
        Layout.alignment: Qt.AlignVCenter
        visible: !row.away && (row.toggle !== "" || row.blocked)
        iconText: row.toggle === "stop" ? "\udb80\udfe4" : "\udb81\udc0a"
        tooltipText: row.blocked ? String(row.entry.fit_reason || "") || "Not enough memory"
          : row.toggle === "stop" ? "Stop  (s)" : "Start  (s)"
        foreground: row.blocked ? Color.muted : Color.foreground
        opacity: row.blocked ? 0.5 : 1
        onClicked: if (!row.blocked) row.toggleRequested()
        PanelToolTip {
          // The keyboard cursor landing on a greyed-out start says why too.
          visible: row.blocked && row.current
          text: toggleButton.tooltipText
        }
      }
    }

    // Under the model: its download while it is set up, progress while it loads, stops or is removed (against
    // how long that took last time), memory while it runs.
    RowLayout {
      Layout.fillWidth: true
      visible: row.shownBar !== null && !row.away
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
          text: row.kind === "installing" && row.entry.install ? Model.downloadAmount(Number(row.entry.install.done_bytes) || 0, Number(row.entry.install.total_bytes) || 0) : ""
        }
      }
      Text {
        // A fixed width, so the bars of all rows end in line.
        Layout.preferredWidth: Style.space(96)
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        text: row.shownBar ? row.shownBar.value : ""
        color: Color.muted
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
