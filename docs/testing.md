# Testing

The session, the checks and reload are the devkit's (`scripts/devkit`, a git submodule of `bmaltais/omarchy-plugin-devkit`, pinned at a tag; clone with `--recurse-submodules` or run `git submodule update --init`). Its guide is [scripts/devkit/docs/testing.md](../scripts/devkit/docs/testing.md); this file says only what is StartDGX's own.

## The checks

`scripts/check.sh` runs the devkit's `check` (bash -n and shellcheck on `scripts/`, `tests/`, `.githooks/` and `devkit.conf`, the kit's lint rules, qmllint against `scripts/qmllint-baseline.txt`, `omarchy plugin validate .`), then:

- `tests/cli.sh`: the CLI against a fake ssh and a fake host, and demo mode with shims that fail the run if it ever starts ssh, rsync, sudo, tailscale or a terminal.
- `node --test tests/js/`: the manager's rules in `DgxModel.js` (scoped to `tests/js/` so the devkit's own tests are not swept in). They run on the demo's fixtures and on a real DGX Spark's answers (`tests/js/fixtures/gx10-status.json` and `gx10-list.json`, `startdgx status` and `list` of gx10-f5f4 at engine v0.6.3-dgx.1; nothing secret in them), so a change in the engine's output shows up there.
- The icon check: an empty `iconText` fails (write icons as `\uXXXX` escapes).

qmllint runs with the Omarchy shell's modules on its import path (`scripts/lint/qmllint`, which `devkit.conf` and `scripts/qmllint` put first on PATH: it links `qs` to `/usr/share/omarchy/shell` in `$XDG_RUNTIME_DIR`, since a symlink can't live in the plugin folder), so `qs.Commons` and `qs.Ui` resolve and every warning about our code is a real one. The baseline (`scripts/qmllint-baseline.txt`) then holds only what is in the shell's own typing, which our code can't fix: `Style.font.*`, `Style.spacing.*` and `Color.menu.*` are declared there as plain `QtObject`s, so each member read is "not found on type QObject" (one entry per file and member, so a misspelt member is still new), the bar API's `run` likewise, and Quickshell's `PanelWindow` registered as not creatable. Anything else is fixed, not baselined.

The pre-commit hook (`.githooks/pre-commit`, enabled with `git config core.hooksPath .githooks`) runs the same check and refuses commits on `main`.

## The session

```sh
scripts/dev up              # nested Hyprland + shell, this checkout as the plugin, in demo mode
scripts/dev open            # the manager
scripts/dev add             # the manager with its Add machine card
scripts/dev uninstall demo@spark-a   # a machine's uninstall card
scripts/dev forget demo@spark-a      # a machine's forget card
scripts/dev models demo@spark-a      # a machine's model picker
scripts/dev remove demo@spark-a qwen3.8-27b-tensorfold   # a model's remove card
scripts/dev shot FILE       # look at it; click PX PY, key j, key Return ...
scripts/dev errors          # 0 = clean
scripts/dev reload          # after a QML edit
scripts/dev down
```

- **Demo mode.** The session's home has the marker `~/.config/startdgx/demo/ENABLED` (the session refuses to start without it), and `STARTDGX_DEMO=1` is set: the CLI serves the fixture machines in `demo/` (spark-a and spark-b answer, spark-c doesn't; discover adds spark-d, which can be added, spark-e, which needs installing, spark-f, which has an engine startdgx didn't install and no root setup (it can be added, and Set up there then fails as the engine's does, so the manager offers Install…), and a machine that isn't a Spark). A demo start returns once its model has loaded (6 s), as the engine's does and keeps its state in the session's `$XDG_STATE_HOME/startdgx-demo`. Starts, stops and downloads take time there as on a host, so the bars move. Launches (install, uninstall, logs) only print what they would run, and are started detached, so the session shows nothing but the window closing.
- **The second wall.** `devkit.conf` guards `ssh scp sftp rsync ssh-copy-id tailscale` in the session, so even a hole in demo mode reaches no machine. `scripts/dev status` counts the guard's refusals: Omarchy's own tailscale bar widget is refused a few times a minute (`tailscale status`, `switch --list`, `exit-node list`), which is expected; anything from `startdgx` would be a bug.
- **Never test the UI against real machines.** The real shell is not in demo mode: opening the manager there polls `status` over ssh (read-only), and a click is real.
