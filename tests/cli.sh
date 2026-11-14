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
printf '%s\n' "$*" >>"$FAKE_LOG.args"
if [ "${*: -2:1}" = me@newkey ]; then
  printf '%s\n' "No ED25519 host key is known for newkey and you have requested strict checking." "Host key verification failed." >&2; exit 255
fi
root=$FAKE_HOST/root; [ "$root" != /root ] || exit 99
rooted() { sed "s#/etc/#$root/etc/#g; s#/usr/local/#$root/usr/local/#g"; }
host() { HOME=$FAKE_HOST/home PATH=$FAKE_HOSTBIN:$PATH "$@"; }
case "$cmd" in
  "bash -s") found=$(rooted | host bash -s 2>/dev/null | sed "s#$root##g"); cat "$FAKE_HOST/probe"
    printf '%s\n' "$found" | grep -E '^file:.*=.'; printf '%s\n' "$found" | grep -qx link_kind=none || printf '%s\n' "$found" | grep '^link_';;
  "bash -s -- startdgx-"*) rooted | host bash -s;;
  # delete --dry-run's read-only probe, run against the fake home.
  "python3 -I -"*) host bash -c "$cmd";;
  "sudo bash -c "*" startdgx-uninstall") printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi
    script=$(printf '%s' "${cmd#sudo }" | rooted); FAKE_AS_ROOT=1 host eval "$script";;
  "sudo bash -c "*) printf '%s\n' "$@" >"$FAKE_HOST/root-call"; if [ -f "$FAKE_HOST/engine-root" ]; then root=$root bash "$FAKE_HOST/engine-root"; fi
    if [ -n "${FAKE_ROOT_ESC:-}" ]; then printf 'root\033]52;c;ZXZpbA==\007says\n'; fi
    if [ -f "$FAKE_HOST/probe.after" ]; then cp "$FAKE_HOST/probe.after" "$FAKE_HOST/probe"; fi
    if [ -n "${FAKE_ROOT_FAIL:-}" ]; then exit 1; fi;;
  *"cat > "*manifest*) mkdir -p "${FAKE_MANIFEST%/*}"; cat >"$FAKE_MANIFEST";;
  *"cat "*manifest.json*) cat "$FAKE_MANIFEST" 2>/dev/null; true;;
  *"profile"*) echo '{"ram_class":128,"gpus":[]}';;
  # A host that prints terminal controls: an OSC 52 clipboard write, a C1 CSI, a byte that isn't UTF-8.
  *"logs ctlerr"*) printf 'Error: bad\033[2Jthing\n' >&2; exit 1;;
  *"logs ctl"*) printf 'a\033]52;c;ZXZpbA==\007b\302\233c\td\n\377e\n';;
  *"start slow-load"*) sleep 2; echo "Started slow-load";;
  *"start hang-load"*) echo $$ >"$FAKE_HOST.ssh-pid"; exec sleep 30;;
  # The engine's detach_use: it starts one setup unit per model and says so, or that it's already running.
  *" use "*" --detach") rid=${cmd% --detach}; rid=${rid% --yes}; rid=${rid##* }; echo "Recipe $rid: 3 file(s)"
    if [ -e "$FAKE_HOST.use-$rid" ]; then echo "$rid is already being set up; follow it with: journalctl"
    else : >"$FAKE_HOST.use-$rid"; echo "Setting up $rid in the background; follow it with: journalctl"; fi;;
  # status's own command runs for real, in zsh where there is one (the hosts' login shell), against a stub engine in the fake home.
  *"status --json"*"'#manifest'"*) shell=bash; command -v zsh >/dev/null && shell=zsh; host "$shell" -c "$cmd";;
  *"status --json"*) echo '{"models":{}}';;
  # recipe validate and add make a temp folder, copy stdin into it and run the engine on it: run for real.
  *"mktemp -d"*"recipe "*) shell=bash; command -v zsh >/dev/null && shell=zsh; host "$shell" -c "$cmd";;
  *"recipe remove "*|*"recipe list"*|*"recipe confirm "*|*" measure "*) host sh -c "$cmd";;
  # The engine's share when tailscale serve refuses: it has already saved the share, and says why over several lines.
  *"share serve-off --off"*) echo "serve-off is no longer shared";;
  *"share serve-off"*) printf '%s\n' "Error: tailscale serve /local-ai/serve-off: Serve is not enabled on your tailnet." "To enable, visit:" "  https://login.tailscale.com/f/serve?node=n1" >&2; exit 1;;
  # The engine's share when tailscale serve hangs (a tailnet without Serve makes it wait for a click): it only says so.
  *"share serve-hang"*) echo "Error: tailscale serve didn't answer" >&2; exit 1;;
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
for tool in loginctl sudo; do cp "$tmp/stub" "$FAKE_HOSTBIN/$tool"; done
# systemctl logs like the others, and answers is-active with what a running-UNIT file in the fake host holds (inactive without one).
cat >"$FAKE_HOSTBIN/systemctl" <<'F'
#!/usr/bin/env bash
if [ "$*" != "${*/is-active/}" ]; then st=$(cat "$FAKE_HOST/running-${*: -1}" 2>/dev/null || echo inactive); echo "$st"; [ "$st" = active ]; exit; fi
printf '%s\n' "${0##*/} $*" >>"$FAKE_HOST/calls"
F
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
  "debug prefs") printf '{"OperatorUser": "%s"}\n' "$(cat "$FAKE_HOST/operator" 2>/dev/null)";;
  "set --operator="*) printf '%s' "${2#--operator=}" >"$FAKE_HOST/operator";;
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
eng=$FAKE_HOST/home/.local/share/omarchy-local-ai; mkdir -p "$eng"; cat >"$eng/omarchy-local-ai" <<'F'
#!/bin/sh
# The engine's recipe commands, as the fork's: validate prints its errors on stdout and exits 1, add's rejection is an
# Error: on stderr, and remove refuses a recipe a model uses, naming the model.
if [ "$1" = recipe ]; then
  case "$2" in
    validate) if grep -q CLAIM "$3"; then printf '%s\n' "recipes/claim.variant[0].source: a recipe of yours can't claim measured numbers (only \`measure\` writes them); set source = \"estimated\" or source = \"drafted\"" "recipes/claim.variant[1].source: a recipe of yours can't claim measured numbers (only \`measure\` writes them); set source = \"estimated\" or source = \"drafted\""; exit 1; fi
      if grep -q BAD "$3"; then printf '%s\n' "recipes/bad: no name" "recipes/bad: no runtime"; exit 1; fi; echo "Recipe $(basename "$3" .toml) is valid";;
    add) if grep -q BAD "$3"; then printf '%s\n' "Error: recipes/bad: no name" "recipes/bad: no runtime" >&2; exit 1; fi
      cp "$3" "$HOME/added.toml"; basename "$3" >"$HOME/added.name"; echo "Added recipe $(basename "$3" .toml)";;
    remove) if [ "$3" = used ]; then echo "Error: Recipe used is used by the model used (Used) set up here; remove it first with: omarchy agent local remove used" >&2; exit 1; fi; echo "Removed recipe $3";;
    list) echo '[{"id":"mine","user":true,"source":"drafted"}]';;
    confirm) if [ "$3" = none ]; then echo "Error: Recipe none has no estimated variant to confirm" >&2; exit 1; fi; echo "Confirmed 1 estimated variant(s) of $3";;
  esac
  exit
fi
if [ "$1" = measure ]; then
  printf '%s\n' "Measure $2 at context $4 (now a drafted variant)" "  download: 3.5 GiB to download (3.5 GiB in 2 file(s))" "  load: Mine on tensorfold, context $4"
  if [ "$5" = --yes ]; then echo "Measured $2 at context $4: 61.2 GiB RAM"; echo "$2" >"$HOME/measured"; else echo "Nothing was changed. Run again with --yes to do it."; fi
  exit
