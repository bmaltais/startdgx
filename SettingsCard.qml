// A machine's or a model's settings, behind the gear on its row: the settings window of the Start family (pages on the left, the
// page on the right, changes apply at once), floating over the manager. The rows keep to a name, a status and a few buttons; what
// else there is to do or set is here. DgxModel builds the pages (hostPages, modelPages) and says what a click asks for
// (hostChange, modelChange); this file only wires them to the service. Esc closes (a search is cleared first).
pragma ComponentBehavior: Bound
import QtQuick
import "DgxModel.js" as Model

FocusScope {
  id: card

  property var svc
  property string kind: "host"          // "host" or "model"
  property string host: ""
  property string model: ""
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
  // What was typed that won't do, until the next change.
  property string problem: ""

  readonly property var pages: card.kind === "host"
    ? Model.hostPages({
        machine: card.machine, update: Model.engineUpdate(card.status), needsSetup: !!card.dgx.setupNeeded[card.host],
        storage: card.storage, readError: card.dgx.storageErrors[card.host] || "", busy: (card.dgx.pending[card.host + "/"] || "") !== "" })
    : card.entry ? Model.modelPages({
        entry: card.entry, pending: card.pending, sharing: card.sharing, store: card.storage ? card.storage.store : null,
        location: Model.locationOf(card.storage, card.model), choices: card.choices,
        variantsLoading: card.mine && card.dgx.variantsLoading, variantsError: card.mine ? card.dgx.variantsError : "",
        away: Model.isAway(card.dgx.shownState[card.host]) }) : []
  readonly property var values: card.kind === "host" ? Model.hostValues(card.storage) : Model.modelValues(card.entry)

  // The model went (a removal finished): nothing left to set.
  readonly property bool gone: card.kind === "model" && !card.entry
  onGoneChanged: if (card.gone) card.svc.closeCard()

  implicitHeight: win.implicitHeight

  Component.onCompleted: {
    for (let i = 0; i < card.pages.length; i++) if (card.pages[i].title === card.startPage) win.page = i
  }

  Keys.onPressed: event => {
    if (event.key === Qt.Key_Escape) { card.svc.closeCard(); event.accepted = true }
  }

  SettingsWindow {
    id: win
    anchors.fill: parent
    title: card.kind === "host" ? card.machine : String(card.entry ? card.entry.name || card.model : card.model)
    subtitle: card.kind === "host" ? "SETTINGS" : "SETTINGS  ·  ON " + card.machine.toUpperCase()
    pages: card.pages
    values: card.values
    footerText: card.problem !== "" ? card.problem : card.svc.notice !== "" ? card.svc.notice : "Changes apply instantly"
    footerIsError: card.problem !== "" || (card.svc.notice !== "" && card.svc.noticeIsError)

    onChanged: function (key, value) {
      card.problem = ""
      if (card.kind === "host") {
        const r = Model.hostChange(card.host, key, value, card.storage)
        if (r.error) card.problem = r.error
        if (r.action) card.svc.dispatch(r.action)
      } else {
        const action = Model.modelChange(card.host, card.model, key, value)
        if (action) card.svc.dispatch(action)
      }
    }
  }
}
