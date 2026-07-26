#!/usr/bin/env bash
#
# SessionStart hook: auto-recall. Sources the single mem0-brady config file
# (per-user OPENAI_API_KEY + models + embedded Qdrant path), puts the
# uv-tool bin dir on PATH, and execs the fork's `mem0-hook-context` console
# script, which instantiates mem0 directly (NOT via the HTTP server) and
# injects recalled memories as additionalContext.
#
# Fail-open: if the env file or key is missing, the fork hook swallows the
# error and emits a no-op response — recall is skipped, the session is never
# broken. We mirror that by not hard-failing if the target is absent.
set -uo pipefail

# Config file, MCP-URL bridge, PATH, and every mem0 scope for this session.
# MEM0_RECALL_APP_IDS scopes recall to this session's partition(s) — the fork's
# context_main filters per app_id when it's set. See lib-scope.sh for the
# resolution order (env > repo .mem0-brady.json > machine rules > default).
# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"
mem0_scope_init

# Capture-tee-replay: run the fork hook on the original stdin, log what it
# injected (for /mem0-brady:digest), then replay its exact output to Claude.
# Replaces a bare `exec mem0-hook-context`; the payload still passes through
# untouched. Fail-open lives in the lib helper.
# shellcheck source=lib-recall-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-recall-log.sh"
mem0_run_and_log mem0-hook-context session-start
