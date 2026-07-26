#!/usr/bin/env bash
# lib-scope.sh — the ONE place that turns a session into mem0 scopes.
#
# Sourced, never exec'd. Every hook wrapper calls `mem0_scope_init` and gets a
# fully-resolved scope environment. Before this file existed the routing rule
# ("any path containing 'evergreen' is the evergreen domain") was copy-pasted
# into seven wrappers, along with the env-source / MCP-URL-bridge / PATH
# preamble. Both are now here exactly once — a divergence between two copies
# was silent and its only symptom was memories landing in the wrong partition,
# which nothing checks and nobody notices until recall comes back empty.
#
# Exports, in mem0's own vocabulary:
#   MEM0_USER_ID          the store's namespace — WHO owns these memories
#   MEM0_APP_ID           the project/domain partition — WHAT they are about
#   MEM0_RECALL_APP_IDS   comma-separated partitions to recall FROM
#   MEM0_AGENT_ID         WHICH agent wrote them (claude / hal / saga …)
# plus MEM0_SCOPE_WHY_<scope>, naming the layer that decided each value so
# /mem0-brady:scopes can explain a resolution instead of just asserting one.
#
# run_id (the workstream scope) is deliberately NOT resolved here. It keys on
# session_id, which a wrapper cannot read: stdin must pass through untouched to
# the exec'd fork hook. The fork resolves it in Python, where the payload is
# already parsed. See hooks.py::_active_workstream.
#
# Precedence, highest first:
#   1. explicit environment   — an agent pinning its own identity at launch
#   2. repo .mem0-brady.json  — what THIS checkout wants
#   3. machine .env rules     — what THIS machine routes by default
#   4. plugin default         — 'general', with no repo names baked in
#
# Fails OPEN throughout: any error resolves to the plugin default rather than
# breaking a session.

# Layer 1 must be snapshotted BEFORE the machine .env is sourced. Sourcing runs
# under `set -a`, so a value from the config file becomes an environment
# variable indistinguishable from one the caller exported — without this
# snapshot, layers 1 and 3 would collapse into each other and the machine
# config could never be overridden by an agent's own launch environment.
_MEM0_ENV_APP_ID="${MEM0_SCOPE_APP_ID:-}"
_MEM0_ENV_RECALL="${MEM0_SCOPE_RECALL_APP_IDS:-}"
_MEM0_ENV_AGENT_ID="${MEM0_SCOPE_AGENT_ID:-}"
_MEM0_ENV_USER_ID="${MEM0_USER_ID:-}"

# mem0_scope_source_env
# Load the machine config, bridge the MCP URL, and put the uv-tool bin dir on
# PATH. Previously the opening ~20 lines of all five run-*.sh wrappers.
mem0_scope_source_env() {
  local env_file="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi

  # Under an external stack, drive mem0 through the MCP server rather than an
  # in-process client: the server already holds the Qdrant URL, collection,
  # user_id and API key, and is long-lived, so a hook neither duplicates that
  # config on the host nor pays a cold Memory init per process. The fork reads
  # MEM0_MCP_URL; the plugin stores it under its own namespaced key.
  # Managed stacks stay on the direct client — unchanged behaviour.
  if [ "${MEM0_BRADY_STACK:-managed}" = "external" ] && [ -n "${MEM0_BRADY_MCP_URL:-}" ]; then
    export MEM0_MCP_URL="$MEM0_BRADY_MCP_URL"
  fi

  export PATH="$HOME/.local/bin:$PATH"
}

# mem0_scope_repo_file <cwd>
# Echo the path to the nearest .mem0-brady.json at or above <cwd>, else nothing.
# Walks to the filesystem root rather than stopping at a .git boundary, because
# a git worktree's .git is a FILE and a bare-checkout layout may have none at
# all — a boundary test would skip the override in exactly the multi-worktree
# setup it exists to serve.
mem0_scope_repo_file() {
  local dir="${1:-$PWD}" guard=0
  [ -d "$dir" ] || dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.mem0-brady.json" ]; then
      printf '%s' "$dir/.mem0-brady.json"
      return 0
    fi
    dir="$(dirname "$dir")"
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && break
  done
  [ -f "/.mem0-brady.json" ] && printf '%s' "/.mem0-brady.json"
  return 0
}

# _mem0_scope_json <file> <jq-filter>
# Read one value out of the repo override. Silent when jq is absent or the file
# is malformed — a syntax error in a checked-in config must not cost a session
# its memory.
_mem0_scope_json() {
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$2 // empty" "$1" 2>/dev/null || true
}

# _mem0_scope_rule_match <cwd> <rules>
# Rules are "app_id:glob" pairs joined by ';' — first match wins, so order them
# most-specific-first. Echoes the app_id of the first glob matching <cwd>.
# Consequence of the separators: an app_id may not contain ':' or ';'.
_mem0_scope_rule_match() {
  local cwd="$1" rules="$2" rule app pat
  local IFS=';'
  for rule in $rules; do
    [ -n "$rule" ] || continue
    app="${rule%%:*}"
    pat="${rule#*:}"
    [ -n "$app" ] && [ -n "$pat" ] && [ "$app" != "$rule" ] || continue
    # Unquoted RHS on purpose: that is what makes $pat a glob and not a literal.
    # shellcheck disable=SC2053
    if [[ "$cwd" == $pat ]]; then
      printf '%s' "$app"
      return 0
    fi
  done
  return 0
}

