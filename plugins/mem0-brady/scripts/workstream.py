#!/usr/bin/env python3
"""Workstream state manager for the mem0-brady ``/mem0-brady:workstream`` skill.

A *workstream* is one thread of work that spans multiple Claude sessions —
spread across time, commits, branches, and worktrees — under a single
overarching goal. This script maintains, per workstream ``<slug>``:

  * a referenceable markdown **details doc** (the source of truth)::

        <data>/mem0-brady/workstreams/<slug>.md

    holding a lifecycle ``status`` (``active`` or ``archived``) + the Goal + a
    **Pieces** index (one entry per contributing worktree, each *referencing*
    that worktree's per-cwd handoff for its current state — referenced, never
    inlined) + a **Narrative** pointer + a hand-maintained References section.

    The doc holds what must be enumerated exactly — goal, config, artifact
    pointers, the piece index. It deliberately does NOT hold narrative history:
    while a session is tagged, capture stamps ``run_id=<slug>``, making the
    thread's history a real mem0 scope that is searched by relevance rather
    than read whole. That is what keeps a long-lived doc a fixed size instead
    of growing past the point anyone rereads it.

  * an **active pointer** keyed by ``session_id`` (so the tag is strictly
    per-session)::

        <data>/mem0-brady/workstreams/active/<session_id>.json

    The fork's Stop / PreCompact hooks read this (via ``hook_input.session_id``)
    to decide whether to write a handoff at all — only a tagged session gets one
    — and, when they do, to fold the workstream overview in and bake the
    re-activation call in, so the workstream rides the handoff chain forward.

Note the two senses of "active", which are orthogonal: the doc's ``status`` says
whether the *thread* is still being worked, while an active pointer says a
*session* is currently tagged. Archiving is what keeps ``list`` readable once a
year of finished threads has piled up — it hides them from the default listing
without deleting the doc, its run scope, or the handoffs it references.

Paths and the cwd hash scheme are kept in lockstep with the fork's
``_workstream_dir`` / ``_handoff_path_for`` and the plugin's per-cwd session
marker. Stdlib only; fail-soft.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

_PIECES_COMMENT = (
    "<!-- current state of each piece lives in its referenced handoff — "
    "read on demand; NOT auto-injected -->"
)
# The doc holds what must be ENUMERATED EXACTLY; mem0 holds what is better
# RANKED. Keeping narrative out of References is what stops a long-lived
# workstream doc from growing into something too big to read — which is the
# failure mode it had, since every session appended and none ever pruned.
_REFERENCES_COMMENT = (
    "<!-- free-form, hand-maintained: PRs, commits, issues, links. "
    "Pointers and config only — narrative history belongs in mem0 under "
    "run_id, where it comes back ranked instead of read whole. -->"
)
_NARRATIVE_COMMENT = (
    "<!-- managed: how to pull this workstream's history back, ranked -->"
)
_GOAL_PLACEHOLDER = "<describe the overarching objective in 1–3 sentences>"

_STATUS_ACTIVE = "active"
_STATUS_ARCHIVED = "archived"
_STATUSES = (_STATUS_ACTIVE, _STATUS_ARCHIVED)


def _narrative_body(slug: str) -> list[str]:
    """The Narrative section: a query, not a transcript.

    While a session is tagged with this workstream, capture stamps run_id=<slug>
    on the memory it writes. That makes the thread's history a real mem0 scope —
    searchable by relevance, filterable, and retirable in one call — so this
    section stays a fixed three lines no matter how long the workstream runs,
    instead of accumulating prose nobody rereads.
    """
    return [
        _NARRATIVE_COMMENT,
        "",
        f"Session history for this workstream is captured in mem0 under "
        f"`run_id={slug}`. Pull the relevant parts rather than reading it all:",
        "",
        f'- `mcp__mem0__search_memories(query="<what you need>", run_id="{slug}")` '
        f"— ranked by relevance to the question at hand",
        f'- `mcp__mem0__get_memories(run_id="{slug}")` — everything, newest first',
        "",
        "Per-piece *current* state is in each piece's handoff, above. This is the "
        "cross-session narrative: what was tried, what was decided, what broke.",
        "",
    ]
_PRUNE_DAYS = 30


# --- paths (must match the fork + lib-recall-log.sh) ------------------------

def _data_root() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME", "").strip()
    return Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share"


def _workstream_dir() -> Path:
    override = os.environ.get("MEM0_WORKSTREAM_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return _data_root() / "mem0-brady" / "workstreams"


def _active_dir() -> Path:
    return _workstream_dir() / "active"


def _sessions_dir() -> Path:
    override = os.environ.get("MEM0_BRADY_SESSIONS_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return _data_root() / "mem0-brady" / "sessions"


def _handoff_dir() -> Path:
    override = os.environ.get("MEM0_HANDOFF_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return _data_root() / "mem0-brady" / "handoffs"


# --- small helpers ----------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha8(s: str) -> str:
    return hashlib.sha1((s or "").encode("utf-8")).hexdigest()[:8]


def _safe_slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", s or "").strip("-")


def _safe_name(s: str) -> str:
    return _safe_slug(s) or "project"


def _handoff_path(cwd: str) -> Path:
    """Mirror the fork's _handoff_path_for: <safe(basename)>-<sha1(cwd)[:8]>.md."""
    name = _safe_name(Path(cwd).name)
    return _handoff_dir() / f"{name}-{_sha8(cwd or Path(cwd).name)}.md"