fi
echo '{"models":{}}'
F
chmod +x "$eng/omarchy-local-ai"
s status me@dgx | grep -q models; ok $? "status passes the engine's JSON through"
# status says when the host's engine is older than the pin (the manifest records its tag), and only then
pin=$(s engine | cut -d' ' -f2)
st() { s status me@dgx | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ($1))"; }
settag() { mkdir -p "${FAKE_MANIFEST%/*}"; printf '{\n  "engine": {\n    "tag": "%s",\n    "repo": "r"\n  }\n}\n' "$1" >"$FAKE_MANIFEST"; }
rm -f "$FAKE_MANIFEST"; st '"engine_update" not in d and d["models"] == {}'; ok $? "status adds nothing where the host records no engine tag"
settag v0.6.3-dgx.1; st 'd["engine_update"] == {"from": "v0.6.3-dgx.1", "to": "'"$pin"'"}'; ok $? "status says an older engine can be updated to the pin"
settag "$pin"; st '"engine_update" not in d'; ok $? "and nothing where the host has the pin"
settag v9.9.9-dgx.9; st '"engine_update" not in d'; ok $? "and nothing where the host is newer, which an update would downgrade"
settag 'not a tag'; st '"engine_update" not in d'; ok $? "and nothing for a tag it can't read"
rm -f "$FAKE_MANIFEST"
s start me@dgx qwen3.8-27b-tensorfold >/dev/null; ok $? "start runs on the host"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai start qwen3.8-27b-tensorfold'; ok $? "start sends the recipe to the engine"
s stop me@dgx >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai stop$'; ok $? "stop without a model stops every one"
s delete me@dgx qwen3.8-27b-tensorfold >/dev/null; tail -3 "$FAKE_LOG" | grep -q 'remove qwen3.8-27b-tensorfold'; ok $? "delete maps to the engine's remove"
s share me@dgx qwen3.8-27b-tensorfold >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai share qwen3.8-27b-tensorfold$'; ok $? "share sends the recipe to the engine's share"
s share me@dgx qwen3.8-27b-tensorfold --off >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai share qwen3.8-27b-tensorfold --off$'; ok $? "share --off stops sharing it"
before=$(wc -l <"$FAKE_LOG"); s share me@dgx '--off;x' >/dev/null 2>&1; ok $((!$?)) "share refuses what is no recipe id"
same "$(wc -l <"$FAKE_LOG")" "$before"; ok $? "and sends the engine nothing"
err=$(s share me@dgx serve-off 2>&1 >/dev/null); ok $((!$?)) "a share the engine refuses fails"
same "$(echo "$err" | wc -l)" 1 && echo "$err" | grep -q '^Error: serve-off is not shared: tailscale serve /local-ai/serve-off: Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve?node=n1$'
ok $? "with the engine's whole message on one line, saying the model is not shared"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai share serve-off --off$'; ok $? "and the share the engine had already saved is taken back"
s share me@dgx serve-off --off >/dev/null; ok $? "so that unsharing it works"
err=$(s share me@dgx serve-hang 2>&1 >/dev/null)
same "$err" "Error: serve-hang is not shared: tailscale serve didn't answer. Serve may not be enabled on the tailnet: enable it at https://login.tailscale.com/f/serve, then share again"
ok $? "a share whose tailscale serve hangs says Serve may not be enabled, and where to enable it"
# use --ctx, and variants: the context sizes a recipe has measured, read from the recipe file on the host
s use me@dgx qwen3.8-27b-tensorfold --detach --ctx 65536 >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use qwen3.8-27b-tensorfold --ctx 65536 --detach$'; ok $? "use --ctx sends the context to the engine"
s use me@dgx qwen3.8-27b-tensorfold --ctx abc >/dev/null 2>&1; ok $((!$?)) "use --ctx refuses what isn't a number"
mkdir -p "$FAKE_HOST/home/.local/share/omarchy-local-ai/recipes"
cat >"$FAKE_HOST/home/.local/share/omarchy-local-ai/recipes/vr.toml" <<'F'
name = "VR"
[[variant]]
ctx = 65536
peak_ram_gib = 60
peak_gpu_gib = 58
[[variant]]
ctx = 262144
peak_ram_gib = 91.5
peak_gpu_gib = 90
source = "estimated"
F
s variants me@dgx vr --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not (d == [{'ctx': 262144, 'peak_ram_gib': 91.5, 'peak_gpu_gib': 90, 'source': 'estimated', 'confirmed': False}, {'ctx': 65536, 'peak_ram_gib': 60, 'peak_gpu_gib': 58, 'source': 'measured', 'confirmed': False}]))"
ok $? "variants lists a recipe's contexts, largest first, each with its source (measured unless the recipe says otherwise)"
s variants me@dgx vr | grep -q '262144.*91.5'; ok $? "and as text without --json"
s variants me@dgx nope --json >/dev/null 2>&1; ok $((!$?)) "a recipe the host doesn't have is an error"
s variants me@dgx '../x' --json >/dev/null 2>&1; ok $((!$?)) "variants refuses what is no recipe id"
# Recipes: a .toml on this computer goes over ssh on stdin to the engine's recipe commands, in a folder of its own, named
# for its id (the engine takes the id from the file name).
rd=$tmp/recipes; mkdir -p "$rd"
printf 'name = "Mine"\n' >"$rd/mine.toml"; printf 'BAD = 1\n' >"$rd/bad.toml"
out=$(s recipe validate me@dgx "$rd/mine.toml"); ok $? "recipe validate accepts a good file"
same "$out" "Recipe mine is valid"; ok $? "and says what the engine said"
grep -qF "recipe validate \"\$d\"/mine.toml" "$FAKE_LOG"; ok $? "it asks the engine to validate a copy named for the id"
out=$(s recipe validate me@dgx "$rd/bad.toml" 2>&1 >/dev/null); ok $((!$?)) "recipe validate refuses a bad file"
same "$out" "$(printf 'recipes/bad: no name\nrecipes/bad: no runtime')"; ok $? "and prints each of the engine's errors on its own line"
s recipe validate me@dgx "$rd/bad.toml" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d == {"ok": False, "id": "bad", "errors": ["recipes/bad: no name", "recipes/bad: no runtime"], "message": ""}))'
ok $? "recipe validate --json gives the errors as a list, and exits 0, since the machine answered"
printf 'CLAIM = 1\n' >"$rd/claim.toml"
out=$(s recipe validate me@dgx "$rd/claim.toml" 2>&1 >/dev/null); ok $((!$?)) "a recipe the engine rejects for claiming measured numbers is refused"
same "$(echo "$out" | wc -l)" 2 && echo "$out" | sed -n 1p | grep -q 'variant\[0\]' && echo "$out" | sed -n 2p | grep -q 'variant\[1\]'; ok $? "with each of the engine's lines shown on its own line"
printf 'CLAIM = 1\n' >"$rd/claim.toml"
out=$(s recipe validate me@dgx "$rd/claim.toml" 2>&1 >/dev/null); ok $((!$?)) "a recipe the engine rejects for claiming measured numbers is refused"
same "$(echo "$out" | wc -l)" 2 && echo "$out" | sed -n 1p | grep -q 'variant\[0\]' && echo "$out" | sed -n 2p | grep -q 'variant\[1\]'; ok $? "with each of the engine's lines shown on its own line"
rm -f "$FAKE_HOST/home/added.toml"
s recipe validate me@dgx "$rd/mine.toml" >/dev/null; none_of "$FAKE_HOST/home/added.toml"; ok $? "validating changes nothing on the host"
out=$(s recipe add me@dgx "$rd/mine.toml"); same "$out" "Added recipe mine"; ok $? "recipe add installs it under its id"
cmp -s "$rd/mine.toml" "$FAKE_HOST/home/added.toml" && same "$(cat "$FAKE_HOST/home/added.name")" mine.toml; ok $? "the engine got the file's text on stdin, named mine.toml"
s recipe add me@dgx "$rd/bad.toml" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["ok"] is False and d["errors"] == ["recipes/bad: no name", "recipes/bad: no runtime"]))'
ok $? "a rejected add lists the engine's errors, one each, without its Error: prefix"
s recipe add me@dgx "$rd/mine.toml" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d == {"ok": True, "id": "mine", "errors": [], "message": "Added recipe mine"}))'
ok $? "recipe add --json says it was added"
before=$(wc -l <"$FAKE_LOG")
printf 'x' >"$rd/Not_An_Id.toml"; printf 'x' >"$rd/notes.txt"
for f in "$rd/Not_An_Id.toml" "$rd/notes.txt" "$rd/missing.toml" "$rd"; do s recipe validate me@dgx "$f" >/dev/null 2>&1; ok $((!$?)) "recipe validate refuses $(basename "$f") without asking the host"; done
same "$(wc -l <"$FAKE_LOG")" "$before"; ok $? "and sends the host nothing"
head -c 300000 /dev/zero | tr '\0' 'a' >"$rd/huge.toml"; s recipe validate me@dgx "$rd/huge.toml" >/dev/null 2>&1; ok $((!$?)) "a file too big to be a recipe is refused"
tilde='~'; (cd "$rd" && HOME=$rd s recipe validate me@dgx "$tilde/mine.toml" >/dev/null); ok $? "a leading ~ is this computer's home"
s recipe list me@dgx --json | grep -q '"user":true'; ok $? "recipe list --json passes the engine's listing through"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai recipe list --json$'; ok $? "asking the engine for it"
out=$(s recipe remove me@dgx mine); same "$out" "Removed recipe mine"; ok $? "recipe remove removes an unused recipe"
out=$(s recipe remove me@dgx used 2>&1); ok $((!$?)) "recipe remove of one a model uses fails"
same "$out" "Error: Recipe used is used by the model used (Used) set up here; remove it first with: omarchy agent local remove used"; ok $? "with the engine's message"
s recipe remove me@dgx '../x' >/dev/null 2>&1; ok $((!$?)) "recipe remove refuses what is no recipe id"
printf 'name = "Dash"\n' >"$rd/-dash.toml"
(cd "$rd" && s recipe validate me@dgx -- -dash.toml >/dev/null 2>&1); ok $((!$?)) "a path that starts with - is a path after --, and is then refused as a name that can't be an id"
printf 'name = "Dash"\n' >"$rd/dash.toml"; (cd "$rd" && s recipe validate me@dgx -- dash.toml >/dev/null); ok $? "recipe validate takes -- before the file"
(cd "$rd" && s recipe add me@dgx -- dash.toml >/dev/null); ok $? "and so does recipe add"
s recipe validate me@dgx -x >/dev/null 2>&1; ok $((!$?)) "a path that starts with - without -- is an unknown option, not a file"
s recipe validate nobody@else "$rd/mine.toml" >/dev/null 2>&1; ok $((!$?)) "recipe commands refuse a machine that isn't added"
# measure and confirm: the engine's own, over ssh. Without --yes measure says what it would download and changes nothing.
rm -f "$FAKE_HOST/home/measured"
out=$(s recipe measure me@dgx mine --ctx 65536); ok $? "recipe measure without --yes succeeds"
echo "$out" | grep -q '3.5 GiB to download' && echo "$out" | grep -q 'Nothing was changed'; ok $? "and shows the engine's dry-run text: the download, what it loads"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai measure mine --ctx 65536$' && none_of "$FAKE_HOST/home/measured"; ok $? "asking the engine without --yes, which changes nothing"
out=$(s recipe measure me@dgx mine --ctx 65536 --yes); ok $? "recipe measure --yes runs it"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai measure mine --ctx 65536 --yes$' && present "$FAKE_HOST/home/measured"; ok $? "with the engine's --yes"
s recipe measure me@dgx mine >/dev/null 2>&1; ok $((!$?)) "recipe measure needs --ctx"
s recipe measure me@dgx mine --ctx abc >/dev/null 2>&1; ok $((!$?)) "and a number for it"
s recipe measure me@dgx '../x' --ctx 1 >/dev/null 2>&1; ok $((!$?)) "recipe measure refuses what is no recipe id"
out=$(s recipe confirm me@dgx mine); same "$out" "Confirmed 1 estimated variant(s) of mine"; ok $? "recipe confirm accepts a recipe's estimated numbers"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai recipe confirm mine$'; ok $? "through the engine's recipe confirm"
out=$(s recipe confirm me@dgx none 2>&1); ok $((!$?)) "recipe confirm of a recipe with nothing to confirm fails"
same "$out" "Error: Recipe none has no estimated variant to confirm"; ok $? "with the engine's message"
# use of a recipe of yours: the engine wants --yes, which is sent only when asked for.
s use me@dgx mine --detach --yes >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use mine --yes --detach$'; ok $? "use --yes passes the confirmation to the engine"
s use me@dgx mine --detach --ctx 65536 --yes >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use mine --ctx 65536 --yes --detach$'; ok $? "with a context too"
s use me@dgx mine --yes >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use mine --yes$'; ok $? "use --yes without --detach passes it on too"
s use me@dgx mine >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use mine$'; ok $? "use never adds --yes by itself, even for a recipe of yours: only the person's say-so sends it"
s use me@dgx mine --detach --ctx 65536 >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'use mine --ctx 65536 --detach$'; ok $? "a context change doesn't send it either"
s use me@dgx q-noyes --detach >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'use q-noyes --detach$'; ok $? "and is not sent when not asked for"
# variants reads the recipes of yours, in the engine's state dir, as well as the curated ones
mkdir -p "$FAKE_HOST/home/.local/state/omarchy/agent-local/recipes"
cat >"$FAKE_HOST/home/.local/state/omarchy/agent-local/recipes/ur.toml" <<'F'
name = "UR"
[[variant]]
ctx = 32768
peak_ram_gib = 12.3456781
peak_gpu_gib = 18
source = "estimated"
[[variant]]
ctx = 65536
peak_ram_gib = 30
peak_gpu_gib = 28
source = "drafted"
F
s variants me@dgx ur --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ([(v['ctx'], v['source']) for v in d] == [(65536, 'drafted'), (32768, 'estimated')]))"
ok $? "variants reads a recipe of yours from the engine's state dir, with each variant's source"
echo '{"ur": ["32768/12.3456781/18.0"], "other": ["65536/30/28"]}' >"$FAKE_HOST/home/.local/state/omarchy/agent-local/recipes-confirmed.json"
s variants me@dgx ur --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ([(v['ctx'], v['source'], v['confirmed']) for v in d] == [(65536, 'drafted', False), (32768, 'estimated', True)]))"
ok $? "variants marks an estimated variant the person confirmed (the engine's confirmations file keys it by id and its ctx/ram/gpu numbers, written as the float's repr: 12.3456781 and 18.0)"
# Contract with the engine: when a fork checkout is there (STARTDGX_ENGINE, else ~/StartFS/github/omarchy-local-ai), its own variant_key
# must give the key the fixture above holds, so a change to the engine's key format fails here and not on a host.
fork_engine=${STARTDGX_ENGINE:-$HOME/StartFS/github/omarchy-local-ai}
if [ -f "$fork_engine/agent_local.py" ]; then
  engine_key=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import agent_local as a; print(a.variant_key({"ctx": 32768, "peak_ram_gib": 12.3456781, "peak_gpu_gib": 18}))' "$fork_engine" 2>/dev/null)
  matches=1; if [ "$engine_key" = "32768/12.3456781/18.0" ]; then matches=0; fi
  ok $matches "the engine's variant_key gives the key variants reads (a fork checkout is present)"
else
  ok 0 "the engine's variant_key contract is skipped: no fork checkout at $fork_engine"
