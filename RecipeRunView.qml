// The confirmation card for a recipe of yours, over the manager: before the machine downloads what the recipe names and
// runs it, either to measure one of its variants (`recipe measure --yes`) or to set it up (`use --yes`). It first asks the
// machine what that would do (`recipe measure HOST ID --ctx N` without --yes, which changes nothing) and shows the
// engine's own lines, the download first. Only the pill, or Enter, once that has been read, says go; Esc, Keep it or a
// click outside close the card and nothing happens.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  property string mode: "measure"
  property var recipe: ({})
  property int ctx: 0

  readonly property var dgx: card.svc.dgx
  readonly property bool mine: card.dgx.runHost === card.host && card.dgx.runId === card.recipe.id && card.dgx.runCtx === card.ctx
  readonly property bool failed: card.mine && !card.dgx.runPlanning && card.dgx.runError !== ""
  readonly property bool ready: card.mine && !card.dgx.runPlanning && card.dgx.runPlan !== null
  readonly property var words: Model.recipeRunWords(card.mode, card.recipe, card.ctx, Model.hostName(card.host))

  function confirm() {
    if (!card.ready) return
    card.svc.dispatch(card.mode === "measure"
      ? { type: "measureNow", host: card.host, recipe: card.recipe, ctx: card.ctx }
      : { type: "setupNow", host: card.host, recipe: card.recipe })
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

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
        text: card.words.title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.mine && card.dgx.runPlanning ? "ASKING THE MACHINE WHAT IT WOULD DO…"
          : card.failed ? "WHAT IT WOULD DO IS UNKNOWN" : "WHAT THE MACHINE WOULD DO"
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

    // The engine's own lines: the download, what it loads, what follows.
    Repeater {
      model: card.mine && card.dgx.runPlan ? card.dgx.runPlan : []
      delegate: Text {
        required property string modelData
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: modelData
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Why the machine couldn't say: nothing goes ahead without its answer.
    Text {
      Layout.fillWidth: true
      visible: card.failed
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.runError
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
        text: "Not now"
        onClicked: card.svc.closeCard()
      }
      SettingsPill {
        text: card.words.button
        primary: true
        // Only once the machine has said what it would do.
        opacity: card.ready ? 1 : 0.4
        onClicked: card.confirm()
      }
    }
  }
}
