#!/usr/bin/env bash
#
# Health check for the mem0-brady plugin. Run via /mem0-brady:doctor.
#
# Verifies the stack this install actually runs. Everything it checks — URLs,
# collection, user_id, ports — comes from ~/.config/mem0-brady/.env, so a
# machine that points at its own store is checked against ITS values, not
# against defaults baked into the plugin.
#
#   - macOS (launchd)
#   - uv + the fork's console scripts on PATH
#   - the single config file (~/.config/mem0-brady/.env) exists + has a key
#   - the Qdrant server answers, and holds a collection matching this config
#   - the MCP server answers
#   - (optional) workstream dirs + any active workstream tags
#
# Managed stack only (MEM0_BRADY_STACK=managed, the default):
#   - the native qdrant binary
#   - both launchd agents loaded (com.mem0brady.qdrant, com.mem0brady.server)
#   - the Qdrant storage dir is present + writable
# Under MEM0_BRADY_STACK=external those three are skipped — somebody else runs
# Qdrant and the MCP server, so the plugin owns no binary, agent, or storage dir.
#
# Compose stack only (MEM0_BRADY_STACK=compose):
#   - docker is running and both containers are up
#   - the Qdrant storage dir is present + writable
#   - the RUNNING container's config still matches the config file. A container
#     keeps serving whatever it was started with, so an edited .env and a stale
#     container are indistinguishable from the outside — this is the one check
#     that catches it.
#
# Exits 0 if all required checks pass, 1 otherwise. Optional checks warn but
# never fail the run.
set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REQUIRED_FAILED=0
OPTIONAL_FAILED=0

# Same overrides setup.sh, migrate.sh and the hooks honor, so all of them can be
# pointed at one relocated (or test) config instead of drifting apart.
CONFIG_DIR="${MEM0_BRADY_CONFIG_DIR:-${HOME}/.config/mem0-brady}"
ENV_FILE="${MEM0_BRADY_ENV:-${CONFIG_DIR}/.env}"
DATA_DIR="${MEM0_BRADY_DATA_DIR:-${HOME}/.local/share/mem0-brady}"
QDRANT_BIN="${DATA_DIR}/bin/qdrant"
QDRANT_STORAGE="${DATA_DIR}/qdrant-storage"
QDRANT_LABEL="com.mem0brady.qdrant"
SERVER_LABEL="com.mem0brady.server"
GUI="gui/$(id -u)"

# Read a KEY out of the config without sourcing it (the file holds the OpenAI
# key; sourcing would export it into this shell and every child process).
env_get() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Precedence: explicit env var > config > default. Defaults only apply to a
# machine with no config yet, which the Config section reports as a failure
# anyway.
STACK="${MEM0_BRADY_STACK:-$(env_get MEM0_BRADY_STACK)}"; STACK="${STACK:-managed}"
QDRANT_URL="${MEM0_BRADY_QDRANT_URL:-$(env_get MEM0_QDRANT_URL)}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6433}"
MCP_URL="${MEM0_BRADY_MCP_URL:-$(env_get MEM0_BRADY_MCP_URL)}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8788/mcp}"
COLLECTION="$(env_get MEM0_COLLECTION)"; COLLECTION="${COLLECTION:-mem0_brady}"
# Deliberately NOT defaulted. Under an external stack the server owns the
# namespace and this host legitimately has no MEM0_USER_ID, so a default here
# would be a guess reported as fact — and this script's whole premise is that it
# checks a machine against ITS values. Empty means "unknown", and the Stack
# section says so rather than naming a store that may not exist.
USER_ID="$(env_get MEM0_USER_ID)"
# An external stack drives mem0 through the server, so this host holds no key,
# no store identity and no mem0 install. Checking for them would report a
# healthy install as broken.
MCP_MODE=0
COMPOSE_MODE=0
case "$STACK" in
  external) MCP_MODE=1 ;;
  # compose also drives mem0 through the server, so the same host-side checks
  # are skipped — but this plugin OWNS that server, so its health is checkable
  # here in a way an external one is not.
  compose)  MCP_MODE=1; COMPOSE_MODE=1 ;;
esac

