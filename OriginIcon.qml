// A small mark for where a model's recipe comes from: the engine's own (Omarchy local AI), TensorFold's list, or a file of yours (Custom).
// assets/<origin>.svg, or its -light twin on a light surface (as VendorIcon's marks); the engine's own is the local-AI chip.
import QtQuick
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

Item {
  id: mark

  property string origin: "omarchy"
  property real size: Style.font.body

  function channel(value) {
    const c = Number(value)
    if (!isFinite(c)) return 0
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  }
  readonly property bool lightSurface: 0.2126 * mark.channel(Color.menu.background.r) + 0.7152 * mark.channel(Color.menu.background.g)
    + 0.0722 * mark.channel(Color.menu.background.b) >= 0.5
  readonly property string file: mark.origin === "tensorfold" ? "tensorfold" : mark.origin === "custom" ? "custom" : "local"
  readonly property string words: Model.originWords(mark.origin)

  width: mark.size
  height: mark.size
  opacity: 0.7

  Image {
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/" + mark.file + (mark.lightSurface ? "-light" : "") + ".svg")
    sourceSize.width: mark.size * 2
    sourceSize.height: mark.size * 2
    fillMode: Image.PreserveAspectFit
  }
  HoverHandler { id: hover }
  PanelToolTip {
    visible: hover.hovered
    text: mark.words
  }
}
