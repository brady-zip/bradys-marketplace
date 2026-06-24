# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""slack_client.py — shared pure-stdlib bridge to Slack's web API via browser session tokens.

Imported by BOTH the MCP server (server/server.py) and the triage-board skill scripts
(skills/slack-triage/*.py). Stdlib only (no third-party deps), so it imports identically under
`uv run` (ephemeral venv) and plain `python3`.

Auth = browser SESSION tokens, not an OAuth app token:
    xoxc  workspace token, from the Slack web page's localStorage (localConfig_v2)
    xoxd  the `d` cookie value
These carry the full permissions of the logged-in user and reach Slack's internal endpoints
(activity.feed, messages.list, saved.*) that OAuth app tokens (xoxp/xoxb) cannot. Capture them
with the bundled Chrome extension; they expire on logout / SSO refresh.

Endpoint confidence:
    KNOWN      activity.feed, messages.list, conversations.mark, auth.test, users.info,
               conversations.info  (proven in the colleague's /slack-cleanup skill)
    KNOWN      chat.scheduleMessage / chat.scheduledMessages.list / chat.deleteScheduledMessage
               (public Web API methods; work with a session token)
    R-ENG      saved.list / saved.update  (reverse-engineered internal "Later" endpoints;
               reference impl: korotovsky/slack-mcp-server pkg/provider/edge/saved.go)
    DISCOVERY  saved.add / saved.remove  (Slack exposes NO confirmed endpoint for adding/
               removing a single Later item — see saved_add/saved_remove docstrings)
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# --- tuning ---
MSG_PREVIEW = 280
PAGE_LIMIT = 50
MAX_PAGES = 30
WORKERS = 8
MSG_BATCH_CHANNELS = 20  # messages.list caps channels per request (too_many_channels)
HTTP_RETRIES = 4

# Dotfile search order. $SLACK_BRIDGE_DOTFILE (set in .mcp.json) wins; the colleague's
# /slack-cleanup path is last so an existing user works with zero extra setup.
DOTFILE_CANDIDATES = [
    os.environ.get("SLACK_BRIDGE_DOTFILE"),
    "~/.config/slack-bridge/.env",
    "~/.config/slack-unread/.env",
]

# Activity-feed item types we surface.
FEED_TYPES = ",".join([
    "at_user",
    "at_user_group",
    "at_channel",
    "at_everyone",
    "keyword",
    "unjoined_channel_mention",
    "thread_v2",
    "dm",
    "bot_dm_bundle",
])

# Feed item type -> our category.
CATEGORY = {
    "at_user": "mention",
    "unjoined_channel_mention": "mention",
    "at_channel": "broadcast",
    "at_everyone": "broadcast",
    "at_user_group": "broadcast",
    "keyword": "keyword",
    "dm": "dm",
    "bot_dm_bundle": "dm",
    "thread_v2": "thread",
}
CATEGORY_ORDER = ["dm", "mention", "thread", "broadcast", "keyword"]
CATEGORY_TITLE = {
    "dm": "Direct messages",
    "mention": "Direct @mentions",
    "thread": "Thread replies",
    "broadcast": "Broadcast / group mentions",
    "keyword": "Highlight-word matches",
}


class SlackError(RuntimeError):
    """A Slack API call returned ok=false, or transport failed after retries."""


class SlackAuthError(SlackError):
    """Tokens missing/expired/revoked — the user must (re)capture xoxc/xoxd."""


def load_auth(dotfile=None):
    """Return (xoxc, xoxd) from the first readable dotfile. Raises SlackAuthError if none."""
    paths = [dotfile] if dotfile else DOTFILE_CANDIDATES
    for p in paths:
        if not p:
            continue
        p = os.path.expanduser(p)
        if not os.path.exists(p):
            continue
        vals = {}
        with open(p) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip().strip('"').strip("'")
        xoxc, xoxd = vals.get("SLACK_XOXC"), vals.get("SLACK_XOXD")
        if xoxc and xoxd:
            return xoxc, xoxd
        raise SlackAuthError(f"{p} exists but is missing SLACK_XOXC / SLACK_XOXD.")
    searched = ", ".join(os.path.expanduser(p) for p in paths if p)
    raise SlackAuthError(
        f"No Slack tokens found (looked in: {searched}). Run scripts/setup.sh and load the "
        "Chrome extension to capture xoxc/xoxd, or create ~/.config/slack-bridge/.env "
        "(chmod 600) with lines SLACK_XOXC=… and SLACK_XOXD=…"
    )


class Slack:
    """Thin Slack web-API client over a browser session token pair."""

    def __init__(self, xoxc, xoxd, host="slack.com"):
        self.xoxc = xoxc
        self.xoxd = xoxd
        self.host = host
        self.team_url = "https://slack.com/"
        self.user_id = ""  # the authed user (set by connect) — used to detect "I already replied"
        self.user = ""

    @classmethod
    def from_env(cls, dotfile=None):
        """Load tokens from the dotfile and resolve the team host. Re-reads every call
        (no module-level cache) so a freshly re-captured token is picked up without a restart."""
        xoxc, xoxd = load_auth(dotfile)
        sl = cls(xoxc, xoxd)
        sl.connect()
        return sl

    def connect(self):
        """Resolve the team host + authed user via auth.test (e.g. enterprise.slack.com)."""
        auth = self.call("auth.test")
        self.team_url = auth.get("url", "https://slack.com/")
        self.host = urllib.parse.urlparse(self.team_url).netloc or "slack.com"
        self.user_id = auth.get("user_id", "")
        self.user = auth.get("user", "")
        return auth

    def call(self, method, params=None):
        form = dict(params or {})
        form["token"] = self.xoxc
        data = urllib.parse.urlencode(form).encode()
        body = None
        last_exc = None
        for attempt in range(HTTP_RETRIES):
            try:
                req = urllib.request.Request(f"https://{self.host}/api/{method}", data=data)
                # xoxd from the cookie store is ALREADY url-encoded — send it raw.
                # Re-encoding (urllib.parse.quote) double-encodes it -> invalid_auth.
                req.add_header("Cookie", f"d={self.xoxd}")
                req.add_header("Content-Type", "application/x-www-form-urlencoded")
                with urllib.request.urlopen(req, timeout=30) as resp:
                    body = json.loads(resp.read().decode())
                break
            except urllib.error.HTTPError as e:
                last_exc = e
                if e.code == 429:  # rate limited — honor Retry-After
                    try:
                        wait = int(e.headers.get("Retry-After", "1") or "1")
                    except ValueError:
                        wait = 1
                    time.sleep(min(wait, 30))
                else:
                    time.sleep(0.5 * (attempt + 1))
            except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
                last_exc = e
                time.sleep(0.5 * (attempt + 1))
        if body is None:
            raise SlackError(f"{method} failed after {HTTP_RETRIES} retries: {last_exc}")
        if not body.get("ok"):
            err = body.get("error", "unknown")
            if err in ("invalid_auth", "not_authed", "token_revoked", "token_expired"):
                raise SlackAuthError(
                    f"Slack auth failed ({err}). Session tokens expire on SSO refresh — "
                    "re-capture xoxc/xoxd via the Chrome extension and update the dotfile."
                )
            raise SlackError(f"{method} failed: {err}")
        return body


# --------------------------------------------------------------------------- unread

def fetch_feed(sl):
    """Paginate the activity feed, unread only. Returns the list of raw feed items."""
    items, cursor = [], ""
    for _ in range(MAX_PAGES):
        params = {
            "limit": str(PAGE_LIMIT),
            "types": FEED_TYPES,
            "mode": "chrono_v1",
            "archive_only": "false",
            "unread_only": "true",
            "priority_only": "false",
            "only_salesforce_channels": "false",
            "exclude_automations": "false",
            "is_activity_inbox": "true",
        }
        if cursor:
            params["cursor"] = cursor
        body = sl.call("activity.feed", params)
        items.extend(body.get("items", []))
        cursor = body.get("response_metadata", {}).get("next_cursor", "")
        if not cursor:
            break
    return items


def ref_of(item):
    """Pull (channel, ts, author) out of a feed item, across its type variants."""
    it = item["item"]
    t = it["type"]
    if t == "dm":
        m = (
            it.get("bundle_info", {})
            .get("payload", {})
            .get("dm_entry", {})
            .get("latest_message", {})
        )
    elif t == "bot_dm_bundle":
        m = it.get("bundle_info", {}).get("payload", {}).get("message", {})
    elif t == "thread_v2":
        m = it.get("root_msg", {}) or it.get("message", {})
    else:
        m = it.get("message", {})
    return m.get("channel", ""), m.get("ts", ""), m.get("author_user_id", "")


class Enricher:
    """Resolves user/channel names and bulk-hydrates message text. Caches lookups."""

    def __init__(self, sl):
        self.sl = sl
        self._users = {}
        self._chans = {}

    def user_name(self, uid):
        if not uid:
            return ""
        if uid not in self._users:
            try:
                u = self.sl.call("users.info", {"user": uid}).get("user", {})
                self._users[uid] = u.get("real_name") or u.get("name") or uid
            except SlackError:
                self._users[uid] = uid
        return self._users[uid]

    def chan_name(self, cid):
        if cid not in self._chans:
            try:
                ch = self.sl.call("conversations.info", {"channel": cid}).get("channel", {})
                if ch.get("is_im"):
                    self._chans[cid] = "@" + self.user_name(ch.get("user", ""))
                else:
                    self._chans[cid] = "#" + ch.get("name", cid)
            except SlackError:
                self._chans[cid] = cid
        return self._chans[cid]

    def bulk_messages(self, refs):
        """One (chunked, parallel) messages.list pass. refs: [(channel, ts, author)].
        Returns {(channel, ts): {text, user}}."""
        by_channel = {}
        for channel, ts, _ in refs:
            if channel and ts:
                by_channel.setdefault(channel, []).append(ts)
        if not by_channel:
            return {}
        channels = list(by_channel)
        chunks = [
            {c: by_channel[c] for c in channels[i : i + MSG_BATCH_CHANNELS]}
            for i in range(0, len(channels), MSG_BATCH_CHANNELS)
        ]
        out = {}
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for part in pool.map(self._bulk_chunk, chunks):
                out.update(part)
        return out

    def _bulk_chunk(self, by_channel):
        message_ids = [{"channel": c, "timestamps": ts} for c, ts in by_channel.items()]
        resp = self.sl.call(
            "messages.list",
            {
                "message_ids": json.dumps(message_ids),
                "org_wide_aware": "true",
                "cached_latest_updates": "{}",
            },
        )
        out = {}
        for channel, data in (resp.get("messages_data") or {}).items():
            for m in data.get("messages", []):
                out[channel, m.get("ts")] = {
                    "text": " ".join((m.get("text") or "").split()),
                    "user": m.get("user", ""),
                }
        return out

    def row(self, ref, msg):
        channel, ts, author = ref
        text = msg.get("text", "") if msg else ""
        if not author and msg:
            author = msg.get("user", "")
        if len(text) > MSG_PREVIEW:
            text = text[:MSG_PREVIEW] + "…"
        link = (
            f"{self.sl.team_url}archives/{channel}/p{ts.replace('.', '')}"
            if (channel and ts)
            else ""
        )
        return {
            "channel_label": self.chan_name(channel) if channel else "",
            "channel_id": channel,
            "author": self.user_name(author),
            "text": text,
            "ts": ts,
            "permalink": link,
        }


def list_unread(sl, categories=None, no_keywords=False, max_items=None):
    """Fetch true unread (activity.feed) and hydrate it.

    categories: optional subset of CATEGORY_ORDER to keep (dm/mention/thread/broadcast/keyword).
    no_keywords: drop highlight-word matches (the noisy bulk of the feed).
    Returns {items: [...], total, team_url, by_category: {cat: [...]}}.
    Each item: {category, channel_id, channel_label, author, text, ts, permalink}.
    """
    feed = fetch_feed(sl)
    work = []
    for item in feed:
        cat = CATEGORY.get(item["item"]["type"])
        if not cat:
            continue
        if no_keywords and cat == "keyword":
            continue
        if categories and cat not in categories:
            continue
        ref = ref_of(item)
        if ref[0] and ref[1]:
            work.append((ref, cat))

    enr = Enricher(sl)
    msgs = enr.bulk_messages([ref for ref, _ in work])

    def build(entry):
        ref, cat = entry
        row = enr.row(ref, msgs.get((ref[0], ref[1])))
        row["category"] = cat
        return row

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        rows = list(pool.map(build, work))

    if max_items:
        rows = rows[:max_items]

    by_category = {c: [] for c in CATEGORY_ORDER}
    for r in rows:
        by_category[r["category"]].append(r)
    return {"items": rows, "total": len(rows), "team_url": sl.team_url, "by_category": by_category}


def read_thread(sl, channel, ts, limit=50):
    """Read a message and its thread replies (conversations.replies) to judge whether a saved
    item still needs action. Returns {reply_count, replied_by_me, latest_ts, messages:[{user,
    author, text, ts}]}. replied_by_me is True if the authed user appears in the replies."""
    body = sl.call("conversations.replies", {"channel": channel, "ts": ts, "limit": str(limit)})
    enr = Enricher(sl)
    msgs = []
    for m in body.get("messages", []):
        msgs.append({
            "user": m.get("user", ""),
            "author": enr.user_name(m.get("user", "")),
            "text": " ".join((m.get("text") or "").split())[:MSG_PREVIEW],
            "ts": m.get("ts", ""),
        })
    replies = [m for m in msgs if m["ts"] != ts]
    replied_by_me = bool(sl.user_id) and any(m["user"] == sl.user_id for m in replies)
    latest_ts = msgs[-1]["ts"] if msgs else ts
    return {"reply_count": len(replies), "replied_by_me": replied_by_me,
            "latest_ts": latest_ts, "messages": msgs}


def mark_read(sl, channel_id, ts):
    """Advance the read cursor in one channel to `ts` (real mark-read)."""
    sl.call("conversations.mark", {"channel": channel_id, "ts": ts})
    return {"ok": True, "channel": channel_id, "ts": ts}


def mark_all_read(sl, items):
    """Mark read across channels. items: [{channel_id, ts}]. Per channel, marks the newest ts
    (Slack's read cursor is per-channel)."""
    newest = {}
    for it in items:
        cid, ts = it.get("channel_id"), it.get("ts")
        if cid and ts and (cid not in newest or float(ts) > float(newest[cid])):
            newest[cid] = ts
    marked, failed = 0, []
    for cid, ts in newest.items():
        try:
            sl.call("conversations.mark", {"channel": cid, "ts": ts})
            marked += 1
        except SlackError:
            failed.append(cid)
    return {"ok": True, "channels_marked": marked, "failed": failed}


# ----------------------------------------------------------------------- saved-for-later
# "Later" / saved items. Internal, reverse-engineered endpoints — require a session token.
# Slack has NO public API here (see api.slack.com changelog 2023-07). Names/params confirmed
# against korotovsky/slack-mcp-server pkg/provider/edge/saved.go; isolate every call here so a
# rename is a one-line edit.

SAVED_LIMIT_MAX = 50  # saved.list rejects limit > 50 with invalid_arguments


def saved_list(sl, state=None, limit=SAVED_LIMIT_MAX):
    """List 'Later' (saved) items. Paginates via response_metadata.next_cursor.

    Each raw item: {item_id (== channel id for messages), item_type, ts, state
    ("in_progress"|...), todo_state, is_archived, date_created, date_due, date_completed,
    date_updated, date_snoozed_until}.

    state: optional client-side filter — "in_progress" | "completed" | "archived". Slack's
    server-side `filter` arg only accepts a narrow set, so we fetch all and filter here.
    """
    limit = min(int(limit), SAVED_LIMIT_MAX)
    out, cursor = [], ""
    for _ in range(MAX_PAGES):
        params = {"limit": str(limit)}
        if cursor:
            params["cursor"] = cursor
        body = sl.call("saved.list", params)
        out.extend(body.get("saved_items", []))  # NB: key is saved_items, not items
        cursor = body.get("response_metadata", {}).get("next_cursor", "")
        if not cursor:
            break
    if state == "archived":
        out = [it for it in out if it.get("is_archived")]
    elif state == "completed":
        out = [it for it in out if it.get("date_completed")]
    elif state:
        out = [it for it in out if it.get("state") == state and not it.get("is_archived")]
    return {"items": out, "total": len(out)}


def hydrate_saved(sl, items):
    """Enrich raw saved items with channel name, author, text, and a permalink — same
    messages.list bulk path as unread. Returns rows sorted newest-saved first."""
    enr = Enricher(sl)
    refs = [(it["item_id"], it["ts"], "") for it in items
            if it.get("item_type") == "message" and it.get("item_id") and it.get("ts")]
    msgs = enr.bulk_messages(refs)
    rows = []
    for it in items:
        cid, ts = it.get("item_id", ""), it.get("ts", "")
        m = msgs.get((cid, ts))
        base = enr.row((cid, ts, ""), m) if m or it.get("item_type") == "message" else {
            "channel_label": "", "channel_id": cid, "author": "", "text": "", "ts": ts,
            "permalink": "",
        }
        base.update({
            "item_id": it.get("item_id", ""),
            "item_type": it.get("item_type", ""),
            "state": it.get("state", ""),
            "is_archived": it.get("is_archived", False),
            "date_created": it.get("date_created", 0),
            "date_due": it.get("date_due", 0),
            "date_completed": it.get("date_completed", 0),
        })
        rows.append(base)
    rows.sort(key=lambda r: r.get("date_created", 0), reverse=True)
    return rows


def saved_update(sl, item_id, item_type="message", ts=None, mark=None, date_due=None):
    """Update a saved item via saved.update (requires item_type + item_id). The state-change
    field is `mark` (confirmed live): mark='archived' archives, mark='completed' completes.
    item_id/item_type/ts come from saved_list() rows; date_due=<unix> sets a reminder.
    """
    params = {"item_id": item_id, "item_type": item_type}
    if ts:
        params["ts"] = ts
    if mark:
        params["mark"] = mark
    if date_due is not None:
        params["date_due"] = str(int(date_due))
    sl.call("saved.update", params)
    return {"ok": True, "item_id": item_id}


def saved_add(sl, channel_id, ts, date_due=None, item_type="message"):
    """Add a message to 'Later' via saved.add (confirmed to exist; requires item_type +
    item_id). For a message, item_id is the channel id."""
    params = {"item_type": item_type, "item_id": channel_id, "ts": ts}
    if date_due is not None:
        params["date_due"] = str(int(date_due))
    body = sl.call("saved.add", params)
    item = body.get("item", {}) if isinstance(body.get("item"), dict) else {}
    return {"ok": True, "item_id": item.get("item_id", channel_id)}


def saved_remove(sl, item_id, item_type="message", ts=None):
    """Remove a saved item. There is no saved.remove method — this ARCHIVES the item via
    saved.update mark='archived', which clears it from the active Later list."""
    return saved_update(sl, item_id, item_type=item_type, ts=ts, mark="archived")


# ------------------------------------------------------------------------ scheduled messages
# Public, documented Web API methods. Work with a session token.

def schedule_message(sl, channel_id, text, post_at):
    """Schedule a message. post_at = unix timestamp (must be <=120 days out)."""
    body = sl.call(
        "chat.scheduleMessage",
        {"channel": channel_id, "text": text, "post_at": str(int(post_at))},
    )
    return {
        "ok": True,
        "channel": body.get("channel", channel_id),
        "scheduled_message_id": body.get("scheduled_message_id", ""),
        "post_at": int(body.get("post_at", post_at)),
    }


def list_scheduled(sl, channel_id=None, limit=100):
    """List pending scheduled messages, optionally filtered to one channel. Paginates."""
    out, cursor = [], ""
    for _ in range(MAX_PAGES):
        params = {"limit": str(limit)}
        if channel_id:
            params["channel"] = channel_id
        if cursor:
            params["cursor"] = cursor
        body = sl.call("chat.scheduledMessages.list", params)
        out.extend(body.get("scheduled_messages", []))
        cursor = body.get("response_metadata", {}).get("next_cursor", "")
        if not cursor:
            break
    return {"items": out, "total": len(out)}


def delete_scheduled(sl, channel_id, scheduled_message_id):
    """Delete a pending scheduled message (can't delete if it posts within 60s)."""
    sl.call(
        "chat.deleteScheduledMessage",
        {"channel": channel_id, "scheduled_message_id": scheduled_message_id},
    )
    return {"ok": True, "scheduled_message_id": scheduled_message_id}


if __name__ == "__main__":
    # Self-check used by scripts/check-setup.sh: validate tokens via auth.test.
    import sys as _sys

    try:
        _sl = Slack.from_env()
        _auth = _sl.call("auth.test")
    except SlackError as _e:
        print(f"FAIL: {_e}", file=_sys.stderr)
        _sys.exit(1)
    print(f"OK: authenticated as {_auth.get('user', '?')} @ {_auth.get('team', _sl.team_url)}")