# mem0_scope_resolve [cwd]
# Resolve every scope and export it, recording which layer won in
# MEM0_SCOPE_WHY_*. Call mem0_scope_source_env first (mem0_scope_init does).
mem0_scope_resolve() {
  local cwd="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local repo_file app why recall agent user

  repo_file="$(mem0_scope_repo_file "$cwd")"
  export MEM0_SCOPE_REPO_FILE="$repo_file"
  export MEM0_SCOPE_CWD="$cwd"

  # --- app_id -------------------------------------------------------------
  if [ -n "$_MEM0_ENV_APP_ID" ]; then
    app="$_MEM0_ENV_APP_ID"; why="env MEM0_SCOPE_APP_ID"
  else
    [ -n "$repo_file" ] && app="$(_mem0_scope_json "$repo_file" '.app_id')"
    if [ -n "${app:-}" ]; then
      why="repo ${repo_file}"
    else
      app="$(_mem0_scope_rule_match "$cwd" "${MEM0_SCOPE_RULES:-}")"
      if [ -n "$app" ]; then
        why="machine rule MEM0_SCOPE_RULES"
      elif [ -n "${MEM0_SCOPE_DEFAULT_APP:-}" ]; then
        app="$MEM0_SCOPE_DEFAULT_APP"; why="machine MEM0_SCOPE_DEFAULT_APP"
      else
        app="general"; why="plugin default"
      fi
    fi
  fi
  export MEM0_APP_ID="$app"
  export MEM0_SCOPE_WHY_APP_ID="$why"

  # --- recall app_ids -----------------------------------------------------
  # Defaults to the write partition. A repo widens it when its work genuinely
  # spans partitions (e.g. a project that should also see 'general' tooling
  # memories) — that is the override worth having, more than the write target.
  if [ -n "$_MEM0_ENV_RECALL" ]; then
    recall="$_MEM0_ENV_RECALL"; why="env MEM0_SCOPE_RECALL_APP_IDS"
  else
    recall=""
    if [ -n "$repo_file" ]; then
      recall="$(_mem0_scope_json "$repo_file" '(.recall_app_ids // []) | join(",")')"
    fi
    if [ -n "$recall" ]; then
      why="repo ${repo_file}"
    elif [ -n "${MEM0_SCOPE_RECALL_APP_IDS:-}" ]; then
      recall="$MEM0_SCOPE_RECALL_APP_IDS"; why="machine MEM0_SCOPE_RECALL_APP_IDS"
    else
      recall="$app"; why="follows app_id"
    fi
  fi
  export MEM0_RECALL_APP_IDS="$recall"
  export MEM0_SCOPE_WHY_RECALL_APP_IDS="$why"

  # --- agent_id -----------------------------------------------------------
  # WHICH agent is writing, orthogonal to what it is writing about. One repo
  # can host several: a coding agent on app_id=<project> and an ops agent on
  # app_id=<project>-ops, each pinning MEM0_SCOPE_AGENT_ID at launch, so their
  # task-learned behaviour never cross-pollinates.
  if [ -n "$_MEM0_ENV_AGENT_ID" ]; then
    agent="$_MEM0_ENV_AGENT_ID"; why="env MEM0_SCOPE_AGENT_ID"
  else
    agent=""
    [ -n "$repo_file" ] && agent="$(_mem0_scope_json "$repo_file" '.agent_id')"
    if [ -n "$agent" ]; then
      why="repo ${repo_file}"
    elif [ -n "${MEM0_SCOPE_AGENT_ID:-}" ]; then
      # Reaching this means the value came from the machine config: an
      # explicitly-exported one was captured into _MEM0_ENV_AGENT_ID above and
      # would have won already.
      agent="$MEM0_SCOPE_AGENT_ID"; why="machine MEM0_SCOPE_AGENT_ID"
    else
      agent="claude"; why="plugin default"
    fi
  fi
  export MEM0_AGENT_ID="$agent"
  export MEM0_SCOPE_WHY_AGENT_ID="$why"

  # --- user_id ------------------------------------------------------------
  # The store namespace. Under an external stack the SERVER owns it and the
  # host may legitimately not know it — in which case we export nothing and
  # mark it unknown, rather than guessing. A guess here is worse than a gap:
  # enforce-metadata.sh denies writes that disagree with this value, so a wrong
  # literal turns the guard into a machine for steering writes at a namespace
  # nothing reads. See MEM0_SCOPE_USER_ID_KNOWN.
  user="${_MEM0_ENV_USER_ID:-${MEM0_USER_ID:-}}"
  if [ -n "$user" ]; then
    export MEM0_USER_ID="$user"
    export MEM0_SCOPE_USER_ID_KNOWN=1
    export MEM0_SCOPE_WHY_USER_ID="config MEM0_USER_ID"
  else
    export MEM0_SCOPE_USER_ID_KNOWN=0
    export MEM0_SCOPE_WHY_USER_ID="unset — server owns it (external stack)"
  fi
}

# mem0_scope_init [cwd]
# The whole preamble in one call. Wrappers reduce to sourcing this file and
# calling this.
mem0_scope_init() {
  mem0_scope_source_env
  mem0_scope_resolve "${1:-}"
}
