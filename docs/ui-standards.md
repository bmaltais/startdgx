# UI standards

How StartDGX looks and behaves. **The shared rules are in the devkit: [scripts/devkit/docs/ui-standards.md](../scripts/devkit/docs/ui-standards.md)** (principles, windows, moving and resizing, remembered state, controls, words, notifications). Read it first. This file holds only where StartDGX differs from it or adds to it, and the [decision log](#decision-log).

**Both files are the source of truth for the UI.** A change that makes a design decision neither covers, or goes against one, updates the file it concerns in the same change and adds a line to the decision log. A UI change without a matching update is not finished.

The kit's fifth principle names this app's tool: the QML never runs ssh, the engine or a terminal itself; it asks `bin/startdgx`, and only through `DgxService.qml` and `HostPoller.qml`. Its only other processes are local: `notify-send` (with `--` and the body escaped) and the `mkdir` of the bar icon's status folder (see the decision log).

## Differences from the shared rules

- **No settings window yet**, so no first run, no Window page and no *Remember size* / *Remember position* switches.
- **Size and position are not remembered** across a shell restart: the manager moves and resizes as the kit says, and opens centred at its default size after a restart (see the decision log).
- **Cards, not settings windows, float over the manager**: Add machine, a machine's uninstall card, model picker and Add recipe card, and a model's remove card and context card. They follow the stacking rules (the manager stays behind under a 35% veil, Esc and a click outside close only the card), but they are centred on the manager, sized to their content (560 wide), and neither move nor resize.

## The manager

```
┌──────────────────────────────────────────────────────────┐
│ ▣ StartDGX                                         [⟳] ✕ │  header
│   3 MACHINES · 1 RUNNING · 1 FAILED · 1 NOT ANSWERING     │
│ MACHINES                                                  │
│ ● spark-a  demo@spark-a · DGX Spark · 128 GB  Logs… Uninstall… Forget │  a machine
│   ┌─────────────────────────────────────────────────────┐ │
│   │ ◆ Qwen3.8 27B                          [▤] [🗑] [⏸]  │ │  a model
│   │   ● Running · 128K context                          │ │
│   │   Memory  ━━━━━━━━━━──────────────     28 of 122 GiB │ │
│   └─────────────────────────────────────────────────────┘ │
│   [ +  Add model…                                       ] │
│ ● spark-c  demo@spark-c didn't answer in time · last seen 3 min ago │
│ [+ Add machine…]                            Esc to close ◢│  footer
└──────────────────────────────────────────────────────────┘
```

- **Header.** The chip mark, the name, the count line in small capitals (red while a machine doesn't answer or a model failed), and look again (refresh). The words come from `DgxModel.subtitle`.
- **A machine.** A dot (accent when it answers, red when it doesn't, muted before its first answer), its name, its SSH target and what it is (`DgxModel.hostLine`). Under it: "Asking the machine…", "No models set up yet", or why it doesn't answer and when it last did (`offlineText`). On the right, quiet text links: **Logs…** (the model started last), **Uninstall…** and **Forget…**. A machine that doesn't answer keeps its last known models, dimmed and without buttons.
- **A model.** Its maker's mark, its name (the endpoint on hover), a status dot and line (`DgxModel.modelState`: Running, Loading, Stopping, Removing, Cancelling, Waiting to download, Downloading, Failed, Not enough memory, Stopped) with its context and the memory it took, then **Share** (the Tailscale mark: lit while shared, struck through while private; any model that is set up), **Logs…**, **Remove…** (a muted trash; **Cancel the setup…**, an ✕, while it downloads) and **Start/Stop**. A model that doesn't fit has its play button greyed out with the reason as its tooltip. Under it, a meter (`DgxModel.meter`): memory while it runs; progress while it loads, stops or is removed, against how long that took last time; the download while it is set up (an empty Waiting bar until it begins). A failure's reason is a red link to its logs.
- **Start and stop** show once their command runs on the machine ("pending"), and the machine's next answer after the command replaces it. So does a **removal**: the row says Removing (Cancelling, for a setup) until the model is gone. Each machine runs two commands at once: a start (which returns only once its model has loaded), and a stop, set up or removal beside it, each with its queue (`DgxModel.submit`). A command waiting its turn leaves the row as the machine says, with "· stop queued" (start, removal) after it; a start waiting its turn can be taken back with Stop.
- **A machine that needs its root setup.** When Set up fails because the engine says the machine needs Podman set up as root first (`DgxModel.setupNeeded`), the machine says so in red and gets an **Install…** link: `install --replace-engine` in a terminal, which backs up an engine startdgx didn't install and does the root setup. The footer only points at it.
- **Add model…** is the last row of a machine that answers (a cursor row like the others); it opens the machine's model picker.
- **Footer.** **Add machine…** on the left, the latest message (six seconds, red for an error) or "Esc to close" on the right. A setup's message drops the engine's pointers to the agents panel and journalctl (`DgxModel.actionNotice`): the row follows the setup.
- **Keyboard.** The keys are `DgxModel.keyAction`, so a key and a button cannot disagree (a machine that isn't answering has no Start, Stop or Logs either way, and a model that doesn't fit is never started); each button's tooltip names its key. No single key destroys anything: `d`, `u` and `f` open a card that asks. A held Enter, `s`, `t`, `d` or `f` acts once (its auto-repeat is ignored, in the cards too).

| Key | Does |
|---|---|
| Up, Down, `k`, `j` | Move the cursor over machines and models |
| Enter, `s` | Start or stop the model under the cursor (on Add model…: open the picker) |
| `t` | Share the model under the cursor with the tailnet, or stop sharing it |
| `a` | Add a model to the machine… |
| `e` | Add a recipe of your own to the machine… (in the model picker too) |
| `d`, Delete | Remove the model… (or cancel its setup) |
| `l` | Its logs… (a machine's row: the model started last) |
| `u` | Uninstall the machine… |
| `f` | Forget the machine… (a card asks first) |
| `n` | Add machine… |
| `r` | Look again |
| Esc | Close |

## Add machine

Lists `startdgx discover --json` (it installs nothing and changes nothing on the machines; its ssh saves the host key of a machine it has never seen, in `~/.ssh/known_hosts`): each machine of the tailnet with its target and what it can do (`DgxModel.peerOffer`). A DGX Spark with startdgx's engine has **Add**, which adds it at once and marks it Added; one without an engine has **Install…**, which opens the install in a terminal (sudo asks there) and closes the window; one with an engine startdgx didn't install has both, and says that Install… backs that engine up first (`install --replace-engine`; uninstall puts it back). A machine that isn't a Spark, or doesn't answer, says so, dimmed (a machine that wants a password says to run `ssh-copy-id`). **User on the machines** is the ssh user discover asks as (empty: this machine's); Enter there, or **Look again**, asks the tailnet again as that user. Up/Down, Enter, `r`, Esc.

## Add model

A machine's model picker: every recipe of its catalog (`startdgx list HOST`), sorted by `DgxModel.recipeOffers`: the engine's recommendation first (marked *recommended*, its own `best`), then what the machine can run and doesn't have, what it has (*On this machine*) or is setting up, and what it can't run, dimmed, with the engine's reason. Each shows its maker's mark, the memory it takes, its context and speed on this machine class (`recipeFacts`) and its summary. **Set up** (Enter) runs `use --detach`, closes the card and puts the cursor on the new row, which shows at once as *Waiting to download* (`withSetups`) until the machine lists it, then follows the download through the status poll, then loads. A failure (exit code non-zero) takes the row away again and puts the CLI's last stderr line in the footer. **Look again** (`r`) reads the catalog again. **Add recipe…** (`e`) opens the Add recipe card. A user recipe wears a *yours* mark, and one whose numbers aren't measured says so (*estimated*, *drafted, not yet fitting*); a drafted recipe is dimmed, can't be set up, and says why. Up/Down, Enter, `r`, `e`, Esc.

## Add recipe

A machine's card for adding a **user recipe**: a `.toml` you wrote, on this computer, in the **curated recipe**'s format. It takes a path (Esc drops the typed path first, then closes the card; the path is only handed to `startdgx recipe`, which reads the file, so there is no file dialog). **Add** (Enter) validates first with `recipe validate --json` and adds with `recipe add --json` only when nothing is wrong; **Check only** validates and changes nothing. Each error the engine finds is a row of its own (the first eight, then "and N more"); a machine that doesn't answer, or a file that can't be read, is one red line instead (the CLI exits 0 for a rejection, since the machine answered, and non-zero for the rest, so the card can tell them apart). The recipe's id is the file's name without `.toml`, which is what the engine does too.

Under the field, **your recipes on this machine** (`recipe list --json`, the rows with `user`): each with its id and marks, and **Remove**, which asks the engine (`recipe remove`) and shows its message in red when a model set up from the recipe is there, naming the model. Removing needs no card to ask first: only the recipe goes, and its file is still on this computer. Add, Remove, Confirm and a measure are writes, run one at a time and never ended by closing the card; the card's questions (validate, the list, the variants, a dry run) are Queries.

**Variants** (a link on each recipe) lists the recipe's context sizes with their source (`startdgx variants`, which reads the machine's own recipes and yours). A drafted variant has **Measure…**; an estimated one has **Confirm** (`recipe confirm`: it then counts as fitting) and **Measure…**; a measured one has neither.

## Recipe run

A recipe of yours downloads what it names and runs it, so the engine wants `--yes` for both a **measure** and a **setup**, and the panel sends it only from this card. **Measure…** (a variant) and **Set up…** (the picker's button on a user recipe) open it: it asks the machine what that would do (`recipe measure HOST ID --ctx N` without `--yes`, which changes nothing; for a setup the recipe's own context) and shows the engine's lines, the download first. Only **Download and measure** / **Download and set up** (or Enter, once the lines are shown) goes ahead; **Not now**, Esc or a click outside close it and nothing happens. A machine that can't say leaves the pill off. A measure takes minutes, holds the engine's lock and restarts a model that runs there, so it is a write nothing ends, with a message when it is done; a setup follows the model's own row. Setting up a curated recipe has no card, as before.

A **variant**'s **source** says where its numbers come from: *measured* (the default, and every curated recipe's), *estimated*, or *drafted*. A recipe without `user` or `source` is curated and measured. A drafted variant never counts as fitting, in the picker (the recipe is dimmed and can't be set up) and in the context card (its size is greyed out, with why); an estimated one is marked as such, and the engine's own `recipe confirm` decides when it counts (not offered here yet). An unrecognised source is treated as drafted. Demo mode ships three files in `demo/recipes/` (a measured one, a drafted one, a broken one with several errors); `scripts/dev recipe HOST [PATH]` opens the card with a path typed in.

## Remove

`startdgx delete` stops the model if it runs and deletes its weights at once, so the card is the question: it first asks the machine what that frees (`delete HOST MODEL --dry-run --json`, read-only) and says so (`removeConfirm`: "freeing 47.5 GiB that no other model uses", or that the weights are shared and nothing is freed). For a download in progress it is *Cancel the setup…*, which deletes what was downloaded so far. The **Remove** pill (danger) and Enter wait for that answer; if the machine can't give it, the card says why in red and the removal can still go ahead. **Keep it**, Esc or a click outside close it and nothing happens. The removal runs with a 600 s timeout, since it returns only once the model is gone.

## Forget

A machine's **Forget…** (`f`) asks in a card: it takes the machine off this list, nothing on the machine changes, and Add machine can add it again. **Forget** (danger) or Enter forgets it; **Keep it**, Esc or a click outside close it.

## Uninstall

`startdgx launch uninstall` runs the real uninstall at once, so the card is the confirmation: it first shows the plan (`startdgx uninstall HOST --dry-run --json`, which changes nothing), and its **Uninstall…** pill (danger, enabled only once the plan for the chosen opt-ins has been read) opens the terminal that does it. Opt-ins, off by default and shown only where they would do something (`DgxModel.uninstallChoices`), say what they cost: **Also delete the recipes you added** (`--delete-recipes`; your recipes live in the engine's state dir, which uninstall otherwise deletes, so they are kept unless this is on, and the install manifest never records them), **Also delete the model weights** (`--delete-models`, with the space it frees) and **Also remove the packages the install added** (`--remove-packages`, naming them; anything else that uses them stops working, python3 always stays). Each change asks for the plan again; a removal apt would widen fails there and keeps the pill off. **Cancel**, Esc or a click outside close it and nothing happens.

## Terminals

Install, uninstall and logs need a person at a terminal, so they run in Omarchy's floating terminal through `startdgx launch`, started detached, and the window closes to get out of the way. Nothing comes back to the manager: the terminal shows the result (Omarchy's Done/Failed prompt), and in demo mode, where the launch only prints what it would run, nothing is shown at all.

## Words

- A **machine** is a DGX Spark added to startdgx (its SSH target); a **model** is one of the engine's recipes set up on it.
- A **user recipe** is one you added from a `.toml` of your own (marked *yours*); a **curated recipe** ships with the engine. A **variant** is one context size of a recipe with its memory, and its **source** (measured, estimated or drafted) says where those numbers come from.
- *Add* puts a machine that already runs the engine on the list; *Install…* sets the engine up on one; *Uninstall…* takes it off again; *Forget…* only takes the machine off this list, after a question.

## The bar icon

A server glyph at the end of the right section: dim when nothing runs, accent while a model runs or moves, red when a machine doesn't answer or a model failed. Left click opens or closes the manager, right click looks again. It reads one word (`idle`, `running`, `busy`, `alert`, from `DgxModel.summarize`) from `~/.cache/startdgx/status`, which the service rewrites whenever it changes.

## Notifications

A model that fails, or a setup that does, is a critical notification, once per failure and again if it comes back with another reason (`DgxModel.alerts`); not while the manager is open.

## Shared UI code

`ScrollTrack.qml` and `SettingsPill.qml` are StartDrive's, unchanged. `Meter.qml`, `TextLink.qml`, `VendorIcon.qml`, `ModelRow.qml` and `AddModelView.qml` (its recipe rows) are adapted from Omarchy's agents plugin, and so are parts of `DgxModel.js` (the status validation, the start and stop progress curve, the download figures); each says so in its header, with DHH's line in `LICENSE`. They use the shell's theme colours in place of the bar's and literal English in place of the agents strings. The images in `assets/` are the agents plugin's, unchanged: `assets/NOTICE` carries its MIT notice and says the makers' logos are their companies' trademarks, used only to name each model's maker.

## Decision log

Newest first. One line each: what was decided, and why.

| Date | Decision | Why |
|---|---|---|
| 2026-11-12 | A recipe of yours needs a confirmation card (its dry-run download, then Download and measure / set up) before the panel passes `--yes`; variants offer Measure… and Confirm by source; uninstall keeps your recipes unless `--delete-recipes` | The engine refuses `use` and `measure --yes` on a user recipe without `--yes`, since it downloads what the recipe names and runs it as a model: the panel must not pass it unseen, so it shows the engine's own dry run and asks once. The dry run needs a context, so a setup uses the recipe's own. Confirm is one click (it only accepts numbers, undone by editing the file). Uninstall deletes the engine's whole state dir, which holds your recipes and what you confirmed; they are the user's work, so they stay unless asked (the manifest records nothing for them, since startdgx creates none). The picker still reads plain `list`: the engine's `recipe_listing` serves it and `recipe list` alike, with `user` and `source`. |
| 2026-11-12 | Add recipe… is a card opened from the model picker (and key `e`, IPC `addRecipe`) that takes a typed path, validates first and shows each engine error on its own row; user recipes wear *yours*, and a drafted recipe is dimmed as not yet fitting, in the picker and the context card | The engine's catalog only grew by editing its checkout. A path field, not a file dialog or pasted TOML (out of scope), keeps the QML away from files: `startdgx recipe` reads it and sends it on stdin, named for its id because the engine takes the id from the file name. The engine's rejections are one error per line, so each is a row; the CLI's `--json` returns them as an answer (exit 0), apart from a host that didn't answer. Add and remove are writes, so they run in Processes nothing kills, not in a Query. Removal has no confirming card: only the recipe goes, and its file is still here; the engine refuses while a model uses it, and that message is shown as it is. A drafted variant never fits (the engine's rule, repeated in the panel so a stale or partial listing can't offer it), and an unrecognised source is treated as drafted. |
| 2026-11-12 | A machine whose engine is an older release than the plugin's pin shows "Engine X; Y is available" and an Update… link, which opens the same terminal install as Install… (no `--replace-engine`) | Each pin bump left installed hosts behind with nothing saying so. The CLI compares the manifest's tag with the pin and adds `engine_update` to `status` (still one ssh per poll), so the rule is in one place; only an older fork release counts, so an update never downgrades. No auto-update and no check against GitHub: the engine runs as root, and the pin is deliberate. Update needs sudo, so it is a terminal launch like Install. |
| 2026-11-12 | A set-up model has a sliders button (key `c`) that opens a context card: the contexts its recipe has measured, what each needs, the one running, and Use on the others; one that needs more memory than the machine has is greyed, with why | Context size was fixed at the largest that fit. The engine runs only measured contexts (`use --ctx` refuses the rest, and keeps the old setup if a start fails), so the card lists those instead of a free-form box that would invent a RAM figure. Read from the recipe file on the host (`startdgx variants`), since the engine's list gives only the chosen one. Choosing restarts the model (the engine's re-run of `use`), so the card says requests in flight are interrupted; it shows no mark of its own, like a setup, and the row's Loading bar shows the restart. Not offered while the model loads, stops or is removed. Sampling settings stay with the clients. |
| 2026-11-12 | The share mark's tooltip says what the state means for other machines ("Shared: Omarchy on your other machines lists this model. Click to make it private") | A click on the lit mark made the model vanish from Omarchy's list on the paired desktop, which read as a bug; the old text ("Stop sharing") didn't say who stops seeing it. |
| 2026-11-12 | Each model has a share toggle, the Tailscale mark (lit while shared, struck through while private; key `t`), for any model that is set up, running or not | Sharing was CLI-only (#10). Omarchy's agents panel offers it only for a running model on the same machine; the engine keeps a model shared while stopped and lists it on the tailnet in whatever state it is, so hiding the toggle on a stopped model would leave it shared with no way to stop it from the panel. The mark is the one Omarchy's tailscale panel draws (dot grid, MIT notice kept). A share's mark lives under `host/model#share`, apart from the model's own, so it never hides a Loading or Stopping, nor Start and Stop, and no stop supersedes it (a removal only takes back the model's shares still waiting); it runs in a slot of its own (the engine's share takes its own lock, not the start or removal's), so neither a load nor a 25-minute removal holds it up, and a share never holds up a stop. A share the engine can't publish (Serve not enabled) is taken back by `startdgx share` and fails in one line that says the model is not shared, since the engine saves a share before it publishes it. |
| 2026-11-12 | Forget has its own line, beside adds; discover stops at a time limit (60 s) and when its card closes | A forget waited behind an add to a machine that was timing out; a tailnet of hung peers kept discover going for minutes. The CLI locks hosts.json for each change, so the two lines can't lose each other's. |
| 2026-11-11 | A card's question (catalog, removal or uninstall plan, the tailnet) runs through one Query each: a new one ends the old, waits for its exit, drops that answer, then asks | Killing and restarting one Process let the old one's exit arrive after the restart and read as the new card's error. Closing Add machine ends its discover. |
| 2026-11-11 | notify-send and the status folder's mkdir stay in the QML; AGENTS.md's Layout rule now says so | The smaller of the two fixes the review allowed: moving them into the CLI would add two commands, and demo mode's wall (which refuses every process) would then take the nested session's notifications away. Neither reaches a machine; notify-send gets `--` before its text and the body's `&<>` escaped (`DgxModel.notifyCommand`). |
| 2026-11-11 | The uninstall card offers `--delete-models` and `--remove-packages` as opt-ins, off by default, read from a new `uninstall --dry-run --json` | They were command-line only; each states its cost (the space, the packages), and the plan is asked again with them so what the terminal does is what was shown. |
| 2026-11-11 | Forget asks in a card; a held key acts once | No single key should be destructive: `f` alone took a machine off the list, and a held Enter or `s` started and stopped a model again and again. |
| 2026-11-11 | A Spark with an engine startdgx didn't install offers Add and Install…; a Set up that fails for want of the root setup offers Install… on its machine | Add works with that engine as it is; Install (`--replace-engine`, harmless where the engine is startdgx's) is the way to the root setup the engine asks for in a terminal. |
| 2026-11-11 | Add machine has a User on the machines field (discover `--user`), not a free-form target | Discover asked only as this machine's user; a typed user keeps the card's list, host keys and offers. |
| 2026-11-11 | Discover's ssh takes a never-seen machine's host key (`accept-new`), and only discover's | With BatchMode alone a Spark this machine never reached was unreachable and got no Install. Its peers are the tailnet's, which the user chose to list; a changed key is still refused and says so. Add and install check against the key it saved. |
| 2026-11-11 | Two command slots per machine: one start at a time, and a stop, set up or removal beside it; a mark shows once its command runs, "queued" before | The engine's `stop` and `use --detach` take no lock, so a Stop sent during a load really runs; its `start` and `remove` take the engine's lock, so a removal of a model that is loading sends a stop first (its start holds the lock until the load ends), and a removal of another model waits on the engine (its timeout is 1500 s). A stop or removal takes back a start of that model still queued, and supersedes one that is loading: that start's failed exit is not reported. The engine records "Didn't start" on a model stopped while it loaded (its `systemctl start` fails), so the row can read Failed after such a Stop: an engine matter, left for the fork. |
| 2026-11-11 | Set up closes the picker and moves the cursor to the new row, which shows at once as *Waiting to download* | The download is followed on the row, not in the card; a setup that only appeared after `use` returned and the next poll would look like nothing happened. The waiting row goes when the machine lists the model, or when `use` fails. |
| 2026-11-11 | The picker lists every recipe, not only what can be set up, sorted best first | Why a recipe can't run on a machine (and what is already there) is part of choosing; the engine's own `best` mark is kept rather than a ranking of ours. |
| 2026-11-11 | Remove asks in a card that says the space freed, read with a new `delete --dry-run`; Enter confirms | Neither status nor list carries the size of a model's weights. The count follows the engine's own remove (blobs no other model links). Enter after `d` is two deliberate keys, as Remove pill after the trash is two clicks. |
| 2026-11-11 | A download in progress has Cancel the setup… (the same `delete`) | The engine's `remove` on a setup stops its unit and deletes its partial files, at the pinned tag. |
| 2026-11-11 | Remove is a muted trash on the row, Add model… a quiet outlined row | Quiet by default: removal is destructive and rare. |
| 2026-11-11 | ~~Start and stop queue per machine, one at a time~~; ~~Set up and Remove join that same queue~~ (replaced: see the two command slots, above) | A Stop then waited up to 15 minutes behind a start still loading, while its row said Stopping. |
| 2026-11-11 | Terminal launches are detached and report nothing back; their actions end in an ellipsis (Logs…, Install…, Uninstall…) | The launcher's `uwsm-app` runs the terminal as a scope in the foreground, so a Process would live as long as the terminal and kill it on a shell restart. The terminal itself shows the result. |
| 2026-11-11 | Uninstall shows the dry-run plan in a card and asks before it opens the terminal | `launch uninstall` runs the real uninstall at once; the plan is read with BatchMode ssh, which needs no terminal. |
| 2026-11-11 | Add machine and uninstall are cards over the manager that neither move nor resize | They are short questions, not settings windows; the stacking and closing rules still hold. |
| 2026-11-11 | Size and position are not remembered across restarts | There is no `startdgx window` or config file yet; drag and resize work for the session. Add both with a settings window. |
| 2026-11-11 | Host actions (Logs, Uninstall…, Forget) are text links | Quiet by default: they are rare, and Uninstall is destructive. |
