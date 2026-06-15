#!/usr/bin/env bash
# steer.sh — SessionStart hook. Injects the memory operating model into the session.
#
# Mem0 (this plugin) is the single memory backbone: it does BOTH explicit hard
# facts (mcp__mem0__* tools) AND passive capture/recall (the Stop/SessionStart
# hooks). There is no Honcho. Memory is one shared store (user_id shared-bch),
# partitioned by app_id into domains.
#
# Ported/updated from ~/.claude/hooks/mem0/on_session_start.sh. Reads the launch
# JSON (incl. .cwd) on stdin to pick this session's domain; falls back to $PWD.

set -uo pipefail

PREFIX="mcp__mem0__"

input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
case "$cwd" in
  *evergreen*) domain=evergreen ;;
  *) domain=general ;;
esac

steer="Memory is active (Mem0, self-hosted). This session's Mem0 DOMAIN is app_id='${domain}' (cwd=${cwd}).
Mem0 is the SINGLE memory backbone — it does BOTH explicit hard facts AND passive capture/recall. There is no Honcho.
Memory is one shared store (user_id 'shared-bch', shared with Hal) partitioned by app_id into domains: 'evergreen' (work in the evergreen repo + its worktrees), 'general' (Claude tooling, customizations, memory infra), and 'hal-ops' (Hal's own ops, written by Hal). ALWAYS pass app_id='${domain}' on every ${PREFIX}add_memory this session, and filter every ${PREFIX}search_memories / get_memories with app_id='${domain}' so recall stays in-domain. Only widen to another domain when the user explicitly asks for cross-domain context.
By KIND:
- Explicit HARD FACTS (IPs, ports, versions, config values, ids, endpoints) -> save with ${PREFIX}add_memory, recall with ${PREFIX}search_memories. Search Mem0 before asking the user for an infra/config detail.
- PASSIVE memory (session summaries, decisions, patterns) is captured automatically on Stop and recalled automatically on SessionStart — you don't hand-write it.
- WORKING MEMORY on a large/ongoing task -> pass run_id=<repo-or-task> to ${PREFIX}add_memory / search_memories so scratch context stays scoped and out of the long-term pool. (app_id is the coarse domain; run_id is the fine task within it — orthogonal.)
- Native file-memory (the ~/.claude .../memory/ dir) is RETIRED: writes there are blocked and steered here."

jq -n --arg c "$steer" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
