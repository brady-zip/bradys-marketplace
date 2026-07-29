#!/usr/bin/env bash
# steer.sh — SessionStart hook. Injects the memory operating model into the session.
#
# Mem0 (this plugin) is the single memory backbone: it does BOTH explicit hard
# facts (mcp__mem0__* tools) AND passive capture/recall (the Stop/SessionStart
# hooks). There is no Honcho. Memory is one shared store (user_id from this
# install's config), partitioned by app_id into domains.
#
# Ported/updated from ~/.claude/hooks/mem0/on_session_start.sh. Reads the launch
# JSON (incl. .cwd) on stdin to pick this session's scopes; falls back to $PWD.
#
# Nothing about the scope layout is baked in here. The partition names, the
# store namespace and the agent identity are all whatever lib-scope.sh resolves
# for this machine and this checkout, so the steer describes the store the
# session actually writes to rather than one install's habits.

set -uo pipefail

PREFIX="mcp__mem0__"

# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"

input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
mem0_scope_init "$cwd"
domain="$MEM0_APP_ID"
agent="$MEM0_AGENT_ID"
recall="$MEM0_RECALL_APP_IDS"

# Stamp the current-session markers. The global marker lets /mem0-brady:digest
# tell an ongoing session (scope to it) from a freshly-opened one (scope to the
# whole day). The per-cwd marker lets the /mem0-brady:workstream skill learn
# THIS session's id (the global one is overwritten by whichever session started
# last, so it can't identify a specific concurrent session).
# shellcheck source=lib-recall-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-recall-log.sh"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
mem0_write_session_marker "$session_id" "$cwd" "$domain"
mem0_write_cwd_session_marker "$session_id" "$cwd"

# Recall breadth is usually just the write partition; say so plainly when it is.
# When a repo has widened it, the instruction has to be executable: PASSIVE
# recall runs one filtered search per app_id and merges (hooks.py builds a
# filter per id), but the search_memories TOOL takes a single app_id string.
# Telling the model to "filter to [a,b]" would be asking for a call it cannot
# make, so spell out the two ways it actually can.
if [ "$recall" = "$domain" ]; then
  recall_clause="app_id='${domain}'"
else
  recall_clause="app_id='${domain}' — and this checkout also recalls from [${recall}], so when the answer may live in a sibling partition, either run one search per app_id or omit app_id to search the whole store"
fi

steer="Memory is active (Mem0, self-hosted). This session's Mem0 SCOPES: app_id='${domain}', agent_id='${agent}' (cwd=${cwd}).
Mem0 is the SINGLE memory backbone — it does BOTH explicit hard facts AND passive capture/recall. There is no Honcho.
Memory is ONE store, sliced by four scopes. Use them:
- user_id — the store namespace. The server sets it; never pass a different one, or the write lands where nothing reads it.
- app_id — WHAT a memory is about (project/domain). ALWAYS pass app_id='${domain}' on every ${PREFIX}add_memory this session, and filter every ${PREFIX}search_memories / get_memories to ${recall_clause}. Widen only when the user explicitly asks for cross-domain context.
- agent_id — WHO wrote it. You are '${agent}'. Several agents can work the same project without cross-pollinating what each has learned, so leave it alone unless asked to read another agent's memories.
- run_id — the active workstream, when this session is tagged (/mem0-brady:workstream). Narrative state for a long-running thread: it is filterable and retirable as a unit, so it stays out of the durable pool.
By KIND:
- Explicit HARD FACTS (IPs, ports, versions, config values, ids, endpoints) -> save with ${PREFIX}add_memory, recall with ${PREFIX}search_memories. Search Mem0 before asking the user for an infra/config detail.
- PASSIVE memory (session summaries, decisions, patterns) is captured automatically on Stop and recalled automatically on SessionStart — you don't hand-write it.
- WORKING MEMORY on a large/ongoing task -> activate a workstream (/mem0-brady:workstream <slug>); capture then carries run_id=<slug> automatically, AND Stop/PreCompact start writing a resume handoff for this cwd — an untagged session gets no handoff, so activate before a task you intend to resume later. Pass run_id explicitly on ${PREFIX}search_memories to pull just that thread's history, ranked. (app_id is the coarse domain; run_id is the fine thread within it — orthogonal.)
- Native file-memory (the ~/.claude .../memory/ dir) is RETIRED: writes there are blocked and steered here."

# If a recent resume-handoff file exists for this cwd (written by the fork's
# Stop/PreCompact hooks, and only for a workstream-tagged session), append a
# pointer so a fresh session can pick up where the last one left off without
# reloading the whole history. Silent when none — the common, untagged case.
resume="$(mem0_handoff_pointer "$cwd" 2>/dev/null || true)"
[ -n "$resume" ] && steer="$steer
$resume"

jq -n --arg c "$steer" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
