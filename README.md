# startdgx

Control DGX Spark machines from an Omarchy desktop, over SSH: add and remove models, start and stop them.
It drives the [omarchy-local-ai](https://github.com/omacom/omarchy-local-ai) engine on the host and never
changes it. For a Spark on plain DGX OS, the host runs our fork of the engine (it emulates an Omarchy-based
DGX), so other Omarchy machines see its models through the usual tailnet sharing.

## Status

- [x] `bin/startdgx` SSH control CLI (`add`, `forget`, `hosts`, `status`, `list`, `use`, `start`, `stop`, `delete`), tests in `tests/cli.sh`
- [ ] Omarchy plugin: manager window and bar widget, reusing the model controls of the `agents` plugin
- [ ] Discovery of Sparks on the tailnet (GB10 / DGX OS signature over SSH)
- [ ] Install of the pinned fork tag with a manifest of what it changed; `uninstall` that reverses it

## Credits

Parts of the panel are adapted from Omarchy's `agents` plugin, MIT, Copyright (c) David Heinemeier Hansson.
