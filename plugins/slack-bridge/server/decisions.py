# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""decisions.py — durable JSON store of /slack-saved triage decisions.

Keyed by "<item_id>:<ts>". Records what the user decided about each saved item
(done | archive | keep | snooze | reply | review | do) so decisions survive across runs, and so
**snoozed items stay hidden until their snooze_until date** when /slack-saved is invoked again.

Stdlib only; shared by server.py (the record_decision tool + list_saved suppression) and the
skill's fetch_saved.py. The store lives outside git at ~/.config/slack-bridge/saved-decisions.json
(override with $SLACK_BRIDGE_DECISIONS).
"""

from __future__ import annotations

import json
import os
import time

STORE_PATH = os.path.expanduser(
    os.environ.get("SLACK_BRIDGE_DECISIONS") or "~/.config/slack-bridge/saved-decisions.json"
)

VALID_DECISIONS = {"done", "archive", "keep", "snooze", "reply", "review", "do"}


def _key(item_id, ts):
    return f"{item_id}:{ts}"


def load(path=STORE_PATH):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def save(data, path=STORE_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, path)  # atomic


def get(item_id, ts, path=STORE_PATH):
    return load(path).get(_key(item_id, str(ts)))


def record(item_id, ts, decision, snooze_until=None, note="", channel_label="", gist="",
           now=None, path=STORE_PATH):
    """Upsert a decision. For decision='snooze', snooze_until (unix ts) is required to suppress
    the item until then."""
    if decision not in VALID_DECISIONS:
        raise ValueError(f"decision must be one of {sorted(VALID_DECISIONS)}, got {decision!r}")
    if decision == "snooze" and not snooze_until:
        raise ValueError("snooze requires snooze_until (unix timestamp)")
    now = int(now if now is not None else time.time())
    data = load(path)
    entry = {
        "item_id": item_id,
        "ts": str(ts),
        "decision": decision,
        "decided_at": now,
        "snooze_until": int(snooze_until) if snooze_until else None,
        "note": note,
        "channel_label": channel_label,
        "gist": gist,
    }
    data[_key(item_id, str(ts))] = entry
    save(data, path)
    return entry


def annotate_and_filter(rows, now=None, include_snoozed=False, path=STORE_PATH):
    """Given hydrated/raw saved rows (each with item_id + ts), drop items currently snoozed
    (snooze_until in the future) and tag the rest with prior_decision / prior_snooze_until.
    Returns (kept_rows, suppressed_count)."""
    now = int(now if now is not None else time.time())
    store = load(path)
    out, suppressed = [], 0
    for r in rows:
        d = store.get(_key(r.get("item_id", ""), str(r.get("ts", ""))))
        if d:
            snoozed = d.get("decision") == "snooze" and (d.get("snooze_until") or 0) > now
            if snoozed and not include_snoozed:
                suppressed += 1
                continue
            r = {**r, "prior_decision": d.get("decision"), "prior_snooze_until": d.get("snooze_until")}
        out.append(r)
    return out, suppressed


def active_snoozes(now=None, path=STORE_PATH):
    """Currently-suppressed items: {key: entry} with decision=snooze and snooze_until in future."""
    now = int(now if now is not None else time.time())
    return {k: v for k, v in load(path).items()
            if v.get("decision") == "snooze" and (v.get("snooze_until") or 0) > now}


if __name__ == "__main__":
    # Quick dump for debugging: counts + active snoozes.
    data = load()
    snz = active_snoozes()
    print(f"store: {STORE_PATH}")
    print(f"decisions: {len(data)} | active snoozes: {len(snz)}")
    from collections import Counter
    c = Counter(v.get("decision") for v in data.values())
    for k, n in c.most_common():
        print(f"  {k}: {n}")
