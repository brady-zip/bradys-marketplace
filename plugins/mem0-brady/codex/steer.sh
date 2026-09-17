#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib-scope.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib-recall-log.sh"

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
mem0_scope_init "${cwd:-$PWD}"
mem0_write_session_marker "$session_id" "$MEM0_SCOPE_CWD" "$MEM0_APP_ID"
mem0_write_cwd_session_marker "$session_id" "$MEM0_SCOPE_CWD"
resume="$(mem0_handoff_pointer "$MEM0_SCOPE_CWD" 2>/dev/null || true)"

context="Mem0 shares this machine's existing memory server with Claude Code and Hal.
This session uses app_id='$MEM0_APP_ID', agent_id='$MEM0_AGENT_ID', and recall partitions '$MEM0_RECALL_APP_IDS'.
Use mcp__mem0__search_memories to recall relevant context. Search one app_id at a time when multiple recall partitions apply; omit agent_id to include the other agents' memories.
For explicit mcp__mem0__add_memory calls, pass app_id='$MEM0_APP_ID' and agent_id='$MEM0_AGENT_ID'. Omit user_id so the server keeps its configured namespace.
SessionStart and resume prompts recall context. Stop and PreCompact use the shared capture settings to save summaries.
For work spanning sessions, the mem0-brady workstream skill associates captures with run_id and enables resume handoffs.
$resume"

jq -n --arg context "$context" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}'
