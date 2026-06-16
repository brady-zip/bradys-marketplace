---
description: One-time setup for mem0-brady — installs the Mem0 fork, captures your keys, asks which embedding/reranking provider to use, and starts the local MCP server
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh)
---

Run the mem0-brady installer. It will: install `uv` if missing, `uv tool install` the
patched self-hosted Mem0 fork, reuse (or prompt for) your OpenAI API key (the LLM that
extracts facts is always OpenAI), **ask which provider should do embeddings + reranking —
`openai` (default) or `zeroentropy`** (prompting for a ZeroEntropy key in that case), write
`~/.config/mem0-brady/.env`, install the native Qdrant server binary, and install + load two
launchd agents — a native Qdrant server on `127.0.0.1:6433` and the MCP server on
`127.0.0.1:8788` pointed at it. No Docker.

If no keys/provider are already present, the prompts read from your terminal (hidden input
for keys), so a first-time run must be interactive. Re-runs reuse the existing provider and
keys from `~/.config/mem0-brady/.env`.

Execute:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh
```

After it finishes, tell the user to **restart their Claude Code session** so the
`.mcp.json` server and the SessionStart/Stop hooks attach, then run `/mem0-brady:doctor`.
