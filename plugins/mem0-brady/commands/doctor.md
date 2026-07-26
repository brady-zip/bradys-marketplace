---
description: Health-check the mem0-brady stack — toolchain, config, launchd agents, MCP server, and native Qdrant server
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh)
---

Run the mem0-brady health check and report the results. Every endpoint and name it
checks comes from this install's `~/.config/mem0-brady/.env`, so a machine pointed at its
own store is checked against *its* values, not defaults baked into the plugin.

It verifies macOS, `uv` + the fork's console scripts on PATH, the config file and its
key, the stack mode and store identity, that Qdrant answers and holds a collection whose
vector size matches `MEM0_EMBED_DIMS`, that the MCP server answers, and (optionally) the
workstream dirs + any active workstream tags.

Under the **managed** stack it also checks the native Qdrant binary, both launchd agents
(`com.mem0brady.qdrant`, `com.mem0brady.server`), the storage dir, the API key, the
collection's vector size and the reranker. Under **external** all of those are skipped —
the server owns them and the host never contacts Qdrant — leaving the MCP server as the
one thing that must answer. It still warns if a leftover managed agent is loaded, since
that would quietly serve a different store than your config names.

Execute:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh
```

If any required check fails, the usual fix is to run `/mem0-brady:setup`. Summarize the
output for the user and call out the specific remediation for any failures.
