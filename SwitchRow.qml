// A setting in a card: its label and what it does on the left, the family's switch on the right (RoundSwitch), a hairline under
// it, as in the settings windows. Clicking anywhere on the row asks to flip it; whoever uses it flips `checked`.
import QtQuick
import qs.Commons

Item {
  id: row

  property string label: ""
  property string description: ""
  property bool checked: false
  signal clicked()

  implicitHeight: Math.max(labels.implicitHeight, toggle.height) + Style.spacing.md * 2

  Column {
    id: labels
    anchors.left: parent.left
    anchors.right: toggle.left
    anchors.rightMargin: Style.spacing.xxl
    anchors.verticalCenter: parent.verticalCenter
    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.Wrap
      text: row.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      textFormat: Text.PlainText
      visible: row.description !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      text: row.description
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  RoundSwitch {
    id: toggle
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: row.checked
    onClicked: row.clicked()
  }

  Rectangle {
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 1
    color: Util.alpha(Color.foreground, 0.07)
  }

  MouseArea {
    anchors.fill: parent
    z: -1
    cursorShape: Qt.PointingHandCursor
    onClicked: row.clicked()
  }
}