fi
rm -rf "$FAKE_HOST/home/.local/state/omarchy/agent-local/recipes" "$FAKE_HOST/home/.local/state/omarchy/agent-local/recipes-confirmed.json"
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
out=$(s add me@newkey 2>&1); ok $((!$?)) "add refuses a machine whose host key ssh hasn't seen"
same "$out" "Error: ssh hasn't seen me@newkey's host key yet: Add machine's tailnet list saves it, or run ssh me@newkey once"; ok $? "and says how to get it"
: >"$FAKE_LOG"; s add me@dgx:x >/dev/null 2>&1; ok $((!$?)) "a host with a colon is refused"
s install --dry-run me@spark:x --engine-path /nonexistent >/dev/null 2>&1; ok $((!$?)) "install refuses a host with a colon, which rsync would read as a daemon or path"
same "$(wc -l <"$FAKE_LOG")" 0; ok $? "a host with a colon never reaches ssh"
out=$(s start me@dgx slow-load --timeout 1 2>&1); ok $((!$?)) "start gives up after --timeout seconds"
echo "$out" | grep -qx "Error: me@dgx didn't answer in time"; ok $? "and says the host didn't answer in time"
s start --help | grep -q 'default: 600'; ok $? "start waits 600 seconds by default, for the model to load"
tail -1 "$FAKE_LOG.args" | grep -q -- '-o ServerAliveInterval=15 -o ServerAliveCountMax=3 '; ok $? "ssh sends keepalives, so a host that went away is noticed in 45 s"
# storage: the disks a host could keep its models on, read from lsblk (stubbed here) and changing nothing. A disk
# qualifies when it is mounted and isn't the root device, the efi partition or a snap's loop; it is usable when its
# filesystem handles symlinks and permissions.
cat >"$FAKE_HOSTBIN/lsblk" <<'F'
#!/usr/bin/env bash
cat <<J
{"blockdevices":[
 {"name":"loop0","type":"loop","tran":null,"fstype":"squashfs","mountpoint":"/snap/core22/1","fssize":"73400320","fsavail":"0"},
 {"name":"nvme0n1","type":"disk","tran":"nvme","fstype":null,"mountpoint":null,"children":[
  {"name":"nvme0n1p1","type":"part","tran":"nvme","fstype":"vfat","mountpoint":"/boot/efi","fssize":"535822336","fsavail":"528482304"},
  {"name":"nvme0n1p2","type":"part","tran":"nvme","fstype":"ext4","mountpoint":"/","fssize":"982000000000","fsavail":"424000000000"}]},
 {"name":"sda","type":"disk","tran":"usb","fstype":null,"mountpoint":null,"children":[
  {"name":"sda1","type":"part","tran":"usb","fstype":null,"mountpoint":null},
  {"name":"sda2","type":"part","tran":"usb","fstype":"ext4","mountpoint":"$FAKE_HOST/media/usbdisk","fssize":"1966000000000","fsavail":"492000000000"}]},
 {"name":"sdb","type":"disk","tran":"usb","fstype":"exfat","mountpoint":"$FAKE_HOST/media/stick","fssize":"64000000000","fsavail":"60000000000"}
]}
J
F
chmod +x "$FAKE_HOSTBIN/lsblk"
mkdir -p "$FAKE_HOST/media/usbdisk" "$FAKE_HOST/media/stick"
# shellcheck disable=SC2016 # $FAKE_HOST in the expected text is replaced on the next line
exp='{"store": null, "disks": [{"mount": "$FAKE_HOST/media/usbdisk", "bus": "usb", "fstype": "ext4", "size": 1966000000000, "free": 492000000000, "usable": true, "reason": ""}, {"mount": "$FAKE_HOST/media/stick", "bus": "usb", "fstype": "exfat", "size": 64000000000, "free": 60000000000, "usable": false, "reason": "exfat cannot hold symlinks and permissions; use ext4, xfs or btrfs"}], "models": []}'
exp=${exp//\$FAKE_HOST/$FAKE_HOST}
same "$(s storage me@dgx --json)" "$exp"; ok $? "storage lists the mounted disks other than the root device, and says which a model store can use"
# storage --set: the folder is made on a usable disk and marked, then remembered on the host; --unset forgets it, but not
# while a model's weights are linked into it.
cfg=$FAKE_HOST/home/.local/share/startdgx/store.json store=$FAKE_HOST/media/usbdisk/startdgx-models
out=$(s storage me@dgx --set "$FAKE_HOST/media/stick/models" 2>&1); ok $((!$?)) "storage --set refuses a disk whose filesystem can't hold symlinks"
same "$out" "Error: $FAKE_HOST/media/stick: exfat cannot hold symlinks and permissions; use ext4, xfs or btrfs"; ok $? "and says why"
out=$(s storage me@dgx --set "$FAKE_HOST/home/models" 2>&1); ok $((!$?)) "storage --set refuses a folder that is on the root disk"
same "$out" "Error: $FAKE_HOST/home/models isn't on an external disk; the root disk is where the models already are"; ok $? "and says so"
out=$(s storage me@dgx --set "$FAKE_HOST/media/usbdisk/../stick/x" 2>&1); ok $((!$?)) "storage --set refuses a path that climbs out of its disk"
same "$out" "Error: Give the store as an absolute path without .. or a trailing slash"; ok $? "and says what it wants"
[ ! -e "$cfg" ] && none_of "$FAKE_HOST/media/stick/models" "$FAKE_HOST/home/models"; ok $? "a refused --set changes nothing"
s storage me@dgx --set "$store" >/dev/null; ok $? "storage --set takes a folder on a usable disk"
present "$store/.startdgx-store" && grep -q "$store" "$cfg"; ok $? "and marks the folder and remembers it on the host"
s storage me@dgx --json | grep -q '"store": {"path": "'"$store"'", "present": true}'; ok $? "storage then names the store, present"
rm "$store/.startdgx-store"
s storage me@dgx --json | grep -q '"present": false'; ok $? "a store whose marker is gone (the disk isn't mounted) is not present"
touch "$store/.startdgx-store"
ed=$FAKE_HOST/home/.local/share/omarchy/agent-local; mkdir -p "$ed/blobs/sha256"; : >"$store/w"; ln -s "$store/w" "$ed/blobs/sha256/w"
s storage me@dgx --unset >/dev/null 2>&1; ok $((!$?)) "storage --unset refuses while a model's weights are linked into the store"
present "$cfg"; ok $? "and keeps the setting"
mkdir -p "$FAKE_HOST/media/usbdisk/other"
out=$(s storage me@dgx --set "$FAKE_HOST/media/usbdisk/other" 2>&1); ok $((!$?)) "storage --set refuses to switch stores while weights are linked into the current one"
same "$out" "Error: 1 model file(s) are on the current store, $store; move those models back first"; ok $? "and says which"
grep -q "$store" "$cfg" && [ ! -e "$FAKE_HOST/media/usbdisk/other/.startdgx-store" ]; ok $? "and changes nothing"
s storage me@dgx --set "$store" >/dev/null; ok $? "storage --set of the store already in use is not a switch"
rm "$ed/blobs/sha256/w"
s storage me@dgx --unset >/dev/null; ok $? "storage --unset forgets the store"
[ ! -e "$cfg" ] && present "$store/w"; ok $? "and leaves the disk's contents alone"
# move --to usb: the model's weights go to the store and the model's folder becomes a link to them, which the container's
# bind mount follows (a link to each file would dangle inside it). The engine's blobs link to the store's files too, so a
# later use finds them. Only a model that isn't running, and only once the copy is verified.
ed=$FAKE_HOST/home/.local/share/omarchy/agent-local store=$FAKE_HOST/media/usbdisk/startdgx-models
rm -rf "$ed"; mkdir -p "$ed/blobs/sha256" "$ed/models/big/fs1/target" "$ed/models/big/fs1.rank0" "$ed/models/frag/fs1"
head -c 3000 /dev/urandom >"$ed/blobs/sha256/aaa"; head -c 500 /dev/urandom >"$ed/blobs/sha256/bbb"; head -c 70 /dev/urandom >"$ed/blobs/sha256/ccc"
ln "$ed/blobs/sha256/aaa" "$ed/models/big/fs1/target/w1"; ln "$ed/blobs/sha256/bbb" "$ed/models/big/fs1/tok"; ln "$ed/blobs/sha256/ccc" "$ed/models/frag/fs1/w"
echo state >"$ed/models/big/fs1.rank0/s"; cp "$ed/blobs/sha256/aaa" "$tmp/aaa"; cp "$ed/blobs/sha256/bbb" "$tmp/bbb"
rm -f "$cfg"
out=$(s move me@dgx big --to usb 2>&1); ok $((!$?)) "move refuses without a model store"
same "$out" "Error: No model store is set; set one with: startdgx storage me@dgx --set PATH"; ok $? "and says how to set one"
s storage me@dgx --set "$store" >/dev/null
out=$(s move me@dgx nope --to usb 2>&1); ok $((!$?)) "move refuses a model that isn't set up"
same "$out" "Error: nope isn't set up"; ok $? "and says so"
 echo active >"$FAKE_HOST/running-omarchy-agent-local-model-big.service"
out=$(s move me@dgx big --to usb 2>&1); ok $((!$?)) "move refuses a model that is running"
same "$out" "Error: big is running; stop it first"; ok $? "and says to stop it"
echo activating >"$FAKE_HOST/running-omarchy-agent-local-model-big.service"
s move me@dgx big --to usb >/dev/null 2>&1; ok $((!$?)) "move refuses a model that is loading too"
rm "$FAKE_HOST/running-omarchy-agent-local-model-big.service"
rm "$store/.startdgx-store"
out=$(s move me@dgx big --to usb 2>&1); ok $((!$?)) "move refuses when the store's disk isn't mounted"
same "$out" "Error: The model store $store isn't mounted"; ok $? "and says so"
touch "$store/.startdgx-store"
mkdir -p "$store/frag"; chmod 555 "$store/frag"
s move me@dgx frag --to usb >/dev/null 2>&1; ok $((!$?)) "a move whose copy fails is an error"
[ -d "$ed/models/frag/fs1" ] && [ ! -L "$ed/models/frag/fs1" ] && present "$ed/blobs/sha256/ccc"; ok $? "and leaves the model as it was"
chmod 755 "$store/frag"
out=$(s move me@dgx big --to usb 2>&1); ok $? "move --to usb moves a stopped model"
same "$out" "big: on the store (3.4 KiB)"; ok $? "and says how much"
[ -L "$ed/models/big/fs1" ] && same "$(readlink "$ed/models/big/fs1")" "$store/big/fs1"; ok $? "the model's folder is now a link to the store"
cmp -s "$store/big/fs1/target/w1" "$tmp/aaa" && cmp -s "$store/big/fs1/tok" "$tmp/bbb"; ok $? "the store holds the weights, byte for byte"
[ -L "$ed/blobs/sha256/aaa" ] && cmp -s "$ed/blobs/sha256/aaa" "$tmp/aaa"; ok $? "the engine's blob links to the store's copy"
[ -d "$ed/models/big/fs1.rank0" ] && [ ! -L "$ed/models/big/fs1.rank0" ] && present "$ed/models/big/fs1.rank0/s"; ok $? "the model's state stays where it was"
same "$(s move me@dgx big --to usb)" "big: already on the store"; ok $? "moving a model that is on the store again changes nothing"
# move --to nvme: the reverse. The weights come back as the engine lays them out (a blob, with the model's file hard-linked
# to it); the store's copy stays, so the model is on both and moving it to the store again is only a check and a link.
rm "$store/.startdgx-store"
out=$(s move me@dgx big --to nvme 2>&1); ok $((!$?)) "move --to nvme refuses when the store's disk isn't mounted"
touch "$store/.startdgx-store"
out=$(s move me@dgx big --to nvme 2>&1); ok $? "move --to nvme brings a model back"
same "$out" "big: on the internal disk (3.4 KiB)"; ok $? "and says how much"
[ -d "$ed/models/big/fs1" ] && [ ! -L "$ed/models/big/fs1" ] && cmp -s "$ed/models/big/fs1/target/w1" "$tmp/aaa" && cmp -s "$ed/models/big/fs1/tok" "$tmp/bbb"; ok $? "the model's folder holds the weights again, byte for byte"
same "$(stat -c '%F %h' "$ed/blobs/sha256/aaa")" "regular file 2"; ok $? "each linked to the engine's blob as before"
cmp -s "$store/big/fs1/target/w1" "$tmp/aaa"; ok $? "the store keeps its copy"
same "$(s move me@dgx big --to nvme)" "big: already on the internal disk"; ok $? "moving a model that is on the internal disk again changes nothing"
out=$(s move me@dgx big --to usb 2>&1); ok $? "a model on both goes back to the store"
[ -L "$ed/models/big/fs1" ] && cmp -s "$ed/blobs/sha256/aaa" "$tmp/aaa" && [ -L "$ed/blobs/sha256/aaa" ]; ok $? "by link again, with the store's copy checked"
# storage lists where each model's weights are: on the internal disk, on the store, on both, or on a store that isn't mounted.
loc() { s storage me@dgx --json | python3 -c 'import json,sys; print(" ".join(f"{m['"'"'id'"'"']}={m['"'"'location'"'"']}:{m['"'"'bytes'"'"']}" for m in json.load(sys.stdin)["models"]))'; }
same "$(loc)" "big=usb:3500 frag=nvme:70"; ok $? "storage lists each model with where its weights are, and how big"
s move me@dgx big --to nvme >/dev/null; same "$(loc)" "big=both:3500 frag=nvme:70"; ok $? "a model on both disks is both"
s move me@dgx big --to usb >/dev/null; rm "$store/.startdgx-store"; same "$(loc)" "big=usb-missing:None frag=nvme:70"; ok $? "a model whose store isn't mounted is usb-missing, its size unknown"
touch "$store/.startdgx-store"
# delete also removes the model's folder on the store, which the engine doesn't know about.
s delete me@dgx big >/dev/null; ok $? "delete removes a model"
rm -rf "$ed/models/big" "$ed/blobs/sha256/aaa" "$ed/blobs/sha256/bbb"   # the engine's remove does these; the fake one doesn't
[ ! -e "$store/big" ] && present "$store/.startdgx-store"; ok $? "and its copy on the store, not the store"
# The cases a move can be left in: a crash between its steps, a store that is unmounted, and what depends on the store.
mkdir -p "$ed/models/crashy/fs1.moving" "$ed/models/c2/fs1.returning" "$store/c2/fs1"
echo old >"$ed/models/crashy/fs1.moving/w"; echo new >"$ed/models/c2/fs1.returning/w"; echo new >"$store/c2/fs1/w"
s move me@dgx crashy --to usb >/dev/null; ok $? "a move after a crash between its rename and its link finds the model's files again"
[ -L "$ed/models/crashy/fs1" ] && same "$(cat "$store/crashy/fs1/w")" old && [ ! -e "$ed/models/crashy/fs1.moving" ]; ok $? "and finishes the move"
mkdir -p "$ed/models/crashy/fs1.moving"; echo stale >"$ed/models/crashy/fs1.moving/w"
s move me@dgx crashy --to usb >/dev/null; [ ! -e "$ed/models/crashy/fs1.moving" ] && same "$(cat "$store/crashy/fs1/w")" old; ok $? "a leftover copy beside a finished move is deleted, the store's copy kept"
s move me@dgx c2 --to nvme >/dev/null; ok $? "a move back after a crash between its two last steps finds the new folder"
[ -d "$ed/models/c2/fs1" ] && [ ! -L "$ed/models/c2/fs1" ] && same "$(cat "$ed/models/c2/fs1/w")" new && [ ! -e "$ed/models/c2/fs1.returning" ]; ok $? "and puts it in place"
mkdir -p "$ed/models/zz"; ln -s "$store/zz" "$ed/models/zz/fs1"; mkdir -p "$store/zz"
out=$(s storage me@dgx --unset 2>&1); ok $((!$?)) "storage --unset refuses while a model's folder links into the store, blobs or not"
rm "$ed/models/zz/fs1"
mkdir -p "$ed/models/st" "$store/st/fs1"; ln -s "$store/st/fs1" "$ed/models/st/fs1"
rm "$store/.startdgx-store"
out=$(s start me@dgx st 2>&1); ok $((!$?)) "start refuses a model whose weights are on a store that isn't mounted"
same "$out" "Error: st's weights are on the model store, whose disk isn't mounted"; ok $? "and says so"
out=$(s delete me@dgx frag 2>&1); ok $? "delete with the store unmounted still removes the model"
echo "$out" | grep -q "^The model store isn't mounted; what it holds of frag stays there"; ok $? "and says what stays on the store"
touch "$store/.startdgx-store"
s start me@dgx st >/dev/null 2>&1; ok $? "start goes ahead once the store is mounted"
rm -rf "$ed/models/st" "$store/st" "$ed/models/zz" "$ed/models/crashy" "$ed/models/c2" "$store/zz" "$store/crashy" "$store/c2"
# A model that shares a blob with another frees less than it moves: the move says so, and the second one frees the rest.
mkdir -p "$ed/models/sh1/fs1" "$ed/models/sh2/fs1"
head -c 100 /dev/urandom >"$ed/blobs/sha256/own1"; head -c 40 /dev/urandom >"$ed/blobs/sha256/shared"
ln "$ed/blobs/sha256/own1" "$ed/models/sh1/fs1/w"; ln "$ed/blobs/sha256/shared" "$ed/models/sh1/fs1/tok"; ln "$ed/blobs/sha256/shared" "$ed/models/sh2/fs1/tok"
same "$(s move me@dgx sh1 --to usb)" "sh1: on the store (140 B), freeing 100 B on the internal disk; 40 B is shared with another model and stays there"; ok $? "move says how much a shared blob keeps on the internal disk"
same "$(s move me@dgx sh2 --to usb)" "sh2: on the store (40 B)"; ok $? "and the model that shares it frees it"
same "$(stat -c %F "$ed/blobs/sha256/shared")" "symbolic link"; ok $? "whose blob then links to the store"
rm -rf "$ed/models/sh1" "$ed/models/sh2" "$store/sh1" "$store/sh2" "$ed/blobs/sha256/own1" "$ed/blobs/sha256/shared"
# startdgx stopped (a shell restart kills the panel's processes) takes its ssh with it.
for sig in TERM INT HUP; do
  # startdgx itself in the background (a function there would be a subshell, which the signal wouldn't pass through).
  rm -f "$FAKE_HOST.ssh-pid"; "$here/bin/startdgx" start me@dgx hang-load >/dev/null 2>&1 & cli_pid=$!
  for _ in $(seq 50); do [ -s "$FAKE_HOST.ssh-pid" ] && break; sleep 0.1; done
  kill -"$sig" "$cli_pid"; wait "$cli_pid"; code=$?
  ssh_pid=$(cat "$FAKE_HOST.ssh-pid" 2>/dev/null); sleep 0.3
  [ -n "$ssh_pid" ] && ! kill -0 "$ssh_pid" 2>/dev/null && [ "$code" -ne 0 ]; ok $? "SIG$sig to startdgx ends its ssh too"
  [ -z "$ssh_pid" ] || kill "$ssh_pid" 2>/dev/null
done
out=$(s use --detach me@dgx q-detach); ok $? "use --detach succeeds"
tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use q-detach --detach$'; ok $? "use --detach asks the engine to set the model up in the background"
same "$out" "Setting up q-detach in the background; follow it with: journalctl"; ok $? "use --detach prints a single line"
out=$(s use --detach me@dgx q-detach); ok $? "a second use --detach of the same model succeeds"
same "$out" "q-detach is already being set up; follow it with: journalctl"; ok $? "and says, in one line, that it's already being set up"
s use me@dgx q-plain >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai use q-plain$'; ok $? "use without --detach waits for the setup"
s logs me@dgx q-detach >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai logs q-detach$'; ok $? "logs shows a model's logs from the engine"
s logs me@dgx >/dev/null; tail -1 "$FAKE_LOG" | grep -q 'omarchy-local-ai logs$'; ok $? "logs without a model shows the last one started"
out=$(s logs me@dgx ctl | od -An -c | tr -s ' \n' ' '); ok $? "logs passes on output with terminal controls in it, and output that isn't UTF-8"
same "$out" " a ] 5 2 ; c ; Z X Z p b A = = b c \t d \n 357 277 275 e \n "; ok $? "with the controls taken out (C0 and C1, but newline and tab), and bad bytes shown as such"
out=$(s logs me@dgx ctlerr 2>&1 | od -An -c | tr -s ' \n' ' '); same "$out" " E r r o r : b a d [ 2 J t h i n g \n "; ok $? "and an error line from the host is cleaned too"
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
same "$(launched uninstall me@spark --delete-recipes)" "$(printf '1\n%s\n' "$cli uninstall me@spark --delete-recipes")"; ok $? "launch uninstall passes on --delete-recipes"
same "$(launched uninstall me@spark --delete-models --remove-packages)" "$(printf '1\n%s\n' "$cli uninstall me@spark --delete-models --remove-packages")"; ok $? "launch uninstall passes on --delete-models and --remove-packages"
same "$(launched logs me@dgx q1)" "$(printf '1\n%s\n' "$cli logs me@dgx q1")"; ok $? "launch logs opens a terminal on a model's logs"
same "$(launched logs me@dgx)" "$(printf '1\n%s\n' "$cli logs me@dgx")"; ok $? "launch logs without a model shows the last one started"
for refused in "delete me@dgx q1" "start me@dgx q1" "install me@spark q1" "uninstall me@spark q1" "uninstall me@spark --replace-engine" \
               "logs me@dgx q1 --replace-engine" "install me@spark --delete-models" "logs me@dgx --remove-packages" "install me@spark --delete-recipes"; do
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
# Adds and forgets run at once (the panel's forget doesn't wait behind an add): none may lose another's change.
for i in $(seq 1 12); do s add "me@par$i" >/dev/null & done; s forget me@nothing >/dev/null 2>&1 & wait
same "$(s hosts | grep -c '^me@par')" 12; ok $? "adds at the same time all land in hosts.json"
for i in $(seq 1 12); do s forget "me@par$i" >/dev/null & done; wait
same "$(s hosts | grep -c '^me@par')" 0; ok $? "and so do forgets"
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
out=$(FAKE_ROOT_ESC=1 s install me@spark --engine-path "$engine" 2>&1); echo "$out" | grep -q 'root]52;c;ZXZpbA==says' && ! echo "$out" | grep -q $'\033'
ok $? "what the root script prints reaches this terminal without its terminal controls"
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

# The tailscale operator: without it tailscale serve refuses the user the engine shares as. The install sets it when the host
# runs tailscale and records what it was; uninstall puts that back only while it is still ours.
fresh_host operator=; after operator=me
out=$(s install --dry-run me@spark --engine-path "$engine"); echo "$out" | grep -q 'set the tailscale operator to me'; ok $? "install --dry-run lists setting the tailscale operator"
s install me@spark --engine-path "$engine" >/dev/null
# shellcheck disable=SC2016 # the $1 is the root script's, meant to stay unexpanded
grep -q 'tailscale set --operator="\$1"' "$FAKE_HOST/root-call"; ok $? "the root script sets the tailscale operator to the user"
m 'item("operator", "tailscale")["created_by_us"] and item("operator", "tailscale")["previous"] == {"operator": ""}'; ok $? "an operator that was unset is marked ours"
fresh_host operator=bob; after operator=me
out=$(s install --dry-run me@spark --engine-path "$engine"); echo "$out" | grep -q 'set the tailscale operator to me (now bob)'; ok $? "the plan says whose operator it replaces"
s install me@spark --engine-path "$engine" >/dev/null
m 'item("operator", "tailscale")["changed_by_us"] and item("operator", "tailscale")["previous"] == {"operator": "bob"}'; ok $? "another user's operator is recorded and marked changed"
fresh_host operator=me; after operator=me
out=$(s install --dry-run me@spark --engine-path "$engine"); ! echo "$out" | grep -q operator; ok $? "an operator that is already the user needs no step"
s install me@spark --engine-path "$engine" >/dev/null
! grep -q 'tailscale set' "$FAKE_HOST/root-call" && m 'not item("operator", "tailscale")["created_by_us"] and not item("operator", "tailscale")["changed_by_us"]'; ok $? "and is not marked ours"
fresh_host; s install me@spark --engine-path "$engine" >/dev/null
! grep -q 'tailscale' "$FAKE_HOST/root-call" && m '("operator", "tailscale") not in its'; ok $? "a host without tailscale gets no operator step and no item"
fresh_host operator='?'; after operator=me
s install me@spark --engine-path "$engine" >/dev/null
grep -q 'tailscale set --operator' "$FAKE_HOST/root-call" && m '("operator", "tailscale") not in its'; ok $? "an operator the user can't read is set but not recorded, so uninstall leaves it"

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

uj() { s uninstall --dry-run --json "$@" me@spark | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ($cond))"; }
cond='sorted(d) == ["host", "kept", "manual", "models_bytes", "packages", "recipes", "steps"] and d["host"] == "me@spark" and d["recipes"] == 0 and d["models_bytes"] == 1048576 and d["packages"] == []'
uj; ok $? "uninstall --dry-run --json says the plan, the weights' size and the packages it could remove"
cond='any("share q1 --off" in step for step in d["steps"]) and any("1.0 MiB" in k for k in d["kept"]) and any("forget" in m for m in d["manual"])'
uj; ok $? "with the same steps, what it keeps and what is left for you, as the text plan"
cond='any("delete ~/.local/share/omarchy/agent-local" in step for step in d["steps"]) and not any("1.0 MiB" in k for k in d["kept"])'
uj --delete-models; ok $? "and with --delete-models, the weights go in the steps"
same "$(tree)" "$before" && none_of "$FAKE_HOST/root-call"; ok $? "uninstall --dry-run --json writes nothing"
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

changed=(operator=me); installed operator=; changed=(); echo me >"$FAKE_HOST/operator"
s uninstall --dry-run me@spark | grep -q 'as root: clear the tailscale operator'; ok $? "uninstall --dry-run lists clearing an operator the install set"
s uninstall me@spark >/dev/null 2>&1; same "$(cat "$FAKE_HOST/operator")" ""; ok $? "uninstall clears the operator the install set"
changed=(operator=me); installed operator=; changed=(); echo carol >"$FAKE_HOST/operator"
s uninstall me@spark >/dev/null 2>&1; same "$(cat "$FAKE_HOST/operator")" carol; ok $? "and leaves one someone else set since"
changed=(operator=me); installed operator=bob; changed=(); echo me >"$FAKE_HOST/operator"
s uninstall --dry-run me@spark | grep -q 'as root: set the tailscale operator back to bob'; ok $? "uninstall --dry-run lists putting back the operator the install replaced"
s uninstall me@spark >/dev/null 2>&1; same "$(cat "$FAKE_HOST/operator")" bob; ok $? "uninstall puts back the operator the install replaced"
installed operator=me; echo me >"$FAKE_HOST/operator"
s uninstall me@spark >/dev/null 2>&1; same "$(cat "$FAKE_HOST/operator")" me; ok $? "uninstall leaves an operator that was already the user's"

# A host whose engine was there before the install, which --replace-engine replaced.
eng=$h/.local/share/omarchy-local-ai
replaced() {
  before_root="mkdir -p $eng; echo 'old engine' >$eng/agent_local.py"; install_flags=(--replace-engine)
  installed "engine=$(echo 'old engine' | sha256sum | cut -c1-64)"; before_root='' install_flags=()
  echo 'new engine' >"$eng/agent_local.py"
}
setrecipes() { local d=$h/.local/state/omarchy/agent-local; mkdir -p "$d/recipes"; echo 'name = "m"' >"$d/recipes/mine.toml"; echo '{}' >"$d/recipes-confirmed.json"; }
replaced; setrecipes; before=$(cd "$h" && find . -path ./.local/share/startdgx -prune -o -path ./.local/share/omarchy-local-ai -prune -o -print | sort)
out=$(s uninstall --dry-run me@spark); echo "$out" | grep -q "put back the engine" && echo "$out" | grep -q "was there before" && ! echo "$out" | grep -q 'share q1 --off'
ok $? "uninstall --dry-run of a replaced engine says it puts it back and leaves the engine's setup"
s uninstall --dry-run --json --delete-recipes me@spark | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["recipes"] == 0 and not any("recipes" in x for x in d["steps"] + d["kept"])))'
ok $? "where the engine was there before, the plan has no recipes of ours to keep or delete"
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

