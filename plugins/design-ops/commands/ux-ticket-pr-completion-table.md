---
description: Generate the UX quality ticket completion table from Linear
argument-hint: [optional date range; defaults to current Zip quarter, e.g. 2026-06-01..today]
allowed-tools: Bash(python3:*), Bash(gh:*), Read, Edit, Write, ToolSearch
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

GitHub always goes through `gh`. Runs in a few seconds and always hits both APIs live, so there is
nothing cached to go stale between runs.

Flags: `--json` for machine-readable output · `--no-sweep` to skip the gap sweep · `--since` /
`--until` instead of a `START..END` range. Pass no arguments for the current Zip fiscal quarter.

**If it exits saying there is no usable Linear source**, fall through to step 1b — do not stop, and
do not ask the user for an API key before trying the MCP route.

## Step 1b — the Linear MCP fallback

Linear is reachable two ways. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ux_pr_table.py --probe` prints
which one is live: `api` (a working `LINEAR_API_KEY`, nothing more to do) or `mcp`. On `mcp`, you
fetch the issues and hand them back to the script, which still does all the attribution work:

1. **Find the Linear MCP tools.** Any Linear server works — the claude.ai connector
   (`mcp__claude_ai_Linear__*`), a plugin-provided one (`mcp__plugin_linear_linear__*`), or a
   directly-configured `mcp__linear__*`. Do not assume the exact names: call
   `ToolSearch("+linear issues")` and use whatever list/get issue tools come back. If the only tools
   exposed are `authenticate` / `complete_authentication`, the server is installed but not logged in
   — run the authenticate tool and walk the user through the OAuth flow first.
2. **Query the tickets:** issues with label `UX Quality` that are in a completed state OR in the
   `Merged` state. Page until exhausted. If the list tool omits attachments, call the get-issue tool
   per ticket to collect them — GitHub PR links live in the attachments, not the description.
3. **Write them to JSON**, then run the script against that file (add `$ARGUMENTS` if the user passed
   a range):

   ```
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ux_pr_table.py --issues-file /tmp/ux_issues.json
   ```

Field names are normalized permissively, so most MCP shapes drop straight in. Per issue, supply:

```json
[{
  "identifier": "UX-2182",
  "title": "Consolidate Payment Method Alerts",
  "url": "https://linear.app/ziphq/issue/UX-2182/...",
  "state": "Done",
  "completedAt": "2026-08-04T18:02:34.589Z",
  "updatedAt": "2026-08-04T18:02:34.589Z",
  "assignee": {"id": "d83e3069-...", "name": "Jenny Liu"},
  "attachments": [{"url": "https://github.com/Greenbax/evergreen/pull/122046"}]
}]
```

Accepted variations: a bare `{"issues": [...]}` wrapper; `state` as `{"name","type"}` or a bare
name; `assignee` as an object or a bare display name; attachments as `{"nodes":[...]}`, a list of
objects, or plain URL strings under `attachments` / `links` / `prUrls`.

**Include the assignee `id` whenever the MCP returns one.** Matching falls back to the display name
without it, and display names drift from the roster — Jing Jian is `JingZhi Jian` in Linear, which
only works because of an explicit alias. `Merged` must be spelled exactly if you pass a bare state
name, since it is the one tracked state Linear does not classify as completed.

Both routes produce a byte-identical table; only the Linear fetch differs.

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
