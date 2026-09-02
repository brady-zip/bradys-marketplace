---
name: expand-dashboard
description: Use when user wants to add new metrics, widgets, or sections to an existing Datadog dashboard
argument-hint: "<path-to.dash.json>"
allowed-tools: Bash(bash:*), Bash(chart-room:*), Bash(curl:*), Bash(jq:*), Bash(gh:*), Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill
---

# Expanding a Datadog Dashboard

Add new metrics and content to an existing dashboard: find the gap, instrument the code, test emission, PR the changes, then iterate visually.

## Overview

**Metrics before visuals.** Adding widgets to a dashboard is pointless if the metrics don't exist or aren't emitting correctly. This skill ensures metrics are instrumented, tested, and PR'd before touching the dashboard JSON.

**The argument is the path to the .dash.json file.** If no argument was provided, ask the user which .dash.json file to expand.

## Prerequisites

- An existing `.dash.json` file with `_meta.intent` and `_meta.audience`
- The dashboard must be initialized in Datadog (`chart-room status <file>`)

## Workflow

```
Preflight → Read _meta → Gap analysis → Instrument code → Test emission → PR metrics → Update .dash.json → Iterate visuals → Ledger
```

**CRITICAL: Read `_meta.intent`, `_meta.audience`, and `_meta.scope` from the .dash.json BEFORE starting. The intent defines what metrics matter. The audience defines how they should be presented. The scope identifies which services and integrations are available.**

## Phase 0: Preflight — MANDATORY, EVERY INVOCATION

**This runs automatically, before Phase 1, on every single invocation — including when `create-dashboard` just handed off to you. The handoff is not a substitute: the machine can change between phases, and `create`'s preflight ran with `--skill create`, which treats the Datadog credentials this skill needs as deferred rather than blocking.**

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill expand --brief 2>&1 || true`

**The block above already ran.** It is an inline bash block, so Claude Code executed it the moment this skill was invoked — its output is in your context right now, above this line. You do not run it again, and there is no path through this skill where it did not run. That is the point: the check no longer depends on anyone remembering to perform it.

If you see no preflight output above, the injection failed. Run it manually and treat the result exactly the same way:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill expand --brief
```

`--brief` keeps a healthy machine down to two lines. It does **not** hide problems: on anything other than a clean pass the full repaired / deferred / `USER ACTION REQUIRED` blocks are printed inline, and the complete report is written to a log file whose path comes back as `PREFLIGHT_LOG:`. Drop `--brief` (or `cat` that log) when a check itself is misbehaving.

Act on the machine-readable tail:

- **`PREFLIGHT_STATUS: OK`** → say so in one line, proceed to Phase 1.
- **`PREFLIGHT_STATUS: REPAIRED`** → **tell the user exactly what was installed on their machine**, then proceed.
- **`PREFLIGHT_STATUS: BLOCKED`** → **STOP.** Show the user the `USER ACTION REQUIRED` block verbatim. Do not start the gap analysis.

This skill's hard dependencies are `DD_API_KEY` / `DD_APP_KEY` (the metric search in Phase 1 is meaningless without them) and `chart-room` (Phase 5 uploads through it). The preflight validates the Datadog keys with a live call rather than just checking they are set — a revoked key that is still exported produces empty metric searches that read exactly like "this metric does not exist", which sends the whole gap analysis down the wrong path.

If `PREFLIGHT_DEFERRED > 0`, tell the user now which dependency `iterate-dashboard` will hit at the Phase 6 handoff.

**Never substitute your own judgement for a missing dependency.** Do not guess whether a metric exists because the search is unavailable.

Full rationale: @${CLAUDE_PLUGIN_ROOT}/knowledge/preflight-contract.md

## Phase 1: Gap Analysis

