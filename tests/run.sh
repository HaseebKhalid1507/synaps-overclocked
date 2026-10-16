#!/usr/bin/env bash
# Test suite for ./overclock. Every case runs in a throwaway HOME.
# Needs network (clones from GitHub), git, jq, python3, node, bun. Never runs a real cargo.
set -uo pipefail   # no -e: a failing case is recorded, not fatal

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OC="$REPO/overclock"
REAL_HOME="$( (getent passwd "$(id -un)" 2>/dev/null || true) | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"
LOCK="$REPO/skills.lock.json"

PASS=0 FAIL=0 FAILED=()
CASE=""

# ---------- hard guard ----------
canon() { realpath -m "$1" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
guard_base() { # refuse the real Synaps dir or anything else under the real HOME
  local b; b="$(canon "$1")"
  case "$b/" in
    "$(canon "$REAL_HOME")"/*) echo "GUARD: refusing base dir under real HOME: $b" >&2; exit 99 ;;
  esac
}

SCRATCH="$(mktemp -d)"   # every throwaway dir lives here; removed on exit
trap 'rm -rf "$SCRATCH"' EXIT
tmpd() { mktemp -d "$SCRATCH/t.XXXXXX"; }

# The suite never runs a real cargo: PATH is a symlink farm of the current PATH minus
# `cargo`, so crush is skipped unless a case puts a stub cargo in front.
NOCARGO="$SCRATCH/nocargo-bin"; mkdir -p "$NOCARGO"
IFS=: read -r -a _pdirs <<<"$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _b="${_f##*/}"
    if [ "$_b" != cargo ] && [ -x "$_f" ] && [ ! -d "$_f" ] && [ ! -e "$NOCARGO/$_b" ]; then ln -s "$_f" "$NOCARGO/$_b"; fi
  done
done
export PATH="$NOCARGO"
STUBS="$SCRATCH/stub-cargo"; mkdir -p "$STUBS"
CARGO_STUB_LOG="$SCRATCH/cargo-calls.log"; export CARGO_STUB_LOG
cat >"$STUBS/cargo" <<'EOF'
#!/bin/sh
# stub cargo: records the call, fakes `cargo build` (CARGO_STUB_FAIL=1 makes it fail)
echo "$PWD|$*" >>"$CARGO_STUB_LOG"
if [ -n "${CARGO_STUB_FAIL:-}" ]; then echo "error[E0000]: stub build failure" >&2; exit 101; fi
# like a real cargo with a user-level build.target-dir: without an explicit --target-dir the
# binary lands in a shared dir, not ./target
case " $* " in *" --target-dir target "*) out=target ;; *) out="$CARGO_STUB_LOG.shared-target" ;; esac
mkdir -p "$out/release" && printf '#!/bin/sh\necho crush\n' >"$out/release/crush" && chmod +x "$out/release/crush"
EOF
chmod +x "$STUBS/cargo"
with_cargo() { PATH="$STUBS:$NOCARGO" "$@"; }
ALL_PLUGINS="$(jq -r '.plugins[].name' "$REPO/.synaps-plugin/marketplace.json" "$REPO/subdir-plugins.json")"

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
short() { printf '%s' "$1" | cut -c1-7; }