print_header() { printf "\n${BOLD}%s${NC}\n" "$1"; printf '%s\n' "------------------------------------------------------------"; }
pass() { printf "  ${GREEN}OK${NC}      %s\n" "$1"; }
fail_required() { printf "  ${RED}MISSING${NC} %s\n" "$1"; REQUIRED_FAILED=$((REQUIRED_FAILED + 1)); [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"; return 0; }
fail_optional() { printf "  ${YELLOW}WARN${NC}    %s\n" "$1"; OPTIONAL_FAILED=$((OPTIONAL_FAILED + 1)); [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"; return 0; }

http_code() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

agent_loaded() { launchctl print "${GUI}/$1" >/dev/null 2>&1; }

# --- Platform ----------------------------------------------------------------
print_header "Platform (required)"
if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS detected"
else
  fail_required "not macOS ($(uname -s)) — mem0-brady relies on launchd" "Run on macOS."
fi

# --- Toolchain ---------------------------------------------------------------
print_header "Toolchain (required)"
export PATH="${HOME}/.local/bin:${PATH}"
if command -v uv >/dev/null 2>&1; then pass "uv found at $(command -v uv)"; else fail_required "uv not on PATH" "Run /mem0-brady:setup (installs uv)."; fi
for bin in mem0-mcp-selfhosted mem0-hook-context mem0-hook-stop; do
  if command -v "$bin" >/dev/null 2>&1; then pass "$bin on PATH"; else fail_required "$bin not on PATH" "Run /mem0-brady:setup."; fi
done
if [ "$STACK" = "managed" ]; then
  if [ -x "$QDRANT_BIN" ]; then
    pass "qdrant binary present ($("$QDRANT_BIN" --version 2>/dev/null | head -1))"
  else
    fail_required "qdrant binary missing at ${QDRANT_BIN}" "Run /mem0-brady:setup."
  fi
else
  pass "qdrant binary not needed (external stack)"
fi

# --- Stack + identity --------------------------------------------------------
print_header "Stack + store identity"
pass "stack: ${STACK}"
pass "mcp:    ${MCP_URL}"
if [ "$MCP_MODE" = "1" ]; then
  pass "store identity, embeddings and API key: owned by the server"
  # "Owned by the server" is true but useless on its own — it names nothing you
  # can check against. Ask the server what it actually holds, so this reports
  # the real namespace rather than an assurance that one exists somewhere.
  # shellcheck source=lib-mcp.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-mcp.sh"
  if mcp_init "$MCP_URL"; then
    SERVER_ENT="$(mcp_call list_entities '{}' || true)"
    if [ -n "$SERVER_ENT" ]; then
      SERVER_USERS="$(printf '%s' "$SERVER_ENT" | jq -r '[.users[]? | "\(.value) (\(.count))"] | join(", ")' 2>/dev/null)"
      SERVER_AGENTS="$(printf '%s' "$SERVER_ENT" | jq -r '[.agents[]? | "\(.value) (\(.count))"] | join(", ")' 2>/dev/null)"
      [ -n "$SERVER_USERS" ] && pass "server user_id: ${SERVER_USERS}" \
        || fail_optional "server holds no memories under any user_id" "Expected on a brand-new store; otherwise check you are pointed at the right server."
      [ -n "$SERVER_AGENTS" ] && pass "server agent_id: ${SERVER_AGENTS}"
      # The host guessing a namespace the server disagrees with is the exact
      # failure this pairing exists to catch: hooks and the write guard enforce
      # the host's copy while writes land under the server's.
      if [ -n "$USER_ID" ] && ! printf '%s' "$SERVER_ENT" | jq -e --arg u "$USER_ID" '[.users[]?.value] | index($u)' >/dev/null 2>&1; then
        if [ "$COMPOSE_MODE" = "1" ]; then
          # Under compose the host copy is not a duplicate to delete — it is the
          # SAME line the container was started from. Disagreement therefore
          # means the container predates the config, not that the host is wrong.
          fail_required "host pins MEM0_USER_ID=${USER_ID}, which the server does not hold" \
            "The running container is stale relative to ${ENV_FILE} — restart it: docker compose --env-file ${ENV_FILE} up -d"
        else
          fail_required "host pins MEM0_USER_ID=${USER_ID}, which the server does not hold" \
            "Remove MEM0_USER_ID from ${ENV_FILE} — under an external stack the server owns the namespace, and a host copy that disagrees is enforced against writes that land elsewhere."
        fi
      elif [ -n "$USER_ID" ]; then
        pass "host MEM0_USER_ID=${USER_ID} matches the server"
      fi
    fi
  else
    fail_optional "could not read store identity from ${MCP_URL}" "Start the external stack; identity is unverified until then."
  fi
else
  pass "collection: ${COLLECTION}"
  if [ -n "$USER_ID" ]; then
    pass "user_id: ${USER_ID}"
  else
    fail_required "no MEM0_USER_ID in ${ENV_FILE}" "A managed stack owns its own identity — run /mem0-brady:setup."
  fi
  pass "qdrant: ${QDRANT_URL}"
fi

# --- Capture policy ----------------------------------------------------------
# What the Stop/PreCompact hooks will actually DO here, as opposed to what is
# installed. Its own section because the defaults are per-ENTRYPOINT: two cloud
# containers off one image, with byte-identical config, capture differently.
# A session that records nothing is indistinguishable from a healthy one while
# you are inside it, so this is the only place that difference is visible.
#
# The policy is NOT restated here. It is resolved by importing the module that
# decides (hooks.py) under the interpreter the hooks themselves run on, because
# a second copy of the table in bash is precisely the drift that would make this
# check confidently wrong.
print_header "Capture policy"
EP_RAW="${CLAUDE_CODE_ENTRYPOINT:-}"
pass "entrypoint: ${EP_RAW:-(unset — not launched by Claude Code)}"
HOOK_BIN="$(command -v mem0-hook-stop 2>/dev/null || true)"
if [ -n "$HOOK_BIN" ]; then
  HOOK_PY="$(head -1 "$HOOK_BIN" | sed 's/^#!//' || true)"
  if [ -x "$HOOK_PY" ]; then
    # A switch set only in the config has to be honored here exactly as the
    # hooks will honor it — but lifted key by key rather than by sourcing the
    # file, which would export OPENAI_API_KEY into this shell and its children
    # (the reason env_get exists at all).
    POLICY="$(
      MEM0_CAPTURE_ENABLED="${MEM0_CAPTURE_ENABLED:-$(env_get MEM0_CAPTURE_ENABLED)}" \
      MEM0_HANDOFF_ENABLED="${MEM0_HANDOFF_ENABLED:-$(env_get MEM0_HANDOFF_ENABLED)}" \
      "$HOOK_PY" -c 'import mem0_mcp_selfhosted.hooks as h
for label, on, var in (
    ("capture", h._CAPTURE_ENABLED, "MEM0_CAPTURE_ENABLED"),
    ("handoff", h._HANDOFF_ENABLED, "MEM0_HANDOFF_ENABLED"),
):
    print(f"{label} ON" if on else f"{label} OFF  ({h._disabled_by(var)})")' 2>/dev/null)"
    if [ -n "$POLICY" ]; then
      printf '%s\n' "$POLICY" | while IFS= read -r line; do pass "$line"; done
    else
      fail_optional "could not resolve capture policy from the installed hooks" \
        "Reinstall: uv tool install --force <plugin>/server"
    fi
  fi
else
  fail_optional "mem0-hook-stop not on PATH — capture policy unknown" \
    "Run /mem0-brady:setup, then re-run doctor."
fi

# --- Config ------------------------------------------------------------------
print_header "Config (required)"
if [ -f "$ENV_FILE" ]; then
  pass "config present at ${ENV_FILE}"
  if [ "$MCP_MODE" = "1" ]; then
    pass "no OPENAI_API_KEY needed — the server holds it"
  else
    KEY="$(grep -E '^OPENAI_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [ -n "$KEY" ] && [ "$KEY" != "__OPENAI_API_KEY__" ]; then pass "OPENAI_API_KEY is set"; else fail_required "OPENAI_API_KEY missing/placeholder in ${ENV_FILE}" "Run /mem0-brady:setup."; fi
  fi
  PERMS="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  [ "$PERMS" = "600" ] && pass "permissions 600" || fail_optional "permissions ${PERMS:-unknown} (expected 600)" "chmod 600 ${ENV_FILE}"
else
  fail_required "config not found at ${ENV_FILE}" "Run /mem0-brady:setup."
fi

# --- launchd agents ----------------------------------------------------------
print_header "launchd agents (required)"
if [ "$STACK" = "managed" ]; then
  agent_loaded "$QDRANT_LABEL" && pass "${QDRANT_LABEL} is loaded" || fail_required "${QDRANT_LABEL} not loaded" "Run /mem0-brady:setup."
  agent_loaded "$SERVER_LABEL" && pass "${SERVER_LABEL} is loaded" || fail_required "${SERVER_LABEL} not loaded" "Run /mem0-brady:setup."
elif [ "$COMPOSE_MODE" = "1" ]; then
  pass "no launchd agents (compose stack — the containers are the supervisor)"
else
  pass "no launchd agents (external stack — somebody else runs Qdrant + the MCP server)"
  # A leftover managed agent still bound to its port is invisible here but will
  # quietly serve a DIFFERENT store than the one this config points at.
  for lbl in "$QDRANT_LABEL" "$SERVER_LABEL"; do
    agent_loaded "$lbl" && fail_optional "${lbl} is still loaded from a previous managed install" \
      "It serves a different store than this config. Remove it: launchctl bootout ${GUI}/${lbl}"
  done
fi

# --- Qdrant server -----------------------------------------------------------
print_header "Qdrant server (required)"
if [ "$MCP_MODE" = "1" ]; then
  pass "not contacted from this host — the server reaches it"
else
CODE="$(http_code "${QDRANT_URL}/readyz")"
if [ "$CODE" != "000" ]; then
  pass "Qdrant reachable at ${QDRANT_URL} (HTTP ${CODE})"
  # The recall/capture hooks instantiate mem0 directly against this URL, so a
  # collection whose vector size disagrees with MEM0_EMBED_DIMS fails at runtime
  # deep inside mem0. Surface it here instead.
  COLL_JSON="$(curl -s --max-time 5 "${QDRANT_URL}/collections/${COLLECTION}" 2>/dev/null || true)"
  if printf '%s' "$COLL_JSON" | jq -e '.result' >/dev/null 2>&1; then
    HAVE_DIMS="$(printf '%s' "$COLL_JSON" | jq -r '.result.config.params.vectors.size // empty')"
    POINTS="$(printf '%s' "$COLL_JSON" | jq -r '.result.points_count // 0')"
    WANT_DIMS="$(env_get MEM0_EMBED_DIMS)"
    if [ -n "$HAVE_DIMS" ] && [ -n "$WANT_DIMS" ] && [ "$HAVE_DIMS" != "$WANT_DIMS" ]; then
      fail_required "collection '${COLLECTION}' has ${HAVE_DIMS}-dim vectors but MEM0_EMBED_DIMS=${WANT_DIMS}" \
        "Point MEM0_COLLECTION at a matching collection, or migrate the data."
    else
      pass "collection '${COLLECTION}': ${POINTS} memories, ${HAVE_DIMS:-?} dims"
    fi
  else
    fail_optional "collection '${COLLECTION}' does not exist yet" "Normal on a fresh store — it is created on the first write."
  fi
else
  if [ "$STACK" = "managed" ]; then
    fail_required "Qdrant not reachable at ${QDRANT_URL}" "Check ${DATA_DIR}/qdrant.log; re-run /mem0-brady:setup."
  else
    fail_required "Qdrant not reachable at ${QDRANT_URL}" \
      "Start your external stack, or point MEM0_QDRANT_URL at a reachable Qdrant."
  fi
fi
fi

# --- MCP server --------------------------------------------------------------
print_header "MCP server (required)"
# Streamable-HTTP at /mcp returns a non-2xx to a plain GET (wants an
# Accept: text/event-stream header), but ANY HTTP response (non-000) proves
# something is listening. 000 means nothing is there.
CODE="$(http_code "$MCP_URL")"
if [ "$CODE" != "000" ]; then
  pass "MCP server reachable at ${MCP_URL} (HTTP ${CODE})"
else
  if [ "$STACK" = "managed" ]; then
    fail_required "MCP server not reachable at ${MCP_URL}" "Check ${DATA_DIR}/server.log; re-run /mem0-brady:setup."
  else
    fail_required "MCP server not reachable at ${MCP_URL}" "Start your external stack (the plugin does not run it)."
  fi
fi

# --- Compose stack -----------------------------------------------------------
# Only meaningful when the plugin owns the containers. The point of these checks
# is drift: a container keeps running happily against the config it was STARTED
# with, so an edited .env and a stale container look identical from the outside.
if [ "$COMPOSE_MODE" = "1" ]; then
  print_header "Compose stack (required)"
  if ! command -v docker >/dev/null 2>&1; then
    fail_required "docker not found, but MEM0_BRADY_STACK=compose" "Install Docker, or re-run /mem0-brady:setup and choose another stack."
  elif ! docker info >/dev/null 2>&1; then
    fail_required "docker is installed but not running" "Start Docker, then re-run."
  else
    pass "docker running"
    PROJECT="$(env_get MEM0_BRADY_COMPOSE_PROJECT)"; PROJECT="${PROJECT:-mem0-host}"
    for svc in qdrant mem0-mcp; do
      cid="$(docker ps -q -f "name=^${PROJECT}-${svc}-1$" 2>/dev/null || true)"
      if [ -n "$cid" ]; then
        pass "${PROJECT}-${svc}-1 running"
      else
        fail_required "${PROJECT}-${svc}-1 not running" \
          "Start it: docker compose --env-file ${ENV_FILE} up -d"
      fi
    done
    # The drift check proper: compare the model the container was started with
    # against the one the config now says. They diverge the moment you edit the
    # config without restarting, and every write silently uses the old value.
    live_model="$(docker exec "${PROJECT}-mem0-mcp-1" printenv MEM0_LLM_MODEL 2>/dev/null || true)"
    cfg_model="$(env_get MEM0_LLM_MODEL)"
    if [ -n "$live_model" ] && [ -n "$cfg_model" ]; then
      if [ "$live_model" = "$cfg_model" ]; then
        pass "container config matches ${ENV_FILE} (MEM0_LLM_MODEL=${live_model})"
      else
        fail_required "container is running MEM0_LLM_MODEL=${live_model} but the config says ${cfg_model}" \
          "The container predates your edit — restart it: docker compose --env-file ${ENV_FILE} up -d"
      fi
    fi
  fi
fi

# --- Qdrant storage ----------------------------------------------------------
print_header "Qdrant storage (required)"
if [ "$COMPOSE_MODE" = "1" ]; then
  CSTORAGE="$(env_get MEM0_BRADY_QDRANT_STORAGE)"
  if [ -z "$CSTORAGE" ]; then
    fail_required "no MEM0_BRADY_QDRANT_STORAGE in ${ENV_FILE}" "compose cannot start without it — run /mem0-brady:setup."
  elif [ -d "$CSTORAGE" ] && [ -w "$CSTORAGE" ]; then
    pass "storage dir present + writable: ${CSTORAGE}"
  elif [ -d "$CSTORAGE" ]; then
    fail_required "storage dir not writable: ${CSTORAGE}" "chmod u+w ${CSTORAGE}"
  else
    fail_required "storage dir missing: ${CSTORAGE}" "Create it, or run /mem0-brady:setup."
  fi
elif [ "$STACK" != "managed" ]; then
  pass "storage is owned by an external stack, not the plugin"
elif [ -d "$QDRANT_STORAGE" ]; then
  if [ -w "$QDRANT_STORAGE" ]; then pass "storage dir present + writable: ${QDRANT_STORAGE}"; else fail_required "storage dir not writable: ${QDRANT_STORAGE}" "chmod u+w ${QDRANT_STORAGE}"; fi
else
  fail_required "storage dir missing: ${QDRANT_STORAGE}" "Run /mem0-brady:setup."
fi

# --- Reranker (optional) -----------------------------------------------------
print_header "Reranker (optional)"
if [ "$MCP_MODE" = "1" ]; then
  pass "server-side concern — this host runs no retrieval"
else
RERANK_PROVIDER=""
[ -f "$ENV_FILE" ] && RERANK_PROVIDER="$(grep -E '^MEM0_RERANK_PROVIDER=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [ -z "$RERANK_PROVIDER" ]; then
  pass "reranking disabled (MEM0_RERANK_PROVIDER unset) — search is vector-only"
else
  pass "reranking enabled (provider=${RERANK_PROVIDER})"
  RERANK_MODEL="$(grep -E '^MEM0_RERANK_MODEL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  RERANK_MODEL="${RERANK_MODEL:-cross-encoder/ms-marco-MiniLM-L-6-v2}"
  TOOL_PY="$(uv tool dir 2>/dev/null)/mem0-mcp-selfhosted/bin/python"
  if [ -x "$TOOL_PY" ] && "$TOOL_PY" -c "import sentence_transformers" >/dev/null 2>&1; then
    pass "sentence-transformers importable in the tool venv"
    # Fast cache probe (does NOT load torch/the model): is config.json cached?
    if "$TOOL_PY" -c 'from huggingface_hub import try_to_load_from_cache as t; import sys; sys.exit(0 if isinstance(t(sys.argv[1],"config.json"),str) else 1)' "$RERANK_MODEL" >/dev/null 2>&1; then
      pass "reranker model cached (${RERANK_MODEL})"
    else
      fail_optional "reranker model not cached (${RERANK_MODEL})" "Downloads (~80MB) on the server's next boot; or re-run /mem0-brady:setup to pre-cache."
    fi
  else
    fail_optional "sentence-transformers not importable in the tool venv" "Re-run /mem0-brady:setup (reinstalls the fork with reranker deps)."
  fi
fi
fi

# --- Scopes (optional) -------------------------------------------------------
print_header "Scopes (optional)"
# How this machine partitions the store. Reported for the CWD, since scope is a
# property of where a session runs, not of the install. Full inventory (which
# partitions actually hold memories) is /mem0-brady:scopes; this only checks
# that resolution works and that the config is not silently mangled.
SCOPE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" 2>/dev/null && pwd)/lib-scope.sh"
if [ ! -f "$SCOPE_LIB" ]; then
  fail_optional "scope resolver missing at ${SCOPE_LIB}" "Reinstall the plugin."
else
  SCOPE_OUT="$(
    # shellcheck disable=SC1090
    . "$SCOPE_LIB" 2>/dev/null
    mem0_scope_init "$PWD" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s' "${MEM0_APP_ID:-}" "${MEM0_RECALL_APP_IDS:-}" \
      "${MEM0_AGENT_ID:-}" "${MEM0_SCOPE_WHY_APP_ID:-}" \
      "${MEM0_SCOPE_WHY_AGENT_ID:-}" "${MEM0_SCOPE_REPO_FILE:-}"
  )"
  S_APP="${SCOPE_OUT%%|*}";    REST="${SCOPE_OUT#*|}"
  S_RECALL="${REST%%|*}";      REST="${REST#*|}"
  S_AGENT="${REST%%|*}";       REST="${REST#*|}"
  S_WHY="${REST%%|*}";         REST="${REST#*|}"
  S_WHY_AGENT="${REST%%|*}";   S_REPO="${REST#*|}"
  if [ -n "$S_APP" ]; then
    pass "app_id=${S_APP}   (${S_WHY})"
    pass "agent_id=${S_AGENT}   (${S_WHY_AGENT})"
    if [ "$S_RECALL" = "$S_APP" ]; then
      pass "recall: ${S_RECALL} (same as writes)"
    else
      pass "recall widened to: ${S_RECALL}"
    fi
    # Naming the file matters: a scope coming from a checked-in repo override is
    # the case most likely to surprise someone reading only the machine config.
    if [ -n "$S_REPO" ]; then
      pass "repo override in effect: ${S_REPO}"
    else
      pass "no repo override (no .mem0-brady.json at or above ${PWD})"
    fi
  else
    fail_optional "scope resolution produced no app_id for ${PWD}" "Run /mem0-brady:scopes to see which layer failed."
  fi

  # The rules value is globs joined by ';' in a file that gets `source`d, so an
  # unquoted value does not merely misparse — the ';' ends the assignment and
  # the shell tries to RUN the remainder. Symptom is a rule that never matches,
  # which looks identical to a rule that does not apply.
  RAW_RULES="$(grep -E '^MEM0_SCOPE_RULES=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  if [ -n "$RAW_RULES" ]; then
    case "$RAW_RULES" in
      \'*\'|\"*\") pass "MEM0_SCOPE_RULES is quoted" ;;
      *\;*|*\**)
        fail_optional "MEM0_SCOPE_RULES is unquoted in ${ENV_FILE}" \
          "Wrap the value in single quotes — this file is sourced, so an unquoted ';' ends the assignment and an unquoted '*' globs against the cwd." ;;
      *) pass "MEM0_SCOPE_RULES set" ;;
    esac
  else
    pass "no MEM0_SCOPE_RULES — every path resolves to the default partition"
  fi
fi

# --- Workstreams (optional) --------------------------------------------------
print_header "Workstreams (optional)"
# Multi-session work grouping (/mem0-brady:workstream). All paths are created
# lazily on first activation, so absence is normal — never a hard failure. Paths
# honor the same overrides the fork + workstream.py use.
WORKSTREAM_DIR="${MEM0_WORKSTREAM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mem0-brady/workstreams}"
WS_ACTIVE_DIR="${WORKSTREAM_DIR}/active"
SESSIONS_DIR="${MEM0_BRADY_SESSIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mem0-brady/sessions}"
# Extract a string field from a pretty-printed pointer JSON (no jq dependency).
_ws_field() { sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" 2>/dev/null | head -1; }

if [ -d "$WORKSTREAM_DIR" ]; then
  ws_docs="$(find "$WORKSTREAM_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  # A doc is archived only if it says so: the status field postdates the first
  # workstreams, and an un-statused doc is one nobody archived.
  ws_archived="$(grep -lE '^- status:[[:space:]]*archived' "$WORKSTREAM_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  pass "workstreams dir present: ${WORKSTREAM_DIR} (${ws_docs} doc(s), $((ws_docs - ws_archived)) active / ${ws_archived} archived)"
  [ -w "$WORKSTREAM_DIR" ] || fail_optional "workstreams dir not writable: ${WORKSTREAM_DIR}" "chmod u+w ${WORKSTREAM_DIR}"
else
  pass "no workstreams yet — created on first /mem0-brady:workstream activation"
fi

if [ -d "$SESSIONS_DIR" ]; then
  sess_n="$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  pass "per-cwd session markers present: ${SESSIONS_DIR} (${sess_n})"
else
  pass "no session markers yet — steer.sh writes one per cwd at SessionStart"
fi

if [ -d "$WS_ACTIVE_DIR" ] && find "$WS_ACTIVE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | grep -q .; then
  n="$(find "$WS_ACTIVE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  pass "${n} active workstream tag(s):"
  find "$WS_ACTIVE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do
    slug="$(_ws_field "$f" slug)"; sid="$(_ws_field "$f" session_id)"; when="$(_ws_field "$f" activated_at)"
    printf "          - %s  (session %s, activated %s)\n" "${slug:-?}" "${sid:0:8}" "${when:-?}"
  done
else
  pass "no active workstream tags — no session is currently tagged"
fi

# --- Summary -----------------------------------------------------------------
print_header "Summary"
if [ "$REQUIRED_FAILED" -eq 0 ] && [ "$OPTIONAL_FAILED" -eq 0 ]; then
  printf "${GREEN}All checks passed.${NC} mem0-brady is healthy — recall/capture hooks and mcp__mem0__* tools are live.\n"
  exit 0
fi
[ "$REQUIRED_FAILED" -gt 0 ] && printf "${RED}${REQUIRED_FAILED} required check(s) failed.${NC} Fix the items above (usually: re-run /mem0-brady:setup).\n"
[ "$OPTIONAL_FAILED" -gt 0 ] && printf "${YELLOW}${OPTIONAL_FAILED} optional check(s) warned.${NC} The plugin still works.\n"
[ "$REQUIRED_FAILED" -gt 0 ] && exit 1
exit 0
