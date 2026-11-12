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
  # delete --dry-run's read-only probe, run against the fake home.
  "python3 -I - "*) host bash -c "$cmd";;
  "sudo bash -c "*" startdgx-uninstall") printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi
    script=$(printf '%s' "${cmd#sudo }" | rooted); FAKE_AS_ROOT=1 host eval "$script";;
  "sudo bash -c "*) printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -f "$FAKE_HOST/engine-root" ]; then root=$root bash "$FAKE_HOST/engine-root"; fi
    if [ -f "$FAKE_HOST/probe.after" ]; then cp "$FAKE_HOST/probe.after" "$FAKE_HOST/probe"; fi
    if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi;;
  *"cat > "*manifest*) mkdir -p "${FAKE_MANIFEST%/*}"; cat >"$FAKE_MANIFEST";;
  *"cat "*manifest.json*) cat "$FAKE_MANIFEST" 2>/dev/null; true;;
  *"profile"*) echo '{"ram_class":128,"gpus":[]}';;
  *"start slow-load"*) sleep 2; echo "Started slow-load";;
  # The engine's detach_use: it starts one setup unit per model and says so, or that it's already running.
  *" use "*" --detach") rid=${cmd% --detach}; rid=${rid##* }; echo "Recipe $rid: 3 file(s)"
    if [ -e "$FAKE_HOST.use-$rid" ]; then echo "$rid is already being set up; follow it with: journalctl"
    else : >"$FAKE_HOST.use-$rid"; echo "Setting up $rid in the background; follow it with: journalctl"; fi;;
  *"status --json"*) echo '{"models":{}}';;
  *"fail"*) echo "Error: boom" >&2; exit 1;;
