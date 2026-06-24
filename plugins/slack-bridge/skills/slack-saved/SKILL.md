---
name: slack-saved
description: Triage the user's Slack "Later" (saved-for-later) list into a chat digest — what still needs followup vs what's gone stale, grouped by theme, overdue items called out. Use when the user asks about their "saved for later", "Later list", "saved Slack messages", "Slack followups", "what did I save in Slack", "/slack-saved", or wants to work through / clear their Slack saved items. Reads Slack's real saved.list via browser session tokens. Distinct from /slack-triage, which handles UNREAD, not saved.
---

# Slack saved-for-later digest

Turn the user's Slack **"Later"** list (deliberately saved items, often needing followup) into a
**chat digest**: grouped by theme, with the items that still look actionable surfaced and the
stale majority flagged for clearing. Overdue items (a `date_due` in the past) are called out.

This is **not** `/slack-triage` — that command handles *unread* (`activity.feed`). Saved items
are a separate Slack feature: an unread @mention vanishes once read; a saved item stays until the
user completes or archives it. People save things precisely because they meant to come back.

Ships with the **slack-bridge** plugin; shares its Slack client and session tokens. `$S` =
`${CLAUDE_PLUGIN_ROOT}/skills/slack-saved`. The fetch script runs with `uv run` (PEP 723, stdlib).

## Steps

1. Fetch the hydrated saved list (read-only):
   ```bash
   uv run "$S/fetch_saved.py" --json > /tmp/slack-saved.json     # in-progress backlog
   # add --all to also include completed + archived items
   ```
   If it errors `No Slack tokens found` / `auth failed` → run `${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh`.

   Each item: `channel_label`, `channel_id`, `author`, `text`, `ts`, `permalink`, `state`,
   `date_created` (when saved), `date_due` (reminder, 0 if none), `date_completed`, `item_id`,
   `item_type`. `item_id` == `channel_id` for messages (needed to mark done / archive).

   The fetch **auto-hides items you snoozed to a future date** and reports `snoozed_hidden`; items
   you decided on before are tagged `prior_decision` (e.g. a `keep` from last run). Pass
   `--include-snoozed` to see snoozed ones too.

2. **Triage into tiers** — read the items (spawn a subagent to read `/tmp/slack-saved.json` if the
   list is large) and split them. Judge on content + recency (`date_due` is auto-assigned by
   Slack and almost always lapsed — do NOT use it as a priority signal):
   - **🔴 Still actionable** — needs the user to do something: a direct question/ask to them, a PR
     awaiting their review/response, a pending decision, a task they saved to act on.
   - **🟡 Worth a look** — reference/context they saved intentionally, no hard pending action.
   - **⚪ Likely stale** — the moment has passed: old announcements/FYIs, resolved/superseded
     threads, bot posts, very old saves with no live ask.

   Present a short digest (counts + themed summary). 🔴+🟡 are the **keep-set** (the worklist);
   ⚪ is the **clear-set**.

3. **Clear the stale (⚪)** — offer to bulk-**archive** the clear-set (confirm first; archiving is
   reversible). For a large clear-set, archive on a trickle (random gaps, e.g. spread over ~10
   min) rather than a burst, to avoid rate limits. Keepers are matched on `(item_id, ts)` pairs
   so messages sharing a channel with stale ones are never swept up.

