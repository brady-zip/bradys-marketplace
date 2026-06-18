#!/usr/bin/env bash
#
# Health check for the mem0-brady plugin. Run via /mem0-brady:doctor.
#
# Verifies the full local stack:
#   - macOS (launchd)
#   - uv + the fork's console scripts on PATH
#   - the native qdrant binary
#   - the single config file (~/.config/mem0-brady/.env) exists + has a key
#   - both launchd agents loaded (com.mem0brady.qdrant, com.mem0brady.server)
#   - the Qdrant server answers on :6433 and the MCP server on :8788
#   - the Qdrant storage dir is present + writable
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
QDRANT_URL="${MEM0_BRADY_QDRANT_URL:-http://127.0.0.1:6433}"
MCP_URL="${MEM0_BRADY_MCP_URL:-http://127.0.0.1:8788/mcp}"
GUI="gui/$(id -u)"

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
if [ -x "$QDRANT_BIN" ]; then
  pass "qdrant binary present ($("$QDRANT_BIN" --version 2>/dev/null | head -1))"
else
  fail_required "qdrant binary missing at ${QDRANT_BIN}" "Run /mem0-brady:setup."
fi

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
agent_loaded "$QDRANT_LABEL" && pass "${QDRANT_LABEL} is loaded" || fail_required "${QDRANT_LABEL} not loaded" "Run /mem0-brady:setup."
agent_loaded "$SERVER_LABEL" && pass "${SERVER_LABEL} is loaded" || fail_required "${SERVER_LABEL} not loaded" "Run /mem0-brady:setup."

# --- Qdrant server -----------------------------------------------------------
print_header "Qdrant server (required)"
CODE="$(http_code "${QDRANT_URL}/readyz")"
if [ "$CODE" != "000" ]; then
  pass "Qdrant reachable at ${QDRANT_URL} (HTTP ${CODE})"
else
  fail_required "Qdrant not reachable at ${QDRANT_URL}" "Check ${DATA_DIR}/qdrant.log; re-run /mem0-brady:setup."
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
  fail_required "MCP server not reachable at ${MCP_URL}" "Check ${DATA_DIR}/server.log; re-run /mem0-brady:setup."
fi

# --- Qdrant storage ----------------------------------------------------------
print_header "Qdrant storage (required)"
if [ -d "$QDRANT_STORAGE" ]; then
  if [ -w "$QDRANT_STORAGE" ]; then pass "storage dir present + writable: ${QDRANT_STORAGE}"; else fail_required "storage dir not writable: ${QDRANT_STORAGE}" "chmod u+w ${QDRANT_STORAGE}"; fi
else
  fail_required "storage dir missing: ${QDRANT_STORAGE}" "Run /mem0-brady:setup."
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
