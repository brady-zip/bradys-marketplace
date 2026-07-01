#!/usr/bin/env bash
# enforce-metadata.sh — PreToolUse hook (matcher: mcp__mem0__.*).
#
# Keeps every Mem0 write in the SHARED namespace (so Claude + Hal cross-query one
# store) AND in the correct DOMAIN partition (app_id). The MCP server is registered
# with a fixed user_id, so adds default to the shared store with no per-call
# metadata. Two guards:
#   1. user_id: a write pinning a *different* user_id would fragment the shared
#      store, so DENY it (the model retries omitting user_id / using shared).
#   2. app_id: a write missing app_id would escape the evergreen/general domain
#      partition (the server would silently default it to 'general'). app_id is
#      deterministic from the session cwd, so rather than deny+retry we INJECT it
#      via updatedInput (PreToolUse can rewrite tool_input). An explicit app_id is
#      left untouched. Both actions are audited to mem0_denials.log.
# Otherwise allows silently.
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

# PreToolUse denies/injects are otherwise invisible (they never reach the
# PostToolUse audit in mem0_ops.log), so record them to a separate log. Kept
# out of mem0_ops.log so /mem0-brady:digest's TSV parser is unaffected.
LOG_DIR="${MEM0_BRADY_LOG_DIR:-$HOME/.local/share/mem0-brady/logs}"

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

# Append a fail-open audit line for a guard action. Logs the tool_input KEYS
# (not the memory text) to keep the log small and non-sensitive. $1=outcome
# (e.g. injected-app|denied-user|denied-app), $2=freeform detail.
log_event() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  local ts sid keys
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sid="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
  keys="$(printf '%s' "$input" | jq -c '.tool_input | keys' 2>/dev/null || echo '[]')"
  printf '%s\t%s\n' "$ts" "$(jq -nc \
      --arg tool "$tool_name" --arg sid "$sid" --arg outcome "$1" \
      --arg detail "$2" --argjson keys "${keys:-[]}" \
      '{tool:$tool,session_id:$sid,outcome:$outcome,detail:$detail,input_keys:$keys}')" \
    >> "$LOG_DIR/mem0_denials.log" 2>/dev/null || true
}

# Guard 1: a pinned non-shared user_id would fragment the store.
call_user="$(printf '%s' "$input" | jq -r '.tool_input.user_id // empty')"
if [ -n "$call_user" ] && [ "$call_user" != "$SHARED" ]; then
  log_event "denied-user" "user_id=${call_user}"
  deny "This Mem0 write pins user_id='${call_user}', which would fragment the shared memory store. Omit user_id (the server defaults to the shared namespace '${SHARED}' that B, Claude, and Hal all read), or set user_id='${SHARED}' explicitly."
fi

# Guard 2: every write must carry an app_id (domain partition). The value is
# deterministic from the session cwd, so rather than bounce the model with a
# deny+retry, INJECT it via updatedInput (PreToolUse can rewrite tool_input).
# An explicit app_id (top-level OR nested under metadata) is left untouched, so
# a user-requested cross-domain write still works. Note: updatedInput REPLACES
# tool_input, so we emit the full original input merged with {app_id}.
call_app="$(printf '%s' "$input" | jq -r '.tool_input.app_id // .tool_input.metadata.app_id // empty')"
if [ -z "$call_app" ]; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  [ -z "$cwd" ] && cwd="$PWD"
  domain="$(domain_for_cwd "$cwd")"
  ti="$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)"
  [ -n "$ti" ] || ti='{}'
  log_event "injected-app" "app_id=${domain} cwd=${cwd}"
  jq -n --argjson ti "$ti" --arg app "$domain" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:($ti + {app_id:$app})}}'
  exit 0
fi
exit 0
