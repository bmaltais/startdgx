// A model's remove card, over the manager: the question before `startdgx delete`, which stops the model if it
// runs and deletes its weights (or, for a setup in progress, cancels it and deletes what it downloaded). It first
// asks the machine how much space that frees (`delete HOST MODEL --dry-run --json`, which changes nothing); the
// Remove pill waits for that answer, and goes ahead without the figure if the machine can't give it. Enter
// removes, Esc, Keep it or a click outside close the card and nothing happens.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  property string model: ""

  readonly property var dgx: card.svc.dgx
  readonly property var entry: card.dgx.entry(card.host, card.model)
  readonly property string action: Model.removeAction(card.entry, card.dgx.pending[card.host + "/" + card.model] || "") || ""
  readonly property bool mine: card.dgx.removeHost === card.host && card.dgx.removeId === card.model
  readonly property bool failed: card.mine && !card.dgx.removePlanning && card.dgx.removeError !== ""
  readonly property bool ready: card.mine && !card.dgx.removePlanning && (card.dgx.removeBytes >= 0 || card.failed)
  readonly property var words: card.entry ? Model.removeConfirm(card.entry, card.host, card.ready && !card.failed ? card.dgx.removeBytes : null, card.failed)
    : ({ title: "", body: "", button: "Remove", keep: "Keep it" })

  // The model went (removed elsewhere), or can't be removed now (it began stopping): nothing to ask. A setup
  // that finished meanwhile frees another amount, so the machine is asked again. After the change has settled,
  // not while the binding that saw it is being worked out.
  property string planned: ""
  Component.onCompleted: card.planned = card.action
  onActionChanged: Qt.callLater(card.follow)
  function follow() {
    if (card.action === "") { card.svc.closeCard(); return }
    if (card.planned !== "" && card.planned !== card.action) card.dgx.planRemove(card.host, card.model)
    card.planned = card.action
  }

  function confirm() {
    if (card.ready && card.action !== "") card.svc.dispatch({ type: "removeNow", host: card.host, id: card.model })
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { card.confirm(); event.accepted = true }
  }

  ColumnLayout {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.panelGap

    ColumnLayout {
      Layout.fillWidth: true
      Layout.rightMargin: Style.space(32)
      spacing: 0
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: card.words.title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.mine && card.dgx.removePlanning ? "ASKING THE MACHINE WHAT IT FREES…"
          : card.failed ? "HOW MUCH IT FREES IS UNKNOWN" : card.action === "cancel" ? "WHAT CANCELLING DELETES" : "WHAT REMOVING FREES"
        color: card.failed ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.words.body
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Why the machine couldn't say: the removal can still go ahead.
    Text {
      Layout.fillWidth: true
      visible: card.failed
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.removeError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Item { Layout.fillHeight: true }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Enter to " + card.words.button.toLowerCase() + " · Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: card.words.keep
        onClicked: card.svc.closeCard()
      }
      SettingsPill {
        text: card.words.button
        danger: true
        // Only once the machine has answered.
        opacity: card.ready ? 1 : 0.4
        onClicked: card.confirm()
      }
    }
  }
}
