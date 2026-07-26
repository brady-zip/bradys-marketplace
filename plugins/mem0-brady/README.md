# mem0-brady

B's personal self-hosted [Mem0](https://github.com/mem0ai/mem0) backbone, packaged as a Claude
Code plugin. It is the **single memory store shared by both Claude Code and Hal** — one
Qdrant, one namespace, so the two actors cross-query each other's memories.

Which Qdrant and which namespace are **per-install**, chosen at setup and recorded in
`~/.config/mem0-brady/.env` — they are not baked into the plugin. Point two machines at the
same values and they share one memory; see [Stacks](#stacks-managed-vs-external).

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
- **`/mem0-brady:migrate`** — move a store between stacks, or merge a second machine's
  memories into a shared one. Vectors are copied **verbatim** (no re-embedding, so no OpenAI
  spend and no chance of the fact-extractor rewording a memory in transit), point ids are
  preserved and memories deduped by content hash, so import is idempotent and a partial run
  is resumable. Export/import is file-based on purpose: the two Qdrants normally live on
  different machines, each bound to its own loopback. The source is never modified.
- **`workstream` skill** — `/mem0-brady:workstream <slug>` groups multi-session work (spread
  across commits, branches, and worktrees) under one overarching goal: it tags the session,
  maintains a referenceable details doc, and makes the Stop/PreCompact handoffs
  workstream-aware so the workstream propagates to future sessions. See
  [Workstreams](#workstreams).

(This replaced a Honcho-based passive layer — Mem0 now owns the implicit capture too.)

Under the default **managed** stack everything runs locally with no Docker: a native Qdrant
server binary and the MCP server, both under launchd. If you already run Qdrant and the MCP
server yourself, choose the **external** stack instead and the plugin installs neither.

## Stacks: managed vs external

`MEM0_BRADY_STACK` in `~/.config/mem0-brady/.env` decides how much of the stack the plugin owns.

| | `managed` (default) | `external` |
|---|---|---|
| Qdrant | native binary under launchd, ports from config (default `6433`/`6434`) | yours, never contacted from the host |
| MCP server | launchd, port from config (default `8788`) | yours |
| how hooks reach mem0 | in-process (`mem0.Memory`) | through the MCP server |
| setup installs | console scripts + mem0 + models, Qdrant binary, 2 launchd agents | an MCP client and a two-line config |
| host needs an API key | yes | **no** — the server holds it |
| install size | multi-GB (mem0ai, torch, spaCy, fastembed) | ~70MB |

On `external`, the hooks drive mem0 **through the server**, so the server owns the Qdrant URL,
the collection, the `user_id`, the embedding model and the API key. None of them are configured
on the host — a duplicate would just be a second copy to keep in sync, and a stale one fails
by quietly reading a different store. The whole config is:

```
MEM0_BRADY_STACK=external
MEM0_BRADY_MCP_URL=http://127.0.0.1:8081/mcp
```

Hooks fail **open**: a slow or unreachable server skips recall/capture and lets the session
continue, rather than blocking it.

Moving between stacks — or merging a second machine's memories into one shared store — is
`/mem0-brady:migrate`. Setup refuses to switch an install to `external` while managed-stack
data is still sitting there unmigrated.

## Memory model: one store, partitioned by `app_id`

There is **one** `user_id` (`MEM0_USER_ID`, whatever this install set it to) that every actor
reads and writes. Memory is partitioned into domains by an `app_id` tag, kept in the Qdrant
payload:

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
Claude Code ──(user-level mcpServers, http)──► MEM0_BRADY_MCP_URL
                                       │  managed: launchd com.mem0brady.server
                                       │  (uv-tool-installed mem0-mcp-selfhosted)
                                       │  external: your own server
                                       │
Claude hooks (this plugin):            │
  SessionStart(startup|compact) ─► run-context.sh ─► mem0-hook-context (recall) ─┐
  Stop                          ─► run-stop.sh    ─► mem0-hook-stop    (capture) ─┤
                                       │                                          │
Hal / Hermes (mem0_selfhosted         │                                          │
  provider) ──────────────────────────┤                                          │
                                       ▼                                          ▼
                                  Qdrant at MEM0_QDRANT_URL  ◄──────────────────────┘
                                  managed: native binary, launchd com.mem0brady.qdrant
                                  external: yours (must be published on the host)
                                  collection + user_id per install (see .env)

Config (single source of truth): ~/.config/mem0-brady/.env
```

The `mcp__mem0__*` tools are registered at the **user level** (`~/.claude.json` →
`mcpServers.mem0` → your `MEM0_BRADY_MCP_URL`), not via a plugin `.mcp.json` — a plugin-provided
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
| `mem0_denials.log` | `PreToolUse(mcp__mem0__*)` guard (`enforce-metadata.sh`) | every guard action (TSV: ts + `{tool,session_id,outcome,detail,input_keys}`) — an auto-injected `app_id` or a denied non-shared `user_id`. These never reach `mem0_ops.log`, because a PreToolUse deny/inject never triggers PostToolUse |
| `current_session.json` | `SessionStart` steer hook | marker for the most-recently-started session, so the digest can scope to it |

The recall hooks run the fork console script, **log what it injected, then replay its
exact output** — recall behaviour is unchanged, the logging is a fail-open side effect.
`mem0_recall.log` only starts filling on sessions that begin *after* this is installed.

The `enforce-metadata.sh` write guard keeps every `add_memory` in the right partition. A
missing `app_id` is **auto-injected** from the session cwd's domain (via PreToolUse
`updatedInput`) rather than bounced back to the model — so a write can't silently misfile into
`general` when the session is in another domain. A pinned non-shared `user_id` is still denied
(it would fragment the shared store). Both actions are audited to `mem0_denials.log`.

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
   A first run asks which stack backs this install (`managed` / `external`) and what store
   to point at — collection, `user_id`, Qdrant URL, MCP URL. Later runs read those answers
   back out of the config and stay silent. The config is **merged**, never overwritten, so
   hand-edits survive.
4. **Register the MCP at the user level** (one line; keeps the `mcp__mem0__*` namespace).
   Setup prints the exact command with your URL filled in:
   ```
   claude mcp add --transport http --scope user mem0 <MEM0_BRADY_MCP_URL>
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

- **Qdrant not reachable** — managed only: check `~/.local/share/mem0-brady/qdrant.log`, then
  re-run `/mem0-brady:setup`. An external install never contacts Qdrant from the host, so this
  cannot be your problem there; check the MCP server instead.
- **MCP server not reachable** — managed: check `~/.local/share/mem0-brady/server.log`, then
  re-run `/mem0-brady:setup`. (The server connects to Qdrant lazily on the first tool call, so
  Qdrant must be up first — setup orders them correctly.) External: start your own server.
- **Recall is silently empty but doctor is green** — check that `MEM0_COLLECTION` and
  `MEM0_USER_ID` name the store your memories are actually in; `/mem0-brady:migrate inspect`
  lists the namespaces and domains present in a collection.
- **`mcp__mem0__*` tools missing** — confirm the user-level registration exists (`claude mcp
  list` should show `mem0 →` your MCP URL) and that you restarted the Claude session after
  setup. Note the hooks match the `mcp__mem0__.*` prefix exactly: a server registered under
  another name (or reached as a remote connector, which namespaces differently) will work as
  a tool but the `app_id` write guard and the digest's op log won't fire for it.
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

| Path | What | Stack |
|------|------|-------|
| `~/.local/bin/mem0-mcp-selfhosted` (+ `mem0-hook-*`) | uv-tool console scripts (the patched fork) | both |
| `~/.config/mem0-brady/.env` | config: key, models, stack, collection, `user_id`, URLs, ports (chmod 600) | both |
| `~/.local/share/mem0-brady/bin/qdrant` | native Qdrant server binary (no Docker) | managed |
| `~/.local/share/mem0-brady/qdrant-storage` | Qdrant's on-disk data | managed |
| `~/Library/LaunchAgents/com.mem0brady.qdrant.plist` | launchd agent running Qdrant | managed |
| `~/Library/LaunchAgents/com.mem0brady.server.plist` | launchd agent running the MCP server | managed |

Setup boots out any stale `com.mem0team.*` agents from the plugin's former name (`mem0-team`).

The fork is pinned to a tagged release: `github.com/brady-zip/mem0-mcp-selfhosted@v0.11.0`
(`app_id`-aware capture/recall, prompt/file-context/pre-compact lifecycle hooks, the
`general` default for untagged writes, resume handoffs that build on the previous handoff for
continuity, and workstream-aware handoffs that fold an active workstream's overview into the
recap and bake its re-activation call in). Qdrant is pinned to `v1.18.2` (prebuilt
`*-apple-darwin` binary from GitHub releases).
