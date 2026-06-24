# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "mcp>=1.2.0",
# ]
# ///
"""slack-bridge MCP server.

A thin FastMCP wrapper over slack_client.py (pure stdlib — the only dependency here is the
`mcp` SDK itself). Exposes Slack capabilities the hosted Slack MCP lacks: true UNREAD
notifications (+ mark-read), SAVED-FOR-LATER, and SCHEDULED MESSAGES — all over the user's
browser session tokens (xoxc/xoxd). Launched by .mcp.json via `uv run`.

Each tool builds a fresh client (Slack.from_env) so a re-captured token in the dotfile is
picked up without restarting the session. Slack errors propagate as MCP tool errors with
human-readable messages (see slack_client.SlackError / SlackAuthError).
"""

import os
import sys

# The script's own dir is on sys.path[0] under both `uv run` and `python3`, but make the
# sibling import bulletproof against any cwd/launch quirk.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import decisions as dec  # noqa: E402
import slack_client as sc  # noqa: E402
from mcp.server.fastmcp import FastMCP  # noqa: E402

mcp = FastMCP("slack-bridge")


def _client():
    """Fresh, authenticated client. Re-reads the dotfile every call (no cache)."""
    return sc.Slack.from_env(os.environ.get("SLACK_BRIDGE_DOTFILE"))


# --------------------------------------------------------------------------- unread

@mcp.tool()
def list_unread(limit: int = 100, categories: list[str] | None = None,
                include_keywords: bool = True) -> dict:
    """List the user's TRUE unread Slack — the same set Slack's Activity inbox shows (DMs,
    @mentions, thread replies, broadcasts, highlight-word matches). The hosted Slack MCP
    cannot see read-state; this can.

    limit: max items to return (default 100).
    categories: optional subset of ["dm","mention","thread","broadcast","keyword"].
    include_keywords: set False to drop noisy highlight-word matches.

    Returns {total, counts:{category:n}, team_url, items:[{category, channel_id, channel_label,
    author, text, ts, permalink}]}. Use ts + channel_id with mark_read.
    """
    sl = _client()
    res = sc.list_unread(sl, categories=categories, no_keywords=not include_keywords,
                         max_items=limit)
    return {
        "total": res["total"],
        "counts": {c: len(v) for c, v in res["by_category"].items() if v},
        "team_url": res["team_url"],
        "items": res["items"],
    }


@mcp.tool()
def mark_read(channel_id: str, ts: str) -> dict:
    """Mark a channel read up to message `ts` (advances Slack's read cursor — real mark-read)."""
    return sc.mark_read(_client(), channel_id, ts)


@mcp.tool()
def read_thread(channel_id: str, ts: str) -> dict:
    """Read a message + its thread replies, to judge whether a saved/unread item was already
    answered. Returns {reply_count, replied_by_me, messages:[{author, text, ts}]}. Useful for
    grounding /slack-saved next-step recommendations (reply vs mark-done)."""
    return sc.read_thread(_client(), channel_id, ts)


@mcp.tool()
def mark_all_read(items: list[dict]) -> dict:
    """Mark multiple messages read. `items`: [{"channel_id","ts"}]. Per channel, marks the
    newest ts. Returns {ok, channels_marked, failed:[channel_id]}."""
    return sc.mark_all_read(_client(), items)


# ----------------------------------------------------------------------- saved-for-later

@mcp.tool()
def list_saved(state: str | None = "in_progress", limit: int = 100, hydrate: bool = True,
               include_snoozed: bool = False) -> dict:
    """List the user's 'Later' (saved) items. state: "in_progress" (active, default) |
    "completed" | "archived" | None (all). With hydrate=True (default), each item includes the
    resolved channel_label, author, text, and permalink; limit caps the number hydrated.

    By default, items SNOOZED via record_decision (snooze_until in the future) are hidden —
    pass include_snoozed=True to see them. Items with a prior decision are tagged prior_decision.

    Returns {total, snoozed_hidden, items:[{item_id, channel_id, channel_label, author, text, ts,
    permalink, state, is_archived, date_created, date_due, date_completed, prior_decision?}]}."""
    sl = _client()
    res = sc.saved_list(sl, state=state)
    base = sc.hydrate_saved(sl, res["items"][:limit]) if hydrate else res["items"][:limit]
    rows, suppressed = dec.annotate_and_filter(base, include_snoozed=include_snoozed)
    return {"total": res["total"], "snoozed_hidden": suppressed, "items": rows}


