#!/usr/bin/env bash
#
# PreCompact hook: capture a session-state summary before context compaction.
# Sources the mem0-brady config, sets the app_id domain, and execs the fork's
# `mem0-hook-precompact` console script, which writes a summary tagged
# source=pre-compact-hook so a resume after compaction can recall what was in
# flight. Shares the capture path with the Stop hook.
#
# Fail-open: a missing env/key/install just skips.
set -euo pipefail

# Config file, MCP-URL bridge, PATH, and every mem0 scope — see lib-scope.sh.
# Shares the capture path with the Stop hook, so it shares its scoping too.
# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"
mem0_scope_init

if ! command -v mem0-hook-precompact >/dev/null 2>&1; then
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-precompact