esac
F
cat >"$tmp/bin/rsync" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HOST/rsync.log"
if [ -n "${FAKE_RSYNC_FAIL:-}" ]; then echo "rsync: connection unexpectedly closed" >&2; exit 12; fi
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
cat >"$FAKE_HOSTBIN/id" <<'F'
#!/usr/bin/env bash
echo "${FAKE_ID:-me}"
F
# The user's systemd manager is running.
{ cat "$tmp/stub"; echo 'echo 4242'; } >"$FAKE_HOSTBIN/pgrep"
# apt-get -s prints what apt would remove: the named packages, those in $FAKE_HOST/apt-also, and as root those in
# apt-also-root (what changed since a check as the user).
cat >"$FAKE_HOSTBIN/apt-get" <<'F'
#!/usr/bin/env bash
printf '%s\n' "apt-get $*" >>"$FAKE_HOST/calls"
if [ "$1" = -s ]; then
  echo "NOTE: This is only a simulation!"
  for pkg in "${@:3}" $(cat "$FAKE_HOST/apt-also" ${FAKE_AS_ROOT:+"$FAKE_HOST/apt-also-root"} 2>/dev/null); do [ "$pkg" = -- ] || echo "Remv $pkg [1.0-1]"; done
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
# delete --dry-run: what a removal would free, read from the engine's files and changing none. Model m1 links its own
# blob and one it shares with m2; m3 is a setup in progress with a half-downloaded file in staging.
ed=$FAKE_HOST/home/.local/share/omarchy/agent-local es=$FAKE_HOST/home/.local/state/omarchy/agent-local
mkdir -p "$ed/blobs/sha256" "$ed/models/m1" "$ed/models/m2" "$ed/staging" "$es/models" "$es/installing"
head -c 3000 /dev/zero >"$ed/blobs/sha256/own"; head -c 500 /dev/zero >"$ed/blobs/sha256/shared"
ln "$ed/blobs/sha256/own" "$ed/models/m1/weights"; ln "$ed/blobs/sha256/shared" "$ed/models/m1/tokenizer"; ln "$ed/blobs/sha256/shared" "$ed/models/m2/tokenizer"
echo '{}' >"$es/models/m1.json"; echo '{}' >"$es/models/m2.json"
part=$(printf 'a%.0s' {1..64}).part; head -c 700 /dev/zero >"$ed/staging/$part"
printf '{"phase": "downloading", "partials": ["%s", "../../escape.part"]}\n' "$part" >"$es/installing/m3.json"
: >"$FAKE_LOG"
same "$(s delete --dry-run --json me@dgx m1)" '{"recipe": "m1", "setting_up": false, "bytes": 3000}'; ok $? "delete --dry-run --json counts what only that model links"
same "$(s delete --dry-run --json me@dgx m2)" '{"recipe": "m2", "setting_up": false, "bytes": 0}'; ok $? "and nothing for weights another model shares"
same "$(s delete --dry-run --json me@dgx m3)" '{"recipe": "m3", "setting_up": true, "bytes": 700}'; ok $? "a setup in progress frees what it downloaded so far"
same "$(s delete --dry-run me@dgx m1)" "Removing m1 would free 2.9 KiB"; ok $? "delete --dry-run says it in one line"
same "$(s delete --dry-run me@dgx m3)" "Cancelling the setup of m3 would delete the 700 B downloaded so far"; ok $? "and for a setup, that it cancels it"
out=$(s delete --dry-run me@dgx m4 2>&1); ok $((!$?)) "delete --dry-run refuses a model that isn't set up"
same "$out" "Error: m4 isn't set up on me@dgx"; ok $? "and says so"
! grep -q remove "$FAKE_LOG" && present "$ed/blobs/sha256/own" "$ed/models/m1/weights" "$es/models/m1.json" "$ed/staging/$part"; ok $? "delete --dry-run removes nothing"
s delete --dry-run me@dgx 'x;reboot' >/dev/null 2>&1; ok $((!$?)) "delete --dry-run refuses a recipe id with shell characters"
s start me@dgx 'x; rm -rf ~' >/dev/null 2>&1; ok $((!$?)) "a recipe id with shell characters is refused"
s add -oProxyCommand=x >/dev/null 2>&1; ok $((!$?)) "a host that looks like an ssh option is refused"
: >"$FAKE_LOG"; s add me@dgx:x >/dev/null 2>&1; ok $((!$?)) "a host with a colon is refused"
s install --dry-run me@spark:x --engine-path /nonexistent >/dev/null 2>&1; ok $((!$?)) "install refuses a host with a colon, which rsync would read as a daemon or path"
same "$(wc -l <"$FAKE_LOG")" 0; ok $? "a host with a colon never reaches ssh"
out=$(s start me@dgx slow-load --timeout 1 2>&1); ok $((!$?)) "start gives up after --timeout seconds"
echo "$out" | grep -qx "Error: me@dgx didn't answer in time"; ok $? "and says the host didn't answer in time"
s start --help | grep -q 'default: 600'; ok $? "start waits 600 seconds by default, for the model to load"
out=$(s use --detach me@dgx q-detach); ok $? "use --detach succeeds"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use q-detach --detach$'; ok $? "use --detach asks the engine to set the model up in the background"
same "$out" "Setting up q-detach in the background; follow it with: journalctl"; ok $? "use --detach prints a single line"
out=$(s use --detach me@dgx q-detach); ok $? "a second use --detach of the same model succeeds"
same "$out" "q-detach is already being set up; follow it with: journalctl"; ok $? "and says, in one line, that it's already being set up"
s use me@dgx q-plain >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use q-plain$'; ok $? "use without --detach waits for the setup"
s logs me@dgx q-detach >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai logs q-detach$'; ok $? "logs shows a model's logs from the engine"
s logs me@dgx >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai logs$'; ok $? "logs without a model shows the last one started"
# launch, against a fake terminal launcher that records how many arguments it got, then each one.
cat >"$tmp/bin/omarchy-launch-floating-terminal-with-presentation" <<'F'
#!/usr/bin/env bash
{ echo "$#"; printf '%s\n' "$@"; } >>"$FAKE_LAUNCH"
F
chmod +x "$tmp/bin/omarchy-launch-floating-terminal-with-presentation"; export FAKE_LAUNCH=$tmp/launch.log
cli=$(realpath "$here/bin/startdgx")
launched() { : >"$FAKE_LAUNCH"; s launch "$@" >/dev/null 2>&1 && cat "$FAKE_LAUNCH"; }
same "$(launched install me@spark)" "$(printf '1\n%s\n' "$cli install me@spark")"; ok $? "launch install opens a terminal running startdgx install"
same "$(launched install me@spark --replace-engine)" "$(printf '1\n%s\n' "$cli install me@spark --replace-engine")"; ok $? "launch install --replace-engine passes it on"
same "$(launched uninstall me@spark)" "$(printf '1\n%s\n' "$cli uninstall me@spark")"; ok $? "launch uninstall opens a terminal running startdgx uninstall"
same "$(launched logs me@dgx q1)" "$(printf '1\n%s\n' "$cli logs me@dgx q1")"; ok $? "launch logs opens a terminal on a model's logs"
same "$(launched logs me@dgx)" "$(printf '1\n%s\n' "$cli logs me@dgx")"; ok $? "launch logs without a model shows the last one started"
for refused in "delete me@dgx q1" "start me@dgx q1" "install me@spark q1" "uninstall me@spark q1" "uninstall me@spark --replace-engine" \
               "logs me@dgx q1 --replace-engine"; do
  read -ra words <<<"$refused"; : >"$FAKE_LAUNCH"; s launch "${words[@]}" >/dev/null 2>&1; ok $((!$?)) "launch refuses: $refused"
  same "$(cat "$FAKE_LAUNCH")" ""; ok $? "and opens no terminal: $refused"
done
# shellcheck disable=SC2016 # the shell in these names is meant to stay unexpanded
for host in 'me@x;reboot' '$(reboot)' '-oProxyCommand=x' 'me@x:y' 'me@x y' "me@x'y" 'me@x`id`'; do
  : >"$FAKE_LAUNCH"; s launch install "$host" >/dev/null 2>&1; ok $((!$?)) "launch refuses the host $host"
  same "$(cat "$FAKE_LAUNCH")" ""; ok $? "and opens no terminal for it"
done
# shellcheck disable=SC2016 # as above
for model in 'q1;reboot' '$(reboot)' '-q1' 'q1 x' 'q1&' "q'1"; do
  : >"$FAKE_LAUNCH"; s launch logs me@dgx "$model" >/dev/null 2>&1; ok $((!$?)) "launch refuses the model $model"
  same "$(cat "$FAKE_LAUNCH")" ""; ok $? "and opens no terminal for it"
