// A machine's, a model's or a ComfyUI install's settings, behind the gear on its row: the settings window of the Start family (pages on the left, the
// page on the right, changes apply at once), floating over the manager. The rows keep to a name, a status and a few buttons; what
// else there is to do or set is here. DgxModel builds the pages (hostPages, modelPages, comfyPages) and says what a click asks for
// (hostChange, modelChange, comfyChange); this file only wires them to the service. Esc closes (a search is cleared first).
pragma ComponentBehavior: Bound
import QtQuick
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string kind: "host"          // "host", "model", "recipe" (a row of the model picker) or "comfy" (an install)
  property string host: ""
  property string model: ""
  property string path: ""              // a "comfy" window's install: its folder
  property var recipeRow: ({})          // the picker row a "recipe" window was opened from, until the list says better
  property string startPage: ""         // the title of the page to open on ("" is the first)

  readonly property var dgx: card.svc.dgx
  readonly property string machine: Model.hostName(card.host)
  readonly property var status: (card.dgx.shownState[card.host] || {}).status || null
  readonly property var storage: card.dgx.storage[card.host] || null
  readonly property var entry: card.kind === "model" ? card.dgx.entry(card.host, card.model) : null
  readonly property string key: Model.modelKey(card.host, card.model)
  readonly property string pending: card.dgx.pending[card.key] || ""
  readonly property string sharing: card.dgx.pending[Model.shareKey(card.host, card.model)] || ""
  readonly property bool mine: card.dgx.variantsHost === card.host && card.dgx.variantsId === card.model
  readonly property var choices: card.kind === "model" && card.mine && card.dgx.variants && card.entry
    ? Model.contextChoices(card.dgx.variants, card.entry.ctx, card.status ? card.status.ram_total_gib : 0) : []
  // A ComfyUI install: its row as the manager draws it, the answer of `comfyui status` for it (read when the window opens and
  // after each click), and a click waiting.
  readonly property var comfyInstall: card.kind === "comfy" ? (card.dgx.comfyui[card.host] || []).filter(function (i) { return i.path === card.path })[0] || null : null
  readonly property var comfyInfo: card.comfyInstall ? Model.comfyRow(card.comfyInstall, card.status) : null
  readonly property string comfyPending: card.kind === "comfy" ? card.dgx.pending[Model.comfyKey(card.host, card.path)] || "" : ""
  readonly property bool comfyMine: card.dgx.comfyStatusKey === card.host + "\n" + card.path
  readonly property var comfyAnswer: card.kind === "comfy" && card.comfyMine ? card.dgx.comfyStatus : null
  onComfyPendingChanged: if (card.kind === "comfy" && card.comfyPending === "") card.dgx.comfyStatusFor(card.host, card.path)
  // What was typed that won't do, until the next change.
  property string problem: ""

  readonly property var recipeNow: {
    if (card.kind !== "recipe") return null
    const list = card.dgx.listHost === card.host && Array.isArray(card.dgx.recipes) ? card.dgx.recipes : []
    return list.find(function (r) { return r.id === card.model }) || card.recipeRow
  }

  readonly property var pages: card.kind === "comfy"
    ? (card.comfyInfo ? Model.comfyPages({ host: card.host, info: card.comfyInfo, answer: card.comfyAnswer, error: card.comfyMine ? card.dgx.comfyStatusError : "", pending: card.comfyPending }) : [])
    : card.kind === "recipe"
    ? Model.recipePages({ recipe: card.recipeNow, variants: card.mine ? card.dgx.variants : null, loading: card.mine && card.dgx.variantsLoading,
        error: card.mine ? card.dgx.variantsError : "", busy: card.dgx.recipeBusy || card.dgx.recipeRemoving !== "" })
    : card.kind === "host"
    ? Model.hostPages({
        machine: card.machine, update: Model.engineUpdate(card.status), needsSetup: !!card.dgx.setupNeeded[card.host],
        storage: card.storage, readError: card.dgx.storageErrors[card.host] || "", busy: (card.dgx.pending[card.host + "/"] || "") !== "" })
    : card.entry ? Model.modelPages({
        entry: card.entry, pending: card.pending, sharing: card.sharing, store: card.storage ? card.storage.store : null,
        location: Model.locationOf(card.storage, card.model), choices: card.choices,
        variantsLoading: card.mine && card.dgx.variantsLoading, variantsError: card.mine ? card.dgx.variantsError : "",
        away: Model.isAway(card.dgx.shownState[card.host]) }) : []
  readonly property var values: card.kind === "comfy" ? Model.comfyValues(card.comfyAnswer) : card.kind === "recipe" ? ({}) : card.kind === "host" ? Model.hostValues(card.storage) : Model.modelValues(card.entry)

  // The model went (a removal finished): nothing left to set.
  readonly property bool gone: (card.kind === "model" && !card.entry) || (card.kind === "comfy" && !card.comfyInstall)
  onGoneChanged: if (card.gone) card.svc.closeCard()

  implicitHeight: win.implicitHeight

  // Opens on the page asked for; again when the window is pointed at another machine, model or page while open.
  property bool built: false
  function start() {
    if (!card.built) return
    win.reset()
    card.problem = ""
    for (let i = 0; i < card.pages.length; i++) if (card.pages[i].title === card.startPage) win.page = i
  }
  Component.onCompleted: { card.built = true; card.start() }
  onKindChanged: card.start()
  onHostChanged: card.start()
  onModelChanged: card.start()
  onPathChanged: card.start()
  onStartPageChanged: card.start()

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
  }

  SettingsWindow {
    id: win
    anchors.fill: parent
    title: card.kind === "comfy" ? String(card.comfyInfo ? card.comfyInfo.name : card.path) : card.kind === "recipe" ? String(card.recipeNow.name || card.model) : card.kind === "host" ? card.machine : String(card.entry ? card.entry.name || card.model : card.model)
    subtitle: card.kind === "comfy" ? "COMFYUI  ·  ON " + card.machine.toUpperCase() : card.kind === "recipe" ? "RECIPE  ·  ON " + card.machine.toUpperCase() : card.kind === "host" ? "SETTINGS" : "SETTINGS  ·  ON " + card.machine.toUpperCase()
    pages: card.pages
    values: card.values
    footerText: card.problem !== "" ? card.problem : card.svc.notice !== "" ? card.svc.notice : "Changes apply instantly"
    footerIsError: card.problem !== "" || (card.svc.notice !== "" && card.svc.noticeIsError)

    onChanged: function (key, value) {
      card.problem = ""
      if (card.kind === "comfy") {
        const action = Model.comfyChange(card.host, card.comfyInfo, card.comfyAnswer, key, value)
        if (action) card.svc.dispatch(action)
      } else if (card.kind === "recipe") {
        const action = Model.recipeChange(card.host, card.recipeNow, key, value)
        if (action) card.svc.dispatch(action)
      } else if (card.kind === "host") {
        const r = Model.hostChange(card.host, key, value, card.storage)
        if (r.error) card.problem = r.error
        if (r.action) card.svc.dispatch(r.action)
      } else {
        const action = Model.modelChange(card.host, card.model, key, value, card.entry)
        if (action) card.svc.dispatch(action)
      }
    }
  }
}
