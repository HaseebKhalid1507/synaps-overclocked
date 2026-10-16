# synaps-overclocked

Our plugin stack in a box. One command turns stock SynapsCLI into Synaps the way Haseeb runs it.

## What's in the stack

| kind | item | source | needs |
|---|---|---|---|
| plugin | `agent-comms`: session awareness, cross-session messages and claims | [agent-comms](https://github.com/HaseebKhalid1507/agent-comms) (tracks HEAD) | `python3` |
| plugin | `chronos`: injects the current time before every user message | [synaps-chronos](https://github.com/HaseebKhalid1507/synaps-chronos) (tracks HEAD) | `python3` |
| plugin | `synaps-dash`: browser client for the session daemon | [synaps-dash](https://github.com/HaseebKhalid1507/synaps-dash) (tracks HEAD) | `bun` |
| plugin | `heartbeat`: keeps the Anthropic prompt cache warm through idle gaps with a tiny keepalive turn before the 5-minute TTL | [synaps-heartbeat](https://github.com/HaseebKhalid1507/synaps-heartbeat) (tracks HEAD) | `python3` |
| plugin | `d20`: rolls a d20 before every user message and injects it | [synaps-d20](https://github.com/HaseebKhalid1507/synaps-d20) (tracks HEAD) | `python3` |
| plugin | `crush`: native Rust compressor for tool output (`after_tool_call`) | [Crush-Synaps](https://github.com/HaseebKhalid1507/Crush-Synaps) (tracks HEAD, built on install) | `cargo` |
| plugin | `tmux-tools`: worker-pane skills for agents running inside tmux | `tmux-tools-plugin/` in [maha-media/synaps-skills](https://github.com/maha-media/synaps-skills) by JR Morton (tracks HEAD, MIT) | – (`tmux` at runtime) |
| agents | spike, shady, chrollo, case, silverhand, yoru, joestar, gojo, starlord, okarin, zero, ryuga, 007, saul | `agents/` in this repo | – |
| skill | `gauntlet-loop` | [robonuggets/gauntlet-loop](https://github.com/robonuggets/gauntlet-loop) @ `9b1975a` (CC BY 4.0, technique by Matt Shumer) | – |
| skill | `last30days` | [mvanhorn/last30days-skill](https://github.com/mvanhorn/last30days-skill) @ `0188da7` (MIT) | `python3` at runtime |
| MCP | `context-mode` | [mksglu/context-mode](https://github.com/mksglu/context-mode) @ `928bdf1` (Elastic License 2.0) | `node` ≥ 22.5 (see below) |

Skills and context-mode are pinned in [`skills.lock.json`](skills.lock.json) and cloned at that exact commit during install. tmux-tools is listed in [`subdir-plugins.json`](subdir-plugins.json), because it's a subdirectory of someone else's repo. Nothing third-party is vendored in this repo.

## Install

Requires `git` and `jq`. `python3`, `bun`, `node` and `cargo` are optional: a missing runtime skips only the items that need it, and you get a warning. `cargo` (the Rust toolchain, [rustup.rs](https://rustup.rs)) is only needed for crush, which overclock builds from source.

```bash
git clone https://github.com/HaseebKhalid1507/synaps-overclocked ~/synaps-overclocked && ~/synaps-overclocked/overclock
```

Keep the checkout around if you want `overclock status` / `overclock update` later. Agents are copied, not linked, so deleting it doesn't break anything.

```
overclock [install|status|update|uninstall] [--dry-run] [--reclone] [--replace-foreign] [--profile NAME]

  install            (default) install whatever is missing; rerunning is a no-op
  status             each item: installed / skipped (foreign) / missing, plus commit vs pinned
  update             fast-forward the plugins; re-pin skills/context-mode when skills.lock.json changed
  uninstall          move everything overclock installed to BASE/overclocked/removed/<ts>/
                     and put back anything --replace-foreign displaced
  --dry-run          print every action, write nothing
  --reclone          safe: touches only items overclock owns. install reclones its plugins and
                     refreshes agents you edited; update reclones plugins that can't fast-forward
                     (rewritten upstream) or have local changes
  --replace-foreign  explicit: moves items overclock did NOT install (dirs, dev symlinks, a
                     different context-mode mcp entry) aside and installs ours instead
  --force            deprecated alias for --reclone (prints a notice)
```

Anything replaced is moved to `BASE/overclocked/backups/<ts>/`, never deleted.

Restart Synaps afterwards so it loads the new plugins and MCP server.

### Plugins only: the native `/plugins` route

This repo also works as a Synaps marketplace (`.synaps-plugin/marketplace.json`, absolute https sources):

1. In Synaps, run `/plugins` → **add marketplace** → `https://github.com/HaseebKhalid1507/synaps-overclocked`
2. Install `agent-comms`, `chronos`, `synaps-dash`, `heartbeat`, `d20` and `crush` from the list. crush declares a setup step (`scripts/setup.sh`, `cargo build --release --locked --target-dir target`), so `/plugins` builds it for you when `cargo` is on `PATH`.
3. tmux-tools lives in JR's repo, and the marketplace format only allows `./<subdir>` sources inside the marketplace's own repo. To get it through `/plugins`, add his marketplace (`https://github.com/maha-media/synaps-skills`) and install `tmux-tools` from there.

That route only covers the plugins. For the agents, skills and context-mode, run `overclock`. It skips plugins that are already installed, and it adopts clean `/plugins` installs of the same source (see below).

### context-mode and Node

`server.bundle.mjs` bundles all of its JS dependencies. The one exception is SQLite. On Node ≥ 22.5 (or Bun) it uses the built-in `node:sqlite` with FTS5, so **no `npm install` is needed**. On older Node it falls back to `better-sqlite3` from `node_modules`. overclock never runs npm. If your node can't do it, the installer prints the exact command:

```bash
(cd ~/.synaps-cli/overclocked/context-mode && npm install --omit=dev)
```

## What it touches

Everything lives under `BASE="${SYNAPS_BASE_DIR:-$HOME/.synaps-cli}"`:

| path | what |
|---|---|
| `plugins/{agent-comms,chronos,synaps-dash,heartbeat,d20,crush}/` | `git clone --depth=1`, same as the `/plugins` TUI |
| `plugins/crush/target/` | `cargo build --release --locked --target-dir target`, run in the fresh clone before it is moved into `plugins/`, and again in place after `update` fast-forwards it |
| `plugins/tmux-tools/` | the `tmux-tools-plugin/` dir of `maha-media/synaps-skills` at HEAD, copied the way `/plugins` installs a `./<subdir>` plugin (`install_plugin_from_subdir`): no `.git`, nothing else from the repo. overclock fetches it with a shallow, sparse checkout |
| `plugins.json` | jq merge: adds the `synaps-overclocked` marketplace, one `installed` entry per plugin, and the trusted hosts `github.com/HaseebKhalid1507` and `github.com/maha-media`. Each entry gets `installed_commit` (`git rev-parse HEAD`, or the fetched repo commit for tmux-tools) and `setup_status`: `not_required`, or `succeeded` with `log_path` for crush. tmux-tools also gets `source_url` = the synaps-skills repo and `source_subdir: "tmux-tools-plugin"`. Existing keys and entries are preserved. |
| `agents/<name>.md` | copied from `agents/` |
| `skills/{gauntlet-loop,last30days}/` | skill dir from the pinned commit, plus `.SOURCE_COMMIT` (and `SOURCE` for gauntlet-loop) |
| `overclocked/context-mode/` | pinned git checkout of context-mode |
| `context-mode/`, `context-mode-shim/` | empty state dirs for context-mode (mode 700) |
| `mcp.json` | jq merge: adds `mcpServers.context-mode`. Other servers and keys are preserved. |
| `overclocked/state.json` | the record of what overclock installed. This is how "ours" is told apart from "foreign". For tmux-tools it also records a content hash, so `update` can tell local edits from upstream changes. |
| `overclocked/logs/crush-<ts>.log` | output of each crush build (the `log_path` in `plugins.json`) |
| `overclocked/backups/<ts>/` | everything `--reclone`/`--replace-foreign`/`update` replaced, plus a copy of `plugins.json`/`mcp.json` before each rewrite, at its path relative to `BASE` |
| `overclocked/removed/<ts>/` | what `uninstall` moved out |

**Trust:** `trusted_hosts` gets `github.com/HaseebKhalid1507` and, for tmux-tools, `github.com/maha-media`. That's the same thing the `/plugins` trust prompt records when you accept it. It means any future `/plugins` install from those GitHub owners skips the trust prompt. overclock records in `state.json` whether it added that host (and the `synaps-overclocked` marketplace). `uninstall` removes only what overclock added. If they were already there, they stay.

Safety rules:
- An existing plugin dir, agent file or skill dir (symlinks included) that overclock didn't install is **skipped** and reported. `--reclone` never touches it. Only `--replace-foreign` moves it to `BASE/overclocked/backups/<ts>/<same relative path>`. The original path, the backup path and (for symlinks) the link target are recorded in `state.json`, so `uninstall` can put it back. Backups never sit inside `plugins/`, `skills/` or `agents/`, so Synaps can't load a stale copy.
- **Adoption.** A plugin dir (or the context-mode checkout) that isn't installed by overclock but looks like an overclock install gets adopted instead of skipped. That covers an interrupted overclock run and a copy installed through `/plugins`. All three must hold:
  - it is not a symlink
  - its `origin` is the same repo (ignoring `.git`, a trailing `/` and case)
  - it is clean: `git status --porcelain` is empty, and it has no commits ahead of `@{upstream}`

  A dev clone with local work is treated as foreign.

  tmux-tools has no `.git`, so it's adopted when `plugins.json` already has a `tmux-tools` entry with the same `source_url` and `source_subdir`, and the dir's content matches that subdir at the entry's `installed_commit` exactly. Anything else is foreign.
- Before `plugins.json` or `mcp.json` is rewritten, it is copied into the backups dir. Writes are atomic (temp file + rename). If either file is invalid JSON or the wrong shape, overclock aborts before writing anything. If either one is a symlink, overclock warns and leaves it alone, because a rename would replace the link.
- A `context-mode` MCP entry that points somewhere else is left alone unless `--replace-foreign` is given. In that case the old entry is recorded and `uninstall` restores it.
- Rewritten `plugins.json`/`mcp.json` keep their file mode. New files are created `0600`.
- Recorded paths must sit under `BASE` with no `.`/`..` components. `SYNAPS_BASE_DIR` itself may not contain them either.
- **crush** is the only thing overclock builds. It runs `cargo build --release --locked --target-dir target` (never an unlocked build, and never without a `Cargo.lock`) and then checks that the manifest's `extension.command` (`target/release/crush`) exists and is executable. Without `cargo`, crush is skipped with a warning and not registered. If the build fails on install, nothing is moved into `plugins/` or registered (a foreign dir that `--replace-foreign` would have replaced stays where it is). If the rebuild fails on `update`, the clone is reset to the commit it was at and the previous binary stays.
- `update` and tmux-tools: overclock compares the recorded commit with `git ls-remote` HEAD and copies the subdir again if HEAD moved; the old copy goes to backups. If you edited files in it, the update is skipped, unless you pass `--reclone`.
- Refuses to run as root. Never runs npm/bun installs.

### Profiles

If `SYNAPS_PROFILE` is set (or `--profile NAME` is passed), the paths follow Synaps' own resolution in `agent-core/src/core/config.rs`:
- `plugins.json` goes to `BASE/<profile>/plugins.json` (`resolve_write_path`).
- `mcp.json` goes to the profile copy if one exists, otherwise to the base file.
- skills go to `BASE/<profile>/skills` if that dir exists, otherwise to the base dir.
- Plugins and agents always go to `BASE/plugins` and `BASE/agents`, because that's the only place the extension manager and the agent resolver look.

## Uninstall

```bash
overclock uninstall --dry-run   # review
overclock uninstall
```

This works from `BASE/overclocked/state.json`, using the profile recorded at install time. If you pass a different `--profile`, you get a warning and the recorded one is used.
- Every item overclock installed is moved to `BASE/overclocked/removed/<ts>/`, outside every dir Synaps scans. Nothing is deleted. Items that have since become a symlink, or were never moved, are left alone.
- From `plugins.json`, only `synaps-overclocked`-marketplace entries for plugins that were actually moved are dropped. The marketplace and the trusted host are removed only if overclock added them and nothing still uses them.
- `mcpServers.context-mode` is dropped from `mcp.json`, but only if it is still the entry overclock wrote. A user entry that `--replace-foreign` displaced is put back.
- **Restore.** Every foreign item `--replace-foreign` displaced is moved back to its original path, but only if that path is empty at that point. A symlink comes back with the same target. If the path is occupied, the item stays in backups and uninstall prints where it is.
- Both JSON files are backed up first and written atomically.
- `state.json` itself is retired into the same `removed/` dir.
- The context-mode data dirs (`BASE/context-mode`, `BASE/context-mode-shim`) are left alone.

Delete `BASE/overclocked/removed/` yourself once you're sure.

## Tests

```bash
tests/run.sh
```

Every case runs with a throwaway `HOME` and `SYNAPS_BASE_DIR`. The suite refuses to start if the base dir resolves to anything under your real home. It never runs a real `cargo`: `PATH` is rebuilt without it, and the crush cases put a stub `cargo` in front that fakes a successful or failing build. The full-install cases need network access, because they clone from GitHub. The update, force-push, adoption, profile, uninstall, heartbeat/d20, tmux-tools and crush cases use local `file://` repos.

## Tested on

Linux with bash 5 and GNU coreutils; that's where the suite runs. macOS (bash 3.2, BSD userland) is **best-effort**: the script avoids `mapfile`, associative arrays, unguarded empty-array expansion, `realpath`/`readlink -f`/`sed -i`, and falls back to `shasum -a 256` when `sha256sum` is missing, but it hasn't been run there. `tests/run.sh` itself uses GNU `find -printf`, so it's Linux-only.

## License

MIT © Haseeb Khalid. The bundled agents are covered by it too. The third-party skills and context-mode keep their own licenses (listed in `skills.lock.json`).
