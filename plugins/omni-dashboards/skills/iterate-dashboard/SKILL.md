---
name: iterate-dashboard
description: Refine a rendered Omni test dashboard through browser query-health checks and independent Gemini screenshot evaluation, producing an HTML report and completion ledger for user acceptance.
argument-hint: "<path/to/dashboard.omni.jsonc>"
allowed-tools: Bash(bash:*), Bash(python3:*), Bash(chart-room:*), Bash(omni:*), Bash(llm:*), Read, Write, Edit, Task, AskUserQuestion, Skill
---

# Iterate on an Omni dashboard

Read @${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-contract.md,
@${CLAUDE_PLUGIN_ROOT}/knowledge/query-evidence.md and
@${CLAUDE_PLUGIN_ROOT}/knowledge/review-artifacts.md.

## 0. Preflight — every invocation

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill iterate --brief 2>&1 || true`

Run manually if missing. Iteration includes a tiny billable Gemini smoke call via
the installed `llm` and a Chrome Beta check. Stop on BLOCKED. A deferred browser
process probe needs an actual MCP attachment check; it does not prove failure or
success. No browser means no screenshots; unavailable Gemini means no rating.
Do not substitute the author's judgment for either dependency.

After selecting the file/profile, rerun with `--skill iterate --file FILE
--profile PROFILE --require-context`. Resolve required unknown probes before the
loop. Preserve selected profile, filters, time window and timezone throughout.

## 1. Context and session

Read the full definition and intent, audience, questions and sections. Ask for
missing metadata or change direction, reusing the direction already supplied.
Validate with chart-room. Create a private durable session directory outside the
repository (for example `~/.local/share/omni-dashboards/reviews/<unique-run>`), mode
700. Use restrictive file permissions. Record CLI versions and a fresh source
snapshot for every pass. Follow the artifact reference; never commit internal
screenshots, raw exports or credentials.

Start pass counting at **1**. Use `_meta.gemini_stop_limit`, default **5**, as the
maximum number of completed Gemini evaluations. A failed query is not a completed
evaluation; allow at most two focused query-repair attempts before reporting its
owner handoff. Avoid an unbounded repair loop outside the five-pass limit.

Before any screenshot leaves the machine, follow the organization's Gemini rules
for internal dashboards and record the permitted scope. The user chose screenshot
review; do not broaden it to raw data exports. If that scope is not permitted or
not established, stop evaluation and explain the missing policy information.

## 2. Inspect the exact test dashboard through the browser agent

Read `chart-room status FILE --json --profile PROFILE` and the most recent successful
`chart-room test` result. Verify hostname `zip.omniapp.co` and the definition's test
ID. The production URL must never be used as the review target.

Invoke the Task tool with `subagent_type="omni-dashboards:dashboard-browser"` and
provide the exact URL, source hash, section inventory, active filters/time window,
1440×1000 viewport and evidence directory. Ask it to attach to the existing
authenticated Chrome Beta, inspect all visible states and capture every section.
The agent discovers tool suffixes/capabilities, not one hardcoded namespace.

If agent/tool invocation is forbidden or missing, report a failed browser phase.
A namespace-only discovery failure warrants one redispatch with the suffixes; a
second failure stops the phase. Never describe imagined rendering from source.

## 3. Query-health gate before aesthetics

Correlate browser DOM/loading/error/empty states with the real query evidence from
expansion. Scroll each section into view and wait for loading to finish. Check
filters and date defaults actually work, then restore the recorded active view.
Never infer a query failure from blank pixels alone.

Every query/sql/linked tile needs executed-query evidence, an observation timestamp
and either ready data or a verified, accepted empty state. A blank screenshot,
static field inspection, successful upload or query plan is insufficient. Failed
queries, unresolved loading and unexplained empty results stop Gemini evaluation.
Fix only the source file, validate, re-run the relevant bounded queries, publish
with `chart-room test FILE --profile PROFILE --format json`, then inspect again.
Never edit production or shared models through the UI.

Write `browser.json` from these real observations using the artifact reference.
The browser agent cannot attest API evidence it did not execute; the parent must
join the CLI evidence before setting `query_health` to PASS.

## 4. Independent Gemini evaluation

Use the bundled parser/gate so malformed output never becomes a score:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review.py" evaluate \
  --definition "path/to/dashboard.omni.jsonc" \
  --evidence "SESSION/pass-1/browser.json" --out "SESSION/pass-1/gemini" \
  --approved-screenshots
```

Use the selected installed Gemini model via `--model` if different from the default
`gemini/gemini-2.5-flash`. The helper uses `llm --no-stream --no-log`, stdin and all
section screenshots, and sends intent, audience, questions and the active view.
It asks about hierarchy, readability, information density, comparability, labeling
and question coverage. It never sends the query export. Preserve exact response,
rating, summary and suggestions; show the evaluation to the user.

On command failure or malformed rating, stop the evaluation phase immediately,
record FAILED and produce the partial report. Do not guess, round into a pass, use
a prior stale rating or supply an author score.

## 5. Apply suggestions and repeat

For every suggestion record APPLIED or DECLINED plus a reason. Decline unsupported
resources, invented measures or changes that conflict with the agreed intent.
Apply accepted changes through the `.omni.jsonc` source, not the browser editor.
Validate native configuration, rerun affected queries, and publish **test only**
through chart-room. Preserve active filters and time windows; document intentional
changes. Reinspect every section and get a new rating for the changed revision.

If the latest healthy rendered revision rates at least **7**, stop and present it.
If five passes finish below 7, report **NOT PASSED** with the exact rating sequence.
Do not make unreviewed edits after the final rating. Further passes require the
user's direction and a recorded revised limit. Data correctness remains a separate
gate regardless of the visual rating.

## 6. Acceptance, report and merge route

Present the current screenshots, query-health evidence, exact rating, unresolved
gaps and test URL for user acceptance. Record ACCEPTED, DECLINED or PENDING with
the user's response; an acceptance request is not itself acceptance. Even user
acceptance below 7 does not turn the visual gate into a pass.

Write `session.json` and run the HTML report helper described in the artifact
reference, including on a failed/partial run. It embeds screenshots, exact
ratings, applied/declined suggestions, query evidence, versions, phase outcomes
and final acceptance. Link test/prod, local definition and PR if one exists. Give
the user the report path. If reporting fails, mark FAILED and link raw artifacts.

Successful iteration ends at the merge-to-deploy route: source under domain
ownership, reviewed PR and the consuming repository's deployment workflow after
merge. Evergreen auto-deployment is a separate acceptance gate; check the consuming
repo's current runbook before claiming it is activated. Never run a direct
production upload as part of this skill. PR creation/push requires the user's
workflow scope. `chart-room comment FILE` posts to GitHub: run it only when the
invoked workflow explicitly includes posting, announce it, and link the comment.

## 7. Completion ledger — always print

| Phase | Status | Reason / evidence |
|---|---|---|
| preflight | | |
| context | | |
| browser | | |
| query-health | | |
| gemini | | |
| acceptance | | |
| report | | |
| merge-route | | |

Use DONE, SKIPPED or FAILED and a reason in every row. Gemini is DONE only for a
current healthy revision rated ≥7; below-limit failure remains FAILED. Record pass
count and every exact rating. Acceptance pending is SKIPPED with a reason, never
DONE. Restate skipped/failed phases and next actions in prose. Return complete
source/test/report links and explicit workflow/acceptance status.
