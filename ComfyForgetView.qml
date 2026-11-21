// A ComfyUI install's forget card, over the manager: the question before `startdgx comfyui forget`, which takes the install off the
// list and changes nothing in its folder. A background service it set up (it starts at boot) stays unless the switch says to remove
// it too. Enter or Forget forgets it; Esc, Keep it or a click outside close the card and nothing happens.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  property string path: ""
  property bool removeService: false

  readonly property var dgx: card.svc.dgx
  readonly property var info: Model.comfyRow((card.dgx.comfyui[card.host] || []).filter(function (i) { return i.path === card.path })[0] || { path: card.path }, null)
  // Known once the install's own status has been read: only an install with a service has one to remove.
  readonly property var answer: card.dgx.comfyStatusKey === card.host + "\n" + card.path ? card.dgx.comfyStatus : null
  readonly property bool hasService: !!(card.answer && card.answer.status && card.answer.status.service && card.answer.status.service.installed)

  function confirm() { card.svc.dispatch({ type: "comfyForgetNow", host: card.host, path: card.path, stopService: card.hasService && card.removeService }) }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2
  Component.onCompleted: if (card.dgx.comfyStatusKey !== card.host + "\n" + card.path) card.dgx.comfyStatusFor(card.host, card.path)

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // A held Enter must not answer the question.
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
        text: "Forget " + card.info.name + "?"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: "STOP MANAGING THIS INSTALL"
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "startdgx stops managing " + card.path + " on " + Model.hostName(card.host) + ". The folder, its models and its workflows are not touched, and Find existing ComfyUI… can adopt it again. A ComfyUI that is running keeps running."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    SwitchRow {
      Layout.fillWidth: true
      visible: card.hasService
      label: "Remove its background service too"
      description: "It stops, and no longer starts when the machine boots. Otherwise the service stays."
      checked: card.removeService
      onClicked: card.removeService = !card.removeService
    }

    Item { Layout.fillHeight: true }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Enter to forget · Esc to close"
        color: Tones.muted
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
