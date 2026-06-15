#!/usr/bin/env bash
#
# UserPromptSubmit hook: recall steering. Sources the mem0-brady config, sets
# the app_id domain for this session, and execs the fork's `mem0-hook-prompt`
# console script, which injects a once-per-session search rubric and — on
# resume-intent — pre-searches mem0 and injects the recovered context.
#
# Recall/prose only — never captures, so it adds no duplication. Fail-open: a
# missing env/key/install just skips, never blocks the prompt.
set -euo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

export PATH="$HOME/.local/bin:$PATH"

# Domain partition (app_id) for this session — see run-context.sh.
case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *evergreen*) _mem0_domain=evergreen ;;
  *) _mem0_domain=general ;;
esac
export MEM0_APP_ID="$_mem0_domain"
export MEM0_RECALL_APP_IDS="$_mem0_domain"

if ! command -v mem0-hook-prompt >/dev/null 2>&1; then
  printf '%s\n' '{"continue": true, "suppressOutput": true}'
  exit 0
fi

exec mem0-hook-prompt
