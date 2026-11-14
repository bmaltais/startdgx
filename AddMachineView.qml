// The Add machine card, over the manager: the machines of your tailnet (`startdgx discover --json`, which
// installs and changes nothing on them; it saves a never-seen machine's host key) and what each can do
// (DgxModel.peerOffer). A DGX Spark with startdgx's engine is added at once; one with another engine can be added as
// it is, or installed over (the engine there is backed up first); one with none is installed in a terminal, where
// sudo asks for its password. The machines are asked as this machine's user, or the one typed in User on the
// machines. Keyboard: Up/Down (or j/k) move, Enter adds or installs the machine under the cursor, r looks again,
// Esc closes the card; in the user field, Enter looks again as that user.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property int cursor: 0

  readonly property var dgx: card.svc.dgx
  readonly property var peers: card.dgx.peers
  readonly property bool scanning: card.dgx.discovering

  function act(peer) {
    const offer = Model.peerOffer(peer)
    if (offer.action === "add") card.svc.dispatch({ type: "addHost", host: peer.target })
    else if (offer.action === "install") card.install(peer)
  }
  function install(peer) {
    card.svc.dispatch({ type: "install", host: peer.target, replace: Model.peerOffer(peer).install === "replace" })
  }
  function lookAgain() {
    card.svc.discoverUser = userField.text.trim()
    card.dgx.discover(card.svc.discoverUser)
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2
  onPeersChanged: card.cursor = Math.max(0, Math.min(card.cursor, card.peers.length - 1))

  Keys.onPressed: event => {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Up || event.text === "k") { card.cursor = Math.max(0, card.cursor - 1); event.accepted = true }
    else if (event.key === Qt.Key_Down || event.text === "j") { card.cursor = Math.min(card.peers.length - 1, card.cursor + 1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // A held Enter would add or install the next machine too.
      if (!event.isAutoRepeat && card.peers.length) card.act(card.peers[card.cursor])
      event.accepted = true
    }
    else if (event.text === "r") { card.lookAgain(); event.accepted = true }
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
        text: "Add machine"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.scanning ? "LOOKING ON YOUR TAILNET…" : card.dgx.peersError !== "" ? "THE TAILNET COULD NOT BE READ" : "MACHINES ON YOUR TAILNET"
        color: card.dgx.peersError !== "" && !card.scanning ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    // The ssh user the machines are asked as: this machine's by default.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        text: "User on the machines"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      TextField {
        id: userField
        Layout.fillWidth: true
        text: card.svc.discoverUser
        placeholderText: "the same as here"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        onAccepted: { card.lookAgain(); card.forceActiveFocus() }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: card.dgx.peersError !== "" && !card.scanning
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.peersError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.peers.length === 0 && !card.scanning && card.dgx.peersError === ""
      wrapMode: Text.Wrap
      text: "No Linux machine of your tailnet is online."
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
        model: card.peers
        currentIndex: card.cursor
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: peerRow
          required property var modelData
          required property int index
          readonly property var offer: Model.peerOffer(modelData)
          readonly property bool current: index === card.cursor
          width: ListView.view.width
          implicitHeight: peerBody.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, peerHover.hovered || peerRow.current ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: peerRow.current ? Util.alpha(Color.accent, 0.7) : Util.alpha(Color.foreground, 0.06)
          opacity: peerRow.offer.action === null && !modelData.added ? 0.6 : 1
          HoverHandler { id: peerHover }
          MouseArea { anchors.fill: parent; onClicked: { card.cursor = peerRow.index; card.forceActiveFocus() } }

          RowLayout {
            id: peerBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.lg

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.xxs
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md
                Text {
                  // As wide as the name, and cut when the row is narrower, so it never runs under the buttons.
                  Layout.fillWidth: true
                  Layout.maximumWidth: Math.ceil(implicitWidth)
                  textFormat: Text.PlainText
                  text: String(peerRow.modelData.name)
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  // Takes what the name leaves.
                  Layout.fillWidth: true
                  Layout.preferredWidth: 0
                  textFormat: Text.PlainText
                  text: String(peerRow.modelData.target)
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: peerRow.offer.text
                color: peerRow.offer.action !== null || peerRow.modelData.added ? Color.foreground : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }

            Button {
              visible: peerRow.offer.action === "add"
              text: "Add"
              bordered: true
              enabled: !card.dgx.busy
              tooltipText: "Add " + peerRow.modelData.name + " to the manager"
              onClicked: card.act(peerRow.modelData)
            }
            Button {
              visible: peerRow.offer.install !== ""
              text: "Install…"
              bordered: true
              tooltipText: peerRow.offer.install === "replace"
                ? "Back up the engine on " + peerRow.modelData.name + " (uninstall puts it back) and install startdgx's, in a terminal; sudo there asks for its password"
                : "Install the engine on " + peerRow.modelData.name + " in a terminal; sudo there asks for its password"
              onClicked: card.install(peerRow.modelData)
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
        enabled: !card.scanning
        tooltipText: "Ask the tailnet again, as the user above  (r)"
        onClicked: card.lookAgain()
      }
      FooterNote {
        Layout.fillWidth: true
        svc: card.svc
      }
    }
  }
}
