---
description: Summarize mem0-brady activity — captures stored and the critical context the recall hooks injected (this session if ongoing, else the whole day)
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh:*), mcp__mem0__get_memories, mcp__mem0__search_memories
---

Produce a digest of what mem0-brady did — proof that the memory integration is earning
its keep. Two halves: **what got captured** and **what the recall hooks injected** (and
which injections actually mattered).

## 1. Gather the local signal

Run the digest script and read its output:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh
```

It auto-picks scope and prints a header (`SCOPE`, `DAY`, `CURRENT_SESSION`,
`SESSION_DOMAIN`, `SESSION_STARTED`) plus three sections: `CAPTURES` (explicit
`add_memory`), `SEARCHES` (explicit `search_memories`), and `HOOK INJECTIONS` (what the
SessionStart / prompt / filecontext recall hooks fed into context, with an
`INJECTION_TALLY`).

- **`SCOPE: session`** → summarize just the current ongoing session (events since
  `SESSION_STARTED`).
- **`SCOPE: day`** → summarize the whole calendar `DAY` (the command was run in a
  fresh session).
- The user may pass `--day`, `--session`, or a `YYYY-MM-DD` date; forward it verbatim to
  the script.

## 2. Add what the script can't see

The script only knows about explicit tool calls and hook injections. **Stop-hook session
summaries are written straight to the store, not via MCP**, so they're absent from the
local logs. Pull them from the store to complete the capture picture:

- Call `mcp__mem0__get_memories` with `app_id=<SESSION_DOMAIN>`, then keep only memories
  whose `created_at` falls in the reported window (for `session` scope, at/after
  `SESSION_STARTED`; for `day` scope, the calendar `DAY`). These are what actually
  persisted — including the auto-captured summaries.

## 3. Report

Write a tight digest, no raw log dumps:

- **Scope line** — "This session (since 2:00pm)" or "Today (2026-06-16)".
- **Captured** — what was stored, grouped by topic/`run_id`, one line each. Reconcile the
  explicit `CAPTURES` with the store memories from step 2 so Stop-hook summaries are
  included and duplicates collapsed. If nothing was captured, say so plainly.
- **Critical injections** — the headline. From `HOOK INJECTIONS`, surface the ones that
  *materially shaped work*: a prior decision, a gotcha/blocker, prior art on a file just
  opened. For each, give one line: `hook → what it surfaced → why it mattered`. Read full
  content from `RECALL_LOG` if a preview is truncated and you need it. Explicitly set
  aside routine/boilerplate injections (the once-per-session steering rubric, generic
  no-hit recalls) — count them, don't quote them.
- **Verdict** — one or two sentences: did memory earn its keep this scope? Did injected
  recall actually feed into the work, and did captures preserve real state worth keeping?
  Be honest — "low signal today" is a valid and useful finding.

Keep it skimmable. The point is a fast, trustworthy read on whether the memory layer is
pulling its weight — not an exhaustive transcript.
