#!/usr/bin/env bash
#
# Guided token bootstrap for the slack-bridge plugin.
#
# slack-bridge authenticates to Slack with browser SESSION tokens (xoxc + xoxd) — the same
# credentials the Slack web client uses — because Slack's internal endpoints (activity.feed,
# saved.*) are not reachable with an OAuth app token. This script walks you through capturing
# them with the bundled Chrome extension and writing them to the dotfile, then validates.

set -u

BOLD='\033[1m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DOTFILE="${SLACK_BRIDGE_DOTFILE:-$HOME/.config/slack-bridge/.env}"
EXT_DIR="$PLUGIN_ROOT/extension"

mkdir -p "$(dirname "$DOTFILE")"

printf "${BOLD}slack-bridge token setup${NC}\n"
printf '%s\n' "------------------------------------------------------------"
printf "Tokens go in: %s\n\n" "$DOTFILE"

printf "${BOLD}1.${NC} Load the token-grabber Chrome extension (one-time):\n"
printf "   • Chrome → ${BLUE}chrome://extensions${NC} → toggle ${BOLD}Developer mode${NC} (top-right)\n"
printf "   • Click ${BOLD}Load unpacked${NC} → choose:\n       %s\n\n" "$EXT_DIR"

printf "${BOLD}2.${NC} Capture your tokens:\n"
printf "   • Open a logged-in Slack tab (e.g. ${BLUE}app.slack.com${NC})\n"
printf "   • Click the extension → ${BOLD}Grab tokens from current Slack tab${NC}\n"
printf "   • Click ${BOLD}Copy env line${NC}, then paste it into your terminal and run it.\n"
printf "     (It writes %s and chmod 600s it.)\n\n" "$DOTFILE"

printf "   Manual fallback (DevTools on the Slack tab):\n"
printf "   • xoxc: Console → ${BLUE}JSON.parse(localStorage.localConfig_v2).teams${NC} → a team's .token\n"
printf "   • xoxd: Application → Cookies → app.slack.com → the ${BLUE}d${NC} cookie value (send raw)\n\n"

if [ -f "$DOTFILE" ]; then
  printf "${GREEN}Found an existing dotfile.${NC} Validating it now…\n"
else
  printf "Once you've written the dotfile, re-run this script (or check-setup.sh) to validate.\n"
fi

printf '\n%s\n' "------------------------------------------------------------"
exec bash "$PLUGIN_ROOT/scripts/check-setup.sh"
