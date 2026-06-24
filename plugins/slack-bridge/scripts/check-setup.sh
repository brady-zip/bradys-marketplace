#!/usr/bin/env bash
#
# Setup check for the slack-bridge plugin.
#
# Verifies everything the MCP server and the /slack-triage skill need:
#   - uv (the .mcp.json launches the server via `uv run server/server.py`)
#   - python3 (uv provides the interpreter; this is an extra sanity check)
#   - the token dotfile (~/.config/slack-bridge/.env) present + chmod 600
#   - the tokens actually authenticate (auth.test via slack_client.py)
#
# Exits 0 if all required checks pass, 1 otherwise.

set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

REQUIRED_FAILED=0
OPTIONAL_FAILED=0

print_header() {
  printf "\n${BOLD}%s${NC}\n" "$1"
  printf '%s\n' "------------------------------------------------------------"
}
pass()          { printf "  ${GREEN}OK${NC}      %s\n" "$1"; }
fail_required() {
  printf "  ${RED}MISSING${NC} %s\n" "$1"
  REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
  [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"
}
fail_optional() {
  printf "  ${YELLOW}WARN${NC}    %s\n" "$1"
  OPTIONAL_FAILED=$((OPTIONAL_FAILED + 1))
  [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"
}
info() { printf "          %s\n" "$1"; }

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DOTFILE="${SLACK_BRIDGE_DOTFILE:-$HOME/.config/slack-bridge/.env}"

# --- uv -----------------------------------------------------------------------
print_header "uv (required — launches the MCP server)"
if command -v uv >/dev/null 2>&1; then
  pass "uv found at $(command -v uv) ($(uv --version 2>/dev/null))"
else
  fail_required \
    "uv not on PATH" \
    "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh   (then restart your shell). If uv is installed but Claude Code can't see it on launch, set an absolute path in .mcp.json, e.g. \"command\": \"$HOME/.local/bin/uv\"."
fi

# --- python3 ------------------------------------------------------------------
print_header "python3 (sanity check)"
if command -v python3 >/dev/null 2>&1; then
  pass "python3 found at $(command -v python3) ($(python3 --version 2>&1))"
else
  fail_optional "python3 not on PATH" "uv ships its own interpreter, so this is non-fatal, but install python3 if you want to run scripts directly."
fi

# --- token dotfile ------------------------------------------------------------
print_header "Slack session tokens (required)"
if [ -f "$DOTFILE" ]; then
  pass "dotfile found at $DOTFILE"
  PERMS="$(stat -f '%Lp' "$DOTFILE" 2>/dev/null || stat -c '%a' "$DOTFILE" 2>/dev/null)"
  if [ "$PERMS" = "600" ]; then
    pass "dotfile permissions are 600"
  else
    fail_optional "dotfile permissions are $PERMS (expected 600)" "chmod 600 $DOTFILE"
  fi
  if grep -q '^SLACK_XOXC=' "$DOTFILE" && grep -q '^SLACK_XOXD=' "$DOTFILE"; then
    pass "SLACK_XOXC and SLACK_XOXD present"
  else
    fail_required "SLACK_XOXC / SLACK_XOXD missing from dotfile" "Re-capture via the Chrome extension (see scripts/setup.sh)."
  fi
else
  fail_required \
    "no token dotfile at $DOTFILE" \
    "Run: bash \"$PLUGIN_ROOT/scripts/setup.sh\"  (loads the Chrome extension and writes the dotfile)."
fi

# --- live auth.test -----------------------------------------------------------
print_header "Token validity (auth.test)"
if command -v uv >/dev/null 2>&1 && [ -f "$DOTFILE" ]; then
  if AUTH_OUT="$(SLACK_BRIDGE_DOTFILE="$DOTFILE" uv run "$PLUGIN_ROOT/server/slack_client.py" 2>&1)"; then
    pass "$AUTH_OUT"
  else
    fail_required "tokens did not authenticate" "$AUTH_OUT"
    info "Session tokens expire on SSO refresh — re-capture via the Chrome extension."
  fi
else
  info "Skipped (needs uv + a dotfile)."
fi

# --- Summary ------------------------------------------------------------------
print_header "Summary"
if [ "$REQUIRED_FAILED" -eq 0 ] && [ "$OPTIONAL_FAILED" -eq 0 ]; then
  printf "${GREEN}All checks passed.${NC} slack-bridge is ready (MCP tools + /slack-triage).\n"
  exit 0
fi
if [ "$REQUIRED_FAILED" -gt 0 ]; then
  printf "${RED}${REQUIRED_FAILED} required check(s) failed.${NC} Fix the items above.\n"
fi
if [ "$OPTIONAL_FAILED" -gt 0 ]; then
  printf "${YELLOW}${OPTIONAL_FAILED} optional check(s) had warnings.${NC}\n"
fi
[ "$REQUIRED_FAILED" -gt 0 ] && exit 1
exit 0
