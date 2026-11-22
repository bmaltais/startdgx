// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component AddView: its recipe rows), MIT,
// Copyright (c) David Heinemeier Hansson: the maker's mark, the name with the engine's recommendation, and the facts line.
// A machine's model picker, over the manager: its catalog (`startdgx list HOST`), best first, each recipe with
// whether it runs there (and why not), whether it is set up, what it takes and what it is. Set up starts the
// setup on the machine (`use --detach`), closes the card and puts the cursor on the new row, which follows the
// download. Under the machine's own recipes come the models it could have: TensorFold's published list for one DGX Spark (read from this
// computer, `tensorfold list`), each with an Add that puts the model in the list above at once, without downloading it. Each row has a small
// mark for where it comes from (the engine, TensorFold, a file of yours). The box at the top filters both lists as you type.
// From a file… (e) opens the card that adds a recipe of your own. Keyboard: Up/Down (or j/k) move, Enter sets up
// the recipe under the cursor, / goes to the filter, r looks again, Esc closes.
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
  property int cursor: 0
  property string query: ""
  // A model just added: its row in the list above gets the cursor when the list has it.
  property string landing: ""

  readonly property var dgx: card.svc.dgx
  readonly property bool mine: card.dgx.listHost === card.host
  readonly property var hostState: card.dgx.shownState[card.host] || null
  readonly property var allOffers: card.mine ? Model.recipeOffers(card.dgx.recipes, card.hostState ? card.hostState.status : null) : []
  // What the box at the top keeps: the rows whose name, id, maker or origin hold every word typed.
  property string filter: ""
  readonly property var offers: Model.filterOffers(card.allOffers, card.filter, card.dgx.tfList)
  readonly property bool reading: card.dgx.listing && card.allOffers.length === 0
  readonly property string failure: card.mine && !card.dgx.listing ? card.dgx.recipesError : ""

  readonly property var tfAll: Model.tfOffers(card.dgx.tfList, card.mine ? card.dgx.recipes : null, card.hostState ? card.hostState.status : null)
  readonly property var tfOffers: ({ rows: Model.filterTfRows(card.tfAll.rows, card.filter), blockedText: card.tfAll.blockedText })
  // The last add: its steps, warnings and any clash or validation error, as on the card this replaced.
  readonly property bool drafting: card.dgx.recipeHost === card.host && card.dgx.draftRepo !== ""
  readonly property string draftStep: card.dgx.draftStep !== "" ? card.dgx.draftStep : card.dgx.recipeStep
  readonly property var draftResult: card.drafting && card.dgx.draftId !== "" && card.dgx.recipeResult && card.dgx.recipeResult.id === card.dgx.draftId ? card.dgx.recipeResult : null
  readonly property string draftFailure: !card.drafting ? "" : card.dgx.draftError !== "" ? card.dgx.draftError : card.dgx.recipeError
  readonly property int shownErrors: 8
  function land() {
    for (let i = 0; i < card.offers.length && card.landing !== ""; i++) if (card.offers[i].recipe.id === card.landing) { card.cursor = i; card.landing = ""; list.positionViewAtIndex(i, ListView.Contain) }
  }
  onDraftResultChanged: if (card.draftResult && card.draftResult.ok) { card.landing = card.draftResult.id; card.dgx.listRecipes(card.host); card.land() }
  onOffersChanged: {
    if (card.landing === "") card.cursor = Math.max(0, Math.min(card.cursor, card.offers.length - 1))
    else card.land()
  }
  function addEntry(row) { if (!card.dgx.recipeBusy) card.dgx.draftTensorfold(card.host, row, null) }
  Component.onCompleted: searchField.text = card.query

  function act(offer) {
    // A recipe of yours downloads what it names and runs it: a card shows the download and asks first.
    if (offer && offer.action === "use") card.svc.dispatch({ type: offer.confirm ? "setupYours" : "use", host: card.host, recipe: offer.recipe })
  }

  function measure(r, ctx) {
    if (ctx > 0) card.svc.dispatch({ type: "measureRecipe", host: card.host, recipe: r, ctx: ctx })
    else card.svc.dispatch({ type: "addRecipe", host: card.host })
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { card.cursor = Math.max(0, card.cursor - 1); event.accepted = true }
    else if (event.key === Qt.Key_Down || event.text === "j") { card.cursor = Math.min(card.offers.length - 1, card.cursor + 1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // A held Enter would set up the next recipe too.
      if (!event.isAutoRepeat && card.offers.length) card.act(card.offers[card.cursor])
      event.accepted = true
    }
    else if (event.text === "r") { card.dgx.listRecipes(card.host); event.accepted = true }
    else if (event.text === "/") { searchField.forceActiveFocus(); event.accepted = true }
    else if (event.text === "e") { card.svc.dispatch({ type: "addRecipe", host: card.host }); event.accepted = true }
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
        text: "Add a model to " + Model.hostName(card.host)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.reading ? "READING THE MACHINE'S CATALOG…" : card.failure !== "" ? "THE CATALOG COULD NOT BE READ" : card.tfOffers.rows.length > 0 ? "MODELS FOR THIS MACHINE · " + card.tfOffers.rows.length + " MORE FROM TENSORFOLD BELOW" : "MODELS FOR THIS MACHINE"
        color: card.failure !== "" ? Color.urgent : Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

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

    TextField {
      id: searchField
      Layout.fillWidth: true
      placeholderText: "Filter the models: qwen, gemma, tensorfold, custom…   ( / )"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      onTextChanged: card.filter = searchField.text
      // Enter goes back to the list (the card's own Enter sets up the recipe under the cursor).
      Keys.onReturnPressed: event => { card.forceActiveFocus(); event.accepted = true }
      Keys.onEnterPressed: event => { card.forceActiveFocus(); event.accepted = true }
      // Esc drops what was typed first, then closes the card.
      Keys.onEscapePressed: event => {
        if (searchField.text !== "") { searchField.text = ""; event.accepted = true }
        else event.accepted = false
      }
    }

    // What the last add is doing or said: its step, warnings, and each error found.
    Text {
      Layout.fillWidth: true
      visible: card.drafting && card.draftStep !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: Model.draftStatus(card.draftStep, card.host, card.dgx.draftRepo)
      color: Tones.muted
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
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    Repeater {
      model: card.draftResult && !card.draftResult.ok ? card.draftResult.errors.slice(0, card.shownErrors) : []
      delegate: ErrorRow {
        required property string modelData
        Layout.fillWidth: true
        message: modelData
      }
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftResult !== null && card.draftResult.ok && card.draftResult.added === true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.draftResult ? Model.draftDone(card.host, card.draftResult.id, card.dgx.draftSource) : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.mine && !card.dgx.listing && card.failure === "" && card.allOffers.length === 0
      wrapMode: Text.Wrap
      text: "The engine on this machine has no models in its catalog."
      color: Tones.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      Layout.fillWidth: true
      visible: card.filter.trim() !== "" && card.allOffers.length > 0 && card.offers.length === 0 && card.tfOffers.rows.length === 0
      wrapMode: Text.Wrap
      text: "No model matches \u201c" + card.filter.trim() + "\u201d."
      color: Tones.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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
        model: card.offers
        currentIndex: card.cursor
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        boundsBehavior: Flickable.StopAtBounds

        // The models this machine could have, under the ones it can run: TensorFold's list.
        footer: ColumnLayout {
          width: ListView.view.width
          spacing: Style.spacing.md
          Text {
            Layout.topMargin: Style.spacing.lg
            visible: card.tfOffers.rows.length > 0
            text: "FROM TENSORFOLD · NOT IN THE LIST YET"
            color: Tones.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }
          Repeater {
            model: card.tfOffers.rows
            delegate: FindRow {
              id: tfEntry
              required property var modelData
              Layout.fillWidth: true
              name: tfEntry.modelData.name
              origin: "tensorfold"
              mark: tfEntry.modelData.status
              facts: Model.tfRowText(tfEntry.modelData)
              busy: card.dgx.recipeBusy
              tooltip: "Add " + tfEntry.modelData.name + " to " + Model.hostName(card.host) + "'s list with TensorFold's default settings. Nothing is downloaded until you set it up"
              onAddRequested: card.addEntry(tfEntry.modelData)
            }
          }
          Text {
            Layout.fillWidth: true
            visible: card.tfOffers.blockedText !== ""
            wrapMode: Text.Wrap
            text: card.tfOffers.blockedText
            color: Tones.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        delegate: Rectangle {
          id: recipeRow
          required property var modelData
          required property int index
          readonly property var r: modelData.recipe
          readonly property bool current: index === card.cursor
          readonly property bool can: modelData.action === "use"
          readonly property bool removable: Model.isUserRecipe(recipeRow.r) && recipeRow.r.installed !== true
          // A recipe added from TensorFold's list is set up and run as it is: measuring is in its settings, not on its row.
          readonly property bool fromList: Model.tfAddedRow(card.dgx.tfList, recipeRow.r.id) !== null
          readonly property string origin: Model.recipeOrigin(recipeRow.r, card.dgx.tfList)
          readonly property var measureCtx: recipeRow.fromList ? null : Model.pickerMeasureCtx(recipeRow.r)
          readonly property string facts: Model.recipeFacts(recipeRow.r)
          readonly property string marks: Model.recipeMarks(recipeRow.r).join(" · ")
          width: ListView.view.width
          implicitHeight: recipeBody.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, recipeHover.hovered || recipeRow.current ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: recipeRow.current ? Util.alpha(Color.accent, 0.7) : Util.alpha(Color.foreground, 0.06)
          // What this machine can't run is there to say why, dimmed.
          opacity: recipeRow.r.available === true ? 1 : 0.6
          HoverHandler { id: recipeHover }
          MouseArea { anchors.fill: parent; onClicked: { card.cursor = recipeRow.index; card.forceActiveFocus() } }

          RowLayout {
            id: recipeBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.space(10)

            VendorIcon {
              Layout.alignment: Qt.AlignTop
              vendor: String(recipeRow.r.vendor || "")
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.xxs
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md
                Text {
                  // As wide as the name, and cut when the row is narrower: the marks after it keep their room.
                  Layout.fillWidth: true
                  Layout.maximumWidth: Math.ceil(implicitWidth)
                  textFormat: Text.PlainText
                  text: String(recipeRow.r.name || recipeRow.r.id)
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                OriginIcon {
                  Layout.alignment: Qt.AlignVCenter
                  origin: recipeRow.origin
                }
                // Yours, and where a user recipe's numbers come from when they aren't measured.
                Text {
                  visible: recipeRow.marks !== ""
                  textFormat: Text.PlainText
                  text: recipeRow.marks
                  color: recipeRow.r.source === "drafted" ? Tones.muted : Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                // The engine's own recommendation for this machine.
                Text {
                  visible: recipeRow.modelData.best
                  text: "recommended"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Item { Layout.fillWidth: true }
              }
              // Whether it runs here, or is set up; why not, when it can't.
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: recipeRow.modelData.best && recipeRow.can ? "" : recipeRow.modelData.text
                color: recipeRow.can || recipeRow.r.available === true ? Color.foreground : Tones.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Text {
                Layout.fillWidth: true
                id: factsText
                visible: recipeRow.facts !== ""
                textFormat: Text.PlainText
                text: recipeRow.facts
                color: Tones.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                HoverHandler { id: factsHover }
                PanelToolTip {
                  visible: factsHover.hovered && factsText.truncated
                  text: factsText.text
                }
              }
              Text {
                Layout.fillWidth: true
                id: summaryText
                visible: text !== ""
                textFormat: Text.PlainText
                text: String(recipeRow.r.summary || "")
                color: Tones.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                HoverHandler { id: summaryHover }
                PanelToolTip {
                  visible: summaryHover.hovered && summaryText.truncated
                  text: summaryText.text
                }
              }
            }

            // Its settings: the context sizes, what can be measured, and (for yours) adding a size or removing it.
            Button {
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredWidth: implicitHeight
              iconText: "\uf013"
              tooltipText: "Settings of " + String(recipeRow.r.name || recipeRow.r.id) + ": " + (recipeRow.fromList ? "context, requests at once, input" : "its context sizes" + (Model.isUserRecipe(recipeRow.r) ? ", measuring, adding a size, removing it" : ""))
              foreground: Tones.muted
              onClicked: card.svc.dispatch({ type: "recipeSettings", host: card.host, recipe: recipeRow.r })
            }

            // A recipe of yours, not set up here: take it off the machine's list (its file stays on this computer, the engine
            // refuses while a model uses it).
            Button {
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredWidth: implicitHeight
              visible: recipeRow.removable
              enabled: card.dgx.recipeRemoving === "" && !card.dgx.recipeBusy
              iconText: "\uf1f8"
              tooltipText: "Remove " + String(recipeRow.r.name || recipeRow.r.id) + " from " + Model.hostName(card.host) + "'s list. It is yours: nothing else is deleted"
              foreground: Tones.muted
              onClicked: card.dgx.removeRecipe(card.host, recipeRow.r.id)
            }

            // A recipe of yours whose numbers aren't measured: measure it from here (its context when the row has one,
            // else From a file…, which lists its variants).
            Button {
              Layout.alignment: Qt.AlignVCenter
              visible: recipeRow.measureCtx !== null
              text: "Measure…"
              bordered: true
              tooltipText: "Download " + String(recipeRow.r.name || recipeRow.r.id) + ", load it and bench it on " + Model.hostName(card.host) + ", to replace its numbers with measured ones. Shows the download and asks first"
              onClicked: card.measure(recipeRow.r, recipeRow.measureCtx)
            }

            Button {
              Layout.alignment: Qt.AlignVCenter
              visible: recipeRow.can
              text: recipeRow.modelData.confirm ? "Set up…" : "Set up"
              bordered: true
              tooltipText: "Download " + String(recipeRow.r.name || recipeRow.r.id) + " to " + Model.hostName(card.host) + " and set it up; it starts if there is room" + (recipeRow.modelData.confirm ? ". A recipe of yours shows its download and asks first" : "") + "  (Enter)"
              onClicked: card.act(recipeRow.modelData)
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

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xxl
      Button {
        text: "Look again"
        bordered: true
        enabled: !card.dgx.listing
        tooltipText: "Read the machine's catalog again  (r)"
        onClicked: card.dgx.listRecipes(card.host)
      }
      Button {
        text: "From a file…"
        bordered: true
        tooltipText: "Add a recipe of your own, a .toml file from this computer, to " + Model.hostName(card.host) + "'s catalog  (e)"
        onClicked: card.svc.dispatch({ type: "addRecipe", host: card.host })
      }
      FooterNote {
        Layout.fillWidth: true
        svc: card.svc
      }
    }
  }
}
