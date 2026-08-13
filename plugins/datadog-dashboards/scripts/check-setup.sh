#!/usr/bin/env bash
#
# Setup check for the datadog-dashboards plugin.
#
# Verifies every dependency the plugin's skills and agents reference:
#   - chart-room CLI (create/expand/iterate skills all call it)
#   - DD_API_KEY / DD_APP_KEY env vars (metric search in expand-dashboard)
#   - uvx + llm tool with a Gemini model (iterate-dashboard auto-loop)
#   - mise + Chrome (the bundled datadog-dashboard-viewer MCP runs
#     `mise x node@22 -- npx -y chrome-devtools-mcp@latest --autoConnect`)
#   - jq / curl / base64 (used by skill workflows)
#
# Exits 0 if all required checks pass, 1 otherwise. Optional checks never fail
# the script but always print remediation hints.

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

# --- chart-room CLI -----------------------------------------------------------
print_header "chart-room CLI (required)"
if command -v chart-room >/dev/null 2>&1; then
  CR_VERSION="$(chart-room --version 2>/dev/null || echo unknown)"
  pass "chart-room found at $(command -v chart-room) (v${CR_VERSION})"
else
  fail_required \
    "chart-room not on PATH" \
    "Install chart-room and ensure its bin dir is on PATH. It is the CLI used by create/expand/iterate skills (init, test, prod, status)."
  info "Verify with: command -v chart-room"
fi

# --- Datadog API credentials --------------------------------------------------
print_header "Datadog API credentials (required for expand-dashboard)"
if [ -n "${DD_API_KEY:-}" ]; then
  pass "DD_API_KEY is set"
else
  fail_required \
    "DD_API_KEY not set" \
    "export DD_API_KEY=... in your shell profile (~/.zshrc or ~/.bashrc). Get a key from Datadog: Organization Settings -> API Keys."
fi

if [ -n "${DD_APP_KEY:-}" ]; then
  pass "DD_APP_KEY is set"
else
  fail_required \
    "DD_APP_KEY not set" \
    "export DD_APP_KEY=... in your shell profile. Get an application key from Datadog: Organization Settings -> Application Keys."
fi

# --- uvx + llm + Gemini -------------------------------------------------------
print_header "uvx + llm + Gemini (required for iterate-dashboard)"
if command -v uvx >/dev/null 2>&1; then
  pass "uvx found at $(command -v uvx)"

  # llm + gemini check via uvx
  if uvx llm --version >/dev/null 2>&1; then
    pass "uvx llm runs"

    GEMINI_MODELS="$(uvx llm models 2>/dev/null | grep -i gemini || true)"
    if [ -n "$GEMINI_MODELS" ]; then
      pass "Gemini model(s) configured for uvx llm"
      printf '%s\n' "$GEMINI_MODELS" | sed 's/^/            /'

      if printf '%s' "$GEMINI_MODELS" | grep -q "gemini/gemini-2.5-flash"; then
        pass "Preferred model 'gemini/gemini-2.5-flash' available"
      else
        fail_optional \
          "Preferred model 'gemini/gemini-2.5-flash' not listed" \
          "iterate-dashboard prefers gemini-2.5-flash but will fall back to gemini-3.1-pro-preview. Install the gemini plugin: uvx llm install llm-gemini"
      fi
    else
      fail_required \
        "No Gemini models configured for uvx llm" \
        "uvx llm install llm-gemini && uvx llm keys set gemini   (paste your Google AI Studio API key from https://aistudio.google.com/apikey)"
    fi

    # SOCKS proxy + httpx[socks] compatibility check.
    # If ALL_PROXY/all_proxy points at a socks:// URL, httpx (used by llm) needs
    # the socksio extra or every llm call dies with:
    #   "Using SOCKS proxy, but the 'socksio' package is not installed."
    SOCKS_PROXY="${ALL_PROXY:-${all_proxy:-}}"
    if [ -n "$SOCKS_PROXY" ] && printf '%s' "$SOCKS_PROXY" | grep -qiE '^socks[0-9a-z]*://'; then
      if uvx llm python -c 'import socksio' >/dev/null 2>&1; then
        pass "SOCKS proxy detected and socksio is available to llm"
      else
        fail_required \
          "SOCKS proxy in ALL_PROXY ($SOCKS_PROXY) but llm's httpx lacks the socks extra" \
          "Install llm with the socks extra so httpx can use the SOCKS proxy: uv tool install llm --with 'httpx[socks]' --with llm-gemini   (or one-off: uvx --with 'httpx[socks]' llm ...). Alternatively, unset SOCKS for llm calls: ALL_PROXY= all_proxy= uvx llm ..."
      fi
    fi
  else
    fail_required \
      "uvx llm fails to run" \
      "Try: uvx llm --help. The llm tool is auto-fetched by uvx, so this usually means uvx itself is broken."
  fi