# Recipes of yours live in the engine's state dir, which uninstall deletes: they are kept unless --delete-recipes says
# otherwise, and the install manifest records nothing for them (they are never created by startdgx).
installed; setrecipes
m 'not any("recipes" in str(i) for i in d["items"])'; ok $? "the install manifest records nothing for the recipe folder"
cond='d["recipes"] == 1 and any("keep" in k and "your recipes" in k and "--delete-recipes" in k for k in d["kept"]) and any("except your recipes" in st for st in d["steps"])'
uj; ok $? "uninstall --dry-run --json counts the recipes of yours and says it keeps them"
cond='any("with your recipes" in st for st in d["steps"]) and not any("keep" in k and "your recipes" in k for k in d["kept"])'
uj --delete-recipes; ok $? "and with --delete-recipes, they go in the steps"
before=$(tree); s uninstall --dry-run me@spark >/dev/null; same "$(tree)" "$before"; ok $? "the dry run changes nothing"
out=$(s uninstall me@spark 2>&1); ok $? "uninstall succeeds where there are recipes of yours"
present "$h/.local/state/omarchy/agent-local/recipes/mine.toml" "$h/.local/state/omarchy/agent-local/recipes-confirmed.json"; ok $? "your recipes (and what you confirmed) are kept"
none_of "$h/.local/state/omarchy/agent-local/status.json" "$h/.config/omarchy/agent-local"; ok $? "the rest of the engine's state still goes"
echo "$out" | grep -q 'keep your recipes'; ok $? "and it says it kept them"
installed; setrecipes
s uninstall --delete-recipes me@spark >/dev/null 2>&1; ok $? "uninstall --delete-recipes succeeds"
none_of "$h/.local/state/omarchy"; ok $? "and deletes them"
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
changed=(podman=yes); installed podman=no; changed=()
cond='d["packages"] == ["podman"]'; uj; ok $? "uninstall --dry-run --json names the packages --remove-packages would remove"

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
g add -A; g commit -qm base; g push -q origin HEAD:master; g tag v0.6.3; g push -q origin v0.6.3; g fetch -q origin
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
git -C "$tmp/origin.git" tag | grep -q -- '-dgx'; ok $((!$?)) "release-engine never pushes to origin"
# The tag names the upstream release it contains (v0.6.3-dgx.3 once held v0.6.4 and was cut anyway)
git -C "$other" -c user.name=t -c user.email=t@t tag v0.6.4 && git -C "$other" push -q origin v0.6.4
out=$("$rel" v0.6.3-dgx.3 "$fork" 2>&1); ok $((!$?)) "release-engine refuses a tag that names an older upstream release than HEAD contains"
echo "$out" | grep -q 'tag it v0.6.4-dgx.N'; ok $? "release-engine says which release to name the tag for"
g rev-parse -q --verify refs/tags/v0.6.3-dgx.3 >/dev/null; ok $((!$?)) "release-engine creates no tag when it refuses"
"$rel" v0.6.4-dgx.1 "$fork" >/dev/null 2>&1; ok $? "release-engine accepts the tag named for the upstream release HEAD contains"

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
case "$*" in "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -- "*) ;; *) exit 99;; esac
[ -e "$peer" ] || { echo "ssh: Could not resolve hostname" >&2; exit 255; }
case "$(head -1 "$peer")" in
  refuse) echo "$host: Permission denied (publickey)." >&2; exit 255;;
  rekeyed) printf '%s\n' "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@" "Host key verification failed." >&2; exit 255;;
  hang) echo $$ >>"$DISCO_PIDS"; exec sleep 30;;
  *) cat >/dev/null; cat "$peer";;
esac
F
chmod +x "$disco/bin/"*
export DISCO_LOG=$disco/log DISCO_STATUS=$disco/status.json DISCO_PEERS=$disco/peers DISCO_PIDS=$disco/pids
python3 - "$DISCO_STATUS" <<'F'
import json, sys
def peer(name, os="linux", online=True):
  return {"HostName": name, "DNSName": f"{name}.tail1234.ts.net.", "OS": os, "Online": online}
peers = [peer("gx10-spark"), peer("gx10-fresh"), peer("pc-linux"), peer("locked-down"), peer("sleepy"), peer("rekeyed"),
         peer("gone", online=False), peer("laptop", os="macOS"), peer("phone", os="iOS"), peer("-oProxyCommand=x")]
