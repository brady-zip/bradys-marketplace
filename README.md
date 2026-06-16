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

## Install

1. **Add the marketplace** (once per machine):
   ```
   /plugin marketplace add brady-zip/mem0-brady
   ```
2. **Enable the plugin**:
   ```
   /plugin install mem0-brady@mem0-brady
   ```
3. **Run setup**:
   ```
   /mem0-brady:setup
   ```
4. **Register the MCP at the user level** (one line; keeps the `mcp__mem0__*` namespace):
   ```
   claude mcp add --transport http mem0 http://127.0.0.1:8788/mcp
   ```
   Then **restart your Claude Code session** so the MCP server and hooks attach.

Verify any time with:
```
/mem0-brady:doctor
```

## Embedding & reranking provider

Setup asks which provider should do **embeddings + reranking**:

| Provider | Embedder | Reranker | Key |
|----------|----------|----------|-----|
| `openai` (default) | `text-embedding-3-small` (1536 dims) | none | `OPENAI_API_KEY` |
| `zeroentropy` | `zembed-1` (2560 dims, Matryoshka) | `zerank-1` | `ZEROENTROPY_API_KEY` |

The **LLM that extracts facts is always OpenAI** (`gpt-4o-mini`) — ZeroEntropy doesn't offer an
LLM — so an `OPENAI_API_KEY` is required either way. Picking `zeroentropy` swaps the embedder to
[ZeroEntropy's](https://zeroentropy.dev) `zembed-1` and adds a `zerank-1` reranking pass over
recall hits before they reach the model; it bills those to your `ZEROENTROPY_API_KEY`.

> ZeroEntropy's key env var is spelled two ways in the wild — the SDK reads `ZEROENTROPY_API_KEY`
> while Mem0's reranker wrapper reads `ZERO_ENTROPY_API_KEY`. The rendered `.env` sets **both** to
> the same value so neither path breaks.

This plugin owns the **config contract** (the `MEM0_EMBED_PROVIDER` / `MEM0_RERANK_PROVIDER` /
`MEM0_RERANK_MODEL` env vars and the keys above). The runtime support lives in the pinned Mem0
fork: Mem0 ships a first-party `zero_entropy` reranker, and the fork wires `zembed-1` as the
embedder when `MEM0_EMBED_PROVIDER=zeroentropy`. Make sure the fork ref you install honors these.

A collection's vector size is fixed when it's created, so **switching providers changes
`MEM0_EMBED_DIMS` and needs a fresh collection**. To switch, stop the agents, wipe the store, and
re-run setup:

```
launchctl bootout gui/$(id -u)/com.mem0brady.server
launchctl bootout gui/$(id -u)/com.mem0brady.qdrant
rm -rf ~/.local/share/mem0-brady/qdrant-storage
/mem0-brady:setup
```

## Requirements

- **macOS** (the servers run under launchd), Apple Silicon or Intel.
- An **OpenAI API key** (`sk-...`) in `~/.config/mem0-brady/.env` — always required for the LLM
  (`gpt-4o-mini`) that extracts facts, and for embeddings (`text-embedding-3-small`) when the
  provider is `openai`. Setup reuses an existing key if present; otherwise it prompts.
- A **ZeroEntropy API key** *only if* you pick the `zeroentropy` provider (embeddings +
  reranking). Setup prompts for it and reuses it on re-runs.
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
| `~/.config/mem0-brady/.env` | config: keys, embedding/reranking provider + models, MCP port, Qdrant URL, `shared-bch` (chmod 600) |
| `~/.local/share/mem0-brady/qdrant-storage` | Qdrant's on-disk data |
| `~/Library/LaunchAgents/com.mem0brady.qdrant.plist` | launchd agent running Qdrant (`:6433`) |
| `~/Library/LaunchAgents/com.mem0brady.server.plist` | launchd agent running the MCP server (`:8788`) |

Setup boots out any stale `com.mem0team.*` agents from the plugin's former name (`mem0-team`).

The fork is pinned to a tagged release: `github.com/brady-zip/mem0-mcp-selfhosted@v0.6.1`
(`app_id`-aware capture/recall, prompt/file-context/pre-compact lifecycle hooks, and the
`general` default for untagged writes). Qdrant is pinned to `v1.18.2` (prebuilt
`*-apple-darwin` binary from GitHub releases).