# plugins.json shape per agent-engine skills/state.rs (PluginsState / InstalledPlugin / Marketplace)
plugins_json_shape() {
  jq -e '
    (.marketplaces | type == "array") and (.installed | type == "array") and (.trusted_hosts | type == "array")
    and all(.marketplaces[]; (.name | type == "string") and (.url | type == "string")
          and (.cached_plugins | type == "array")
          and all(.cached_plugins[]; (.name | type == "string") and (.source | type == "string")))
    and all(.installed[]; (.name | type == "string") and (.source_url | type == "string")
          and (.installed_commit | test("^[0-9a-f]{40}$")) and (.installed_at | type == "string")
          and (.setup_status.state == "not_required" or .setup_status.state == "succeeded")
          and (.source_subdir == null or (.source_subdir | type == "string")))
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
check "all repo agents installed" test "$(ls "$B/agents" | wc -l)" = "$(ls "$REPO/agents" | wc -l)"
check "agent copied verbatim" cmp "$REPO/agents/spike.md" "$B/agents/spike.md"
check "plugins.json valid + schema-shaped" plugins_json_shape "$B/plugins.json"
check "plugins.json marketplace linked" jq -e '.marketplaces[0].name == "synaps-overclocked" and all(.installed[]; .marketplace == "synaps-overclocked")' "$B/plugins.json"
check "plugins.json trusted hosts" jq -e '.trusted_hosts == ["github.com/HaseebKhalid1507","github.com/maha-media"]' "$B/plugins.json"
check "tmux-tools copied from its subdir" test -f "$B/plugins/tmux-tools/skills/tmux/SKILL.md"
check "tmux-tools is not a git checkout" test ! -e "$B/plugins/tmux-tools/.git"
check "tmux-tools recorded like /plugins" jq -e '.installed[] | select(.name == "tmux-tools") | .source_url == "https://github.com/maha-media/synaps-skills.git" and .source_subdir == "tmux-tools-plugin" and (.installed_commit | test("^[0-9a-f]{40}$"))' "$B/plugins.json"
check "crush skipped without cargo" grep -q "crush: skipped, needs 'cargo'" <<<"$out"
check "crush not installed" test ! -e "$B/plugins/crush"
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
check "no backups written" test ! -e "$B/overclocked/backups"

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
out="$(oc install --dry-run --replace-foreign 2>&1)"; rc=$?
check "exit 0 with --replace-foreign" test "$rc" = 0
check "tree unchanged (dry-run --replace-foreign)" test "$before" = "$(tree_hash "$B")"
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
check "other plugins installed" jq -e '[.installed[].name] | index("agent-comms") != null and index("synaps-dash") != null and index("tmux-tools") != null' "$B/plugins.json"
check "status says foreign" grep -q "chronos: skipped (foreign) symlink" <<<"$(oc status)"
out="$(oc install --reclone 2>&1)"; rc=$?
check "--reclone exit 0" test "$rc" = 0
check "--reclone leaves the plugin symlink alone" test "$(readlink "$B/plugins/chronos")" = "$target"
check "--reclone leaves the agent symlink alone" test "$(readlink "$B/agents/zero.md")" = "$target/.synaps-plugin/plugin.json"
# swap our mcp entry for a user-owned one, then replace foreign items explicitly
jq '.mcpServers["context-mode"] = {"command":"node","args":["/elsewhere/server.bundle.mjs"]}' "$B/mcp.json" >"$B/mcp.json.new" && mv "$B/mcp.json.new" "$B/mcp.json"
out="$(oc install --replace-foreign 2>&1)"; rc=$?
check "--replace-foreign exit 0" test "$rc" = 0
bk="$(ls -d "$B"/overclocked/backups/*/plugins/chronos 2>/dev/null | head -n1)"
check "--replace-foreign moved symlink into backups/" test "$(readlink "$bk")" = "$target"
check "nothing but plugins left in plugins/" test -z "$(ls "$B/plugins" | grep -vxF "$ALL_PLUGINS")"
check "--replace-foreign cloned chronos" test -d "$B/plugins/chronos/.git"
check "--replace-foreign recorded chronos" jq -e 'any(.installed[]; .name == "chronos")' "$B/plugins.json"
check "--replace-foreign backed up plugins.json" bash -c "ls '$B'/overclocked/backups/*/plugins.json >/dev/null"
check "--replace-foreign moved agent aside" test -L "$(ls -d "$B"/overclocked/backups/*/agents/zero.md | head -n1)"
check "displacements recorded" jq -e --arg p "$B/plugins/chronos" --arg t "$target" 'any(.displaced[]; .path == $p and .link == $t) and any(.displaced[]; .entry.args == ["/elsewhere/server.bundle.mjs"])' "$B/overclocked/state.json"
check "our mcp entry now active" jq -e --arg b "$B" '.mcpServers["context-mode"].args[0] == "\($b)/overclocked/context-mode/server.bundle.mjs"' "$B/mcp.json"
check "no backups in scanned trees" bash -c "! ls '$B/plugins' '$B/skills' '$B/agents' | grep -q bak"
check "target dir intact" test -f "$target/.synaps-plugin/plugin.json"
out="$(oc uninstall 2>&1)"; rc=$?
check "uninstall exit 0" test "$rc" = 0
check "uninstall restores the plugin symlink, same target" test "$(readlink "$B/plugins/chronos")" = "$target"
check "uninstall restores the agent symlink" test "$(readlink "$B/agents/zero.md")" = "$target/.synaps-plugin/plugin.json"
check "only the restored symlink left in plugins/" test "$(ls -A "$B/plugins" | tr '\n' ' ')" = "chronos "
check "uninstall restores the user's mcp entry" jq -e '.mcpServers["context-mode"].args == ["/elsewhere/server.bundle.mjs"]' "$B/mcp.json"

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
bk="$(ls "$B"/overclocked/backups/*/mcp.json 2>/dev/null | head -n1)"
check "timestamped backup equals original" test "$(cat "$bk")" = "$orig"
# a foreign context-mode entry is left alone without --replace-foreign
new_home; mkdir -p "$B"
echo '{"mcpServers":{"context-mode":{"command":"node","args":["/elsewhere/server.bundle.mjs"]}}}' >"$B/mcp.json"
mkdir -p "$B/plugins" "$B/agents" "$B/skills"
for p in $ALL_PLUGINS; do ln -s /nonexistent "$B/plugins/$p"; done
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
mkdir -p "$B/plugins"; for p in $ALL_PLUGINS; do ln -s /nonexistent "$B/plugins/$p"; done
"$fork/overclock" install >/dev/null 2>&1
check "old pin installed" test "$(head -n1 "$B/skills/gauntlet-loop/.SOURCE_COMMIT")" = "$old"
check "status flags update" grep -q "gauntlet-loop: installed @ f2c462e pinned 9b1975a \[update available\]" <<<"$(oc status)"
out="$(oc update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "bumped to new pin" test "$(head -n1 "$B/skills/gauntlet-loop/.SOURCE_COMMIT")" = "$new"
check "old copy moved to backups/" test "$(head -n1 "$(ls -d "$B"/overclocked/backups/*/skills/gauntlet-loop | head -n1)/.SOURCE_COMMIT")" = "$old"
check "skills/ holds only live skills" test "$(ls "$B/skills" | tr '\n' ' ')" = "gauntlet-loop last30days "
check "last30days untouched" grep -q "last30days: at pinned" <<<"$out"
before="$(tree_hash "$B/skills")"
oc update >/dev/null 2>&1
check "second update leaves skills alone" test "$before" = "$(tree_hash "$B/skills")"

# ======================================================================
# offline fixtures: local file:// upstreams for the plugins (plus a multi-plugin
# repo for the subdir plugin and a stub-built crush), a fork of this
# repo whose marketplace points at them, and skills/context-mode pre-made as
# foreign symlinks so these cases never touch the network.
# ======================================================================
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
UP="$(tmpd)"
mk_upstream() { # <name> <extension.command>
  local w="$UP/$1-work"
  git init -q -b main "$w"; mkdir -p "$w/.synaps-plugin"
  printf '{"name":"%s","extension":{"runtime":"process","command":"%s","args":["main.py"]}}\n' "$1" "$2" >"$w/.synaps-plugin/plugin.json"
  echo v1 >"$w/main.py"; git -C "$w" add -A; git -C "$w" commit -qm v1
  git clone -q --bare "$w" "$UP/$1.git"
  git -C "$w" remote add origin "$UP/$1.git"
}
push_commit() { echo "$2" >>"$UP/$1-work/main.py"; git -C "$UP/$1-work" commit -qam "$2"; git -C "$UP/$1-work" push -q origin main; }
force_rewrite() { # new root commit force-pushed over main
  local w="$UP/$1-work"
  git -C "$w" checkout -q --orphan rewritten; echo rewritten >"$w/main.py"; git -C "$w" add -A; git -C "$w" commit -qm rewritten
  git -C "$w" push -q -f origin rewritten:main
}
up_head() { git -C "$UP/$1.git" rev-parse main; }
mk_upstream agent-comms ./bin/agent     # path command: relative to plugin dir, not a PATH lookup
mk_upstream chronos python3
mk_upstream synaps-dash bun
mk_upstream heartbeat python3
printf 'config\n' >"$UP/heartbeat-work/.gitignore"   # user settings stay untracked (see its README)
git -C "$UP/heartbeat-work" add -A; git -C "$UP/heartbeat-work" commit -qm gitignore; git -C "$UP/heartbeat-work" push -q origin main
mk_upstream d20 python3
mk_upstream crush target/release/crush   # Rust plugin: built by `cargo build --release --locked`
printf 'target/\n' >"$UP/crush-work/.gitignore"; echo '[package]' >"$UP/crush-work/Cargo.toml"; echo '# lock' >"$UP/crush-work/Cargo.lock"
git -C "$UP/crush-work" add -A; git -C "$UP/crush-work" commit -qm cargo; git -C "$UP/crush-work" push -q origin main
# a multi-plugin repo (like maha-media/synaps-skills); overclock takes one subdir of it
mk_subdir_repo() {
  local w="$UP/skills-repo-work"
  git init -q -b main "$w"
  mkdir -p "$w/tmux-tools-plugin/.synaps-plugin" "$w/tmux-tools-plugin/skills/tmux" "$w/tmux-tools-plugin/scripts" "$w/other-plugin"
  echo '{"name":"tmux-tools","version":"0.2.1"}' >"$w/tmux-tools-plugin/.synaps-plugin/plugin.json"
  printf -- '---\nname: tmux\ndescription: d\n---\nv1\n' >"$w/tmux-tools-plugin/skills/tmux/SKILL.md"
  printf '#!/bin/sh\necho pane\n' >"$w/tmux-tools-plugin/scripts/pane.sh"; chmod +x "$w/tmux-tools-plugin/scripts/pane.sh"
  echo other >"$w/other-plugin/README"; echo root >"$w/README.md"
  git -C "$w" add -A; git -C "$w" commit -qm v1
  git clone -q --bare "$w" "$UP/skills-repo.git"
  git -C "$w" remote add origin "$UP/skills-repo.git"
}
mk_subdir_repo
push_sub() { # <file under the repo> <line>
  echo "$2" >>"$UP/skills-repo-work/$1"; git -C "$UP/skills-repo-work" add -A
  git -C "$UP/skills-repo-work" commit -qm "$2"; git -C "$UP/skills-repo-work" push -q origin main
}
LIVE_OFFLINE="agent-comms chronos d20 heartbeat synaps-dash tmux-tools "   # crush needs cargo; PATH has none
FORK="$(tmpd)"
cp -R "$REPO/." "$FORK/"; rm -rf "$FORK/.git"
jq --arg u "$UP" '.plugins |= map(.source = "file://\($u)/\(.name).git")' "$REPO/.synaps-plugin/marketplace.json" >"$FORK/.synaps-plugin/marketplace.json"
jq --arg u "$UP" '.plugins |= map(.source = "file://\($u)/skills-repo.git")' "$REPO/subdir-plugins.json" >"$FORK/subdir-plugins.json"
ocf() { guard_base "$SYNAPS_BASE_DIR"; "$FORK/overclock" "$@"; }
offline_home() {
  new_home
  mkdir -p "$B/skills" "$B/overclocked"
  ln -s /nonexistent "$B/skills/gauntlet-loop"; ln -s /nonexistent "$B/skills/last30days"; ln -s /nonexistent "$B/overclocked/context-mode"
}
pj_commit() { jq -r --arg n "$2" '.installed[] | select(.name == $n) | .installed_commit' "$1"; }

# ======================================================================
start "plugin update fast-forwards (file:// upstream)"
offline_home
out="$(ocf install 2>&1)"; rc=$?
check "offline install exit 0" test "$rc" = 0
check "path command not treated as missing runtime" test -d "$B/plugins/agent-comms/.git"
check "path command warning shown" grep -q "agent-comms: ./bin/agent not present in the plugin dir" <<<"$out"
c1="$(git -C "$B/plugins/chronos" rev-parse HEAD)"
at1="$(jq -r '.installed[] | select(.name == "chronos") | .installed_at' "$B/plugins.json")"
push_commit chronos v2; push_commit chronos v3
out="$(ocf update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "chronos fast-forwarded" test "$(git -C "$B/plugins/chronos" rev-parse HEAD)" = "$(up_head chronos)"
check "plugins.json installed_commit bumped" test "$(pj_commit "$B/plugins.json" chronos)" = "$(up_head chronos)"
check "installed_at kept (TUI update semantics)" test "$(jq -r '.installed[] | select(.name == "chronos") | .installed_at' "$B/plugins.json")" = "$at1"
check "state.json commit bumped" jq -e --arg c "$(up_head chronos)" '.items["plugin:chronos"].commit == $c' "$B/overclocked/state.json"
check "other plugins untouched" grep -q "agent-comms: up to date" <<<"$out"
check "plugins.json still schema-shaped" plugins_json_shape "$B/plugins.json"

# ======================================================================
start "force-pushed upstream: update fails loudly, update --reclone recovers"
force_rewrite chronos
before="$(git -C "$B/plugins/chronos" rev-parse HEAD)"
out="$(ocf update 2>&1)"; rc=$?
check "update still exits 0" test "$rc" = 0
check "git error shown, not swallowed" grep -q "unrelated histories" <<<"$out"
check "hint at --reclone" grep -q "update --reclone" <<<"$out"
check "plugin left as it was" test "$(git -C "$B/plugins/chronos" rev-parse HEAD)" = "$before"
out="$(ocf update --reclone 2>&1)"; rc=$?
check "update --reclone exit 0" test "$rc" = 0
check "recloned onto rewritten upstream" test "$(git -C "$B/plugins/chronos" rev-parse HEAD)" = "$(up_head chronos)"
check "plugins.json commit follows" test "$(pj_commit "$B/plugins.json" chronos)" = "$(up_head chronos)"
check "old copy in backups/" test "$(git -C "$(ls -d "$B"/overclocked/backups/*/plugins/chronos | head -n1)" rev-parse HEAD)" = "$before"
check "plugins/ holds only live plugins" test "$(ls -A "$B/plugins" | tr '\n' ' ')" = "$LIVE_OFFLINE"
n_bk="$(ls -d "$B"/overclocked/backups/*/plugins/chronos* | wc -l)"
out="$(ocf install --force 2>&1)"; rc=$?
check "--force prints a deprecation notice" grep -q "force is deprecated; it now means --reclone" <<<"$out"
check "--force (= --reclone) reclones owned plugins" test "$(ls -d "$B"/overclocked/backups/*/plugins/chronos* | wc -l)" -gt "$n_bk"
check "--force leaves only live plugins" test "$(ls -A "$B/plugins" | tr '\n' ' ')" = "$LIVE_OFFLINE"

# ======================================================================
start "orphaned clone is adopted"
offline_home
mkdir -p "$B/plugins"
git clone -q --depth=1 "file://$UP/chronos.git" "$B/plugins/chronos"
git -C "$B/plugins/chronos" remote set-url origin "file://$UP/chronos/"   # .git + trailing slash normalised
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "reported as adopted" grep -q "chronos: adopted existing clone" <<<"$out"
check "recorded in state.json" jq -e '.items["plugin:chronos"] != null' "$B/overclocked/state.json"
check "recorded in plugins.json" test "$(pj_commit "$B/plugins.json" chronos)" = "$(git -C "$B/plugins/chronos" rev-parse HEAD)"
check "no backup made" test ! -e "$B/overclocked/backups"
check "status: adopted plugin installed" grep -q "chronos: installed @" <<<"$(ocf status)"

# ======================================================================
start "symlinked plugins.json is refused"
offline_home
real="$(tmpd)/plugins.json"; echo '{"keep":true}' >"$real"
ln -s "$real" "$B/plugins.json"
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "warned" grep -q "plugins.json is a symlink; not rewriting it" <<<"$out"
check "still a symlink" test "$(readlink "$B/plugins.json")" = "$real"
check "target unchanged" test "$(cat "$real")" = '{"keep":true}'

# ======================================================================
start "--profile / SYNAPS_PROFILE"
offline_home
out="$(SYNAPS_PROFILE=work ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "plugins.json written to profile dir" jq -e '[.installed[].name] | sort == ["agent-comms","chronos","d20","heartbeat","synaps-dash","tmux-tools"]' "$B/work/plugins.json"
check "no base plugins.json" test ! -e "$B/plugins.json"
check "plugins still in base plugins/" test -d "$B/plugins/chronos/.git"
check "--profile flag sees the same state" grep -q "chronos: installed @ .* (plugins.json: [0-9a-f]\{7\};" <<<"$(ocf status --profile work)"
out="$(ocf install --profile 2>&1)"; rc=$?
check "--profile without a value dies" test "$rc" != 0
check "--profile message" grep -q "needs a profile name" <<<"$out"

# ======================================================================
start "--reclone never touches foreign symlinks (offline)"
offline_home
tgt="$(tmpd)"; mkdir -p "$B/plugins"; ln -s "$tgt" "$B/plugins/chronos"
out="$(ocf install --reclone 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "symlink untouched" test "$(readlink "$B/plugins/chronos")" = "$tgt"
check "skill symlinks untouched" test "$(readlink "$B/skills/gauntlet-loop")" = /nonexistent
out="$(ocf install --force 2>&1)"
check "--force alias also leaves it" test "$(readlink "$B/plugins/chronos")" = "$tgt"
check "nothing displaced" jq -e '(.displaced // []) == []' "$B/overclocked/state.json"

# ======================================================================
start "adoption needs a clean clone"
offline_home
mkdir -p "$B/plugins"
git clone -q "file://$UP/chronos.git" "$B/plugins/chronos"
echo dirty >>"$B/plugins/chronos/main.py"
git clone -q "file://$UP/synaps-dash.git" "$B/plugins/synaps-dash"
echo ahead >>"$B/plugins/synaps-dash/main.py"; git -C "$B/plugins/synaps-dash" commit -qam ahead
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "dirty clone treated as foreign" grep -q "chronos: .* local changes or unpushed commits; treating it as foreign" <<<"$out"
check "ahead clone treated as foreign" grep -q "synaps-dash: .* local changes or unpushed commits; treating it as foreign" <<<"$out"
check "neither recorded" jq -e '.items["plugin:chronos"] == null and .items["plugin:synaps-dash"] == null' "$B/overclocked/state.json"
check "dirty work kept" grep -q dirty "$B/plugins/chronos/main.py"

# ======================================================================
start "uninstall keeps plugins.json entries it doesn't own (shady repro)"
offline_home
ocf install >/dev/null 2>&1
dev="$(tmpd)"; mv "$B/plugins/agent-comms" "$dev/agent-comms"; ln -s "$dev/agent-comms" "$B/plugins/agent-comms"
jq '.installed |= map(if .name == "agent-comms" then .marketplace = "local" else . end)' "$B/plugins.json" >"$B/p.new" && mv "$B/p.new" "$B/plugins.json"
out="$(ocf uninstall 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "dev symlink left alone" test "$(readlink "$B/plugins/agent-comms")" = "$dev/agent-comms"
check "foreign-marketplace entry kept" jq -e 'any(.installed[]; .name == "agent-comms" and .marketplace == "local")' "$B/plugins.json"
check "our moved entries dropped" jq -e '[.installed[].name] == ["agent-comms"]' "$B/plugins.json"
check "marketplace overclock added is dropped" jq -e 'all(.marketplaces[]; .name != "synaps-overclocked")' "$B/plugins.json"

# ======================================================================
start "uninstall keeps a pre-existing marketplace and trusted host"
offline_home
cat >"$B/plugins.json" <<'EOF'
{"marketplaces":[{"name":"synaps-overclocked","url":"https://example.invalid/m.json","cached_plugins":[]}],"installed":[],"trusted_hosts":["github.com/HaseebKhalid1507"]}
EOF
chmod 644 "$B/plugins.json"
orig="$(jq -S . "$B/plugins.json")"
ocf install >/dev/null 2>&1
check "existing file mode kept (644)" test "$(stat -c %a "$B/plugins.json")" = 644
check "not recorded as added" jq -e '(.added_marketplace // false) == false and (.added_trusted_hosts // []) == []' "$B/overclocked/state.json"
ocf uninstall >/dev/null 2>&1
check "plugins.json back to the original" test "$(jq -S . "$B/plugins.json")" = "$orig"
check "mode still 644" test "$(stat -c %a "$B/plugins.json")" = 644

# ======================================================================
start "new JSON files are 0600"
offline_home
ocf install >/dev/null 2>&1
check "new plugins.json 600" test "$(stat -c %a "$B/plugins.json")" = 600
check "new state.json 600" test "$(stat -c %a "$B/overclocked/state.json")" = 600
check "profile recorded" jq -e --arg pj "$B/plugins.json" '.profile == "" and .plugins_json == $pj' "$B/overclocked/state.json"

# ======================================================================
start "uninstall follows the recorded profile"
offline_home
SYNAPS_PROFILE=work ocf install >/dev/null 2>&1
out="$(ocf uninstall 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "warns about the profile mismatch" grep -q "recorded under profile 'work'" <<<"$out"
check "cleaned the recorded profile's plugins.json" jq -e '.installed == []' "$B/work/plugins.json"
check "did not create a base plugins.json" test ! -e "$B/plugins.json"

# ======================================================================
start "paths with .. are refused"
offline_home
ocf install >/dev/null 2>&1
victim="$HOME/victim"; mkdir -p "$victim"; echo keep >"$victim/f"
jq --arg p "$B/../victim" '.items["plugin:evil"] = {path:$p}' "$B/overclocked/state.json" >"$B/s.new" && mv "$B/s.new" "$B/overclocked/state.json"
out="$(ocf uninstall 2>&1)"; rc=$?
check "uninstall exit 0" test "$rc" = 0
check "warned" grep -q "plugin:evil: recorded path .* \. / \.\. components; left alone" <<<"$out"
check "victim untouched" test "$(cat "$victim/f")" = keep
out="$(SYNAPS_BASE_DIR="$HOME/x/../.synaps-cli" "$OC" status 2>&1)"; rc=$?
check "base dir with .. refused" test "$rc" != 0
check "message" grep -q "must not contain . or .. components" <<<"$out"

# ======================================================================
start "bad environments die cleanly"
out="$(env -u HOME -u SYNAPS_BASE_DIR "$OC" status 2>&1)"; rc=$?
check "unset HOME: nonzero" test "$rc" != 0
check "unset HOME: clean message" grep -q "neither SYNAPS_BASE_DIR nor HOME is set" <<<"$out"
check "unset HOME: no bash error" bash -c '! grep -q "unbound variable" <<<"$1"' _ "$out"
out="$(SYNAPS_BASE_DIR=/ "$OC" status 2>&1)"; rc=$?
check "SYNAPS_BASE_DIR=/ nonzero" test "$rc" != 0
check "SYNAPS_BASE_DIR=/ message" grep -q "refusing to use / as the Synaps base dir" <<<"$out"

# ======================================================================
start "uninstall leaves nothing live"
offline_home
ocf install >/dev/null 2>&1
before="$(tree_hash "$B")"
out="$(ocf uninstall --dry-run 2>&1)"; rc=$?
check "uninstall --dry-run exit 0" test "$rc" = 0
check "uninstall --dry-run writes nothing" test "$before" = "$(tree_hash "$B")"
out="$(ocf uninstall 2>&1)"; rc=$?
check "uninstall exit 0" test "$rc" = 0
check "plugins/ empty" test -z "$(ls -A "$B/plugins")"
check "agents/ empty" test -z "$(ls -A "$B/agents")"
check "foreign skills symlinks untouched" test -L "$B/skills/gauntlet-loop"
check "plugins.json: no entries of ours" jq -e '(.installed | length) == 0 and all(.marketplaces[]; .name != "synaps-overclocked")' "$B/plugins.json"
check "state.json retired" test ! -e "$B/overclocked/state.json"
check "removed/ holds the plugins" test -d "$(ls -d "$B"/overclocked/removed/*/plugins/chronos | head -n1)/.git"
check "status after uninstall: missing" grep -q "chronos: missing" <<<"$(ocf status)"
out="$(ocf install 2>&1)"; rc=$?
check "reinstall after uninstall works" test -d "$B/plugins/chronos/.git"

# ======================================================================
start "heartbeat + d20 install, update and uninstall like the others"
offline_home
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
for p in heartbeat d20; do
  check "$p cloned" test -d "$B/plugins/$p/.git"
  check "$p commit == upstream" test "$(git -C "$B/plugins/$p" rev-parse HEAD)" = "$(up_head "$p")"
  check "$p plugins.json entry" jq -e --arg n "$p" --arg u "file://$UP/$p.git" '.installed[] | select(.name == $n) | .source_url == $u and .marketplace == "synaps-overclocked" and .source_subdir == null and .setup_status == {state:"not_required"}' "$B/plugins.json"
  check "status: $p installed" grep -q "$p: installed @ [0-9a-f]\{7\} (plugins.json: [0-9a-f]\{7\}; unpinned, tracks HEAD)" <<<"$(ocf status)"
done
check "plugins.json schema-shaped" plugins_json_shape "$B/plugins.json"
printf 'max_beats = 3\n' >"$B/plugins/heartbeat/config"   # the user's own settings (gitignored upstream)
push_commit heartbeat v2
out="$(ocf update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "heartbeat fast-forwards past a local config" test "$(git -C "$B/plugins/heartbeat" rev-parse HEAD)" = "$(up_head heartbeat)"
check "local config kept" grep -q "max_beats = 3" "$B/plugins/heartbeat/config"
check "plugins.json commit bumped" test "$(pj_commit "$B/plugins.json" heartbeat)" = "$(up_head heartbeat)"
check "d20 up to date" grep -q "d20: up to date" <<<"$out"
out="$(ocf uninstall 2>&1)"; rc=$?
check "uninstall exit 0" test "$rc" = 0
check "heartbeat and d20 moved out" test ! -e "$B/plugins/heartbeat" -a ! -e "$B/plugins/d20"
check "their entries are gone" jq -e 'all(.installed[]; .name != "heartbeat" and .name != "d20")' "$B/plugins.json"
check "removed/ holds heartbeat with its config" test -f "$(ls -d "$B"/overclocked/removed/*/plugins/heartbeat | head -n1)/config"

# ======================================================================
start "subdir plugin (tmux-tools): install like /plugins"
offline_home
before_up="$(git -C "$UP/skills-repo.git" rev-parse main)"
out="$(ocf install --dry-run 2>&1)"; rc=$?
check "dry-run exit 0" test "$rc" = 0
check "dry-run names the sparse copy" grep -q "\[dry-run\] sparse clone --depth=1 file://$UP/skills-repo.git, copy tmux-tools-plugin/ -> $B/plugins/tmux-tools" <<<"$out"
check "dry-run wrote nothing" test ! -e "$B/plugins"
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
T="$B/plugins/tmux-tools"
check "subdir content copied" test -f "$T/skills/tmux/SKILL.md" -a -f "$T/.synaps-plugin/plugin.json"
check "exec bit kept" test -x "$T/scripts/pane.sh"
check "no .git in the plugin dir" test ! -e "$T/.git"
check "nothing else from the repo" test ! -e "$T/other-plugin" -a ! -e "$T/README.md" -a ! -e "$T/tmux-tools-plugin"
check "plugins.json entry like a /plugins subdir install" jq -e --arg u "file://$UP/skills-repo.git" --arg c "$before_up" \
  '.installed[] | select(.name == "tmux-tools") | .source_url == $u and .source_subdir == "tmux-tools-plugin" and .installed_commit == $c and .setup_status == {state:"not_required"} and .checksum_value == null' "$B/plugins.json"
check "state.json records subdir + content hash" jq -e --arg c "$before_up" '.items["plugin:tmux-tools"] | .subdir == "tmux-tools-plugin" and .commit == $c and (.tree | test("^[0-9a-f]{64}$"))' "$B/overclocked/state.json"
check "plugins.json schema-shaped" plugins_json_shape "$B/plugins.json"
check "status shows subdir" grep -q "tmux-tools: installed @ $(short "$before_up") (plugins.json: $(short "$before_up"); tmux-tools-plugin/ of file://$UP/skills-repo.git, tracks HEAD)" <<<"$(ocf status)"
check "no scratch dir left" bash -c "! ls -d '$B'/overclocked/.tmp.* 2>/dev/null"
before="$(tree_hash "$B")"
out="$(ocf install 2>&1)"
check "rerun is a no-op" test "$before" = "$(tree_hash "$B")"
check "rerun reports installed" grep -q "tmux-tools: installed @ $(short "$before_up")" <<<"$out"

start "subdir plugin: update"
out="$(ocf update 2>&1)"
check "unchanged upstream: up to date" grep -q "tmux-tools: up to date @ $(short "$before_up")" <<<"$out"
at1="$(jq -r '.installed[] | select(.name == "tmux-tools") | .installed_at' "$B/plugins.json")"
push_sub tmux-tools-plugin/skills/tmux/SKILL.md v2
out="$(ocf update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "new content copied" grep -q v2 "$T/skills/tmux/SKILL.md"
check "plugins.json commit bumped" test "$(pj_commit "$B/plugins.json" tmux-tools)" = "$(up_head skills-repo)"
check "installed_at kept" test "$(jq -r '.installed[] | select(.name == "tmux-tools") | .installed_at' "$B/plugins.json")" = "$at1"
check "state.json commit bumped" jq -e --arg c "$(up_head skills-repo)" '.items["plugin:tmux-tools"].commit == $c' "$B/overclocked/state.json"
check "old copy in backups/" bash -c "! grep -q v2 '$(ls -d "$B"/overclocked/backups/*/plugins/tmux-tools | head -n1)/skills/tmux/SKILL.md'"
check "plugins/ holds only live plugins" test "$(ls -A "$B/plugins" | tr '\n' ' ')" = "$LIVE_OFFLINE"
push_sub other-plugin/README unrelated
out="$(ocf update 2>&1)"
check "commit outside the subdir still bumps the commit" test "$(pj_commit "$B/plugins.json" tmux-tools)" = "$(up_head skills-repo)"
echo "my edit" >>"$T/skills/tmux/SKILL.md"
push_sub tmux-tools-plugin/skills/tmux/SKILL.md v3
cur="$(pj_commit "$B/plugins.json" tmux-tools)"
out="$(ocf update 2>&1)"
check "local edit blocks update" grep -q "tmux-tools: local changes, not updating (use --reclone to replace it)" <<<"$out"
check "local edit kept" grep -q "my edit" "$T/skills/tmux/SKILL.md"
check "commit unchanged" test "$(pj_commit "$B/plugins.json" tmux-tools)" = "$cur"
out="$(ocf update --reclone 2>&1)"; rc=$?
check "update --reclone exit 0" test "$rc" = 0
check "--reclone took upstream" grep -q v3 "$T/skills/tmux/SKILL.md"
check "--reclone dropped the edit from plugins/" bash -c "! grep -q 'my edit' '$T/skills/tmux/SKILL.md'"
check "edited copy kept in backups/" bash -c "grep -lq 'my edit' '$B'/overclocked/backups/*/plugins/tmux-tools*/skills/tmux/SKILL.md"

start "subdir plugin: uninstall"
out="$(ocf uninstall 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "moved out of plugins/" test ! -e "$T"
check "entry gone" jq -e 'all(.installed[]; .name != "tmux-tools")' "$B/plugins.json"
check "removed/ holds it" test -f "$(ls -d "$B"/overclocked/removed/*/plugins/tmux-tools | head -n1)/skills/tmux/SKILL.md"

# ======================================================================
start "subdir plugin: adopting a /plugins install"
offline_home
c="$(up_head skills-repo)"
w="$(tmpd)"; git clone -q "file://$UP/skills-repo.git" "$w/r"
mkdir -p "$B/plugins"; cp -Rp "$w/r/tmux-tools-plugin" "$B/plugins/tmux-tools"
jq -n --arg u "file://$UP/skills-repo.git" --arg c "$c" '{marketplaces:[], trusted_hosts:[], installed:[{name:"tmux-tools", marketplace:"synaps-skills", source_url:$u, installed_commit:$c,
  latest_commit:null, installed_at:"2026-01-01T00:00:00+00:00", source_subdir:"tmux-tools-plugin", checksum_algorithm:null, checksum_value:null, setup_status:{state:"not_required"}}]}' >"$B/plugins.json"
