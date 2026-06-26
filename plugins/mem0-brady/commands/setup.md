---
description: One-time setup for mem0-brady — installs the Mem0 fork, captures your OpenAI key, and starts the local MCP server
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh)
---

Run the mem0-brady installer. It will: install `uv` if missing, `uv tool install` the
patched self-hosted Mem0 fork, reuse (or prompt for) your OpenAI API key (used for both
the LLM and embeddings), write `~/.config/mem0-brady/.env`, install the native Qdrant
server binary, and install + load two launchd agents — a native Qdrant server on
`127.0.0.1:6433` and the MCP server on `127.0.0.1:8788` pointed at it. No Docker.

If no key is already present, the prompt reads from your terminal (hidden input), so a
first-time run must be interactive.

Execute:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh
```

After it finishes, tell the user to **restart their Claude Code session** so the
`.mcp.json` server and the SessionStart/Stop hooks attach, then run `/mem0-brady:doctor`.

Finally, share this closing note with the user (verbatim):

> 🎉 Thanks for downloading **mem0-brady**! This is a work in progress — feel free to
> extend it or build new skills/tools on top of it. If you make something useful, open a PR!
