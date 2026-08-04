---
description: Generate the UX quality ticket completion table from Linear
argument-hint: [optional date range; defaults to current Zip quarter, e.g. 2026-06-01..today]
allowed-tools: Bash(python3:*), Bash(gh:*), Read, Edit
---

Generate the UX quality ticket completion table.

## Step 1 — run the report

```
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ux_pr_table.py $ARGUMENTS
```

The script does all deterministic work and prints the finished markdown table: it resolves the
date window, pages Linear for `UX Quality` tickets in Done or Merged, reads each ticket's GitHub
attachments, batch-fetches every attached PR's author and assignees, applies the attribution rule,
and sweeps for merged PRs that never made it into the table.

Requires `LINEAR_API_KEY` in the environment and an authenticated `gh`. Runs in a few seconds and
always hits both APIs live, so there is nothing cached to go stale between runs.

Flags: `--json` for machine-readable output · `--no-sweep` to skip the gap sweep · `--since` /
`--until` instead of a `START..END` range. Pass no arguments for the current Zip fiscal quarter.

## Step 2 — judge the "possible tracking gaps" section

The script lists every in-window merged PR (designer-authored, or Z\* assigned to a designer) that
is **not** in the table. It deliberately does not classify them — that part is your call. For each,
decide whether it looks like UX-quality work, and if so name the likely cause:

- the PR title carries no Linear ticket id, so nothing ever linked
- the linked ticket is missing the `UX Quality` label
- the ticket is unassigned or assigned to someone else
- the ticket is still Todo/In Progress rather than Done/Merged
- a Z\* PR where the designer holds the Linear ticket but was never assigned on the PR itself

Report these under "possible gaps" per designer. Never fold them into the counts.

Also flag anything the script marked `(Z\*, unassigned PR)`: those counted via the ticket-assignee
fallback, and the real fix is assigning the designer on the PR.

## Step 3 — keep the roster current

`DESIGNERS` in the script maps each designer to their Linear user id and GitHub handle. Three
handles are `None` (Xande Macedo, Yumei Feng, Zack Karrasch) because they have no PRs in the repo
yet; the script names them under the table. If one has since authored a PR, resolve the handle from
it and edit the script so the entry sticks for future runs.

## The attribution rule (implemented in the script)

A ticket counts for a designer when **any** attached PR in `Greenbax/evergreen` is attributable to
them, by either path:

1. **Designer-authored** — the PR author is that designer's handle.
2. **Z\*-authored** — the author is the Z\* agent (`z-star-agent`; the `gh` CLI renders app accounts
   as `app/z-star-agent`) **and** the designer is among the PR's assignees. Z\* opens the PR on the
   designer's behalf, so the GitHub author is the agent while the Linear ticket stays assigned to
   the designer — credit follows the assignee. If a Z\* PR has no assignees at all, the Linear
   ticket's assignee stands in and the row is marked `(Z\*, unassigned PR)`.

Z\* is matched by exact login, never by a `z` prefix — `zelongjiang-byte`, `zipster-vibhav`, and
`zip-it` are real people. Only PRs in a ticket's Linear attachments count, not ones mentioned in
description text. Z\*-attributed tickets are marked `(Z\*)` in the output and totalled in a
trailing `Z\* PRs` column, so agent-assisted and hand-authored work stay distinguishable.

Reference: UX quality project https://linear.app/ziphq/project/ux-quality-9d2ed62523ef · label
`UX Quality` (id `4cfa26ce-b27c-47f4-8cae-75aeb4d35a93`).
