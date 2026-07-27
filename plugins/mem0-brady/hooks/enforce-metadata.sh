#!/usr/bin/env bash
# enforce-metadata.sh — PreToolUse hook (matcher: mcp__mem0__.*).
#
# Keeps every explicit Mem0 write in the same SCOPES the passive capture hooks
# write automatically. Without this, a tool call and a Stop-hook capture from
# one session land in different partitions and only one comes back on recall.
#
# The MCP server is registered with a fixed user_id, so adds already reach the
# right store with no per-call metadata. Three guards:
#   1. user_id: a write pinning a DIFFERENT user_id would fragment the store, so
#      DENY it — but only when this host actually knows the store's user_id.
#      Under an external stack the server owns it and the host may legitimately
#      not. When unknown, allow and stay quiet: a guess is worse than no check
#      here, because the deny message NAMES a replacement namespace, so a wrong
#      guess actively steers writes somewhere nothing reads. Not hypothetical —
#      this guard shipped with a hardcoded literal that did not match the
#      running server, and would have denied the correct value.
#   2. app_id: deterministic from the session cwd, so rather than bounce the
#      model with deny+retry, INJECT it via updatedInput.
#   3. agent_id: likewise injected, so an explicit write carries the same actor
#      the capture path stamps.
# An explicitly-passed value is never overwritten — a deliberate cross-domain
# write still works. Guard actions are audited to mem0_denials.log.
#
# Scope RESOLUTION lives in lib-scope.sh; this hook only enforces the result.

set -uo pipefail

# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"

# PreToolUse denies/injects are otherwise invisible (they never reach the
# PostToolUse audit in mem0_ops.log), so record them to a separate log. Kept
# out of mem0_ops.log so /mem0-brady:digest's TSV parser is unaffected.
LOG_DIR="${MEM0_BRADY_LOG_DIR:-$HOME/.local/share/mem0-brady/logs}"

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool_name" in
  *add_memories|*add_memory|*add) ;;
  *) exit 0 ;;
esac

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -z "$cwd" ] && cwd="$PWD"
mem0_scope_init "$cwd"

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Append a fail-open audit line for a guard action. Logs the tool_input KEYS
# (not the memory text) to keep the log small and non-sensitive. $1=outcome
# (e.g. injected-scope|denied-user), $2=freeform detail.
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

# Guard 1 — only enforceable when the host knows the store's namespace.
call_user="$(printf '%s' "$input" | jq -r '.tool_input.user_id // empty')"
if [ "${MEM0_SCOPE_USER_ID_KNOWN:-0}" = "1" ] && [ -n "$call_user" ] && [ "$call_user" != "${MEM0_USER_ID}" ]; then
  log_event "denied-user" "user_id=${call_user} expected=${MEM0_USER_ID}"
  deny "This Mem0 write pins user_id='${call_user}', but this store's shared namespace is '${MEM0_USER_ID}' — the write would land where nothing reads it. Omit user_id (the server defaults correctly) or set user_id='${MEM0_USER_ID}'."
fi

# Guards 2 + 3 — inject the session's app_id / agent_id when the call omits
# them. updatedInput REPLACES tool_input, so emit the full original merged with
# only the keys being added. Each accepts an explicit value at the top level or
# nested under metadata, and neither is overwritten when already present.
call_app="$(printf '%s' "$input" | jq -r '.tool_input.app_id // .tool_input.metadata.app_id // empty')"
call_agent="$(printf '%s' "$input" | jq -r '.tool_input.agent_id // .tool_input.metadata.agent_id // empty')"

add='{}'
detail=""
if [ -z "$call_app" ] && [ -n "${MEM0_APP_ID:-}" ]; then
  add="$(jq -nc --argjson a "$add" --arg v "$MEM0_APP_ID" '$a + {app_id:$v}')"
  detail="app_id=${MEM0_APP_ID}"
fi
if [ -z "$call_agent" ] && [ -n "${MEM0_AGENT_ID:-}" ]; then
  add="$(jq -nc --argjson a "$add" --arg v "$MEM0_AGENT_ID" '$a + {agent_id:$v}')"
  detail="${detail:+$detail }agent_id=${MEM0_AGENT_ID}"
fi

if [ "$add" != '{}' ]; then
  ti="$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)"
  [ -n "$ti" ] || ti='{}'
  log_event "injected-scope" "${detail} cwd=${cwd}"
  jq -n --argjson ti "$ti" --argjson add "$add" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:($ti + $add)}}'
  exit 0
fi
exit 0
