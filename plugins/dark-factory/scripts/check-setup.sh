#!/usr/bin/env bash
#
# Preflight/doctor for the dark-factory plugin's setup.
#
# Verifies the prerequisites the radio pattern, the Codex SessionStart adapter,
# and GSD (get-shit-done core) provisioning depend on:
#   - git        (lock state + repo-scoped deploy live under .git / repo root)
#   - h5i CLI    (the radio transport + `h5i init` / `h5i hook codex prelude`)
#   - node       (runs the Codex SessionStart adapter, a .cjs file)
#   - jq         (setup.sh merges .claude/settings.json + .codex/hooks.json with jq)
#   - npx        (optional; provisions GSD from its pinned npm package)
#
# Exits 0 if all required checks pass, 1 otherwise. Optional checks warn only.

set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REQUIRED_FAILED=0
OPTIONAL_FAILED=0

print_header() { printf "\n${BOLD}%s${NC}\n" "$1"; printf '%s\n' "------------------------------------------------------------"; }
pass()          { printf "  ${GREEN}OK${NC}      %s\n" "$1"; }
fail_required() { printf "  ${RED}MISSING${NC} %s\n" "$1"; REQUIRED_FAILED=$((REQUIRED_FAILED + 1)); [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"; }
fail_optional() { printf "  ${YELLOW}WARN${NC}    %s\n" "$1"; OPTIONAL_FAILED=$((OPTIONAL_FAILED + 1)); [ -n "${2:-}" ] && printf "          ${BLUE}Fix:${NC} %s\n" "$2"; }

print_header "git (required)"
if command -v git >/dev/null 2>&1; then
  pass "git found at $(command -v git)"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    pass "inside a git work tree ($(git rev-parse --show-toplevel))"
  else
    fail_required "not inside a git repository" "cd into the repo you want to set up, then re-run. Radio state lives under .git and assets deploy to the repo root."
  fi
else
  fail_required "git not on PATH" "Install git (e.g. brew install git)."
fi

print_header "h5i CLI (required)"
if command -v h5i >/dev/null 2>&1; then
  H5I_VER="$(h5i --version 2>/dev/null || echo unknown)"
  pass "h5i found at $(command -v h5i) (${H5I_VER})"
else
  fail_required "h5i not on PATH" "Install h5i (auditable workspaces for AI agents) and ensure its bin dir is on PATH. See https://h5i.dev/. It is the radio transport (h5i msg) and provides h5i init / h5i hook codex prelude."
fi

print_header "node (required for the Codex SessionStart adapter)"
if command -v node >/dev/null 2>&1; then
  pass "node found at $(command -v node) ($(node --version 2>/dev/null))"
else
  fail_required "node not on PATH" "Install Node.js. The Codex prelude adapter (.codex/hooks/dark-factory-codex-session-start.cjs) runs under node."
fi

print_header "jq (required for settings.json merge)"
if command -v jq >/dev/null 2>&1; then
  pass "jq found at $(command -v jq)"
else
  fail_required "jq not on PATH" "Install jq (brew install jq). setup.sh uses it to merge .claude/settings.json and .codex/hooks.json without clobbering other keys."
fi

print_header "npx (optional; for GSD provisioning)"
if command -v npx >/dev/null 2>&1; then
  pass "npx found at $(command -v npx)"
else
  fail_optional "npx not on PATH" "GSD (get-shit-done core) is provisioned via npx from a pinned npm package. Without npx, run setup with --skip-gsd (or install Node.js) — the rest of setup still proceeds."
fi

print_header "Summary"
if [ "$REQUIRED_FAILED" -eq 0 ] && [ "$OPTIONAL_FAILED" -eq 0 ]; then
  printf "${GREEN}All checks passed.${NC} dark-factory setup can proceed.\n"
  exit 0
fi
[ "$REQUIRED_FAILED" -gt 0 ] && printf "${RED}%s required check(s) failed.${NC} Fix them before running setup.\n" "$REQUIRED_FAILED"
[ "$OPTIONAL_FAILED" -gt 0 ] && printf "${YELLOW}%s optional check(s) warned.${NC}\n" "$OPTIONAL_FAILED"
[ "$REQUIRED_FAILED" -gt 0 ] && exit 1
exit 0
