#!/usr/bin/env bash
#
# identity-lock.sh - per-session identity lock for the dark factory radio pattern.
#
# The dark factory radio is a live peer channel (refs/h5i/msg) between agent sessions,
# each addressed by an identity (e.g. `claude`, `codex`, `claude-roadmap`).
# Two live sessions holding the SAME identity race the shared inbox read cursor
# and the numbered reply view. This script gives an identity a lightweight,
# repo-local lock so a second session is refused (and told to pick another
# identity) instead of silently corrupting the other session's inbox.
#
# Design (deliberately simple - create-on-start / remove-on-end):
#   * Lock lives inside .git (per-clone, uncommitted), next to h5i's own state
#     under .git/.h5i/msg/cursors/. It is NOT shared across clones.
#   * Cleanup is driven by the session-end hook (Claude) or explicit release
#     (Codex, which has no SessionEnd). A pid-liveness check is an opportunistic
#     backstop so a crashed session that recorded a real pid never blocks the
#     identity forever. There is no heartbeat and no time-based expiry.
#
# Lock file:    <git-dir>/dark-factory/locks/<identity>.lock
#   One line, US-delimited (0x1F):  <session_id><US><pid><US><host><US><epoch>
#   The delimiter is deliberately NON-whitespace. `read` trims leading and
#   collapses runs of IFS *whitespace* (tabs included), so an empty session or pid
#   field written with a tab delimiter shifted every later field left (host<-session,
#   epoch<-pid) and left host empty -> pid_alive() then assumed "alive on another
#   host" and a session refused its own re-acquire. The US byte cannot appear in a
#   session id / pid / hostname / epoch, so empty fields round-trip intact.
# Session map:  <git-dir>/dark-factory/sessions/<session_id>  -> contains <identity>
#   (lets the session-end hook, which only knows session_id, find the identity
#    to release.)
#
# Usage:
#   identity-lock.sh acquire <identity> [pid]   # claim; [pid] = a long-lived
#                                               #   process pid (e.g. the Claude
#                                               #   Monitor shell $$) enabling
#                                               #   stale-reclaim. Omit for
#                                               #   transient callers.
#   identity-lock.sh release [identity] [--force]
#   identity-lock.sh release-hook               # reads {session_id,cwd} JSON on
#                                               #   stdin (SessionEnd hook)
#   identity-lock.sh status
#
# Identity/session resolution: session_id prefers $CLAUDE_SESSION_ID and falls back
# to a non-empty per-session token when it is unset (see SELF_SESSION below). Always
# pass identity explicitly - the h5i stored default is intentionally untrusted in
# shared clones.

set -u

HOSTN="$(hostname 2>/dev/null || echo unknown)"

# Field delimiter for the lock line: the ASCII Unit Separator (0x1F). It MUST be a
# non-whitespace byte so `read` preserves empty leading/middle fields instead of
# collapsing them (see the header note).
US=$'\037'

# Session identity. Prefer Claude Code's real session id; when it is unset (older
# Claude, Codex, or a manual invocation) fall back to a non-empty token. The fallback
# must never be empty: an empty owner (a) aliased every id-less session to the same
# "" owner, so one session's "already ours" check matched another's lock and stole it,
# and (b) suppressed the session-map entry (guarded on non-empty), silently breaking
# the SessionEnd auto-release. PPID - the harness/CLI process that spawns each
# invocation within one session - is stable across a session's calls and distinct
# across concurrent sessions, which is exactly what the owner field needs.
SELF_SESSION="${CLAUDE_SESSION_ID:-}"
[ -n "$SELF_SESSION" ] || SELF_SESSION="anon-${PPID:-$$}@${HOSTN}"

die() { printf 'identity-lock: %s\n' "$1" >&2; exit "${2:-1}"; }

# Resolve the lock base dir inside .git for the repo containing $PWD.
# Prints the absolute base dir, or exits non-zero if not in a git repo.
lock_base() {
  local gd
  gd="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  gd="$(cd "$gd" && pwd)" || return 1
  printf '%s/dark-factory' "$gd"
}

pid_alive() {
  # $1 = pid, $2 = host. Only meaningful on the same host.
  local pid="$1" host="$2"
  [ -n "$pid" ] || return 1          # no recorded pid -> not reclaimable by pid
  [ "$host" = "$HOSTN" ] || return 0 # different host -> assume alive (cannot check)
  kill -0 "$pid" 2>/dev/null
}

