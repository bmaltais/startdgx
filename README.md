# startdgx

Control DGX Spark machines from an Omarchy desktop, over SSH: add and remove models, start and stop them.
It drives the [omarchy-local-ai](https://github.com/omacom/omarchy-local-ai) engine on the host and never
changes it. For a Spark on plain DGX OS, the host runs our fork of the engine (it emulates an Omarchy-based
DGX), so other Omarchy machines see its models through the usual tailnet sharing.

## Status

- [x] `bin/startdgx` SSH control CLI (`add`, `forget`, `hosts`, `status`, `list`, `use`, `start`, `stop`, `delete`), tests in `tests/cli.sh`
- [ ] Omarchy plugin: manager window and bar widget, reusing the model controls of the `agents` plugin
- [ ] Discovery of Sparks on the tailnet (GB10 / DGX OS signature over SSH)
- [x] `startdgx install [--dry-run] [--engine-path DIR] <host>`: installs the pinned fork tag (`startdgx engine`) with the
  engine's own host setup (one `sudo` on the host, which asks for its password at your terminal), and records what
  was there before and what it changed in `~/.local/share/startdgx/manifest.json` on the host
- [x] `startdgx uninstall [--dry-run] [--delete-models] [--remove-packages] <host>`: reverses the install from its
  manifest. It stops sharing and stops the engine's units, then removes only the `/local-ai` tailscale serve routes,
  the engine's quadlets, network, secret and images (an image a container still uses stays), its state and config,
  and finally the engine. Then, in one `sudo`, it reverts only what the install changed: files that predate it are
  restored from their backups, and linger and the agent link go back to how they were. Model weights stay unless
  `--delete-models` is given, and the uninstall says how much they take. Packages the install added stay unless
  `--remove-packages` is given. If a step fails, the uninstall stops and keeps the manifest, so running it again
  picks up where it stopped.

## Credits

Parts of the panel are adapted from Omarchy's `agents` plugin, MIT, Copyright (c) David Heinemeier Hansson.
