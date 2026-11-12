# Engine releases

startdgx pins the engine (`ENGINE_REPO`, `ENGINE_TAG` in `bin/startdgx`) to a tag on the bmaltais fork of omarchy-local-ai.

## Fork branch

- Keep the DGX OS support (PR #15) and the remote-machines changes as separate commits, so each can be dropped or sent upstream on its own.
- Merge omacom `master` (remote `origin`) into the branch; don't rebase.
- After each merge, re-test the host install on a DGX Spark.

## Releasing

1. Run `scripts/release-engine vX.Y.Z-dgx.N [fork-path]`. It checks the tag format, a clean tree, that `origin/master` (fetched first) is merged, and that `tests/engine-test.sh` passes, then creates the tag locally and prints its commit. It never pushes.
2. Push the tag with the command it prints (`git push fork <tag>`).
3. Bump `ENGINE_TAG` in `bin/startdgx` and commit.
