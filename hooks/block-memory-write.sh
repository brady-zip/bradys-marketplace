#!/usr/bin/env bash
# block-memory-write.sh — PreToolUse hook (matcher: Write|Edit|MultiEdit|NotebookEdit)
#
# Native file-based memory is retired: Mem0 (this plugin) owns memory now — both
# explicit hard facts (mcp__mem0__* tools) and passive capture/recall (the hooks).
# This hook DENIES any Write/Edit to a Claude file-memory surface and steers the
# model to Mem0 instead. Anything else is allowed (silent exit 0).
#
# Ported from ~/.claude/hooks/mem0/block_memory_write.sh into the mem0-brady plugin.

set -euo pipefail

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

# Pull the target path out of whichever field this tool uses.
file_path="$(printf '%s' "$input" | jq -r '
  .tool_input.file_path
  // .tool_input.path
  // .tool_input.notebook_path
  // empty')"

case "$tool_name" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[ -n "$file_path" ] || exit 0

# Memory surface = any file inside a .claude .../memory/ dir, or a MEMORY.md
# index under a .claude projects tree.
is_memory_surface=0
case "$file_path" in
  *"/.claude/"*"/memory/"*)  is_memory_surface=1 ;;
  *"/.claude/"*"/MEMORY.md")  is_memory_surface=1 ;;
esac

[ "$is_memory_surface" -eq 1 ] || exit 0

reason="Native file-memory is disabled (Mem0 owns memory now). Do NOT write to ${file_path}.
- Explicit HARD FACT (IP / port / version / config value / id / endpoint)? Call mcp__mem0__add_memory with the fact text and app_id for this session's domain. It persists across sessions and is searchable via mcp__mem0__search_memories.
- Behavioral pattern / preference / how-B-works / session summary? You don't need to write anything — Mem0 auto-captures a session summary on Stop and auto-recalls relevant memories on SessionStart.
If you genuinely must write a file here (e.g. editing the plugin's own hook docs), ask the user to temporarily disable the mem0-brady block-memory-write hook."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
