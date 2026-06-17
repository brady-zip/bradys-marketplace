#!/usr/bin/env bash
# on-post-tool-use.sh — PostToolUse hook (matcher: mcp__mem0__.*).
#
# Plumbing only: appends an audit line for every Mem0 operation so we can see what
# got stored/searched. Fails open and never blocks.
#
# Ported from ~/.claude/hooks/mem0/on_post_tool_use.sh into the plugin. Logs to the
# plugin data dir instead of ~/.claude/hooks/mem0/logs.

set -uo pipefail

LOG_DIR="$HOME/.local/share/mem0-brady/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
case "$tool_name" in
  mcp__mem0__*) ;;
  *) exit 0 ;;
esac

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# session_id lets /mem0-brady:digest scope explicit ops to the current session.
summary="$(printf '%s' "$input" | jq -c '{tool: .tool_name, session_id: (.session_id // ""), input: .tool_input}' 2>/dev/null || echo '{}')"
printf '%s\t%s\n' "$ts" "$summary" >> "$LOG_DIR/mem0_ops.log" 2>/dev/null || true
exit 0
