---
description: Show which mem0 scopes a directory resolves to (app_id / agent_id / recall / user_id) and which config layer decided each
argument-hint: "[path]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/scopes.sh:*)
---

Show how a directory resolves to mem0 scopes, and **why**.

Memory is one store sliced by four scopes: `user_id` (whose store), `app_id` (what the
work is about), `agent_id` (which agent wrote it), and `run_id` (which workstream thread).
`app_id` and `agent_id` resolve through four layers — an agent's launch environment, a
`.mem0-brady.json` at or above the session cwd, this machine's `MEM0_SCOPE_RULES`, then the
plugin default `general`. That is one layer more than anyone can hold in their head while
working out why a memory landed somewhere unexpected, so this prints the value and the
deciding layer together.

It then inventories the store, because the expensive mistake with partitions is not
picking a bad name — it is picking one a character off an existing name. Nothing errors:
the write just starts a fresh partition, and every memory in the old one silently stops
reaching recall. Each `app_id` this machine can resolve to is listed with how many
memories it already holds, and empty ones are flagged as new.

Read-only. It resolves config and counts memories; it writes nothing.

Execute (pass `$ARGUMENTS` as the path when the user named one, else omit for the cwd):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/scopes.sh $ARGUMENTS
```

Summarize for the user. Call out specifically:

- an `app_id` about to receive writes that holds **0 memories** — either a deliberate new
  partition or a typo, and the two look identical from here
- a resolution coming from `plugin default` when the user expected a repo or machine rule,
  which usually means `MEM0_SCOPE_RULES` is unquoted in `~/.config/mem0-brady/.env` (the
  file is `source`d, so an unquoted `;` ends the assignment and an unquoted `*` globs)
- `recall` narrower than the user expects — widen it per-repo with `recall_app_ids` in
  `.mem0-brady.json`

If the store inventory is skipped, the MCP server is unreachable; the resolution shown is
still correct, since it comes from local config alone. Run `/mem0-brady:doctor` for that.
