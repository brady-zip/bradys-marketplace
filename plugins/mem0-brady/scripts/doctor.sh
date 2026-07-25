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
# Under MEM0_BRADY_STACK=external those three are skipped — you run Qdrant and
# the MCP server yourself, so the plugin owns no binary, agent, or storage dir.
#
# Exits 0 if all required checks pass, 1 otherwise. Optional checks warn but
# never fail the run.
set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REQUIRED_FAILED=0
OPTIONAL_FAILED=0

CONFIG_DIR="${HOME}/.config/mem0-brady"
ENV_FILE="${CONFIG_DIR}/.env"
DATA_DIR="${HOME}/.local/share/mem0-brady"
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
USER_ID="$(env_get MEM0_USER_ID)"; USER_ID="${USER_ID:-shared-bch}"

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
pass "collection: ${COLLECTION}   user_id: ${USER_ID}"
pass "qdrant: ${QDRANT_URL}"
pass "mcp:    ${MCP_URL}"

# --- Config ------------------------------------------------------------------
print_header "Config (required)"
if [ -f "$ENV_FILE" ]; then
  pass "config present at ${ENV_FILE}"
  KEY="$(grep -E '^OPENAI_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  if [ -n "$KEY" ] && [ "$KEY" != "__OPENAI_API_KEY__" ]; then pass "OPENAI_API_KEY is set"; else fail_required "OPENAI_API_KEY missing/placeholder in ${ENV_FILE}" "Run /mem0-brady:setup."; fi
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
else
  pass "no launchd agents (external stack — you run Qdrant + the MCP server)"
  # A leftover managed agent still bound to its port is invisible here but will
  # quietly serve a DIFFERENT store than the one this config points at.
  for lbl in "$QDRANT_LABEL" "$SERVER_LABEL"; do
    agent_loaded "$lbl" && fail_optional "${lbl} is still loaded from a previous managed install" \
      "It serves a different store than this config. Remove it: launchctl bootout ${GUI}/${lbl}"
  done
fi

# --- Qdrant server -----------------------------------------------------------
print_header "Qdrant server (required)"
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
      "Start your external stack. The hooks talk to Qdrant DIRECTLY, so it must be published on the host — a container-network-only port is invisible to them (docker-compose: ports: [\"127.0.0.1:6333:6333\"])."
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

# --- Qdrant storage ----------------------------------------------------------
print_header "Qdrant storage (required)"
if [ "$STACK" != "managed" ]; then
  pass "storage is owned by your external stack, not the plugin"
elif [ -d "$QDRANT_STORAGE" ]; then
  if [ -w "$QDRANT_STORAGE" ]; then pass "storage dir present + writable: ${QDRANT_STORAGE}"; else fail_required "storage dir not writable: ${QDRANT_STORAGE}" "chmod u+w ${QDRANT_STORAGE}"; fi
else
  fail_required "storage dir missing: ${QDRANT_STORAGE}" "Run /mem0-brady:setup."
fi

# --- Reranker (optional) -----------------------------------------------------
print_header "Reranker (optional)"
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
  pass "workstreams dir present: ${WORKSTREAM_DIR} (${ws_docs} doc(s))"
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
