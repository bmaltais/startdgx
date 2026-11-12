#!/usr/bin/env bash
# Tests startdgx against a fake ssh that records its arguments.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME=$tmp/config PATH=$tmp/bin:$PATH
mkdir -p "$tmp/bin"
# The fake host. The host user's home is $FAKE_HOST/home, which holds the manifest, and $FAKE_HOST/root stands
# in for / under /etc and /usr/local. startdgx's own scripts (the backup, uninstall's phases and its root part) run
# for real against those two, with stubs that only log for the host's tools. The read-only probe reports
# $FAKE_HOST/probe, with the root files and agent link it really finds in the fake root on top; probe.after replaces
# that file once the install's root script has run. That script, the engine's, is only recorded: in its place
# $FAKE_HOST/engine-root, if there, writes to the fake root (as $root), then it fails when FAKE_ROOT_FAIL is set.
cat >"$tmp/bin/ssh" <<'F'
#!/usr/bin/env bash
cmd=${*: -1}
printf '%s\n' "$cmd" >>"$FAKE_LOG"
root=$FAKE_HOST/root; [ "$root" != /root ] || exit 99
rooted() { sed "s#/etc/#$root/etc/#g; s#/usr/local/#$root/usr/local/#g"; }
host() { HOME=$FAKE_HOST/home PATH=$FAKE_HOSTBIN:$PATH "$@"; }
case "$cmd" in
  "bash -s") found=$(rooted | host bash -s 2>/dev/null | sed "s#$root##g"); cat "$FAKE_HOST/probe"
    printf '%s\n' "$found" | grep -E '^file:.*=.'; printf '%s\n' "$found" | grep -qx link_kind=none || printf '%s\n' "$found" | grep '^link_';;
  "bash -s -- startdgx-"*) rooted | host bash -s;;
  "sudo bash -c "*" startdgx-uninstall") printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi
    script=$(printf '%s' "${cmd#sudo }" | rooted); host eval "$script";;
  "sudo bash -c "*) printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -f "$FAKE_HOST/engine-root" ]; then root=$root bash "$FAKE_HOST/engine-root"; fi
    if [ -f "$FAKE_HOST/probe.after" ]; then cp "$FAKE_HOST/probe.after" "$FAKE_HOST/probe"; fi
    if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi;;
  *"cat > "*manifest*) mkdir -p "${FAKE_MANIFEST%/*}"; cat >"$FAKE_MANIFEST";;
  *"cat "*manifest.json*) cat "$FAKE_MANIFEST" 2>/dev/null; true;;
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
export FAKE_MANIFEST=$FAKE_HOST/home/.local/share/startdgx/manifest.json FAKE_HOSTBIN=$tmp/hostbin
# The host's tools, as uninstall's scripts see them: each logs its arguments to $FAKE_HOST/calls; podman's
# networks, secrets, images and containers are files in $FAKE_HOST/podman (where busy makes network rm fail),
# tailscale's serve config is
# $FAKE_HOST/serve.json.
mkdir -p "$FAKE_HOSTBIN"
cat >"$tmp/stub" <<'F'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >>"$FAKE_HOST/calls"
F
for tool in systemctl loginctl sudo; do cp "$tmp/stub" "$FAKE_HOSTBIN/$tool"; done
printf '#!/usr/bin/env bash\necho me\n' >"$FAKE_HOSTBIN/id"
# The user's systemd manager is running.
{ cat "$tmp/stub"; echo 'echo 4242'; } >"$FAKE_HOSTBIN/pgrep"
# apt-get -s prints what apt would remove: the named packages, and those in $FAKE_HOST/apt-also.
cat >"$FAKE_HOSTBIN/apt-get" <<'F'
#!/usr/bin/env bash
printf '%s\n' "apt-get $*" >>"$FAKE_HOST/calls"
if [ "$1" = -s ]; then
  echo "NOTE: This is only a simulation!"
  for pkg in "${@:3}" $(cat "$FAKE_HOST/apt-also" 2>/dev/null); do [ "$pkg" = -- ] || echo "Remv $pkg [1.0-1]"; done
