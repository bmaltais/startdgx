// Adapted from Omarchy's agents plugin (shell/plugins/agents/Panel.qml, component Meter), MIT, Copyright (c) David Heinemeier Hansson.
// A rounded track with a fill: a model's memory, or how far its download, load, stop or removal has come.
import QtQuick
import qs.Commons

Item {
  id: meter

  property real value: 0
  property bool alarming: false
  property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

  implicitHeight: thickness

  Rectangle {
    id: meterTrack
    anchors.fill: parent
    radius: height / 2
    color: Style.selectedFillFor(Color.foreground, Color.accent)
  }

  Rectangle {
    anchors.left: meterTrack.left
    anchors.verticalCenter: meterTrack.verticalCenter
    height: meterTrack.height
    radius: meterTrack.radius
    width: meterTrack.width * Math.max(0, Math.min(1, meter.value))
    color: meter.alarming ? Color.urgent : Color.foreground

    Behavior on width {
      NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
    }
  }
}
