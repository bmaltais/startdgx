// A machine's uninstall card, over the manager. `startdgx launch uninstall` starts the real uninstall at once,
// so this card is the confirmation: it shows the plan first (`uninstall HOST --dry-run`, which changes nothing),
// and only its Uninstall… button opens the terminal that does it, where sudo asks for the machine's password.
// Esc, Cancel or a click outside closes it and nothing happens.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""

  readonly property var dgx: card.svc.dgx
  readonly property bool planned: card.dgx.planHost === card.host && !card.dgx.planning && card.dgx.planError === "" && card.dgx.planText !== ""

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
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
        elide: Text.ElideRight
        text: "Uninstall from " + Model.hostName(card.host)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.dgx.planning ? "ASKING THE MACHINE WHAT WOULD CHANGE…" : card.dgx.planError !== "" ? "NO PLAN" : "WHAT WOULD CHANGE"
        color: card.dgx.planError !== "" && !card.dgx.planning ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    // The plan, as the CLI prints it.
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: Math.min(planFlick.contentHeight, Style.space(320))
      visible: card.dgx.planText !== "" || card.dgx.planError !== ""
      spacing: Style.spacing.md

      Flickable {
        id: planFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentHeight: planText.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Text {
          id: planText
          width: planFlick.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: card.dgx.planError !== "" ? card.dgx.planError : card.dgx.planText
          color: card.dgx.planError !== "" ? Color.urgent : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
      ScrollTrack {
        target: planFlick
        Layout.fillHeight: true
        Layout.preferredWidth: implicitWidth
      }
    }

    Text {
      Layout.fillWidth: true
      wrapMode: Text.Wrap
      text: "The model weights are kept. The uninstall runs in a terminal, where sudo asks for the machine's password."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      SettingsPill {
        text: "Cancel"
        onClicked: card.svc.closeCard()
      }
      SettingsPill {
        text: "Uninstall…"
        danger: true
        // Only once the plan has been seen.
        enabled: card.planned
        opacity: card.planned ? 1 : 0.4
        onClicked: if (card.planned) card.svc.dispatch({ type: "uninstallNow", host: card.host })
      }
    }
  }
}