done
mkdir -p "$tmp/empty"; out=$(PATH=$tmp/empty s launch install me@spark 2>&1); ok $((!$?)) "launch fails without the Omarchy terminal launcher"
echo "$out" | grep -q '^Error: '; ok $? "and says so in one line"
s use --help | tr -s ' \n' ' ' | grep -q 'default: 3600, or 120 with --detach'; ok $? "use --detach waits only for the setup to start"
s forget me@dgx >/dev/null; s hosts --json | grep -q me@dgx; ok $((!$?)) "forget drops the host"
s engine | grep -Eq '^https://github.com/bmaltais/omarchy-local-ai v[0-9]+\.[0-9]+\.[0-9]+-dgx\.[0-9]+$'; ok $? "engine prints the pinned repo and tag"
s engine --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["repo"].startswith("https://") and "-dgx." in d["tag"]))'; ok $? "engine --json gives repo and tag"

# install, against the fake host
fresh_host "gpu=AMD Radeon" dgx_name=
out=$(s install me@pc --engine-path "$engine" 2>&1); ok $((!$?)) "install refuses a host that isn't a DGX Spark"
echo "$out" | grep -q "isn't a DGX Spark"; ok $? "install says why it refused"
none_of "$FAKE_HOST/root-call" "$FAKE_HOST/rsync.log"; ok $? "a refused install changes nothing"

fresh_host 'user=me;x'; s install --dry-run me@spark --engine-path "$engine" 2>&1 | grep -q 'unexpected user'; ok $? "install refuses a host that reports an odd user"
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
m 'item("linger", "me")["previous"] == {"linger": "no"} and item("linger", "me")["created_by_us"]'; ok $? "a failed install records what was there before and what its root script changed"
s install me@spark --engine-path "$engine" >/dev/null; m 'item("linger", "me")["previous"] == {"linger": "no"} and item("linger", "me")["created_by_us"]'; ok $? "a rerun after a failure keeps both"
fresh_host; after linger=yes
FAKE_RSYNC_FAIL=1 s install me@spark --engine-path "$engine" >/dev/null 2>&1; ok $((!$?)) "install fails when copying the engine fails"
m 'item("linger", "me")["created_by_us"]'; ok $? "a failed copy still records what the root script changed"

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

# An engine that was there before startdgx: install replaces it only when told to, keeping a copy.
old_engine=$FAKE_HOST/home/.local/share/omarchy-local-ai
engine_there() { fresh_host; mkdir -p "$old_engine"; echo "old engine" >"$old_engine/agent_local.py"
  spark "engine=$(sha256sum <"$old_engine/agent_local.py" | cut -c1-64)" >"$FAKE_HOST/probe"; after "engine=$(printf '%064d' 9)"; : >"$FAKE_LOG"; }
