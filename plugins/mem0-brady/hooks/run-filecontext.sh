#!/usr/bin/env bash
#
# PreToolUse(Read) hook: file context. Sources the mem0-brady config, sets the
# app_id domain, and execs the fork's `mem0-hook-filecontext` console script,
# which searches mem0 for the file about to be read and injects a compact
# "prior work on this file" list. Recall only — never blocks the Read.
#
# Fail-open: a missing env/key/install just skips.
set -uo pipefail

# Config file, MCP-URL bridge, PATH, and every mem0 scope — see lib-scope.sh.
# shellcheck source=lib-scope.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-scope.sh"
mem0_scope_init

# Capture-tee-replay: run the fork hook, log what it injected (for
# /mem0-brady:digest), replay its output. Replaces a bare `exec`.
# shellcheck source=lib-recall-log.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-recall-log.sh"
mem0_run_and_log mem0-hook-filecontext filecontext
