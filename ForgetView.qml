// A machine's forget card, over the manager: the question before `startdgx forget`, which takes the machine off
// this list and changes nothing on it. Enter or Forget forgets it; Esc, Keep it or a click outside close the card
// and nothing happens. So no single key forgets a machine.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""

  readonly property string machine: Model.hostName(card.host)

  function confirm() { card.svc.dispatch({ type: "forgetNow", host: card.host }) }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // A held Enter (from the manager's row) must not answer the question.
      if (!event.isAutoRepeat) card.confirm()
      event.accepted = true
    }
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
        text: "Forget " + card.machine + "?"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: "TAKE IT OFF THIS LIST"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "This takes " + card.host + " off this list. Nothing on the machine changes: its engine and models stay, and Add machine can add it again. Uninstall… is what takes the engine off it."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Item { Layout.fillHeight: true }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Enter to forget · Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: "Keep it"
        onClicked: card.svc.closeCard()
      }
      SettingsPill {
        text: "Forget"
        danger: true
        onClicked: card.confirm()
      }
    }
  }
}
