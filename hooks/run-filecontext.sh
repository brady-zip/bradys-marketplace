#!/usr/bin/env bash
#
# PreToolUse(Read) hook: file context. Sources the mem0-brady config, sets the
# app_id domain, and execs the fork's `mem0-hook-filecontext` console script,
# which searches mem0 for the file about to be read and injects a compact
# "prior work on this file" list. Recall only — never blocks the Read.
#
# Fail-open: a missing env/key/install just skips.
set -euo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

export PATH="$HOME/.local/bin:$PATH"

case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *evergreen*) _mem0_domain=evergreen ;;
  *) _mem0_domain=general ;;
esac
export MEM0_APP_ID="$_mem0_domain"
export MEM0_RECALL_APP_IDS="$_mem0_domain"

if ! command -v mem0-hook-filecontext >/dev/null 2>&1; then
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-filecontext
