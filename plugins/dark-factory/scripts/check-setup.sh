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
#   - code-review (optional; the Claude peer's official Anthropic code-review
#                  skill, which $radio-review asks it to run)
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

print_header "code-review skill (optional; enables \$radio-review for the Claude peer)"
# $radio-review asks the live Claude peer to run its official Anthropic code-review
# skill. Setup runs on the Claude peer's machine, so probe the local Claude config:
# an install recorded in installed_plugins.json, a plugin cache/marketplace tree, or a
# code-review command/skill on the user- or repo-level Claude paths.
CR_PLUGINS="$HOME/.claude/plugins"
CR_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
cr_found="no"
if [ -f "$CR_PLUGINS/installed_plugins.json" ] && grep -q '"code-review@' "$CR_PLUGINS/installed_plugins.json" 2>/dev/null; then
  cr_found="yes"
elif [ -d "$CR_PLUGINS" ] && find "$CR_PLUGINS" -maxdepth 4 -type d -name code-review 2>/dev/null | grep -q .; then
  cr_found="yes"
else
  for p in \
    "$HOME/.claude/commands/code-review.md" \
    "$HOME/.claude/skills/code-review/SKILL.md" \
    ${CR_REPO:+"$CR_REPO/.claude/commands/code-review.md"} \
    ${CR_REPO:+"$CR_REPO/.claude/skills/code-review/SKILL.md"}; do
    if [ -f "$p" ]; then cr_found="yes"; break; fi
  done
fi
if [ "$cr_found" = "yes" ]; then
  pass "official Anthropic code-review skill available to the Claude peer"
else
  fail_optional "official Anthropic code-review skill not found for the Claude peer" "\$radio-review asks the Claude peer to run it. Install it: /plugin marketplace add anthropics/claude-plugins-official, then /plugin install code-review@claude-plugins-official. The rest of setup still proceeds."
fi

print_header "sandbox writability (optional; agent Bash sandboxes can block .claude/commands/)"
# Under an agent's Bash sandbox (e.g. macOS seatbelt in Claude Code), mkdir/cp into
# .claude/commands/ can be denied even though a sibling like .claude/skills/ writes
# fine - which makes the /radio command deploy fail. Probe the exact path here so
# the operator learns about it up front instead of via a FAILED line mid-apply.
# Probe non-destructively: create only what's missing, then remove exactly that.
DF_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$DF_REPO" ]; then
  DF_CMD_DIR="$DF_REPO/.claude/commands"
  DF_HAD_CLAUDE="no"; DF_HAD_CMD="no"
  [ -d "$DF_REPO/.claude" ] && DF_HAD_CLAUDE="yes"
  [ -d "$DF_CMD_DIR" ] && DF_HAD_CMD="yes"
  DF_PROBE="$DF_CMD_DIR/.df-write-probe.$$"
  if ( mkdir -p "$DF_CMD_DIR" && : > "$DF_PROBE" ) 2>/dev/null && [ -f "$DF_PROBE" ]; then
    pass ".claude/commands/ is writable ($DF_CMD_DIR)"
  else
    fail_optional ".claude/commands/ is not writable from here" "An agent Bash sandbox (macOS seatbelt) may be blocking this path while .claude/skills/ writes fine - the /radio command deploy will FAIL for it. Recover by placing .claude/commands/radio.md via an editor or Claude Code's Write tool (goes through the permission path, not the Bash sandbox), or run setup in a plain, unsandboxed terminal."
  fi
  # Clean up: remove the probe and only the dirs this check itself created.
  rm -f "$DF_PROBE" 2>/dev/null
  [ "$DF_HAD_CMD" = "no" ] && rmdir "$DF_CMD_DIR" 2>/dev/null
  [ "$DF_HAD_CLAUDE" = "no" ] && rmdir "$DF_REPO/.claude" 2>/dev/null
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
