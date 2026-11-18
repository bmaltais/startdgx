# ComfyUI on a DGX Spark

startdgx can find, adopt, install, start, stop and update [dgx-comfyui](https://github.com/bmaltais/dgx-comfyui) installs on a host. It is the CLI group `startdgx comfyui`; the panel reads the same commands with `--json`.

## What startdgx keeps

A host can have several installs, but **one ComfyUI runs at a time** (they share the Spark's unified memory, and dgx-comfyui's service unit serves one install). startdgx records the installs it manages in `~/.local/share/startdgx/comfyui.json` on the host: path (the real path), label, `created` or `adopted`, when, and the dgx-comfyui ref. It is a file of its own, not part of the install manifest: that manifest says startdgx installed the *engine*, and `uninstall` and `discover` read its presence that way. See [ADR 0002](adr/0002-comfyui-records.md).

startdgx **never deletes an install's folder**. `forget` drops the record (`--stop-service` also removes the install's background service). The engine `uninstall` leaves ComfyUI installs alone and says so.

## Commands

All take `HOST`; `--dir` names an install by its label or its folder (absolute, or starting with `~/`) and is optional when the host manages just one. `--json` everywhere.

| Command | What it does |
|---|---|
| `discover` | Read-only: installs from the service unit, a running ComfyUI, the records, and a bounded walk of `~` (5 deep, no dot folders, a symlinked top-level folder such as `~/usbdisk` followed). Runs no script of an install. A ComfyUI without `dgx-comfyui.sh` is listed as *found, not managed*. |
| `list` | The managed installs. |
| `adopt --dir D [--label L]` | Record an existing install. Writes only startdgx's record. |
| `forget --dir D [--stop-service]` | Drop the record. |
| `status` | The install's own `dgx-comfyui.sh status --json`, its job, whether another install runs, and an update offer when its tool tag is older than the pin. An install without `lib/jsonout.py` is **too old**: startdgx doesn't run it for `status`. |
| `start`, `stop` | `dgx-comfyui.sh service` / `stop`. `start` is refused while another install runs or a job runs; `stop` refuses a ComfyUI that was started in a terminal. |
| `autostart on\|off` | `on` is `start`. `off` removes the service (it stops, and no longer starts at boot), only if the unit is this install's. |
| `plan [--dir D]` | The host's disks with free space, and whether D can take an install (absent or empty, writable, 40 GiB free). |
| `install --dir D [--label L]` | Clones dgx-comfyui at the pinned release into D and runs its `install`, as a **detached job** (`systemd-run --user`, about 15 minutes). Refused if the account doesn't linger, and says the `sudo loginctl enable-linger` to run. A failed install is run again where it stopped. |
| `update [--dir D] [--comfyui]` | Moves the tool to the pinned release, then runs `install` (or the tool's own `update` with `--comfyui`). Only a **clean, detached** checkout moves (one `install.sh` or startdgx left on a release tag). Uncommitted or unpushed work, or any branch, is refused with the `git` commands to run yourself: a checkout on a branch may be one someone works in, and an install made by `install.sh` sits on `main`. |
| `job` | The install/update/recipe job: `running`, `succeeded` or `failed`, and the end of its log (`~/.local/state/startdgx/comfyui/`). |
| `recipe list\|show\|check\|install` | ComfyUI workflows (a recipe: nodes and models with size and sha256). `install` is a job, refused first if a source is gated, gone, or the disk is too small. |

The pins are `COMFYUI_REPO` and `COMFYUI_TAG` in `bin/startdgx` (`engine --json` reports them). `--repo` and `--ref` override them.

## Tokens

Gated downloads need `HF_TOKEN` or `CIVITAI_TOKEN`. startdgx never stores, writes or sends one. You keep them in `~/.config/startdgx/comfyui.env` on the host (`HF_TOKEN=...`, one per line, `chmod 600`: a file others can read is refused). The pre-check reads that file, and the install job gets it as the unit's `EnvironmentFile`, so a token is on no command line and in no ssh command. A user manager that lingers never sees `~/.config/environment.d` changes, which is why it isn't used. When a recipe is gated and the file has no token, the refusal names the token and the file.

## In the panel

Each machine lists its managed installs under its models (`comfyui list`, read with the storage every 30 s while the manager is open), with what the status poll saw of the running one. A row has a Start or Stop button (and Enter or `s` on it); one ComfyUI runs at a time, so a stopped install's button is greyed out, with the running one named. **Find existing ComfyUI…** ends the group: it opens a card with what `comfyui discover` found, and Adopt records a dgx-comfyui folder (nothing in it changes). A foreign ComfyUI is listed, not offered. A started or stopped install keeps its "Starting" or "Stopping" until the status poll shows it took (at most 30 s). The gear on a row (or `g`) opens the install's window: **General** (its status, **Open ComfyUI** at `http://<machine>:<port>` when it listens on the network, and the **Keep running in the background** switch: on starts it now as a service that starts at boot, off removes the service and stops it), **About** (its folder, versions, models size and free space; from `comfyui status`), and **Manage** (**Forget**, which asks first and can remove the service too; the folder is never touched). Still to come: workflows and Update (jobs that need progress), a Doctor (the CLI has no verb for it yet), and Install ComfyUI….

## The memory bar

`status` carries `comfyui: [{path, rss_mib}]` for each running managed install, read from its pid file in the same ssh call. The figure is the process's resident memory; whether it also covers the GPU's allocations on unified memory is not verified on a real host.

## Testing

`tests/cli.sh` part `comfyui` runs the host script for real against a fake home, with fake `systemd-run`, `systemctl` and `loginctl` and a fake `dgx-comfyui.sh`; one case runs the real `status --json` from a checkout of dgx-comfyui. Demo mode serves four installs and two recipes on gx10-demo.