fi
F
cat >"$FAKE_HOSTBIN/podman" <<'F'
#!/usr/bin/env bash
printf '%s\n' "podman $*" >>"$FAKE_HOST/calls"
p=$FAKE_HOST/podman; key() { printf '%s' "${1//[\/:@]/_}"; }
case "$1 $2" in
  "network exists") [ -e "$p/network" ];;
  "network rm") if [ -e "$p/busy" ]; then echo "Error: network is in use" >&2; exit 2; fi; rm "$p/network";;
  "secret inspect") [ -e "$p/secret" ];;
  "secret rm") rm "$p/secret";;
  "image exists") [ -e "$p/image-$(key "$3")" ];;
  "image rm") rm "$p/image-$(key "$3")";;
  "ps -a") if [ -e "$p/used-$(key "${5#ancestor=}")" ]; then echo c0ffee; fi;;
esac
F
cat >"$FAKE_HOSTBIN/tailscale" <<'F'
#!/usr/bin/env bash
printf '%s\n' "tailscale $*" >>"$FAKE_HOST/calls"
case "$*" in
  "serve status --json") cat "$FAKE_HOST/serve.json" 2>/dev/null || echo '{}';;
  "serve --yes --set-path "*" off") python3 -c '
import json, sys
path, file = sys.argv[1:]
config = json.load(open(file))
handlers = [web["Handlers"] for web in config.get("Web", {}).values() if path in web.get("Handlers", {})]
if not handlers:
  sys.exit(print("Error: handler Not Found", file=sys.stderr) or 1)
for found in handlers:
  del found[path]
json.dump(config, open(file, "w"))' "$4" "$FAKE_HOST/serve.json";;
esac
F
# The engine, whose share --off drops its route, and the listing with the last one, as publish_shares does.
cat >"$tmp/engine-stub" <<'F'
#!/usr/bin/env bash
printf '%s\n' "engine $*" >>"$FAKE_HOST/calls"
if [ "$1 $3" = "share --off" ]; then python3 -c '
import json, sys
rid, file = sys.argv[1:]
config = json.load(open(file))
for web in config.get("Web", {}).values():
  web["Handlers"].pop("/local-ai/" + rid, None)
  if not [path for path in web["Handlers"] if path.startswith("/local-ai/") and path != "/local-ai/models.json"]:
    web["Handlers"].pop("/local-ai/models.json", None)
