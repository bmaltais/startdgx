// Adapted from Omarchy's tailscale panel (shell/plugins/panels/tailscale/TailscaleIcon.qml), MIT, Copyright (c) David
// Heinemeier Hansson. The Tailscale mark drawn as a 3×3 grid of dots, the inactive ones faded, which stays crisp at a
// button's size where an SVG would not. `crossed` strikes it through: not shared.
pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

Item {
  id: mark

  property real iconSize: Style.space(16)
  property color color: Color.foreground
  property bool crossed: false

  width: mark.iconSize
  height: mark.iconSize

  readonly property real dotSize: Math.max(2, mark.iconSize * 0.24)
  readonly property real mid: (mark.iconSize - mark.dotSize) / 2
  readonly property real end: mark.iconSize - mark.dotSize

  // Row by row, the lit dots at full strength.
  Repeater {
    model: [[0, 0, 0.24], [1, 0, 0.24], [2, 0, 0.24], [0, 1, 1], [1, 1, 1], [2, 1, 1], [0, 2, 0.24], [1, 2, 1], [2, 2, 0.24]]
    delegate: Rectangle {
      required property var modelData
      x: modelData[0] === 0 ? 0 : modelData[0] === 1 ? mark.mid : mark.end
      y: modelData[1] === 0 ? 0 : modelData[1] === 1 ? mark.mid : mark.end
      width: mark.dotSize
      height: mark.dotSize
      radius: width / 2
      color: mark.color
      opacity: modelData[2]
    }
  }

  Rectangle {
    visible: mark.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: mark.color
    rotation: -45
  }
}
