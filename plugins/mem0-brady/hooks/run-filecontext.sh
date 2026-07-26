#!/usr/bin/env bash
#
# PreToolUse(Read) hook: file context. Sources the mem0-brady config, sets the
# app_id domain, and execs the fork's `mem0-hook-filecontext` console script,
# which searches mem0 for the file about to be read and injects a compact
# "prior work on this file" list. Recall only — never blocks the Read.
#
# Fail-open: a missing env/key/install just skips.
set -uo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Recall via the MCP server instead of an in-process mem0 client, when this
# install points at an external stack. The server already holds the Qdrant URL,
# collection, user_id and API key, and is long-lived, so recall neither
# duplicates that config on the host nor pays a cold Memory init per hook
# process. The fork reads MEM0_MCP_URL; the plugin stores it under its own
# namespaced key, so bridge the two here.
# Managed stacks stay on the direct client — unchanged behaviour.
if [ "${MEM0_BRADY_STACK:-managed}" = "external" ] && [ -n "${MEM0_BRADY_MCP_URL:-}" ]; then
  export MEM0_MCP_URL="$MEM0_BRADY_MCP_URL"
fi

export PATH="$HOME/.local/bin:$PATH"

case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *evergreen*) _mem0_domain=evergreen ;;
  *) _mem0_domain=general ;;
esac
export MEM0_APP_ID="$_mem0_domain"
export MEM0_RECALL_APP_IDS="$_mem0_domain"

# Capture-tee-replay: run the fork hook, log what it injected (for
# /mem0-brady:digest), replay its output. Replaces a bare `exec`.
# shellcheck source=lib-recall-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-recall-log.sh"
mem0_run_and_log mem0-hook-filecontext filecontext