json.dump({"Self": peer("this-machine"), "Peer": {f"nodekey:{i}": p for i, p in enumerate(peers)}}, open(sys.argv[1], "w"))
F
{ spark startdgx=yes engine=abc; } >"$disco/peers/me@gx10-spark"
spark >"$disco/peers/me@gx10-fresh"
spark "gpu=AMD Radeon" dgx_name= >"$disco/peers/me@pc-linux"
echo refuse >"$disco/peers/me@locked-down"
echo hang >"$disco/peers/me@sleepy"
echo rekeyed >"$disco/peers/me@rekeyed"
mkdir -p "$tmp/empty" "$XDG_CONFIG_HOME/startdgx"; echo '{"me@gx10-fresh": {}}' >"$XDG_CONFIG_HOME/startdgx/hosts.json"
hosts_before=$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")
d() { PATH=$disco/bin:$PATH s discover --user me "$@"; }
dj() { PATH=$disco/bin:$PATH s discover --json --user me --timeout 2 | python3 -c "import json,sys; d={p['name']: p for p in json.load(sys.stdin)}; sys.exit(not ($1))"; }
: >"$DISCO_LOG"
out=$(d --json --user me --timeout 2); ok $? "discover --json succeeds with dead and refusing peers"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (isinstance(d, list) and [p["name"] for p in d] == sorted(p["name"] for p in d)))'; ok $? "discover --json is a list sorted by name"
dj 'set(d) == {"gx10-spark", "gx10-fresh", "pc-linux", "locked-down", "sleepy", "rekeyed", "-oProxyCommand=x"}'; ok $? "discover leaves out offline and non-Linux peers and this machine"
dj 'all(set(p) == {"name", "target", "reachable", "reason", "spark", "installed", "engine", "added"} for p in d.values())'; ok $? "every peer has exactly the documented keys"
dj 'd["gx10-spark"]["target"] == "me@gx10-spark" and d["gx10-spark"]["spark"] is True and d["gx10-spark"]["installed"] is True and d["gx10-spark"]["engine"] is True and d["gx10-spark"]["added"] is False and d["gx10-spark"]["reachable"] is True and d["gx10-spark"]["reason"] is None'; ok $? "an installed Spark is reported as such"
dj 'd["gx10-fresh"]["spark"] is True and d["gx10-fresh"]["installed"] is False and d["gx10-fresh"]["engine"] is False and d["gx10-fresh"]["added"] is True'; ok $? "a fresh Spark is not installed, and is added when hosts.json has it"
dj 'd["pc-linux"]["spark"] is False and d["pc-linux"]["reachable"] is True'; ok $? "a Linux machine without the Spark signature is not a Spark"
dj 'd["locked-down"]["reachable"] is False and d["locked-down"]["reason"] == "ssh needs a key: run ssh-copy-id me@locked-down" and d["locked-down"]["spark"] is None and d["locked-down"]["installed"] is None'; ok $? "a peer that refuses key-based ssh is unreachable, and says how to give it a key"
dj 'd["rekeyed"]["reachable"] is False and d["rekeyed"]["reason"].startswith("its host key changed")'; ok $? "a peer whose host key changed says so, not ssh's banner"
dj 'd["sleepy"]["reachable"] is False and d["sleepy"]["reason"]'; ok $? "a peer that never answers times out as unreachable"
dj 'd["-oProxyCommand=x"]["reachable"] is False and "name" in d["-oProxyCommand=x"]["reason"]'; ok $? "a hostile tailnet name is reported unreachable"
! grep -q -e ProxyCommand "$DISCO_LOG"; ok $? "a hostile tailnet name never reaches ssh"
! grep -e '^-o' "$DISCO_LOG" | grep -vq 'BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -- '; ok $? "every probe is BatchMode with a 5 second connect timeout, and takes a never-seen host's key"
grep -q -e '^-o' "$DISCO_LOG"; ok $? "(the probes were logged)"
: >"$DISCO_LOG"; d --json --timeout 2 >/dev/null
[ "$(grep -c '^tailscale' "$DISCO_LOG")" = 1 ] && ! grep -q -e rsync -e sudo "$DISCO_LOG"; ok $? "discover asks tailscale once and runs nothing but the probe"
same "$(cat "$XDG_CONFIG_HOME/startdgx/hosts.json")" "$hosts_before"; ok $? "discover never writes hosts.json"
PATH=$disco/bin:$PATH s discover --user bob --json --timeout 2 | grep -q '"target": "bob@gx10-spark"'; ok $? "--user sets the user the probe goes to"
PATH=$disco/bin:$PATH s discover --json --timeout 2 | grep -q "\"target\": \"$(id -un)@gx10-spark\""; ok $? "the user defaults to the local one"
PATH=$disco/bin:$PATH s discover --user 'x y' --json >/dev/null 2>&1; ok $((!$?)) "--user is validated"
d --timeout 2 | grep -q 'gx10-spark.*me@gx10-spark.*spark.*installed'; ok $? "discover prints human lines by default"
d --timeout 2 | grep -q 'locked-down.*unreachable.*ssh-copy-id me@locked-down'; ok $? "the human output says why a peer is unreachable"
echo 'not json' >"$DISCO_STATUS"; d >/dev/null 2>&1; ok $((!$?)) "an unreadable tailscale status is an error"
PATH=$tmp/empty s discover >/dev/null 2>&1; ok $((!$?)) "discover without tailscale is an error"
python3 - "$DISCO_STATUS" <<'P'
import json, sys
peers = [{"HostName": f"hung-{i}", "DNSName": f"hung-{i}.tail1234.ts.net.", "OS": "linux", "Online": True} for i in range(12)]
json.dump({"Peer": {str(i): p for i, p in enumerate(peers)}}, open(sys.argv[1], "w"))
P
for i in $(seq 0 11); do echo hang >"$disco/peers/me@hung-$i"; done
: >"$DISCO_PIDS"; PATH=$disco/bin:$PATH "$here/bin/startdgx" discover --user me --json --timeout 20 >/dev/null 2>&1 & cli_pid=$!
for _ in $(seq 50); do [ "$(wc -l <"$DISCO_PIDS")" -ge 8 ] && break; sleep 0.1; done
kill -TERM "$cli_pid"; wait "$cli_pid"; sleep 0.5
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)) && kill "$p"; done <"$DISCO_PIDS"
same "$alive:$(wc -l <"$DISCO_PIDS")" "0:8"; ok $? "a stopped discover ends all its probes, and starts no more"
: >"$DISCO_PIDS"; began=$SECONDS
out=$(PATH=$disco/bin:$PATH "$here/bin/startdgx" discover --user me --json --timeout 20 --limit 2); ok $? "discover with a time limit succeeds when peers hang"
same "$((SECONDS - began <= 5))" 1; ok $? "and ends at its limit, not each peer's timeout"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (len(d) == 12 and all(not p["reachable"] and p["reason"] for p in d)))'
ok $? "every peer it didn't hear from in time is unreachable, with why"
echo "$out" | grep -q "discover's time limit"; ok $? "one it never asked says the limit ran out"
"$here/bin/startdgx" discover --help | grep -q -- '--limit'; ok $? "discover --help names --limit"
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
dj 'sorted(d) == ["demo@gx10-demo", "demo@spark-a", "demo@spark-b", "demo@spark-c"] and d["demo@spark-a"]["profile"]["platform"] == "aarch64-gb10"' hosts --json
ok $? "demo hosts --json lists the fixture machines"
# gx10-demo mirrors a real Spark's answers (tests/js/fixtures/gx10-*.json): long names, a recipe of yours, a model store with
# models on it, and a recipe that measured one context twice.
g=demo@gx10-demo
dj 'd["models"]["'$abl'"]["name"] == "Qwen3.8 27B Abliterated TensorFold" and d["models"]["'$abl'"]["shared"] and d["models"]["'$nem'"]["unit"] == "failed" and len(d["models"]) == 5' status $g
ok $? "demo gx10-demo has a long-named shared model, a failed one, and five in all"
dj 'd["store"] == {"path": "/media/demo/usb/startdgx-models", "present": True} and {m["id"]: m["location"] for m in d["models"]}["'$abl'"] == "usb" and {m["id"]: m["location"] for m in d["models"]}["'$qwen'"] == "both" and {m["id"]: m["location"] for m in d["models"]}["'$nem'"] == "nvme"' storage $g --json
ok $? "it starts with a model store set (storage.json), one model on it and one on both disks"
dj '[(v["ctx"], v["peak_ram_gib"]) for v in d] == [(262144, 54), (262144, 40)]' variants $g $nem --json
ok $? "its Nemotron recipe has two variants at one context, as the engine's has"
dj '{r["id"]: r for r in d}["nemotron-3.5-lightning-spark"]["user"] is True' list $g
ok $? "and it has a recipe of yours"
dj 'd["store"] is None' storage $a --json; ok $? "a demo machine without storage.json has no store"
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
dj 'd["models"]["'$nem'"]["shared"] is False' status $a; ok $? "a demo model starts private"
out=$(ds share $a $nem); same "$out" "Sharing $nem on your tailnet (demo)"; ok $? "demo share says so"
dj 'd["models"]["'$nem'"]["shared"] is True' status $a; ok $? "and the model is shared, stopped or not"
out=$(ds share $a $nem --off); same "$out" "$nem is no longer shared"; ok $? "demo share --off says so"
dj 'd["models"]["'$nem'"]["shared"] is False' status $a; ok $? "and the model is private again"
out=$(ds share $a $flash 2>&1); same "$out" "Error: $flash isn't set up. Run: omarchy agent local use $flash"; ok $? "demo share refuses a model that isn't set up"
out=$(ds start $a $abl 2>&1); ok $((!$?)) "demo start refuses a model that doesn't fit"
echo "$out" | grep -q '^Error: Not enough memory'; ok $? "and says why"
out=$(ds start $a $flash 2>&1); same "$out" "Error: $flash isn't set up. Run: omarchy agent local use $flash"; ok $? "demo start refuses a model that isn't set up"

out=$(ds use --detach $a $flash); ok $? "demo use --detach succeeds"
same "$(echo "$out" | wc -l)" 1 && echo "$out" | grep -q "^Setting up $flash in the background"; ok $? "and prints one line"
dj 'd["models"]["'$flash'"]["unit"] == "installing" and d["models"]["'$flash'"]["install"]["phase"] == "waiting" and d["models"]["'$flash'"]["install"]["done_bytes"] == 0' status $a
ok $? "a demo setup starts waiting, as the engine's does"
now=$((t0 + 11)); dj 'd["models"]["'$flash'"]["install"]["phase"] == "waiting"' status $a; ok $? "and waits two seconds"
now=$((t0 + 13)); dj 'd["models"]["'$flash'"]["install"]["phase"] == "downloading" and 0 < d["models"]["'$flash'"]["install"]["done_bytes"] <= 1200000000' status $a
ok $? "then downloads, from the end of its wait"
now=$((t0 + 10))
out=$(ds use --detach $a $flash); ok $? "a second demo use of the same model succeeds"
echo "$out" | grep -q "^$flash is already being set up"; ok $? "and says it is already being set up"
now=$((t0 + 15)); dj '0 < d["models"]["'$flash'"]["install"]["done_bytes"] < d["models"]["'$flash'"]["install"]["total_bytes"]' status $a; ok $? "the demo setup's download advances"
dj 'not [r for r in d if r["id"] == "'$flash'"][0]["installed"]' list $a; ok $? "a model being set up isn't installed yet"
now=$((t0 + 3600)); row $a $flash active; ok $? "a finished demo setup loads and runs the model"
dj '[r for r in d if r["id"] == "'$flash'"][0]["installed"]' list $a; ok $? "and the list shows it installed"
dj '[v["ctx"] for v in d] == [262144, 131072, 65536] and d[0]["peak_ram_gib"] > d[2]["peak_ram_gib"]' variants $a $qwen --json; ok $? "demo variants lists a model's contexts, each needing less memory"
out=$(ds use --detach $a $qwen --ctx 12345 2>&1); ok $((!$?)) "demo use --ctx refuses a context that isn't measured"
now=$((t0 + 3700)); out=$(ds use --detach $a $qwen --ctx 131072); ok $? "demo use --ctx restarts a model set up with another context"
dj 'd["models"]["'$qwen'"]["ctx"] == 131072 and d["models"]["'$qwen'"]["unit"] == "activating"' status $a; ok $? "and it reloads at once with it"
now=$((t0 + 7200)); row $a $qwen active; ok $? "then runs again"
now=$((t0 + 3600))
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

