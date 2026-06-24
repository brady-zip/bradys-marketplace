# slack-bridge

A Claude Code plugin that bridges to **Slack's web API using your browser session tokens**
(`xoxc` + `xoxd`), unlocking things the hosted Slack MCP can't reach:

- **Unread notifications** — your *true* Activity-inbox unread (DMs, @mentions, thread replies,
  broadcasts, keyword matches), with real bulk **mark-read**. The hosted Slack MCP has no
  read-state endpoints; this does.
- **Saved-for-later** — list, complete, snooze, archive, and add items in your "Later" list, and
  triage the backlog into a grounded, stateful worklist.
- **Scheduled messages** — list/create/delete *(currently needs an OAuth token — see Limitations)*.

It ships **two ways to use it**: an **MCP server** (`slack-bridge`) exposing tools any session can
call, and a set of **skills** (slash-invokable workflows) layered on top. One shared, pure-stdlib
Slack client (`server/slack_client.py`) backs everything, so the skills and the tools never diverge
on auth, permalinks, or categorization.

## Why browser session tokens?

Slack's internal endpoints (`activity.feed`, `messages.list`, `saved.*`) are gated to the browser
session credentials — an OAuth app token (`xoxp`/`xoxb`) can't call them, and installing an app
often needs workspace-admin approval. `xoxc` (workspace token, from the page's `localStorage`) +
`xoxd` (the `d` cookie) carry your full user permissions and reach everything the web client can.
They expire on logout / SSO refresh; re-capture when that happens (`/slack-setup`).

## Setup

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"      # or: /slack-setup
```

Walks you through loading the bundled Chrome extension (`extension/`), grabbing your tokens on a
logged-in Slack tab, and writing them to `~/.config/slack-bridge/.env` (chmod 600). Then:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh"   # or: /slack-doctor
```

The MCP server is launched by `.mcp.json` as `uv run ${CLAUDE_PLUGIN_ROOT}/server/server.py`
(`uv` resolves the one dependency, `mcp`, into an ephemeral venv). Requires `uv` on PATH.

## Skills

| Skill | What it does |
|---|---|
| **`/slack-setup`** | Capture/refresh Slack session tokens via the Chrome extension; validate with `auth.test`. Run first, and whenever tokens expire. |
| **`/slack-doctor`** | Health-check: uv, dotfile + perms, live `auth.test`, and the decision store. PASS/FAIL with fixes. |
| **`/slack-triage`** | Interactive HTML board of your true unread, grouped by urgency + topic, with click-tracking and real bulk mark-read. Served at `localhost:8770`. |
| **`/slack-saved`** | Triage your "Later" backlog into a chat digest, then **work the keepers one-by-one**: live-grounded next-step recommendations (PR status via `gh`, thread state via `read_thread`), auto-clear the obvious, walk the rest. Decisions persist; snoozes hide items until their date. |
| **`/slack-unwrapped`** | A "Spotify Wrapped"-style stats recap of your Slack life — backlog, unread snapshot, busiest channels/people, decisions logged. |

## MCP tools

| Tool | What it does |
|---|---|
| `list_unread(limit, categories, include_keywords)` | True unread, categorized + hydrated |
| `mark_read(channel_id, ts)` / `mark_all_read(items)` | Advance the read cursor (real mark-read) |
| `read_thread(channel_id, ts)` | Read a message + thread replies (grounds /slack-saved next steps) |
| `list_saved(state, limit, hydrate, include_snoozed)` | List "Later" items (`in_progress`/`completed`/`archived`), hydrated; hides active snoozes |
| `complete_saved(item_id, ts)` | Mark a Later item done (`saved.update mark=completed`) |
| `remove_saved(item_id, ts)` | Archive a Later item (`saved.update mark=archived`) |
| `snooze_saved(item_id, ts, until)` | Set Slack's own reminder date on a Later item (`date_due`) |
| `add_saved(channel_id, ts, date_due)` | Save a message to Later (`saved.add`) |
| `record_decision(item_id, ts, decision, snooze_until, …)` | Persist a /slack-saved decision to the durable store (drives snooze suppression) |
| `list_scheduled(channel_id)` | Pending scheduled messages *(needs OAuth token)* |
| `schedule_message(channel_id, text, post_at)` | Schedule a message *(needs OAuth token)* |
| `delete_scheduled(channel_id, scheduled_message_id)` | Cancel a scheduled message *(needs OAuth token)* |

## Durable decisions (`/slack-saved`)

`/slack-saved` persists every triage decision to `~/.config/slack-bridge/saved-decisions.json`
(keyed by `item_id:ts`, via `record_decision`). This makes the worklist **stateful across runs**:
**snoozed items stay hidden until their `snooze_until` date**, then resurface; other decisions
(done/archive/keep/…) form an audit trail and tag reappearing items with their `prior_decision`.
Inspect it with `uv run server/decisions.py`.

## Endpoint confidence & limitations

- **Unread, mark-read, read-thread** — solid (proven internal endpoints, work with session tokens).
- **Saved-for-later** (`saved.list` / `saved.update` / `saved.add`) — internal, undocumented, but
  **verified live against a real workspace**: `saved.list` returns `saved_items` (cap `limit`≤50,
  cursor-paginated); `saved.update` takes `item_type`+`item_id`(+`ts`) and a `mark` field
  (`completed` / `archived`) — there is no hard delete, so `remove_saved` archives. Reference:
  [korotovsky/slack-mcp-server](https://github.com/korotovsky/slack-mcp-server)
  `pkg/provider/edge/saved.go`. Slack may change these without notice.
- **Scheduled messages** — ⚠️ **currently non-functional under session-token auth.** The public
  `chat.scheduleMessage` / `chat.scheduledMessages.list` / `chat.deleteScheduledMessage` methods
  reject browser tokens with `not_allowed_token_type` (verified live) — they need an OAuth
  user/bot token. The web client schedules via an internal endpoint not yet reverse-engineered
  here. The tools are left in place for when an OAuth token is wired in or that endpoint is found.
- **Enterprise Grid** — `chat.getPermalink` is blocked, so permalinks are built locally. Some
  admin policies may also restrict other calls for session tokens.

## Security

`xoxc`+`xoxd` are your full Slack session (they bypass SSO/2FA). The dotfile is chmod 600, lives
outside git (`~/.config/slack-bridge/`), and `.gitignore` guards against stray copies. Writes are
limited to: mark-read (read cursor only), saved-item state (complete/archive/snooze/add), and
scheduling — no message posting or deletion. The `/slack-triage` board server binds `127.0.0.1`
only. Tokens are never echoed into logs or chat.

## Credits & prior art

The core idea — reading *true* unread from Slack's internal `activity.feed` via browser session
tokens, hydrating with `messages.list`, building an interactive triage board, and doing real
mark-read through `conversations.mark` — is adapted from **@chuqian**'s `/slack-cleanup` skill:

> **[Greenbax/evergreen#112154 — "Add slack-cleanup skill: triaged unread board with real
> mark-read"](https://github.com/Greenbax/evergreen/pull/112154)**

That PR worked out the hard parts this plugin builds on: the `activity.feed` (`chrono_v1`,
`unread_only`) pagination, the `xoxc`/`xoxd` auth flow and the "send `xoxd` raw, never re-encode"
gotcha, chunked parallel `messages.list` hydration, local permalink construction for Enterprise
Grid, the Chrome token-grabber extension, and the HTML board UX. slack-bridge repackages that as a
reusable MCP-backed plugin and extends it with saved-for-later (a grounded, stateful worklist),
scheduled-message tools, the decision store, and the setup/doctor/unwrapped lifecycle skills.
Thanks, Chuqian. 🙏
