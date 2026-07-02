---
name: workstream
description: Activate or manage a "workstream" — one thread of work that spans multiple Claude sessions, commits, branches, and worktrees, under a single overarching goal. Activating tags THIS session with the workstream, pulls its details doc (goal + an index of the pieces of work, each referencing its own handoff for current state), and makes the Stop/PreCompact handoffs workstream-aware so the workstream propagates to future sessions via the handoff chain. Use when the user says "activate workstream", "track this as a workstream", "what workstream am I on", "start/resume workstream <name>", or when a resume handoff says to run `/mem0-brady:workstream <slug>`.
---

# Workstreams

A **workstream** groups multi-session work — spread across time, commits, branches, and
worktrees — under one overarching goal. Each contributing worktree already gets its own
per-cwd resume **handoff**; a workstream is the higher-level thread that ties those handoffs
together and carries the shared goal forward.

How it works:

- **Tagging is manual + per-session.** A fresh session starts untagged. Running this skill
  tags *this* session (an active pointer keyed on `session_id`) and updates the workstream's
  details doc.
- **Propagation rides the handoff.** When a session is tagged, the fork's Stop / PreCompact
  hooks fold the workstream's overview into the handoff recap and bake a
  `/mem0-brady:workstream <slug>` call into it. A future session that resumes from that
  handoff runs the skill, re-tags itself, and pulls the workstream forward.
- **Current state is referenced, not inlined.** The details doc's **Pieces** index points at
  each worktree's handoff. You read those on demand — they are never auto-injected.

All state lives under `~/.local/share/mem0-brady/` (`workstreams/<slug>.md`, the source of
truth; `workstreams/active/<session_id>.json`, the per-session tag). The helper script does
all file I/O deterministically.

<precheck>

This skill needs `python3` (stdlib only) and a SessionStart marker for the current cwd (written
by the plugin's `steer.sh` hook so the tag binds to the id the Stop hook reports):

```bash
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — required for /mem0-brady:workstream"; exit 1; }
```

If `python3` is missing, **stop** and tell the user. If the activate step later warns that it
could not resolve this session's id, the plugin hooks likely didn't run this session — tell the
user to restart Claude Code (so `steer.sh` writes the per-cwd marker) and re-activate.

</precheck>

<what-to-do>

Decide the intent from the user's request (or the handoff that triggered this skill), then run
the helper and relay its output. The script is at
`${CLAUDE_PLUGIN_ROOT}/scripts/workstream.py`.

**Activate / resume a workstream** — when the user names one, says "track this as a workstream,"
or a handoff says to run `/mem0-brady:workstream <slug>`:

1. Pick the `<slug>` (kebab-case). If the handoff supplied one, use it verbatim.
2. If this is a **new** workstream and no goal is known yet, ask the user for a **one-line
   overarching goal** before activating (one question, then proceed). If resuming an existing
   one, you don't need to ask.
3. Run:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/workstream.py" activate <slug> "<one-line goal>"
   ```
   (Omit the goal when resuming an existing workstream — it won't overwrite a real goal.)
4. Relay the printed Goal + Pieces. **State explicitly** that each piece's current state lives
   in its referenced handoff and you'll read it on demand — it is not auto-loaded. If the user
   wants the latest state of a sibling piece, `Read` that piece's handoff file.

**Other intents:**

- "What workstream am I on?" → `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/workstream.py" show`
- Show a specific one → `... show <slug>`
- List all → `... list`
- Stop tagging this session → `... deactivate`

</what-to-do>

<supporting-info>

## The details doc

`~/.local/share/mem0-brady/workstreams/<slug>.md` is the source of truth and is safe to
hand-edit. The skill fully manages the **Pieces** section (one entry per worktree, deduped by
cwd) and bumps `updated`; it sets the **Goal** only when it's still the placeholder (edit the
doc directly to revise an existing goal); and it leaves the **References** section verbatim for
your free-form notes (PRs, commits, issues, links).

## Pieces are a byproduct of activation

There is no scanning or auto-detection. Each time you activate in a worktree, that worktree
(its cwd, current git branch, and handoff path) is registered as a piece. A workstream is the
set of worktrees where you've activated the same slug. To bring a brand-new worktree into a
workstream, activate the slug there — typically because you carried the slug over in a handoff.

## Why per-session

Keying the tag on `session_id` means a fresh session is untagged until you (or the handoff's
baked-in call) activate it — matching "only manual activation tags a session." The plugin's
`steer.sh` writes a per-cwd SessionStart marker so this skill learns the same `session_id` the
Stop/PreCompact hooks report; the tag is `workstreams/active/<session_id>.json`.

## Relationship to passive memory

Activation doesn't write to Mem0. Separately, while a session is tagged, the Stop hook tags its
auto-captured session summary with `workstream_id` so `/mem0-brady:digest` and passive recall
can filter by workstream — additive, with the file doc remaining the source of truth.

## Footer badge (open the active workstream doc)

Both `activate` and `show` print a `Doc: <details-doc-path>` line. If the user has a `file:`
footer-link badge configured — a `footerLinksRegexes` entry in `~/.claude/settings.json` keyed
on the `workstreams/<slug>.md` path, enabled by the local Claude Code `file:`-scheme patch —
that line renders a clickable footer badge that opens the doc in the default `.md` app. This is
user-local config (not shipped by the plugin); the helper just emits the path so the badge can
latch onto it. Nothing to do here beyond running the skill normally.

</supporting-info>
