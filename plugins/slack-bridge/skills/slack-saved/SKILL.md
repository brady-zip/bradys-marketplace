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
     Includes **TL;DRs / summaries / notes** the user saved to *remember* (recaps, decisions, design
     writeups) — in the second pass these become **save-to-memory** candidates, not just "read again".
   - **⚪ Likely stale** — the moment has passed: old announcements/FYIs, resolved/superseded
     threads, bot posts, very old saves with no live ask.

   Present a short digest (counts + themed summary). 🔴+🟡 are the **keep-set** (the worklist);
   ⚪ is the **clear-set**.

3. **Clear the stale (⚪)** — offer to bulk-**archive** the clear-set (confirm first; archiving is
   reversible). For a large clear-set, archive on a trickle (random gaps, e.g. spread over ~10
   min) rather than a burst, to avoid rate limits. Keepers are matched on `(item_id, ts)` pairs
   so messages sharing a channel with stale ones are never swept up.

4. **Work the keep-set one message at a time** (second pass) — this is the point of the skill. The
   first pass bucketed and made **one overarching call** (clear the stale). The second pass is the
   opposite: **no grouped action plan, no bulk auto-clear.** Walk the keep-set (🔴 first, then 🟡)
   **one item at a time** — ground each, recommend a single next action from the **action bank**,
   act on the user's choice, then advance.

   a. **Ground the keepers first** so the walk is fast, not blind. Do this for all keepers up front —
      ideally one subagent that runs the lookups in parallel and returns the enriched list. Grounding
      is enrichment, not action; only *acting* stays strictly one-by-one.
      - **PR links** (`github.com/Greenbax/evergreen/pull/N` or `#NNNNN`):
        `gh pr view N --repo Greenbax/evergreen --json state,reviewDecision,mergedAt,title,reviewRequests`.
        Open + you're a requested reviewer / not yet reviewed → lean **Review PR**; merged/closed →
        lean **done / archive**.
      - **Questions / asks**: `read_thread(channel_id, ts)`. `replied_by_me` true or clearly resolved
        downstream → lean **done**; still unanswered & aimed at you → lean **draft a response**.
      - **TL;DRs / summaries / notes** (the item *is* a recap — meeting notes, a decision summary, a
        "TL;DR:" writeup, a reference snippet — not an ask) → lean **save to memory**.
      - A task the user clearly meant to act on → lean **Linear ticket** (track it) or **handoff**
        (start implementing now); otherwise judge from text + age.

   b. **Walk one item at a time.** For each keeper, show a single compact card and stop for the user:

      ```
      [i/N] 🔴 · #channel · author · saved 6d ago
      gist: <one line> — <grounded finding, e.g. "PR #82910 open, you're a requested reviewer">
      → recommend: Review PR
      [ open · draft reply · review PR · linear ticket · handoff · save to memory · done · archive · snooze · skip ]
      ```

      Surface only the menu entries that fit the item (don't offer "review PR" on a non-PR). Pick the
      **one** recommended action from the action bank below; the user can override with any entry.
      Execute the choice, **persist it** with `record_decision`, then advance to `[i+1/N]`. Keep it
      tight — this is a worklist, not a conversation.

## Action bank (per-item, second pass)

Recommend exactly **one** action per keeper. Every action ends with a durable `record_decision` so
the item won't resurface (snooze excepted — it resurfaces on its date).

| When the item is… | Recommend | How to execute | Record |
|---|---|---|---|
| a question/ask still aimed at you | **Draft a response** | Compose a suggested reply in chat (match the author's tone, keep it short). slack-bridge can't post — open the `permalink` to paste it, or send via the Slack MCP if one is available. | `record_decision(item_id, ts, "reply")` |
| an open PR awaiting your review | **Review PR** | Invoke the **`/review`** skill on the PR URL/number — it reviews the remote PR, no local checkout needed. | `record_decision(..., "review")` |
| an actionable task/bug worth tracking | **Create Linear ticket** | Run the Linear sub-flow ↓. | `record_decision(..., "do", note="<ticket URL>")` |
| a task you want to start implementing now | **Implement (handoff)** | Invoke the **`handoff`** skill to spin up an implementation handoff. If it isn't installed, tell the user to add it: `npx skills add https://github.com/mattpocock/skills --skill handoff`, then continue. | `record_decision(..., "do")` |
| a TL;DR / summary / notes / reference fact | **Save to memory** | Save the gist via mem0 (`mcp__mem0__add_memory`, `app_id="general"`). If the mem0 tools aren't available, tell the user to install the **mem0-brady** plugin, then continue. Once saved, the item is captured → `complete_saved`. | `record_decision(..., "done", note="saved to memory")` |
| already handled / resolved | **Mark done** | `complete_saved(item_id, ts)`. | `record_decision(..., "done")` |
| no longer relevant | **Archive** | `remove_saved(item_id, ts)`. | `record_decision(..., "archive")` |
| not now, but later | **Snooze** | Convert "a week" / "next Monday" to a unix ts relative to today; optionally `snooze_saved(item_id, ts, until)` to set Slack's own reminder. Hidden until then. | `record_decision(..., "snooze", snooze_until=<unix>)` |
| worth keeping as-is | **Keep** | leave it untouched. | `record_decision(..., "keep")` |

**Create Linear ticket sub-flow** (uses the Linear MCP):
1. **Draft** a title + description from the message and any grounded thread context; put the Slack
   `permalink` in the description so the ticket links back.
2. **Pick the project**: infer the best-matching project from the message content / channel via
   `mcp__plugin_linear_linear__list_projects`, and show it for one-tap confirmation — the user can
   override. (Resolve the project's team for the create call.)
3. **Confirm, then create** with `mcp__plugin_linear_linear__save_issue` (title, description, chosen
   project + team). Report the new issue URL back and pass it as the `record_decision` note.

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
