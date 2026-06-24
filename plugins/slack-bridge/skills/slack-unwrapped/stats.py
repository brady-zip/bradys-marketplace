# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compute 'Slack Unwrapped' stats as JSON for the /slack-unwrapped recap.

Pulls from everything slack-bridge can see: the saved/Later backlog (saved.list), the unread
Activity feed, pending scheduled messages, and the durable /slack-saved decision store. Read-only.

    uv run stats.py            # JSON blob of computed stats
"""

import json
import os
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import decisions as dec  # noqa: E402
import slack_client as sc  # noqa: E402


def main():
    now = int(time.time())
    try:
        sl = sc.Slack.from_env()

        # --- saved / Later backlog (one full fetch, bucketed) ---
        all_saved = sc.saved_list(sl, state=None)["items"]

        def bucket(it):
            if it.get("is_archived"):
                return "archived"
            if it.get("date_completed"):
                return "completed"
            return "in_progress"

        counts = Counter(bucket(it) for it in all_saved)
        in_prog = [it for it in all_saved if bucket(it) == "in_progress"]
        ip_rows = sc.hydrate_saved(sl, in_prog)
        top_saved_channels = Counter(
            r["channel_label"] for r in ip_rows if r.get("channel_label")
        ).most_common(5)
        oldest_days = round((now - min((it.get("date_created", now) for it in in_prog), default=now)) / 86400)
        overdue = sum(1 for it in in_prog if it.get("date_due") and it["date_due"] < now)

        # --- unread snapshot ---
        unread = sc.list_unread(sl)
        ur = unread["items"]
        ur_cats = {k: len(v) for k, v in unread["by_category"].items() if v}
        top_unread_channels = Counter(i["channel_label"] for i in ur if i.get("channel_label")).most_common(5)
        top_unread_authors = Counter(i["author"] for i in ur if i.get("author")).most_common(5)

    except sc.SlackError as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

    # --- scheduled (public API rejects session tokens with not_allowed_token_type) ---
    try:
        scheduled_pending = sc.list_scheduled(sl)["total"]
    except sc.SlackError:
        scheduled_pending = None  # unavailable with session-token auth

    # --- decisions logged via /slack-saved (durable store) ---
    store = dec.load()
    by_decision = dict(Counter(v.get("decision") for v in store.values()))
    logged_7d = sum(1 for v in store.values() if (v.get("decided_at") or 0) > now - 7 * 86400)
    logged_24h = sum(1 for v in store.values() if (v.get("decided_at") or 0) > now - 86400)

    out = {
        "as_of": now,
        "user": sl.user,
        "saved": {
            "in_progress": counts.get("in_progress", 0),
            "completed": counts.get("completed", 0),
            "archived": counts.get("archived", 0),
            "total": len(all_saved),
            "oldest_in_progress_days": oldest_days,
            "overdue_in_progress": overdue,
            "top_channels": top_saved_channels,
        },
        "unread": {
            "total": unread["total"],
            "by_category": ur_cats,
            "top_channels": top_unread_channels,
            "top_authors": top_unread_authors,
        },
        "scheduled_pending": scheduled_pending,
        "decisions": {
            "logged_total": len(store),
            "by_decision": by_decision,
            "logged_last_7d": logged_7d,
            "logged_last_24h": logged_24h,
            "active_snoozes": len(dec.active_snoozes(now)),
        },
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