engine_there
out=$(s install me@spark --engine-path "$engine" 2>&1); ok $((!$?)) "install refuses to overwrite an engine it didn't install"
echo "$out" | grep -q 'omarchy-local-ai' && echo "$out" | grep -q -- '--replace-engine'; ok $? "it says why, and how to replace it"
none_of "$FAKE_HOST/root-call" "$FAKE_HOST/rsync.log" "$FAKE_MANIFEST" "$bk"; ok $? "a refused replacement changes nothing"
out=$(s install --dry-run me@spark --engine-path "$engine" 2>&1); ok $((!$?)) "install --dry-run refuses it too"
echo "$out" | grep -q -- '--replace-engine'; ok $? "and says so"
out=$(s install --dry-run --replace-engine me@spark --engine-path "$engine"); echo "$out" | grep -q "back up the engine"
ok $? "install --dry-run --replace-engine says it backs the engine up"
s install --replace-engine me@spark --engine-path "$engine" >/dev/null; ok $? "install --replace-engine succeeds"
same "$(cat "$bk/engine/agent_local.py" 2>/dev/null)" "old engine"; ok $? "it backs the old engine up first"
m 'item("engine", "/home/me/.local/share/omarchy-local-ai")["previous"]["backup"] == "/home/me/.local/share/startdgx/backup/engine" and item("engine", "/home/me/.local/share/omarchy-local-ai")["changed_by_us"] and not item("engine", "/home/me/.local/share/omarchy-local-ai")["created_by_us"]'
ok $? "the manifest records the backup, and the engine as changed, not created"
echo "newer" >"$old_engine/agent_local.py"; s install me@spark --engine-path "$engine" >/dev/null; ok $? "a second install needs no --replace-engine"
same "$(cat "$bk/engine/agent_local.py")" "old engine"; ok $? "and keeps the first backup"

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
before_root='' engine_root='' changed=() install_flags=()
installed() {
  fresh_host "home=$h" "$@"; eval "$before_root"
  after "home=$h" "$@" linger=yes engine=e1 "${changed[@]}"
  cat >"$FAKE_HOST/engine-root" <<E
mkdir -p "\$root/etc/security/limits.d" "\$root/usr/local/bin"
printf '%s\\n' '$rdma' >"\$root$limits"
ln -sfn '$fentry' "\$root/usr/local/bin/omarchy-agent-local"
$engine_root
E
  s install "${install_flags[@]}" me@spark --engine-path "$engine" >/dev/null || echo "installed: install failed" >&2
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
  && echo "$out" | grep -q "keep .*1.0 MiB" && echo "$out" | grep -q 'omarchy agent local forget'; ok $? "uninstall --dry-run lists what it would change and keep"

out=$(FAKE_ID='me;x' s uninstall --dry-run me@spark 2>&1); ok $((!$?)) "uninstall refuses a host that reports an odd user"
echo "$out" | grep -q 'unexpected user'; ok $? "and says so, before comparing it with the manifest's"
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
echo "$out" | grep -q 'omarchy agent local forget' && echo "$out" | grep -q 'authorized_keys'
ok $? "uninstall says to forget the host on paired Omarchy machines, and that its authorized_keys entry stays"
s uninstall --help | grep -q 'kept by default'; ok $? "uninstall --help says the models are kept by default"
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

FAKE_ROOT_FAIL=1 installed 2>/dev/null
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall after a failed install succeeds"
grep -q 'loginctl disable-linger me' "$FAKE_HOST/calls" && none_of "$r$limits" "$r$link" "$FAKE_MANIFEST"; ok $? "it undoes what the failed install's root script did"

uconf=/etc/systemd/user.conf.d/99-rdma-memlock.conf
engine_root="mkdir -p \"\$root${uconf%/*}\"; printf '%s\\n' '$rdma' >\"\$root$uconf\""; installed; engine_root=''
s uninstall me@spark >/dev/null 2>&1; none_of "$r$uconf" && grep -qx 'systemctl --user -M me@ daemon-reexec' "$FAKE_HOST/calls"
ok $? "removing the user services' memlock default re-executes the user's systemd, to drop it"

# A host whose engine was there before the install, which --replace-engine replaced.
eng=$h/.local/share/omarchy-local-ai
replaced() {
  before_root="mkdir -p $eng; echo 'old engine' >$eng/agent_local.py"; install_flags=(--replace-engine)
  installed "engine=$(echo 'old engine' | sha256sum | cut -c1-64)"; before_root='' install_flags=()
  echo 'new engine' >"$eng/agent_local.py"
}
replaced; before=$(cd "$h" && find . -path ./.local/share/startdgx -prune -o -path ./.local/share/omarchy-local-ai -prune -o -print | sort)
out=$(s uninstall --dry-run me@spark); echo "$out" | grep -q "put back the engine" && echo "$out" | grep -q "was there before" && ! echo "$out" | grep -q 'share q1 --off'
ok $? "uninstall --dry-run of a replaced engine says it puts it back and leaves the engine's setup"
out=$(s uninstall me@spark 2>&1); ok $? "uninstall succeeds where the install replaced an engine"
! echo "$out" | grep -q 'Removing what the engine set up'; ok $? "and doesn't say it removes the engine's setup"
same "$(ls "$eng")" agent_local.py && same "$(cat "$eng/agent_local.py")" 'old engine'; ok $? "it puts the old engine back"
same "$(cd "$h" && find . -path ./.local/share/startdgx -prune -o -path ./.local/share/omarchy-local-ai -prune -o -print | sort)" "$before" \
  && present "$FAKE_HOST/podman/network" "$FAKE_HOST/podman/secret" "$FAKE_HOST/podman/image-${img//[\/:@]/_}" \
  && ! grep -q -e 'systemctl --user stop' -e 'share q1' -e 'tailscale serve --yes' "$FAKE_HOST/calls"
ok $? "it leaves the engine's units, quadlets, network, secret, images, state, config and models"
echo "$out" | grep -q "left .*units.*was there before"; ok $? "and says what it left and why"
grep -q 'loginctl disable-linger me' "$FAKE_HOST/calls" && none_of "$r$limits" "$r$link" "$FAKE_MANIFEST" "$h/.local/share/startdgx"
ok $? "it still undoes as root what the install changed, and finishes"
replaced; rm -rf "$h/.local/share/startdgx/backup/engine"
s uninstall me@spark >/dev/null 2>&1; ok $((!$?)) "uninstall fails when the replaced engine's backup is gone"
present "$FAKE_MANIFEST" && same "$(cat "$eng/agent_local.py")" 'new engine'; ok $? "and keeps the manifest and the engine there"

before_root="put $link '#!/bin/sh old agent'"; installed; before_root=''
m 'item("symlink", "'$link'")["changed_by_us"] and item("symlink", "'$link'")["previous"]["type"] == "file"'; ok $? "a plain file where the agent link goes is recorded as changed"
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall succeeds where the agent link replaced a plain file"
[ ! -L "$r$link" ] && same "$(cat "$r$link")" '#!/bin/sh old agent'; ok $? "the plain file is restored from its backup"

for previous in "put $link '#!/bin/sh old agent'" "mkdir -p $r/usr/local/bin; ln -s /opt/old/agent $r$link"; do
  before_root=$previous engine_root="ln -sfn /opt/someone-else \"\$root$link\""; installed; before_root='' engine_root=''
  out=$(s uninstall me@spark 2>&1); ok $((!$?)) "uninstall fails when it can't put back an agent link that was there (${previous%% *})"
  same "$(readlink "$r$link")" /opt/someone-else && present "$FAKE_MANIFEST" && echo "$out" | grep -q "left .*$link: it no longer points at the engine; put back"; ok $? "it leaves the link, says what to do, and keeps the manifest and backups"
done

compat_header='# Written by omarchy-local-ai link setup'
dropin=/etc/systemd/system/nvidia-cdi-refresh.service.d/podman-compat.conf
engine_root="mkdir -p \"\$root/usr/local/sbin\" \"\$root${dropin%/*}\" \"\$root/etc/cdi\"
printf '#!/usr/bin/python3\\n%s\\n' '$compat_header' >\"\$root$compat\"
printf '[Service]\\nExecStartPost=%s\\n' \"\$root$compat\" >\"\$root$dropin\"
echo 'cdiVersion: 0.6.0' >\"\$root$cdi\""
installed; engine_root=''
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall succeeds where the install wrote the Podman 4 CDI compat"
none_of "$r$compat" "$r$dropin" "$r${dropin%/*}" "$r$cdi" && grep -qx 'systemctl daemon-reload' "$FAKE_HOST/calls"; ok $? "it removes the compat script, its drop-in and the CDI spec, and reloads systemd"
engine_root="mkdir -p \"\$root$(dirname $dropin)\"; printf '[Service]\\nExecStartPost=/opt/mine\\n' >\"\$root$dropin\""; installed; engine_root=''
s uninstall me@spark >/dev/null 2>&1; present "$r$dropin"; ok $? "a drop-in that no longer runs the compat script is left"

engine_root="ln -sfn /opt/someone-else \"\$root$link\""; installed; engine_root=''
printf '# mine now\n' >"$r$limits"
s uninstall me@spark >/dev/null 2>&1; ok $? "uninstall succeeds where files it created were changed since"
present "$r$limits" && same "$(readlink "$r$link")" /opt/someone-else; ok $? "a created file without the engine's header, and an agent link not at the engine, are left"
changed=(podman=yes python3=yes); installed podman=no python3=no; changed=()
out=$(s uninstall --delete-models --remove-packages me@spark 2>&1); ok $? "uninstall --delete-models --remove-packages succeeds"
none_of "$h/.local/share/omarchy"; ok $? "--delete-models deletes the model weights"
grep -qx 'apt-get remove -y -qq podman' "$FAKE_HOST/calls"; ok $? "--remove-packages removes the packages the install added"
! grep -q 'apt-get remove.*python3' "$FAKE_HOST/calls" && echo "$out" | grep -q 'keep python3'; ok $? "--remove-packages never removes python3, and says so"
! grep -q pacman "$FAKE_HOST/root-call"; ok $? "the root part only knows apt (install only supports DGX OS)"

changed=(podman=yes); installed podman=no; changed=(); echo podman-docker >"$FAKE_HOST/apt-also"; before=$(tree)
out=$(s uninstall --dry-run --remove-packages me@spark 2>&1); ok $((!$?)) "uninstall --dry-run --remove-packages refuses when apt would remove more"
echo "$out" | grep -q podman-docker; ok $? "and names what else apt would remove"
out=$(s uninstall --remove-packages me@spark 2>&1); ok $((!$?)) "uninstall --remove-packages refuses when apt would remove more"
same "$(tree)" "$before" && none_of "$FAKE_HOST/root-call" && echo "$out" | grep -q podman-docker; ok $? "and changes nothing"
changed=(podman=yes); installed podman=no; changed=(); echo podman-docker >"$FAKE_HOST/apt-also-root"
out=$(s uninstall --remove-packages me@spark 2>&1); ok $((!$?)) "the root part also refuses a removal that would take more"
! grep -qx 'apt-get remove -y -qq podman' "$FAKE_HOST/calls" && present "$FAKE_MANIFEST" && none_of "$r$limits" && echo "$out" | grep -q podman-docker
ok $? "it keeps the packages and the manifest, and reverts the rest"

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
git -C "$other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m upstream; git -C "$other" push -q origin HEAD:master
"$rel" v0.6.3-dgx.2 "$fork" >/dev/null 2>&1; ok $((!$?)) "release-engine fetches origin, and refuses when its master is not merged"
g merge -q origin/master -m merge
out=$("$rel" v0.6.3-dgx.2 "$fork" 2>&1); ok $? "release-engine accepts a merged, clean, passing fork"
g rev-parse -q --verify refs/tags/v0.6.3-dgx.2 >/dev/null; ok $? "release-engine creates the tag"
echo "$out" | grep -q 'git push fork v0.6.3-dgx.2'; ok $? "release-engine prints the push command"
echo "$out" | grep -q "$(g rev-parse 'v0.6.3-dgx.2^{commit}')"; ok $? "release-engine prints the tag's commit"
git -C "$tmp/fork-remote.git" tag | grep -q .; ok $((!$?)) "release-engine never pushes to fork"
git -C "$tmp/origin.git" tag | grep -q .; ok $((!$?)) "release-engine never pushes to origin"

# discover, against a fake tailscale and a fake ssh that answers per peer from $tmp/disco/peers
disco=$tmp/disco; mkdir -p "$disco/bin" "$disco/peers"
cat >"$disco/bin/tailscale" <<'F'
#!/usr/bin/env bash
printf '%s\n' "tailscale $*" >>"$DISCO_LOG"
[ "$*" = "status --json" ] || exit 2
cat "$DISCO_STATUS"
F
cat >"$disco/bin/ssh" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DISCO_LOG"
host=${*: -2:1}; peer=$DISCO_PEERS/$host
case "$*" in "-o BatchMode=yes -o ConnectTimeout=5 -- "*) ;; *) exit 99;; esac
[ -e "$peer" ] || { echo "ssh: Could not resolve hostname" >&2; exit 255; }
case "$(head -1 "$peer")" in
  refuse) echo "$host: Permission denied (publickey)." >&2; exit 255;;
  hang) sleep 30;;
  *) cat >/dev/null; cat "$peer";;