4. **Work the keep-set one-by-one** — this is the point of the skill: turn 🔴+🟡 into concrete
   next steps. **Plan → auto-clear obvious → walk the rest.**

   a. **Ground each keeper with live state** (don't recommend blind):
      - **PR links** in the text (`github.com/Greenbax/evergreen/pull/N` or `#NNNNN`): run
        `gh pr view N --repo Greenbax/evergreen --json state,reviewDecision,mergedAt,title,reviewRequests`.
        Open + you're a requested reviewer / not yet reviewed → **REVIEW**; merged/closed → **DONE/ARCHIVE**.
      - **Questions / asks**: call the `read_thread(channel_id, ts)` MCP tool. `replied_by_me` true
        or clearly resolved downstream → **DONE**; still unanswered & aimed at you → **REPLY**.
      - Otherwise judge from text + age.
      Enrich efficiently — for many items, spawn a subagent that returns the enriched plan (run
      the `gh` lookups in parallel).

   b. **Present the ACTION PLAN** — every keeper grouped by recommended **disposition**, each a
      one-line specific next step:

      Every disposition is **persisted** via `record_decision` so decisions survive across runs:

      | Disposition | Meaning → action + durable record |
      |---|---|
      | **REPLY** | needs your response → open `permalink`; `record_decision(item_id, ts, "reply")` |
      | **REVIEW** | PR open, awaiting you → open the PR; `record_decision(..., "review")` |
      | **DO** | external task (e.g. update Linear) → open/note; `record_decision(..., "do")` |
      | **DONE** | already handled → `complete_saved(item_id, ts)` + `record_decision(..., "done")` |
      | **ARCHIVE** | no longer relevant → `remove_saved(item_id, ts)` + `record_decision(..., "archive")` |
      | **SNOOZE** | revisit later → `record_decision(item_id, ts, "snooze", snooze_until=<unix>)` — **hidden until that date**; optionally also `snooze_saved(...)` to set Slack's own reminder |
      | **KEEP** | leave as-is → `record_decision(..., "keep")` |

      For **SNOOZE**, convert the user's phrasing ("snooze a week", "next Monday") into a unix
      timestamp relative to today and pass it as `snooze_until`. The bulk auto-clear in (c) records
      its DONE/ARCHIVE decisions too.

   c. **Auto-clear the unambiguous** on the user's OK: bulk `complete_saved` the DONE set and
      `remove_saved` the ARCHIVE set (these are mechanical — no per-item decision needed).

   d. **Walk the rest one at a time** (REPLY / REVIEW / DO and anything ambiguous). For each, show:
      `[i/N] tier · #channel · author (saved Nd) — gist + grounded finding → NEXT: <step>` and offer
      `[ open · mark done · archive · snooze · skip ]`. Act on the choice via the tools below, then
      advance. Keep it tight; this is a worklist, not a conversation.

## Acting on items (writes — confirm first)

Clearing/changing items mutates the user's Later list, so **confirm before mutating** (bulk steps
get one confirmation; per-item steps act on the user's choice). slack-bridge MCP tools:
- `complete_saved(item_id, ts)` — mark **done** (`saved.update mark=completed`).
- `remove_saved(item_id, ts)` — **archive** (`saved.update mark=archived`; Slack has no hard delete).
- `add_saved(channel_id, ts)` — save a new message to Later.
- `snooze_saved(item_id, ts, until)` — set Slack's own reminder date (optional; the store drives suppression).
- `read_thread(channel_id, ts)` — read a thread to check if a saved item was already answered (grounding).
- `record_decision(item_id, ts, decision, snooze_until=…, note=…)` — **persist** the decision (durable store).

## Durable decision store

Decisions are written to `~/.config/slack-bridge/saved-decisions.json` (override
`$SLACK_BRIDGE_DECISIONS`), keyed by `item_id:ts`, via `record_decision`. This makes the worklist
**stateful across runs**:
- **Snooze** records `snooze_until`; the item is hidden from the fetch/`list_saved` until that
  date, then resurfaces automatically. (Snooze is a *local* suppression — it doesn't depend on
  Slack archiving the item.)
- Other decisions (`done`/`archive`/`keep`/`reply`/`review`/`do`) are kept as an audit trail; an
  item that reappears shows its `prior_decision` so you can skip re-triaging it.
Inspect the store anytime: `uv run ${CLAUDE_PLUGIN_ROOT}/server/decisions.py`.

(`item_id` == `channel_id` and `ts` come straight from the fetched rows.) If Slack rejects a field,
report it rather than retrying blindly. slack-bridge does NOT send messages — for **REPLY** items,
open the `permalink` (or use the separate Slack MCP if available).

## Notes / gotchas

- `saved.list` caps `limit` at 50 (higher → `invalid_arguments`) and paginates via
  `response_metadata.next_cursor`; the shared client handles both. The response key is
  `saved_items` (not `items`).
- The "in-progress" count should match Slack's own **Later** badge.
- Same auth + expiry behavior as the rest of slack-bridge (session tokens; re-grab on SSO
  refresh).
