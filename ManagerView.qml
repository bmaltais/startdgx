// The manager: your machines, the models on each and what they are doing, and a way to add more. Opened from
// the launcher or the bar icon. Keyboard: Up/Down (or j/k) move, Enter or s starts or stops the model under the
// cursor, l opens its logs, u uninstalls the machine, f forgets it, n adds a machine, r looks again. Esc closes.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: view

  property var svc
  property int cursor: 0

  signal escapePressed()

  readonly property var dgx: view.svc.dgx
  readonly property var rows: view.dgx.rows
  readonly property var summary: view.dgx.summary
  readonly property var currentRow: view.rows.length ? view.rows[Math.min(view.cursor, view.rows.length - 1)] : null
  readonly property string cursorKey: !view.currentRow ? "" : view.currentRow.kind === "host" ? view.currentRow.host : view.currentRow.host + "/" + view.currentRow.id

  // The manager's clock, for the load and stop bars and "last seen": four times a second while a bar moves,
  // every few seconds otherwise.
  property real nowMs: Date.now()
  Timer {
    interval: view.summary.busy > 0 ? 250 : 5000
    running: view.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: view.nowMs = Date.now()
  }

  function move(dy) { view.cursor = Math.max(0, Math.min(view.rows.length - 1, view.cursor + dy)) }
  function focusList() { view.forceActiveFocus() }
  function select(key) {
    for (let i = 0; i < view.rows.length; i++) {
      const r = view.rows[i]
      if ((r.kind === "host" ? r.host : r.host + "/" + r.id) === key) view.cursor = i
    }
    view.forceActiveFocus()
  }
  function keyFor(key) {
    return Model.keyAction(key, view.currentRow,
      view.currentRow && view.currentRow.kind === "model" ? view.dgx.entry(view.currentRow.host, view.currentRow.id) : null,
      view.currentRow && view.currentRow.kind === "model" ? view.dgx.pending[view.cursorKey] || "" : "")
  }
  // Keeps the row under the cursor in sight.
  function reveal(item) {
    if (!item) return
    const top = item.mapToItem(flick.contentItem, 0, 0).y
    if (top < flick.contentY) flick.contentY = top
    else if (top + item.height > flick.contentY + flick.height) flick.contentY = top + item.height - flick.height
  }

  onVisibleChanged: if (visible) { view.cursor = 0; view.forceActiveFocus() }
  onRowsChanged: view.cursor = Math.max(0, Math.min(view.cursor, view.rows.length - 1))

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    if (event.key === Qt.Key_Escape) { view.escapePressed(); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { view.move(-1); event.accepted = true }
    else if (event.key === Qt.Key_Down || event.text === "j") { view.move(1); event.accepted = true }
    else {
      const key = event.key === Qt.Key_Return || event.key === Qt.Key_Enter ? "enter" : event.text
      if (key === "") return
      const action = view.keyFor(key)
      if (action) { view.svc.dispatch(action); event.accepted = true }
    }
  }

  ColumnLayout {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.panelGap

    // Header
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxl

      Image {
        source: Qt.resolvedUrl(Color.menu.background.hslLightness >= 0.5 ? "assets/local-light.svg" : "assets/local.svg")
        sourceSize.width: Style.space(64)
        sourceSize.height: Style.space(64)
        Layout.preferredWidth: Style.space(32)
        Layout.preferredHeight: Style.space(32)
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          text: "StartDGX"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: Model.subtitle(view.summary)
          color: view.summary.kind === "alert" ? Color.urgent : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }
      }
      Button {
        iconText: "\uf021"
        tooltipText: "Look at the machines again  (r)"
        iconSpinning: spin.running
        onClicked: { spin.restart(); view.svc.dispatch({ type: "refresh" }) }
        Timer { id: spin; interval: 900 }
      }
      // Keeps clear of the close button in the card's corner.
      Item { Layout.preferredWidth: Style.space(24) }
    }

    Text {
      text: "MACHINES"
      visible: view.dgx.hostList.length > 0
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    // The machines, with a scroll bar when they don't fit.
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: flick.contentHeight
      visible: view.dgx.hostList.length > 0
      spacing: Style.spacing.md

      Flickable {
        id: flick
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: contentHeight
        clip: true
        contentHeight: hostColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: hostColumn
          width: flick.width
          spacing: Style.spacing.xxl

          Repeater {
            model: view.dgx.hostList
            delegate: HostSection {
              required property string modelData
              Layout.fillWidth: true
              host: modelData
              profile: (view.dgx.hosts[modelData] || {}).profile || ({})
              hostState: view.dgx.hostState[modelData] || null
              pending: view.dgx.pending
              nowMs: view.nowMs
              cursorKey: view.cursorKey
              onSelectRequested: key => view.select(key)
              onActionRequested: action => view.svc.dispatch(action)
              onRevealRequested: item => view.reveal(item)
            }
          }
        }
      }

      ScrollTrack {
        target: flick
        Layout.fillHeight: true
        Layout.preferredWidth: implicitWidth
      }
    }

    // Nothing added yet: say how to begin.
    Text {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: view.dgx.loaded && view.dgx.hostList.length === 0
      wrapMode: Text.WordWrap
      text: "No machines yet. Add machine looks for DGX Sparks on your tailnet and sets one up, or adds one that already runs the engine."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Footer: add on the left, the latest message or a hint on the right.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxl

      Button {
        text: "+  Add machine…"
        bordered: true
        tooltipText: "Find DGX Sparks on your tailnet  (n)"
        onClicked: view.svc.dispatch({ type: "addMachine" })
      }
      Text {
        Layout.fillWidth: true
        Layout.rightMargin: Style.space(20)
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: view.svc.notice !== "" ? view.svc.notice : "Esc to close"
        color: view.svc.notice !== "" && view.svc.noticeIsError ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
