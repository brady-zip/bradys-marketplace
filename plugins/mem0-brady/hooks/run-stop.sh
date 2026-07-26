#!/usr/bin/env bash
#
# Stop hook: auto-capture. Sources the single mem0-brady config file, puts the
# uv-tool bin dir on PATH, and execs the fork's `mem0-hook-stop` console
# script, which instantiates mem0 directly (NOT via the HTTP server) and
# writes a session-summary memory.
#
# Fail-open: a missing env file / key / install never breaks the session —
# capture is simply skipped.
set -euo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Capture via the MCP server when this install points at an external stack:
# the server performs the memory write AND the handoff synthesis (its
# synthesize_handoff tool), so the host needs no LLM provider or API key. All
# file IO — transcript read, handoff write — stays here, on the host.
# The fork reads MEM0_MCP_URL; bridge the plugin's namespaced key onto it.
if [ "${MEM0_BRADY_STACK:-managed}" = "external" ] && [ -n "${MEM0_BRADY_MCP_URL:-}" ]; then
  export MEM0_MCP_URL="$MEM0_BRADY_MCP_URL"
fi

export PATH="$HOME/.local/bin:$PATH"

# --- Domain partition (app_id) for this session ---
# Mirrors mem0_domain_for_cwd from ~/.claude/hooks/mem0/config.sh: any path with
# an "evergreen" segment is the evergreen domain; everything else is "general".
# CLAUDE_PROJECT_DIR is set by Claude Code for hooks; fall back to PWD. We can't
# read cwd from the hook stdin here — it must pass through untouched to the
# exec'd fork hook. MEM0_APP_ID tags the captured memory with this domain (the
# fork's stop_main writes it into metadata.app_id when set).
case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *evergreen*) _mem0_domain=evergreen ;;
  *) _mem0_domain=general ;;
esac
export MEM0_APP_ID="$_mem0_domain"
export MEM0_RECALL_APP_IDS="$_mem0_domain"

if ! command -v mem0-hook-stop >/dev/null 2>&1; then
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-stop