push_sub tmux-tools-plugin/skills/tmux/SKILL.md v4    # upstream moved on since that install
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "adopted at its recorded commit" grep -q "tmux-tools: adopted existing install (tmux-tools-plugin/ @ $(short "$c"))" <<<"$out"
check "recorded in state.json" jq -e --arg c "$c" '.items["plugin:tmux-tools"].commit == $c' "$B/overclocked/state.json"
check "existing plugins.json entry kept" jq -e '[.installed[] | select(.name == "tmux-tools")] | length == 1 and .[0].marketplace == "synaps-skills"' "$B/plugins.json"
check "plugin dir not replaced" bash -c "! ls -d '$B'/overclocked/backups/*/plugins/tmux-tools 2>/dev/null"
offline_home
mkdir -p "$B/plugins"; cp -Rp "$w/r/tmux-tools-plugin" "$B/plugins/tmux-tools"; echo hacked >>"$B/plugins/tmux-tools/scripts/pane.sh"
jq -n --arg u "file://$UP/skills-repo.git" --arg c "$c" '{installed:[{name:"tmux-tools", source_url:$u, installed_commit:$c, installed_at:"x", source_subdir:"tmux-tools-plugin"}]}' >"$B/plugins.json"
out="$(ocf install 2>&1)"
check "modified copy is foreign" grep -q "tmux-tools: skipped, $B/plugins/tmux-tools exists and is not managed by overclock" <<<"$out"
check "modified copy untouched" grep -q hacked "$B/plugins/tmux-tools/scripts/pane.sh"

