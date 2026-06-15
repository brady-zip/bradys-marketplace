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
# broken. We mirror that by not hard-failing if the exec target is absent.
set -euo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

export PATH="$HOME/.local/bin:$PATH"

# --- Domain partition (app_id) for this session ---
# Mirrors mem0_domain_for_cwd from ~/.claude/hooks/mem0/config.sh: any path with
# an "evergreen" segment is the evergreen domain; everything else is "general".
# CLAUDE_PROJECT_DIR is set by Claude Code for hooks; fall back to PWD. We can't
# read cwd from the hook stdin here — it must pass through untouched to the
# exec'd fork hook. MEM0_RECALL_APP_IDS scopes recall to this domain (the fork's
# context_main filters per app_id when it's set).
case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *evergreen*) _mem0_domain=evergreen ;;
  *) _mem0_domain=general ;;
esac
export MEM0_APP_ID="$_mem0_domain"
export MEM0_RECALL_APP_IDS="$_mem0_domain"

if ! command -v mem0-hook-context >/dev/null 2>&1; then
  # Not installed yet — emit the no-op hook response and exit cleanly.
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-context
