---
description: Generate the UX quality ticket completion table from Linear
argument-hint: [optional date range; defaults to current Zip quarter, e.g. 2026-06-01..today]
---

Generate the UX quality ticket completion table from Linear.

References: UX quality project https://linear.app/ziphq/project/ux-quality-9d2ed62523ef · label "UX Quality" (id 4cfa26ce-b27c-47f4-8cae-75aeb4d35a93).

Scope: issues carrying the "UX Quality" label that are either in a completed (Done) state OR in "Merged" status. The date window runs from the start of the CURRENT Zip fiscal quarter through today. For Done tickets, keep those with completedAt in that window. For Merged tickets (statusType is "started", completedAt is null), keep those with updatedAt on or after the quarter start. If an explicit date range is passed in $ARGUMENTS, use that instead of the quarter default.

Zip fiscal quarters (compute the start from today's month): Feb 1–Apr 30, May 1–Jul 31, Aug 1–Oct 31, Nov 1–Jan 31. So the quarter start is: month Feb/Mar/Apr → Feb 1 of this year; May/Jun/Jul → May 1; Aug/Sep/Oct → Aug 1; Nov/Dec → Nov 1 of this year; Jan → Nov 1 of the PREVIOUS year (January belongs to the Nov–Jan quarter). Determine today's date at run time and derive the start accordingly.

Count only these assignees (id → name):
cea55c77-c587-4a3b-bb62-36f5ee02cb8b Akash Talyan · 977e8100-0dd9-4e29-9b4e-b08af594e2ff Amanda Yam · 44cbd156-bf6f-4abd-96a2-29f7c02aa233 Ashley Quinn · 1226f282-f5cf-4124-9332-806a9c988e2b Chris Duxbury · bae9ccb4-9a15-4d6b-b721-191d90bd25e1 Esther Kwon · da552334-1ea7-45ff-8676-4482c59fe434 Forrest Kim · f735bb06-fc9f-43af-bcfa-660a5ad03797 Jack D'Aquila · eef733af-16fe-4472-9881-9d750333ad6f Jacob Esparza · ad596419-dd98-4922-88c3-8e40c97aebc9 Janet Peng · d83e3069-665f-4482-9d1e-8f2dd7c15872 Jenny Liu · bcc45ea5-147b-4919-ae5e-02aa178e2181 Jing Jian · f37591a1-0e6f-47ff-b3b0-f28aab4fe17a Xande Macedo · 7a9dccde-6230-4238-8249-12cec27b4b63 Ying Wong · 7bad4cb2-3af1-48cb-85c3-363a4cec3934 Yumei Feng · cee547a3-45bc-410e-9614-9b36e35ee77c Zack Karrasch.

Method: run two `list_issues` queries with label="UX Quality" (do not use an unfiltered query, it exceeds output limits): one with state="completed" and one with state="Merged". Paginate if needed. Combine both sets, filter by date + assignee, then `get_issue` per kept ticket to inspect its attachments array for GitHub PRs (url contains "github.com" and "/pull/"). Only PRs in the attachments array count, not ones referenced only in the description text.

The PR must be AUTHORED BY THE DESIGNER themselves. Check EVERY GitHub PR attached to the ticket, not just the first one: a ticket often has multiple PRs (e.g. an engineer's plus the designer's own). For each attached PR, get its author via `gh pr view <num> --repo Greenbax/evergreen --json author --jq .author.login`. The ticket counts if ANY attached PR is authored by that designer's handle below. Do not stop at the first attachment, or you will miss cases like a designer's PR sitting behind an engineer's on the same ticket.

Designer → GitHub handle:
Akash Talyan=akashtalyan1 · Amanda Yam=amandayam-zip · Ashley Quinn=ashleyquinn28 · Chris Duxbury=chrisduxbury-design · Esther Kwon=estheryjk · Forrest Kim=forrestkim2012 · Jack D'Aquila=jackdaquila · Jacob Esparza=jacobespa · Janet Peng=j-peng · Jenny Liu=jennyliu-0099 · Jing Jian=thisisJing · Xande Macedo=? · Ying Wong=yg-wong · Yumei Feng=? · Zack Karrasch=? (resolve unknown "?" handles from one of their own authored PRs at run time; Xande/Yumei/Zack have no merged PRs in the repo so far).

Always pull the latest status for every ticket at run time. Don't reuse cached results from a prior run, since statuses, labels, and PR links change between runs.

Coverage cross-check (catch tracking gaps): after building the table, for each designer list their merged PRs since the start date via `gh pr list --repo Greenbax/evergreen --author <handle> --state merged --limit 100 --json number,title,mergedAt`. Any merged PR that looks like UX-quality work but is NOT already counted signals a tracking gap, usually one of: (a) the PR title has no Linear ticket id so it never linked, (b) the linked ticket is missing the "UX Quality" label, (c) the ticket is unassigned or assigned to someone else, or (d) the ticket is still Todo/In Progress rather than Done/Merged. Report these separately as "possible gaps" per designer rather than silently dropping them; do not auto-count them.

Output: one table — Designer | Completed or Merged, with a PR they authored. Ranked descending by that count (break ties by unique PRs). List qualifying tickets as markdown links to their PR URLs.
