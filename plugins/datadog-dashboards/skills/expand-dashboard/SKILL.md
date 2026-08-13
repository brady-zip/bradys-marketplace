---
name: expand-dashboard
description: Use when user wants to add new metrics, widgets, or sections to an existing Datadog dashboard
argument-hint: "<path-to.dash.json>"
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
Read _meta → Gap analysis → Instrument code → Test emission → PR metrics → Update .dash.json → Iterate visuals
```

**CRITICAL: Read `_meta.intent`, `_meta.audience`, and `_meta.scope` from the .dash.json BEFORE starting. The intent defines what metrics matter. The audience defines how they should be presented. The scope identifies which services and integrations are available.**

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
3. **Use correct query format** — refer to @${CLAUDE_PLUGIN_ROOT}/knowledge/dashboard-json-reference.md
4. **Place widgets** in the appropriate group/section, or create new groups if needed
5. **Upload** with `chart-room test <file>`

## Phase 6: Handoff to Iterate

Invoke the `iterate-dashboard` skill to visually refine the newly added widgets. The user will drive the visual iteration from here.

## Guidelines

- **Verify metrics exist in Datadog before adding widgets that reference them**
- **Metrics PR first, dashboard changes second** — never merge dashboard widgets referencing metrics that don't exist yet
- **Preserve \_meta** — never remove or modify `_meta.intent` or `_meta.audience`
- **One concern per PR** — metric instrumentation in one PR, dashboard JSON updates separately
- **Verify before trusting** — always confirm metrics appear in Metrics Explorer before adding widgets
