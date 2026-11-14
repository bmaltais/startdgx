// The family's switch: a pill that is accent while on, with a knob that slides. The same look as the switches in the settings
// windows (SettingsWindow.qml's switch editor); stateless, so whoever uses it flips `checked` when it says `clicked()`.
import QtQuick
import qs.Commons

Rectangle {
  id: sw

  property bool checked: false
  signal clicked()

  implicitWidth: Style.space(42)
  implicitHeight: Style.space(24)
  radius: height / 2
  color: sw.checked ? Color.accent : Util.alpha(Color.foreground, 0.25)

  // Animating only once the first value has settled keeps the knob from sliding into place when a card opens.
  property bool settled: false
  Component.onCompleted: Qt.callLater(function () { sw.settled = true })

  Rectangle {
    width: parent.height - 6
    height: width
    radius: width / 2
    y: 3
    x: sw.checked ? parent.width - width - 3 : 3
    color: Color.menu.background
    Behavior on x { enabled: sw.settled; NumberAnimation { duration: 100 } }
  }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: sw.clicked()
  }
}
