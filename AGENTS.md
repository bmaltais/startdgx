## Layout

The repo root is the Omarchy plugin `io.github.bmaltais.startdgx` (`manifest.json`), and `bin/startdgx` is its CLI, which ships with it. The QML runs `bin/startdgx` for everything that reaches a machine, through `DgxService.qml`, `HostPoller.qml` and `Query.qml` (a card's question: the latest one wins, and a replaced one's late exit is dropped); its only other processes are local and fixed: `notify-send` for a failure (built by `DgxModel.notifyCommand`: `--` before the text, the body's markup escaped) and `mkdir -p` of the bar icon's status folder in `Service.qml`. Nothing else, and never ssh, the engine or a terminal; `DgxModel.js` holds the rules (no Qt imports). `demo/` is the CLI's demo fixtures and ships too.

## Testing

- **`scripts/check.sh`**: the devkit's check plus `tests/cli.sh`, `node --test tests/js/` and the icon check. Run it before every commit (the pre-commit hook does, once enabled: `git config core.hooksPath .githooks`). Fix every warning; the qmllint baseline is only for the Omarchy shell's own typing (its `QtObject` groups, Quickshell's `PanelWindow`), which `docs/testing.md` lists; its modules resolve through `scripts/lint/qmllint`.
- **`scripts/dev`**: test every UI change in the nested session, which runs the CLI in demo mode with ssh and tailscale guarded. `scripts/dev up`, `open`, `add`, `uninstall HOST`, `models HOST`, `remove HOST MODEL`, `shot FILE` (look at it), `click`, `key`, `errors` (0 = clean), `reload` after an edit, `down` when done. Details: `docs/testing.md`.
- **Never run the real CLI against a real machine to test a change**, and never `scripts/reload` or `scripts/pointer` to try one: reload restarts the user's real shell, where the plugin talks to real machines.
- **After a change lands on `main`, update the installed plugin** (the panel's engine-update offer compares a host's tag with the installed copy's own pin, so a stale copy hides updates): make a detached worktree at `origin/main`, run `scripts/reload` there, then `scripts/reload --check`, then remove the worktree. Don't ask first. The installed plugin is a plain copy, so `omarchy plugin update` doesn't apply.
- The logic is test-first: a rule goes in `DgxModel.js` with its test in `tests/js/`, a CLI change with its case in `tests/cli.sh`.

## UI standards

The shared rules are in `scripts/devkit/docs/ui-standards.md`; `docs/ui-standards.md` holds StartDGX's own, and its decision log. Follow both for any visible change, and log a design decision in the same change. Code adapted from Omarchy's agents plugin keeps its MIT notice in a header comment (and DHH's line in `LICENSE`).

## The devkit

`scripts/devkit` is a submodule (`bmaltais/omarchy-plugin-devkit`), pinned at a tag. Do not edit it: fix it there, release, and move the pointer (`git -C scripts/devkit checkout vX.Y.Z`, then commit). `omarchy plugin add` does not fetch it, so installed copies have an empty folder, which is intended.