json.dump(config, open(file, "w"))' "$2" "$FAKE_HOST/serve.json"; fi
F
chmod +x "$FAKE_HOSTBIN"/*
# A Spark's probe, plain DGX OS with Podman 4; later key=value arguments override earlier ones.
spark() {
  printf '%s\n' user=me home=/home/me "gpu=NVIDIA GB10" "dgx_name=DGX Spark" podman=yes rsync=yes python3=yes \
    linger=no podman_major=4 var_cdi_gids=yes memlock_limits=no link_kind=none link_target= engine= "$@"
}
fresh_host() { rm -rf "$FAKE_HOST"; mkdir -p "$FAKE_HOST/home" "$FAKE_HOST/root"; spark "$@" >"$FAKE_HOST/probe"; }
# put PATH CONTENT: writes a file in the fake root.
put() { mkdir -p "$FAKE_HOST/root${1%/*}"; printf '%s\n' "$2" >"$FAKE_HOST/root$1"; }
sha() { sha256sum <"$FAKE_HOST/root$1" | cut -c1-64; }
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
present() { local f; for f; do [ -e "$f" ] || return 1; done; }
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
none_of "$FAKE_HOST/root-call" "$FAKE_HOST/rsync.log" "$FAKE_MANIFEST" \
  && ! grep -q me@spark "$XDG_CONFIG_HOME/startdgx/hosts.json" && ! grep -q 'mkdir' "$FAKE_LOG"; ok $? "install --dry-run writes nothing"
echo "$out" | grep -q 'install podman' && echo "$out" | grep -q 'enable linger for me' \
  && echo "$out" | grep -q '/etc/security/limits.d/99-rdma-memlock.conf' \
  && echo "$out" | grep -q 'link /usr/local/bin/omarchy-agent-local -> /home/me/.local/share/omarchy-local-ai/omarchy-local-ai' && ! echo "$out" | grep -q 'install rsync'; ok $? "install --dry-run lists what it would change"

# m 'python condition': checks the fake host's manifest; item(kind, path or name) is one of its items.
m() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); its={(i['kind'], i.get('path') or i.get('name')): i for i in d['items']}
item=lambda k, n: its[(k, n)]
sys.exit(not ($1))" "$FAKE_MANIFEST"
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
link=/usr/local/bin/omarchy-agent-local
m 'item("symlink", "'$link'")["previous"]["target"] == "/opt/old/agent" and item("symlink", "'$link'")["changed_by_us"] and not item("symlink", "'$link'")["created_by_us"]'
ok $? "a re-pointed agent link keeps its previous target, and is marked changed, not created"
m 'item("engine", "/home/me/.local/share/omarchy-local-ai")["created_by_us"]'; ok $? "the engine copy is marked ours"
grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "install adds the host"

items() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([d["installed_at"], d["pre_state"], d["items"]], sort_keys=True))' "$FAKE_MANIFEST"; }
first=$(items)
s install me@spark --engine-path "$engine" >/dev/null; ok $? "a second install succeeds"
same "$(items)" "$first"; ok $? "a second install keeps the manifest's items, pre-state and install time"

fresh_host
after linger=yes "file:$limits=abc123 engine"
FAKE_ROOT_FAIL=1 s install me@spark --engine-path "$engine" >/dev/null 2>&1; ok $((!$?)) "install fails when the root script fails"
m 'item("linger", "me")["previous"] == {"linger": "no"}'; ok $? "a failed install still records what was there before"
s install me@spark --engine-path "$engine" >/dev/null; m 'item("linger", "me")["created_by_us"]'; ok $? "a rerun after a failure marks what the failed run changed as ours"

cdi=/etc/cdi/nvidia.yaml compat=/usr/local/sbin/nvidia-cdi-podman-compat bk=$FAKE_HOST/home/.local/share/startdgx/backup
fresh_host; put $cdi 'cdiVersion: 0.6.0'; put $compat '#!/bin/sh'; put /etc/other 'not ours'
spark "file:$cdi=$(sha $cdi) other" "file:$compat=$(sha $compat) other" >"$FAKE_HOST/probe"; : >"$FAKE_LOG"
s install me@spark --engine-path "$engine" >/dev/null
cmp -s "$FAKE_HOST/root$cdi" "$bk/etc_cdi_nvidia.yaml" && cmp -s "$FAKE_HOST/root$compat" "$bk/usr_local_sbin_nvidia-cdi-podman-compat" \
  && same "$(ls "$bk")" "$(printf '%s\n' etc_cdi_nvidia.yaml usr_local_sbin_nvidia-cdi-podman-compat)"; ok $? "install backs up the root files that were there before, and only those"
m 'item("file", "'$cdi'")["previous"]["backup"] == "/home/me/.local/share/startdgx/backup/etc_cdi_nvidia.yaml" and not item("file", "'$cdi'")["created_by_us"]'
ok $? "a root file that was there before is recorded with its backup, and isn't marked ours"
fresh_host "file:$cdi=$(printf '%064d' 1) other" "file:$limits=$(printf '%064d' 2) engine"
after "file:$cdi=$(printf '%064d' 3) engine" "file:$limits=$(printf '%064d' 2) engine"
s install me@spark --engine-path "$engine" >/dev/null
m 'not item("file", "'$cdi'")["created_by_us"] and item("file", "'$cdi'")["changed_by_us"] and not item("file", "'$limits'")["changed_by_us"]'
ok $? "a root file that was there before and that the install changed is marked changed, not created"
fresh_host; put $cdi 'cdiVersion: 0.6.0'; spark "file:$cdi=$(sha $cdi) other" >"$FAKE_HOST/probe"; s install me@spark --engine-path "$engine" >/dev/null
put $cdi 'changed since'; s install me@spark --engine-path "$engine" >/dev/null
same "$(cat "$bk/etc_cdi_nvidia.yaml")" 'cdiVersion: 0.6.0'; ok $? "a second install keeps the first backup"
first_line() { grep -n -m1 -e "$1" "$FAKE_LOG" | cut -d: -f1; }
earlier() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
earlier "$(first_line startdgx-backup)" "$(first_line '^sudo bash -c')"; ok $? "the backup is taken before the root script runs"

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

# uninstall, against the fake host
fresh_host; : >"$FAKE_LOG"
out=$(s uninstall me@spark 2>&1); ok $((!$?)) "uninstall refuses a host without an install manifest"
echo "$out" | grep -q 'No install manifest' && echo "$out" | grep -q 'startdgx install'; ok $? "uninstall says the manifest is missing"
same "$(wc -l <"$FAKE_LOG")" 1 && none_of "$FAKE_HOST/root-call" "$FAKE_HOST/calls"; ok $? "uninstall without a manifest only reads it"

# installed [probe overrides]: a host startdgx installed, with $before_root in the fake root before it, where the
# engine's root script enabled linger, wrote the limits file and the agent link, and ran $engine_root (with
# ${changed[@]} on top of the probe after it), and where the engine then set up two models on one image, shared
# one, and left 1 MiB of weights.
h=$FAKE_HOST/home q=$FAKE_HOST/home/.config/containers/systemd
fentry=$h/.local/share/omarchy-local-ai/omarchy-local-ai
img=ghcr.io/omacom/tensorfold@sha256:$(printf '%064d' 7)
rdma='# RDMA between paired DGX Sparks registers large buffers as locked memory.'
before_root='' engine_root='' changed=()
installed() {
  fresh_host "home=$h" "$@"; eval "$before_root"
  after "home=$h" "$@" linger=yes engine=e1 "${changed[@]}"
  cat >"$FAKE_HOST/engine-root" <<E
mkdir -p "\$root/etc/security/limits.d" "\$root/usr/local/bin"
printf '%s\\n' '$rdma' >"\$root$limits"
ln -sfn '$fentry' "\$root/usr/local/bin/omarchy-agent-local"
$engine_root
E
  s install me@spark --engine-path "$engine" >/dev/null || echo "installed: install failed" >&2
  mkdir -p "$q" "$h/.config/omarchy/agent-local" "$h/.config/omarchy/other" "$h/.local/state/omarchy/agent-local" \
    "$h/.local/share/omarchy/agent-local/models/q1" "$h/.config/systemd/user" "$FAKE_HOST/podman" "${fentry%/*}"
  cp "$tmp/engine-stub" "$fentry"; chmod +x "$fentry"
  for rid in q1 q2; do
    printf '# Generated by omarchy-agent-local use; changes are overwritten.\n[Container]\nImage=%s\n' "$img" >"$q/omarchy-agent-local-model-$rid.container"
  done
  printf '[Quadlet]\nDefaultDependencies=false\n\n[Network]\nNetworkName=omarchy-agent-local\nInternal=true\n' >"$q/omarchy-agent-local.network"
  printf '[Container]\nImage=docker.io/library/mine\n' >"$q/mine.container"
  echo '{"recipes": ["q1"]}' >"$h/.config/omarchy/agent-local/shares.json"; echo k >"$h/.config/omarchy/agent-local/key"
  echo '{}' >"$h/.local/state/omarchy/agent-local/status.json"; : >"$h/.config/systemd/user/omarchy-agent-local-share.service"
  head -c 1048576 /dev/zero >"$h/.local/share/omarchy/agent-local/models/q1/blob"
  : >"$FAKE_HOST/podman/network"; : >"$FAKE_HOST/podman/secret"; : >"$FAKE_HOST/podman/image-${img//[\/:@]/_}"
  printf '{"Web": {"spark.ts.net:443": {"Handlers": {"/local-ai/q1": {"Proxy": "http://127.0.0.1:11430/q1"}, "/local-ai/models.json": {"Text": "{}"}, "/mine": {"Proxy": "http://127.0.0.1:8080"}}}}}' >"$FAKE_HOST/serve.json"
  : >"$FAKE_LOG"; rm -f "$FAKE_HOST/calls" "$FAKE_HOST/root-call"
}
tree() { (cd "$FAKE_HOST" && find . -path ./calls -prune -o -print | sort && find . -type f ! -name calls -exec md5sum {} + | sort); }
installed; before=$(tree)
out=$(s uninstall --dry-run me@spark); ok $? "uninstall --dry-run succeeds"
same "$(tree)" "$before" && none_of "$FAKE_HOST/root-call" && ! grep -qv -e 'status --json$' -e ' exists ' -e ' inspect ' "$FAKE_HOST/calls" \
  && grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "uninstall --dry-run writes nothing"
echo "$out" | grep -q 'share q1 --off' && echo "$out" | grep -q '/local-ai/models.json' && ! echo "$out" | grep -q '/mine' \
  && echo "$out" | grep -q 'omarchy-agent-local-model-q2.container' && ! echo "$out" | grep -q 'mine.container' \
  && [ "$(echo "$out" | grep -c "$img")" = 1 ] && echo "$out" | grep -q 'disable linger for me' \
  && echo "$out" | grep -q "keep .*1.0 MiB"; ok $? "uninstall --dry-run lists what it would change and keep"

call() { grep -n -m1 -F -e "$1" "$FAKE_HOST/calls" | cut -d: -f1; }
out=$(s uninstall me@spark 2>&1); ok $? "uninstall succeeds"
earlier "$(call 'engine share q1 --off')" "$(call 'systemctl --user stop')" && earlier "$(call 'systemctl --user stop')" "$(call 'tailscale serve --yes')" \
  && earlier "$(call 'tailscale serve --yes')" "$(call 'podman network rm')" && earlier "$(call 'podman network rm')" "$(call 'podman image rm')"
ok $? "uninstall unshares, then stops the units, then removes routes, network and image"
python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["Web"]["spark.ts.net:443"]["Handlers"]; sys.exit(list(h) != ["/mine"])' "$FAKE_HOST/serve.json"
ok $? "uninstall removes only the /local-ai serve routes"
grep -q 'serve reset' "$FAKE_HOST/calls" "$FAKE_HOST/root-call" || grep -q 'prune' "$FAKE_HOST/calls" "$FAKE_HOST/root-call"; ok $((!$?)) "uninstall never resets serve or prunes images"
none_of "$q"/omarchy-agent-local* "$h/.config/omarchy/agent-local" "$h/.local/state/omarchy" "$h/.config/systemd/user/omarchy-agent-local-share.service" \
  "$h/.local/share/omarchy-local-ai" "$FAKE_HOST/podman/network" "$FAKE_HOST/podman/secret" "$FAKE_HOST/podman/image-${img//[\/:@]/_}"
ok $? "uninstall removes the engine, its quadlets, state, config, network, secret and image"
present "$q/mine.container" "$h/.config/omarchy/other"; ok $? "uninstall keeps what isn't the engine's"
[ -f "$h/.local/share/omarchy/agent-local/models/q1/blob" ] && echo "$out" | grep -q 'keep .*1.0 MiB'; ok $? "uninstall keeps the model weights by default and says how much"
r=$FAKE_HOST/root
grep -q 'loginctl disable-linger me' "$FAKE_HOST/calls" && none_of "$r$limits" "$r$link"; ok $? "uninstall undoes as root what the install created"
grep -qx -- -t "$FAKE_HOST/root-call" && tail -1 "$FAKE_HOST/root-call" | grep -q " startdgx-uninstall$"; ok $? "the root part is one sudo script run with a terminal"
none_of "$h/.local/share/startdgx" && ! grep -q me@spark "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "uninstall deletes the manifest and forgets the host"

before_root="put $cdi 'cdiVersion: 0.6.0'; put /etc/systemd/user.conf.d/99-rdma-memlock.conf '$rdma'"; installed; before_root=''
s uninstall me@spark >/dev/null 2>&1
same "$(cat "$r$cdi")" 'cdiVersion: 0.6.0' && present "$r/etc/systemd/user.conf.d/99-rdma-memlock.conf" && ! grep -q apt-get "$FAKE_HOST/calls"
ok $? "uninstall leaves the root files and packages the install didn't change, even with the engine's header"

before_root="put $cdi 'cdiVersion: 0.6.0'; mkdir -p $r/usr/local/bin; ln -s /opt/old/agent $r$link"
engine_root="printf 'cdiVersion: 0.7.0\\n' >\"\$root$cdi\""; changed=(podman=yes)
installed linger=yes podman=no; before_root='' engine_root='' changed=()
out=$(s uninstall me@spark 2>&1); ok $? "uninstall succeeds where the install changed what was there"
! grep -q disable-linger "$FAKE_HOST/calls"; ok $? "linger that was already on stays on"
same "$(cat "$r$cdi")" 'cdiVersion: 0.6.0'; ok $? "a CDI spec the install overwrote is restored from its backup"
same "$(readlink "$r$link")" /opt/old/agent; ok $? "the agent link goes back to its previous target"
! grep -q apt-get "$FAKE_HOST/calls" && echo "$out" | grep -q 'keep the packages podman'; ok $? "packages the install added are kept by default"

before_root="put $cdi 'cdiVersion: 0.6.0'"; engine_root="printf 'cdiVersion: 0.7.0\\n' >\"\$root$cdi\""
installed; before_root='' engine_root=''
echo tampered >"$h/.local/share/startdgx/backup/etc_cdi_nvidia.yaml"
out=$(s uninstall me@spark 2>&1); ok $((!$?)) "uninstall fails when a backup to restore has changed"
same "$(cat "$r$cdi")" 'cdiVersion: 0.7.0' && echo "$out" | grep -q "backup .* is missing or changed" && none_of "$r$limits"
ok $? "it leaves that file, says why, and still reverts the rest"
present "$FAKE_MANIFEST" "$h/.local/share/startdgx/backup/etc_cdi_nvidia.yaml" && grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json"
ok $? "a failed restore keeps the manifest, the backups and the host"

before_root="put $link '#!/bin/sh old agent'"; installed; before_root=''
m 'item("symlink", "'$link'")["changed_by_us"] and item("symlink", "'$link'")["previous"]["type"] == "file"'; ok $? "a plain file where the agent link goes is recorded as changed"
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall succeeds where the agent link replaced a plain file"
[ ! -L "$r$link" ] && same "$(cat "$r$link")" '#!/bin/sh old agent'; ok $? "the plain file is restored from its backup"

engine_root="ln -sfn /opt/someone-else \"\$root$link\""; installed; engine_root=''
printf '# mine now\n' >"$r$limits"
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall succeeds where files it created were changed since"
present "$r$limits" && same "$(readlink "$r$link")" /opt/someone-else; ok $? "a created file without the engine's header, and an agent link not at the engine, are left"
changed=(podman=yes); installed podman=no; changed=()
s uninstall --delete-models --remove-packages me@spark >/dev/null; ok $? "uninstall --delete-models --remove-packages succeeds"
none_of "$h/.local/share/omarchy"; ok $? "--delete-models deletes the model weights"
grep -q 'apt-get remove -y -qq podman;' "$FAKE_HOST/root-call"; ok $? "--remove-packages removes the packages the install added"

installed; : >"$FAKE_HOST/podman/used-${img//[\/:@]/_}"
out=$(s uninstall me@spark 2>&1); [ -e "$FAKE_HOST/podman/image-${img//[\/:@]/_}" ] && echo "$out" | grep -qF "kept $img"; ok $? "an image a container still uses is kept"

installed; : >"$FAKE_HOST/podman/busy"
s uninstall me@spark >/dev/null 2>&1; ok $((!$?)) "uninstall stops at the first step that fails"
[ -f "$FAKE_MANIFEST" ] && grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json" && none_of "$FAKE_HOST/root-call" "$q/omarchy-agent-local-model-q1.container" \
  && [ -e "$FAKE_HOST/podman/image-${img//[\/:@]/_}" ]; ok $? "a stopped uninstall keeps the manifest and the host, and goes no further"
rm "$FAKE_HOST/podman/busy"; s uninstall me@spark >/dev/null; ok $? "a rerun after a failed step succeeds"
none_of "$FAKE_HOST/podman/image-${img//[\/:@]/_}" "$FAKE_HOST/podman/network" "$FAKE_MANIFEST"; ok $? "the rerun removes the image its removed quadlets named, and finishes"

installed
FAKE_ROOT_FAIL=1 s uninstall me@spark >/dev/null 2>&1; ok $((!$?)) "uninstall fails when the root part fails"
[ -f "$FAKE_MANIFEST" ] && grep -q '"me@spark"' "$XDG_CONFIG_HOME/startdgx/hosts.json"; ok $? "a failed root part keeps the manifest and the host"
rm "$FAKE_HOST/root-call"; s uninstall me@spark >/dev/null; ok $? "a rerun after a failed root part succeeds"
grep -q 'disable-linger me' "$FAKE_HOST/root-call" && none_of "$FAKE_MANIFEST"; ok $? "the rerun runs the root part again and finishes"

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
