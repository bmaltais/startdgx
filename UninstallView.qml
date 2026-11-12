// A machine's uninstall card, over the manager. `startdgx launch uninstall` starts the real uninstall at once,
// so this card is the confirmation: it shows the plan first (`uninstall HOST --dry-run --json`, which changes
// nothing), and only its Uninstall… button opens the terminal that does it, where sudo asks for the machine's password.
// Two opt-ins, off by default, are asked for where they would do something (DgxModel.uninstallChoices): deleting the
// model weights (--delete-models) and removing the packages the install added (--remove-packages). Each change asks
// the machine for the plan again, and Uninstall… waits for it. Esc, Cancel or a click outside closes it and nothing
// happens.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  // The opt-ins chosen, as the CLI's flags.
  property var flags: []

  readonly property var dgx: card.svc.dgx
  readonly property bool planRead: card.dgx.planKey === [card.host].concat(card.flags).join(" ") && !card.dgx.planning
    && card.dgx.planError === "" && card.dgx.uninstallPlan !== null
  // The opt-ins the machine offers; they don't depend on the flags, so they stay while the plan is asked again.
  property var choices: []
  readonly property var plan: card.dgx.planHost === card.host ? card.dgx.uninstallPlan : null
  onPlanChanged: if (card.plan) card.choices = Model.uninstallChoices(card.plan)

  function toggle(flag) {
    card.flags = card.flags.indexOf(flag) >= 0 ? card.flags.filter(function (f) { return f !== flag }) : card.flags.concat([flag])
    card.dgx.plan(card.host, card.flags)
  }

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

    // The plan, as the CLI's dry run says it.
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: Math.min(planFlick.contentHeight, Style.space(280))
      visible: card.plan !== null || card.dgx.planError !== ""
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
          text: card.dgx.planError !== "" ? card.dgx.planError : card.plan ? Model.uninstallText(card.plan) : ""
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

    // The opt-ins, off by default.
    Repeater {
      model: card.choices
      delegate: Toggle {
        required property var modelData
        Layout.fillWidth: true
        label: modelData.label
        description: modelData.description
        checked: card.flags.indexOf(modelData.flag) >= 0
        onClicked: card.toggle(modelData.flag)
      }
    }

    Text {
      Layout.fillWidth: true
      wrapMode: Text.Wrap
      text: "The uninstall runs in a terminal, where sudo asks for the machine's password."
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
        // Only once the plan for these opt-ins has been seen.
        enabled: card.planRead
        opacity: card.planRead ? 1 : 0.4
        onClicked: if (card.planRead) card.svc.dispatch({ type: "uninstallNow", host: card.host, flags: card.flags })
      }
    }
  }
}
