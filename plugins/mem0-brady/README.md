# mem0-brady

B's personal self-hosted [Mem0](https://github.com/mem0ai/mem0) backbone, packaged as a Claude
Code plugin. It is the **single memory store shared by both Claude Code and Hal** — one local
Qdrant, one namespace (`shared-bch`), so the two actors cross-query each other's memories.

Mem0 does **both** kinds of memory here:

- **Explicit hard facts** — `mcp__mem0__*` tools (`add_memory`, `search_memories`, …), available
  in every session, for IPs / ports / versions / config values / ids / endpoints.
- **Passive auto-recall** — on `SessionStart` (and `UserPromptSubmit` resume-intent, and `Read`
  file-context), relevant past memories are injected as context.
- **Passive auto-capture** — on `Stop` and `PreCompact`, a session summary is written to memory.
- **`grill-me` skill** — a Mem0-backed plan/design interview ("grill me") that stress-tests a
  design against prior decisions and persists resolved glossary terms + decisions to the store,
  `app_id`-scoped to the session's domain. (Folded in from the former standalone `grill-me` plugin.)
- **`/mem0-brady:digest`** — proof the layer is earning its keep: summarizes what got captured
  and, critically, **which recall-hook injections actually shaped the work**. Scopes to the
  current session when run mid-session, or the whole day when run in a fresh one. See
  [Digest](#digest-is-the-memory-layer-useful).
- **`workstream` skill** — `/mem0-brady:workstream <slug>` groups multi-session work (spread
  across commits, branches, and worktrees) under one overarching goal: it tags the session,
  maintains a referenceable details doc, and makes the Stop/PreCompact handoffs
  workstream-aware so the workstream propagates to future sessions. See
  [Workstreams](#workstreams).

(This replaced a Honcho-based passive layer — Mem0 now owns the implicit capture too.)

Everything runs **locally, no Docker**: a native Qdrant server binary and the MCP server, both
under launchd.

## Memory model: one store, partitioned by `app_id`

There is **one** `user_id` (`shared-bch`) that every actor reads and writes. Memory is partitioned
into domains by an `app_id` tag, kept in the Qdrant payload:

| Actor | Capture (write) | Recall (read filter) |
|-------|-----------------|----------------------|
| Claude Code in the evergreen repo | `evergreen` | `evergreen` |
| Claude Code elsewhere | `general` | `general` |
| Hal | `hal-ops` | `hal-ops` + `evergreen` |

`run_id` stays available, orthogonally, for scratch / working memory scoped to a task.

The hook wrappers derive the domain from the session's cwd (`*evergreen* → evergreen`, else
`general`) and export `MEM0_APP_ID` (capture) + `MEM0_RECALL_APP_IDS` (recall) before invoking
the fork hooks. Active `mcp__mem0__*` writes pass `app_id` per call (a PreToolUse guard enforces it).

## How it works

```
Claude Code ──(user-level mcpServers, http)──► http://127.0.0.1:8788/mcp
                                       │  launchd: com.mem0brady.server
                                       │  (uv-tool-installed mem0-mcp-selfhosted)
                                       │
Claude hooks (this plugin):            │
  SessionStart(startup|compact) ─► run-context.sh ─► mem0-hook-context (recall) ─┐
  Stop                          ─► run-stop.sh    ─► mem0-hook-stop    (capture) ─┤
                                       │                                          │
Hal / Hermes (mem0_selfhosted         │                                          │
  provider) ──────────────────────────┤                                          │
                                       ▼                                          ▼
                                  native Qdrant server (no Docker)  ◄─────────────┘
                                  launchd: com.mem0brady.qdrant  →  http://127.0.0.1:6433
                                  collection mem0_brady, user_id shared-bch
                                  storage: ~/.local/share/mem0-brady/qdrant-storage

Config (single source of truth): ~/.config/mem0-brady/.env
```

The `mcp__mem0__*` tools are registered at the **user level** (`~/.claude.json` →
`mcpServers.mem0` → `http://127.0.0.1:8788/mcp`), not via a plugin `.mcp.json` — a plugin-provided
server would be namespaced `mcp__plugin_mem0-brady_mem0__*`, but the hooks, steer message, and
muscle memory all expect the canonical `mcp__mem0__*`. The plugin owns the hooks + setup; the MCP
registration is one line in `~/.claude.json`.

The MCP server (for the tools) and the hooks (for recall/capture) both read the same
`~/.config/mem0-brady/.env` and both connect to the vector store **over HTTP**. The store is a
**native Qdrant server binary** (no Docker) running under its own launchd agent. A server (rather
than an embedded on-disk store) is required because Qdrant's embedded mode takes an **exclusive
per-process lock** — it can't be shared by the MCP server, the hooks, concurrent Claude sessions,
and the Hal gateway at once. The server handles concurrent access cleanly.

## Digest: is the memory layer useful?

`/mem0-brady:digest` answers "did memory pull its weight?" by reporting both sides of the
ledger for a window:

- **Captures** — what got stored (explicit `add_memory` calls from the local op log, plus
  the Stop-hook session summaries pulled from the store, deduped).
- **Hook injections** — what the recall hooks (`SessionStart`, `UserPromptSubmit`,
  `Read` file-context) silently fed into context, with the **critical** ones highlighted:
  a prior decision, a gotcha, prior art on a file just opened. Routine steering/no-hit
  recalls are counted but not quoted.

**Scope is automatic.** Run it mid-session and it summarizes just *this* session (events
since the session marker's `started_at`); run it in a freshly-opened session and it
summarizes the whole calendar day. Force with `--session` / `--day`, or pass a
`YYYY-MM-DD`.

This is powered by two append-only logs under `~/.local/share/mem0-brady/logs/`:

| Log | Written by | Holds |
|-----|-----------|-------|
| `mem0_ops.log` | `PostToolUse(mcp__mem0__*)` hook | every explicit `add_memory` / `search_memories` call (TSV: ts + `{tool,session_id,input}`) |
| `mem0_recall.log` | the recall hooks (capture-tee-replay) | every hook injection (JSONL: `{ts,hook,session_id,app_id,chars,content}`) |
| `current_session.json` | `SessionStart` steer hook | marker for the most-recently-started session, so the digest can scope to it |

The recall hooks run the fork console script, **log what it injected, then replay its
exact output** — recall behaviour is unchanged, the logging is a fail-open side effect.
`mem0_recall.log` only starts filling on sessions that begin *after* this is installed.

## Workstreams

A **workstream** is one thread of work that spans multiple Claude sessions — spread across
time, commits, branches, and worktrees — under a single overarching goal. The Stop/PreCompact
handoff already captures *per-worktree* state (keyed by cwd); a workstream is the higher-level
thread that ties related worktrees together.

`/mem0-brady:workstream <slug>` **activates** a workstream for the current session:

- It maintains a **details doc** (`~/.local/share/mem0-brady/workstreams/<slug>.md`) — the
  source of truth, safe to hand-edit — holding the overarching **Goal** and a **Pieces** index.
  Each piece is a contributing worktree (cwd + branch) that *references* its own per-cwd handoff
  for current state. State is **referenced, never inlined**: you read a piece's handoff on
  demand, it is not auto-injected.
- It **tags the session** with an active pointer keyed on `session_id`
  (`workstreams/active/<session_id>.json`). Tagging is **manual and per-session** — a fresh
  session starts untagged, and the *only* way to tag it is running the skill (directly, or
  because a handoff said to). Activating in a worktree registers that worktree as a piece.

While a session is tagged, the fork's Stop / PreCompact hooks:

1. fold the workstream's overview (goal + sibling pieces) into the **handoff synthesis**, so
   each per-worktree recap is situated within the larger goal;
2. **bake a `/mem0-brady:workstream <slug>` call into the handoff**, so a session that resumes
   from it re-tags itself and pulls the workstream forward — the workstream rides the handoff
   chain across sessions and worktrees; and
3. tag the auto-captured session summary with `workstream_id`, so `/mem0-brady:digest` and
   passive recall can filter by workstream (the file doc stays the source of truth).

Beyond activation, ask "what workstream am I on" (show), or list / deactivate. The helper
(`scripts/workstream.py`, stdlib-only) does all file I/O deterministically.

**Per-session keying** depends on the skill learning the same `session_id` the Stop hook
reports. `steer.sh` writes a per-cwd SessionStart marker
(`~/.local/share/mem0-brady/sessions/<cwd-hash>.json`) for exactly this — the global
`current_session.json` can't serve it, since it's a single file overwritten by whichever
session started last. (`<cwd-hash>` is `sha1(cwd)[:8]`, the same scheme the handoff files use.)

## Install

1. **Add the marketplace** (once per machine):
   ```
   /plugin marketplace add brady-zip/bradys-marketplace
   ```
2. **Enable the plugin**:
   ```
   /plugin install mem0-brady@bradys-marketplace
   ```
3. **Run setup**:
   ```
   /mem0-brady:setup
   ```
4. **Register the MCP at the user level** (one line; keeps the `mcp__mem0__*` namespace):
   ```
   claude mcp add --transport http --scope user mem0 http://127.0.0.1:8788/mcp
   ```
   `--scope user` is required so mem0 loads in **every** project, not just the directory you
   ran the command from (without it, `claude mcp add` defaults to `local` scope). Then
   **restart your Claude Code session** so the MCP server and hooks attach.

Verify any time with:
```
/mem0-brady:doctor
```

## Requirements

- **macOS** (the servers run under launchd), Apple Silicon or Intel.
- An **OpenAI API key** (`sk-...`) in `~/.config/mem0-brady/.env`. It pays for memory extraction
  (LLM, `gpt-4o-mini`) and embeddings (`text-embedding-3-small`, 1536 dims). Setup reuses an
  existing key if present; otherwise it prompts.
- `curl`, `jq`, `tar` (setup checks for these; install with `brew install curl jq`).
- `uv` — setup installs it automatically if missing.
- Network access during setup (to download the Mem0 fork and the Qdrant binary). No Docker.

## Troubleshooting

Run `/mem0-brady:doctor` first — it pinpoints which layer is broken and prints the fix.

- **Qdrant not reachable on `:6433`** — check `~/.local/share/mem0-brady/qdrant.log`, then
  re-run `/mem0-brady:setup`.
- **MCP server not reachable on `:8788`** — check `~/.local/share/mem0-brady/server.log`, then
  re-run `/mem0-brady:setup`. (The server connects to Qdrant lazily on the first tool call, so
  Qdrant must be up first — setup orders them correctly.)
- **`mcp__mem0__*` tools missing** — confirm the user-level registration exists
  (`claude mcp list` should show `mem0 → http://127.0.0.1:8788/mcp`) and that you restarted the
  Claude session after setup.
- **Hooks not recalling/capturing** — hooks fail open (a missing key/install/store just skips
  recall/capture, never breaks a session). Confirm `~/.config/mem0-brady/.env` has your key
  via `/mem0-brady:doctor`.
- **Reset the launchd agents**:
  ```
  launchctl bootout gui/$(id -u)/com.mem0brady.server
  launchctl bootout gui/$(id -u)/com.mem0brady.qdrant
  /mem0-brady:setup
  ```

## What setup installs

| Path | What |
|------|------|
| `~/.local/bin/mem0-mcp-selfhosted` (+ `mem0-hook-*`) | uv-tool console scripts (the patched fork) |
| `~/.local/share/mem0-brady/bin/qdrant` | native Qdrant server binary (no Docker) |
| `~/.config/mem0-brady/.env` | config: key, models, MCP port, Qdrant URL, `shared-bch` (chmod 600) |
| `~/.local/share/mem0-brady/qdrant-storage` | Qdrant's on-disk data |
| `~/Library/LaunchAgents/com.mem0brady.qdrant.plist` | launchd agent running Qdrant (`:6433`) |
| `~/Library/LaunchAgents/com.mem0brady.server.plist` | launchd agent running the MCP server (`:8788`) |

Setup boots out any stale `com.mem0team.*` agents from the plugin's former name (`mem0-team`).

The fork is pinned to a tagged release: `github.com/brady-zip/mem0-mcp-selfhosted@v0.11.0`
(`app_id`-aware capture/recall, prompt/file-context/pre-compact lifecycle hooks, the
`general` default for untagged writes, resume handoffs that build on the previous handoff for
continuity, and workstream-aware handoffs that fold an active workstream's overview into the
recap and bake its re-activation call in). Qdrant is pinned to `v1.18.2` (prebuilt
`*-apple-darwin` binary from GitHub releases).