esac
F
chmod +x "$disco/bin/"*
export DISCO_LOG=$disco/log DISCO_STATUS=$disco/status.json DISCO_PEERS=$disco/peers
python3 - "$DISCO_STATUS" <<'F'
import json, sys
def peer(name, os="linux", online=True):
  return {"HostName": name, "DNSName": f"{name}.tail1234.ts.net.", "OS": os, "Online": online}
peers = [peer("gx10-spark"), peer("gx10-fresh"), peer("pc-linux"), peer("locked-down"), peer("sleepy"),
         peer("gone", online=False), peer("laptop", os="macOS"), peer("phone", os="iOS"), peer("-oProxyCommand=x")]
json.dump({"Self": peer("this-machine"), "Peer": {f"nodekey:{i}": p for i, p in enumerate(peers)}}, open(sys.argv[1], "w"))
F
{ spark startdgx=yes engine=abc; } >"$disco/peers/me@gx10-spark"
spark >"$disco/peers/me@gx10-fresh"
spark "gpu=AMD Radeon" dgx_name= >"$disco/peers/me@pc-linux"
echo refuse >"$disco/peers/me@locked-down"
echo hang >"$disco/peers/me@sleepy"
mkdir -p "$tmp/empty" "$XDG_CONFIG_HOME/startdgx"; echo '{"me@gx10-fresh": {}}' >"$XDG_CONFIG_HOME/startdgx/hosts.json"
hosts_before=$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")
d() { PATH=$disco/bin:$PATH s discover --user me "$@"; }
dj() { PATH=$disco/bin:$PATH s discover --json --user me --timeout 2 | python3 -c "import json,sys; d={p['name']: p for p in json.load(sys.stdin)}; sys.exit(not ($1))"; }
: >"$DISCO_LOG"
out=$(d --json --user me --timeout 2); ok $? "discover --json succeeds with dead and refusing peers"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (isinstance(d, list) and [p["name"] for p in d] == sorted(p["name"] for p in d)))'; ok $? "discover --json is a list sorted by name"
dj 'set(d) == {"gx10-spark", "gx10-fresh", "pc-linux", "locked-down", "sleepy", "-oProxyCommand=x"}'; ok $? "discover leaves out offline and non-Linux peers and this machine"
dj 'all(set(p) == {"name", "target", "reachable", "reason", "spark", "installed", "engine", "added"} for p in d.values())'; ok $? "every peer has exactly the documented keys"
dj 'd["gx10-spark"]["target"] == "me@gx10-spark" and d["gx10-spark"]["spark"] is True and d["gx10-spark"]["installed"] is True and d["gx10-spark"]["engine"] is True and d["gx10-spark"]["added"] is False and d["gx10-spark"]["reachable"] is True and d["gx10-spark"]["reason"] is None'; ok $? "an installed Spark is reported as such"
dj 'd["gx10-fresh"]["spark"] is True and d["gx10-fresh"]["installed"] is False and d["gx10-fresh"]["engine"] is False and d["gx10-fresh"]["added"] is True'; ok $? "a fresh Spark is not installed, and is added when hosts.json has it"
dj 'd["pc-linux"]["spark"] is False and d["pc-linux"]["reachable"] is True'; ok $? "a Linux machine without the Spark signature is not a Spark"
dj 'd["locked-down"]["reachable"] is False and "Permission denied" in d["locked-down"]["reason"] and d["locked-down"]["spark"] is None and d["locked-down"]["installed"] is None'; ok $? "a peer that refuses BatchMode ssh is unreachable, with the reason"
dj 'd["sleepy"]["reachable"] is False and d["sleepy"]["reason"]'; ok $? "a peer that never answers times out as unreachable"
dj 'd["-oProxyCommand=x"]["reachable"] is False and "name" in d["-oProxyCommand=x"]["reason"]'; ok $? "a hostile tailnet name is reported unreachable"
! grep -q -e ProxyCommand "$DISCO_LOG"; ok $? "a hostile tailnet name never reaches ssh"
! grep -e '^-o' "$DISCO_LOG" | grep -vq 'BatchMode=yes -o ConnectTimeout=5 -- '; ok $? "every probe is BatchMode with a 5 second connect timeout"
: >"$DISCO_LOG"; d --json --timeout 2 >/dev/null
[ "$(grep -c '^tailscale' "$DISCO_LOG")" = 1 ] && ! grep -q -e rsync -e sudo "$DISCO_LOG"; ok $? "discover asks tailscale once and runs nothing but the probe"
same "$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")" "$hosts_before"; ok $? "discover never writes hosts.json"
PATH=$disco/bin:$PATH s discover --user bob --json --timeout 2 | grep -q '"target": "bob@gx10-spark"'; ok $? "--user sets the user the probe goes to"
PATH=$disco/bin:$PATH s discover --json --timeout 2 | grep -q "\"target\": \"$(id -un)@gx10-spark\""; ok $? "the user defaults to the local one"
PATH=$disco/bin:$PATH s discover --user 'x y' --json >/dev/null 2>&1; ok $((!$?)) "--user is validated"
d --timeout 2 | grep -q 'gx10-spark.*me@gx10-spark.*spark.*installed'; ok $? "discover prints human lines by default"
d --timeout 2 | grep -q 'locked-down.*unreachable.*Permission denied'; ok $? "the human output says why a peer is unreachable"
echo 'not json' >"$DISCO_STATUS"; d >/dev/null 2>&1; ok $((!$?)) "an unreadable tailscale status is an error"
PATH=$tmp/empty s discover >/dev/null 2>&1; ok $((!$?)) "discover without tailscale is an error"
# Demo mode: fixtures from demo/, state under $XDG_STATE_HOME/startdgx-demo, and nothing run. Every tool that could
# reach a machine is a shim here that records its call; the last test fails if demo mode ran any of them.
mkdir -p "$tmp/demo-bin"; export DEMO_CALLS=$tmp/demo-calls; : >"$DEMO_CALLS"
cat >"$tmp/demo-stub" <<'F'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >>"$DEMO_CALLS"
F
for tool in ssh scp sftp rsync sudo tailscale git systemd-run systemctl ssh-copy-id omarchy-launch-floating-terminal-with-presentation; do
  cp "$tmp/demo-stub" "$tmp/demo-bin/$tool"; chmod +x "$tmp/demo-bin/$tool"
