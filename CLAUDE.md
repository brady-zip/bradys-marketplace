# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code plugin marketplace** — not an application. There is no build step, no
package manager at the root, and no CI. The deliverable is the tree itself: Claude Code
reads `.claude-plugin/marketplace.json`, clones/copies the repo, and loads each plugin
from its `source` path.

Everything is bash + stdlib Python + markdown. The only heavyweight subproject is the
vendored Python MCP server under `plugins/mem0-brady/server/`.

## Layout and the two-file invariant

```
.claude-plugin/marketplace.json     # marketplace manifest — one entry per plugin
plugins/<name>/
  .claude-plugin/plugin.json        # plugin manifest
  commands/*.md  skills/*/SKILL.md  hooks/hooks.json  scripts/  server/  README.md
```

**Every plugin's `name`, `description`, and `version` exist in two places** —
`plugins/<name>/.claude-plugin/plugin.json` and its entry in
`.claude-plugin/marketplace.json`. They must be edited together; a version bump is a
two-line commit touching both files (see `98e6fa2`). Nothing validates this.

Versions are date-based: `YYMMDD.N` (`260807.0` = 2026-08-07, first release that day).
The vendored server has its own independent semver in `pyproject.toml`.

Adding a plugin: create `plugins/<name>/` with its own `.claude-plugin/plugin.json`, then
add a marketplace entry with `"source": "./plugins/<name>"`.

## Commands

```bash
# Install from this checkout instead of GitHub — the only route before changes are pushed
claude plugin marketplace add /Users/bradywatkinson/dev/bradys-marketplace
claude plugin install <name>@bradys-marketplace
claude plugin marketplace update bradys-marketplace   # after pushing

# Manifest sanity (nothing else validates these)
jq . .claude-plugin/marketplace.json plugins/*/.claude-plugin/plugin.json

# design-ops: 13 self-checks, stdlib only, no network, no pytest
python3 plugins/design-ops/scripts/test_ux_pr_table.py
python3 plugins/design-ops/scripts/ux_pr_table.py --probe   # which Linear route is live

# mem0-brady vendored server (cd plugins/mem0-brady/server first)
python3 -m pytest tests/unit/ -v                  # mocked, no infra
python3 -m pytest tests/contract/ -v              # validates mem0ai internal API assumptions
python3 -m pytest tests/integration/ -v           # needs live Qdrant + Neo4j + Ollama
python3 -m pytest tests/ -m "not integration" -v
python3 -m pytest tests/unit/test_auth.py::TestIsOatToken::test_oat_token_detected -v

# Each user-facing plugin ships its own health check
bash plugins/<name>/scripts/check-setup.sh        # slack-bridge, dark-factory
bash plugins/mem0-brady/scripts/doctor.sh         # or /mem0-brady:doctor
```

When working inside `plugins/mem0-brady/server/`, read its own `CLAUDE.md` — it documents
the module roles and the mem0ai-specific landmines (graph deletion bug, mutable
`enable_graph` state, eager reranker construction) that are not repeated here.

## Cross-cutting conventions

- **`${CLAUDE_PLUGIN_ROOT}`** is how hooks, `.mcp.json`, and skills address plugin files.
  Never hardcode an install path — plugins run from `~/.claude/plugins/marketplaces/...`,
  from a local checkout, or from a sparse clone.
- **One config file per plugin, outside the repo**: `~/.config/<plugin>/.env`, chmod 600,
  owned by that plugin's `setup.sh`. Deliberately no `.env` inside the source tree — a
  second copy is how a live key ends up committed-adjacent and how an edit lands on the
  copy nothing reads. `mem0-brady`'s config is `source`d by bash *and* read by
  `docker compose`, so **quote any value containing a space, `;`, `*`, `{` or `#`**.
- **`setup.sh` + `check-setup.sh` pair** under `scripts/`, surfaced as a `/…setup` and
  `/…doctor` skill. Setup is idempotent and re-runnable; the checker is the thing to run
  when a user reports breakage.
- **Hooks fail open.** A missing config, unreachable server, or timeout must skip the
  feature and let the session continue — never block it. Preserve this when editing
  anything under `hooks/`.
