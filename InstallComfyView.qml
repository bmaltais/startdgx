// The Install ComfyUI card, over the manager: a new dgx-comfyui in a folder on the machine, picked here. The disks of the machine
// (`startdgx comfyui plan --json`) are offered with the room each has; the folder is typed (or chosen from them) and checked on
// the machine as it is typed: it must be new or empty, writable, with 40 GiB free. Install then clones the release startdgx pins
// and installs it in the background on the machine (about 15 minutes), and the new row shows how it goes. Keyboard: Enter
// installs when the folder is good, Esc closes.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string host: ""
  // The folder typed, and the one the last plan was asked for.
  property string folder: ""
  property bool seeded: false

  readonly property var dgx: card.svc.dgx
  readonly property var plan: card.dgx.comfyPlan
  readonly property string machine: Model.hostName(card.host)
  readonly property var choices: Model.comfyFolderChoices(card.plan)
  readonly property var ready: Model.comfyInstallReady(card.plan && card.plan.path === card.typed ? card.plan : null, card.typed)
  readonly property string typed: card.folder.trim()
  readonly property bool busy: (card.dgx.pending[Model.comfyKey(card.host, card.typed)] || "") !== ""

  function install() {
    if (!card.ready.ready || card.busy) return
    card.svc.dispatch({ type: "comfyInstallNow", host: card.host, path: card.typed, label: labelField.text.trim() })
  }
  function useFolder(path) {
    folderField.text = path
    card.folder = path
    card.check()
  }
  // The folder typed is checked on the machine a moment after the last key.
  function check() {
    if (card.typed !== "") card.dgx.comfyPlanFor(card.host, card.typed)
  }
  // The first answer (the disks, and the machine's home) puts a folder in the field, ready to check.
  onPlanChanged: if (card.plan && !card.seeded) {
    const first = Model.comfyFolderChoices(card.plan)
    card.seeded = true
    if (first.length > 0) card.useFolder(first[0].folder)
  }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2
  Timer { id: checkSoon; interval: 400; onTriggered: card.check() }

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!event.isAutoRepeat) card.install()
      event.accepted = true
    }
  }

  ColumnLayout {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.panelGap

    ColumnLayout {
      Layout.fillWidth: true
      Layout.rightMargin: Style.space(32)
      spacing: 0
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: "Install ComfyUI on " + card.machine
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.dgx.comfyPlanError !== "" ? "THE MACHINE COULD NOT BE READ" : card.plan ? "A NEW COPY, IN A FOLDER YOU PICK" : "LOOKING AT ITS DISKS…"
        color: card.dgx.comfyPlanError !== "" ? Color.urgent : Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      visible: card.dgx.comfyPlanError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.comfyPlanError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // The disks, with their room: one click puts a folder on it in the field.
    ColumnLayout {
      Layout.fillWidth: true
      visible: card.choices.length > 0
      spacing: Style.spacing.xs
      Text {
        text: "On this disk"
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Flow {
        Layout.fillWidth: true
        spacing: Style.spacing.md
        Repeater {
          model: card.choices
          delegate: Button {
            id: choice
            required property var modelData
            bordered: true
            text: choice.modelData.text
            tooltipText: "Install in " + choice.modelData.folder
            onClicked: { card.useFolder(choice.modelData.folder); folderField.forceActiveFocus() }
          }
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xs
      Text {
        text: "Folder on " + card.machine
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      TextField {
        id: folderField
        Layout.fillWidth: true
        placeholderText: "/home/you/dgx-comfyui"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        onTextEdited: { card.folder = text; checkSoon.restart() }
        onAccepted: card.install()
      }
      Text {
        Layout.fillWidth: true
        visible: card.ready.text !== ""
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: card.ready.text
        color: card.ready.ready ? Color.foreground : card.ready.text === "Checking…" ? Tones.muted : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.xs
      Text {
        text: "Name in the panel (optional)"
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      TextField {
        id: labelField
        Layout.fillWidth: true
        placeholderText: "the folder's name"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        onAccepted: card.install()
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "It installs in the background on " + card.machine + " and takes about 15 minutes; the new row shows how it goes. The machine's account must stay logged in for that (it lingers): if it doesn't, this says what to run."
      color: Tones.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: "Enter to install · Esc to close"
        color: Tones.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        text: "Cancel"
        onClicked: card.svc.closeCard()
      }
      SettingsPill {
        text: "Install"
        enabled: card.ready.ready && !card.busy
        opacity: enabled ? 1 : 0.45
        onClicked: card.install()
      }
    }
  }
}
