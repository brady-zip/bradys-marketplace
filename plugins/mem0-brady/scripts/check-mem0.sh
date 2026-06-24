#!/usr/bin/env bash
#
# Setup check for the grill-me plugin.
#
# The grill-me skill persists resolved glossary terms and decisions to
# Mem0 via the self-hosted `mem0` MCP server instead of writing CONTEXT.md /
# ADR files. That server must be (a) running locally and (b) registered with
# your MCP client so the add_memory / search_memories / get_memories tools are
# exposed.
#
# This script verifies:
#   - curl / jq are available (used by this check and by skill workflows)
#   - the mem0 MCP server is reachable on http://127.0.0.1:8788/mcp
#   - a `mem0` MCP server is registered with the Claude client
#   - the backing Qdrant vector store on http://127.0.0.1:6333 (optional, info only)
#
# Exits 0 if all required checks pass, 1 otherwise. Optional checks never fail
# the script but print remediation hints.

set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

REQUIRED_FAILED=0
OPTIONAL_FAILED=0

MEM0_MCP_URL="${MEM0_MCP_URL:-http://127.0.0.1:8788/mcp}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6333}"

print_header() {
  printf "\n${BOLD}%s${NC}\n" "$1"
  printf '%s\n' "------------------------------------------------------------"
}

pass() {
  printf "  ${GREEN}OK${NC}      %s\n" "$1"
}

fail_required() {
  printf "  ${RED}MISSING${NC} %s\n" "$1"
  REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
  if [ -n "${2:-}" ]; then
    printf "          ${BLUE}Fix:${NC} %s\n" "$2"
  fi
}

fail_optional() {
  printf "  ${YELLOW}WARN${NC}    %s\n" "$1"
  OPTIONAL_FAILED=$((OPTIONAL_FAILED + 1))
  if [ -n "${2:-}" ]; then
    printf "          ${BLUE}Fix:${NC} %s\n" "$2"
  fi
}

info() {
  printf "          %s\n" "$1"
}

# Return the HTTP status code for a URL, or 000 if the connection failed.
# Note: curl prints "%{http_code}" (which is 000 on a connection failure) AND
# exits non-zero, so we must NOT add a `|| echo 000` fallback — that would
# concatenate a second "000" and break the != "000" down-detection below.
http_code() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# --- Shell helpers ------------------------------------------------------------
print_header "Shell helpers (required)"
for tool in curl jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool found at $(command -v "$tool")"
  else
    fail_required \
      "$tool not on PATH" \
      "Install via Homebrew: brew install $tool"
  fi
done

# --- mem0 MCP server ----------------------------------------------------------
print_header "mem0 MCP server (required)"
# The mem0 MCP server speaks streamable-HTTP at /mcp. A plain GET returns a
# non-2xx code (e.g. 406 Not Acceptable, because the transport wants an
# `Accept: text/event-stream` header) — but ANY HTTP response (non-000) proves
# something is listening. A 000 means nothing is there.
MCP_CODE="$(http_code "${MEM0_MCP_URL}")"
if [ "$MCP_CODE" != "000" ]; then
  pass "mem0 MCP reachable at ${MEM0_MCP_URL} (HTTP ${MCP_CODE})"
else
  fail_required \
    "mem0 MCP server not reachable at ${MEM0_MCP_URL}" \
    "Start the self-hosted mem0 MCP server (project ~/dev/unified-memory/mem0-mcp-selfhosted), and make sure its backing Qdrant container is up (docker start openmemory-mem0_store-1). Override the URL with MEM0_MCP_URL if you run it elsewhere."
fi

# --- mem0 MCP server registered with the Claude client ------------------------
print_header "mem0 MCP registration (required)"
# The skill calls the add_memory / search_memories / get_memories tools, which
# are only available if a `mem0` MCP server is registered with your client.
# Probe `claude mcp list` first; if the CLI is unavailable, fall back to looking
# for the server in ~/.claude.json (where HTTP MCP servers are registered).
REGISTERED=0
if command -v claude >/dev/null 2>&1; then
  MCP_LIST="$(claude mcp list 2>/dev/null || true)"
  if printf '%s' "$MCP_LIST" | grep -qiE 'mem0|8788'; then
    pass "A mem0 MCP server appears registered with the Claude CLI"
    printf '%s\n' "$MCP_LIST" | grep -iE 'mem0|8788' | sed 's/^/            /'
    REGISTERED=1
  fi
fi
if [ "$REGISTERED" -eq 0 ] && [ -f "$HOME/.claude.json" ]; then
  if jq -e '.mcpServers // {} | to_entries[] | select((.key|test("mem0";"i")) or ((.value.url // "")|test("8788")))' \
      "$HOME/.claude.json" >/dev/null 2>&1; then
    pass "A mem0 MCP server is registered in ~/.claude.json"
    REGISTERED=1
  fi
fi
if [ "$REGISTERED" -eq 0 ]; then
  fail_required \
    "No mem0 MCP server found (checked 'claude mcp list' and ~/.claude.json)" \
    "Register it: claude mcp add --transport http --scope user mem0 \"${MEM0_MCP_URL}\""
fi

# --- Qdrant backing store (optional) ------------------------------------------
print_header "Qdrant backing store (optional)"
QDRANT_CODE="$(http_code "${QDRANT_URL}/collections")"
if [ "$QDRANT_CODE" != "000" ]; then
  pass "Qdrant reachable at ${QDRANT_URL} (HTTP ${QDRANT_CODE}) — browse memories at ${QDRANT_URL}/dashboard"
else
  fail_optional \
    "Qdrant not reachable at ${QDRANT_URL}" \
    "Optional. The mem0 MCP server needs it to store vectors: docker start openmemory-mem0_store-1. Override with QDRANT_URL if you run it elsewhere."
fi

# --- Summary ------------------------------------------------------------------
print_header "Summary"
if [ "$REQUIRED_FAILED" -eq 0 ] && [ "$OPTIONAL_FAILED" -eq 0 ]; then
  printf "${GREEN}All checks passed.${NC} grill-me is ready — memory operations will hit ${MEM0_MCP_URL}.\n"
  exit 0
fi

if [ "$REQUIRED_FAILED" -gt 0 ]; then
  printf "${RED}${REQUIRED_FAILED} required check(s) failed.${NC} Fix the items above before running grill-me — without Mem0 the session has nowhere to persist resolved terms and decisions.\n"
fi
if [ "$OPTIONAL_FAILED" -gt 0 ]; then
  printf "${YELLOW}${OPTIONAL_FAILED} optional check(s) had warnings.${NC} The skill will still work but some conveniences may be unavailable.\n"
fi

if [ "$REQUIRED_FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
