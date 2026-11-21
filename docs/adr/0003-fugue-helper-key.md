# The Fugue helper's key stays on the host and is shown by one command

The helper's key (`~/.config/fugue/helper.key`) is made on the host and never copied here or into any startdgx file. Only `fugue-helper provider --json` reads it, over the ssh session, and prints it as part of Fugue's providers.json entry; every other verb (status, install, remove) answers without it, and `provider` without `--json` refuses. The record that says what install created (`fugue-helper.json`) holds paths and hashes, not the key.

Why: the key is a password to a service that reads files under the host's models folders. Keeping it in one place, and printing it from one command whose name says so, leaves nothing for a log, a status poll or a panel refresh to leak. Considered: caching it in startdgx's config for the panel's copy button. Rejected: it would add a second copy of a secret on this computer; the panel can run `provider --json` when the user clicks copy.
