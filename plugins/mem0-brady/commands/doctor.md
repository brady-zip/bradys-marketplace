---
description: Health-check the mem0-brady stack — toolchain, config, launchd agents, MCP server, and native Qdrant server
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh)
---

Run the mem0-brady health check and report the results. It verifies macOS, `uv` + the
fork's console scripts on PATH, the config file (`~/.config/mem0-brady/.env`) and its key,
the launchd agents (`com.mem0brady.qdrant`, `com.mem0brady.server`), the native Qdrant
server on `:6433`, and the MCP server on `:8788`.

Execute:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh
```

If any required check fails, the usual fix is to run `/mem0-brady:setup`. Summarize the
output for the user and call out the specific remediation for any failures.
