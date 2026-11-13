// One error the engine found, on its own tinted row: the Add recipe card's and the Find card's draft errors.
import QtQuick
import qs.Commons

Rectangle {
  id: row

  property string message: ""

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
    text: row.message
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
