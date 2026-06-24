---
name: slack-setup
description: Set up the slack-bridge plugin — capture Slack browser session tokens (xoxc/xoxd) via the bundled Chrome extension and write them to the dotfile, then validate. Use when the user asks to "set up slack-bridge", "configure slack-bridge", "connect Slack", "capture/grab Slack tokens", "my Slack tokens expired", "re-auth slack-bridge", or "/slack-setup". Run this before first use of /slack-triage, /slack-saved, or the slack-bridge MCP tools, and again whenever tokens stop working.
---

# slack-bridge setup

slack-bridge authenticates with **browser session tokens** (`xoxc` workspace token + `xoxd` `d`
cookie) — the same credentials the Slack web client uses — because Slack's internal endpoints
(`activity.feed`, `saved.list`) aren't reachable with an OAuth app token. These expire on logout /
SSO refresh, so setup is also the re-auth path.

## Steps

1. Run the guided bootstrap (it prints the exact extension-load + token-capture steps and then
   validates whatever dotfile exists):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
   ```

2. Relay its instructions to the user and help as needed. The flow:
   - Load the unpacked extension once: Chrome → `chrome://extensions` → **Developer mode** →
     **Load unpacked** → choose `${CLAUDE_PLUGIN_ROOT}/extension`.
   - On a logged-in Slack tab, click the extension → **Grab tokens** → **Copy env line**, then
     paste that line into the terminal (it writes `~/.config/slack-bridge/.env`, chmod 600).
   - If the user can't use the extension, the manual fallback (DevTools) is in the script output.

3. Re-run `setup.sh` (or `/slack-doctor`) to confirm `auth.test` passes — expect
   `OK: authenticated as <user> @ <team>`.

## Notes
- Tokens = the user's full Slack session (bypass SSO/2FA). The dotfile is chmod 600 and lives
  outside git; never echo tokens into logs or chat.
- After re-capturing expired tokens mid-session, the MCP server picks them up on its next tool
  call (the client re-reads the dotfile each call) — no restart needed.
