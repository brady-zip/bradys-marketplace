# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fetch true Slack unread as categorized buckets (for the /slack-triage board).

Thin CLI wrapper over the shared slack_client (../../server/slack_client.py). Read-only.

    uv run fetch_unread.py            # human-readable summary
    uv run fetch_unread.py --json     # buckets {dm, mention, thread, broadcast, keyword: [...]}
    uv run fetch_unread.py --no-keywords   # drop highlight-word noise
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import slack_client as sc  # noqa: E402


def main():
    as_json = "--json" in sys.argv
    no_keywords = "--no-keywords" in sys.argv
    try:
        sl = sc.Slack.from_env()
        res = sc.list_unread(sl, no_keywords=no_keywords)
    except sc.SlackError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    buckets = res["by_category"]
    if as_json:
        print(json.dumps(buckets, indent=2))
        return

    total = res["total"]
    if total == 0:
        print("Nothing unread. 🎉")
        return
    print(f"{total} unread:\n")
    for cat in sc.CATEGORY_ORDER:
        rows = buckets.get(cat, [])
        if not rows:
            continue
        print(f"━━ {sc.CATEGORY_TITLE[cat]} ({len(rows)}) ━━")
        for r in rows:
            who = f"{r['author']} in " if r["author"] else ""
            print(f"  {who}{r['channel_label']}")
            print(f"    {r['text']}")
            if r["permalink"]:
                print(f"    {r['permalink']}")
        print()


if __name__ == "__main__":
    main()
