// A machine's model storage card, over the manager: where it keeps its model files. By default its internal disk; an
// external disk can be added as a model store, which models are then moved to and from one at a time (Move to USB
// on a model's row). Lists the disks the machine could use, takes a folder of your own, and removes the store
// (the CLI refuses while models are on it, and says so in the footer). Esc closes.
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

  readonly property var dgx: card.svc.dgx
  readonly property string machine: Model.hostName(card.host)
  readonly property var storage: card.dgx.storage[card.host] || null
  readonly property var disks: Model.diskRows(card.storage)
  readonly property string readError: card.dgx.storageErrors[card.host] || ""
  // A store change is running or waiting its turn: its buttons wait.
  readonly property bool busy: (card.dgx.pending[card.host + "/"] || "") !== ""
  readonly property string pathProblem: Model.storagePathProblem(pathField.text)
  // Models whose files are linked into the current store (not one that only has a spare copy there): switching stores
  // under them would strand those files.
  readonly property int onStore: card.storage ? card.storage.models.filter(function (m) { return m.location !== "nvme" && m.location !== "both" }).length : 0

  readonly property string storePath: card.storage && card.storage.store ? String(card.storage.store.path) : ""
  // A change to another folder waits until no model has files on the current store (the machine refuses it too).
  function canUse(path) { return !card.busy && card.storage !== null && (card.onStore === 0 || path === card.storePath) }
  function use(path) { if (card.canUse(path)) card.svc.dispatch({ type: "storageSet", host: card.host, path: path }) }

  implicitHeight: col.implicitHeight + Style.spacing.panelPadding * 2

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
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
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: "Model storage on " + card.machine
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: "WHERE ITS MODEL FILES LIVE"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      visible: card.storage !== null || card.readError === ""
      text: card.storage ? Model.storageSummary(card.storage) : "Asking the machine…"
      color: card.storage && card.storage.store && !card.storage.store.present ? Color.urgent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      Layout.fillWidth: true
      visible: card.readError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.readError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      visible: card.onStore > 0
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.onStore + " model" + (card.onStore === 1 ? " has" : "s have") + " files on the store. Move " + (card.onStore === 1 ? "it" : "them") + " back to the internal disk (Move to NVMe on the row) before choosing another folder or removing the store."
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "A model store is a folder on an external disk. Setting one up moves nothing: each model has a Move to USB button on its row, which copies it, checks it and frees the internal disk. A model on the store loads from there, a little slower than from the internal disk."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      text: "EXTERNAL DISKS"
      visible: card.disks.length > 0
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      Layout.fillWidth: true
      visible: card.storage !== null && card.disks.length === 0
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "No external disk is mounted on " + card.machine + ". Plug one in, or type a folder on a disk that is mounted below."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: card.disks
      delegate: RowLayout {
        id: diskRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.spacing.lg
        opacity: diskRow.modelData.usable ? 1 : 0.6
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            text: diskRow.modelData.text
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            Layout.fillWidth: true
            visible: !diskRow.modelData.usable
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Can't be used: " + diskRow.modelData.reason
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          visible: diskRow.modelData.inUse
          text: "In use"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        SettingsPill {
          visible: diskRow.modelData.usable && !diskRow.modelData.inUse
          opacity: card.canUse(diskRow.modelData.mount + "/startdgx-models") ? 1 : 0.5
          text: "Use this disk"
          onClicked: card.use(diskRow.modelData.mount + "/startdgx-models")
        }
      }
    }

    Text {
      text: "OR A FOLDER OF YOUR OWN"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      TextField {
        id: pathField
        Layout.fillWidth: true
        placeholderText: "/media/you/disk/models"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        onAccepted: if (card.pathProblem === "") card.use(pathField.text.trim())
      }
      SettingsPill {
        text: "Use this folder"
        opacity: card.pathProblem !== "" || !card.canUse(pathField.text.trim()) ? 0.5 : 1
        onClicked: if (card.pathProblem === "") card.use(pathField.text.trim())
      }
    }
    Text {
      Layout.fillWidth: true
      visible: pathField.text !== "" && card.pathProblem !== ""
      text: card.pathProblem
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: card.busy ? "Working on the machine…" : card.svc.footerText
        color: card.svc.notice !== "" && card.svc.noticeIsError ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      SettingsPill {
        visible: card.storage !== null && card.storage.store !== null
        opacity: card.busy || card.onStore > 0 ? 0.5 : 1
        text: "Remove store"
        danger: true
        // Files on the store stay where they are; the machine refuses while any model is linked into it, and so does this button.
        onClicked: if (!card.busy && card.onStore === 0) card.svc.dispatch({ type: "storageUnset", host: card.host })
      }
      SettingsPill {
        text: "Close"
        onClicked: card.svc.closeCard()
      }
    }
  }
}
