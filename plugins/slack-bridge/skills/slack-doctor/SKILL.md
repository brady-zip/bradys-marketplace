---
name: slack-doctor
description: Health-check the slack-bridge plugin — verify uv is on PATH, the token dotfile exists with correct perms, the Slack session tokens still authenticate (auth.test), and report the saved-decisions store. Use when the user asks to "check slack-bridge", "slack-bridge doctor", "is slack-bridge working", "diagnose Slack", "why is slack-bridge failing", "are my Slack tokens still good", or "/slack-doctor".
---

# slack-bridge doctor

Diagnose slack-bridge end to end and tell the user exactly what (if anything) to fix.

## Steps

1. Run the setup checker (covers uv, python3, the dotfile + perms, and a live `auth.test`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh"
   ```

2. Report the durable decision store (counts + active snoozes):
   ```bash
   uv run "${CLAUDE_PLUGIN_ROOT}/server/decisions.py"
   ```

3. Summarize for the user: PASS/FAIL per area and the specific remediation for any failure.
   Common ones:
   - **uv not found** → install uv, or set an absolute path in `.mcp.json` (the checker prints it).
   - **no dotfile / tokens missing** → run `/slack-setup`.
   - **`auth.test` fails (`invalid_auth`/`token_expired`)** → tokens expired on SSO refresh;
     re-capture via `/slack-setup`.

## Optional deeper check
If the user suspects the MCP server itself won't start (vs. just tokens), confirm the launch path
resolves dependencies:
```bash
uv run "${CLAUDE_PLUGIN_ROOT}/server/server.py" --help 2>&1 | head -1 || true
```
(The server is a stdio process; a clean start with no traceback means `uv` resolved `mcp` and the
imports are intact. For a full tool-list handshake, that's beyond a quick doctor run.)