@mcp.tool()
def complete_saved(item_id: str, ts: str, item_type: str = "message",
                   completed: bool = True) -> dict:
    """Mark a saved 'Later' item complete (or uncomplete) via saved.update. item_id/ts/item_type
    come from list_saved rows (item_id is the channel id for messages)."""
    return sc.saved_update(_client(), item_id, item_type=item_type, ts=ts,
                           mark="completed" if completed else "uncompleted")


@mcp.tool()
def add_saved(channel_id: str, ts: str, date_due: int | None = None) -> dict:
    """Save a message to 'Later' via saved.add. date_due: optional unix-timestamp reminder."""
    return sc.saved_add(_client(), channel_id, ts, date_due=date_due)


@mcp.tool()
def snooze_saved(item_id: str, ts: str, until: int) -> dict:
    """Snooze a saved 'Later' item by (re)setting its reminder date. until = unix timestamp.
    Keeps the item active but re-surfaces it later. (saved.update date_due — best-effort.)"""
    return sc.saved_update(_client(), item_id, ts=ts, date_due=until)


@mcp.tool()
def remove_saved(item_id: str, ts: str, item_type: str = "message") -> dict:
    """Remove a saved 'Later' item. Slack has no delete method, so this ARCHIVES it (clears it
    from the active Later list) via saved.update."""
    return sc.saved_remove(_client(), item_id, item_type=item_type, ts=ts)


@mcp.tool()
def record_decision(item_id: str, ts: str, decision: str, snooze_until: int | None = None,
                    note: str = "", channel_label: str = "", gist: str = "") -> dict:
    """Persist a /slack-saved triage decision to the durable local store
    (~/.config/slack-bridge/saved-decisions.json), so decisions survive across runs.
    decision: done | archive | keep | snooze | reply | review | do.

    For decision='snooze', pass snooze_until (unix timestamp) — the item is then HIDDEN from
    list_saved / the /slack-saved worklist until that time, and resurfaces afterward. This does
    NOT mutate Slack (use complete_saved/remove_saved for that, and snooze_saved to also set
    Slack's own reminder); it records intent + drives local suppression."""
    return dec.record(item_id, ts, decision, snooze_until=snooze_until, note=note,
                      channel_label=channel_label, gist=gist)


# ------------------------------------------------------------------------ scheduled messages
# NOTE: the public chat.scheduled* methods reject browser session tokens with
# `not_allowed_token_type` (verified live) — they need an OAuth user/bot token. These tools are
# kept for that case / future internal-endpoint discovery, but will error under session-token auth.

@mcp.tool()
def list_scheduled(channel_id: str | None = None) -> dict:
    """List pending scheduled messages, optionally filtered to one channel. Returns
    {total, items:[{id, channel_id, post_at, text}]}. Use id + channel_id with delete_scheduled."""
    return sc.list_scheduled(_client(), channel_id=channel_id)


@mcp.tool()
def schedule_message(channel_id: str, text: str, post_at: int) -> dict:
    """Schedule a message to post later. post_at = unix timestamp (must be <=120 days out).
    Returns {ok, channel, scheduled_message_id, post_at}."""
    return sc.schedule_message(_client(), channel_id, text, post_at)


@mcp.tool()
def delete_scheduled(channel_id: str, scheduled_message_id: str) -> dict:
    """Cancel a pending scheduled message (cannot delete if it posts within 60s). Get the id
    from list_scheduled or schedule_message."""
    return sc.delete_scheduled(_client(), channel_id, scheduled_message_id)


if __name__ == "__main__":
    mcp.run()
