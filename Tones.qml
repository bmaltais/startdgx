// qmllint disable import
// (Qt's qmllint warns on every singleton file it lints on its own, even with its qmldir right beside it; the qmldir declares it.)
pragma Singleton
import QtQuick
import qs.Commons
import "DgxModel.js" as Model

// The colours text takes where the theme's own would not read. A theme's "muted" can be 2.5:1 on its own background, so
// muted text is not that colour and not a fixed opacity either: it is the dimmest the foreground can be (no dimmer than 55%,
// the kit's muted) that still reaches 4.5:1 (WCAG AA) on what it sits on. That is the menu's background lifted by the
// hover tint, the lightest it gets, so a row under the pointer reads too (`DgxModel.readableOn`). Pick every new text colour
// here, never by an opacity written at the element.
QtObject {
  readonly property color surface: Qt.tint(Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1), Util.alpha(Color.foreground, 0.08))
  readonly property color muted: Model.readableOn(Color.foreground, surface, 4.5, 0.55)
}
