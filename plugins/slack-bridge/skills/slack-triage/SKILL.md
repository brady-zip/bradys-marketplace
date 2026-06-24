---
name: slack-triage
description: Build an interactive HTML board of true unread Slack (DMs, @mentions, keyword matches) grouped by urgency + topic, with click-tracking and real bulk mark-read. Use when the user asks to "triage my Slack", "clean up Slack", "what's unread in Slack", "check my Slack notifications", "/slack-triage", or "/unread-slack". Reads Slack's real Activity feed via browser session tokens — the count matches Slack itself and already-read messages never re-show.
---

# Slack triage

Produce an interactive board of the user's real Slack unread, grouped by urgency + topic.
Bold = not yet clicked; clicking a message opens Slack; checkboxes + a button do REAL bulk
mark-read. The board count matches Slack's own Activity tab.

This skill ships with the **slack-bridge** plugin and shares its Slack client
(`server/slack_client.py`) and its session tokens (`xoxc`/`xoxd`). The MCP tools
(`list_unread`, `mark_read`, `list_saved`, `schedule_message`, …) are the *conversational*
way to do one-off actions; this skill is the *board* workflow when you want to triage a large
pile visually.

## Architecture

YOU (this skill) do fetch + triage + build. The local server only marks read.

```
${CLAUDE_PLUGIN_ROOT}/                          ← git-tracked (no secrets)
  server/slack_client.py    shared Slack client (auth, activity.feed, conversations.mark, …)
  skills/slack-triage/
    fetch_unread.py   activity.feed → hydrate via messages.list → buckets JSON (imports slack_client)
    generate_html.py  reads ~/.config/slack-bridge/triaged.json → writes board.html there
    serve.py          serves board.html + POST /api/mark → conversations.mark (REAL)

~/.config/slack-bridge/                          ← NOT git-tracked (secrets + runtime)
  .env              SLACK_XOXC + SLACK_XOXD  (browser session tokens, chmod 600)
  triaged.json      your urgency/topic grouping (transient)
  board.html        generated board (transient)
```

Below, `$S` = `${CLAUDE_PLUGIN_ROOT}/skills/slack-triage`. Scripts run with `uv run` (they carry
PEP 723 headers; stdlib only). They read the token from `~/.config/slack-bridge/.env` and write
runtime files to `~/.config/slack-bridge/`, regardless of cwd.

## Why it works (and the gotchas)

- **Source = Slack's internal `activity.feed`** (mode `chrono_v1`), the same endpoint the web
  client's Activity inbox uses — so the unread set == what Slack shows; nothing already read
  re-appears. The hosted Slack MCP can't do this (no read-state endpoints).
- **Auth = browser session tokens** `xoxc` (workspace token, page localStorage) + `xoxd` (the
  `d` cookie). `xoxd` from the cookie store is ALREADY url-encoded — sent raw; never re-encode
  (double-encoding → `invalid_auth`). The client handles this.
- **`keyword` items** are real "Keyword mentions" (matched a highlight word or your name, not a
  hard @-tag). They're often the bulk of the count and mostly low-urgency — keep them unless the
  user asks for `--no-keywords`.
- **Enterprise Grid**: `chat.getPermalink` is blocked, so permalinks are built locally as
  `{team_url}archives/{channel}/p{ts_without_dot}`.
- **Speed**: `activity.feed` returns refs only; `messages.list` bulk-hydrates (chunked ≤20
  channels, parallel). Full run ~6s, `--no-keywords` ~3s.
- **Tokens expire** on logout / SSO refresh → `auth failed`. Re-grab via the extension (see
  Token setup).

## Steps

1. Fetch raw buckets:
   ```bash
   mkdir -p ~/.config/slack-bridge
   uv run "$S/fetch_unread.py" --json > /tmp/slack-unread.json
   ```
   If it errors `No Slack tokens found` → see "Token setup" below.
   If `auth failed` → session expired; re-grab tokens via the extension.

