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
s engine | grep -Eq '^https://github.com/bmaltais/omarchy-local-ai v[0-9]+\.[0-9]+\.[0-9]+-dgx\.[0-9]+$'; ok $? "engine prints the pinned repo and tag"
s engine --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["repo"].startswith("https://") and "-dgx." in d["tag"]))'; ok $? "engine --json gives repo and tag"

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
