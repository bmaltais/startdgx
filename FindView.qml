// A machine's Find on Hugging Face card, over the manager: searches Hugging Face for MLX 4-bit models of a known family
// (`startdgx hf search --json`, run on this computer: it reaches no machine). Every row is a repo whose config.json was
// read: its parameters, license and base model, a mark on an abliterated or uncensored derivative (a toggle hides those),
// and the weights' size next to the machine's memory as two plain numbers. No row says it fits: only a measuring run does
// (docs/adr/0001). Draft recipe… on a row writes a drafted recipe for that repo and adds it to the machine through the Add recipe
// path; With an agent… opens a terminal where an agent finishes the recipe (`startdgx launch author`); its steps, warnings and any clash or validation error show under the toggle, line by line. Enter searches, Esc drops the typed query and then closes the card.
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
  property string query: ""

  readonly property var dgx: card.svc.dgx
  readonly property var hostState: card.dgx.shownState[card.host] || null
  readonly property real ramGib: card.hostState && card.hostState.status ? Number(card.hostState.status.ram_total_gib) || 0 : 0
  // Derivative-labelled rows are shown until the person hides them (the maintainer's decision, #31).
  property bool showDerivatives: true
  readonly property var rows: Model.hfShown(card.dgx.hfRows, card.showDerivatives)
  readonly property string toggleText: Model.hfToggleText(card.dgx.hfRows, card.showDerivatives)
  readonly property bool searching: card.dgx.hfSearching
  readonly property bool asked: card.dgx.hfAsked !== "" || card.dgx.hfRows !== null

  // Draft recipe… on a result: the card's own account of the last one (drafting it, then the Add recipe path's check and add).
  readonly property bool drafting: card.dgx.recipeHost === card.host && card.dgx.draftRepo !== ""
  readonly property string draftStep: card.dgx.draftStep !== "" ? card.dgx.draftStep : card.dgx.recipeStep
  readonly property var draftResult: card.drafting && card.dgx.draftId !== "" && card.dgx.recipeResult && card.dgx.recipeResult.id === card.dgx.draftId ? card.dgx.recipeResult : null
  readonly property string draftFailure: !card.drafting ? "" : card.dgx.draftError !== "" ? card.dgx.draftError : card.dgx.recipeError
  readonly property int shownErrors: 8

  function draft(repo) {
    if (!card.dgx.recipeBusy) card.dgx.draftRecipe(card.host, repo)
  }

  // With an agent…: a terminal that drafts and lets an agent finish the recipe; nothing comes back to the card.
  function author(repo) {
    const l = Model.authorLaunch(card.host, repo)
    if (l) card.dgx.launch(l.verb, l.host, l.id)
  }

  function go() {
    if (!card.searching) card.dgx.searchHf(queryField.text)
  }

  Component.onCompleted: {
    queryField.text = card.query
    if (card.query !== "") card.go()
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
        text: "Find on Hugging Face"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.searching ? "SEARCHING HUGGING FACE…" : card.dgx.hfError !== "" ? "THE SEARCH DID NOT RUN"
          : card.dgx.hfRows !== null ? card.rows.length + (card.rows.length === 1 ? " MODEL" : " MODELS") + " FOUND" : "MLX 4-BIT MODELS OF A KNOWN FAMILY"
        color: card.dgx.hfError !== "" ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Searches from this computer; no machine is asked. Each result's config.json says it is MLX affine 4-bit and of a family known to work. Whether it fits " + Model.hostName(card.host) + " is only known after a measuring run."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    TextField {
      id: queryField
      Layout.fillWidth: true
      focus: true
      placeholderText: "qwen, gemma, lfm…"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      onAccepted: card.go()
      // Esc drops what was typed first, then closes the card.
      Keys.onEscapePressed: event => {
        if (queryField.text !== "") { queryField.text = ""; event.accepted = true }
        else event.accepted = false
      }
    }

    Toggle {
      Layout.fillWidth: true
      visible: card.toggleText !== ""
      label: card.toggleText
      description: "Repos labelled abliterated or uncensored from their name or tags; the others are not touched."
      checked: card.showDerivatives
      onClicked: card.showDerivatives = !card.showDerivatives
    }

    Text {
      Layout.fillWidth: true
      visible: card.dgx.hfError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.hfError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // A search that found nothing says so, apart from one that did not run.
    Text {
      Layout.fillWidth: true
      visible: card.dgx.hfRows !== null && card.dgx.hfError === "" && !card.searching && card.rows.length === 0
      wrapMode: Text.Wrap
      text: card.dgx.hfRows !== null && card.dgx.hfRows.length > 0 ? "Every result is hidden by the toggle." : "No MLX 4-bit repo of a known family matched."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Draft recipe…: where it is, its warnings, and each error found, on its own row.
    Text {
      Layout.fillWidth: true
      visible: card.drafting && card.draftStep !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: Model.draftStatus(card.draftStep, card.host, card.dgx.draftRepo)
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftFailure !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.draftFailure
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Repeater {
      model: card.drafting ? card.dgx.draftWarnings : []
      delegate: Text {
        required property string modelData
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: "Warning: " + modelData
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    Repeater {
      model: card.draftResult && !card.draftResult.ok ? card.draftResult.errors.slice(0, card.shownErrors) : []
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
      visible: card.draftResult !== null && !card.draftResult.ok && card.draftResult.errors.length > card.shownErrors
      text: card.draftResult ? "and " + (card.draftResult.errors.length - card.shownErrors) + " more" : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftResult !== null && card.draftResult.ok && card.draftResult.added === true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.draftResult ? Model.draftDone(card.host, card.draftResult.id) : ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: list.contentHeight
      spacing: Style.spacing.md

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: contentHeight
        clip: true
        spacing: Style.spacing.md
        model: card.rows
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: hfRow
          required property var modelData
          readonly property string label: Model.hfLabel(hfRow.modelData)
          width: ListView.view.width
          implicitHeight: body.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, hover.hovered ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: Util.alpha(Color.foreground, 0.06)
          HoverHandler { id: hover }

          ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.xxs
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.md
              Text {
                Layout.fillWidth: hfRow.label === ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: hfRow.modelData.repo
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              // A derivative says so, in the colour of a caution.
              Text {
                Layout.fillWidth: true
                visible: hfRow.label !== ""
                textFormat: Text.PlainText
                text: hfRow.label
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: Model.hfRowText(hfRow.modelData)
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.lg
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: Model.hfMemoryLine(hfRow.modelData, card.ramGib)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              SettingsPill {
                text: Model.AUTHOR_TEXT
                opacity: Model.authorLaunch(card.host, hfRow.modelData.repo) ? 1 : 0.4
                onClicked: card.author(hfRow.modelData.repo)
              }
              SettingsPill {
                text: "Draft recipe…"
                opacity: card.dgx.recipeBusy ? 0.4 : 1
                onClicked: card.draft(hfRow.modelData.repo)
              }
            }
          }
        }
      }

      ScrollTrack {
        target: list
        Layout.fillHeight: true
        Layout.preferredWidth: implicitWidth
      }
    }

    Item { Layout.fillHeight: true; visible: card.rows.length === 0 }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Enter to search · Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: "Search"
        primary: true
        opacity: card.searching ? 0.4 : 1
        onClicked: card.go()
      }
    }
  }
}
