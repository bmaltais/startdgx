// StartDGX: DGX Spark machines and their models, from the Omarchy shell. This file owns the window, the
// cards over it, the IPC entry points and the bar icon's status; DgxService.qml owns the machines and every
// call to bin/startdgx; ManagerView.qml, AddMachineView.qml, UninstallView.qml, ForgetView.qml, AddModelView.qml
// and RemoveView.qml draw what is in it.
//
//   omarchy-shell io.github.bmaltais.startdgx open               toggle the manager
//   omarchy-shell io.github.bmaltais.startdgx addMachine         the manager with its Add machine card
//   omarchy-shell io.github.bmaltais.startdgx uninstall <host>   the manager with a machine's uninstall card
//   omarchy-shell io.github.bmaltais.startdgx addModel <host>    the manager with a machine's model picker
//   omarchy-shell io.github.bmaltais.startdgx removeModel <host> <model>   the manager with a model's remove card
//   omarchy-shell io.github.bmaltais.startdgx forget <host>      the manager with a machine's forget card
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "DgxModel.js" as Model

Item {
  id: root

  // Injected by omarchy-shell (the plugin service loader).
  property var shell: null

  readonly property string cli: Qt.resolvedUrl("bin/startdgx").toString().replace("file://", "")
  readonly property int shadow: Style.space(14)
  readonly property int radius: Math.max(Style.cornerRadius, Style.space(10))
  readonly property alias dgx: core

  // ---- what the window shows ----------------------------------------------
  property bool shown: false
  // A card floats over the manager: "add" (Add machine), "uninstall" or "forget" (one machine's), "addModel" (a
  // machine's model picker) or "remove" (one model's), or "" for none.
  property string card: ""
  property string cardHost: ""
  property string cardModel: ""
  property var targetScreen: null

  // The window is only mapped once the machine list has loaded, so it never flashes empty.
  property bool slow: false
  readonly property bool ready: root.slow || core.loaded
  onShownChanged: {
    root.slow = false
    core.windowOpen = root.shown
    if (root.shown) slowTimer.restart()
  }
  Timer { id: slowTimer; interval: 700; onTriggered: root.slow = true }

  // ---- window control ---------------------------------------------------------
  function focusedScreen() {
    const monitor = Hyprland.focusedMonitor
    const screens = Quickshell.screens
    for (let i = 0; i < screens.length; i++) {
      if (monitor && screens[i].name === monitor.name) return screens[i]
    }
    return screens.length ? screens[0] : null
  }

  function showManager() {
    root.card = ""
    root.targetScreen = root.focusedScreen()
    root.shown = true
    core.refreshAll()
    // Not when a card was opened with it (an IPC call for a card on a closed manager): the card keeps the keys.
    Qt.callLater(function () { if (root.card === "") managerView.focusList() })
  }
  function ensureManager() { if (!root.shown) root.showManager() }

  function close() {
    if (root.card === "add") core.cancelDiscover()
    root.card = ""
    root.shown = false
  }
  function closeCard() {
    if (root.card === "add") core.cancelDiscover()
    root.card = ""
    Qt.callLater(function () { managerView.focusList() })
  }

  function showAddMachine() {
    root.ensureManager()
    root.card = "add"
    core.discover(root.discoverUser)
  }
  // The ssh user typed in the Add machine card, kept while the shell runs ("" is this machine's).
  property string discoverUser: ""
  function showUninstall(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "uninstall"
    core.plan(host, [])
  }

  function showForget(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "forget"
  }

  function showAddModel(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "addModel"
    core.listRecipes(host)
  }
  function showRemove(host, id) {
    if (!Model.removeAction(core.entry(host, id), core.pending[Model.modelKey(host, id)] || "")) return
    root.ensureManager()
    root.cardHost = host
    root.cardModel = id
    root.card = "remove"
    core.planRemove(host, id)
  }
  // Set up a recipe from the picker: the card closes and the cursor goes to the new row, which shows at once.
  function setUp(host, r) {
    core.use(host, r)
    root.closeCard()
    Qt.callLater(function () { managerView.select(Model.modelKey(host, r.id)) })
  }

  // What a click or a key asks for, from Model.keyAction or a button.
  function dispatch(action) {
    if (!action) return
    switch (action.type) {
    case "start": core.start(action.host, action.id); break
    case "stop": core.stop(action.host, action.id); break
    case "logs": core.launch("logs", action.host, action.id); root.close(); break
    case "uninstall": root.showUninstall(action.host); break
    case "forget": root.showForget(action.host); break
    case "forgetNow": core.forget(action.host); root.closeCard(); break
    case "refresh": core.refreshAll(); break
    case "addMachine": root.showAddMachine(); break
    case "addHost": core.addHost(action.host); break
    case "install": core.launch("install", action.host, "", action.replace ? ["--replace-engine"] : []); root.close(); break
    case "uninstallNow": core.launch("uninstall", action.host, "", action.flags || []); root.close(); break
    case "addModel": root.showAddModel(action.host); break
    case "use": root.setUp(action.host, action.recipe); break
    case "removeModel": root.showRemove(action.host, action.id); break
    case "removeNow": core.remove(action.host, action.id); root.closeCard(); break
    }
  }

  // ---- messages -----------------------------------------------------------------------------
  // The footers say what an action did, for a few seconds.
  readonly property string notice: core.error !== "" ? core.error : core.notice
  readonly property bool noticeIsError: core.error !== ""
  // What a footer says: the latest message, or how to close.
  readonly property string footerText: root.notice !== "" ? root.notice : "Esc to close"
  readonly property string noticeKey: (core.error !== "" ? "!" : "") + root.notice
  onNoticeKeyChanged: if (root.notice !== "") noticeTimer.restart()
  Timer { id: noticeTimer; interval: 6000; onTriggered: { core.notice = ""; core.error = "" } }

  // ---- IPC -------------------------------------------------------------------------
  IpcHandler {
    target: "io.github.bmaltais.startdgx"
    function state(): string { return JSON.stringify({ hosts: core.hosts, hostState: core.hostState, pending: core.pending, setups: core.setups }) }
    function refresh(): string { core.refreshAll(); return "ok" }
    function open(): void { if (root.shown) root.close(); else root.showManager() }
    function toggle(): void { if (root.shown) root.close(); else root.showManager() }
    function close(): void { root.close() }
    function addMachine(): void { root.showAddMachine() }
    function uninstall(host: string): void { root.showUninstall(host) }
    function addModel(host: string): void { root.showAddModel(host) }
    function removeModel(host: string, model: string): void { root.showRemove(host, model) }
    function forget(host: string): void { root.showForget(host) }
    function start(host: string, model: string): string { core.start(host, model); return "ok" }
    function stop(host: string, model: string): string { core.stop(host, model); return "ok" }
  }

  DgxService {
    id: core
    script: root.cli
  }

  // ---- the bar icon's status ---------------------------------------------------------------
  // The icon (BarWidget.qml) is a separate instance and cannot see the machines, so the state it draws (idle,
  // running, busy, alert) is written to a file it watches, whenever it changes.
  readonly property string statusDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/startdgx"
  readonly property string barKind: core.summary.kind
  property bool statusDirReady: false
  Process {
    running: true
    command: ["mkdir", "-p", root.statusDir]
    onExited: root.statusDirReady = true
  }
  FileView {
    id: statusFile
    path: root.statusDir + "/status"
    printErrors: false
    atomicWrites: true
  }
  function writeStatus() { if (root.statusDirReady) statusFile.setText(root.barKind) }
  onBarKindChanged: root.writeStatus()
  onStatusDirReadyChanged: root.writeStatus()

  // ---- the window ------------------------------------------------------------------------
  PanelWindow {
    id: win
    visible: root.shown && root.ready
    screen: root.targetScreen
    color: "transparent"
    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-startdgx"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // The card opens centred; dragging its top strip moves it. The offsets are from the centre, so the card
    // stays where it was put when its size changes. (Not remembered across restarts: see docs/ui-standards.md.)
    property real dragX: 0
    property real dragY: 0
    property real sizeW: 0
    property real sizeH: 0
    onHeightChanged: if (visible) win.moveBy(0, 0)

    function resetWindow() { win.sizeW = 0; win.sizeH = 0; win.dragX = 0; win.dragY = 0 }
    // The top-left corner stays put: the card is centred plus an offset, so a change of size moves the centre by half of it.
    function resizeBy(dx, dy) {
      const w = Math.max(Style.space(480), Math.min(win.width - Style.space(40), frame.width + dx))
      const h = Math.max(Style.space(300), Math.min(win.height - Style.space(40), frame.height + dy))
      win.dragX += (w - frame.width) / 2
      win.dragY += (h - frame.height) / 2
      win.sizeW = w
      win.sizeH = h
    }
    // Keeps the card on the screen: at least the top strip stays reachable.
    function moveBy(dx, dy) {
      if (win.width <= 0 || win.height <= 0) return
      const grab = Style.space(60)
      const maxX = (win.width + frame.width) / 2 - grab
      const minY = -(win.height - frame.height) / 2
      const maxY = (win.height + frame.height) / 2 - grab
      win.dragX = Math.max(-maxX, Math.min(maxX, win.dragX + dx))
      win.dragY = Math.max(minY, Math.min(maxY, win.dragY + dy))
    }

    // Click outside the card to dismiss it (the card over the manager first).
    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: { if (root.card !== "") root.closeCard(); else root.close() } }
    }

    RectangularShadow {
      anchors.fill: frame
      radius: frame.radius
      blur: root.shadow
      offset.y: Style.space(4)
      color: Qt.rgba(0, 0, 0, 0.6)
    }

    Rectangle {
      id: frame
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: win.dragX
      anchors.verticalCenterOffset: win.dragY
      width: win.sizeW > 0 ? win.sizeW : Style.space(640)
      height: win.sizeH > 0 ? win.sizeH
        : Math.max(Style.space(300), Math.min(managerView.implicitHeight, Style.space(580), (win.screen ? win.screen.height : 900) - Style.space(80)))
      radius: root.radius
      color: Color.menu.background
      border.width: Style.normalBorderWidth
      border.color: Util.alpha(Color.foreground, 0.14)

      // Swallow clicks so they do not reach the dismiss area behind the card.
      MouseArea { anchors.fill: parent }

      // Drag the top strip to move the card. Declared before the view so its own buttons sit above it.
      MouseArea {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(60)
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real pressX: 0
        property real pressY: 0
        onPressed: function (mouse) { pressX = mouse.x; pressY = mouse.y }
        onPositionChanged: function (mouse) {
          if (pressed) win.moveBy(mouse.x - pressX, mouse.y - pressY)
        }
      }

      ManagerView {
        id: managerView
        anchors.fill: parent
        svc: root
        onEscapePressed: root.close()
      }

      // Resize handle in the bottom-right corner: a small grip and a resize pointer.
      MouseArea {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Style.space(22)
        height: Style.space(22)
        z: 10
        cursorShape: Qt.SizeFDiagCursor
        property real pressX: 0
        property real pressY: 0
        onPressed: function (mouse) { pressX = mouse.x; pressY = mouse.y }
        onPositionChanged: function (mouse) {
          if (pressed) win.resizeBy(mouse.x - pressX, mouse.y - pressY)
        }
        onDoubleClicked: win.resetWindow()
        Repeater {
          model: [0, 1]
          Rectangle {
            required property int index
            width: Style.space(10) - index * Style.space(5)
            height: Math.max(1, Style.normalBorderWidth)
            radius: height / 2
            color: Util.alpha(Color.foreground, 0.30)
            rotation: -45
            x: parent.width - Style.space(14) + index * Style.space(5)
            y: parent.height - Style.space(9) - index * Style.space(5) + Style.space(1)
            transformOrigin: Item.Center
          }
        }
      }

      // Close button in the card's top-right corner.
      Button {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        z: 10
        iconText: "\uf00d"
        tooltipText: "Close"
        onClicked: root.close()
      }
    }

    // ---- a card over the manager -----------------------------------------------------------------
    // The manager stays where it is, dimmed; closing the card brings it back.
    Rectangle {
      visible: root.card !== ""
      anchors.fill: frame
      radius: frame.radius
      color: Qt.rgba(0, 0, 0, 0.35)
      MouseArea { anchors.fill: parent; onClicked: root.closeCard() }
    }

    RectangularShadow {
      visible: cardFrame.visible
      anchors.fill: cardFrame
      radius: cardFrame.radius
      blur: root.shadow
      offset.y: Style.space(4)
      color: Qt.rgba(0, 0, 0, 0.6)
    }

    Rectangle {
      id: cardFrame
      visible: root.card !== ""
      anchors.centerIn: frame
      width: Math.min(Style.space(560), win.width - Style.space(40))
      height: Math.min(Math.max(Style.space(260), cardLoader.item ? (cardLoader.item as Item).implicitHeight : 0), win.height - Style.space(80))
      radius: root.radius
      color: Color.menu.background
      border.width: Style.normalBorderWidth
      border.color: Util.alpha(Color.foreground, 0.14)

      // Swallow clicks so they do not reach the veil behind the card.
      MouseArea { anchors.fill: parent }

      // Built only while open, so a closed card holds nothing.
      Loader {
        id: cardLoader
        property var owner: root
        anchors.fill: parent
        active: root.card !== ""
        sourceComponent: root.card === "uninstall" ? uninstallCard : root.card === "forget" ? forgetCard
          : root.card === "addModel" ? addModelCard : root.card === "remove" ? removeCard : addCard
        onLoaded: (cardLoader.item as Item).forceActiveFocus()
      }
      Component { id: addCard; AddMachineView { svc: cardLoader.owner } }
      Component { id: uninstallCard; UninstallView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: forgetCard; ForgetView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: addModelCard; AddModelView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: removeCard; RemoveView { svc: cardLoader.owner; host: cardLoader.owner.cardHost; model: cardLoader.owner.cardModel } }

      Button {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        z: 10
        iconText: "\uf00d"
        tooltipText: "Close"
        onClicked: root.closeCard()
      }
    }
  }
}
