# Mem0 Memory Format

This skill stores two kinds of memory: **glossary terms** and **decisions**.
Both go to Mem0 via `add_memory`. Mem0 ingests natural-language statements and
extracts the salient facts, so write each memory as one or two clean sentences —
not as JSON or a doc fragment.

To keep memories scoped and retrievable, prefix every memory with the project
key (the repo directory name by default) and a category tag.

## Glossary term

One memory per term. State what the term **is** (not what it does), pick the one
canonical word when several compete, and name the words to avoid.

```
[<project-key>][glossary] "Order" is a confirmed customer request to purchase one or more items. Canonical term — avoid "purchase", "transaction".
```

```
[<project-key>][glossary] "Customer" is a person or organization that places orders. Avoid "client", "buyer", "account" (an account is a User login, which is different).
```

Rules:

- **Be opinionated.** When multiple words mean the same thing, pick one and list
  the rest as words to avoid.
- **Keep it tight.** One or two sentences. Define what it IS.
- **Only project-specific terms.** General programming concepts (timeouts, retry
  patterns, utility helpers) don't belong even if used heavily. Ask: is this a
  concept unique to this project's domain, or general programming? Only the
  former.

## Decision

One memory per decision. Capture *that* a decision was made and *why* — context,
the choice, and the reason in one to three sentences.

```
[<project-key>][decision] The write model is event-sourced and the read model is projected into Postgres, chosen over a single CRUD store so the audit trail is the source of truth. Hard to reverse once events accumulate.
```

```
[<project-key>][decision] Ordering and Billing communicate via domain events, not synchronous HTTP, to keep them independently deployable. Rejected sync calls because a Billing outage must not block order placement.
```

Only record a decision when all three hold: hard to reverse, surprising without
context, and the result of a real trade-off. If a decision is easy to reverse,
unsurprising, or had no real alternative, don't store it.

## Updating vs duplicating

Before adding, `search_memories` for the term or decision. If a close match
exists:

- **Refined wording, same meaning** — skip; the existing memory is fine.
- **Changed meaning** — store the corrected statement and explicitly note it
  supersedes the old understanding (e.g. start with `Correction:`), and delete
  the stale memory if the available tools allow it. Never leave two memories
  that contradict each other.

## Scoping note

Scoping has two levels:

1. **`app_id` (domain) — a hard filter, set on every call.** Mem0 is partitioned
   into `evergreen` (evergreen-repo work), `general` (Claude tooling /
   customizations / everything else), and `hal-ops` (Hal's ops). A Claude
   grill-me session uses `evergreen` or `general`, per the SessionStart steer.
   Pass it as `app_id` on `add_memory` and as the `app_id` filter on
   `search_memories` / `get_memories`. This is enforced — a write without
   `app_id` is rejected.

2. **`<project-key>` text prefix — a soft cluster within a domain.** The prefix
   is how multiple projects coexist inside one domain — the equivalent of the
   original skill's single-`CONTEXT.md`-vs-`CONTEXT-MAP.md` split. For a repo with
   multiple bounded contexts, extend the tag, e.g. `[<project-key>/ordering][glossary]`,
   so semantic search can narrow further. (`app_id` is the coarse, filterable
   domain; the text prefix is the fine, semantic cluster.)
