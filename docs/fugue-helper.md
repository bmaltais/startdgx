# Fugue helper on a host

startdgx installs and runs [Fugue](https://github.com/bmaltais/fugue)'s `fugue-helper --serve-http` on a host, so a Fugue instance of type `fugue-helper` can run stable-diffusion.cpp stages (encode, sample, decode) there. It is the CLI group `startdgx fugue-helper`; every verb takes HOST like the other groups, and `--json` where the others have it. Fugue's own description of the helper is `helper/README.md` ("Paired host") in its repo.

## What lives where on the host

| What | Path | Made by |
| --- | --- | --- |
| the binary | `~/.local/lib/fugue/fugue-helper-cuda` | `install` |
| the key | `~/.config/fugue/helper.key` (mode 600) | `install`, only when there is none |
| the unit | `~/.config/systemd/user/fugue-helper.service` | `install` |
| the record | `~/.local/share/startdgx/fugue-helper.json` | `install` |

The unit runs `fugue-helper-cuda --serve-http --listen <tailnet ip> --port 8765 --key-file ... --models ...`. The listen address is `tailscale ip -4` on the host at install time (install fails if there is none; the helper is never bound to `0.0.0.0`). The address is fixed in the unit when `install` runs: if the host's tailnet IP changes, run `install` again to rewrite it. The port defaults to Fugue's own, 8765. The default models folder is the engine fork's, `~/.local/share/omarchy/agent-local/models`: the helper finds files by name, size and sha256.

## Verbs

| Verb | What it does |
| --- | --- |
| `status` | installed, active, enabled at boot, address (`http://<tailnet ip>:<port>`), the binary's sha256, whether a key exists. Never the key. |
| `install --from FILE_OR_URL [--sha256 HEX] [--port N] [--models DIR[:DIR]] [--start]` | A file here goes to the host over the ssh session (up to 512 MiB); an https URL is downloaded on the host with curl (https only, redirects too, no user name or password in it, and `--sha256` is required: the URL goes to curl on its stdin, not in any command line). A bare binary or a `.tar.zst` / `.tar.gz` holding `fugue-helper-cuda`. `--sha256` checks the file as given before anything is installed. Needs the account to linger (it says the `sudo loginctl enable-linger` to run). Re-running updates the binary and unit that startdgx made and keeps the key; a binary or unit it didn't make (a symlink too) is refused: "exists and isn't startdgx's; move it aside". Files are written to a temporary name and renamed. Does not start it unless `--start`. There is no default download yet (`HELPER_URL` in `bin/startdgx` is empty until Fugue issue #104 publishes a build): without `--from` it says so. |
| `on`, `off` | `systemctl --user enable --now` / `disable --now` (what the panel's switch runs). |
| `provider --json` | Fugue's providers.json entry: `{"name": HOSTNAME, "type": "fugue-helper", "address": ..., "key": ...}`. |
| `remove [--keep-key]` | Stops and disables it and deletes what `install` created. |

## The key

The key never leaves the host except in `provider --json`'s answer, over the ssh session. Treat that output as a secret: anyone with the key can make the host read any file under its `--models` folders by name (a hash check tells whether a file equals a given one) and use its disk and memory. `status`, `install` and `remove` never print it, and `provider` without `--json` is refused so it is not printed by accident. `provider` and `on` refuse a key file that others can read or that is a symlink. See [ADR 0003](adr/0003-fugue-helper-key.md).

## What uninstall touches

`install` records in the record file whether startdgx made the binary, the unit and the key (and any folder it made). `remove`, and the machine `uninstall` (its plan lists "stop the Fugue helper and remove what startdgx created for it"), delete only those. A file that changed since startdgx wrote it (its sha256 is in the record) is left by `remove`, with the reason. An existing key is kept and made mode 600 (the helper refuses one others can read). The record is a file of its own like `comfyui.json`, not the install manifest ([ADR 0002](adr/0002-comfyui-records.md)); `uninstall` still needs the engine's manifest, so on a host with no engine install use `fugue-helper remove`.

## Memory

A running helper holds a loaded model for 600 s after its last job, beside the engine's servers. The status poll does not report it yet.

## In the panel

A machine's settings window (the gear) has a **Fugue helper** page, only for a machine that answers. It reads `status --json` when the window opens and after each click (not with the machine poll), and shows not installed / installed, off / running, the address, and a note when the status can't be read.

- **Not installed:** the exact command to run, as selectable text (`startdgx fugue-helper install HOST --from FILE --start`), since no build is published (Fugue issue #104). `FUGUE_HELPER_BUILD` in `DgxModel.js` is the one place to fill in (an https URL and its sha256) to turn that into an **Install…** button.
- **Installed:** the **Run the helper** switch (`on` / `off`) and **Copy Fugue provider entry**. Both wait while a command runs; a failure shows as a red note under the status.
- **The key and the clipboard:** the copy runs `provider --json` through `bin/startdgx` like every other action. The answer is read in `DgxService.qml`, checked by `DgxModel.fugueProviderEntry`, and put on the clipboard through a hidden `TextEdit` (`selectAll()` + `copy()`), which is emptied at once. The key is not in a QML property, a label, the notice or error line, a notification or a command line. It does sit in the clipboard, so Omarchy's clipboard history (if enabled) keeps it too: the page says the key is a secret.