done
t0=2000000000 now=$t0
real_hosts=$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")
ds() { STARTDGX_DEMO=1 XDG_STATE_HOME=$tmp/state STARTDGX_DEMO_NOW=$now PATH=$tmp/demo-bin:$PATH "$here/bin/startdgx" "$@"; }
# dj 'python condition' ARGS: runs ds ARGS and checks its JSON output, d.
dj() { local cond=$1; shift; ds "$@" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ($cond))"; }
row() { dj "d['models'].get('$2', {}).get('unit') == '$3'" status "$1"; }
a=demo@spark-a b=demo@spark-b c=demo@spark-c
nem=nemotron-3.5-bolt-tensorfold qwen=qwen3.8-27b-tensorfold abl=qwen3.8-27b-abliterated-tensorfold flash=qwen3.8-flash-next-tensorfold
dj 'sorted(d) == ["demo@spark-a", "demo@spark-b", "demo@spark-c"] and d["demo@spark-a"]["profile"]["platform"] == "aarch64-gb10"' hosts --json
ok $? "demo hosts --json lists the fixture machines"
model_keys='["endpoint", "error", "expected_load_seconds", "expected_remove_seconds", "expected_stop_seconds", "fit_reason", "fits", "image", "name", "observed", "port", "ram_total_gib", "recipe", "result", "runtime", "shared", "since_ms", "sub_state", "unit", "vendor", "ctx"]'
dj 'sorted(d) == ["best", "last", "link", "models", "ram_total_gib", "share_error"] and all(sorted(m) == sorted('"$model_keys"') for m in d["models"].values())' status $a
ok $? "demo status has the engine's status and model row keys"
dj 'd["models"]["'$qwen'"]["unit"] == "active" and d["models"]["'$abl'"]["fits"] is False and d["models"]["'$nem'"]["unit"] == "failed" and d["models"]["'$nem'"]["error"]' status $a
ok $? "demo spark-a has a running model, one that doesn't fit, and one that failed"
install_keys='["ctx", "endpoint", "error", "expected_load_seconds", "expected_remove_seconds", "expected_stop_seconds", "fit_reason", "fits", "image", "install", "name", "observed", "port", "recipe", "result", "runtime", "since_ms", "sub_state", "unit", "vendor"]'
dj 'sorted(d["models"]["'$flash'"]) == '"$install_keys"' and sorted(d["models"]["'$flash'"]["install"]) == ["done_bytes", "phase", "rate_bytes_s", "total_bytes"]' status $b
ok $? "a demo setup in progress has the engine's install row keys"
dj 'd["models"]["'$flash'"]["install"]["phase"] == "downloading" and round(d["models"]["'$flash'"]["install"]["done_bytes"] / d["models"]["'$flash'"]["install"]["total_bytes"], 2) == 0.4' status $b
ok $? "demo spark-b is 40% through a download"
out=$(ds status $c 2>&1); ok $((!$?)) "demo spark-c doesn't answer"
same "$out" "Error: demo@spark-c didn't answer in time"; ok $? "and says so as an unreachable host does"
dj 'isinstance(d, list) and {r["id"]: r for r in d}["'$flash'"]["available"] and not {r["id"]: r for r in d}["'$flash'"]["installed"] and {r["id"]: r for r in d}["'$flash'"]["best"] and {r["id"]: r for r in d}["'$qwen'"]["active"]' list $a
ok $? "demo list is the catalog, with what is installed and running"
dj 'all(sorted(p) == ["added", "engine", "installed", "name", "reachable", "reason", "spark", "target"] for p in d) and {p["name"]: p for p in d}["spark-a"]["added"] and not {p["name"]: p for p in d}["spark-d"]["added"] and not {p["name"]: p for p in d}["spark-c"]["reachable"]' discover --json
ok $? "demo discover has discover's keys, and knows which machines are added"
now=$((t0 + 10)); dj 'd["models"]["'$flash'"]["install"]["done_bytes"] - round(0.4 * d["models"]["'$flash'"]["install"]["total_bytes"]) in range(3110000000, 3130000000)' status $b
ok $? "a demo download advances with time"
same "$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")" "$real_hosts"; ok $? "demo mode leaves the real hosts.json alone"

