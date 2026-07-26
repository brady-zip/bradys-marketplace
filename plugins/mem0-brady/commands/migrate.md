---
description: Move a mem0-brady memory store between stacks — export from one machine, import into another, with the namespace rewritten
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh:*)
---

Move memories from one mem0-brady store into another. The usual reason: a machine ran
the **managed** stack (native Qdrant, its own collection and `user_id`) and you want its
memories in a shared **external** stack so there is only one store left to maintain.

Vectors move **verbatim** — nothing is re-embedded, so there is no OpenAI spend and no
chance of mem0's fact-extractor rewording a memory in transit. The source is never
modified and never deleted.

## Before anything: look at both stores

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh inspect --qdrant <URL> --collection <NAME>
```

Prints every collection with its point count and vector size, then the `user_id`
namespaces and `app_id` domains inside the named collection. Run it on **both** machines
and confirm the vector sizes match — two stores built on different embedding models
cannot be merged, and the import will refuse.

## Export (on the machine you are leaving)

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh export ~/mem0-export.jsonl \
    --qdrant http://127.0.0.1:6433 --collection mem0_brady --user-id shared-bch
```

Defaults come from that machine's `~/.config/mem0-brady/.env`, so the flags are only
needed when they differ. `--user-id` filters which namespace is taken; omit it to export
everything. The derived `<collection>_entities` sibling is included automatically.

Copy the resulting file to the other machine by any means you already trust — it is a
plain JSONL file, and this is deliberately not a network protocol, because the two
Qdrants are normally each bound to their own loopback.

## Import (on the machine you are keeping)

Always dry-run first:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh import ~/mem0-export.jsonl \
    --qdrant http://127.0.0.1:6333 --collection agent_memory --user-id brady --dry-run
```

Then drop `--dry-run`. `--user-id` here is the namespace **every imported memory is
rewritten to**, which is what merges the old machine's memories into the store the rest
of your setup already reads.

Import is safe to repeat: point ids are preserved and memories are deduped by their
content hash, so a re-run skips what is already there and a partial run can simply be
run again. Derived entity points carry no hash and are re-upserted under their original
ids — overwrites, not duplicates; the summary reports them separately so a second run
doesn't look like it imported new things.

## After

Verify with `inspect` on the target, then point the migrated machine at the surviving
store by re-running `/mem0-brady:setup` there and choosing the `external` stack (or
editing `MEM0_QDRANT_URL` / `MEM0_COLLECTION` / `MEM0_USER_ID` directly — setup merges
the config rather than overwriting it, so hand-edits survive).

Report to the user: how many memories moved, how many were skipped as already present,
and the resulting counts on both sides. If the vector sizes disagreed or the target
collection was missing, say exactly which and what the script did about it.
