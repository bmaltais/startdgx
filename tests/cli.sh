#!/usr/bin/env bash
# Tests startdgx against a fake ssh that records its arguments.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME=$tmp/config PATH=$tmp/bin:$PATH
mkdir -p "$tmp/bin"
# The fake host: $FAKE_HOST/probe is what the read-only probe reports, replaced by probe.after once
# the root script has run (which then fails when FAKE_ROOT_FAIL is set); the manifest lives in
# $FAKE_HOST/manifest.json.
cat >"$tmp/bin/ssh" <<'F'
#!/usr/bin/env bash
cmd=${*: -1}
printf '%s\n' "$cmd" >>"$FAKE_LOG"
case "$cmd" in
  "bash -s") cat >/dev/null; cat "$FAKE_HOST/probe";;
  "sudo bash -c "*) printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -f "$FAKE_HOST/probe.after" ]; then cp "$FAKE_HOST/probe.after" "$FAKE_HOST/probe"; fi
    if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi;;
  *"cat > "*manifest*) cat >"$FAKE_HOST/manifest.json";;
  *"cat "*manifest.json*) cat "$FAKE_HOST/manifest.json" 2>/dev/null; true;;
  *"profile"*) echo '{"ram_class":128,"gpus":[]}';;
  *"status --json"*) echo '{"models":{}}';;
  *"fail"*) echo "Error: boom" >&2; exit 1;;
esac
F
cat >"$tmp/bin/rsync" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HOST/rsync.log"
F
chmod +x "$tmp/bin/ssh" "$tmp/bin/rsync"; export FAKE_LOG=$tmp/log FAKE_HOST=$tmp/host
# A Spark's probe, plain DGX OS with Podman 4; later key=value arguments override earlier ones.
spark() {
  printf '%s\n' user=me home=/home/me "gpu=NVIDIA GB10" "dgx_name=DGX Spark" podman=yes rsync=yes python3=yes \
    linger=no podman_major=4 var_cdi_gids=yes memlock_limits=no link_kind=none link_target= engine= "$@"
}
fresh_host() { rm -rf "$FAKE_HOST"; mkdir -p "$FAKE_HOST"; spark "$@" >"$FAKE_HOST/probe"; }
after() { spark "$@" >"$FAKE_HOST/probe.after"; }
engine=$tmp/engine; mkdir -p "$engine"
cat >"$engine/agent_local.py" <<'F'
HOST_SETUP = r'''
echo engine-host-setup "$1" @CDI_COMPAT@
'''
CDI_COMPAT = 'engine-cdi-compat'
MACHINE_SETUP_TAIL = 'ln -sf "$2" /usr/local/bin/omarchy-agent-local\n'
F
n=0; bad=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok - $2"; else bad=$((bad+1)); echo "not ok - $2"; fi; }
s() { "$here/bin/startdgx" "$@"; }
none_of() { local f; for f; do [ ! -e "$f" ] || return 1; done; }
same() { [ "$1" = "$2" ]; }

s status me@dgx >/dev/null 2>&1; ok $((!$?)) "an unknown host is refused"
s add me@dgx >/dev/null; ok $? "add records the host"
grep -q '"ram_class": 128' "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "add keeps the host's profile"
s hosts --json | grep -q me@dgx; ok $? "hosts lists it"
s status me@dgx | grep -q models; ok $? "status passes the engine's JSON through"
s start me@dgx qwen3.8-27b-tensorfold >/dev/null; ok $? "start runs on the host"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai start qwen3.8-27b-tensorfold'; ok $? "start sends the recipe to the engine"
s stop me@dgx >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai stop$'; ok $? "stop without a model stops every one"
s delete me@dgx qwen3.8-27b-tensorfold >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'remove qwen3.8-27b-tensorfold'; ok $? "delete maps to the engine's remove"
s start me@dgx 'x; rm -rf ~' >/dev/null 2>&1; ok $((!$?)) "a recipe id with shell characters is refused"
s add -oProxyCommand=x >/dev/null 2>&1; ok $((!$?)) "a host that looks like an ssh option is refused"
s forget me@dgx >/dev/null; s hosts --json | grep -q me@dgx; ok $((!$?)) "forget drops the host"
s engine | grep -Eq '^https://github.com/bmaltais/omarchy-local-ai v[0-9]+\.[0-9]+\.[0-9]+-dgx\.[0-9]+$'; ok $? "engine prints the pinned repo and tag"
s engine --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["repo"].startswith("https://") and "-dgx." in d["tag"]))'; ok $? "engine --json gives repo and tag"