else
  fail_required \
    "uvx not on PATH" \
    "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh   (uvx ships with uv). Then restart your shell."
fi

# --- datadog-dashboard-viewer MCP --------------------------------------------
print_header "datadog-dashboard-viewer MCP (required for dashboard-browser agent)"
# The dashboard-browser agent uses the bundled `datadog-dashboard-viewer` MCP
# server, which is launched as: `mise x node@22 -- npx -y chrome-devtools-mcp@latest --autoConnect`.
# Verify the launcher dependencies are available.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MCP_CONFIG="$PLUGIN_ROOT/.mcp.json"
if [ -f "$MCP_CONFIG" ]; then
  pass ".mcp.json found at $MCP_CONFIG"
else
  fail_required \
    ".mcp.json missing at $MCP_CONFIG" \
    "The plugin should ship a .mcp.json registering the datadog-dashboard-viewer server. Reinstall the plugin or restore the file."
fi

if command -v mise >/dev/null 2>&1; then
  pass "mise found at $(command -v mise)"
else
  fail_required \
    "mise not on PATH" \
    "Install mise: curl https://mise.run | sh   (the .mcp.json launches the MCP via 'mise x node@22 -- npx ...')"
fi

if command -v npx >/dev/null 2>&1; then
  pass "npx found at $(command -v npx) (system fallback)"
else
  info "npx not on system PATH — that's OK; mise will provide it via node@22"
fi

# The MCP launches chrome-devtools-mcp with --channel=beta, so Chrome Beta
# specifically must be installed. Stable Chrome alone won't satisfy the
# launcher.
if [ -d "/Applications/Google Chrome Beta.app" ] || command -v google-chrome-beta >/dev/null 2>&1; then
  pass "Google Chrome Beta detected"
else
  fail_required \
    "Google Chrome Beta not detected" \
    "Install Chrome Beta from https://www.google.com/chrome/beta/. The MCP launches with --channel=beta and will fail against stable Chrome."
fi

# --- Shell helpers ------------------------------------------------------------
print_header "Shell helpers (required by skill workflows)"
for tool in jq curl base64; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool found at $(command -v "$tool")"
  else
    fail_required \
      "$tool not on PATH" \
      "Install via Homebrew: brew install $tool"
  fi
done

# --- Summary ------------------------------------------------------------------
print_header "Summary"
if [ "$REQUIRED_FAILED" -eq 0 ] && [ "$OPTIONAL_FAILED" -eq 0 ]; then
  printf "${GREEN}All checks passed.${NC} The datadog-dashboards plugin is ready to use.\n"
  exit 0
fi

if [ "$REQUIRED_FAILED" -gt 0 ]; then
  printf "${RED}${REQUIRED_FAILED} required check(s) failed.${NC} Fix the items above before running create/expand/iterate-dashboard.\n"
fi
if [ "$OPTIONAL_FAILED" -gt 0 ]; then
  printf "${YELLOW}${OPTIONAL_FAILED} optional check(s) had warnings.${NC} The plugin will still work but some features may be degraded.\n"
fi

if [ "$REQUIRED_FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
