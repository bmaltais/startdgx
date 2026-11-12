// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component AddView: its recipe rows), MIT,
// Copyright (c) David Heinemeier Hansson: the maker's mark, the name with the engine's recommendation, and the facts line.
// A machine's model picker, over the manager: its catalog (`startdgx list HOST`), best first, each recipe with
// whether it runs there (and why not), whether it is set up, what it takes and what it is. Set up starts the
// setup on the machine (`use --detach`), closes the card and puts the cursor on the new row, which follows the
// download. Add recipe… (e) opens the card that adds a recipe of your own. Keyboard: Up/Down (or j/k) move, Enter sets up
// the recipe under the cursor, r looks again, Esc closes.
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

  readonly property var dgx: card.svc.dgx
  readonly property bool mine: card.dgx.listHost === card.host
  readonly property var hostState: card.dgx.shownState[card.host] || null
  readonly property var offers: card.mine ? Model.recipeOffers(card.dgx.recipes, card.hostState ? card.hostState.status : null) : []
  readonly property bool reading: card.dgx.listing && card.offers.length === 0
  readonly property string failure: card.mine && !card.dgx.listing ? card.dgx.recipesError : ""

  function act(offer) {
    if (offer && offer.action === "use") card.svc.dispatch({ type: "use", host: card.host, recipe: offer.recipe })
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2
  onOffersChanged: card.cursor = Math.max(0, Math.min(card.cursor, card.offers.length - 1))

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
        elide: Text.ElideRight
        text: "Add a model to " + Model.hostName(card.host)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.reading ? "READING THE MACHINE'S CATALOG…" : card.failure !== "" ? "THE CATALOG COULD NOT BE READ" : "MODELS FOR THIS MACHINE"
        color: card.failure !== "" ? Color.urgent : Color.muted
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

    Text {
      Layout.fillWidth: true
      visible: card.mine && !card.dgx.listing && card.failure === "" && card.offers.length === 0
      wrapMode: Text.Wrap
      text: "The engine on this machine has no models in its catalog."
      color: Color.muted
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

        delegate: Rectangle {
          id: recipeRow
          required property var modelData
          required property int index
          readonly property var r: modelData.recipe
          readonly property bool current: index === card.cursor
          readonly property bool can: modelData.action === "use"
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
                  Layout.fillWidth: !recipeRow.modelData.best && recipeRow.marks === ""
                  textFormat: Text.PlainText
                  text: String(recipeRow.r.name || recipeRow.r.id)
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                // Yours, and where a user recipe's numbers come from when they aren't measured.
                Text {
                  Layout.fillWidth: !recipeRow.modelData.best
                  visible: recipeRow.marks !== ""
                  textFormat: Text.PlainText
                  text: recipeRow.marks
                  color: recipeRow.r.source === "drafted" ? Color.muted : Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                // The engine's own recommendation for this machine.
                Text {
                  Layout.fillWidth: true
                  visible: recipeRow.modelData.best
                  text: "recommended"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              // Whether it runs here, or is set up; why not, when it can't.
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: recipeRow.modelData.best && recipeRow.can ? "" : recipeRow.modelData.text
                color: recipeRow.can || recipeRow.r.available === true ? Color.foreground : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Text {
                Layout.fillWidth: true
                visible: recipeRow.facts !== ""
                textFormat: Text.PlainText
                text: recipeRow.facts
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: String(recipeRow.r.summary || "")
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }
            }

            Button {
              Layout.alignment: Qt.AlignVCenter
              visible: recipeRow.can
              text: "Set up"
              bordered: true
              tooltipText: "Download " + String(recipeRow.r.name || recipeRow.r.id) + " to " + Model.hostName(card.host) + " and set it up; it starts if there is room  (Enter)"
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
        text: "Add recipe…"
        bordered: true
        tooltipText: "Add a recipe of your own, a .toml file from this computer, to " + Model.hostName(card.host) + "'s catalog  (e)"
        onClicked: card.svc.dispatch({ type: "addRecipe", host: card.host })
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: card.svc.footerText
        color: card.svc.notice !== "" && card.svc.noticeIsError ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
