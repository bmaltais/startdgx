# ComfyUI installs are recorded in a file of their own, not in the install manifest

startdgx keeps which ComfyUI installs it manages in `~/.local/share/startdgx/comfyui.json`, beside `store.json`, and not in `manifest.json`.

The manifest means "startdgx installed the engine here": `uninstall` refuses without it, `discover` reports `startdgx=yes` from its presence, and `build_manifest` rebuilds it whole on every install, which would drop anything added to it. A host that only adopted a ComfyUI would also look like one startdgx had installed the engine on. The records file has none of those meanings, is written under a lock on the host, and is left alone by the engine `uninstall`.

Considered: a `comfyui` list inside the manifest (the first design). Rejected for the three reasons above.