now=$t0 out=$(ds start $a $nem); ok $? "demo start succeeds"
same "$out" "Started $nem at http://127.0.0.1:11435/v1"; ok $? "and says where the model is served"
dj 'd["models"]["'$nem'"]["unit"] == "activating" and d["models"]["'$nem'"]["since_ms"] == '"$t0"'000 and d["last"] == "'$nem'"' status $a; ok $? "a started demo model is loading"
now=$((t0 + 7)); row $a $nem active; ok $? "and is running once its load time has passed"
dj '[r for r in d if r["id"] == "'$nem'"][0]["active"]' list $a; ok $? "demo list shows it running"
out=$(ds stop $a $nem); same "$out" "Stopped $nem"; ok $? "demo stop says what it stopped"
row $a $nem deactivating; ok $? "a stopped demo model is stopping"
now=$((t0 + 10)); row $a $nem inactive; ok $? "and stopped once its stop time has passed"
out=$(ds start $a $abl 2>&1); ok $((!$?)) "demo start refuses a model that doesn't fit"
echo "$out" | grep -q '^Error: Not enough memory'; ok $? "and says why"
out=$(ds start $a $flash 2>&1); same "$out" "Error: $flash isn't set up. Run: omarchy agent local use $flash"; ok $? "demo start refuses a model that isn't set up"

