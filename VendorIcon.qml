// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component ProviderIcon,
// iconCandidatesForProvider and colorLuminance), MIT, Copyright (c) David Heinemeier Hansson.
// A model's maker's mark: assets/<vendor>.svg, or its -light twin on a light surface (a white mark ships one),
// and the generic chip (assets/local.svg) for a maker with no mark here. Only shipped files are tried, so a
// missing one never logs an error.
import QtQuick
import qs.Commons

Item {
  id: mark

  property string vendor: ""
  property real size: Style.font.heading

  function channel(value) {
    const c = Number(value)
    if (!isFinite(c)) return 0
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  }
  readonly property bool lightSurface: 0.2126 * mark.channel(Color.menu.background.r) + 0.7152 * mark.channel(Color.menu.background.g)
    + 0.0722 * mark.channel(Color.menu.background.b) >= 0.5
  // The marks in assets/, and which of them have a -light twin.
  readonly property var shipped: ["deepseek", "kimi", "local", "minimax", "nvidia", "qwen", "zai"]
  readonly property var lightTwins: ["kimi", "local", "minimax", "zai"]
  readonly property string name: mark.shipped.indexOf(mark.vendor) >= 0 ? mark.vendor : "local"
  readonly property url source: Qt.resolvedUrl("assets/" + mark.name + (mark.lightSurface && mark.lightTwins.indexOf(mark.name) >= 0 ? "-light" : "") + ".svg")

  width: mark.size
  height: mark.size

  Image {
    anchors.fill: parent
    source: mark.source
    sourceSize.width: mark.size * 2
    sourceSize.height: mark.size * 2
    fillMode: Image.PreserveAspectFit
  }
}
