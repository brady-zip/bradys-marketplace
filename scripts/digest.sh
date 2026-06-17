#!/usr/bin/env bash
# digest.sh — emit scoped mem0-brady activity for the /mem0-brady:digest command
# to turn into prose. Read-only; never writes. Fails soft (missing logs => empty
# sections, never an error).
#
# Two LOCAL data sources, both under the plugin data dir:
#   mem0_ops.log    — explicit mcp__mem0__* tool calls (adds + searches), TSV:
#                     "<utc-ts>\t<json {tool,session_id,input}>"
#   mem0_recall.log — what the recall HOOKS injected into sessions, JSONL:
#                     {ts,hook,session_id,app_id,chars,content}
#
# SCOPE auto-detects from the current_session.json marker, keyed on TIME (not
# session_id — hook payloads hand out inconsistent session_ids across hook
# types, so equality is an unreliable join; the marker's started_at is stable):
#   - "this session" == every event at/after the marker's started_at.
#   - if that window holds real work (any explicit op, or any recall beyond the
#     one bootstrap SessionStart injection) -> scope=session — "summarize this
#     ongoing session".
#   - otherwise -> scope=day, the whole calendar day — the freshly-opened-session
#     case where the command is run before any work has happened.
# Force with --session / --day. Override the date with a YYYY-MM-DD argument.
#
# NOTE the digest covers only what is observable locally: explicit tool calls
# and hook injections. Stop-hook session SUMMARIES are written straight to the
# store (not via MCP), so they are NOT here — the command queries the mem0 store
# separately for those.
set -uo pipefail

LOG_DIR="${MEM0_BRADY_LOG_DIR:-$HOME/.local/share/mem0-brady/logs}"
OPS_LOG="$LOG_DIR/mem0_ops.log"
RECALL_LOG="$LOG_DIR/mem0_recall.log"
MARKER="$LOG_DIR/current_session.json"

# How many chars of each item's body to show before truncating (session scope
# is bounded, so it shows more; day scope can be large, so it shows less).
CAP_SESSION=900
CAP_DAY=320

# --- args ---------------------------------------------------------------------
force=""
day=""
for a in "$@"; do
  case "$a" in
    --session) force=session ;;
    --day) force=day ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) day="$a" ;;
    *) ;;
  esac
done
[ -n "$day" ] || day="$(date +%Y-%m-%d)"

# Local calendar-day window as UTC epochs (logs are stamped in UTC).
start="$(date -j -f "%Y-%m-%d %H:%M:%S" "$day 00:00:00" +%s 2>/dev/null)" || start=0
end=$((start + 86400))

# --- current session marker ---------------------------------------------------
CUR=""; DOMAIN=""; STARTED=""
if [ -f "$MARKER" ]; then
  CUR="$(jq -r '.session_id // empty' "$MARKER" 2>/dev/null || true)"
  DOMAIN="$(jq -r '.app_id // empty' "$MARKER" 2>/dev/null || true)"
  STARTED="$(jq -r '.started_at // empty' "$MARKER" 2>/dev/null || true)"
fi

# --- in-window readers (emit self-contained JSONL) ----------------------------
# ops: parse the TSV, drop rows outside the window, fold the ts into the json.
ops_in_window() {
  [ -f "$OPS_LOG" ] || return 0
  local ts json e
  while IFS=$'\t' read -r ts json; do
    [ -n "$ts" ] && [ -n "$json" ] || continue
    e="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null)" || continue
    [ "$e" -ge "$start" ] && [ "$e" -lt "$end" ] || continue
    printf '%s' "$json" | jq -c --arg ts "$ts" '. + {ts:$ts}' 2>/dev/null || true
  done < "$OPS_LOG"
}

recall_in_window() {
  [ -f "$RECALL_LOG" ] || return 0
  jq -c --argjson s "$start" --argjson e "$end" \
    'select((.ts|fromdateiso8601) >= $s and (.ts|fromdateiso8601) < $e)' \
    "$RECALL_LOG" 2>/dev/null || true
}

# --- scope decision (time-based) ----------------------------------------------
OPS_JSONL="$(ops_in_window)"
RECALL_JSONL="$(recall_in_window)"

# Epoch of the current session's start (0 if no marker => no session to scope to).
sess_from=0
if [ -n "$STARTED" ]; then
  sess_from="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED" +%s 2>/dev/null || echo 0)"
fi

scope="$force"
if [ -z "$scope" ]; then
  n=0
  if [ -n "$CUR" ] && [ "$sess_from" -gt 0 ]; then
    no="$(printf '%s\n' "$OPS_JSONL" | jq -rs --argjson from "$sess_from" \
      '[.[]|select((.ts|fromdateiso8601) >= $from)]|length' 2>/dev/null || echo 0)"
    # recall beyond the single bootstrap SessionStart injection counts as "work"
    nr="$(printf '%s\n' "$RECALL_JSONL" | jq -rs --argjson from "$sess_from" \
      '[.[]|select((.ts|fromdateiso8601) >= $from and .hook!="session-start")]|length' 2>/dev/null || echo 0)"
    n=$(( ${no:-0} + ${nr:-0} ))
  fi
  if [ -n "$CUR" ] && [ "$n" -gt 0 ]; then scope=session; else scope=day; fi