2. TRIAGE — YOU (Claude) read every item in `/tmp/slack-unread.json` and classify it BY
   JUDGMENT (read the actual text; do NOT map by channel name). Write
   `~/.config/slack-bridge/triaged.json`:
   ```json
   {"stamp":"<date>","groups":[{"urgency":"high|medium|low","topic":"...","items":[<full item objs>]}]}
   ```
   Copy each item object verbatim — must keep `channel_id` + `ts` + `permalink` (used for
   mark-read). Every item in exactly one group; drop none. For a large feed (200+ items) where
   reading all would blow context, spawn a subagent to classify and write the file.

   General judgment guide (adapt to what you know about the user):
   - **HIGH** — plausibly needs the user's action/attention: human DMs, hard @mentions,
     PR-review asks, direct questions, incidents/on-call in their domain, access requests aimed
     at them, anything addressed to them by name.
   - **MEDIUM** — domain-adjacent, worth a skim, no direct ask: team/project threads, launches,
     tooling discussions, product questions they'd want to see but needn't answer.
   - **LOW** — matched a highlight word or their name only, no involvement: broad announcements,
     social chatter, and all bot/automation DMs (CI, deploy bots, calendar, ticketing, etc.).

   Judge on content, not channel: a direct question in a social channel can be HIGH; pure social
   in a work channel is LOW. Group within an urgency by meaningful topic (not raw channel), items
   newest-first, groups ordered high → medium → low.

   DEADLINE BUMP — factor time-sensitivity; it overrides the rules above. If a message has a
   near-term deadline needing the user to act (RSVP/sign-up by a date, "due today/tomorrow/EOD",
   a meeting to confirm, an auto-order cutoff, last call), bump it UP at least one level — even
   social ones — and surface those in a "⏰ Time-sensitive" high group. Conversely, "we launched
   X today" announcements are NOT deadlines — they stay low.

3. Build the board + (re)start the server:
   ```bash
   uv run "$S/generate_html.py"                            # writes ~/.config/slack-bridge/board.html
   lsof -ti tcp:8770 | xargs kill -9 2>/dev/null; true     # free the port
   nohup uv run "$S/serve.py" 8770 >/tmp/slack-serve.log 2>&1 &
   ```
   Give the user the link: **http://localhost:8770**

4. Optionally summarize the HIGH items inline in chat so the user sees the signal without
   opening the board.

## The board UX

- Sections by urgency (🔴 high / 🟡 medium / ⚪ low); collapsible topic groups within.
- **Bold = unclicked**; clicking a message opens Slack in a new tab and dims it (localStorage,
  persists per browser). "reset clicks" clears that.
- Per-message + per-group checkboxes → **"Mark selected read"** → POSTs to `/api/mark` →
  `conversations.mark` actually marks them read in Slack (gone on next fetch). Per channel it
  marks the newest selected ts (Slack's read cursor is per-channel).

## fetch_unread.py flags

| Flag | Effect |
|---|---|
| (none) | Everything: DMs, hard @mentions, threads, broadcasts, keyword mentions. |
| `--json` | Structured buckets `{dm, mention, thread, broadcast, keyword: [...]}`. |
| `--no-keywords` | Drop keyword mentions (DMs + hard @mentions only). Faster. Only if asked. |

## Token setup (first run / after expiry)

`xoxc`/`xoxd` come from a logged-in Slack web session. Run the plugin's setup helper:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```
It walks you through loading the unpacked Chrome extension
(`${CLAUDE_PLUGIN_ROOT}/extension`) — `chrome://extensions` → Developer mode → Load unpacked —
then "Grab tokens" → paste the env line → it writes `~/.config/slack-bridge/.env` (chmod 600)
and validates with `auth.test`.

## Security / housekeeping

- `xoxc`+`xoxd` = the user's full Slack session (bypasses SSO/2FA). Keep `.env` chmod 600, never
  commit, never echo into logs. The server holds the token in memory while running — stop it when
  done: `lsof -ti tcp:8770 | xargs kill`.
- Read-mostly: only `/api/mark` writes, and only the read cursor (no posting, no deleting).