cmd_acquire() {
  local identity="${1:-}" pid="${2:-}"
  [ -n "$identity" ] || die "acquire needs an <identity>"
  local base lockdir sessdir lockfile
  base="$(lock_base)" || die "not inside a git repository"
  lockdir="$base/locks"; sessdir="$base/sessions"
  mkdir -p "$lockdir" "$sessdir" || die "cannot create $base"
  lockfile="$lockdir/$identity.lock"

  if [ -f "$lockfile" ]; then
    local o_sess o_pid o_host o_epoch
    IFS="$US" read -r o_sess o_pid o_host o_epoch < "$lockfile" || true
    if [ "$o_sess" = "$SELF_SESSION" ]; then
      : # already ours - fall through to refresh (updates pid if now provided)
    elif pid_alive "$o_pid" "$o_host"; then
      local age="?"
      if [ -n "${o_epoch:-}" ]; then age="$(( $(date +%s) - o_epoch ))s"; fi
      {
        printf 'identity "%s" is already held by a live session\n' "$identity"
        printf '  owner: session=%s pid=%s host=%s age=%s\n' "${o_sess:-<none>}" "${o_pid:-<none>}" "${o_host:-?}" "$age"
        printf '  -> use a distinct identity, e.g. "%s-2" or "claude-roadmap":\n' "$identity"
        printf '        /radio %s-2        (Claude)\n' "$identity"
        printf '  -> or, if that session is gone, clear it:\n'
        printf '        %s release %s --force\n' "$0" "$identity"
      } >&2
      return 1
    fi
    # else: stale (recorded pid dead on this host) -> reclaim
  fi

  printf '%s%s%s%s%s%s%s\n' "$SELF_SESSION" "$US" "$pid" "$US" "$HOSTN" "$US" "$(date +%s)" > "$lockfile"
  [ -n "$SELF_SESSION" ] && printf '%s\n' "$identity" > "$sessdir/$SELF_SESSION"
  printf 'identity "%s" acquired\n' "$identity"
}

# Remove one identity's lock file (and matching session map entries).
remove_lock() {
  local identity="$1" force="$2" base lockdir sessdir lockfile
  base="$(lock_base)" || return 0
  lockdir="$base/locks"; sessdir="$base/sessions"
  lockfile="$lockdir/$identity.lock"
  [ -f "$lockfile" ] || return 0
  if [ "$force" != "force" ]; then
    local o_sess
    IFS="$US" read -r o_sess _ _ _ < "$lockfile" || true
    if [ "$o_sess" != "$SELF_SESSION" ]; then
      printf 'identity "%s" is held by another session (%s); pass --force to clear\n' "$identity" "${o_sess:-<none>}" >&2
      return 1
    fi
  fi
  rm -f "$lockfile"
  # Drop any session-map entries pointing at this identity.
  if [ -d "$sessdir" ]; then
    local f
    for f in "$sessdir"/*; do
      [ -e "$f" ] || continue
      [ "$(cat "$f" 2>/dev/null)" = "$identity" ] && rm -f "$f"
    done
  fi
  printf 'identity "%s" released\n' "$identity"
}

cmd_release() {
  local identity="" force="no" a
  for a in "$@"; do
    case "$a" in
      --force) force="force" ;;
      *) identity="$a" ;;
    esac
  done
  if [ -z "$identity" ]; then
    # derive from the session map using our session id
    local base sessdir
    base="$(lock_base)" || return 0
    sessdir="$base/sessions"
    [ -n "$SELF_SESSION" ] && [ -f "$sessdir/$SELF_SESSION" ] || return 0
    identity="$(cat "$sessdir/$SELF_SESSION" 2>/dev/null)"
    [ -n "$identity" ] || return 0
  fi
  remove_lock "$identity" "$force"
}

cmd_release_hook() {
  # Read {session_id, cwd} from stdin JSON (SessionEnd hook payload).
  local payload sid cwd
  payload="$(cat)"
  sid="$(printf '%s' "$payload" | _json_get session_id)"
  cwd="$(printf '%s' "$payload" | _json_get cwd)"
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
  SELF_SESSION="${sid:-$SELF_SESSION}"
  cmd_release
}

# Minimal JSON string-field extractor: prefers jq, then python3, then a
# best-effort grep/sed. Reads JSON on stdin, arg $1 = key. Prints value.
_json_get() {
  local key="$1" data
  data="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$data" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$data" | python3 -c 'import sys,json;
d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$key" 2>/dev/null && return 0
  fi
  printf '%s' "$data" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

cmd_status() {
  local base lockdir
  base="$(lock_base)" || die "not inside a git repository"
  lockdir="$base/locks"
  if [ ! -d "$lockdir" ] || [ -z "$(ls -A "$lockdir" 2>/dev/null)" ]; then
    printf 'no identities held in this repo\n'
    return 0
  fi
  local f identity o_sess o_pid o_host o_epoch live age
  printf 'IDENTITY           SESSION            PID       HOST         AGE     LIVE\n'
  for f in "$lockdir"/*.lock; do
    [ -e "$f" ] || continue
    identity="$(basename "$f" .lock)"
    IFS="$US" read -r o_sess o_pid o_host o_epoch < "$f" || true
    if pid_alive "$o_pid" "$o_host"; then live="yes"; else live="no/unknown"; fi
    if [ -n "${o_epoch:-}" ]; then age="$(( $(date +%s) - o_epoch ))s"; else age="?"; fi
    printf '%-18s %-18s %-9s %-12s %-7s %s\n' \
      "$identity" "${o_sess:-<none>}" "${o_pid:-<none>}" "${o_host:-?}" "$age" "$live"
  done
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$sub" in
    acquire)      cmd_acquire "$@" ;;
    release)      cmd_release "$@" ;;
    release-hook) cmd_release_hook ;;
    status)       cmd_status ;;
    ""|-h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown subcommand: $sub (try: acquire|release|release-hook|status)" ;;
  esac
}

main "$@"
