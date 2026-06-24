---
name: slack-unwrapped
description: A "Slack Unwrapped" stats recap — a fun, Wrapped-style summary of the user's Slack life from everything slack-bridge can see: saved/Later backlog, unread snapshot, busiest channels & people, pending scheduled messages, and decisions logged via /slack-saved. Use when the user asks for "slack unwrapped", "slack wrapped", "slack stats", "slack recap", "my slack activity/numbers", or "/slack-unwrapped".
---

# Slack Unwrapped

Produce a playful, scannable recap of the user's Slack life. Read-only — it just counts.

## Steps

1. Gather the numbers:
   ```bash
   uv run "${CLAUDE_PLUGIN_ROOT}/skills/slack-unwrapped/stats.py"
   ```
   Returns JSON: `saved` (in_progress / completed / archived / total, oldest in-progress age,
   overdue count, top_channels), `unread` (total, by_category, top_channels, top_authors),
   `scheduled_pending`, and `decisions` (logged_total, by_decision, logged_last_7d/24h,
   active_snoozes). If it returns `{"error": …}` → tokens issue; point the user to `/slack-setup`.

2. Narrate it as **Slack Unwrapped** 📊 — punchy, emoji-friendly, a few headline stats then the
   fun details. Adapt to the actual numbers; don't force sections that are empty. Suggested beats:
   - **Headline**: the Later backlog story — "X cleared (archived), Y still on your plate" (archived
     vs in_progress), and the oldest-still-open age ("your oldest open save is N days old 👀").
   - **Busiest places/people**: top saved + unread channels, top unread authors.
   - **Inbox right now**: unread total + the category split (call out if it's mostly keyword noise).
   - **In flight**: pending scheduled messages, and active snoozes ("N items snoozed for later").
   - **What you did**: decisions logged via /slack-saved (by_decision, last 7d/24h) — only if
     `logged_total` > 0; otherwise skip (the store fills up as they use /slack-saved).

3. End with a light nudge to action when it fits, e.g. "want to knock down those 43? → /slack-saved"
   or "inbox is 80% keyword noise → /slack-triage with --no-keywords".

## Notes
- Pure counting; no writes. Numbers are a live snapshot (re-run for fresh).
- "Cleared" = Slack's archived/completed totals (cumulative truth). "Logged" decisions come from
  the local /slack-saved store and only reflect actions taken through this plugin.
- A full run does a couple of bulk hydrations (saved + unread), so it takes a few seconds.
