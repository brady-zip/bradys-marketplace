---
description: List mem0-brady workstreams (open threads by default) with each one's goal and a short current state synthesized from its mem0 run scope — pass `all` or `archived` to see finished ones
argument-hint: "[all|archived — default: open workstreams only]"
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/workstream.py:*), mcp__mem0__list_entities, mcp__mem0__get_memories, mcp__mem0__search_memories
---

List the workstreams on this machine — every `~/.local/share/mem0-brady/workstreams/<slug>.md`
doc — each with its status, when it was last touched, its goal, and **a one-line current
state** synthesized from that workstream's mem0 run scope.

The goal comes from the doc and says what the thread is *for*; only the run scope knows where
it actually **got to**. A list of goals answers "what did I set out to do" — which is not the
question you open this list to ask.

A workstream's status is **active** (still being worked) or **archived** (finished). This shows
active only unless told otherwise, because a done thread should stop competing for attention
with the open ones.

Read-only throughout: it reads docs and memories, changes no status, and tags no session.

## 1. List the docs

Map `$ARGUMENTS` to the filter (`all` = active + archived, `archived` = finished only, omitted
= active only — pass it through when the user named one, else omit):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/workstream.py" list $ARGUMENTS
```

It prints one row per workstream, newest-touched first, then the run-scope slugs to fetch.

## 2. Find which run scopes actually hold history

One call, before fetching anything:

```
mcp__mem0__list_entities()
```

Its `runs` array is every run scope in the store with a memory count. Use it to fetch only the
slugs that have something to synthesize, and to catch the two ways a listed slug comes back
empty (see **Drift**, below).

## 3. Fetch and synthesize

For each listed workstream whose slug has a non-zero count, in **one parallel batch**:

```
mcp__mem0__get_memories(run_id="<slug>", limit=8)
```

Do **not** pass `app_id`. A workstream can span domains, and `run_id` is already the narrower
scope — adding `app_id` can only drop entries that belong to the thread.

Then write **≤1 sentence** per workstream: where the thread stands right now, favoring the most
recent entries — what just landed, what's in flight, what's blocked. Not a summary of the goal
(already in the row) and not a history. If the entries don't support a claim about current
state, say `(history exists, no clear current state)` rather than inventing one.

Cap the batch at **8 fetches**. If more workstreams qualify, take the 8 most recently updated
and say plainly which ones you skipped.

## 4. Render

A table, most-recently-updated first:

| Workstream | Updated | Current state | Goal |

Mark archived rows. Keep Goal to a clause — the current state is the column the user is reading.
For workstreams with no run-scope history, put `(no run-scoped history)` in Current state.

## Drift: an empty run scope is a finding, not a blank cell

A listed slug with no memories means one of two things, and they need different responses:

- **Never tagged.** The work happened in sessions that weren't activated, so nothing was
  stamped. Say so — activating is what makes a thread resumable, and the fix is going forward.
- **The history is under a different name.** The doc slug and the run scope are set
  independently, so they drift. If `list_entities` shows a run scope with no matching doc but
  an obviously related name, point at it explicitly and offer to reconcile — either rename the
  doc to match the run scope, or keep both and note the run scope in the doc's References.

Also call out the reverse: run scopes in `list_entities` with **no workstream doc at all**,
especially high-count ones. That is accumulated narrative for a thread nobody can list, and
usually means a workstream that should exist doesn't.

## Following up

The listing is not the state of the work — it is a one-line read on it. To go deeper on one:
`mcp__mem0__search_memories(query="<question>", run_id="<slug>")`, or read a piece's handoff
from the doc's **Pieces** index. To resume one, `/mem0-brady:workstream <slug>` — that tags
this session, which is also what turns the handoff back on. If several rows are plainly
finished, offer to archive them (`workstream.py archive <slug>`).
