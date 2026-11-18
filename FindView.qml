// A machine's Find more models card, over the manager, with two sources: TensorFold's published list for one DGX Spark (the first one) and a search of Hugging Face for MLX 4-bit models of a known family
// (`startdgx hf search --json`, run on this computer: it reaches no machine). Every row is a repo whose config.json was
// read: its parameters, license and base model, a mark on an abliterated or uncensored derivative (a toggle hides those),
// and the weights' size next to the machine's memory as two plain numbers. No row says it fits: only a measuring run does
// (docs/adr/0001). Draft recipe on a row writes a drafted recipe for that repo and adds it to the machine through the Add recipe
// path (TensorFold's list, the other source on the card, drafts the same way: its figure is an estimate, so the draft isn't a fit either); With an agent… opens a terminal where an agent finishes the recipe (`startdgx launch author`); its steps, warnings and any clash or validation error show under the toggle, line by line. Enter searches, Esc drops the typed query and then closes the card.
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
  property string query: ""
  // The card's source: "hf" (a search of Hugging Face) or "tf" (TensorFold's list for one DGX Spark).
  property string source: "tf"
  property bool showBlocked: false
  readonly property bool tf: card.source === "tf"
  readonly property var tfList: card.dgx.tfList
  // The machine's own recipe list, so a row says where its model stands there (not added, added and not measured, already on it).
  readonly property var recipes: card.dgx.listHost === card.host ? card.dgx.recipes : null
  function stateOf(recipeId) { return Model.findState(recipeId, card.recipes, card.hostState ? card.hostState.status : null) }
  // Set up… on a row that is ready: the card that shows the download first, as for any recipe of yours.
  function setUpAdded(state) {
    if (state.recipe && Number(state.recipe.context) > 0) card.svc.dispatch({ type: "setupYours", host: card.host, recipe: state.recipe })
  }
  function measureAdded(state) {
    if (!state.recipe) return
    if (state.measureCtx > 0) card.svc.dispatch({ type: "measureRecipe", host: card.host, recipe: state.recipe, ctx: state.measureCtx })
    else card.svc.dispatch({ type: "addRecipe", host: card.host })
  }
  readonly property var tfParts: Model.tfSplit(card.tfList)
  // The rows to show: those that can be added, and the others too once asked for.
  readonly property var tfShown: card.showBlocked ? card.tfParts.ready.concat(card.tfParts.blocked) : card.tfParts.ready
  readonly property bool tfLoading: card.dgx.tfLoading

  function pickSource(name) {
    card.source = name
    // Opening the list saves this look: what is new or changed since the last visit is marked for this one.
    if (name === "tf" && card.dgx.tfList === null && !card.tfLoading) card.dgx.loadTf(true, card.host)
  }

  readonly property var dgx: card.svc.dgx
  readonly property var hostState: card.dgx.shownState[card.host] || null
  readonly property real ramGib: card.hostState && card.hostState.status ? Number(card.hostState.status.ram_total_gib) || 0 : 0
  // Derivative-labelled rows are shown until the person hides them (the maintainer's decision, #31).
  property bool showDerivatives: true
  readonly property var rows: Model.hfShown(card.dgx.hfRows, card.showDerivatives)
  readonly property string toggleText: Model.hfToggleText(card.dgx.hfRows, card.showDerivatives)
  readonly property bool searching: card.dgx.hfSearching
  readonly property bool asked: card.dgx.hfAsked !== "" || card.dgx.hfRows !== null

  // Draft recipe on a result: the card's own account of the last one (drafting it, then the Add recipe path's check and add).
  readonly property bool drafting: card.dgx.recipeHost === card.host && card.dgx.draftRepo !== ""
  readonly property string draftStep: card.dgx.draftStep !== "" ? card.dgx.draftStep : card.dgx.recipeStep
  readonly property var draftResult: card.drafting && card.dgx.draftId !== "" && card.dgx.recipeResult && card.dgx.recipeResult.id === card.dgx.draftId ? card.dgx.recipeResult : null
  readonly property string draftFailure: !card.drafting ? "" : card.dgx.draftError !== "" ? card.dgx.draftError : card.dgx.recipeError
  readonly property int shownErrors: 8

  function draft(repo) {
    if (!card.dgx.recipeBusy) card.dgx.draftRecipe(card.host, repo)
  }
  function draftEntry(row) {
    if (!card.dgx.recipeBusy) card.dgx.draftTensorfold(card.host, row, card.picked[row.id] || null)
  }
  // What was picked in each TensorFold row's choices (context, requests at once, input), by entry id, and the row whose choices are open.
  property var picked: ({})
  // The row whose Update waits for its second click (a measured recipe loses its measurement).
  property string confirming: ""
  function update(row, st) {
    const plan = Model.tfUpdatePlan(row, st)
    if (plan.kind !== "update" || card.dgx.recipeBusy) return
    if (plan.confirm && card.confirming !== row.id) { card.confirming = row.id; return }
    card.confirming = ""
    card.dgx.draftTensorfold(card.host, row, Model.tfAddedChoices(row), plan.confirm)
  }
  property string customizing: ""
  function pick(id, key, value) {
    const next = Object.assign({}, card.picked)
    next[id] = Object.assign({}, next[id] || {})
    next[id][key] = value
    card.picked = next
  }

  // With an agent…: a terminal that drafts and lets an agent finish the recipe; nothing comes back to the card.
  function author(repo) {
    const l = Model.authorLaunch(card.host, repo)
    if (l) card.dgx.launch(l.verb, l.host, l.id)
  }

  function go() {
    if (!card.searching) card.dgx.searchHf(queryField.text)
  }

  // A model just added changes what the rows say.
  onDraftResultChanged: if (card.draftResult && card.draftResult.ok) { card.dgx.listRecipes(card.host); if (card.tf && !card.tfLoading) card.dgx.loadTf(false, card.host) }

  Component.onCompleted: {
    card.dgx.listRecipes(card.host)
    queryField.text = card.query
    if (card.query !== "") { card.source = "hf"; card.go() }
    else card.pickSource("tf")
  }
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
        elide: Text.ElideRight
        text: "Find more models"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: card.tf ? (card.tfLoading ? "READING TENSORFOLD'S LIST…" : card.dgx.tfError !== "" ? "THE LIST DID NOT LOAD" : Model.tfSummary(card.tfList) || "MODELS FOR ONE DGX SPARK")
          : card.searching ? "SEARCHING HUGGING FACE…" : card.dgx.hfError !== "" ? "THE SEARCH DID NOT RUN"
          : card.dgx.hfRows !== null ? card.rows.length + (card.rows.length === 1 ? " MODEL" : " MODELS") + " FOUND" : "MLX 4-BIT MODELS OF A KNOWN FAMILY"
        color: (card.tf ? card.dgx.tfError : card.dgx.hfError) !== "" ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    // Where to look: a search of Hugging Face, or the list TensorFold publishes for one DGX Spark.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md
      SettingsPill { text: "TensorFold"; primary: card.tf; onClicked: card.pickSource("tf") }
      SettingsPill { text: "Hugging Face"; primary: !card.tf; onClicked: card.pickSource("hf") }
      Item { Layout.fillWidth: true }
    }

    Text {
      Layout.fillWidth: true
      visible: card.tf
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Models TensorFold publishes for one DGX Spark, read from this computer. Add puts one on " + Model.hostName(card.host) + " with TensorFold's memory estimate; Set up… then downloads and starts it there. Measure… is optional: it replaces the estimate with real numbers."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      Layout.fillWidth: true
      visible: !card.tf
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Searches from this computer; no machine is asked. Each result's config.json says it is MLX affine 4-bit and of a family known to work. Whether it fits " + Model.hostName(card.host) + " is only known after a measuring run."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    TextField {
      id: queryField
      visible: !card.tf
      Layout.fillWidth: true
      focus: true
      placeholderText: "qwen, gemma, lfm…"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      onAccepted: card.go()
      // Esc drops what was typed first, then closes the card.
      Keys.onEscapePressed: event => {
        if (queryField.text !== "") { queryField.text = ""; event.accepted = true }
        else event.accepted = false
      }
    }

    SwitchRow {
      Layout.fillWidth: true
      visible: !card.tf && card.toggleText !== ""
      label: card.toggleText
      description: "Repos labelled abliterated or uncensored from their name or tags; the others are not touched."
      checked: card.showDerivatives
      onClicked: card.showDerivatives = !card.showDerivatives
    }

    Text {
      Layout.fillWidth: true
      visible: !card.tf && card.dgx.hfError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.hfError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // A search that found nothing says so, apart from one that did not run.
    Text {
      Layout.fillWidth: true
      visible: !card.tf && card.dgx.hfRows !== null && card.dgx.hfError === "" && !card.searching && card.rows.length === 0
      wrapMode: Text.Wrap
      text: card.dgx.hfRows !== null && card.dgx.hfRows.length > 0 ? "Every result is hidden by the toggle." : "No MLX 4-bit repo of a known family matched."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      Layout.fillWidth: true
      visible: card.tf && card.dgx.tfError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.dgx.tfError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // Draft recipe: where it is, its warnings, and each error found, on its own row.
    Text {
      Layout.fillWidth: true
      visible: card.drafting && card.draftStep !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: Model.draftStatus(card.draftStep, card.host, card.dgx.draftRepo)
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftFailure !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.draftFailure
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    // A recipe the machine already has that the rows above don't show: Add recipe… lists the machine's recipes of yours, with Remove.
    RowLayout {
      Layout.fillWidth: true
      visible: card.draftFailure.indexOf("already has a recipe") >= 0
      Button {
        text: "Your recipes on " + Model.hostName(card.host) + "…"
        bordered: true
        fontSize: Style.font.bodySmall
        tooltipText: "Opens Add recipe…, which lists the recipes of yours on this machine, to measure or remove one"
        onClicked: card.svc.dispatch({ type: "addRecipe", host: card.host })
      }
      Item { Layout.fillWidth: true }
    }
    Repeater {
      model: card.drafting ? card.dgx.draftWarnings : []
      delegate: Text {
        required property string modelData
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: "Warning: " + modelData
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    Repeater {
      model: card.draftResult && !card.draftResult.ok ? card.draftResult.errors.slice(0, card.shownErrors) : []
      delegate: ErrorRow {
        required property string modelData
        Layout.fillWidth: true
        message: modelData
      }
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftResult !== null && !card.draftResult.ok && card.draftResult.errors.length > card.shownErrors
      text: card.draftResult ? "and " + (card.draftResult.errors.length - card.shownErrors) + " more" : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: card.draftResult !== null && card.draftResult.ok && card.draftResult.added === true
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: card.draftResult ? Model.draftDone(card.host, card.draftResult.id, card.dgx.draftSource) : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    RowLayout {
      visible: !card.tf
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: list.contentHeight
      spacing: Style.spacing.md

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: contentHeight
        clip: true
        spacing: Style.spacing.md
        model: card.rows
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: hfRow
          required property var modelData
          readonly property string label: Model.hfLabel(hfRow.modelData)
          readonly property var st: card.stateOf(String(hfRow.modelData.recipe_id || ""))
          width: ListView.view.width
          implicitHeight: body.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, hover.hovered ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: Util.alpha(Color.foreground, 0.06)
          HoverHandler { id: hover }

          ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.xxs
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.md
              Text {
                // As wide as the repo's name, and cut when the row is narrower: its label keeps its room.
                Layout.fillWidth: true
                Layout.maximumWidth: Math.ceil(implicitWidth)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: hfRow.modelData.repo
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              // A derivative says so, in the foreground colour: accent is for the one thing to do and the selected state.
              Text {
                visible: hfRow.label !== ""
                textFormat: Text.PlainText
                text: hfRow.label
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Item { Layout.fillWidth: true }
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: Model.hfRowText(hfRow.modelData)
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.lg
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: Model.hfMemoryLine(hfRow.modelData, card.ramGib)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              // A row's actions are bordered buttons, as in the model picker and Add machine.
              Button {
                text: Model.AUTHOR_TEXT
                bordered: true
                fontSize: Style.font.bodySmall
                opacity: Model.authorLaunch(card.host, hfRow.modelData.repo) ? 1 : 0.4
                tooltipText: Model.authorHint()
                onClicked: card.author(hfRow.modelData.repo)
              }
              Text {
                visible: hfRow.st.state !== ""
                textFormat: Text.PlainText
                text: Model.findStateText(hfRow.st)
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                visible: hfRow.st.state === "unmeasured"
                text: "Measure…"
                bordered: true
                fontSize: Style.font.bodySmall
                tooltipText: "Download " + hfRow.modelData.repo + ", load it and bench it on " + Model.hostName(card.host) + ". Shows the download and asks first"
                onClicked: card.measureAdded(hfRow.st)
              }
              Button {
                visible: hfRow.st.state === ""
                text: "Add"
                bordered: true
                fontSize: Style.font.bodySmall
                opacity: card.dgx.recipeBusy ? 0.4 : 1
                tooltipText: "Add " + hfRow.modelData.repo + " to " + Model.hostName(card.host) + ". It isn't measured yet, so it can't run until you press Measure…"
                onClicked: card.draft(hfRow.modelData.repo)
              }
            }
          }
        }
      }

      ScrollTrack {
        target: list
        Layout.fillHeight: true
        Layout.preferredWidth: implicitWidth
      }
    }

    RowLayout {
      visible: card.tf
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredHeight: tfView.contentHeight
      spacing: Style.spacing.md

      ListView {
        id: tfView
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: contentHeight
        clip: true
        spacing: Style.spacing.md
        model: card.tfShown
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: tfRow
          required property var modelData
          readonly property string note: Model.tfRowNote(tfRow.modelData)
          readonly property var st: card.stateOf(tfRow.modelData.recipeId)
          width: ListView.view.width
          implicitHeight: tfBody.implicitHeight + Style.spacing.lg * 2
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(Color.foreground, tfHover.hovered ? 0.10 : 0.05)
          border.width: Style.normalBorderWidth
          border.color: Util.alpha(Color.foreground, 0.06)
          HoverHandler { id: tfHover }

          ColumnLayout {
            id: tfBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.xxs
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.md
              Text {
                Layout.fillWidth: true
                Layout.maximumWidth: Math.ceil(implicitWidth)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: tfRow.modelData.name
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              // New or changed since the look last saved, in the foreground colour (accent is for the one thing to do).
              Text {
                visible: tfRow.modelData.status !== ""
                textFormat: Text.PlainText
                text: tfRow.modelData.status
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Item { Layout.fillWidth: true }
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: Model.tfRowText(tfRow.modelData)
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.lg
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: tfRow.note
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: tfRow.st.state !== ""
                textFormat: Text.PlainText
                text: Model.tfStateText(tfRow.modelData, tfRow.st)
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                visible: Model.tfUpdatePlan(tfRow.modelData, tfRow.st).kind === "update"
                text: card.confirming === tfRow.modelData.id ? "Discard its measurement and update" : "Update"
                bordered: true
                fontSize: Style.font.bodySmall
                opacity: card.dgx.recipeBusy ? 0.4 : 1
                tooltipText: "Add " + tfRow.modelData.name + " to " + Model.hostName(card.host) + " again from TensorFold's current version, with the choices it had" + (Model.tfUpdatePlan(tfRow.modelData, tfRow.st).confirm ? ". It was measured: the measurement is discarded and it has to be measured again" : "")
                onClicked: card.update(tfRow.modelData, tfRow.st)
              }
              TextLink {
                visible: tfRow.st.state === "ready" && !tfRow.st.measured && tfRow.st.measureCtx > 0
                text: "Measure…"
                tooltip: "Optional: download it, load it and bench it on " + Model.hostName(card.host) + ", to replace TensorFold's estimate with real numbers"
                onClicked: card.measureAdded(tfRow.st)
              }
              Button {
                visible: tfRow.st.state === "ready"
                text: "Set up…"
                bordered: true
                fontSize: Style.font.bodySmall
                tooltipText: "Download " + tfRow.modelData.name + " to " + Model.hostName(card.host) + " and start it. Shows the download and asks first"
                onClicked: card.setUpAdded(tfRow.st)
              }
              Button {
                visible: tfRow.st.state === "unmeasured"
                text: "Measure…"
                bordered: true
                fontSize: Style.font.bodySmall
                tooltipText: "Download " + tfRow.modelData.name + ", load it and bench it on " + Model.hostName(card.host) + ". Its numbers don't count until then. Shows the download and asks first"
                onClicked: card.measureAdded(tfRow.st)
              }
              TextLink {
                visible: tfRow.modelData.settings !== null && tfRow.st.state === ""
                text: Model.tfCustomized(tfRow.modelData.settings, card.picked[tfRow.modelData.id]) ? "Customized" : "Customize"
                tooltip: "Context, requests at once and input, as on tensorfold.dev"
                picked: card.customizing === tfRow.modelData.id
                onClicked: card.customizing = card.customizing === tfRow.modelData.id ? "" : tfRow.modelData.id
              }
              Button {
                visible: tfRow.modelData.draftable && tfRow.st.state === ""
                text: "Add"
                bordered: true
                fontSize: Style.font.bodySmall
                opacity: card.dgx.recipeBusy ? 0.4 : 1
                tooltipText: "Add " + tfRow.modelData.name + " to " + Model.hostName(card.host) + ". It isn't measured yet, so it can't run until you press Measure…"
                onClicked: card.draftEntry(tfRow.modelData)
              }
            }

            // The same three choices tensorfold.dev offers for this model, as pills; each becomes a launch flag of the recipe.
            ColumnLayout {
              id: tfChoices
              Layout.fillWidth: true
              visible: card.customizing === tfRow.modelData.id && tfRow.modelData.settings !== null && tfRow.st.state === ""
              spacing: Style.spacing.md
              readonly property var values: Model.tfValues(tfRow.modelData.settings, card.picked[tfRow.modelData.id])

              Repeater {
                model: [{ key: "context", title: "Context", name: "contexts" }, { key: "parallel", title: "Requests at once", name: "requests" }, { key: "input", title: "Input", name: "inputs" }]
                delegate: RowLayout {
                  id: choiceRow
                  required property var modelData
                  readonly property var options: tfRow.modelData.settings ? tfRow.modelData.settings[choiceRow.modelData.name] : []
                  Layout.fillWidth: true
                  spacing: Style.spacing.md
                  Text {
                    Layout.preferredWidth: Style.space(120)
                    text: choiceRow.modelData.title
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.md
                    Repeater {
                      model: choiceRow.options
                      delegate: SettingsPill {
                        id: choice
                        required property var modelData
                        text: Model.tfChoiceLabel(choiceRow.modelData.key, choice.modelData)
                        primary: tfChoices.values[choiceRow.modelData.key] === choice.modelData
                        onClicked: card.pick(tfRow.modelData.id, choiceRow.modelData.key, choice.modelData)
                      }
                    }
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "TensorFold's memory figure is for its default settings. Measure… finds the real numbers for the ones you pick."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }

      ScrollTrack {
        target: tfView
        Layout.fillHeight: true
        Layout.preferredWidth: implicitWidth
      }
    }

    // What can't be added yet is one quiet line, with its rows a click away.
    TextLink {
      visible: card.tf && card.tfParts.blocked.length > 0
      text: Model.tfBlockedText(card.tfParts.blocked) + " \u00b7 " + (card.showBlocked ? "Hide" : "Show")
      onClicked: card.showBlocked = !card.showBlocked
    }

    Item { Layout.fillHeight: true; visible: card.tf ? card.tfShown.length === 0 : card.rows.length === 0 }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.lg
      Text {
        Layout.fillWidth: true
        text: card.tf ? "Esc to close" : "Enter to search · Esc to close"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      SettingsPill {
        visible: !card.tf
        text: "Search"
        primary: true
        opacity: card.searching ? 0.4 : 1
        onClicked: card.go()
      }

    }
  }
}