# ======================================================================
start "subdir plugin: missing subdir upstream"
offline_home
FORK2="$(tmpd)"; cp -R "$FORK/." "$FORK2/"
jq '.plugins[0].subdir = "no-such-plugin"' "$FORK/subdir-plugins.json" >"$FORK2/subdir-plugins.json"
out="$("$FORK2/overclock" install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "warned" grep -q "tmux-tools: fetching no-such-plugin from .* failed: subdir 'no-such-plugin' not found" <<<"$out"
check "not installed" test ! -e "$B/plugins/tmux-tools"
check "not registered" jq -e 'all(.installed[]; .name != "tmux-tools")' "$B/plugins.json"
jq '.plugins[0].subdir = "../evil"' "$FORK/subdir-plugins.json" >"$FORK2/subdir-plugins.json"
out="$("$FORK2/overclock" install 2>&1)"
check "unsafe subdir refused" grep -q "tmux-tools: unsafe subdir '../evil'" <<<"$out"

# ======================================================================
start "crush: skipped without cargo"
offline_home
out="$(ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "clear warning" grep -q "crush: skipped, needs 'cargo' which is not installed (it is built from source; install the Rust toolchain" <<<"$out"
check "not cloned" test ! -e "$B/plugins/crush"
check "not registered" jq -e 'all(.installed[]; .name != "crush")' "$B/plugins.json"
check "status: missing" grep -q "crush: missing" <<<"$(ocf status)"

start "crush: built with cargo"
offline_home
: >"$CARGO_STUB_LOG"
out="$(with_cargo ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "cargo build --release --locked ran once" test "$(cat "$CARGO_STUB_LOG" | wc -l)" = 1
check "with --locked and a pinned --target-dir" grep -q '|build --release --locked --target-dir target$' "$CARGO_STUB_LOG"
check "built before the swap (in scratch, not plugins/)" bash -c "grep -q '/overclocked/.tmp\.' '$CARGO_STUB_LOG'"
check "binary in place" test -x "$B/plugins/crush/target/release/crush"
check "clone is pristine (target/ ignored)" test -z "$(git -C "$B/plugins/crush" status --porcelain)"
log="$(jq -r '.installed[] | select(.name == "crush") | .setup_status.log_path' "$B/plugins.json")"
check "setup_status succeeded like /plugins" jq -e '.installed[] | select(.name == "crush") | .setup_status.state == "succeeded"' "$B/plugins.json"
check "build log exists" test -f "$log"
check "plugins.json schema-shaped" plugins_json_shape "$B/plugins.json"
check "status: built" grep -q "crush: installed @ [0-9a-f]\{7\} (plugins.json: [0-9a-f]\{7\}; unpinned, tracks HEAD; built)" <<<"$(ocf status)"
before="$(tree_hash "$B")"
with_cargo ocf install >/dev/null 2>&1
check "rerun does not rebuild" test "$(cat "$CARGO_STUB_LOG" | wc -l)" = 1
check "rerun is a no-op" test "$before" = "$(tree_hash "$B")"
push_commit crush v2
out="$(with_cargo ocf update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "update rebuilt in place" test "$(tail -n1 "$CARGO_STUB_LOG" | cut -d'|' -f1)" = "$B/plugins/crush"
check "update fast-forwarded" test "$(git -C "$B/plugins/crush" rev-parse HEAD)" = "$(up_head crush)"
check "plugins.json commit bumped" test "$(pj_commit "$B/plugins.json" crush)" = "$(up_head crush)"
check "setup_status still succeeded" jq -e '.installed[] | select(.name == "crush") | .setup_status.state == "succeeded"' "$B/plugins.json"

start "crush: failed rebuild on update rolls back"
good="$(git -C "$B/plugins/crush" rev-parse HEAD)"
push_commit crush v3
out="$(CARGO_STUB_FAIL=1 with_cargo ocf update 2>&1)"; rc=$?
check "update exit 0" test "$rc" = 0
check "build error shown" grep -q "crush: cargo build failed: .*stub build failure" <<<"$out"
check "rollback reported" grep -q "crush: rebuild failed; source reset to $(short "$good")" <<<"$out"
check "source back at the old commit" test "$(git -C "$B/plugins/crush" rev-parse HEAD)" = "$good"
check "old binary still there" test -x "$B/plugins/crush/target/release/crush"
check "plugins.json commit unchanged" test "$(pj_commit "$B/plugins.json" crush)" = "$good"
out="$(ocf update 2>&1)"
check "update without cargo leaves crush alone" grep -q "crush: not updating, needs 'cargo' to rebuild it" <<<"$out"
check "still at the old commit" test "$(git -C "$B/plugins/crush" rev-parse HEAD)" = "$good"
out="$(with_cargo ocf update 2>&1)"
check "next update with cargo catches up" test "$(pj_commit "$B/plugins.json" crush)" = "$(up_head crush)"
out="$(ocf uninstall 2>&1)"
check "uninstall moves crush out" test ! -e "$B/plugins/crush"
check "uninstall drops its entry" jq -e 'all(.installed[]; .name != "crush")' "$B/plugins.json"

start "crush: failed build on install registers nothing"
offline_home
out="$(CARGO_STUB_FAIL=1 with_cargo ocf install 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "build failure reported" grep -q "crush: cargo build failed" <<<"$out"
check "not installed" grep -q "crush: not installed" <<<"$out"
check "nothing in plugins/" test ! -e "$B/plugins/crush"
check "not registered" jq -e 'all(.installed[]; .name != "crush")' "$B/plugins.json"
check "not in state.json" jq -e '.items["plugin:crush"] == null' "$B/overclocked/state.json"
check "no scratch dir left" bash -c "! ls -d '$B'/overclocked/.tmp.* 2>/dev/null"
mkdir -p "$B/plugins"; ln -s /nonexistent-crush "$B/plugins/crush"
out="$(CARGO_STUB_FAIL=1 with_cargo ocf install --replace-foreign 2>&1)"
check "--replace-foreign + failed build keeps the foreign item" test "$(readlink "$B/plugins/crush")" = /nonexistent-crush

# full (network) install from the first case
HOME="$FRESH_HOME" SYNAPS_BASE_DIR="$FRESH_B"; export HOME SYNAPS_BASE_DIR; B="$FRESH_B"
out="$(oc uninstall 2>&1)"; rc=$?
check "full uninstall exit 0" test "$rc" = 0
check "full: plugins/ empty" test -z "$(ls -A "$B/plugins")"
check "full: skills/ empty" test -z "$(ls -A "$B/skills")"
check "full: agents/ empty" test -z "$(ls -A "$B/agents")"
check "full: mcp.json context-mode gone" jq -e '.mcpServers["context-mode"] == null' "$B/mcp.json"
check "full: trusted host overclock added is gone" jq -e '.trusted_hosts == [] and .marketplaces == []' "$B/plugins.json"
check "full: context-mode clone moved" test -d "$(ls -d "$B"/overclocked/removed/*/overclocked/context-mode | head -n1)"
check "full: backups of JSON kept" bash -c "ls '$B'/overclocked/backups/*/mcp.json '$B'/overclocked/backups/*/plugins.json >/dev/null"

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