def _doc_path(slug: str) -> Path:
    return _workstream_dir() / f"{slug}.md"


def _git_branch(cwd: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def _resolve_session_id(cwd: str) -> tuple[str, str]:
    """Return (session_id, source). Prefer the per-cwd SessionStart marker
    (the id the Stop hook will also report); fall back to the env var."""
    marker = _sessions_dir() / f"{_sha8(cwd)}.json"
    try:
        if marker.is_file():
            sid = json.loads(marker.read_text(encoding="utf-8")).get("session_id")
            if sid:
                return str(sid), "per-cwd marker"
    except (OSError, json.JSONDecodeError):
        pass
    env = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if env:
        return env, "CLAUDE_CODE_SESSION_ID env (unverified)"
    return "", "none"


# --- markdown doc parse / build ---------------------------------------------

def _split(text: str) -> tuple[list[str], list[list]]:
    """Split into (header lines before first '## ', [ [name, body_lines], ... ])."""
    head: list[str] = []
    sections: list[list] = []
    cur: list | None = None
    for ln in text.splitlines():
        m = re.match(r"^## (.+?)\s*$", ln)
        if m:
            cur = [m.group(1).strip(), []]
            sections.append(cur)
        elif cur is None:
            head.append(ln)
        else:
            cur[1].append(ln)
    return head, sections


def _join(head: list[str], sections: list[list]) -> str:
    out = list(head)
    for name, body in sections:
        out.append(f"## {name}")
        out.extend(body)
    return "\n".join(out).rstrip() + "\n"


def _get(sections: list[list], name: str) -> list[str] | None:
    for n, body in sections:
        if n == name:
            return body
    return None


def _set_before(sections: list[list], name: str, body: list[str], anchor: str) -> None:
    """Set *name*, inserting before *anchor* when it has to be created.

    Same as ``_set`` for a section that already exists; the difference is only
    where a NEW one lands, so a doc that predates a section ends up with the
    same layout as one created fresh.
    """
    for entry in sections:
        if entry[0] == name:
            entry[1] = body
            return
    for i, entry in enumerate(sections):
        if entry[0] == anchor:
            sections.insert(i, [name, body])
            return
    sections.append([name, body])


def _set(sections: list[list], name: str, body: list[str]) -> None:
    for entry in sections:
        if entry[0] == name:
            entry[1] = body
            return
    sections.append([name, body])


def _head_field(head: list[str], key: str) -> str:
    for ln in head:
        m = re.match(rf"^- {re.escape(key)}:\s*(.*)$", ln)
        if m:
            return m.group(1).strip()
    return ""


def _set_head_field(head: list[str], key: str, value: str, after: str) -> None:
    """Set ``- <key>: <value>`` in the header, inserting after ``- <after>:``.

    Insertion matters for docs written before a field existed: appending would
    land it past the blank line that ends the header block, so an old doc would
    render differently from a fresh one.
    """
    for i, ln in enumerate(head):
        if re.match(rf"^- {re.escape(key)}:", ln):
            head[i] = f"- {key}: {value}"
            return
    for i, ln in enumerate(head):
        if re.match(rf"^- {re.escape(after)}:", ln):
            head.insert(i + 1, f"- {key}: {value}")
            return
    head.append(f"- {key}: {value}")


def _status(head: list[str]) -> str:
    """The doc's lifecycle status, defaulting to active.

    Docs written before the status field existed have none; they are threads
    nobody archived, so active is the honest reading — and the field is
    backfilled the next time the doc is written.
    """
    val = _head_field(head, "status").lower()
    return val if val in _STATUSES else _STATUS_ACTIVE


def _read_doc(doc: Path) -> tuple[list[str], list[list]] | None:
    try:
        return _split(doc.read_text(encoding="utf-8"))
    except OSError as e:
        print(f"Could not read {doc}: {e}", file=sys.stderr)
        return None


def _untag_sessions(slug: str) -> int:
    """Drop every active pointer for *slug*; returns how many were removed.

    Archiving is a statement that the thread is done, so leaving sessions tagged
    would keep them writing handoffs for it and stamping run_id=<slug> on new
    captures — which is exactly the accumulation archiving is meant to stop.
    """
    ad = _active_dir()
    if not ad.is_dir():
        return 0
    n = 0
    for p in sorted(ad.glob("*.json")):
        try:
            if json.loads(p.read_text(encoding="utf-8")).get("slug") == slug:
                p.unlink()
                n += 1
        except (OSError, json.JSONDecodeError):
            pass
    return n


def _piece_line(cwd: str, branch: str, handoff: Path, ts: str) -> str:
    return (
        f"- **{Path(cwd).name}** — cwd `{cwd}` · branch `{branch or '(detached)'}`"
        f" · handoff `{handoff}` · last active {ts}"
    )


def _new_doc(slug: str, goal: str, ts: str) -> str:
    head = [
        "<!-- mem0-brady workstream (maintained by /mem0-brady:workstream) -->",
        f"# Workstream — {slug}",
        "",
        f"- slug: {slug}",
        f"- status: {_STATUS_ACTIVE}",
        f"- created: {ts}",
        f"- updated: {ts}",
        "",
    ]
    sections: list[list] = [
        ["Goal", ["", goal or _GOAL_PLACEHOLDER, ""]],
        ["Pieces", [_PIECES_COMMENT, ""]],
        ["Narrative", _narrative_body(slug)],
        ["References", [_REFERENCES_COMMENT, ""]],
    ]
    return _join(head, sections)


# --- commands ---------------------------------------------------------------

def cmd_activate(rest: list[str]) -> int:
    if not rest:
        print("usage: workstream.py activate <slug> [goal...]", file=sys.stderr)
        return 2
    slug = _safe_slug(rest[0])
    if not slug:
        print(f"invalid slug: {rest[0]!r}", file=sys.stderr)
        return 2
    goal = " ".join(rest[1:]).strip()
    cwd = os.getcwd()
    ts = _now()
    branch = _git_branch(cwd)
    handoff = _handoff_path(cwd)
    doc = _doc_path(slug)

    _workstream_dir().mkdir(parents=True, exist_ok=True)
    _active_dir().mkdir(parents=True, exist_ok=True)

    created = not doc.exists()
    revived = False
    if created:
        text = _new_doc(slug, goal, ts)
        head, sections = _split(text)
    else:
        head, sections = _split(doc.read_text(encoding="utf-8"))
        head = [re.sub(r"^- updated:.*$", f"- updated: {ts}", ln) for ln in head]
        # Activating an archived workstream revives it: you are picking the
        # thread back up, and a tagged session would otherwise keep writing
        # handoffs and run-scoped captures for a thread the listing hides.
        revived = _status(head) == _STATUS_ARCHIVED
        _set_head_field(head, "status", _STATUS_ACTIVE, after="slug")
        # Set the goal only when the current one is empty/placeholder, so a
        # provided goal seeds an under-specified doc without clobbering a real
        # hand-written one (edit the doc directly to change an existing goal).
        if goal:
            cur_goal = "\n".join(_get(sections, "Goal") or []).strip()
            if not cur_goal or cur_goal == _GOAL_PLACEHOLDER:
                _set(sections, "Goal", ["", goal, ""])
        if _get(sections, "Pieces") is None:
            _set(sections, "Pieces", [_PIECES_COMMENT, ""])
        # Backfilled on activation so docs created before run_id scoping pick it
        # up. Rewritten every time rather than only when absent: it is a fixed
        # pointer derived from the slug, not user content, so there is nothing
        # to preserve and drift would just leave a stale query in the doc.
        # Placed before References to match a freshly-created doc — a plain
        # append would land it after the hand-maintained section, so the two
        # would read differently depending on when the workstream was started.
        _set_before(sections, "Narrative", _narrative_body(slug), "References")
        if _get(sections, "References") is None:
            _set(sections, "References", [_REFERENCES_COMMENT, ""])

    # Rebuild the (fully-managed) Pieces section: comment + every other piece +
    # this cwd's piece (deduped by cwd). References stay verbatim (hand-edited).
    existing = [
        ln for ln in (_get(sections, "Pieces") or [])
        if ln.lstrip().startswith("- **") and f"cwd `{cwd}`" not in ln
    ]
    _set(sections, "Pieces", [_PIECES_COMMENT] + existing + [_piece_line(cwd, branch, handoff, ts), ""])

    doc.write_text(_join(head, sections), encoding="utf-8")

    sid, src = _resolve_session_id(cwd)
    if sid:
        pointer = {
            "slug": slug,
            "doc_path": str(doc),
            "cwd": cwd,
            "branch": branch,
            "session_id": sid,
            "activated_at": ts,
        }
        (_active_dir() / f"{sid}.json").write_text(
            json.dumps(pointer, indent=2) + "\n", encoding="utf-8"
        )
    _prune()

    if created:
        verb = "Created and activated"
    elif revived:
        verb = "Un-archived and activated"
    else:
        verb = "Activated"
    print(f"{verb} workstream '{slug}'.")
    print(f"Doc: {doc}")
    if sid:
        print(f"Tagged this session ({sid}) via {src} — Stop/PreCompact will now write a "
              "workstream-aware handoff for this cwd.")
    else:
        print("WARNING: could not resolve this session's id (no per-cwd marker, no "
              "CLAUDE_CODE_SESSION_ID). The doc was updated, but this session is NOT "
              "tagged, so it will write no handoff — re-run after the SessionStart hook "
              "has run.")
    print()
    _print_overview(doc)
    return 0


def cmd_show(rest: list[str]) -> int:
    cwd = os.getcwd()
    if rest:
        slug = _safe_slug(rest[0])
        doc = _doc_path(slug)
        if not doc.is_file():
            print(f"No workstream doc for '{slug}' at {doc}", file=sys.stderr)
            return 1
        # Emit the doc path (mirrors cmd_activate) so a `file:` footer-link badge
        # keyed on this path surfaces a clickable "open the doc" affordance.
        print(f"Doc: {doc}")
        print()
        _print_overview(doc)
        return 0
    # No slug: report the workstream tagging THIS session, if any.
    sid, _src = _resolve_session_id(cwd)
    pointer = _active_dir() / f"{sid}.json" if sid else None
    if pointer and pointer.is_file():
        try:
            data = json.loads(pointer.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        slug = data.get("slug", "")
        print(f"This session is tagged with workstream '{slug}'.")
        doc = Path(data.get("doc_path") or _doc_path(slug))
        # Emit the doc path (mirrors cmd_activate) so a `file:` footer-link badge
        # keyed on this path surfaces a clickable "open the doc" affordance.
        print(f"Doc: {doc}")
        print()
        if doc.is_file():
            _print_overview(doc)
        return 0
    print("This session is not tagged with a workstream. "
          "Run `/mem0-brady:workstream <slug>` to activate one, or "
          "`/mem0-brady:workstream-list` to see the ones still open.")
    return 0


def cmd_list(rest: list[str]) -> int:
    """List workstreams. One optional argument selects the status filter.

    Defaults to active only: the whole point of archiving is that a finished
    thread stops competing for attention with the ones still being worked.
    """
    arg = (rest[0] if rest else "").strip().lower().lstrip("-")
    if arg in ("", "active"):
        want, label = {_STATUS_ACTIVE}, "active"
    elif arg in ("all", "archived-too", "include-archived"):
        want, label = set(_STATUSES), "all"
    elif arg == "archived":
        want, label = {_STATUS_ARCHIVED}, "archived"
    else:
        print(f"unknown filter {arg!r} — use one of: active (default) | all | archived",
              file=sys.stderr)
        return 2

    wd = _workstream_dir()
    docs = sorted(p for p in wd.glob("*.md")) if wd.is_dir() else []
    if not docs:
        print(f"No workstreams yet (none under {wd}).")
        return 0

    rows: list[tuple[str, str, str, str]] = []
    hidden = 0
    for doc in docs:
        goal = "(no goal set)"
        status = _STATUS_ACTIVE
        updated = ""
        parsed = _read_doc(doc)
        if parsed:
            head, sections = parsed
            status = _status(head)
            updated = _head_field(head, "updated")[:10]
            g = "\n".join(_get(sections, "Goal") or []).strip()
            if g and g != _GOAL_PLACEHOLDER:
                goal = g.splitlines()[0]
        if status not in want:
            hidden += 1
            continue
        rows.append((doc.stem, status, updated, goal))

    # Most-recently-touched first. A listing you consult to decide what to pick
    # back up is ordered by recency, not alphabet; the timestamps are ISO, so
    # they sort lexically, and an undated doc sorts last rather than first.
    rows.sort(key=lambda r: (r[2] or "", r[0]), reverse=True)

    print(f"Workstreams under {wd} ({label}):")
    if rows:
        for slug, status, updated, goal in rows:
            # Only worth marking when the listing is mixed; under `archived` the
            # tag would be on every row and say nothing.
            mark = " [archived]" if status == _STATUS_ARCHIVED and label == "all" else ""
            print(f"  - {slug}{mark} — updated {updated or 'unknown'} — {goal}")
    else:
        print(f"  (none {label})")
    if hidden:
        other = "active" if label == "archived" else "archived"
        print(f"\n{hidden} {other} workstream(s) not shown — "
              f"`/mem0-brady:workstream-list all` to include them.")
    if rows:
        # The doc gives the goal (what this is FOR); only the run scope knows
        # where it got to. This script is stdlib-only and never talks to mem0,
        # so it emits the slugs to fetch and leaves the synthesis to the caller.
        print("\nRun scopes for current state (mem0 run_id, one per workstream):")
        print("  " + " ".join(slug for slug, _s, _u, _g in rows))
    return 0


def _cmd_set_status(rest: list[str], status: str) -> int:
    """Flip a workstream's lifecycle status (shared by archive / unarchive)."""
    verb = "archive" if status == _STATUS_ARCHIVED else "unarchive"
    slug = _safe_slug(rest[0]) if rest else ""
    if not slug and status == _STATUS_ARCHIVED:
        # Bare `archive` means "the one tagging this session" — the common case,
        # since you archive a thread at the moment you finish working it.
        sid, _src = _resolve_session_id(os.getcwd())
        pointer = _active_dir() / f"{sid}.json" if sid else None
        if pointer and pointer.is_file():
            try:
                slug = json.loads(pointer.read_text(encoding="utf-8")).get("slug", "")
            except (OSError, json.JSONDecodeError):
                slug = ""
    if not slug:
        print(f"usage: workstream.py {verb} <slug>"
              + (" (or omit <slug> to archive the one tagging this session)"
                 if status == _STATUS_ARCHIVED else ""),
              file=sys.stderr)
        return 2

    doc = _doc_path(slug)
    if not doc.is_file():
        print(f"No workstream doc for '{slug}' at {doc}", file=sys.stderr)
        return 1
    parsed = _read_doc(doc)
    if parsed is None:
        return 1
    head, sections = parsed
    if _status(head) == status:
        print(f"Workstream '{slug}' is already {status}.")
        return 0
    _set_head_field(head, "status", status, after="slug")
    head = [re.sub(r"^- updated:.*$", f"- updated: {_now()}", ln) for ln in head]
    doc.write_text(_join(head, sections), encoding="utf-8")

    print(f"Workstream '{slug}' is now {status}.")
    print(f"Doc: {doc}")
    if status == _STATUS_ARCHIVED:
        n = _untag_sessions(slug)
        if n:
            print(f"Untagged {n} session(s) that were still riding this workstream — "
                  "they will stop writing handoffs for it.")
        print("Nothing was deleted: the doc, its handoffs, and its mem0 run scope "
              f"(`run_id={slug}`) are intact — it is just hidden from the default "
              "listing. Re-activating it un-archives it.")
        print(f"To retire the history too: mcp__mem0__delete_entities(run_id=\"{slug}\")")
    else:
        print("It shows in the default listing again. Activating it in a worktree "
              "re-tags this session and registers that worktree as a piece.")
    return 0


def cmd_deactivate() -> int:
    cwd = os.getcwd()
    sid, _src = _resolve_session_id(cwd)
    if not sid:
        print("Could not resolve this session's id; nothing to deactivate.")
        return 0
    pointer = _active_dir() / f"{sid}.json"
    if pointer.is_file():
        try:
            pointer.unlink()
            print(f"Deactivated: removed the workstream tag for this session ({sid}).")
            print("The workstream itself is untouched and still listed as open — "
                  "`archive` it when the thread is finished.")
        except OSError as e:
            print(f"Could not remove {pointer}: {e}", file=sys.stderr)
            return 1
    else:
        print("This session was not tagged with a workstream.")
    return 0


def _print_overview(doc: Path) -> None:
    parsed = _read_doc(doc)
    if parsed is None:
        return
    head, sections = parsed
    goal = "\n".join(_get(sections, "Goal") or []).strip() or "(no goal set)"
    pieces = [ln for ln in (_get(sections, "Pieces") or []) if ln.lstrip().startswith("- **")]
    status = _status(head)
    print(f"Status: {status}")
    if status == _STATUS_ARCHIVED:
        print("  (finished — hidden from the default listing; activating it un-archives it)")
    print()
    print("Goal:")
    for ln in goal.splitlines():
        print(f"  {ln}")
    print()
    print("Pieces (current state is in each referenced handoff — read on demand, NOT auto-loaded):")
    if pieces:
        for ln in pieces:
            print(f"  {ln}")
    else:
        print("  (none registered yet)")
    # Printed rather than left to the doc so the query is in front of you at the
    # moment you are deciding what to catch up on.
    slug = doc.stem
    print()
    print("Narrative (cross-session history — search it, don't read it all):")
    print(f'  mcp__mem0__search_memories(query="<what you need>", run_id="{slug}")')


def _prune(days: int = _PRUNE_DAYS) -> None:
    """Drop active pointers older than *days* (ended sessions otherwise linger)."""
    ad = _active_dir()
    if not ad.is_dir():
        return
    cutoff = time.time() - days * 86400
    for p in ad.glob("*.json"):
        try:
            if p.stat().st_mtime < cutoff:
                p.unlink()
        except OSError:
            pass


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "show"
    rest = argv[1:]
    if cmd == "activate":
        return cmd_activate(rest)
    if cmd == "show":
        return cmd_show(rest)
    if cmd == "list":
        return cmd_list(rest)
    if cmd == "archive":
        return _cmd_set_status(rest, _STATUS_ARCHIVED)
    if cmd == "unarchive":
        return _cmd_set_status(rest, _STATUS_ACTIVE)
    if cmd == "deactivate":
        return cmd_deactivate()
    print("usage: workstream.py {activate <slug> [goal]|show [slug]|"
          "list [active|all|archived]|archive [slug]|unarchive <slug>|deactivate}",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
