// The Find existing ComfyUI card, over the manager: what a machine has (`startdgx comfyui discover --json`, which only reads: the
// service's folder, a ComfyUI running now, the ones startdgx already manages, and a bounded look through the home folder and a
// linked disk such as ~/usbdisk; it runs no script of an install). A dgx-comfyui folder gets an Adopt button, which only records
// it: nothing in the folder is changed or deleted, and Forget undoes it. A ComfyUI without dgx-comfyui is listed and not offered.
// Keyboard: Up/Down (or j/k) move, Enter adopts the folder under the cursor, r looks again, Esc closes the card.
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
  readonly property var rows: card.dgx.comfyFound ? Model.comfyFindRows(card.dgx.comfyFound) : []
  readonly property bool looking: card.dgx.comfyFinding
  readonly property string machine: Model.hostName(card.host)

  function adopt(r) {
    if (r.offer !== "adopt" || (card.dgx.pending[Model.comfyKey(card.host, r.path)] || "") !== "") return
    card.svc.dispatch({ type: "comfyAdopt", host: card.host, path: r.path })
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2
  onRowsChanged: card.cursor = Math.max(0, Math.min(card.cursor, card.rows.length - 1))

  Keys.onPressed: event => {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { card.cursor = Math.max(0, card.cursor - 1); event.accepted = true }
    else if (event.key === Qt.Key_Down || event.text === "j") { card.cursor = Math.min(card.rows.length - 1, card.cursor + 1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // A held Enter would adopt the next folder too.
      if (!event.isAutoRepeat && card.rows.length) card.adopt(card.rows[card.cursor])
      event.accepted = true
    }
    else if (event.text === "r") { card.dgx.findComfy(card.host); event.accepted = true }
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
        elide: Text.ElideRight
        text: "Find ComfyUI on " + card.machine
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.looking ? "LOOKING…" : card.dgx.comfyFindError !== "" ? "THE MACHINE COULD NOT BE READ" : "FOUND ON THIS MACHINE"
        color: card.dgx.comfyFindError !== "" && !card.looking ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      visible: card.dgx.comfyFindError !== "" && !card.looking
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.comfyFindError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.dgx.comfyFoundPartial && !card.looking
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "The look through " + card.machine + " was cut short (it took too long), so some folders weren't searched. If yours isn't here, adopt it with: startdgx comfyui adopt " + card.host + " --dir <folder>"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.rows.length === 0 && !card.looking && card.dgx.comfyFindError === "" && card.dgx.comfyFound !== null
      wrapMode: Text.Wrap
      text: "No ComfyUI found in the home folder or under a linked disk such as ~/usbdisk."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: list.contentHeight
      visible: card.rows.length > 0
      spacing: Style.spacing.md

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: contentHeight
        clip: true
        spacing: Style.spacing.md
        model: card.rows
        currentIndex: card.cursor
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: found
          required property var modelData
          required property int index
          readonly property bool current: found.index === card.cursor
          readonly property string pending: card.dgx.pending[Model.comfyKey(card.host, found.modelData.path)] || ""
          width: ListView.view.width
          implicitHeight: foundBody.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, foundHover.hovered || found.current ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: found.current ? Util.alpha(Color.accent, 0.7) : Util.alpha(Color.foreground, 0.06)
          opacity: found.modelData.offer === "" && !found.modelData.managed ? 0.6 : 1
          HoverHandler { id: foundHover }
          MouseArea { anchors.fill: parent; onClicked: { card.cursor = found.index; card.forceActiveFocus() } }

          RowLayout {
            id: foundBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.lg

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.xxs
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: String(found.modelData.name)
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: String(found.modelData.path)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
              }
              Text {
                Layout.fillWidth: true
                visible: found.modelData.text !== ""
                textFormat: Text.PlainText
                text: found.modelData.text
                color: found.modelData.offer !== "" || found.modelData.managed ? Color.foreground : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }

            Text {
              visible: found.modelData.managed
              textFormat: Text.PlainText
              text: "Managed"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              visible: found.modelData.offer === "adopt"
              text: found.pending === "adopt" ? "Adding…" : "Adopt"
              bordered: true
              enabled: found.pending === ""
              tooltipText: "Let startdgx manage this install. Nothing in its folder is changed; Forget undoes it."
              onClicked: card.adopt(found.modelData)
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
        enabled: !card.looking
        tooltipText: "Look through the machine again  (r)"
        onClicked: { card.dgx.findComfy(card.host); card.forceActiveFocus() }
      }
      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        text: "Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
