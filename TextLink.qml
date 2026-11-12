// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component TextLink), MIT, Copyright (c) David Heinemeier Hansson.
// A plain-text control: dim until hovered or picked, for the quiet actions (Logs, Uninstall…, Forget) that
// bordered buttons would make loud. Host text is drawn as plain text.
import QtQuick
import qs.Commons
import qs.Ui

Text {
  id: link

  signal clicked()
  property bool picked: false
  property string tooltip: ""
  property color idleColor: Util.alpha(Color.foreground, 0.55)
  property color hotColor: Color.foreground
  readonly property bool hot: linkMouse.containsMouse || link.picked

  textFormat: Text.PlainText
  color: link.hot ? link.hotColor : link.idleColor
  font.family: Style.font.family
  font.pixelSize: Style.font.caption
  font.underline: link.hot

  MouseArea {
    id: linkMouse
    anchors.fill: parent
    anchors.margins: -Style.space(4)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: link.clicked()
  }

  PanelToolTip {
    visible: link.tooltip !== "" && linkMouse.containsMouse
    text: link.tooltip
  }
}