fi

if [ "$scope" = "session" ]; then CAP="$CAP_SESSION"; else CAP="$CAP_DAY"; fi

# Lower time bound passed to the jq filters: session start for session scope,
# 0 (== whole day window) otherwise.
from=0
[ "$scope" = "session" ] && from="$sess_from"

# --- header -------------------------------------------------------------------
printf '=== mem0-brady digest ===\n'
printf 'SCOPE: %s\n' "$scope"
printf 'DAY: %s (local; window %s..%s UTC-epoch)\n' "$day" "$start" "$end"
printf 'CURRENT_SESSION: %s\n' "${CUR:-<none>}"
printf 'SESSION_DOMAIN: %s\n' "${DOMAIN:-<unknown>}"
printf 'SESSION_STARTED: %s\n' "${STARTED:-<unknown>}"
printf 'GENERATED: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'RECALL_LOG: %s\n' "$RECALL_LOG"
printf 'OPS_LOG: %s\n\n' "$OPS_LOG"

# --- captures (explicit add_memory) -------------------------------------------
printf -- '--- CAPTURES (explicit mcp__mem0__add_memory) ---\n'
caps="$(printf '%s\n' "$OPS_JSONL" | jq -rc --argjson from "$from" --argjson cap "$CAP" '
  select(.tool=="mcp__mem0__add_memory")
  | select((.ts|fromdateiso8601) >= $from)
  | "[\(.ts)] app_id=\(.input.app_id // "?") run_id=\(.input.run_id // "-") session=\((.session_id // "")[0:8])\n"
    + ((.input.text // (.input.messages|tostring) // "") as $t
       | if ($t|length) > $cap then ($t[0:$cap] + " …[+" + (($t|length)-$cap|tostring) + " chars]") else $t end)
    + "\n--" ' 2>/dev/null || true)"
if [ -n "$caps" ]; then printf '%s\n\n' "$caps"; else printf '(none)\n\n'; fi

# --- searches (explicit search_memories) --------------------------------------
printf -- '--- SEARCHES (explicit mcp__mem0__search_memories) ---\n'
srch="$(printf '%s\n' "$OPS_JSONL" | jq -rc --argjson from "$from" '
  select(.tool=="mcp__mem0__search_memories")
  | select((.ts|fromdateiso8601) >= $from)
  | "[\(.ts)] app_id=\(.input.app_id // "?") limit=\(.input.limit // "-") session=\((.session_id // "")[0:8])  q=\"\(.input.query // "")\""
  ' 2>/dev/null || true)"
if [ -n "$srch" ]; then printf '%s\n\n' "$srch"; else printf '(none)\n\n'; fi

# --- hook injections (the headline: what recall hooks fed into context) -------
printf -- '--- HOOK INJECTIONS (what the mem0 recall hooks fed into context) ---\n'
inj="$(printf '%s\n' "$RECALL_JSONL" | jq -rc --argjson from "$from" --argjson cap "$CAP" '
  select((.ts|fromdateiso8601) >= $from)
  | "[\(.ts)] hook=\(.hook) app_id=\(.app_id) chars=\(.chars) session=\((.session_id // "")[0:8])\n"
    + (.content as $t
       | if ($t|length) > $cap then ($t[0:$cap] + " …[+" + (($t|length)-$cap|tostring) + " chars]") else $t end)
    + "\n--" ' 2>/dev/null || true)"
if [ -n "$inj" ]; then
  printf '%s\n\n' "$inj"
  # per-hook tallies so the command can characterize the recall mix at a glance
  printf 'INJECTION_TALLY: '
  printf '%s\n' "$RECALL_JSONL" | jq -rs --argjson from "$from" '
    [.[]|select((.ts|fromdateiso8601) >= $from)]
    | group_by(.hook) | map("\(.[0].hook)=\(length)") | join(" ")' 2>/dev/null || true
  printf '\n'
else
  if [ ! -s "$RECALL_LOG" ]; then
    printf '(none — mem0_recall.log not present yet. Injection logging starts on the\n'
    printf ' next session AFTER these hook changes load. Restart Claude to begin capturing.)\n\n'
  else
    printf '(none in window)\n\n'
  fi
fi

printf -- '--- NOTES ---\n'
printf 'Captures above are EXPLICIT add_memory calls only. Stop-hook session\n'
printf 'summaries go straight to the store (not via MCP) — query the mem0 store\n'
printf '(get_memories, app_id=%s, filter created_at to this window) for those.\n' "${DOMAIN:-<domain>}"
printf 'Full untruncated injection content lives in %s.\n' "$RECALL_LOG"
