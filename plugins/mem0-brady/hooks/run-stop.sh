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

# Config file, MCP-URL bridge, PATH, and every mem0 scope for this session.
# Capture goes through the MCP server under an external stack: the server does
# the memory write AND the handoff synthesis, so the host needs no LLM provider
# or API key. All file IO — transcript read, handoff write — stays here.
#
# MEM0_APP_ID tags the captured memory with this partition (the fork's
# stop_main writes it into metadata.app_id) and MEM0_AGENT_ID with the writing
# agent. Scope is resolved from cwd, not from the hook payload: stdin must pass
# through untouched to the exec'd fork hook. See lib-scope.sh.
# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"
mem0_scope_init

if ! command -v mem0-hook-stop >/dev/null 2>&1; then
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-stop