# install, against the fake host
fresh_host "gpu=AMD Radeon" dgx_name=
out=$(s install me@pc --engine-path "$engine" 2>&1); ok $((!$?)) "install refuses a host that isn't a DGX Spark"
echo "$out" | grep -q "isn't a DGX Spark"; ok $? "install says why it refused"
none_of "$FAKE_HOST/root-call" "$FAKE_HOST/rsync.log"; ok $? "a refused install changes nothing"

fresh_host podman=no; : >"$FAKE_LOG"
out=$(s install --dry-run me@spark --engine-path "$engine"); ok $? "install --dry-run succeeds"
none_of "$FAKE_HOST/root-call" "$FAKE_HOST/rsync.log" "$FAKE_HOST/manifest.json" \
  && ! grep -q me@spark "$XDG_CONFIG_HOME/startdgx/hosts.json" && ! grep -q 'mkdir' "$FAKE_LOG"; ok $? "install --dry-run writes nothing"
echo "$out" | grep -q 'install podman' && echo "$out" | grep -q 'enable linger for me' \
  && echo "$out" | grep -q '/etc/security/limits.d/99-rdma-memlock.conf' \
  && echo "$out" | grep -q 'link /usr/local/bin/omarchy-agent-local -> /home/me/.local/share/omarchy-local-ai/omarchy-local-ai' && ! echo "$out" | grep -q 'install rsync'; ok $? "install --dry-run lists what it would change"

# m 'python condition': checks the fake host's manifest; item(kind, path or name) is one of its items.
m() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); its={(i['kind'], i.get('path') or i.get('name')): i for i in d['items']}
item=lambda k, n: its[(k, n)]
sys.exit(not ($1))" "$FAKE_HOST/manifest.json"
}
limits=/etc/security/limits.d/99-rdma-memlock.conf entry=/home/me/.local/share/omarchy-local-ai/omarchy-local-ai
fresh_host linger=yes podman=no podman_major= link_kind=symlink link_target=/opt/old/agent
after linger=yes podman_major=4 "file:$limits=abc123 engine" link_kind=symlink "link_target=$entry" engine=e1
s install me@spark --engine-path "$engine" >/dev/null; ok $? "install succeeds on a Spark"
grep -qx -- -t "$FAKE_HOST/root-call"; ok $? "the root script runs with a terminal, for sudo's password prompt"
grep -q engine-host-setup "$FAKE_HOST/root-call" && grep -q engine-cdi-compat "$FAKE_HOST/root-call" \
  && grep -q "ln -sf \"\$2\" /usr/local/bin/omarchy-agent-local" "$FAKE_HOST/root-call"; ok $? "the root script is the engine's own HOST_SETUP and MACHINE_SETUP_TAIL"
tail -1 "$FAKE_HOST/root-call" | grep -q "startdgx-install me $entry\$"; ok $? "the root script gets the user and the engine path"
grep -q -- "-a --delete .*$engine/ me@spark:.local/share/omarchy-local-ai/" "$FAKE_HOST/rsync.log"; ok $? "install copies the engine with rsync"
m 'd["schema_version"] == 1 and d["installed_at"]'; ok $? "the manifest has a schema version and install time"
m 'not item("linger", "me")["created_by_us"] and item("linger", "me")["previous"] == {"linger": "yes"}'; ok $? "linger that was already on isn't marked ours"
m 'item("package", "podman")["created_by_us"] and not item("package", "rsync")["created_by_us"]'; ok $? "only the packages that were missing are marked ours"
m 'item("file", "'$limits'")["created_by_us"] and item("file", "'$limits'")["previous"]["exists"] is False'; ok $? "a root file the install created is marked ours"
m 'not item("file", "/etc/cdi/nvidia.yaml")["created_by_us"]'; ok $? "an unchanged root file isn't marked ours"
m 'item("symlink", "/usr/local/bin/omarchy-agent-local")["previous"]["target"] == "/opt/old/agent" and item("symlink", "/usr/local/bin/omarchy-agent-local")["created_by_us"]'; ok $? "the agent link's previous target is kept"
m 'item("engine", "/home/me/.local/share/omarchy-local-ai")["created_by_us"]'; ok $? "the engine copy is marked ours"
grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "install adds the host"

items() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([d["installed_at"], d["pre_state"], d["items"]], sort_keys=True))' "$FAKE_HOST/manifest.json"; }
first=$(items)
s install me@spark --engine-path "$engine" >/dev/null; ok $? "a second install succeeds"
same "$(items)" "$first"; ok $? "a second install keeps the manifest's items, pre-state and install time"

fresh_host
after linger=yes "file:$limits=abc123 engine"
FAKE_ROOT_FAIL=1 s install me@spark --engine-path "$engine" >/dev/null 2>&1; ok $((!$?)) "install fails when the root script fails"
m 'item("linger", "me")["previous"] == {"linger": "no"}'; ok $? "a failed install still records what was there before"
s install me@spark --engine-path "$engine" >/dev/null; m 'item("linger", "me")["created_by_us"]'; ok $? "a rerun after a failure marks what the failed run changed as ours"

# Without --engine-path, the pinned tag is cloned here (a fake git, on this test's PATH only, copies $engine).
mkdir -p "$tmp/fakegit"
cat >"$tmp/fakegit/git" <<F
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$FAKE_HOST/git.log"; cp -r "$engine" "\${*: -1}"
F
chmod +x "$tmp/fakegit/git"; fresh_host
tag=$(s engine --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
PATH=$tmp/fakegit:$PATH s install me@spark >/dev/null; ok $? "install clones the pinned engine by default"
grep -q -- "clone -q --depth 1 --branch $tag -- https://github.com/bmaltais/omarchy-local-ai " "$FAKE_HOST/git.log"; ok $? "the clone is shallow, of the pinned tag"
m 'd["engine"]["tag"] == "'"$tag"'" and d["engine"]["repo"] == "https://github.com/bmaltais/omarchy-local-ai"'; ok $? "the manifest records the engine's repo and tag"
grep -q engine-host-setup "$FAKE_HOST/root-call"; ok $? "the root script comes from the cloned engine"

# release-engine, against a throwaway fork checkout with a bare origin
rel=$here/scripts/release-engine
fork=$tmp/fork
g() { git -C "$fork" -c user.name=t -c user.email=t@t "$@"; }
git init -q --bare -b master "$tmp/origin.git"; git init -q --bare "$tmp/fork-remote.git"
git clone -q "$tmp/origin.git" "$fork" 2>/dev/null
mkdir "$fork/tests"; printf '#!/usr/bin/env bash\nexit 0\n' >"$fork/tests/engine-test.sh"; chmod +x "$fork/tests/engine-test.sh"
g add -A; g commit -qm base; g push -q origin HEAD:master; g fetch -q origin
g remote add fork "$tmp/fork-remote.git"
"$rel" v1.0 "$fork" >/dev/null 2>&1; ok $((!$?)) "release-engine refuses a malformed tag"
echo x >"$fork/dirty"; "$rel" v0.6.3-dgx.2 "$fork" >/dev/null 2>&1; ok $((!$?)) "release-engine refuses a dirty checkout"
rm "$fork/dirty"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fork/tests/engine-test.sh"; g commit -qam failing
"$rel" v0.6.3-dgx.2 "$fork" >/dev/null 2>&1; ok $((!$?)) "release-engine refuses when the engine tests fail"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fork/tests/engine-test.sh"; g commit -qam passing
other=$tmp/other; git clone -q "$tmp/origin.git" "$other" 2>/dev/null
git -C "$other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m upstream; git -C "$other" push -q origin HEAD:master; g fetch -q origin
"$rel" v0.6.3-dgx.2 "$fork" >/dev/null 2>&1; ok $((!$?)) "release-engine refuses when origin/master is not merged"
g merge -q origin/master -m merge
out=$("$rel" v0.6.3-dgx.2 "$fork" 2>&1); ok $? "release-engine accepts a merged, clean, passing fork"
g rev-parse -q --verify refs/tags/v0.6.3-dgx.2 >/dev/null; ok $? "release-engine creates the tag"
echo "$out" | grep -q 'git push fork v0.6.3-dgx.2'; ok $? "release-engine prints the push command"
git -C "$tmp/fork-remote.git" tag | grep -q .; ok $((!$?)) "release-engine never pushes to fork"
git -C "$tmp/origin.git" tag | grep -q .; ok $((!$?)) "release-engine never pushes to origin"
echo "1..$n"; exit $bad
