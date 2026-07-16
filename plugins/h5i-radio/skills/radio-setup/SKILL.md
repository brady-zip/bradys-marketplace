---
name: radio-setup
description: Set up the h5i agent radio in the current repository for both Claude Code and Codex. Use when the user asks to "set up h5i radio", "install the radio pattern", "onboard this repo to h5i radio", "configure codex radio", or after installing the h5i-radio plugin and wanting a repo wired up. Runs preflight checks, `h5i init`, deploys the radio command/skill/prompt into .claude and .codex, sets the identity env + SessionEnd cleanup hook, and installs the Codex SessionStart prelude adapter. Idempotent and drift-protected.
---

# h5i radio — coordinated setup

Onboard the **current git repository** to the h5i radio pattern for both runtimes.
Claude Code cannot install a plugin into Codex, so this deploys committed copies of
the radio assets that Codex discovers, plus the identity env, the SessionEnd
cleanup hook, and the Codex SessionStart prelude adapter (the afferent fix for the
`[`-leading JSON-rejection bug). The engine (`scripts/setup.sh`) owns all logic —
this skill orchestrates it and gates the one destructive path (`--force`) behind
explicit user confirmation.

## What it deploys (see `deploy-manifest.json`)

- `.claude/commands/radio.md` — `/radio` operator loop (Monitor-based)
- `.claude/skills/radio-ask/**` and `.codex/skills/radio-ask/**` — the one-off `$radio-ask` skill
- `.codex/prompts/radio.md` — Codex `/radio` operator loop (blocking wait)
- `.h5i-radio/identity-lock.sh` — the identity lock helper (committed; both runtimes call it)
- `.codex/hooks.json` + `.codex/hooks/h5i-codex-session-start.cjs` + `.codex/hooks/package.json` — Codex SessionStart prelude adapter
- `.claude/settings.json` — merges `env.H5I_AGENT=claude` + a `SessionEnd` hook that releases the identity lock
- runs `h5i init` — generates `.claude/h5i.md` + `AGENTS.md`

## Steps

### 1. Always check first (read-only)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --check
```

This runs preflight (git, h5i, node, jq) and reports each item's status. Exit 3
means work is pending. If preflight fails, surface exactly what's missing and stop
— do not attempt to apply.

### 2. Apply

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```

Files that already match are left alone. A file the user has **locally edited**
(differs from the plugin copy) is reported as `CONFLICT` and skipped.

### 3. Only if there are conflicts — confirm before overwriting

A `CONFLICT` means a managed file was edited since it was deployed. Surface which
file(s) and **ask the user** before discarding their edits. Only then:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --force
```

### 4. Report and remind

Relay the summary, then remind the user (the engine also prints these):

- **Launch Codex with its identity:** `H5I_AGENT=codex codex`, and trust project
  hooks via Codex's `/hooks` so the SessionStart prelude runs.
- **Commit the deployed files** — GSD-style resets discard uncommitted work, and
  Codex reads the committed `.codex/` copies:
  `git add .claude .codex .h5i-radio AGENTS.md && git commit -m "chore: h5i radio setup"`
- Newly deployed hooks/skills load at **session start**, so restart the Claude
  session (or start Codex) to pick them up.
- Enter radio with `/radio` (Claude) or the `radio` prompt (Codex); use a fresh
  identity like `/radio claude-roadmap`. **One live session per identity.**

## Modes

- `--check` — read-only; preflight + status; exit 3 if pending.
- `--dry-run` — show what would change, write nothing.
- `--force` — overwrite a locally-edited managed file (destructive; confirm first).
- `--skip-h5i-init` — deploy assets but do not run `h5i init`.

## Notes

- **Idempotent:** keyed on file content and settings equality — re-running is a no-op.
- **Non-destructive to settings:** only `env.H5I_AGENT` and the `SessionEnd` hook
  entry are added; all other `settings.json` keys are preserved. `settings.json`
  is backed up before any write.
- `.codex/hooks.json` is `noClobber` — if the repo already has one (e.g. GSD),
  it is **not** overwritten; merge the SessionStart entry by hand from
  `${CLAUDE_PLUGIN_ROOT}/codex/hooks.json`.
- **Codex has no SessionEnd hook**, so its identity lock is released by the radio
  prompt at loop-exit, not automatically. A crashed Codex session can leave a
  stale lock — clear it with `.h5i-radio/identity-lock.sh release <identity> --force`.
