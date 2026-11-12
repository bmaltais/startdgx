# UI standards

How StartDGX looks and behaves. **The shared rules are in the devkit: [scripts/devkit/docs/ui-standards.md](../scripts/devkit/docs/ui-standards.md)** (principles, windows, moving and resizing, remembered state, controls, words, notifications). Read it first. This file holds only where StartDGX differs from it or adds to it, and the [decision log](#decision-log).

**Both files are the source of truth for the UI.** A change that makes a design decision neither covers, or goes against one, updates the file it concerns in the same change and adds a line to the decision log. A UI change without a matching update is not finished.

The kit's fifth principle names this app's tool: the QML never runs ssh, the engine or a terminal itself; it asks `bin/startdgx`, and only through `DgxService.qml` and `HostPoller.qml`.

## Differences from the shared rules

- **No settings window yet**, so no first run, no Window page and no *Remember size* / *Remember position* switches.
- **Size and position are not remembered** across a shell restart: the manager moves and resizes as the kit says, and opens centred at its default size after a restart (see the decision log).
- **Cards, not settings windows, float over the manager**: Add machine and a machine's uninstall card. They follow the stacking rules (the manager stays behind under a 35% veil, Esc and a click outside close only the card), but they are centred on the manager, sized to their content (560 wide), and neither move nor resize.

## The manager

```
┌──────────────────────────────────────────────────────────┐
│ ▣ StartDGX                                         [⟳] ✕ │  header
│   3 MACHINES · 1 RUNNING · 1 FAILED · 1 NOT ANSWERING     │
│ MACHINES                                                  │
│ ● spark-a  demo@spark-a · DGX Spark · 128 GB  Logs… Uninstall… Forget │  a machine
│   ┌─────────────────────────────────────────────────────┐ │
│   │ ◆ Qwen3.8 27B                              [▤] [⏸]  │ │  a model
│   │   ● Running · 128K context                          │ │
│   │   Memory  ━━━━━━━━━━──────────────     28 of 122 GiB │ │
│   └─────────────────────────────────────────────────────┘ │
│ ● spark-c  demo@spark-c didn't answer in time · last seen 3 min ago │
│ [+ Add machine…]                            Esc to close ◢│  footer
└──────────────────────────────────────────────────────────┘
```

- **Header.** The chip mark, the name, the count line in small capitals (red while a machine doesn't answer or a model failed), and look again (refresh). The words come from `DgxModel.subtitle`.
- **A machine.** A dot (accent when it answers, red when it doesn't, muted before its first answer), its name, its SSH target and what it is (`DgxModel.hostLine`). Under it: "Asking the machine…", "No models set up yet", or why it doesn't answer and when it last did (`offlineText`). On the right, quiet text links: **Logs…** (the model started last), **Uninstall…** and **Forget**. A machine that doesn't answer keeps its last known models, dimmed and without buttons.
- **A model.** Its maker's mark, its name (the endpoint on hover), a status dot and line (`DgxModel.modelState`: Running, Loading, Stopping, Removing, Downloading, Failed, Not enough memory, Stopped) with its context and the memory it took, then **Logs…** and **Start/Stop**. A model that doesn't fit has its play button greyed out with the reason as its tooltip. Under it, a meter (`DgxModel.meter`): memory while it runs; progress while it loads, stops or is removed, against how long that took last time; the download while it is set up. A failure's reason is a red link to its logs.
- **Start and stop** show at once ("pending"), and the machine's next answer after the command replaces it.
- **Footer.** **Add machine…** on the left, the latest message (six seconds, red for an error) or "Esc to close" on the right.
- **Keyboard.** The keys are `DgxModel.keyAction`, so a key and a button cannot disagree (a machine that isn't answering has no Start, Stop or Logs either way); each button's tooltip names its key.

| Key | Does |
|---|---|
| Up, Down, `k`, `j` | Move the cursor over machines and models |
| Enter, `s` | Start or stop the model under the cursor |
| `l` | Its logs… (a machine's row: the model started last) |
| `u` | Uninstall the machine… |
| `f` | Forget the machine |
| `n` | Add machine… |
| `r` | Look again |
| Esc | Close |

## Add machine

Lists `startdgx discover --json` (it installs and writes nothing): each machine of the tailnet with its target and what it can do (`DgxModel.peerOffer`). A DGX Spark with the engine has **Add**, which adds it at once and marks it Added; one without has **Install…**, which opens the install in a terminal (sudo asks there) and closes the window. A machine that isn't a Spark, or doesn't answer, says so, dimmed. **Look again** asks the tailnet again. Up/Down, Enter, `r`, Esc.

## Uninstall

`startdgx launch uninstall` runs the real uninstall at once, so the card is the confirmation: it first shows the plan (`startdgx uninstall HOST --dry-run`, which changes nothing), and its **Uninstall…** pill (danger, enabled only once a plan has been read) opens the terminal that does it. **Cancel**, Esc or a click outside close it and nothing happens. The weights are kept; `--delete-models` is left to the command line.

## Terminals

Install, uninstall and logs need a person at a terminal, so they run in Omarchy's floating terminal through `startdgx launch`, started detached, and the window closes to get out of the way. Nothing comes back to the manager: the terminal shows the result (Omarchy's Done/Failed prompt), and in demo mode, where the launch only prints what it would run, nothing is shown at all.

## Words

- A **machine** is a DGX Spark added to startdgx (its SSH target); a **model** is one of the engine's recipes set up on it.
- *Add* puts a machine that already runs the engine on the list; *Install…* sets the engine up on one; *Uninstall…* takes it off again; *Forget* only takes the machine off this list.

## The bar icon

A server glyph at the end of the right section: dim when nothing runs, accent while a model runs or moves, red when a machine doesn't answer or a model failed. Left click opens or closes the manager, right click looks again. It reads one word (`idle`, `running`, `busy`, `alert`, from `DgxModel.summarize`) from `~/.cache/startdgx/status`, which the service rewrites whenever it changes.

## Notifications

A model that fails, or a setup that does, is a critical notification, once per failure and again if it comes back with another reason (`DgxModel.alerts`); not while the manager is open.

## Shared UI code

`ScrollTrack.qml` and `SettingsPill.qml` are StartDrive's, unchanged. `Meter.qml`, `TextLink.qml`, `VendorIcon.qml` and `ModelRow.qml` are adapted from Omarchy's agents plugin (MIT, David Heinemeier Hansson; each says so in its header), with the shell's theme colours in place of the bar's and literal English in place of the agents strings.

## Decision log

Newest first. One line each: what was decided, and why.

| Date | Decision | Why |
|---|---|---|
| 2026-11-11 | Start and stop queue per machine, one at a time, while each machine polls on its own | A real `start` returns only once the model has loaded (minutes), so one queue for all would freeze every other machine's Stop. A Stop of a model on the same machine still waits for a start there to return. |
| 2026-11-11 | Terminal launches are detached and report nothing back; their actions end in an ellipsis (Logs…, Install…, Uninstall…) | The launcher's `uwsm-app` runs the terminal as a scope in the foreground, so a Process would live as long as the terminal and kill it on a shell restart. The terminal itself shows the result. |
| 2026-11-11 | Uninstall shows the dry-run plan in a card and asks before it opens the terminal | `launch uninstall` runs the real uninstall at once; the plan is read with BatchMode ssh, which needs no terminal. |
| 2026-11-11 | Add machine and uninstall are cards over the manager that neither move nor resize | They are short questions, not settings windows; the stacking and closing rules still hold. |
| 2026-11-11 | Size and position are not remembered across restarts | There is no `startdgx window` or config file yet; drag and resize work for the session. Add both with a settings window. |
| 2026-11-11 | Host actions (Logs, Uninstall…, Forget) are text links | Quiet by default: they are rare, and Uninstall is destructive. |
