# Fugue helper on a host

startdgx installs and runs [Fugue](https://github.com/bmaltais/fugue)'s `fugue-helper --serve-http` on a host, so a Fugue instance of type `fugue-helper` can run stable-diffusion.cpp stages (encode, sample, decode) there. It is the CLI group `startdgx fugue-helper`; every verb takes HOST like the other groups, and `--json` where the others have it. Fugue's own description of the helper is `helper/README.md` ("Paired host") in its repo.

## What lives where on the host

| What | Path | Made by |
| --- | --- | --- |
| the binary | `~/.local/lib/fugue/fugue-helper-cuda` | `install` |
| the key | `~/.config/fugue/helper.key` (mode 600) | `install`, only when there is none |
| the unit | `~/.config/systemd/user/fugue-helper.service` | `install` |
| the record | `~/.local/share/startdgx/fugue-helper.json` | `install` |

The unit runs `fugue-helper-cuda --serve-http --listen <tailnet ip> --port 8787 --key-file ... --models ...`. The listen address is `tailscale ip -4` on the host at install time (install fails if there is none; the helper is never bound to `0.0.0.0`). The default models folder is the engine fork's, `~/.local/share/omarchy/agent-local/models`: the helper finds files by name, size and sha256.

## Verbs

| Verb | What it does |
| --- | --- |
| `status` | installed, active, enabled at boot, address (`http://<tailnet ip>:<port>`), the binary's sha256, whether a key exists. Never the key. |
| `install --from FILE_OR_URL [--sha256 HEX] [--port N] [--models DIR[:DIR]] [--start]` | A file here goes to the host over the ssh session (up to 512 MiB); an https URL is downloaded on the host with curl. A bare binary or a `.tar.zst` / `.tar.gz` holding `fugue-helper-cuda`. `--sha256` checks the file as given before anything is installed. Needs the account to linger (it says the `sudo loginctl enable-linger` to run). Re-running updates the binary and unit and keeps the key. Does not start it unless `--start`. There is no default download yet (`HELPER_URL` in `bin/startdgx` is empty until Fugue issue #104 publishes a build): without `--from` it says so. |
| `on`, `off` | `systemctl --user enable --now` / `disable --now` (what the panel's switch will map to). |
| `provider --json` | Fugue's providers.json entry: `{"name": HOSTNAME, "type": "fugue-helper", "address": ..., "key": ...}`. |
| `remove [--keep-key]` | Stops and disables it and deletes what `install` created. |

## The key

The key never leaves the host except in `provider --json`'s answer, over the ssh session. Treat that output as a secret: anyone with the key can make the host read any file under its `--models` folders by name (a hash check tells whether a file equals a given one) and use its disk and memory. `status`, `install` and `remove` never print it, and `provider` without `--json` is refused so it is not printed by accident. See [ADR 0003](adr/0003-fugue-helper-key.md).

## What uninstall touches

`install` records in the record file whether startdgx made the binary, the unit and the key (and any folder it made). `remove`, and the machine `uninstall` (its plan lists "stop the Fugue helper and remove what startdgx created for it"), delete only those. A helper somebody set up by hand is updated by `install` but not claimed: its files stay on `remove`. An existing key is kept and made mode 600 (the helper refuses one others can read). The record is a file of its own like `comfyui.json`, not the install manifest ([ADR 0002](adr/0002-comfyui-records.md)); `uninstall` still needs the engine's manifest, so on a host with no engine install use `fugue-helper remove`.

## Memory

A running helper holds a loaded model for 600 s after its last job, beside the engine's servers. The status poll does not report it yet.
