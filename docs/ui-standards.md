# UI standards

How StartDGX looks and behaves. **The shared rules are in the devkit: [scripts/devkit/docs/ui-standards.md](../scripts/devkit/docs/ui-standards.md)** (principles, windows, moving and resizing, remembered state, controls, words, notifications). Read it first. This file holds only where StartDGX differs from it or adds to it, and the [decision log](#decision-log).

**Both files are the source of truth for the UI.** A change that makes a design decision neither covers, or goes against one, updates the file it concerns in the same change and adds a line to the decision log. A UI change without a matching update is not finished.

The kit's fifth principle names this app's tool: the QML never runs ssh, the engine or a terminal itself; it asks `bin/startdgx`, and only through `DgxService.qml` and `HostPoller.qml`.

## Differences from the shared rules

- **No settings window yet**, so no first run, no Window page and no *Remember size* / *Remember position* switches.
- **Size and position are not remembered** across a shell restart: the manager moves and resizes as the kit says, and opens centred at its default size after a restart (see the decision log).
- **Cards, not settings windows, float over the manager**: Add machine, a machine's uninstall card and model picker, and a model's remove card. They follow the stacking rules (the manager stays behind under a 35% veil, Esc and a click outside close only the card), but they are centred on the manager, sized to their content (560 wide), and neither move nor resize.

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
- **A model.** Its maker's mark, its name (the endpoint on hover), a status dot and line (`DgxModel.modelState`: Running, Loading, Stopping, Removing, Cancelling, Waiting to download, Downloading, Failed, Not enough memory, Stopped) with its context and the memory it took, then **Logs…**, **Remove…** (a muted trash; **Cancel the setup…**, an ✕, while it downloads) and **Start/Stop**. A model that doesn't fit has its play button greyed out with the reason as its tooltip. Under it, a meter (`DgxModel.meter`): memory while it runs; progress while it loads, stops or is removed, against how long that took last time; the download while it is set up (an empty Waiting bar until it begins). A failure's reason is a red link to its logs.
- **Start and stop** show once their command runs on the machine ("pending"), and the machine's next answer after the command replaces it. So does a **removal**: the row says Removing (Cancelling, for a setup) until the model is gone. Each machine runs two commands at once: a start (which returns only once its model has loaded), and a stop, set up or removal beside it, each with its queue (`DgxModel.submit`). A command waiting its turn leaves the row as the machine says, with "· stop queued" (start, removal) after it; a start waiting its turn can be taken back with Stop.
- **A machine that needs its root setup.** When Set up fails because the engine says the machine needs Podman set up as root first (`DgxModel.setupNeeded`), the machine says so in red and gets an **Install…** link: `install --replace-engine` in a terminal, which backs up an engine startdgx didn't install and does the root setup. The footer only points at it.
- **Add model…** is the last row of a machine that answers (a cursor row like the others); it opens the machine's model picker.
- **Footer.** **Add machine…** on the left, the latest message (six seconds, red for an error) or "Esc to close" on the right. A setup's message drops the engine's pointers to the agents panel and journalctl (`DgxModel.actionNotice`): the row follows the setup.
- **Keyboard.** The keys are `DgxModel.keyAction`, so a key and a button cannot disagree (a machine that isn't answering has no Start, Stop or Logs either way, and a model that doesn't fit is never started); each button's tooltip names its key. No single key destroys anything: `d`, `u` and `f` open a card that asks. A held Enter, `s`, `d` or `f` acts once (its auto-repeat is ignored, in the cards too).

| Key | Does |
|---|---|
| Up, Down, `k`, `j` | Move the cursor over machines and models |
| Enter, `s` | Start or stop the model under the cursor (on Add model…: open the picker) |
| `a` | Add a model to the machine… |
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

A machine's model picker: every recipe of its catalog (`startdgx list HOST`), sorted by `DgxModel.recipeOffers`: the engine's recommendation first (marked *recommended*, its own `best`), then what the machine can run and doesn't have, what it has (*On this machine*) or is setting up, and what it can't run, dimmed, with the engine's reason. Each shows its maker's mark, the memory it takes, its context and speed on this machine class (`recipeFacts`) and its summary. **Set up** (Enter) runs `use --detach`, closes the card and puts the cursor on the new row, which shows at once as *Waiting to download* (`withSetups`) until the machine lists it, then follows the download through the status poll, then loads. A failure (exit code non-zero) takes the row away again and puts the CLI's last stderr line in the footer. **Look again** (`r`) reads the catalog again. Up/Down, Enter, `r`, Esc.

## Remove

`startdgx delete` stops the model if it runs and deletes its weights at once, so the card is the question: it first asks the machine what that frees (`delete HOST MODEL --dry-run --json`, read-only) and says so (`removeConfirm`: "freeing 47.5 GiB that no other model uses", or that the weights are shared and nothing is freed). For a download in progress it is *Cancel the setup…*, which deletes what was downloaded so far. The **Remove** pill (danger) and Enter wait for that answer; if the machine can't give it, the card says why in red and the removal can still go ahead. **Keep it**, Esc or a click outside close it and nothing happens. The removal runs with a 600 s timeout, since it returns only once the model is gone.

## Forget

A machine's **Forget…** (`f`) asks in a card: it takes the machine off this list, nothing on the machine changes, and Add machine can add it again. **Forget** (danger) or Enter forgets it; **Keep it**, Esc or a click outside close it.

## Uninstall

`startdgx launch uninstall` runs the real uninstall at once, so the card is the confirmation: it first shows the plan (`startdgx uninstall HOST --dry-run --json`, which changes nothing), and its **Uninstall…** pill (danger, enabled only once the plan for the chosen opt-ins has been read) opens the terminal that does it. Two opt-ins, off by default and shown only where they would do something (`DgxModel.uninstallChoices`), say what they cost: **Also delete the model weights** (`--delete-models`, with the space it frees) and **Also remove the packages the install added** (`--remove-packages`, naming them; anything else that uses them stops working, python3 always stays). Each change asks for the plan again; a removal apt would widen fails there and keeps the pill off. **Cancel**, Esc or a click outside close it and nothing happens.

## Terminals

Install, uninstall and logs need a person at a terminal, so they run in Omarchy's floating terminal through `startdgx launch`, started detached, and the window closes to get out of the way. Nothing comes back to the manager: the terminal shows the result (Omarchy's Done/Failed prompt), and in demo mode, where the launch only prints what it would run, nothing is shown at all.

## Words

- A **machine** is a DGX Spark added to startdgx (its SSH target); a **model** is one of the engine's recipes set up on it.
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
