---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree, while challenging it against everything already learned about this project and persisting resolved terms and decisions to Mem0 (via the mem0 MCP server) inline. Memory is the single source of truth — no CONTEXT.md or ADR files are written. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

# Grill with Mem0

A fork of `grill-with-docs` that swaps file-based docs (CONTEXT.md + ADRs) for a
Mem0-backed memory store. Resolved glossary terms and durable decisions are
written to Mem0 through the self-hosted `mem0` MCP server and recalled across
sessions by semantic search — no files are created on disk.

<precheck>

Before doing anything else, verify Mem0 is reachable:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-mem0.sh"
```

If the script exits non-zero, **stop** and relay its remediation hints to the
user. Do not fall back to writing CONTEXT.md / ADR files — for this skill, Mem0
is the persistence layer, and without it there is nowhere to record what the
session resolves.

</precheck>

<memory-tools>

Memories are persisted to a self-hosted Mem0 server (Qdrant-backed) exposed as
the `mem0` MCP server. It surfaces these tools under the `mcp__mem0__*`
namespace:

- `mcp__mem0__add_memory` — store a new memory (`text` arg; Mem0 extracts the
  salient facts by default)
- `mcp__mem0__search_memories` — semantic search over stored memories (`query` arg)
- `mcp__mem0__get_memories` — page through stored memories by filter
- `mcp__mem0__delete_memory` — delete a single memory by id (use when superseding
  a stale entry)

If the server was registered under a different name, the prefix differs — use
whichever `*add_memory` / `*search_memories` / `*get_memories` tools the precheck
confirmed are available.

**Always pass `app_id` (the domain partition).** Mem0 is partitioned into three
domains: `evergreen` (work in the evergreen repo + its worktrees), `general`
(Claude tooling, customizations, and everything else), and `hal-ops` (Hal's own
ops — written by Hal, not by Claude grill-me sessions). The SessionStart steer
states this Claude session's domain (`app_id='evergreen'` or `app_id='general'`).
Pass that `app_id` on **every** `add_memory`, and filter **every**
`search_memories` / `get_memories` with the same `app_id`, so a glossary built in
one domain never bleeds into another. (A PreToolUse guard rejects an `add_memory`
that omits `app_id`.) `app_id` is the coarse domain; the `[<project-key>]` text
prefix below is the fine-grained cluster within it. Store resolved terms/decisions
with `infer=false` so they're kept verbatim, not re-paraphrased into near-dupes.

</memory-tools>

<what-to-do>

Interview me relentlessly about every aspect of this plan until we reach a
shared understanding. Walk down each branch of the design tree, resolving
dependencies between decisions one-by-one. For each question, provide your
recommended answer.

Ask the questions one at a time, waiting for feedback on each question before
continuing.

If a question can be answered by exploring the codebase, explore the codebase
instead.

</what-to-do>

<supporting-info>

## Load prior context first

Before the first question, recall what's already known about this project:

1. Derive a short **project key** for scoping (default: the repo's directory
   name, e.g. `local-marketplace`). Use it consistently so memories cluster.
2. Call `search_memories` with the plan's central nouns and the project key to
   pull back existing glossary terms and decisions. Always pass `app_id` set to
   this session's domain (from the SessionStart steer) so recall stays in-domain.
3. Briefly summarise what you recalled so the user sees the starting point, then
   grill from there. Treat recalled memories as *what was true when written* —
   if a recalled term or decision contradicts the current plan or the code,
   surface the conflict rather than assuming the memory is still correct.

This recall step is the whole point of the Mem0 backing: a glossary built up in
a previous session is available again here.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with one already in memory, call it out
immediately. "Memory says 'cancellation' means X, but you seem to mean Y —
which is it?" If they confirm the new meaning, update the stored memory (see
below) rather than leaving two contradictory entries.

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term.
"You're saying 'account' — do you mean the Customer or the User? Those are
different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific
scenarios. Invent scenarios that probe edge cases and force the user to be
precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you
find a contradiction, surface it: "Your code cancels entire Orders, but you just
said partial cancellation is possible — which is right?"

### Persist resolved terms inline

When a term is resolved, write it to Mem0 right then with `add_memory`, passing
`app_id` set to this session's domain. Don't batch — capture each as it happens.
Before writing, `search_memories` (with the same `app_id`) for the term to avoid
duplicates: if a near-identical memory exists, update it (delete the stale one
with `delete_memory`, or store the corrected version and note it supersedes the
prior understanding) instead of adding a second. Use the glossary format in
[MEMORY-FORMAT.md](./MEMORY-FORMAT.md).

Memory holds the glossary and decisions only — keep it devoid of transient
implementation scratch. It is a glossary plus a decision log, nothing else.

### Persist decisions sparingly

Only record a decision memory when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip it. Use the decision format in
[MEMORY-FORMAT.md](./MEMORY-FORMAT.md).

</supporting-info>
