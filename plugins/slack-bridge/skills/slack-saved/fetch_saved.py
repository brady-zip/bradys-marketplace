# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Dump the user's hydrated Slack 'Later' (saved) items as JSON, for the /slack-saved digest.

Thin CLI wrapper over the shared slack_client (../../server/slack_client.py). Read-only.

    uv run fetch_saved.py --json            # in-progress backlog, hydrated, newest-saved first
    uv run fetch_saved.py --json --all      # include completed + archived
    uv run fetch_saved.py --include-snoozed  # also show items snoozed to a future date
    uv run fetch_saved.py                    # human-readable summary

Active snoozes (recorded via record_decision) are hidden by default; each remaining item is
tagged with prior_decision if one was recorded on an earlier run.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import decisions as dec  # noqa: E402
import slack_client as sc  # noqa: E402


def main():
    as_json = "--json" in sys.argv
    state = None if "--all" in sys.argv else "in_progress"
    include_snoozed = "--include-snoozed" in sys.argv
    try:
        sl = sc.Slack.from_env()
        res = sc.saved_list(sl, state=state)
        rows = sc.hydrate_saved(sl, res["items"])
    except sc.SlackError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    rows, snoozed_hidden = dec.annotate_and_filter(rows, include_snoozed=include_snoozed)

    if as_json:
        print(json.dumps({"total": len(rows), "snoozed_hidden": snoozed_hidden, "items": rows}, indent=2))
        return

    if snoozed_hidden:
        print(f"({snoozed_hidden} snoozed item(s) hidden — pass --include-snoozed to show)\n")

    import datetime as dt

    def d(ts):
        return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d") if ts else "—"

    print(f"{len(rows)} saved items:\n")
    for r in rows:
        who = f"{r['author']} in " if r["author"] else ""
        print(f"  [{r['state']}] saved {d(r['date_created'])} · due {d(r['date_due'])} — {who}{r['channel_label']}")
        print(f"    {r['text']}")
        if r["permalink"]:
            print(f"    {r['permalink']}")
        print()


if __name__ == "__main__":
    main()