1. **Read the .dash.json** — load the full file, understand current widgets and metrics
2. **Read `_meta`** — intent (what questions to answer), audience (who's looking), scope (services, integrations, tags)
3. **Identify the gap** — ask the user what's missing. Use AskUserQuestion:
   - What new questions should the dashboard answer?
   - What behavior or system is under-observed?
4. **Determine required metrics** — for each gap, identify:
   - Does the metric already exist in Datadog? (Search using the script below)
   - If not, what code needs to emit it?
   - What tags are needed for filtering/grouping?

Present the gap analysis to the user for confirmation before proceeding.

### Searching Datadog Metrics

Use the Datadog API directly to check if a metric exists. Requires `DD_API_KEY` and `DD_APP_KEY` environment variables:

```bash
# Search for metrics matching a query string
curl -s -G "https://api.datadoghq.com/api/v1/search" \
  --data-urlencode "q=metrics:${QUERY}" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" | jq '.results.metrics'
```

Replace `${QUERY}` with the metric name or prefix (e.g. `aws.elb`, `trace.servlet.request`). The search supports partial matching.

If `DD_API_KEY` or `DD_APP_KEY` are not set, ask the user to provide them or set them in their shell profile.

## Phase 2: Instrument Code

If new metrics need to be emitted:

1. **Find the right code location** — where does the behavior being measured happen?
2. **Add instrumentation** — emit custom metrics, add trace tags, or configure log-based metrics
3. **Keep changes focused** — the PR should contain ONLY metric instrumentation, no feature work

## Phase 3: Test Metric Emission

Verify metrics are emitting correctly before merging:

**Frontend only metrics (browser/RUM):**

- If metrics are emitted by the frontend app only, tell the user: "Exercise the functionality using the sandbox deploy link on your PR"

**Backend metrics (APM/custom):**

- If metrics require backend code changes, the user will need to create a QA deploy to test them:
- Direct the user to create a next deploy using the `next-preview:qa` github label
- Tell the user "Exercise the functionality after the feature deploys to the QA next environment"

**CI/Pipeline testing (if `pipeline` CLI is available):**

- If testing metrics that are emitted during CI/CD job, if the user has the `pipeline` CLI available, they can run tests directly:
- Use `pipeline enable` to test any CI jobs that validate metric emission
- Run `pipeline skill` for the full workflow

### Verify the metrics

- After the user confirms they have exercised the feature, verify metrics appear using the search script above

## Phase 4: PR for Metric Changes

Create a PR containing ONLY the metric instrumentation changes:

- Separate from any dashboard JSON changes
- Clear description of what metrics are being added and why
- Reference the dashboard and `_meta.intent`

## Phase 5: Update Dashboard JSON

Once metrics are confirmed emitting:

1. **Add new widgets** to the .dash.json for the new metrics
2. **Choose widget types** — refer to @${CLAUDE_PLUGIN_ROOT}/knowledge/widget-selection-guide.md
   - **If any query is a RUM event query, read @${CLAUDE_PLUGIN_ROOT}/knowledge/rum-widget-landmines.md first.** Several RUM constructs upload without complaint and then fail at render, `timeshift()` silently. Getting these wrong costs an upload → screenshot → diagnose cycle each.
3. **Use correct query format** — refer to @${CLAUDE_PLUGIN_ROOT}/knowledge/dashboard-json-reference.md
4. **Place widgets** in the appropriate group/section, or create new groups if needed
5. **Upload** with `chart-room test <file>`

## Phase 6: Handoff to Iterate — REQUIRED, NOT OPTIONAL

1. **State the handoff** — tell the user you are moving from `expand-dashboard` to `iterate-dashboard`, and on which file.
2. **Invoke the `iterate-dashboard` skill** with the `.dash.json` path as its argument. Actually invoke it — do not describe what it would do and stop.

Widgets that have never been looked at are widgets nobody has confirmed render. **The only way to skip this phase is if the user explicitly says to stop** — record that as `SKIPPED` in the ledger with their reason. Running out of context, hitting an unrelated error, or judging it unnecessary are **not** reasons to skip it; mark it `FAILED` with the reason and say so.

## Phase 7: Completion Ledger — ALWAYS PRINT

Before you finish, print this table. Fill `Status` with `DONE`, `SKIPPED`, or `FAILED`, checked against what you **actually did**.

```
| Phase | Status | Notes |
|---|---|---|
| 0. Preflight            |  | |
| 1. Gap analysis         |  | |
| 2. Instrument code      |  | |
| 3. Test metric emission |  | |
| 4. PR metric changes    |  | |
| 5. Update dashboard JSON |  | |
| 6. Handoff to iterate   |  | |
```

Phases 2–4 are legitimately `SKIPPED` when the gap needs no new metrics — say so in Notes ("all required metrics already emitting"). That is a real answer; an empty row is not.

**Every `SKIPPED` or `FAILED` row must carry a reason and must also be restated in prose below the table**, with what the user should do about it.

## Guidelines

- **Preflight runs every invocation** — even on handoff from `create-dashboard`, and its result goes to the user
- **Verify metrics exist in Datadog before adding widgets that reference them**
- **Never silently skip or degrade** — a skipped phase, a failed dependency, or a substituted approach is reported the moment it happens; print the Phase 7 ledger regardless
- **Metrics PR first, dashboard changes second** — never merge dashboard widgets referencing metrics that don't exist yet
- **Preserve \_meta** — never remove or modify `_meta.intent` or `_meta.audience`
- **One concern per PR** — metric instrumentation in one PR, dashboard JSON updates separately
- **Verify before trusting** — always confirm metrics appear in Metrics Explorer before adding widgets
