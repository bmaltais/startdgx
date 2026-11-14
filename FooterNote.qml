// The line at the right of a footer: the latest message (red for an error) or how to close. A message too long for one
// line takes a second, and one cut even then is whole on hover: an error is never left unreadable. Messages come from the
// CLI and are drawn as plain text.
import QtQuick
import qs.Commons
import qs.Ui

Text {
  id: note

  property var svc

  horizontalAlignment: Text.AlignRight
  verticalAlignment: Text.AlignVCenter
  textFormat: Text.PlainText
  wrapMode: Text.Wrap
  maximumLineCount: 2
  elide: Text.ElideRight
  text: note.svc ? note.svc.footerText : ""
  color: note.svc && note.svc.notice !== "" && note.svc.noticeIsError ? Color.urgent : Color.muted
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall

  HoverHandler { id: hover }
  PanelToolTip {
    visible: hover.hovered && note.truncated
    text: note.text
  }
}