out=$(ds use --detach $a $flash); ok $? "demo use --detach succeeds"
same "$(echo "$out" | wc -l)" 1 && echo "$out" | grep -q "^Setting up $flash in the background"; ok $? "and prints one line"
dj 'd["models"]["'$flash'"]["unit"] == "installing" and d["models"]["'$flash'"]["install"]["phase"] == "downloading" and d["models"]["'$flash'"]["install"]["done_bytes"] == 0' status $a
ok $? "a demo setup starts downloading"
out=$(ds use --detach $a $flash); ok $? "a second demo use of the same model succeeds"
echo "$out" | grep -q "^$flash is already being set up"; ok $? "and says it is already being set up"
now=$((t0 + 15)); dj '0 < d["models"]["'$flash'"]["install"]["done_bytes"] < d["models"]["'$flash'"]["install"]["total_bytes"]' status $a; ok $? "the demo setup's download advances"
dj 'not [r for r in d if r["id"] == "'$flash'"][0]["installed"]' list $a; ok $? "a model being set up isn't installed yet"
now=$((t0 + 3600)); row $a $flash active; ok $? "a finished demo setup loads and runs the model"
dj '[r for r in d if r["id"] == "'$flash'"][0]["installed"]' list $a; ok $? "and the list shows it installed"
dj 'd == {"recipe": "'$flash'", "setting_up": False, "bytes": 95 * 2**29}' delete --dry-run --json $a $flash; ok $? "demo delete --dry-run frees what its setup downloaded"
row $a $flash active; ok $? "and changes nothing"
out=$(ds delete $a $flash); ok $? "demo delete succeeds"
row $a $flash removing; ok $? "a deleted demo model is being removed"
now=$((t0 + 3700)); dj '"'$flash'" not in d["models"]' status $a; ok $? "and is gone once its removal time has passed"
dj 'not [r for r in d if r["id"] == "'$flash'"][0]["installed"]' list $a; ok $? "the demo list no longer shows it installed"
now=$((t0 + 20)) dj 'd["setting_up"] and d["bytes"] > 0' delete --dry-run --json $b $flash; ok $? "demo delete --dry-run of a setup counts what is downloaded so far"
ds delete --dry-run $c $flash >/dev/null 2>&1; ok $((!$?)) "demo delete --dry-run on a machine that doesn't answer fails"
now=$((t0 + 20)) out=$(ds delete $b $flash); same "$out" "Cancelled the setup of $flash"; ok $? "deleting a demo setup in progress cancels it"
dj '"'$flash'" not in d["models"]' status $b; ok $? "and drops its row at once"

ds add demo@spark-d >/dev/null && dj '"demo@spark-d" in d' hosts --json; ok $? "demo add adds a discovered machine"
dj 'd["models"] == {}' status demo@spark-d; ok $? "and its status works"
ds add demo@spark-e >/dev/null 2>&1; ok $((!$?)) "demo add refuses a machine without the engine"
ds forget demo@spark-d >/dev/null && dj '"demo@spark-d" not in d' hosts --json; ok $? "demo forget drops it"
out=$(ds launch install demo@spark-e); same "$out" "Demo: would run 'install demo@spark-e' in a terminal"; ok $? "demo launch says what it would run"
ds logs $a $nem >/dev/null; ok $? "demo logs succeeds"
ds install --dry-run demo@spark-e >/dev/null && ds install demo@spark-e >/dev/null && ds uninstall --dry-run $a >/dev/null && ds uninstall $a >/dev/null
ok $? "demo install and uninstall only say what they would do"
ds engine >/dev/null; ds hosts >/dev/null; ds discover >/dev/null; ds list $c >/dev/null 2>&1; ds stop $a >/dev/null
mkdir -p "$tmp/marker/startdgx/demo"; : >"$tmp/marker/startdgx/demo/ENABLED"
XDG_CONFIG_HOME=$tmp/marker XDG_STATE_HOME=$tmp/state PATH=$tmp/demo-bin:$PATH s hosts --json | grep -q demo@spark-a; ok $? "the demo marker file turns demo mode on too"
same "$(cat "$DEMO_CALLS")" ""; ok $? "demo mode never runs ssh, rsync, sudo, tailscale, git, systemd or the terminal launcher"
echo "1..$n"; exit $bad
