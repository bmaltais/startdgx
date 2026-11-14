# startdgx

Control DGX Spark machines from an Omarchy desktop, over SSH: add and remove models, start and stop them.
It drives the [omarchy-local-ai](https://github.com/omacom/omarchy-local-ai) engine on the host and never
changes it. For a Spark on plain DGX OS, the host runs our fork of the engine (it emulates an Omarchy-based
DGX), so other Omarchy machines see its models through the usual tailnet sharing.

## Install on a DGX Spark

You need an Omarchy desktop (the controller) and a DGX Spark on plain DGX OS (the host), both on the same Tailscale tailnet.
startdgx never touches the Spark until you run step 5, and step 5 shows its plan first.

1. **Install the plugin on the Omarchy desktop.**
   ```
   omarchy plugin add https://github.com/bmaltais/startdgx.git --enable
   ```
   Then open the panel with `omarchy-shell io.github.bmaltais.startdgx open`, or add the StartDGX widget to the bar.
   The CLI is `~/.config/omarchy/plugins/io.github.bmaltais.startdgx/bin/startdgx`; the steps below use `startdgx` for it
   (`alias startdgx=~/.config/omarchy/plugins/io.github.bmaltais.startdgx/bin/startdgx`). The panel does all of it too.
2. **Put the Spark on your tailnet.** On the Spark, install Tailscale and run `sudo tailscale up`. Note its tailnet name
   (`tailscale status`). Enable Tailscale Serve for the tailnet once at <https://login.tailscale.com/f/serve>; without it
   a model can't be shared with your other machines.
3. **Let this desktop ssh into the Spark with a key** (startdgx only uses key-based, non-interactive ssh):
   ```
   ssh-copy-id USER@SPARK
   ssh USER@SPARK true   # must succeed without a password prompt
   ```
   Use the Spark's tailnet name for `SPARK` and its login for `USER`. The first connection must also have been accepted
   once so its host key is known (the `ssh` above does that, as does `startdgx discover`).
4. **Check what startdgx sees** (read-only, installs nothing): `startdgx discover`. Your Spark should be listed as a
   Spark, not installed. In the panel: Add machine.
5. **Install the engine on the Spark.** It needs `sudo` on the Spark, which asks for its password, so run it in a real
   terminal (the panel's Install… opens one for you):
   ```
   startdgx install --dry-run USER@SPARK   # what it would change, nothing is done
   startdgx install USER@SPARK
   ```
   It installs `podman`, `rsync` and `python3` if missing, the engine's GPU and RDMA settings, sets you as the
   Tailscale operator, copies the pinned engine (`startdgx engine`) and adds the machine. A Spark that already has an
   omarchy-local-ai engine needs `--replace-engine`: it is backed up first and put back by `uninstall`.
6. **Add a model.** In the panel, Add model… on the machine, then Set up; the row follows the download. From the shell:
   `startdgx list USER@SPARK`, then `startdgx use --detach USER@SPARK MODEL` and `startdgx start USER@SPARK MODEL`.
7. **Share it with your other Omarchy machines** (optional): the Share button in the panel, or
   `startdgx share USER@SPARK MODEL`. Other Omarchy desktops on the tailnet then list and pair it as usual.

To undo it all: `startdgx uninstall --dry-run USER@SPARK`, then `startdgx uninstall USER@SPARK` (see Status for the opt-ins).
Updates: when a newer engine is pinned, the panel offers Update… on the machine (it runs `startdgx install` again).

## Status

- [x] `bin/startdgx` SSH control CLI (`add`, `forget`, `hosts`, `status`, `list`, `use`, `start`, `stop`, `share`, `delete`), tests in `tests/cli.sh`
- [x] Omarchy plugin `io.github.bmaltais.startdgx` (this folder; needs `/usr/bin/python3`, standard on Omarchy): a
  manager window listing each added machine (answering, or why not and when it last did) and its models (running,
  loading, stopped, failed, not enough memory, downloading) with context and memory, Start/Stop, Share (the Tailscale mark), Logs and Remove… per
  model, an Add model… picker per machine over its catalog (`list`; Set up runs `use --detach` and the row follows the
  download), an Add machine card over `discover` (Add, or Install… in a terminal, with `--replace-engine` where an engine startdgx didn't install is there; the ssh user can be typed in), an Install… offer on a machine whose engine says it needs its root setup, Uninstall… that shows the dry-run
  plan (with opt-ins to delete the weights and remove the packages the install added) and asks first, and Forget; plus an optional bar icon. `omarchy-shell io.github.bmaltais.startdgx open` toggles it. UI rules:
  `docs/ui-standards.md`; testing in the nested session, in demo mode: `docs/testing.md`.
- [x] Add and remove models from the manager (`use --detach`, `delete`), issue #6: the picker lists every recipe of the
  machine's catalog, best first, with why one can't run there; Remove… (Cancel the setup… on a download in progress)
  asks first and says the space it frees.
- [x] `startdgx discover [--json] [--user NAME] [--timeout SECONDS] [--limit SECONDS]`: (`--limit`, default 60, is how long the whole discover may take: a peer not heard from by then is unreachable, and one never asked says the limit ran out) lists the tailnet's online Linux peers
  (`tailscale status --json`, never a LAN scan) and probes each over `ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new`
  with the install's read-only Spark probe (GB10 in `nvidia-smi`, DGX name in `/etc/dgx-release`), 8 at a time. It
  installs nothing and changes nothing on the peers. It does take the host key of a peer ssh has never seen (`accept-new`, discover's probes only: they go to the tailnet's own machines, which you chose to list) and saves it in `~/.ssh/known_hosts`, so a never-seen Spark can be offered Install; a key that changed is still refused, and says so. A peer that wants a password says `ssh needs a key: run ssh-copy-id USER@HOST`. The UI offers Install per machine. `--user` is the ssh user (default: this
  machine's). A peer that refuses key-based ssh, or doesn't answer, is `reachable: false` with a `reason`; a tailnet
  name that isn't a valid ssh target never reaches ssh. `--json` prints a list sorted by `name`, one object per peer:
  `name` (tailnet short name), `target` (`user@name`, what `add` and `install` take), `reachable` (bool), `reason`
  (string when unreachable, else null), `spark`, `installed` (startdgx's manifest exists there), `engine` (the engine
  directory exists there), all three null when unreachable, and `added` (the target is in hosts.json).
- [x] `startdgx install [--dry-run] [--engine-path DIR] [--replace-engine] <host>`: installs the pinned fork tag
  (`startdgx engine`) with the engine's own host setup (one `sudo` on the host, which asks for its password at your
  terminal), and records what was there before and what it changed in `~/.local/share/startdgx/manifest.json` on the
  host. The root files it may overwrite are backed up first. It refuses a host that already has an engine it didn't
  install unless `--replace-engine` is given, which backs that engine up for uninstall to put back. A failed install
  still records what it changed, so an uninstall can undo it. Where the host runs tailscale, the same `sudo` makes the
  user its operator (`tailscale set --operator`), without which `tailscale serve` refuses the engine's shares; the
  manifest records who it was.
- [x] `startdgx status` adds `engine_update` (`{from, to}`) when the engine startdgx installed on the host is an older release than the pin; the panel then offers Update…, which opens `startdgx install` in a terminal.
- [x] `startdgx variants HOST MODEL [--json]` lists the context sizes a recipe has measured (read from its file on the host) with the memory each needs; `startdgx use HOST MODEL --ctx N` sets a model up (or restarts one that is set up) with one of them. The Context page of a model's settings window uses both.
- [x] `startdgx recipe validate|add HOST FILE [--json]` sends a user recipe (a `.toml` on this computer, named for its id) over ssh to the engine's `recipe validate` / `recipe add` and prints every error it finds, one per line; `recipe list HOST [--json]` and `recipe remove HOST ID` complete it (the engine refuses a removal while a model uses the recipe). The panel's Add recipe… card uses them; `variants` now also gives each context's `source` (measured, estimated, drafted). `recipe measure HOST ID --ctx N [--yes]` shows the engine's dry run (download size, load) and, with `--yes`, measures a drafted or estimated variant; `recipe confirm HOST ID` accepts estimated numbers; `use --yes` sets up a recipe of yours (the engine requires it). `uninstall` keeps your recipes unless `--delete-recipes`. Needs the engine release that has `recipe` and `measure` (startdgx#20, #21).
- [x] `startdgx hf search QUERY [--json]` lists the top 50 `mlx` repos on Hugging Face for QUERY whose `config.json` is MLX affine 4-bit of a family in `known-families.json` and that are not gated, with parameters, weights size, license and base model, and a label on an abliterated or uncensored derivative (`--json`: `[{repo, params, size_bytes, license, base_model, label}]`). It runs on this computer and reaches no host; answers are cached for an hour per query. It never says a model fits (docs/adr/0001). The panel's Find on Hugging Face card uses it.
- [x] `startdgx recipe draft REPO [--id ID] [--out DIR] [--host HOST] [--json]` writes a user recipe for a repo that passes the same checks: its pinned commit, license and one `drafted` variant whose placeholder numbers equal the weights' size. With `--host` it refuses an id the host already has and has the host's engine validate the file, removing it if it is rejected. It replaces a draft it wrote earlier that nobody edited, and refuses any other file in the way. `startdgx recipe author HOST REPO [--agent] [--here]` drafts the same way (never replacing a file), then opens a terminal with the configured agent (`agent_command` in `~/.config/startdgx/config.json`, default `claude`) and the authoring brief when the draft needs judgement (a drafter, rope scaling) or with `--agent`.
- [x] `startdgx uninstall [--dry-run [--json]] [--delete-models] [--remove-packages] <host>`: (`--dry-run --json` prints `{host, steps, kept, manual, models_bytes, packages}`, for the panel's card) reverses the install from its
  manifest. It stops sharing and stops the engine's units, then removes only the `/local-ai` tailscale serve routes,
  the engine's quadlets, network, secret and images (an image a container still uses stays), its state and config,
  and finally the engine. Then, in one `sudo`, it reverts only what the install changed: what it created goes, files
  it overwrote are restored from their backups, and linger, the agent link and the tailscale operator go back to how they were (an operator someone else set since stays). Model
  weights are kept by default (`--delete-models` deletes them), and the uninstall says how much they take. Packages
  the install added stay unless `--remove-packages` is given, which never removes `python3` and refuses if apt would
  remove anything else with them. Where the engine was there before the install, the uninstall leaves everything it
  set up under the home, puts the old engine back and only reverts the root changes. If a step fails, or a backup
  to restore is missing or changed, the uninstall stops short of deleting the manifest and backups, so running it
  again picks up where it stopped.

  Two things are left for you: run `omarchy agent local forget <host>` (the host's tailnet name) on each Omarchy
  machine paired with it, and remove the controller's key from the host's `~/.ssh/authorized_keys` if it shouldn't
  reach it any more.
- [x] For the panel:
  - `startdgx use --detach <host> <model>` sets the model up in a transient user unit on the host (the engine's
    `use --detach`) and returns at once with one line. `status` shows the setup's progress. A second `use` of a model
    already being set up starts nothing and says so (exit 0). The default `--timeout` is 120 with `--detach`, 3600
    without; `start` waits 600 by default, since it returns once the model has loaded.
  - `startdgx share <host> <model> [--off]` shares the model with the other machines on the host's tailnet (the engine's
    `share`, which publishes it with `tailscale serve`), or stops sharing it. Its failures (not set up, Serve not enabled)
    are the engine's own message.
  - `startdgx logs <host> [model]` shows a model's last error and logs.
  - `startdgx delete --dry-run [--json] <host> <model>` says what removing the model would free, and changes nothing:
    a read-only probe over BatchMode ssh counts the blobs no other model links (what the engine's remove frees), and
    for a setup in progress the half-downloaded files it lists. `--json` prints `{"recipe", "setting_up", "bytes"}`.
    `delete` of a setup in progress cancels it (the engine stops its unit and deletes what it downloaded).
  - `startdgx launch install|uninstall|logs|author <host> [model|repo] [--replace-engine] [--delete-models] [--remove-packages]` opens a
    floating Omarchy terminal running that startdgx command, so sudo can ask for a password. The verb is allow-listed,
    the host and model are checked and shell-quoted, `--replace-engine` goes only with `install`, and the other two only
    with `uninstall`. `author` takes the repo (OWNER/NAME) in the model slot and runs `recipe author --agent --here`.
  - Demo mode (`STARTDGX_DEMO=1`, or the file `~/.config/startdgx/demo/ENABLED`) runs no process at all: every way to
    run one raises. It serves the fixtures in `demo/` (four machines, one unreachable and one, gx10-demo, shaped like a real Spark's answers: long names, a recipe of yours, a model store; plus `discover` peers) and
    keeps its own state, hosts included, in `$XDG_STATE_HOME/startdgx-demo`. `start`, `stop`, `share`, `use` and `delete`
    change that state, and what they start finishes over time as on a host (a setup waits 2 s, then downloads at
    1.2 GB/s; a load takes 6 s). Delete that folder
    to start over. `STARTDGX_DEMO_NOW` (seconds since the epoch) holds the demo's clock still, for tests.

## Safety

- Everything `startdgx` passes on from a host (status, logs, an error line, uninstall's output, what the root script
  prints in its terminal) has its terminal controls taken out first: C0 but newline and tab, DEL and C1 (in the root
  script's terminal, carriage returns stay). So a host can't write to this machine's clipboard (OSC 52) or redraw its
  terminal. Bytes that aren't UTF-8 show as `�`.

- Its ssh sends keepalives (`ServerAliveInterval=15`, `ServerAliveCountMax=3`), so a host that went away is noticed
  in 45 s. SIGTERM, SIGINT or SIGHUP (a shell restart ends the panel's processes) end every ssh it runs, discover's
  probes included, and it starts no more: nothing is left behind.

## Credits

Parts of the panel are adapted from Omarchy's `agents` plugin, MIT, Copyright (c) David Heinemeier Hansson; its images in `assets/` keep their notice in `assets/NOTICE`, and the model makers' logos there are their companies' trademarks.