# User recipes in demo mode: the engine's recipe commands on fixture files (demo/recipes), kept in the demo's state.
rdir=$here/demo/recipes; llama=my-llama-8b draft=my-draft-70b
was=$now; now=$((t0 + 4000))
out=$(ds recipe validate $a "$rdir/$llama.toml"); same "$out" "Recipe $llama is valid"; ok $? "demo recipe validate accepts a good recipe"
dj '"'$llama'" not in [r["id"] for r in d]' recipe list $a --json; ok $? "and adds nothing"
out=$(ds recipe validate $a "$rdir/broken-recipe.toml" 2>&1 >/dev/null); ok $((!$?)) "demo recipe validate refuses a broken one"
[ "$(echo "$out" | wc -l)" -ge 3 ] && echo "$out" | grep -q 'name' && echo "$out" | grep -q 'no-such-runtime' && echo "$out" | grep -q 'ctx'; ok $? "with each error on its own line"
dj 'd["ok"] is False and len(d["errors"]) >= 3 and d["id"] == "broken-recipe"' recipe validate $a "$rdir/broken-recipe.toml" --json; ok $? "and as a list with --json"
mkdir -p "$tmp/clash"; cp "$rdir/$llama.toml" "$tmp/clash/$nem.toml"
out=$(ds recipe validate $a "$tmp/clash/$nem.toml" --json); echo "$out" | grep -q "clashes with the curated recipe '$nem'"; ok $? "an id equal to a curated recipe's is rejected, naming it"
out=$(ds recipe add $a "$rdir/$llama.toml"); same "$out" "Added recipe $llama"; ok $? "demo recipe add adds it"
dj '{r["id"]: r for r in d}["'$llama'"]["user"] is True and {r["id"]: r for r in d}["'$llama'"]["source"] == "estimated" and not {r["id"]: r for r in d}["'$llama'"]["available"] and not {r["id"]: r for r in d}["'$nem'"]["user"]' recipe list $a --json
ok $? "recipe list --json marks it user and estimated, not yet fitting, and a curated recipe not user"
ds recipe confirm $a $llama >/dev/null; dj '{r["id"]: r for r in d}["'$llama'"]["available"]' recipe list $a --json; ok $? "and available once confirmed"
dj '{r["id"]: r for r in d}["'$llama'"]["user"] is True' list $a; ok $? "so does the machine's list, which the model picker reads"
ds recipe add $a "$rdir/$draft.toml" >/dev/null; ok $? "demo recipe add adds a drafted recipe"
dj '{r["id"]: r for r in d}["'$draft'"]["source"] == "drafted" and not {r["id"]: r for r in d}["'$draft'"]["available"] and {r["id"]: r for r in d}["'$draft'"]["reason"]' list $a
ok $? "which is not available, and says why"
ds recipe add $a "$rdir/broken-recipe.toml" >/dev/null 2>&1; ok $((!$?)) "demo recipe add refuses a broken one"
printf 'name = "Claim"\nsummary = "s"\nruntime = "tensorfold"\n[[variant]]\nctx = 1024\npeak_ram_gib = 1\npeak_gpu_gib = 1\nsource = "measured"\n[[variant]]\nctx = 2048\npeak_ram_gib = 2\npeak_gpu_gib = 2\n' >"$tmp/claim.toml"
out=$(ds recipe validate $a "$tmp/claim.toml" 2>&1 >/dev/null); ok $((!$?)) "the demo engine rejects a variant of yours that claims measured numbers, or has no source"
same "$(echo "$out" | grep -c "can't claim measured numbers")" 2; ok $? "one line for each such variant"
echo "$out" | grep -q 'variant\[1\].source.*estimated.*drafted'; ok $? "saying to set estimated or drafted"
dj '[(v["ctx"], v["source"]) for v in d] == [(131072, "estimated"), (32768, "estimated")]' variants $a $llama --json; ok $? "demo variants reads a user recipe's own variants, with their sources"
dj '[v["source"] for v in d] == ["drafted"]' variants $a $draft --json; ok $? "and a drafted one's"
dj 'all(v["source"] == "measured" for v in d)' variants $a $qwen --json; ok $? "a curated recipe's are measured"
ds recipe validate $c "$rdir/$llama.toml" >/dev/null 2>&1; ok $((!$?)) "demo recipe validate on a machine that doesn't answer fails"
out=$(ds use --detach $a $llama 2>&1); ok $((!$?)) "a user recipe isn't set up without --yes, as the engine's use says"
echo "$out" | grep -q "is a recipe of yours, so it isn't set up without your say-so"; ok $? "and the engine's message says to review it first"
ds use --detach $a $llama --yes >/dev/null; ok $? "with --yes a user recipe is set up like any other"
out=$(ds recipe remove $a $llama 2>&1); ok $((!$?)) "demo recipe remove of a recipe a model uses fails"
echo "$out" | grep -q "Error: Recipe $llama is used by the model $llama (My Llama 8B)"; ok $? "naming the model"
ds recipe add $a "$rdir/$llama.toml" >/dev/null 2>&1; ok $((!$?)) "and so does replacing it"
ds delete $a $llama >/dev/null; out=$(ds recipe remove $a $llama); same "$out" "Removed recipe $llama"; ok $? "once the model is gone, demo recipe remove succeeds"
dj '"'$llama'" not in [r["id"] for r in d]' list $a; ok $? "and the recipe is gone from the list"
out=$(ds recipe remove $a $nem 2>&1); ok $((!$?)) "demo recipe remove refuses a curated recipe"
echo "$out" | grep -q "curated recipe"; ok $? "and says it is one"
ds recipe remove $a nothing-here >/dev/null 2>&1; ok $((!$?)) "and one that isn't there"
# measure and confirm
out=$(ds recipe measure $a $draft --ctx 65536); ok $? "demo recipe measure without --yes shows what it would do"
echo "$out" | grep -q 'download' && echo "$out" | grep -q 'Nothing was changed'; ok $? "the download and that nothing was changed"
dj '[v["source"] for v in d] == ["drafted"]' variants $a $draft --json; ok $? "and changes nothing"
ds recipe measure $a $draft --ctx 12345 --yes >/dev/null 2>&1; ok $((!$?)) "demo recipe measure refuses a context the recipe has no variant for"
ds recipe measure $a $qwen --ctx 262144 --yes >/dev/null 2>&1; ok $((!$?)) "and a curated recipe"
out=$(ds recipe measure $a $draft --ctx 65536 --yes); ok $? "demo recipe measure --yes measures it"
dj '[v["source"] for v in d] == ["measured"] and d[0]["peak_ram_gib"] != 90' variants $a $draft --json; ok $? "its variant is now measured, with the numbers it showed"
dj '{r["id"]: r for r in d}["'$draft'"]["source"] == "measured" and {r["id"]: r for r in d}["'$draft'"]["available"]' recipe list $a --json; ok $? "and the recipe fits"
est=my-estimate-14b
ds recipe add $a "$rdir/$est.toml" >/dev/null; ok $? "demo recipe add adds an estimated recipe"
dj '{r["id"]: r for r in d}["'$est'"]["source"] == "estimated" and not {r["id"]: r for r in d}["'$est'"]["available"]' list $a; ok $? "which does not fit until it is confirmed"
out=$(ds recipe confirm $a $est); same "$out" "Confirmed 1 estimated variant(s) of $est"; ok $? "demo recipe confirm accepts it"
dj '{r["id"]: r for r in d}["'$est'"]["available"] and {r["id"]: r for r in d}["'$est'"]["source"] == "estimated"' list $a; ok $? "and it then fits, its numbers still estimated"
ds recipe confirm $a $draft >/dev/null 2>&1; ok $((!$?)) "a recipe with no estimated variant has nothing to confirm"
ds recipe confirm $a $nem >/dev/null 2>&1; ok $((!$?)) "nor a curated one"
ds recipe remove $a $est >/dev/null; ds recipe remove $a $draft >/dev/null; ok $? "unused user recipes are removed"
# uninstall keeps the recipes of yours unless asked
ds recipe add $a "$rdir/$llama.toml" >/dev/null
dj 'd["recipes"] == 1 and any("--delete-recipes" in k for k in d["kept"]) and any("except your recipes" in s for s in d["steps"])' uninstall --dry-run --json $a; ok $? "demo uninstall --dry-run --json counts the recipes of yours and keeps them"
dj 'any("with your recipes" in s for s in d["steps"]) and not any("your recipes" in k for k in d["kept"])' uninstall --dry-run --json --delete-recipes $a; ok $? "and --delete-recipes deletes them"
ds recipe remove $a $llama >/dev/null
dj 'd["recipes"] == 0 and not any("your recipes" in k for k in d["kept"])' uninstall --dry-run --json $a; ok $? "with none, there is nothing to keep"
now=$was
ds add demo@spark-d >/dev/null && dj '"demo@spark-d" in d' hosts --json; ok $? "demo add adds a discovered machine"
dj 'd["models"] == {}' status demo@spark-d; ok $? "and its status works"
ds add demo@spark-e >/dev/null 2>&1; ok $((!$?)) "demo add refuses a machine without the engine"
ds add demo@spark-f >/dev/null; ok $? "demo add adds a machine with an engine startdgx didn't install"
out=$(ds use --detach demo@spark-f $flash 2>&1); ok $((!$?)) "a setup there fails, as the engine's does on a machine not set up as root"
same "$out" "Error: This machine needs Podman set up as root first: run this same command once in a terminal, where sudo can ask for your password"
ok $? "with the engine's own words"
ds forget demo@spark-f >/dev/null
ds forget demo@spark-d >/dev/null && dj '"demo@spark-d" not in d' hosts --json; ok $? "demo forget drops it"
out=$(ds launch install demo@spark-e); same "$out" "Demo: would run 'install demo@spark-e' in a terminal"; ok $? "demo launch says what it would run"
ds logs $a $nem >/dev/null; ok $? "demo logs succeeds"
dj 'sorted(d) == ["host", "kept", "manual", "models_bytes", "packages", "recipes", "steps"] and d["models_bytes"] > 0 and d["packages"] == ["podman"] and any("--delete-models" in k for k in d["kept"])' uninstall --dry-run --json $a
ok $? "demo uninstall --dry-run --json gives a plan the uninstall card can show"
dj 'any("model weights" in s for s in d["steps"]) and any("podman" in s for s in d["steps"]) and d["kept"] == []' uninstall --dry-run --json --delete-models --remove-packages $a
ok $? "and its opt-ins move into the steps"
ds install --dry-run demo@spark-e >/dev/null && ds install demo@spark-e >/dev/null && ds uninstall --dry-run $a >/dev/null && ds uninstall $a >/dev/null
ok $? "demo install and uninstall only say what they would do"
ds engine >/dev/null; ds hosts >/dev/null; ds discover >/dev/null; ds list $c >/dev/null 2>&1; ds stop $a >/dev/null
# A demo start returns only once its model has loaded, as the engine's does, on the real clock (a held one never
# moves, so the tests above return at once).
rs() { STARTDGX_DEMO=1 XDG_STATE_HOME=$tmp/state-real PATH=$tmp/demo-bin:$PATH "$here/bin/startdgx" "$@"; }
out=$(rs start $a $nem --timeout 1 2>&1); ok $((!$?)) "a demo start waits for its model to load, and gives up after --timeout"
same "$out" "Error: $a didn't answer in time"; ok $? "and says the machine didn't answer in time"
began=$SECONDS; out=$(rs start $a $nem --timeout 20); ok $? "a demo start returns once its model has loaded"
same "$out" "Started $nem at http://127.0.0.1:11435/v1" && [ $((SECONDS - began)) -ge 3 ]; ok $? "after its load time, not at once"
rs status $a | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["models"]["'$nem'"]["unit"] != "active")'; ok $? "and the model then runs"
rs start $b $nem --timeout 20 >"$tmp/start-out" 2>&1 & starter=$!
sleep 1; rs stop $b $nem >/dev/null; ok $? "a demo stop runs while that model's start waits for it to load"
wait $starter; ok $((!$?)) "the start it stopped then fails, as the engine's does"
grep -q "^Error: $nem didn't start" "$tmp/start-out"; ok $? "and says it didn't start"
mkdir -p "$tmp/marker/startdgx/demo"; : >"$tmp/marker/startdgx/demo/ENABLED"
XDG_CONFIG_HOME=$tmp/marker XDG_STATE_HOME=$tmp/state PATH=$tmp/demo-bin:$PATH s hosts --json | grep -q demo@spark-a; ok $? "the demo marker file turns demo mode on too"
# hf search: the anonymous Hugging Face API behind STARTDGX_HF_BASE (here a fixture folder, demo/hf), never the real site.
hf() { STARTDGX_HF_BASE=$here/demo/hf s hf search "$@"; }
hj() { local cond=$1; shift; hf "$@" --json | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['repo']: x for x in d}; sys.exit(not ($cond))"; }
hj 'set(r) == {"TensorFold/Qwen3.8-27B-MLX-4bit", "daguoagi/Huihui-Qwen3.8-27B-abliterated-MLX-4bit", "LiquidAI/LFM2.5-24B-A2B-MLX-4bit", "someone/Gemma-4-31B-uncensored-MLX-4bit"}' qwen
ok $? "hf search lists the affine 4-bit repos of known families and hides 8-bit, 3-bit, mxfp4, BF16 tagged mlx, unknown architectures, gated, and missing or malformed configs"
hj 'sorted(r["TensorFold/Qwen3.8-27B-MLX-4bit"]) == ["base_model", "label", "license", "params", "repo", "size_bytes"]' qwen
ok $? "a row has repo, params, size_bytes, license, base_model and label"
hj 'r["TensorFold/Qwen3.8-27B-MLX-4bit"] == {"repo": "TensorFold/Qwen3.8-27B-MLX-4bit", "params": 27356728560, "size_bytes": 16074529674, "license": "apache-2.0", "base_model": "Qwen/Qwen3.8-27B", "label": None}' qwen
ok $? "its parameter count, weights size (the safetensors files only), license and base model come from the repo"
hj 'r["daguoagi/Huihui-Qwen3.8-27B-abliterated-MLX-4bit"]["label"] == "abliterated" and r["daguoagi/Huihui-Qwen3.8-27B-abliterated-MLX-4bit"]["base_model"] == "Qwen/Qwen3.8-27B"' qwen
ok $? "a derivative is labelled abliterated and shows its base model"
hj 'r["someone/Gemma-4-31B-uncensored-MLX-4bit"]["label"] == "uncensored" and r["someone/Gemma-4-31B-uncensored-MLX-4bit"]["base_model"] is None and r["someone/Gemma-4-31B-uncensored-MLX-4bit"]["license"] is None' qwen
ok $? "an uncensored repo is labelled so, and a missing base model or license is null"
badhf=$tmp/hf-bad; cp -r "$here/demo/hf" "$badhf"
python3 - "$badhf" <<'F'
import json, os, shutil, sys
root = sys.argv[1]
rows = json.load(open(root + "/api/models.json"))
for bad in ("x y/z", "../x/y", "a/b/c", "x/y;z"):
  rows.append(dict(rows[0], id=bad))
