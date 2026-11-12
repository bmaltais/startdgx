// A model's context card, over the manager: the context sizes its recipe has measured on the machine (`variants HOST
// MODEL --json`), the one it runs now, and what each needs. Choosing one restarts the model with it (the engine's
// `use --ctx`; a stopped model starts); one that needs more memory than the machine has is greyed out, with why. Esc,
// Keep it or a click outside close the card and nothing changes.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  property string model: ""

  readonly property var dgx: card.svc.dgx
  readonly property var entry: card.dgx.entry(card.host, card.model)
  readonly property string action: Model.contextAction(card.entry, card.dgx.pending[Model.modelKey(card.host, card.model)] || "") || ""
  readonly property bool mine: card.dgx.variantsHost === card.host && card.dgx.variantsId === card.model
  readonly property bool failed: card.mine && !card.dgx.variantsLoading && card.dgx.variantsError !== ""
  readonly property var status: (card.dgx.shownState[card.host] || {}).status || null
  readonly property var choices: card.mine && card.dgx.variants
    ? Model.contextChoices(card.dgx.variants, card.entry ? card.entry.ctx : 0, card.status ? card.status.ram_total_gib : 0) : []

  // The model went, or began something that changes it (a stop, a removal): nothing to ask.
  onActionChanged: Qt.callLater(function () { if (card.action === "") card.svc.closeCard() })

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
        wrapMode: Text.Wrap
        text: "Context size of " + String(card.entry ? card.entry.name || card.model : card.model)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.mine && card.dgx.variantsLoading ? "ASKING THE MACHINE WHICH CONTEXTS IT HAS MEASURED…"
          : card.failed ? "THE MEASURED CONTEXTS ARE UNKNOWN" : "ON " + Model.hostName(card.host).toUpperCase()
        color: card.failed ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      visible: card.failed
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.variantsError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: !card.failed
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Only the sizes the recipe has measured can run. Choosing one restarts the model with it, which interrupts requests in flight (a stopped model starts)."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: card.choices
      delegate: RowLayout {
        id: choice
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.spacing.lg
        opacity: choice.modelData.fits ? 1 : 0.5
        Text {
          Layout.preferredWidth: Style.space(48)
          text: choice.modelData.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: choice.modelData.text
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          visible: choice.modelData.current
          text: "Running with this"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        SettingsPill {
          visible: !choice.modelData.current
          text: "Use"
          opacity: choice.modelData.fits ? 1 : 0.4
          onClicked: if (choice.modelData.fits && card.action !== "") card.svc.dispatch({ type: "contextNow", host: card.host, id: card.model, ctx: choice.modelData.ctx })
        }
      }
    }

    Item { Layout.fillHeight: true }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: "Keep it"
        onClicked: card.svc.closeCard()
      }
    }
  }
}
