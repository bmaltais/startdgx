// A machine's Add recipe card, over the manager: adds a recipe you wrote (a .toml on this computer) to the machine's
// catalog. The path is handed to `startdgx recipe validate` and, when it passes, `recipe add`, which send the file to the
// machine's engine; every error the engine finds is a row of its own and nothing is added until there are none. Under it,
// the machine's own recipes with where their numbers come from, and Remove, which the engine refuses while a model uses
// the recipe. Enter adds, Esc drops the typed path and then closes the card.
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
  property string path: ""

  readonly property var dgx: card.svc.dgx
  readonly property bool mine: card.dgx.recipeHost === card.host
  readonly property var result: card.mine ? card.dgx.recipeResult : null
  readonly property string failure: card.mine ? card.dgx.recipeError : ""
  readonly property string step: card.mine ? card.dgx.recipeStep : ""
  readonly property string problem: pathField.text.trim() === "" ? "" : Model.recipePathProblem(pathField.text)
  readonly property bool ready: Model.recipePathProblem(pathField.text) === "" && !card.dgx.recipeBusy
  readonly property var recipes: card.mine ? card.dgx.userRecipes : null
  readonly property int shownErrors: 8

  function go(thenAdd) {
    if (card.ready) card.dgx.checkRecipe(card.host, pathField.text, thenAdd)
  }

  Component.onCompleted: pathField.text = card.path
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
        text: "Add a recipe to " + Model.hostName(card.host)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.step === "checking" ? "ASKING THE MACHINE TO CHECK IT…" : card.step === "adding" ? "ADDING IT…"
          : card.result && !card.result.ok ? (card.result.errors.length === 1 ? "1 THING TO FIX" : card.result.errors.length + " THINGS TO FIX")
          : "A RECIPE FILE FROM THIS COMPUTER"
        color: card.result && !card.result.ok ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Type the path to a .toml recipe. Its name without .toml is the recipe's id. The machine checks it first and adds it only if there is nothing to fix."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    TextField {
      id: pathField
      Layout.fillWidth: true
      focus: true
      placeholderText: "~/recipes/my-model.toml"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      onAccepted: card.go(true)
      // Esc drops what was typed first, then closes the card.
      Keys.onEscapePressed: event => {
        if (pathField.text !== "") { pathField.text = ""; event.accepted = true }
        else event.accepted = false
      }
    }

    Text {
      Layout.fillWidth: true
      visible: card.problem !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.problem
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // The machine could not be asked, or the file could not be read.
    Text {
      Layout.fillWidth: true
      visible: card.failure !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.failure
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.result !== null && card.result.ok
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.result && card.result.ok ? card.result.message + (card.result.added ? "" : ". Add puts it in the catalog.") : ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // Each error the engine found, on its own row.
    Repeater {
      model: card.result && !card.result.ok ? card.result.errors.slice(0, card.shownErrors) : []
      delegate: Rectangle {
        id: errorRow
        required property string modelData
        Layout.fillWidth: true
        implicitHeight: errorText.implicitHeight + Style.spacing.md * 2
        radius: Math.max(Style.cornerRadius, Style.space(6))
        color: Util.alpha(Color.urgent, 0.10)
        Text {
          id: errorText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.lg
          anchors.rightMargin: Style.spacing.lg
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: errorRow.modelData
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
    Text {
      Layout.fillWidth: true
      visible: card.result !== null && !card.result.ok && card.result.errors.length > card.shownErrors
      text: card.result ? "and " + (card.result.errors.length - card.shownErrors) + " more" : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // The machine's own recipes.
    Text {
      text: "YOUR RECIPES ON THIS MACHINE"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      Layout.fillWidth: true
      visible: card.recipes !== null && card.recipes.length === 0 && card.dgx.userRecipesError === ""
      text: "None yet."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: card.mine && card.dgx.userRecipesError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.userRecipesError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Repeater {
      model: card.recipes || []
      delegate: RowLayout {
        id: recipeRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.spacing.lg
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: String(recipeRow.modelData.name || recipeRow.modelData.id)
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: recipeRow.modelData.id + " · " + Model.recipeMarks(recipeRow.modelData).join(" · ")
            color: recipeRow.modelData.source === "drafted" ? Color.muted : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        TextLink {
          Layout.alignment: Qt.AlignVCenter
          text: card.dgx.recipeRemoving === recipeRow.modelData.id ? "Removing…" : "Remove"
          tooltip: "Take this recipe off " + Model.hostName(card.host) + ". The machine refuses while a model set up from it is there"
          onClicked: card.dgx.removeRecipe(card.host, recipeRow.modelData.id)
        }
      }
    }
    // Why a removal was refused: the engine's own words.
    Text {
      Layout.fillWidth: true
      visible: card.mine && card.dgx.recipeRemoveError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.recipeRemoveError
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
        text: "Enter to add · Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: "Check only"
        opacity: card.ready ? 1 : 0.4
        onClicked: card.go(false)
      }
      SettingsPill {
        text: "Add"
        primary: true
        opacity: card.ready ? 1 : 0.4
        onClicked: card.go(true)
      }
    }
  }
}
