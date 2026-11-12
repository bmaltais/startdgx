#!/usr/bin/env bash
# Tests startdgx against a fake ssh that records its arguments.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME=$tmp/config PATH=$tmp/bin:$PATH
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'F'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >>"$FAKE_LOG"
case "${*: -1}" in *"profile"*) echo '{"ram_class":128,"gpus":[]}';; *"status --json"*) echo '{"models":{}}';; *"fail"*) echo "Error: boom" >&2; exit 1;; esac
F
chmod +x "$tmp/bin/ssh"; export FAKE_LOG=$tmp/log
n=0; bad=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok - $2"; else bad=$((bad+1)); echo "not ok - $2"; fi; }
s() { "$here/bin/startdgx" "$@"; }

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
echo "1..$n"; exit $bad
