#!/usr/bin/env bash
# lib-recall-log.sh — shared best-effort logging for the mem0-brady recall hooks.
#
# Sourced, never exec'd. Every function fails OPEN: any error (missing jq, log
# dir not writable, malformed payload) is swallowed so the hook never breaks a
# session. The recall hooks all `exec mem0-hook-*` for their real work; this lib
# adds a thin capture-tee-replay wrapper so we can also record WHAT got injected.
#
# Two artifacts, both under the plugin data dir:
#   mem0_recall.log      — JSONL, one line per hook injection (the context the
#                          recall hooks silently fed into a session).
#   current_session.json — marker for the session that most recently started,
#                          so /mem0-brady:digest can scope to "this session" vs
#                          "the whole day".

MEM0_LOG_DIR="${MEM0_BRADY_LOG_DIR:-$HOME/.local/share/mem0-brady/logs}"
MEM0_RECALL_LOG="$MEM0_LOG_DIR/mem0_recall.log"
MEM0_SESSION_MARKER="$MEM0_LOG_DIR/current_session.json"

# mem0_log_recall <hook_label> <session_id> <app_id> <content>
# Append one JSONL line describing an injection a recall hook fed into context.
# No-op on empty content (a hook that recalled nothing should leave no trace).
mem0_log_recall() {
  local hook="$1" sid="$2" app="$3" content="$4"
  [ -n "$content" ] || return 0
  mkdir -p "$MEM0_LOG_DIR" 2>/dev/null || return 0
  local ts chars
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  chars="$(printf '%s' "$content" | wc -c | tr -d ' ')"
  jq -nc \
    --arg ts "$ts" --arg hook "$hook" --arg sid "$sid" \
    --arg app "$app" --argjson chars "${chars:-0}" --arg content "$content" \
    '{ts:$ts,hook:$hook,session_id:$sid,app_id:$app,chars:$chars,content:$content}' \
    >> "$MEM0_RECALL_LOG" 2>/dev/null || true
}

# mem0_write_session_marker <session_id> <cwd> <app_id>
# Overwrite the current-session marker. Called from the SessionStart steer hook.
mem0_write_session_marker() {
  local sid="$1" cwd="$2" app="$3"
  [ -n "$sid" ] || return 0
  mkdir -p "$MEM0_LOG_DIR" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg sid "$sid" --arg cwd "$cwd" --arg app "$app" --arg ts "$ts" \
    '{session_id:$sid,cwd:$cwd,app_id:$app,started_at:$ts}' \
    > "$MEM0_SESSION_MARKER" 2>/dev/null || true
}

# mem0_handoff_pointer <cwd>
# Echo a one-line resume pointer if a recent handoff file exists for <cwd>, else
# nothing. The handoff file is written by the fork's Stop/PreCompact hooks; this
# only locates it (same path scheme: <project>-<sha1(cwd)[:8]>.md) so the
# SessionStart steer can tell a fresh session a resume doc is waiting. Fail-open.
mem0_handoff_pointer() {
  local cwd="$1"
  [ -n "$cwd" ] || return 0

  local dir proj safe digest file
  dir="${MEM0_HANDOFF_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mem0-brady/handoffs}"
  proj="$(basename "$cwd")"
  safe="$(printf '%s' "$proj" | sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$safe" ] || safe=project
  digest="$(printf '%s' "$cwd" | shasum -a 1 2>/dev/null | cut -c1-8)"
  [ -n "$digest" ] || return 0
  file="$dir/$safe-$digest.md"
  [ -f "$file" ] || return 0

  local now mtime age max_h max_s human
  now="$(date +%s 2>/dev/null)" || return 0
  mtime="$(stat -f %m "$file" 2>/dev/null)" || return 0
  [ -n "$mtime" ] || return 0
  age=$(( now - mtime ))
  max_h="${MEM0_HANDOFF_MAX_AGE_HOURS:-168}"   # default: 7 days
  max_s=$(( max_h * 3600 ))
  [ "$age" -le "$max_s" ] || return 0          # too stale to surface

  if   [ "$age" -lt 3600 ];  then human="$(( age / 60 ))m ago"
  elif [ "$age" -lt 86400 ]; then human="$(( age / 3600 ))h ago"
  else                            human="$(( age / 86400 ))d ago"
  fi

  printf 'RESUME AVAILABLE: a handoff for this project was written %s at %s. If the user is resuming prior work ("continue", "where were we", "pick up", etc.), read that file FIRST to recover context instead of reloading the whole history.' \
    "$human" "$file"
}

# mem0_run_and_log <console_script> <hook_label>
# The recall-hook body. Reads the hook payload on stdin, runs the fork console
# script with it, logs any injected additionalContext, and replays the script's
# exact output to Claude. Fail-open: a missing script or any error degrades to
# the no-op hook response, so recall is skipped but the session is never broken.
mem0_run_and_log() {
  local script="$1" label="$2"
  local input sid out injected
  input="$(cat 2>/dev/null || true)"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"

  if ! command -v "$script" >/dev/null 2>&1; then
    printf '%s\n' '{"continue": true, "suppressOutput": true}'
    return 0
  fi

  out="$(printf '%s' "$input" | "$script" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    printf '%s\n' '{"continue": true, "suppressOutput": true}'
    return 0
  fi

  injected="$(printf '%s' "$out" \
    | jq -r '(.hookSpecificOutput.additionalContext // .additionalContext // empty)' 2>/dev/null || true)"
  mem0_log_recall "$label" "$sid" "${MEM0_APP_ID:-unknown}" "$injected"

  printf '%s\n' "$out"
}
