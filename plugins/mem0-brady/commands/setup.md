---
description: One-time setup for mem0-brady — installs the Mem0 fork, writes the config, and stands up (or points at) the MCP server
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh)
---

Run the mem0-brady installer. On a first run it asks which stack backs this install and
what store it should point at; on every later run it reads those answers back out of
`~/.config/mem0-brady/.env` and stays silent.

Always: install `uv` if missing, `uv tool install` the patched self-hosted Mem0 fork, and
**merge** `~/.config/mem0-brady/.env` — existing values, comments and unknown keys are
preserved; only genuinely new keys are added. A hand-tuned config survives an upgrade.

**`managed`** (default) additionally installs mem0 and its models, the native Qdrant
server binary, and two launchd agents — Qdrant and the MCP server — on ports from your
config (default `6433`/`8788`). It reuses or prompts for your OpenAI API key. No Docker.

**`external`** installs none of that, and no mem0 either: the hooks drive mem0 *through*
your MCP server, so the host needs no Qdrant reachability, no API key and no store
identity — the server owns all of it. The config comes out at two lines and the tool
install at ~70MB rather than multiple GB. Setup verifies the MCP server answers, and
refuses to proceed if this machine still holds managed-stack data that would be
stranded, pointing at `/mem0-brady:migrate`.

For a managed stack, store identity — collection, `user_id`, URLs — is per-install, never
baked into the plugin. Two machines pointed at the same values share one memory.

If no key is already present, the prompt reads from your terminal (hidden input), so a
first-time run must be interactive. `MEM0_BRADY_NONINTERACTIVE=1` takes every default
instead, for provisioning scripts.

Execute:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh
```

After it finishes, relay the `claude mcp add ... --scope user` line it prints (the
canonical `mcp__mem0__*` namespace the hooks match on comes from that user-level
registration, not from the plugin), tell the user to **restart their Claude Code
session** so the MCP server and the SessionStart/Stop hooks attach, then run
`/mem0-brady:doctor`.

Finally, share this closing note with the user (verbatim):

> 🎉 Thanks for downloading **mem0-brady**! This is a work in progress — feel free to
> extend it or build new skills/tools on top of it. If you make something useful, open a PR!
