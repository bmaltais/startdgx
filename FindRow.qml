// One model that can be added to a machine's list, in the model picker under the machine's own recipes: from TensorFold's list or a Hugging Face
// search. A name, its facts, one muted line (what stands behind its memory figure) and one button, Add. The caller says what the button does.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Rectangle {
  id: row

  property string name: ""
  property string mark: ""          // a derivative's label, or what TensorFold says changed
  property string facts: ""
  property string note: ""
  property bool busy: false
  property string tooltip: ""

  signal addRequested()

  implicitHeight: body.implicitHeight + Style.spacing.lg * 2
  radius: Math.max(Style.cornerRadius, Style.space(6))
  color: Util.alpha(Color.foreground, hover.hovered ? 0.10 : 0.05)
  border.width: Style.normalBorderWidth
  border.color: Util.alpha(Color.foreground, 0.06)
  HoverHandler { id: hover }

  RowLayout {
    id: body
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
          Layout.fillWidth: true
          Layout.maximumWidth: Math.ceil(implicitWidth)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: row.name
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          visible: row.mark !== ""
          textFormat: Text.PlainText
          text: row.mark
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Item { Layout.fillWidth: true }
      }
      Text {
        Layout.fillWidth: true
        visible: row.facts !== ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.facts
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        visible: row.note !== ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.note
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Button {
      Layout.alignment: Qt.AlignVCenter
      text: "Add"
      bordered: true
      opacity: row.busy ? 0.4 : 1
      tooltipText: row.tooltip
      onClicked: row.addRequested()
    }
  }
}
