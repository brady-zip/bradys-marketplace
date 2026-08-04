# design-ops

Design ops commands for the UX team.

## Commands

| Command | Purpose |
|---|---|
| `/design-ops:ux-ticket-pr-completion-table [date range]` | Generates the UX Quality ticket completion table from Linear: pulls Done/Merged tickets carrying the "UX Quality" label for the current Zip fiscal quarter (or an explicit range), matches each to a GitHub PR authored by the assigned designer, and runs a coverage cross-check against each designer's merged PRs to surface tracking gaps. |
