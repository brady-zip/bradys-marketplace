#!/usr/bin/env bash
# enforce-metadata.sh — PreToolUse hook (matcher: mcp__mem0__.*).
#
# Keeps every Mem0 write in the SHARED namespace (so Claude + Hal cross-query one
# store) AND in the correct DOMAIN partition (app_id). The MCP server is registered
# with a fixed user_id, so adds default to the shared store with no per-call
# metadata; PreToolUse can't mutate tool input, so this hook is a GUARD that DENIES
# (the model then retries with the fix):
#   1. a write pinning a *different* user_id (would fragment the shared store);
#   2. a write missing app_id (would escape the evergreen/general domain partition).
# The correct app_id is derived from the session cwd. Otherwise allows silently.
#
# Ported from ~/.claude/hooks/mem0/enforce_metadata_defaults.sh into the plugin.
# The shared user_id is read from the plugin's .env (MEM0_USER_ID), default shared-bch.

set -uo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
SHARED="shared-bch"
if [ -f "$ENV_FILE" ]; then
  v="$(grep -E '^MEM0_USER_ID=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  [ -n "$v" ] && SHARED="$v"
fi

# Domain partition for a cwd: evergreen repo (+ worktrees) -> evergreen, else general.
domain_for_cwd() {
  case "${1:-$PWD}" in
    *evergreen*) echo evergreen ;;
    *) echo general ;;
  esac
}

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool_name" in
  *add_memories|*add_memory|*add) ;;
  *) exit 0 ;;
esac

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Guard 1: a pinned non-shared user_id would fragment the store.
call_user="$(printf '%s' "$input" | jq -r '.tool_input.user_id // empty')"
if [ -n "$call_user" ] && [ "$call_user" != "$SHARED" ]; then
  deny "This Mem0 write pins user_id='${call_user}', which would fragment the shared memory store. Omit user_id (the server defaults to the shared namespace '${SHARED}' that B, Claude, and Hal all read), or set user_id='${SHARED}' explicitly."
fi

# Guard 2: every write must carry an app_id (domain partition).
call_app="$(printf '%s' "$input" | jq -r '.tool_input.app_id // .tool_input.metadata.app_id // empty')"
if [ -z "$call_app" ]; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  [ -z "$cwd" ] && cwd="$PWD"
  domain="$(domain_for_cwd "$cwd")"
  deny "This Mem0 write is missing app_id, so it would escape the memory domain partition. Retry with app_id='${domain}' (the domain for this session's cwd=${cwd}). app_id partitions memory into 'evergreen' (evergreen-repo work) vs 'general' (Claude tooling/customizations)."
fi
exit 0
