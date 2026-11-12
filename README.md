# startdgx

Control DGX Spark machines from an Omarchy desktop, over SSH: add and remove models, start and stop them.
It drives the [omarchy-local-ai](https://github.com/omacom/omarchy-local-ai) engine on the host and never
changes it. For a Spark on plain DGX OS, the host runs our fork of the engine (it emulates an Omarchy-based
DGX), so other Omarchy machines see its models through the usual tailnet sharing.

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
  still records what it changed, so an uninstall can undo it.
- [x] `startdgx uninstall [--dry-run [--json]] [--delete-models] [--remove-packages] <host>`: (`--dry-run --json` prints `{host, steps, kept, manual, models_bytes, packages}`, for the panel's card) reverses the install from its
  manifest. It stops sharing and stops the engine's units, then removes only the `/local-ai` tailscale serve routes,
  the engine's quadlets, network, secret and images (an image a container still uses stays), its state and config,
  and finally the engine. Then, in one `sudo`, it reverts only what the install changed: what it created goes, files
  it overwrote are restored from their backups, and linger and the agent link go back to how they were. Model
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
  - `startdgx launch install|uninstall|logs <host> [model] [--replace-engine] [--delete-models] [--remove-packages]` opens a
    floating Omarchy terminal running that startdgx command, so sudo can ask for a password. The verb is allow-listed,
    the host and model are checked and shell-quoted, `--replace-engine` goes only with `install`, and the other two only
    with `uninstall`.
  - Demo mode (`STARTDGX_DEMO=1`, or the file `~/.config/startdgx/demo/ENABLED`) runs no process at all: every way to
    run one raises. It serves the fixtures in `demo/` (three machines, one unreachable, plus `discover` peers) and
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
