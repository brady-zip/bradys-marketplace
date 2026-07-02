#!/usr/bin/env python3
"""Workstream state manager for the mem0-brady ``/mem0-brady:workstream`` skill.

A *workstream* is one thread of work that spans multiple Claude sessions —
spread across time, commits, branches, and worktrees — under a single
overarching goal. This script maintains, per workstream ``<slug>``:

  * a referenceable markdown **details doc** (the source of truth)::

        <data>/mem0-brady/workstreams/<slug>.md

    holding the Goal + a **Pieces** index (one entry per contributing worktree,
    each *referencing* that worktree's per-cwd handoff for its current state —
    referenced, never inlined) + a hand-maintained References section.

  * an **active pointer** keyed by ``session_id`` (so the tag is strictly
    per-session)::

        <data>/mem0-brady/workstreams/active/<session_id>.json

    The fork's Stop / PreCompact hooks read this (via ``hook_input.session_id``)
    to fold the workstream overview into the handoff and bake the re-activation
    call in, so the workstream rides the handoff chain forward.

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
_REFERENCES_COMMENT = (
    "<!-- free-form, hand-maintained: PRs, commits, issues, links -->"
)
_GOAL_PLACEHOLDER = "<describe the overarching objective in 1–3 sentences>"
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


def _set(sections: list[list], name: str, body: list[str]) -> None:
    for entry in sections:
        if entry[0] == name:
            entry[1] = body
            return
    sections.append([name, body])


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
        f"- created: {ts}",
        f"- updated: {ts}",
        "",
    ]
    sections: list[list] = [
        ["Goal", ["", goal or _GOAL_PLACEHOLDER, ""]],
        ["Pieces", [_PIECES_COMMENT, ""]],
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
    if created:
        text = _new_doc(slug, goal, ts)
        head, sections = _split(text)
    else:
        head, sections = _split(doc.read_text(encoding="utf-8"))
        head = [re.sub(r"^- updated:.*$", f"- updated: {ts}", ln) for ln in head]
        # Set the goal only when the current one is empty/placeholder, so a
        # provided goal seeds an under-specified doc without clobbering a real
        # hand-written one (edit the doc directly to change an existing goal).
        if goal:
            cur_goal = "\n".join(_get(sections, "Goal") or []).strip()
            if not cur_goal or cur_goal == _GOAL_PLACEHOLDER:
                _set(sections, "Goal", ["", goal, ""])
        if _get(sections, "Pieces") is None:
            _set(sections, "Pieces", [_PIECES_COMMENT, ""])
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

    print(f"{'Created and activated' if created else 'Activated'} workstream '{slug}'.")
    print(f"Doc: {doc}")
    if sid:
        print(f"Tagged this session ({sid}) via {src} — Stop/PreCompact handoffs are now workstream-aware.")
    else:
        print("WARNING: could not resolve this session's id (no per-cwd marker, no "
              "CLAUDE_CODE_SESSION_ID). The doc was updated, but the handoff won't be "
              "tagged for this session — re-run after the SessionStart hook has run.")
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
          "Run `/mem0-brady:workstream <slug>` to activate one, or `list` to see existing ones.")
    return 0


def cmd_list() -> int:
    wd = _workstream_dir()
    docs = sorted(p for p in wd.glob("*.md")) if wd.is_dir() else []
    if not docs:
        print(f"No workstreams yet (none under {wd}).")
        return 0
    print(f"Workstreams under {wd}:")
    for doc in docs:
        slug = doc.stem
        goal = "(no goal set)"
        try:
            _h, sections = _split(doc.read_text(encoding="utf-8"))
            g = "\n".join(_get(sections, "Goal") or []).strip()
            if g and g != _GOAL_PLACEHOLDER:
                goal = g.splitlines()[0]
        except OSError:
            pass
        print(f"  - {slug}: {goal}")
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
        except OSError as e:
            print(f"Could not remove {pointer}: {e}", file=sys.stderr)
            return 1
    else:
        print("This session was not tagged with a workstream.")
    return 0


def _print_overview(doc: Path) -> None:
    try:
        _h, sections = _split(doc.read_text(encoding="utf-8"))
    except OSError as e:
        print(f"Could not read {doc}: {e}", file=sys.stderr)
        return
    goal = "\n".join(_get(sections, "Goal") or []).strip() or "(no goal set)"
    pieces = [ln for ln in (_get(sections, "Pieces") or []) if ln.lstrip().startswith("- **")]
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
        return cmd_list()
    if cmd == "deactivate":
        return cmd_deactivate()
    print(f"usage: workstream.py {{activate <slug> [goal]|show [slug]|list|deactivate}}",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
