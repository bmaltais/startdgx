// A machine's memory, the one thing a DGX Spark runs out of: a bar split by the models that hold it, with what is
// free left as the track, and a line saying how much is in use. Colours come from the theme (the accent, stepped
// down for each further model, over the track the Meter uses), so it follows a theme change live.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

ColumnLayout {
  id: bar

  property var mem: null        // DgxModel.hostMemory(), or null while the machine's total is unknown
  property string text: ""      // what the line under the bar says

  spacing: Style.spacing.xs
  visible: bar.mem !== null

  Item {
    id: track
    Layout.fillWidth: true
    implicitHeight: Math.max(Style.space(6), Math.round(Style.spacing.controlHeight * 0.2))

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Style.selectedFillFor(Color.foreground, Color.accent)
    }
    // Clipped to the track's rounded ends.
    Item {
      anchors.fill: parent
      clip: true
      Row {
        id: segmentRow
        height: parent.height
        spacing: 1
        Repeater {
          model: bar.mem ? bar.mem.segments : []
          delegate: Rectangle {
            id: seg
            required property var modelData
            required property int index
            height: segmentRow.height
            width: Math.max(2, track.width * seg.modelData.gib / bar.mem.total)
            // The first model is the accent; each next one steps toward the foreground, so neighbours stay apart.
            // What other programs hold is the foreground, muted: it isn't one of ours.
            color: seg.modelData.other ? Util.alpha(Color.foreground, 0.45)
                                       : Qt.tint(Color.accent, Util.alpha(Color.foreground, Math.min(0.7, 0.28 * seg.index)))
            Behavior on width { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
            HoverHandler { id: segHover }
            PanelToolTip {
              visible: segHover.hovered
              text: seg.modelData.name + (seg.modelData.loading ? " · loading" : "") + " · " + Math.round(seg.modelData.gib) + " GiB"
            }
          }
        }
      }
    }
  }

  Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    text: bar.text
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.features: { "tnum": 1 }
    elide: Text.ElideRight
  }
}