- **Shared bash libs are sourced, never exec'd**, and carry the rationale for existing:
  `mem0-brady/hooks/lib-scope.sh` (the single scope-resolution implementation all seven
  hook wrappers call), `hooks/lib-recall-log.sh`, `scripts/lib-mcp.sh` (a minimal
  streamable-HTTP MCP client for shell). If logic would be copy-pasted into two wrappers,
  it belongs in a lib — silent divergence there has no symptom until recall comes back
  empty.
- **Comments and READMEs explain *why*, at length.** Pinned versions, image tags, quoting
  rules, and naming choices all carry the failure they prevent. Match that density; a
  change that removes a constraint should also remove or update its justification.
- Commits are conventional and scoped by plugin: `feat(mem0-brady): …`,
  `fix(design-ops): …`, `chore(mem0-brady): bump version to …`. Subject lines read as
  prose ("keep the compose stack's data and models where they belong"), not as changelogs.

## Plugin architectures

### `mem0-brady` — the largest and most involved

A self-hosted Mem0 memory backbone. Three layers that must stay consistent:

1. **The vendored fork** (`server/`) — a `mem0ai`-based MCP server plus console-script
   hooks (`mem0-hook-context`, `mem0-hook-stop`, …) installed as a host tool by setup.
2. **The hook wrappers** (`hooks/run-*.sh`) — resolve scopes via `lib-scope.sh`, then exec
   the corresponding console script. Registered in `hooks/hooks.json` across
   SessionStart / UserPromptSubmit / Stop / PreCompact / PreToolUse / PostToolUse.
3. **The compose stack** (`stack/`) — builds its image from `../server`, so the server and
   the hooks are the same code *by construction*. This co-location is the whole point;
   don't reintroduce a git-based image source.

**Memory model — one store, four scopes.** `user_id` (whose store) / `app_id` (what the
work is about) / `agent_id` (which agent wrote it) / `run_id` (which workstream).
`app_id` resolution runs through four layers, highest first: explicit env
(`MEM0_SCOPE_APP_ID`) → repo `.mem0-brady.json` → machine `MEM0_SCOPE_RULES` in the .env →
plugin default `general`. `run_id` is resolved in Python (`hooks.py::_active_workstream`),
not in `lib-scope.sh`, because it keys on `session_id` and stdin must pass through the
wrapper untouched.

**Stack modes** (`MEM0_BRADY_STACK`): `managed` (native Qdrant + server under launchd,
hooks drive mem0 in-process), `compose` (Docker, built from `server/`), `external`
(someone else runs the server; hooks go through MCP and the host holds no API key).

The `mcp__mem0__*` tools are registered at the **user level** in `~/.claude.json`, not via
a plugin `.mcp.json` — a plugin-provided server would be namespaced
`mcp__plugin_mem0-brady_mem0__*`, which the hooks and steer message don't expect.

### `slack-bridge`

Browser session tokens (`xoxc` + `xoxd`) reach Slack's internal endpoints that OAuth
tokens can't. One pure-stdlib client (`server/slack_client.py`) backs both the MCP server
(`server/server.py`, 13 `@mcp.tool()` functions) and the skills, so auth, permalinks, and
categorization never diverge. `decisions.py` is the durable store behind `/slack-saved`.
Launched via the plugin's `.mcp.json` as `uv run ${CLAUDE_PLUGIN_ROOT}/server/server.py`.

### `dark-factory`

Dual-runtime: Claude consumes the plugin directly, but **Codex cannot consume a Claude
plugin**, so `scripts/setup.sh` deploys committed copies into a target repo, driven by
`deploy-manifest.json` (source → dest pairs for `.claude/` and `.codex/`, plus GSD
provisioning). Skills therefore live once here and are *copied* out — edit the plugin
source, then re-run setup in consuming repos. `scripts/identity-lock.sh` keeps two live
sessions from sharing a radio identity; locks live in `.git/dark-factory/locks/`
(per-clone, uncommitted) and are released by the `SessionEnd` hook.

### `design-ops`

Thinnest: one command backed by `scripts/ux_pr_table.py` (stdlib only). The split is
deliberate — deterministic work (window math, Linear paging, PR attribution, the
uncounted-PR sweep) lives in the script; judgment calls stay with the caller. Linear is
reached two ways and the script probes: `LINEAR_API_KEY` direct, or `--issues-file` fed by
Claude from a Linear MCP. GitHub is always read through `gh`.
