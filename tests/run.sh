#!/usr/bin/env bash
# Test suite for ./overclock. Every case runs in a throwaway HOME.
# Needs network (clones from GitHub), git, jq, python3, node, bun.
set -uo pipefail   # no -e: a failing case is recorded, not fatal

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OC="$REPO/overclock"
REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"
LOCK="$REPO/skills.lock.json"

PASS=0 FAIL=0 FAILED=()
CASE=""

# ---------- hard guard ----------
guard_base() { # refuse anything that could be the real Synaps dir
  local b; b="$(realpath -m "$1")"
  case "$b" in
    /home/haseeb/.synaps-cli|/home/haseeb/.synaps-cli/*) echo "GUARD: refusing real base dir $b" >&2; exit 99 ;;
  esac
  case "$b/" in
    "$(realpath -m "$REAL_HOME")"/*) echo "GUARD: refusing base dir under real HOME: $b" >&2; exit 99 ;;
  esac
}

SCRATCH="$(mktemp -d)"   # every throwaway dir lives here; removed on exit
trap 'rm -rf "$SCRATCH"' EXIT
tmpd() { mktemp -d "$SCRATCH/t.XXXXXX"; }

new_home() { # sets HOME + SYNAPS_BASE_DIR for this case
  local h; h="$(tmpd)"
  export HOME="$h" SYNAPS_BASE_DIR="$h/.synaps-cli"
  unset SYNAPS_PROFILE
  guard_base "$SYNAPS_BASE_DIR"
  B="$SYNAPS_BASE_DIR"
}
# guard the environment we were started with, too
guard_base "${SYNAPS_BASE_DIR:-/nonexistent-overclock-test}"

oc() { guard_base "$SYNAPS_BASE_DIR"; "$OC" "$@"; }

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$CASE: $*"); printf '  FAIL %s\n' "$*"; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }
start() { CASE="$1"; printf '\n## %s\n' "$1"; }

tree_hash() { # content + layout + symlink targets + modes
  [ -e "$1" ] || { echo absent; return; }
  ( cd "$1" && { find . -printf '%y %m %p %l\n' | sort; find . -type f -print0 | sort -z | xargs -0 -r sha256sum; } ) | sha256sum | cut -d' ' -f1
}
lock() { jq -r "$1" "$LOCK"; }

# plugins.json shape per agent-engine skills/state.rs (PluginsState / InstalledPlugin / Marketplace)
plugins_json_shape() {
  jq -e '
    (.marketplaces | type == "array") and (.installed | type == "array") and (.trusted_hosts | type == "array")
    and all(.marketplaces[]; (.name | type == "string") and (.url | type == "string")
          and (.cached_plugins | type == "array")
          and all(.cached_plugins[]; (.name | type == "string") and (.source | type == "string")))
    and all(.installed[]; (.name | type == "string") and (.source_url | type == "string")
          and (.installed_commit | test("^[0-9a-f]{40}$")) and (.installed_at | type == "string")
          and (.setup_status.state == "not_required"))
  ' "$1"
}
mcp_json_shape() {
  jq -e '.mcpServers | type == "object" and all(.[]; (.command | type == "string") and ((.args // []) | type == "array") and ((.env // {}) | type == "object"))' "$1"
}

# ======================================================================
start "fresh install"
new_home
out="$(oc install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
for p in agent-comms chronos synaps-dash; do
  check "plugin $p cloned" test -f "$B/plugins/$p/.synaps-plugin/plugin.json"
  check "plugin $p commit == plugins.json" test "$(git -C "$B/plugins/$p" rev-parse HEAD)" = "$(jq -r --arg n "$p" '.installed[] | select(.name == $n) | .installed_commit' "$B/plugins.json")"
done
check "11 agents" test "$(ls "$B/agents" | wc -l)" = 11
check "agent copied verbatim" cmp "$REPO/agents/spike.md" "$B/agents/spike.md"
check "plugins.json valid + schema-shaped" plugins_json_shape "$B/plugins.json"
check "plugins.json marketplace linked" jq -e '.marketplaces[0].name == "synaps-overclocked" and all(.installed[]; .marketplace == "synaps-overclocked")' "$B/plugins.json"
check "plugins.json trusted host" jq -e '.trusted_hosts == ["github.com/HaseebKhalid1507"]' "$B/plugins.json"
check "mcp.json valid + shaped" mcp_json_shape "$B/mcp.json"
check "mcp.json paths templated" jq -e --arg b "$B" '.mcpServers["context-mode"] | .args[0] == "\($b)/overclocked/context-mode/server.bundle.mjs" and .env.CONTEXT_MODE_DIR == "\($b)/context-mode" and .env.CLAUDE_CONFIG_DIR == "\($b)/context-mode-shim"' "$B/mcp.json"
for s in gauntlet-loop last30days; do
  check "skill $s SKILL.md" test -f "$B/skills/$s/SKILL.md"
  check "skill $s commit == lock" test "$(head -n1 "$B/skills/$s/.SOURCE_COMMIT")" = "$(lock ".skills[\"$s\"].commit")"
  check "skill $s not a git checkout" test ! -e "$B/skills/$s/.git"
done
check "gauntlet SOURCE note" grep -q "CC BY 4.0, technique by Matt Shumer" "$B/skills/gauntlet-loop/SOURCE"
check "context-mode commit == lock" test "$(git -C "$B/overclocked/context-mode" rev-parse HEAD)" = "$(lock '.mcp["context-mode"].commit')"
check "context-mode bundle present" test -f "$B/overclocked/context-mode/server.bundle.mjs"
check "no scratch dir left" bash -c "! ls -d '$B'/overclocked/.tmp.* 2>/dev/null"
check "no node_modules installed" test ! -e "$B/overclocked/context-mode/node_modules"
FRESH_B="$B" FRESH_HOME="$HOME"

# ======================================================================
start "rerun is a no-op"
before="$(tree_hash "$B")"
out="$(oc install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "tree unchanged" test "$before" = "$(tree_hash "$B")"
check "no backups written" bash -c "! find '$B' -name '*bak-overclock*' | grep -q ."

# ======================================================================
start "status output"
out="$(oc status 2>&1)"
for l in "agent-comms: installed @" "chronos: installed @" "synaps-dash: installed @" "spike: installed" \
         "gauntlet-loop: installed @ 9b1975a pinned 9b1975a [ok]" "last30days: installed @ 0188da7 pinned 0188da7 [ok]" \
         "context-mode: installed @ 928bdf1 pinned 928bdf1 [ok]" "mcp.json context-mode: installed"; do
  check "status: $l" grep -qF "$l" <<<"$out"
done
check "status writes nothing" test "$before" = "$(tree_hash "$B")"
new_home
out="$(oc status 2>&1)"
check "status on empty base: missing" grep -qF "chronos: missing" <<<"$out"
check "status on empty base writes nothing" test ! -e "$B"

# ======================================================================
start "--dry-run writes nothing"
new_home
out="$(oc install --dry-run 2>&1)"; rc=$?
check "exit 0 on empty base" test "$rc" = 0
check "base dir not created" test ! -e "$B"
check "prints clone actions" grep -q "\[dry-run\] git clone --depth=1 https://github.com/HaseebKhalid1507/synaps-chronos.git" <<<"$out"
mkdir -p "$B/agents" "$B/plugins"
echo "mine" >"$B/agents/spike.md"
echo '{"mcpServers":{"other":{"command":"x"}}}' >"$B/mcp.json"
ln -s /nonexistent "$B/plugins/chronos"
before="$(tree_hash "$B")"
out="$(oc install --dry-run --force 2>&1)"; rc=$?
check "exit 0 with --force" test "$rc" = 0
check "tree unchanged (dry-run --force)" test "$before" = "$(tree_hash "$B")"
check "reports move-aside" grep -q "\[dry-run\] mv $B/agents/spike.md" <<<"$out"
before="$(tree_hash "$FRESH_B")"
out="$(SYNAPS_BASE_DIR="$FRESH_B" HOME="$FRESH_HOME" "$OC" update --dry-run 2>&1)"
check "update --dry-run writes nothing" test "$before" = "$(tree_hash "$FRESH_B")"

# ======================================================================
start "pre-existing symlinked plugin is skipped"
new_home
target="$(tmpd)"; mkdir -p "$target/.synaps-plugin"; echo '{"name":"chronos"}' >"$target/.synaps-plugin/plugin.json"
mkdir -p "$B/plugins" "$B/agents"
ln -s "$target" "$B/plugins/chronos"
ln -s "$target/.synaps-plugin/plugin.json" "$B/agents/zero.md"
out="$(oc install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "symlink untouched" test "$(readlink "$B/plugins/chronos")" = "$target"
check "symlinked agent untouched" test "$(readlink "$B/agents/zero.md")" = "$target/.synaps-plugin/plugin.json"
check "reported as skipped" grep -q "chronos: skipped, .* (symlink → $target)" <<<"$out"
check "no plugins.json entry for chronos" jq -e 'all(.installed[]; .name != "chronos")' "$B/plugins.json"
check "other plugins installed" jq -e '[.installed[].name] == ["agent-comms","synaps-dash"]' "$B/plugins.json"
check "status says foreign" grep -q "chronos: skipped (foreign) symlink" <<<"$(oc status)"
out="$(oc install --force 2>&1)"; rc=$?
check "--force exit 0" test "$rc" = 0
bk="$(ls -d "$B"/plugins/chronos.bak-overclock-*.bak 2>/dev/null | head -n1)"
check "--force moved symlink aside (inert .bak suffix)" test "$(readlink "$bk")" = "$target"
check "--force cloned chronos" test -d "$B/plugins/chronos/.git"
check "--force recorded chronos" jq -e 'any(.installed[]; .name == "chronos")' "$B/plugins.json"
check "--force backed up plugins.json" bash -c "ls '$B'/plugins.json.bak-overclock-* >/dev/null"
check "--force moved agent aside" test -L "$(ls -d "$B"/agents/zero.md.bak-overclock-* | head -n1)"
check "target dir intact" test -f "$target/.synaps-plugin/plugin.json"

# ======================================================================
start "pre-existing mcp.json with another server is preserved"
new_home
mkdir -p "$B"
cat >"$B/mcp.json" <<'EOF'
{"mcpServers":{"other":{"command":"python3","args":["srv.py"],"env":{"K":"V"}}},"keepMe":{"x":1}}
EOF
orig="$(cat "$B/mcp.json")"
out="$(oc install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "other server preserved" jq -e '.mcpServers.other == {"command":"python3","args":["srv.py"],"env":{"K":"V"}}' "$B/mcp.json"
check "unknown top-level key preserved" jq -e '.keepMe == {"x":1}' "$B/mcp.json"
check "context-mode added" jq -e '.mcpServers["context-mode"].command == "node"' "$B/mcp.json"
bk="$(ls "$B"/mcp.json.bak-overclock-* 2>/dev/null | head -n1)"
check "timestamped backup equals original" test "$(cat "$bk")" = "$orig"
# a foreign context-mode entry is left alone without --force
new_home; mkdir -p "$B"
echo '{"mcpServers":{"context-mode":{"command":"node","args":["/elsewhere/server.bundle.mjs"]}}}' >"$B/mcp.json"
mkdir -p "$B/plugins" "$B/agents" "$B/skills"
for p in agent-comms chronos synaps-dash; do ln -s /nonexistent "$B/plugins/$p"; done
out="$(oc install 2>&1)"
check "foreign context-mode entry kept" jq -e '.mcpServers["context-mode"].args == ["/elsewhere/server.bundle.mjs"]' "$B/mcp.json"
check "foreign entry reported" grep -q "different 'context-mode' server is already configured" <<<"$out"

# ======================================================================
start "invalid plugins.json aborts"
new_home
mkdir -p "$B"
printf '{"installed": [ broken' >"$B/plugins.json"
before="$(tree_hash "$B")"
out="$(oc install 2>&1)"; rc=$?
check "nonzero exit" test "$rc" != 0
check "error mentions plugins.json" grep -q "plugins.json is not valid" <<<"$out"
check "nothing written" test "$before" = "$(tree_hash "$B")"
printf '{"installed": {}}' >"$B/plugins.json"
before="$(tree_hash "$B")"
out="$(oc install 2>&1)"; rc=$?
check "wrong-shape plugins.json aborts" test "$rc" != 0
check "nothing written (wrong shape)" test "$before" = "$(tree_hash "$B")"
rm "$B/plugins.json"; printf 'nope' >"$B/mcp.json"
out="$(oc install 2>&1)"; rc=$?
check "invalid mcp.json aborts" test "$rc" != 0
check "no plugins cloned" test ! -e "$B/plugins"

# ======================================================================
start "update bumps a pinned skill only when the lock changes"
new_home
old="f2c462ee0727035719e4b5c8d69195f8ba4f1c4e"   # gauntlet-loop parent of the pinned commit
new="$(lock '.skills["gauntlet-loop"].commit')"
fork="$(tmpd)"
cp -r "$REPO/." "$fork/"; rm -rf "$fork/.git"
jq --arg c "$old" '.skills["gauntlet-loop"].commit = $c' "$LOCK" >"$fork/skills.lock.json"
mkdir -p "$B/plugins"; for p in agent-comms chronos synaps-dash; do ln -s /nonexistent "$B/plugins/$p"; done
"$fork/overclock" install >/dev/null 2>&1
check "old pin installed" test "$(head -n1 "$B/skills/gauntlet-loop/.SOURCE_COMMIT")" = "$old"
check "status flags update" grep -q "gauntlet-loop: installed @ f2c462e pinned 9b1975a \[update available\]" <<<"$(oc status)"
out="$(oc update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "bumped to new pin" test "$(head -n1 "$B/skills/gauntlet-loop/.SOURCE_COMMIT")" = "$new"
check "old copy moved aside" bash -c "ls -d '$B'/skills/gauntlet-loop.bak-overclock-* >/dev/null"
check "last30days untouched" grep -q "last30days: at pinned" <<<"$out"
before="$(tree_hash "$B/skills")"
oc update >/dev/null 2>&1
check "second update leaves skills alone" test "$before" = "$(tree_hash "$B/skills")"

# ======================================================================
start "refuses root"
new_home
fakebin="$(tmpd)"; printf '#!/bin/sh\necho 0\n' >"$fakebin/id"; chmod +x "$fakebin/id"
out="$(PATH="$fakebin:$PATH" oc install 2>&1)"; rc=$?
check "uid 0 is refused" test "$rc" != 0
check "root message" grep -q "refusing to run as root" <<<"$out"
check "nothing written as root" test ! -e "$B"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
