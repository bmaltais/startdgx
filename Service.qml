// StartDGX: DGX Spark machines and their models, from the Omarchy shell. This file owns the window, the
// cards over it, the IPC entry points and the bar icon's status; DgxService.qml owns the machines and every
// call to bin/startdgx; ManagerView.qml, AddMachineView.qml, UninstallView.qml, ForgetView.qml, AddModelView.qml,
// AddRecipeView.qml, FindView.qml, RecipeRunView.qml, RemoveView.qml and SettingsCard.qml draw what is in it.
//
//   omarchy-shell io.github.bmaltais.startdgx open               toggle the manager
//   omarchy-shell io.github.bmaltais.startdgx addMachine         the manager with its Add machine card
//   omarchy-shell io.github.bmaltais.startdgx uninstall <host>   the manager with a machine's uninstall card
//   omarchy-shell io.github.bmaltais.startdgx addModel <host>    the manager with a machine's model picker
//   omarchy-shell io.github.bmaltais.startdgx addRecipe <host> [path]   the manager with a machine's Add recipe card
//   omarchy-shell io.github.bmaltais.startdgx findModel <host> [query]   the manager with a machine's Find on Hugging Face card
//   omarchy-shell io.github.bmaltais.startdgx removeModel <host> <model>   the manager with a model's remove card
//   omarchy-shell io.github.bmaltais.startdgx forget <host>      the manager with a machine's forget card
//   omarchy-shell io.github.bmaltais.startdgx settings <host> <model|""> <page|"">   a machine's settings window, or a model's, on a page
//   omarchy-shell io.github.bmaltais.startdgx size <width> <height>   the manager at that size, centred (0 0: the default)
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
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
  // A card floats over the manager: "add" (Add machine), "uninstall", "forget", "hostSettings" (one machine's), "modelSettings", "addModel" (a
  // machine's model picker, Add recipe or Find on Hugging Face card), "remove" or "recipeRun" (one model's or recipe's), or "" for none.
  property string card: ""
  // The path the Add recipe card opens with (IPC addRecipe's second argument).
  property string cardPath: ""
  // The query the Find on Hugging Face card opens with and searches at once (IPC findModel's second argument).
  property string cardQuery: ""
  // The confirmation card ("recipeRun"): a measure or a setup of a recipe of yours, its recipe and context.
  property string cardMode: "measure"
  property var cardRecipe: ({})
  property int cardCtx: 0
  // The page a settings window opens on, by its title ("" is the first).
  property string cardPage: ""
  property string cardHost: ""
  property string cardModel: ""

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
  function showManager() {
    root.card = ""
    root.shown = true
    core.refreshAll()
    // Not when a card was opened with it (an IPC call for a card on a closed manager): the card keeps the keys.
    Qt.callLater(function () { if (root.card === "") managerView.focusList() })
  }
  function ensureManager() { if (!root.shown) root.showManager() }

  // Ends what the open card was asking before it goes.
  function dropCard() {
    if (root.card === "add") core.cancelDiscover()
    if (root.card === "find") core.cancelHf()
    if (root.card === "findComfy") core.cancelComfyFind()
    if (root.card === "comfySettings") core.cancelComfyWindow()
    if (root.card === "installComfy") core.cancelComfyPlan()
    root.card = ""
  }
  function close() {
    root.dropCard()
    root.shown = false
  }
  function closeCard() {
    root.dropCard()
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

  // The gear on a machine's row, or on a model's: its settings window. A machine's reads its storage, a model's the
  // context sizes its recipe has measured.
  function showHostSettings(host, page) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.cardPage = page || ""
    root.card = "hostSettings"
    const p = core.poller(host)
    if (p) p.pollStorage()
  }
  function showModelSettings(host, id, page) {
    if (!core.entry(host, id)) return
    root.ensureManager()
    root.cardHost = host
    root.cardModel = id
    root.cardPage = page || ""
    root.card = "modelSettings"
    core.planContext(host, id)
    const p = core.poller(host)
    if (p) p.pollStorage()
  }

  // A recipe's settings, behind the gear on a picker row: its context sizes and what can be done with them.
  function showRecipeSettings(host, r, page) {
    if (!core.hosts[host] || !r) return
    root.ensureManager()
    root.cardHost = host
    root.cardRecipe = r
    root.cardModel = r.id
    root.cardPage = page || ""
    root.card = "recipeSettings"
    core.planContext(host, r.id)
  }

  function showAddModel(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "addModel"
    core.listRecipes(host)
  }
  // The Find on Hugging Face card: the search runs on this computer; the machine is only whose memory the rows are set against.
  function showFind(host, query) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.cardQuery = query || ""
    core.hfRows = null
    core.hfError = ""
    core.hfAsked = ""
    if (!core.recipeBusy) core.draftRepo = ""
    root.card = "find"
  }
  // The Install ComfyUI card: the folder to put it in, on a disk of the machine, checked as it is typed.
  function showInstallComfy(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "installComfy"
    core.comfyPlan = null
    core.comfyPlanFor(host, "")
  }
  // The Find existing ComfyUI card: what the machine has (`comfyui discover`, read-only), with an Adopt for each dgx-comfyui folder.
  function showFindComfy(host) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.card = "findComfy"
    core.findComfy(host)
  }
  // An install's settings window (Open, the service switch, facts, Forget), and the question before Forget. `cardModel` holds the folder.
  function showComfySettings(host, path, page) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.cardModel = path
    root.cardPage = page || ""
    root.card = "comfySettings"
    core.comfyStatusFor(host, path)
    // The workflows are read when the install can have them (installed, and speaking --json).
    const install = (core.comfyui[host] || []).filter(function (i) { return i.path === path })[0]
    if (install && install.kind === "dgx-comfyui" && install.installed !== false && install.json_capable !== false) core.comfyRecipesFor(host, path)
  }
  function showComfyForget(host, path) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.cardModel = path
    root.card = "comfyForget"
  }
  function showAddRecipe(host, path) {
    if (!core.hosts[host]) return
    root.ensureManager()
    root.cardHost = host
    root.cardPath = path || ""
    root.card = "recipe"
    core.loadUserRecipes(host)
  }
  // The card that shows what measuring or setting up a recipe of yours would download, and asks first.
  function showRecipeRun(mode, host, r, ctx) {
    if (!core.hosts[host] || !r || !(ctx > 0)) return
    root.ensureManager()
    root.cardHost = host
    root.cardMode = mode
    root.cardRecipe = r
    root.cardCtx = ctx
    root.card = "recipeRun"
    core.planRecipeRun(host, r.id, ctx)
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
  function setUp(host, r, yes) {
    core.use(host, r, yes)
    root.closeCard()
    Qt.callLater(function () { managerView.select(Model.modelKey(host, r.id)) })
  }

  // What a click or a key asks for, from Model.keyAction or a button.
  function dispatch(action) {
    if (!action) return
    switch (action.type) {
    case "start": core.start(action.host, action.id); break
    case "stop": core.stop(action.host, action.id); break
    case "share": case "unshare": core.share(action.host, action.id, action.type); break
    case "move": core.move(action.host, action.id, action.to); break
    case "hostSettings": root.showHostSettings(action.host, action.page); break
    case "modelSettings": root.showModelSettings(action.host, action.id, action.page); break
    case "recipeSettings": root.showRecipeSettings(action.host, action.recipe, action.page); break
    case "addContext": core.addContext(action.host, action.id, action.ctx); break
    case "removeContext": core.addContext(action.host, action.id, action.ctx, true); break
    case "fixRecipe": core.launch("fix", action.host, action.id); root.close(); break
    case "removeRecipeNow": core.removeRecipe(action.host, action.id); root.closeCard(); break
    case "setContext": core.setContext(action.host, action.id, action.ctx); break
    case "storageSet": core.setStore(action.host, action.path); break
    case "storageUnset": core.unsetStore(action.host); break
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
    case "addRecipe": root.showAddRecipe(action.host, ""); break
    case "findModel": root.showFind(action.host, ""); break
    case "findComfy": root.showFindComfy(action.host); break
    case "installComfy": root.showInstallComfy(action.host); break
    case "comfyInstallNow": core.comfyAct(action.host, "install", action.path, action.label || ""); root.closeCard(); break
    case "comfyToggle": core.comfyAct(action.host, action.kind, action.path); break
    case "comfyAdopt": core.comfyAct(action.host, "adopt", action.path, action.label || ""); break
    case "comfySettings": root.showComfySettings(action.host, action.path, action.page); break
    case "comfyForget": root.showComfyForget(action.host, action.path); break
    case "comfyForgetNow": core.comfyAct(action.host, "forget", action.path, "", !!action.stopService); root.closeCard(); break
    case "comfyOpen": Quickshell.execDetached(Model.webappCommand(action.url)); break
    case "comfyOpenAt": core.comfyOpenFor(action.host, action.path); break
    case "comfyRecipeCheck": core.comfyRecipeCheck(action.host, action.path, action.name); break
    case "comfyRecipeInstall": core.comfyAct(action.host, "recipe-install", action.path, action.name); break
    case "comfyDoctor": core.comfyDoctorFor(action.host, action.path); break
    case "use": root.setUp(action.host, action.recipe, false); break
    case "setupYours": root.showRecipeRun("setup", action.host, action.recipe, Number(action.recipe.context)); break
    case "setupNow": root.setUp(action.host, action.recipe, true); break
    case "measureRecipe": root.showRecipeRun("measure", action.host, action.recipe, action.ctx); break
    case "measureNow": core.measureRecipe(action.host, action.recipe.id, action.ctx); root.closeCard(); break
    case "confirmRecipe": core.confirmRecipe(action.host, action.id); break
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
    function addRecipe(host: string, path: string): void { root.showAddRecipe(host, path) }
    function findModel(host: string, query: string): void { root.showFind(host, query) }
    function removeModel(host: string, model: string): void { root.showRemove(host, model) }
    function forget(host: string): void { root.showForget(host) }
    function settings(host: string, model: string, page: string): void { if (model !== "") root.showModelSettings(host, model, page); else root.showHostSettings(host, page) }
    function size(width: int, height: int): void { root.ensureManager(); win.resizeTo(width, height) }
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
  // An ordinary window of the compositor (an xdg toplevel): the compositor moves, resizes, tiles and closes it, as for any
  // application. A card (a question or a settings window) is drawn over the manager inside it, veiled behind.
  FloatingWindow {
    id: win
    visible: root.shown && root.ready
    title: "StartDGX"
    color: Color.menu.background
    implicitWidth: Style.space(640)
    implicitHeight: Style.space(580)
    minimumSize: Qt.size(Style.space(480), Style.space(300))

    // Closed by the compositor (its close key or button): the manager is closed too, so the next open starts one.
    onVisibleChanged: {
      if (!visible && root.shown && root.ready) root.close()
      else if (visible) titlebarSoon.restart()
    }

    // Whether Omarchy's window mode draws a titlebar (with its own close button) over this window; see DgxModel.hasTitlebar.
    // Asked of Hyprland when the window opens and when it floats, moves or the config reloads (which loads the plugin).
    property bool titlebar: false
    Timer { id: titlebarSoon; interval: 250; onTriggered: if (!titlebarProbe.running) titlebarProbe.running = true }
    Connections {
      target: Hyprland
      function onRawEvent(event) { if (win.visible && Model.TITLEBAR_EVENTS.indexOf(event.name) >= 0) titlebarSoon.restart() }
    }
    Process {
      id: titlebarProbe
      command: ["sh", "-c", "hyprctl clients -j 2>/dev/null; echo '@@plugins'; hyprctl plugin list 2>/dev/null"]
      stdout: StdioCollector { id: titlebarOut; waitForEnd: true }
      onExited: {
        const parts = titlebarOut.text.split("@@plugins")
        win.titlebar = Model.hasTitlebar(parts[0], parts[1] || "", win.title, "org.quickshell")
      }
    }

    // The manager at a given size (IPC `size`, for the test session; 0 0 is the default size).
    function resizeTo(w, h) {
      win.implicitWidth = w > 0 ? Math.max(Style.space(480), w) : Style.space(640)
      win.implicitHeight = h > 0 ? Math.max(Style.space(300), h) : Style.space(580)
    }

    Item {
      id: frame
      anchors.fill: parent
      readonly property real radius: root.radius

      ManagerView {
        id: managerView
        anchors.fill: parent
        svc: root
        onEscapePressed: root.close()
      }

      // Close button in the top-right corner (the compositor's own close key works too). Not under a titlebar: it has one.
      Button {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        z: 10
        // A card has its own close button; two together read ambiguously.
        visible: root.card === "" && !win.titlebar
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
      color: Qt.rgba(0, 0, 0, 0.35)
      // Takes the pointer's hover too, so no row or button behind the veil shows its tooltip through it.
      MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: root.closeCard() }
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
      // The settings windows are wider than the other cards: pages on the left, a page on the right.
      width: Math.min(Style.space(root.card === "hostSettings" || root.card === "modelSettings" || root.card === "recipeSettings" || root.card === "comfySettings" ? 760 : 560), win.width - Style.space(40))
      height: Math.min(Math.max(Style.space(260), cardLoader.item ? (cardLoader.item as Item).implicitHeight : 0), win.height - Style.space(80))
      radius: root.radius
      color: Color.menu.background
      border.width: Style.normalBorderWidth
      border.color: Util.alpha(Color.foreground, 0.14)

      // Swallow clicks so they do not reach the veil behind the card, and hover so the manager's rows under the card
      // (it is wider than the manager, and may be taller) show no tooltip over it.
      MouseArea { anchors.fill: parent; hoverEnabled: true }

      // Built only while open, so a closed card holds nothing.
      Loader {
        id: cardLoader
        property var owner: root
        anchors.fill: parent
        active: root.card !== ""
        sourceComponent: root.card === "uninstall" ? uninstallCard : root.card === "forget" ? forgetCard : root.card === "hostSettings" || root.card === "modelSettings" || root.card === "recipeSettings" || root.card === "comfySettings" ? settingsCard
          : root.card === "addModel" ? addModelCard : root.card === "remove" ? removeCard
          : root.card === "recipe" ? recipeCard : root.card === "recipeRun" ? recipeRunCard : root.card === "find" ? findCard : root.card === "findComfy" ? findComfyCard : root.card === "comfyForget" ? comfyForgetCard : root.card === "installComfy" ? installComfyCard : addCard
        onLoaded: (cardLoader.item as Item).forceActiveFocus()
      }
      Component { id: addCard; AddMachineView { svc: cardLoader.owner } }
      Component { id: uninstallCard; UninstallView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: settingsCard; SettingsCard { svc: cardLoader.owner; kind: cardLoader.owner.card === "hostSettings" ? "host" : cardLoader.owner.card === "recipeSettings" ? "recipe" : cardLoader.owner.card === "comfySettings" ? "comfy" : "model"; path: cardLoader.owner.cardModel; recipeRow: cardLoader.owner.cardRecipe; host: cardLoader.owner.cardHost; model: cardLoader.owner.cardModel; startPage: cardLoader.owner.cardPage } }
      Component { id: forgetCard; ForgetView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: addModelCard; AddModelView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: recipeCard; AddRecipeView { svc: cardLoader.owner; host: cardLoader.owner.cardHost; path: cardLoader.owner.cardPath } }
      Component { id: findCard; FindView { svc: cardLoader.owner; host: cardLoader.owner.cardHost; query: cardLoader.owner.cardQuery } }
      Component { id: installComfyCard; InstallComfyView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: comfyForgetCard; ComfyForgetView { svc: cardLoader.owner; host: cardLoader.owner.cardHost; path: cardLoader.owner.cardModel } }
      Component { id: findComfyCard; FindComfyView { svc: cardLoader.owner; host: cardLoader.owner.cardHost } }
      Component { id: recipeRunCard; RecipeRunView { svc: cardLoader.owner; host: cardLoader.owner.cardHost; mode: cardLoader.owner.cardMode; recipe: cardLoader.owner.cardRecipe; ctx: cardLoader.owner.cardCtx } }
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
