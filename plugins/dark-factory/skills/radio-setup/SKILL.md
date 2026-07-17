---
name: radio-setup
description: Set up the dark factory agent radio in the current repository for both Claude Code and Codex. Use when the user asks to "set up dark factory radio", "install the radio pattern", "onboard this repo to dark factory radio", "configure codex radio", or after installing the dark-factory plugin and wanting a repo wired up. Runs preflight checks, `h5i init`, deploys the radio command/skill/prompt into .claude and .codex, provisions GSD (get-shit-done core) for Codex, sets the identity env + SessionEnd cleanup hook, and merges the Codex SessionStart prelude adapter into .codex/hooks.json. Idempotent and drift-protected.
---

# dark factory radio — coordinated setup

Onboard the **current git repository** to the dark factory radio pattern for both runtimes.
Claude Code cannot install a plugin into Codex, so this deploys committed copies of
the radio assets that Codex discovers, plus the identity env, the SessionEnd
cleanup hook, and the Codex SessionStart prelude adapter (the afferent fix for the
`[`-leading JSON-rejection bug). It also **provisions GSD (get-shit-done core)** for
Codex via GSD's own pinned npm installer. The engine (`scripts/setup.sh`) owns all
logic — this skill orchestrates it and gates the one destructive path (`--force`)
behind explicit user confirmation.

## What it deploys (see `deploy-manifest.json`)

- `.claude/commands/radio.md` — `/radio` operator loop (Monitor-based)
- `.claude/skills/radio-ask/**` and `.codex/skills/radio-ask/**` — the one-off `$radio-ask` skill
- `.codex/prompts/radio.md` — Codex `/radio` operator loop (blocking wait)
- `.dark-factory/identity-lock.sh` — the identity lock helper (committed; both runtimes call it)
- `.codex/hooks/dark-factory-codex-session-start.cjs` + `.codex/hooks/package.json` — Codex SessionStart prelude adapter files
- `.codex/hooks.json` — the adapter's SessionStart entry is **merged** in (created if absent, appended if GSD/another tool already owns it; never clobbered)
- **GSD (get-shit-done core)** — provisioned via `npx -y --package=@opengsd/gsd-core@<pinned> -- gsd-core --codex --full`; skipped if `.codex/gsd-core` is already present
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
  `git add .claude .codex .dark-factory AGENTS.md && git commit -m "chore: dark factory radio setup"`
- Newly deployed hooks/skills load at **session start**, so restart the Claude
  session (or start Codex) to pick them up.
- Enter radio with `/radio` (Claude) or the `radio` prompt (Codex); use a fresh
  identity like `/radio claude-roadmap`. **One live session per identity.**

## Modes

- `--check` — read-only; preflight + status; exit 3 if pending.
- `--dry-run` — show what would change, write nothing.
- `--force` — overwrite a locally-edited managed file (destructive; confirm first).
- `--skip-h5i-init` — deploy assets but do not run `h5i init`.
- `--skip-gsd` — deploy assets but do not provision GSD (get-shit-done core).

## Notes

- **Idempotent:** keyed on file content and settings equality — re-running is a no-op.
- **Non-destructive to settings:** only `env.H5I_AGENT` and the `SessionEnd` hook
  entry are added; all other `settings.json` keys are preserved. `settings.json`
  is backed up before any write.
- **Non-destructive to `.codex/hooks.json`:** the SessionStart adapter entry is
  merged in by `jq` — if GSD (or another tool) already owns the file, our entry is
  appended and every other entry is preserved; the file is backed up before any
  write. No hand-merge needed.
- **GSD provisioning:** runs GSD's own installer (`@opengsd/gsd-core`, pinned) for
  the Codex runtime. It is **idempotent** — skipped when `.codex/gsd-core` already
  exists — and **non-fatal**: if `npx` is missing or the install fails, setup logs
  it and continues. GSD must be installed *before* the `.codex/hooks.json` merge
  (it owns that file); the engine orders these correctly. Use `--skip-gsd` to opt out.
- **Codex has no SessionEnd hook**, so its identity lock is released by the radio
  prompt at loop-exit, not automatically. A crashed Codex session can leave a
  stale lock — clear it with `.dark-factory/identity-lock.sh release <identity> --force`.