json.dump(rows, open(root + "/api/models.json", "w"))
os.makedirs(root + "/x y/z/raw/main")
shutil.copy(root + "/TensorFold/Qwen3.8-27B-MLX-4bit/raw/main/config.json", root + "/x y/z/raw/main/config.json")
F
out=$(STARTDGX_HF_BASE=$badhf s hf search qwen --json); same "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" 4
ok $? "a listing id that isn't an OWNER/NAME repo name is skipped, not fetched"
out=$(hf qwen); same "$(printf '%s\n' "$out" | wc -l)" 4 && ! printf '%s' "$out" | grep -q '^[[{]'; ok $? "the human output is one row per line"
printf '%s\n' "$out" | grep -q '^TensorFold/Qwen3.8-27B-MLX-4bit  27.4B  15.0 GiB  apache-2.0  Qwen/Qwen3.8-27B$'; ok $? "a row reads repo, parameters, weights size, license, base model"
printf '%s\n' "$out" | grep -q '^daguoagi/.*  Qwen/Qwen3.8-27B  \[abliterated\]$'; ok $? "and a derivative ends with its label"
printf '%s' "$out" | grep -qi 'fit'; ok $((!$?)) "no row claims a fit (ADR 0001)"
empty=$tmp/hf-empty; mkdir -p "$empty/api"; echo '[]' >"$empty/api/models.json"
out=$(STARTDGX_HF_BASE=$empty s hf search nothing 2>&1); ok $? "a search with no results succeeds"
same "$out" "No known-family MLX 4-bit repos matched"; ok $? "and says there were none"
out=$(STARTDGX_HF_BASE=http://127.0.0.1:9 s hf search qwen 2>&1); ok $((!$?)) "an unreachable Hugging Face fails"
same "$out" "Error: Can't reach Hugging Face: check the network"; ok $? "and says it is offline, not that nothing matched"
same "$(STARTDGX_HF_BASE=http://127.0.0.1:9 s hf search qwen --json 2>/dev/null)" ""; ok $? "and prints no list, not even an empty one"
python3 - "$tmp/hf-limit.port" <<'F' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(429); self.send_header("Retry-After", "150"); self.end_headers()
  def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port)); srv.handle_request()
