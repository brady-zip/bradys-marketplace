#!/usr/bin/env bash
#
# UserPromptSubmit hook: recall steering. Sources the mem0-brady config, sets
# the app_id domain for this session, and execs the fork's `mem0-hook-prompt`
# console script, which injects a once-per-session search rubric and — on
# resume-intent — pre-searches mem0 and injects the recovered context.
#
# Recall/prose only — never captures, so it adds no duplication. Fail-open: a
# missing env/key/install just skips, never blocks the prompt.
set -uo pipefail

# Config file, MCP-URL bridge, PATH, and every mem0 scope — see lib-scope.sh.
# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"
mem0_scope_init

# Capture-tee-replay: run the fork hook, log what it injected (for
# /mem0-brady:digest), replay its output. Replaces a bare `exec`.
# shellcheck source=lib-recall-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-recall-log.sh"
mem0_run_and_log mem0-hook-prompt prompt
