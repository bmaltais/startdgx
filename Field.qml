// A single-line text field in the Start family's look.
import QtQuick
import qs.Commons

Rectangle {
  id: field

  property alias text: input.text
  property string placeholder: ""
  readonly property bool focused: input.activeFocus
  signal accepted()
  signal escaped()      // Escape was pressed in the box; the key still goes on to the window

  function focusInput() { input.forceActiveFocus() }

  implicitHeight: Style.space(34)
  radius: Math.max(Style.cornerRadius, Style.space(5))
  color: Util.alpha(Color.foreground, 0.06)
  border.width: Style.normalBorderWidth
  border.color: Util.alpha(Color.foreground, input.activeFocus ? 0.30 : 0.12)

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.xxl
    anchors.rightMargin: Style.spacing.xxl
    verticalAlignment: TextInput.AlignVCenter
    color: Color.foreground
    selectionColor: Util.alpha(Color.accent, 0.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    clip: true
    // Read-only until focused: an editable TextInput reads the clipboard on every
    // change (to know if it can paste), so an idle one would fetch foreign text.
    readOnly: !activeFocus
    onAccepted: field.accepted()
    Keys.onEscapePressed: function (event) { field.escaped(); event.accepted = false }

    Text {
      textFormat: Text.PlainText
      visible: input.text === ""
      anchors.verticalCenter: parent.verticalCenter
      text: field.placeholder
      color: Color.muted
      font: input.font
    }
  }
}