F
limiter=$!; until [ -s "$tmp/hf-limit.port" ]; do sleep 0.1; done
out=$(STARTDGX_HF_BASE=http://127.0.0.1:$(cat "$tmp/hf-limit.port") s hf search qwen 2>&1); ok $((!$?)) "a rate-limited search fails"
same "$out" "Error: Hugging Face is limiting requests, try again in 3 minutes"; ok $? "and says when to try again"
wait $limiter
gt() { [ "$1" -gt "$2" ]; }
# cache, parallelism cap, and a broken repo, against a counting local server (hf-srv.py logs each request path)
cat >"$tmp/hf-srv.py" <<'F'
import http.server, os, sys, threading, time
root, log = sys.argv[1], sys.argv[2]
lock, state = threading.Lock(), {"now": 0, "max": 0}
class H(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    path = self.path.split("?")[0].strip("/")
    with lock:
      state["now"] += 1; state["max"] = max(state["max"], state["now"])
      open(log, "a").write(path + "\n"); open(log + ".max", "w").write(str(state["max"]))
    time.sleep(0.15 if path.endswith("config.json") else 0)
    with lock: state["now"] -= 1
    if path.endswith("BROKEN/m/raw/main/config.json"):
      self.send_response(500); self.end_headers(); return
    f = os.path.join(root, path + ("" if path.endswith(".json") else ".json"))
    if not os.path.exists(f):
      self.send_response(404); self.end_headers(); return
    body = open(f, "rb").read()
    self.send_response(200); self.end_headers(); self.wfile.write(body)
  def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[3], "w").write(str(srv.server_port))
threading.Timer(120, lambda: os._exit(0)).start()
srv.serve_forever()
F
many=$tmp/hf-many; mkdir -p "$many/api"
python3 - "$many" <<'F'
import json, sys, os
root = sys.argv[1]
ids = ["BROKEN/m"] + [f"o{i}/m" for i in range(24)]
json.dump([{"id": i} for i in ids], open(f"{root}/api/models.json", "w"))
for i in ids:
  os.makedirs(f"{root}/{i}/raw/main", exist_ok=True)
  json.dump({"architectures": ["Qwen3_5ForConditionalGeneration"], "quantization": {"mode": "affine", "bits": 4}}, open(f"{root}/{i}/raw/main/config.json", "w"))
F
python3 "$tmp/hf-srv.py" "$many" "$tmp/hf-log" "$tmp/hf-srv.port" & hfsrv=$!
until [ -s "$tmp/hf-srv.port" ]; do sleep 0.1; done
hs() { XDG_CACHE_HOME=$tmp/hf-cache STARTDGX_HF_NOW=$hnow STARTDGX_HF_BASE=http://127.0.0.1:$(cat "$tmp/hf-srv.port") s hf search "$@"; }
hnow=1000000; out=$(hs many --json); ok $? "a search where one repo's config fetch errors succeeds"
same "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" 24; ok $? "and the other repos are all listed"
peak=$(cat "$tmp/hf-log.max"); gt "$peak" 1 && gt 9 "$peak"; ok $? "the repos' configs are fetched in parallel, at most 8 at a time"
before=$(wc -l <"$tmp/hf-log")
hnow=$((hnow + 3599)); out2=$(hs many --json); same "$out2" "$out"; ok $? "a repeat search within the hour gives the same rows"
same "$(wc -l <"$tmp/hf-log")" "$before"; ok $? "and makes no network request"
hs other --json >/dev/null; after=$(wc -l <"$tmp/hf-log"); gt "$after" "$before"; ok $? "another query is not served from the cache"
before=$(wc -l <"$tmp/hf-log"); hnow=$((hnow + 3601)); hs many --json >/dev/null
after=$(wc -l <"$tmp/hf-log"); gt "$after" "$before"; ok $? "after an hour the same query goes to the network again"
kill "$hfsrv" 2>/dev/null; wait "$hfsrv" 2>/dev/null
out=$(STARTDGX_HF_BASE=http://127.0.0.1:9 ds hf search qwen --json); ok $? "demo hf search ignores STARTDGX_HF_BASE and serves the bundled fixtures"
same "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" 4; ok $? "with the same rows"
# storage and move in demo mode: a USB disk and where each model is, kept in the demo state, and nothing run.
dj 'd["store"] is None and [x["mount"] for x in d["disks"]] == ["/media/demo/usb"] and d["disks"][0]["usable"] and all(m["location"] == "nvme" for m in d["models"]) and len(d["models"]) == 3' storage $a --json
ok $? "demo storage lists a USB disk, no store, and every set-up model on the NVMe"
out=$(ds move $a $abl --to usb 2>&1); ok $((!$?)) "demo move refuses without a store"
same "$out" "Error: No model store is set; set one with: startdgx storage $a --set PATH"; ok $? "and says how to set one"
ds storage $a --set /media/demo/usb/startdgx-models; ok $? "demo storage --set takes a folder on the USB disk"
ds storage $a --set /tmp/elsewhere >/dev/null 2>&1; ok $((!$?)) "and refuses one that isn't on it"
dj 'd["store"] == {"path": "/media/demo/usb/startdgx-models", "present": True}' storage $a --json; ok $? "then names the store"
out=$(ds move $a $qwen --to usb 2>&1); same "$out" "Error: $qwen is running; stop it first"; ok $? "demo move refuses a running model"
out=$(ds move $a $abl --to usb); echo "$out" | grep -q "^$abl: on the store ("; ok $? "demo move --to usb moves a stopped model"
dj '{m["id"]: m["location"] for m in d["models"]}["'$abl'"] == "usb"' storage $a --json; ok $? "and storage says so"
out=$(ds storage $a --unset 2>&1); ok $((!$?)) "demo storage --unset refuses while a model is on the store"
out=$(ds move $a $abl --to nvme); echo "$out" | grep -q "^$abl: on the internal disk ("; ok $? "demo move --to nvme brings it back"
dj '{m["id"]: m["location"] for m in d["models"]}["'$abl'"] == "both"' storage $a --json; ok $? "to both disks"
ds storage $a --unset; ok $? "demo storage --unset forgets the store"
ds storage $a --set /media/demo/usb/startdgx-models; ds move $a $abl --to usb >/dev/null; ds delete $a $abl >/dev/null
python3 -c 'import json,sys; sys.exit("'$abl'" in json.load(open(sys.argv[1]))["hosts"]["spark-a"]["storage"]["locations"])' "$tmp/state/startdgx-demo/state.json"; ok $? "demo delete forgets where the model was"
same "$(cat "$DEMO_CALLS")" ""; ok $? "demo mode never runs ssh, rsync, sudo, tailscale, git, systemd or the terminal launcher"
# recipe draft: a complete user recipe for a repo, written from the Hugging Face API alone (no model, no host unless --host
# checks the id against the host's recipes), with the pinned commit, the license and one drafted variant (ADR 0001).
drafts=$tmp/drafts
draft() { STARTDGX_HF_BASE=$here/demo/hf s recipe draft --out "$drafts" "$@"; }
dd() { local cond=$1; shift; draft "$@" --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ($cond))"; }
tf=TensorFold/Qwen3.8-27B-MLX-4bit
vl=TensorFold/Qwen3.8-VL-27B-MLX-4bit
out=$(draft $tf); ok $? "recipe draft writes a recipe"
present "$drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml"; ok $? "named for the repo, owner dropped, slugified, with -tensorfold appended"
python3 - "$drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml" <<'F'
import sys, tomllib
r = tomllib.load(open(sys.argv[1], "rb"))
a = r["artifacts"]
v = r["variant"]
gib = -(-16074529674 * 10 // 2**30) / 10
ok = (r["runtime"] == "tensorfold" and r["name"] and r["summary"] and len(a) == 1 and len(v) == 1
      and r["hardware"] == [{"gpu": "nvidia-gb10", "ram_class": 128}]
      and a[0] == {"repo": "TensorFold/Qwen3.8-27B-MLX-4bit", "revision": "948c129a6ba97f159b648637d7b54f8f5eb3c61a", "license": "apache-2.0",
                   "files": ["*.safetensors", "*.json", "chat_template.jinja"], "dest": "target", "model": "."}
      and v[0]["source"] == "drafted" and v[0]["peak_ram_gib"] == gib and v[0]["peak_gpu_gib"] == gib and v[0]["ctx"] > 0)
sys.exit(not ok)
F
ok $? "it has the TensorFold artifact block of the curated recipes, the full commit sha, the license, and one drafted variant sized to the weights"
draft $vl --id vision-draft >/dev/null; ok $? "a repo with a vision_config drafts"
python3 - "$drafts/vision-draft.toml" <<'F'
import sys, tomllib
r = tomllib.load(open(sys.argv[1], "rb"))
sys.exit(not (r["input"] == ["text", "image"] and r["server"] == {"args": ["--vision", "--vision-max-images", "50"]}))
F
ok $? "and sets the image input and the server arguments that load the vision tower, as the curated vision recipe does"
python3 - "$drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml" <<'F'
import sys, tomllib
r = tomllib.load(open(sys.argv[1], "rb"))
sys.exit("input" in r or "server" in r)
F
ok $? "a text-only draft sets neither"
dd 'd == {"ok": True, "id": "qwen3.8-draft", "repo": "TensorFold/Qwen3.8-27B-MLX-4bit", "path": "'"$drafts"'/qwen3.8-draft.toml", "revision": "948c129a6ba97f159b648637d7b54f8f5eb3c61a", "license": "apache-2.0", "weights_bytes": 16074529674, "placeholder_gib": 15.0, "source": "drafted", "warnings": [], "judgement": []}' $tf --id qwen3.8-draft
ok $? "--json gives {ok, id, repo, path, revision, license, weights_bytes, placeholder_gib, source, warnings}, and --id names the file"
present "$drafts/qwen3.8-draft.toml"; ok $? "--id picks the id as given"
printf '%s\n' "$out" | grep -q 'apache-2.0' && printf '%s' "$out" | grep -qi 'drafted'; ok $? "the human output shows the license and that it is drafted"
printf '%s' "$out" | grep -qi 'warning'; ok $((!$?)) "a permissive license warns of nothing"
printf '%s' "$out" | grep -q 'recipe add'; ok $? "and says how to add it"
draft $tf >/dev/null 2>&1; ok $? "a draft startdgx wrote and nobody edited is replaced by the next try"
printf '# mine\n' >>"$drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml"
out=$(draft $tf 2>&1); ok $((!$?)) "a draft the person edited is never overwritten"
printf '%s' "$out" | grep -q -- '--id'; ok $? "and the clash asks for --id"
grep -q '^# mine$' "$drafts/qwen3.8-27b-mlx-4bit-tensorfold.toml"; ok $? "and keeps their edit"
: >"$drafts/hand-made.toml"
draft $tf --id hand-made >/dev/null 2>&1; ok $((!$?)) "a file startdgx never wrote is never overwritten"
eng=$FAKE_HOST/home/.local/share/omarchy-local-ai; mkdir -p "$eng"
# A host engine that lists two recipes and, while $HOME/reject exists, rejects every validate.
cat >"$eng/omarchy-local-ai" <<'F'
#!/bin/sh
if [ "$2" = validate ] && [ -e "$HOME/reject" ]; then echo "recipes/x: rejected by the engine"; exit 1; fi
echo '[{"id":"mine","user":true},{"id":"qwen3.8-27b-tensorfold"}]'
F
chmod +x "$eng/omarchy-local-ai"
s add me@dgx >/dev/null 2>&1
out=$(draft $tf --host me@dgx --id mine 2>&1); ok $((!$?)) "an id the host already has fails"
printf '%s' "$out" | grep -q "'mine'.*--id\|--id" && printf '%s' "$out" | grep -q mine; ok $? "naming the id and asking for --id"
s add me@dgx >/dev/null 2>&1; : >"$FAKE_LOG"
draft $tf --host me@dgx --id fresh-one >/dev/null; ok $? "an id the host doesn't have passes the host check"
grep -q 'recipe list --json' "$FAKE_LOG"; ok $? "which asks the host only for its recipe list"
grep -q 'recipe validate' "$FAKE_LOG"; ok $? "and asks the host's engine to validate the draft before it reports success"
touch "$FAKE_HOST/home/reject"
out=$(draft $tf --host me@dgx --id vfail 2>&1); ok $((!$?)) "a draft the host's engine rejects fails"
printf '%s' "$out" | grep -q 'rejected by the engine'; ok $? "with the engine's errors"
none_of "$drafts/vfail.toml"; ok $? "and the file is removed, so a retry is not blocked"
rm -f "$FAKE_HOST/home/reject"
draft $tf --host me@dgx --id vfail >/dev/null; ok $? "the retry drafts it"
out=$(draft --host me@dgx --id panel-order --json -- $tf 2>&1); ok $? "the panel's argument order (options, then -- and the repo) drafts with the host check"
printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not (d['ok'] and d['source'] == 'drafted' and d['id'] == 'panel-order'))"; ok $? "and prints the JSON the panel parses"
dd '"license" in d and d["warnings"] and "other" in d["warnings"][0]' LiquidAI/LFM2.5-24B-A2B-MLX-4bit --id lfm-a
ok $? "a restrictive license warns and still writes the draft"
dd 'd["license"] == "unknown" and d["warnings"] and "unknown" in d["warnings"][0]' someone/Gemma-4-31B-uncensored-MLX-4bit --id gemma-a
ok $? "an unknown license is written as unknown and warns"
lichf=$tmp/hf-lic; cp -r "$here/demo/hf" "$lichf"
for lic in 'x"
name = "evil' 'apache-2.0 plus a very long explanation that is not a license identifier at all, which a card can hold' '🙂-license' 'Apache-2.0'; do
  python3 - "$lichf/api/models/TensorFold/Qwen3.8-27B-MLX-4bit.json" "$lic" <<'F'
import json, sys
d = json.load(open(sys.argv[1])); d["cardData"]["license"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
F
  rm -f "$tmp/lic.toml"; STARTDGX_HF_BASE=$lichf s recipe draft $tf --id lic --out "$tmp/lic" --json >"$tmp/lic.json"
  python3 - "$tmp/lic/lic.toml" "$tmp/lic.json" "$lic" <<'F'
import json, sys, tomllib
t = tomllib.load(open(sys.argv[1], "rb")); j = json.load(open(sys.argv[2]))
good = sys.argv[3] == "Apache-2.0"
sys.exit(not (len(t["artifacts"]) == 1 and t["name"] != "evil" and t["artifacts"][0]["license"] == (sys.argv[3] if good else "unknown")
              and bool(j["warnings"]) == (not good)))
F
  ok $? "license text from a card ($(printf '%s' "$lic" | head -c 12 | tr '\n' ' ')...) is $([ "$lic" = Apache-2.0 ] && echo kept || echo 'written as unknown with a warning'), and the draft is valid TOML"
  rm -rf "$tmp/lic"
done
grep -q '^license = "unknown"' "$drafts/gemma-a.toml"; ok $? "so the engine's non-empty license rule holds"
out=$(draft someone/Qwen3.8-27B-gated-MLX-4bit 2>&1); ok $((!$?)) "a gated repo is refused"
printf '%s' "$out" | grep -qi gated; ok $? "saying it is gated"
for r in someone/Mystery-70B-MLX-4bit someone/Qwen3.8-27B-MLX-8bit someone/Qwen3.8-27B-bf16 someone/Broken-Config-MLX-4bit someone/No-Config-MLX-4bit nobody/Missing-MLX-4bit; do
  draft "$r" --id refused >/dev/null 2>&1; ok $((!$?)) "$r is outside the Find checks and refused"
done
none_of "$drafts/refused.toml"; ok $? "a refusal writes nothing"
for r in notarepo ../x/y a/b/c -x/y; do draft -- "$r" >/dev/null 2>&1; ok $((!$?)) "'$r' is not an OWNER/NAME repo"; done
draft $tf --id Not_An_Id >/dev/null 2>&1; ok $((!$?)) "an --id that can't be a recipe id is refused"
out=$(STARTDGX_HF_BASE=http://127.0.0.1:9 s recipe draft $tf --out "$drafts" 2>&1); ok $((!$?)) "offline fails"
printf '%s' "$out" | grep -q "Can't reach Hugging Face"; ok $? "saying so"
# The engine's own validation, when a checkout of the fork is there: a draft passes, as a user recipe named for its id.
engine_checkout=${STARTDGX_ENGINE:-$HOME/StartFS/github/omarchy-local-ai}
if [ -x "$engine_checkout/omarchy-local-ai" ] && [ -f "$engine_checkout/agent_local.py" ]; then
  for f in qwen3.8-27b-mlx-4bit-tensorfold lfm-a gemma-a; do
    out=$("$engine_checkout/omarchy-local-ai" recipe validate "$drafts/$f.toml" 2>&1); ok $? "the engine's own recipe validate accepts the draft $f${out:+ ($out)}"
  done
  d2=$tmp/drafts-clash; STARTDGX_HF_BASE=$here/demo/hf s recipe draft $tf --id qwen3.8-27b-tensorfold --out "$d2" >/dev/null
  "$engine_checkout/omarchy-local-ai" recipe validate "$d2/qwen3.8-27b-tensorfold.toml" 2>&1 | grep -q 'clashes with the curated'; ok $? "and the engine rejects a draft whose id clashes with a curated recipe, as the contract says"
else
  ok 0 "skipped the engine contract test: no fork checkout (set STARTDGX_ENGINE)"
fi
# Demo mode: the same, on the bundled fixtures, in the demo's state folder, and never the network or a process.
ddraft() { local cond=$1; shift; STARTDGX_HF_BASE=http://127.0.0.1:9 ds recipe draft "$@" --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not ($cond))"; }
ddraft 'd["id"] == "qwen3.8-27b-mlx-4bit-tensorfold" and d["source"] == "drafted" and d["path"].startswith("'"$tmp"'/state/startdgx-demo/")' $tf
ok $? "demo recipe draft serves the bundled fixtures, ignores STARTDGX_HF_BASE, and writes under the demo's state folder"
ds recipe draft $tf >/dev/null 2>&1; ok $? "and an unedited demo draft is replaced by the next try"
ds recipe draft $tf --host $a --id demo-checked >/dev/null; ok $? "a demo draft for a machine passes the demo engine's validation"
printf '# mine\n' >>"$tmp/state/startdgx-demo/drafts/demo-checked.toml"; ds recipe draft $tf --host $a --id demo-checked >/dev/null 2>&1; ok $((!$?)) "and an edited demo draft is not overwritten"
ds recipe draft $tf --host $a --id "$nem" >/dev/null 2>&1; ok $((!$?)) "a demo machine's curated recipe id is a clash"
ds recipe draft someone/Qwen3.8-27B-gated-MLX-4bit >/dev/null 2>&1; ok $((!$?)) "demo refuses a gated repo"
same "$(cat "$DEMO_CALLS")" ""; ok $? "demo draft never runs ssh, rsync, sudo, tailscale, git, systemd or the terminal launcher"
# recipe author: the draft, then (when it needs judgement, or --agent) a terminal running the configured agent command with the
# authoring brief. The agent is a stub here; no real agent or machine runs.
brief=$here/recipe-authoring-brief.txt
present "$brief"; ok $? "the authoring brief is a plain-text file at the plugin root, which the installer copies (it drops docs/ and *.md)"
for rule in 'RECIPE RULES' 'recipe validate' 'recipe add' 'recipe measure' 'recipe confirm' 'numbers come only from' \
  'go-ahead before every download' 'before every measuring run' '--yes' 'stop after three draft-and-measure rounds' 'never counts as fitting'; do
  grep -qi -- "$rule" "$brief"; ok $? "the brief says: $rule"
done
authordir=$tmp/authors
author() { STARTDGX_HF_BASE=$here/demo/hf s recipe author --out "$authordir" "$@"; }
launched_author() { : >"$FAKE_LAUNCH"; author "$@" >/dev/null 2>&1; cat "$FAKE_LAUNCH"; }
: >"$FAKE_LAUNCH"; out=$(author me@dgx $tf --id author-simple 2>&1); ok $? "recipe author drafts"
present "$authordir/author-simple.toml"; ok $? "and writes the draft"
same "$(cat "$FAKE_LAUNCH")" ""; ok $? "a simple draft starts no agent"
printf '%s' "$out" | grep -q -- '--agent'; ok $? "and says how to ask for one"
launched_author me@dgx $tf --id author-asked --agent >"$tmp/l1"; same "$(head -1 "$tmp/l1")" 1; ok $? "--agent opens one terminal command on a simple draft"
tail -n +2 "$tmp/l1" | grep -q '^claude '; ok $? "which runs the default agent command, claude"
tail -n +2 "$tmp/l1" | grep -q 'RECIPE RULES'; ok $? "carrying the authoring brief"
tail -n +2 "$tmp/l1" | grep -q "$authordir/author-asked.toml"; ok $? "and the draft's path"
tail -n +2 "$tmp/l1" | grep -q 'TensorFold/Qwen3.8-27B-MLX-4bit'; ok $? "and the repo"
tail -n +2 "$tmp/l1" | grep -q 'me@dgx'; ok $? "and the host"
mkdir -p "$XDG_CONFIG_HOME/startdgx"; printf '{"agent_command": "my-agent --flag \\"two words\\""}\n' >"$XDG_CONFIG_HOME/startdgx/config.json"
launched_author me@dgx $tf --id author-cfg --agent >"$tmp/l2"; tail -n +2 "$tmp/l2" | grep -q "^my-agent --flag 'two words' "; ok $? "the agent command is configurable in config.json (quoted words stay whole)"
tail -n +2 "$tmp/l2" | grep -q '^claude'; ok $((!$?)) "and replaces the default"
printf '{"agent_command": 5}\n' >"$XDG_CONFIG_HOME/startdgx/config.json"; author me@dgx $tf --id author-bad --agent >/dev/null 2>&1; ok $((!$?)) "an agent_command that isn't a string is refused"
rm -f "$XDG_CONFIG_HOME/startdgx/config.json"
author me@dgx $tf --id author-twice >/dev/null; author me@dgx $tf --id author-twice >/dev/null 2>&1; ok $((!$?)) "recipe author never replaces a draft: an agent may have edited it"
printf '{"agent_command": "no-such-agent-xyz"}\n' >"$XDG_CONFIG_HOME/startdgx/config.json"
author me@dgx $tf --id author-lf --agent --here >/dev/null 2>&1 </dev/null; ok $((!$?)) "an agent that can't start fails"
none_of "$authordir/author-lf.toml"; ok $? "and leaves no draft behind, so a retry is not blocked"
rm -f "$XDG_CONFIG_HOME/startdgx/config.json"
for r in "TensorFold/Qwen3.8-27B-Drafter-MLX-4bit drafter" "TensorFold/Qwen3.8-27B-Yarn-MLX-4bit server"; do
  read -r jrepo jwhy <<<"$r"
  launched_author me@dgx "$jrepo" --id "author-$jwhy" >"$tmp/l3"; same "$(head -1 "$tmp/l3")" 1; ok $? "$jrepo needs judgement: an agent starts by itself"
  tail -n +2 "$tmp/l3" | grep -qi "$jwhy"; ok $? "and the prompt says why ($jwhy)"
done
author me@dgx $tf --id author-json --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not (d['ok'] and d['judgement'] == [] and d['agent'] is False))"; ok $? "--json gives the draft, its judgement reasons and whether an agent would start"
author me@dgx $vl --id author-j2 --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(not (d['judgement'] == [] and d['agent'] is False))"; ok $? "a vision draft needs no judgement: no agent"
: >"$FAKE_LAUNCH"; author me@dgx someone/Qwen3.8-27B-gated-MLX-4bit --agent >/dev/null 2>&1; ok $((!$?)) "a refused repo fails"
same "$(cat "$FAKE_LAUNCH")" ""; ok $? "and starts no agent"
author me@dgx $tf --id author-here --agent --here >/dev/null 2>&1 </dev/null; same "$(cat "$FAKE_LAUNCH")" ""; ok $? "--here runs the agent in this terminal, not a new one"
mkdir -p "$tmp/agentbin"
cat >"$tmp/agentbin/stub-agent" <<'F'
#!/bin/sh
printf '%s\n' "$#" >"$FAKE_AGENT_OUT"
F
chmod +x "$tmp/agentbin/stub-agent"
printf '{"agent_command": "stub-agent"}\n' >"$XDG_CONFIG_HOME/startdgx/config.json"
PATH=$tmp/agentbin:$PATH FAKE_AGENT_OUT=$tmp/agent.out author me@dgx $tf --id author-here2 --agent --here >/dev/null 2>&1 </dev/null
same "$(cat "$tmp/agent.out" 2>/dev/null)" 1; ok $? "the agent gets the brief and context as one argument"
rm -f "$XDG_CONFIG_HOME/startdgx/config.json"
# launch author: the panel's way in, so the draft's errors and the agent show in the terminal.
same "$(launched author me@dgx $tf)" "$(printf '1\n%s\n' "$cli recipe author me@dgx --agent --here -- $tf")"; ok $? "launch author opens a terminal running recipe author --agent --here"
for refused in "author me@dgx" "author me@dgx notarepo" "author me@dgx ../x/y" "author me@dgx a/b/c" "install me@dgx $tf"; do
  read -ra words <<<"$refused"; : >"$FAKE_LAUNCH"; s launch "${words[@]}" >/dev/null 2>&1; ok $((!$?)) "launch refuses: $refused"
  same "$(cat "$FAKE_LAUNCH")" ""; ok $? "and opens nothing"
done
# Demo mode: says what it would run, runs nothing.
out=$(ds recipe author $a $tf --id author-demo --agent); printf '%s' "$out" | grep -q "Demo: would run 'claude "; ok $? "demo author says what it would run in a terminal"
out=$(ds launch author $a $tf); printf '%s' "$out" | grep -q "Demo: would run 'recipe author"; ok $? "demo launch author says what it would run"
same "$(cat "$DEMO_CALLS")" ""; ok $? "demo author never runs ssh, rsync, sudo, tailscale, git, systemd or the terminal launcher"
echo "1..$n"; exit $bad
