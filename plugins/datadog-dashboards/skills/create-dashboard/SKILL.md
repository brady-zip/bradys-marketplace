---
name: create-dashboard
description: Use when user wants to create a new Datadog dashboard from scratch
argument-hint: "[service or topic]"
---

# Creating Datadog Dashboards

Create a new dashboard from intent through initialization, then hand off to expand and iterate.

## Overview

**Intent and audience first.** A dashboard exists to answer specific questions for a specific audience. Nail those down, create the file with `chart-room init`, record the intent and audience as `_meta` in the .dash.json, then hand off to `expand-dashboard` to fill it with content.

**If an argument was provided**, use it as the starting context for Phase 1 (e.g., if the user said `/create-dashboard payments-service`, start by asking about the payments service).

**If no argument**, begin Phase 1: Intent Discovery by asking about the dashboard's purpose.

## Workflow

```
Intent → Audience → Brainstorm sections → chart-room init → Record _meta → Handoff to expand
```

## Phase 1: Intent Discovery

Ask the user using AskUserQuestion:

### 1.1 Dashboard Purpose

```json
{
  "questions": [
    {
      "question": "What is the primary purpose of this dashboard?",
      "header": "Purpose",
      "options": [
        {
          "label": "Service Health",
          "description": "Monitor a service's operational health (latency, errors, throughput)"
        },
        {
          "label": "Infrastructure",
          "description": "Monitor hosts, containers, or cloud resources (CPU, memory, disk, network)"
        },
        {
          "label": "SLO Tracking",
          "description": "Track service level objectives and error budgets"
        },
        {
          "label": "Incident Response",
          "description": "Triage and investigate production issues in real-time"
        }
      ],
      "multiSelect": false
    }
  ]
}
```

### 1.2 Key Questions

Push the user to articulate **3-5 specific questions** this dashboard should answer. These become the `_meta.intent`.

Examples:

- "Is the checkout service healthy right now?"
- "Which endpoints have the highest error rate?"
- "Are we burning through our error budget?"

### 1.3 Audience

Ask who looks at this dashboard and when:

- Engineers debugging? → needs drill-down, log streams, detailed queries
- On-call during incidents? → needs alert status, clear thresholds, fast triage
- Leadership/stakeholders? → needs summary KPIs, trends, SLO status

### 1.4 Scope

- What service(s) or system(s)?
- What environments? (production, staging, etc.)
- What Datadog integrations are available? (APM, logs, infrastructure, synthetics, RUM)
- What tags are available? (service, env, team, cluster)

## Phase 2: Brainstorm Structure

Based on intent and audience, propose:

1. **Dashboard title** — clear, specific (e.g., "Payments Service Health" not "Payments")
2. **Layout type** — ordered (timeboard) for debugging, free (screenboard) for status pages
3. **Section outline** — high-level groups and what questions each answers
4. **Template variables** — env, service, and any other relevant filters

Present to the user for confirmation. Keep it high-level — detailed widget design happens in iterate.

## Phase 3: Initialize

```bash
chart-room init path/to/<dashboard-name>.dash.json
```

This creates the .dash.json file and provisions test + prod dashboards in Datadog.

## Phase 4: Record Metadata

After `chart-room init`, read the generated .dash.json and add `_meta` at the top level. Refer to @${CLAUDE_PLUGIN_ROOT}/knowledge/dashboard-json-reference.md for the correct JSON schema for template variables, layout_type, and widget structure.

```json
{
  "_meta": {
    "intent": [
      "Is the checkout service healthy right now?",
      "Which endpoints have the highest error rate?",
      "Are we burning through our error budget?"
    ],
    "audience": "On-call engineers triaging production incidents",
    "scope": {
      "services": ["checkout-service"],
      "integrations": ["APM", "logs", "infrastructure"]
    }
  },
  "title": "...",
  "description": "...",
  ...
}
```

Also populate:

- `title` — from Phase 2
- `description` — one sentence summarizing purpose and audience
- `layout_type` — from Phase 2
- `template_variables` — from Phase 2
- An initial skeleton of `widgets` — empty group widgets matching the section outline from Phase 2

Write the updated .dash.json back to the file.

## Phase 5: Handoff to Expand

Invoke the `expand-dashboard` skill. The expand skill will:

1. Read `_meta.intent` and `_meta.audience` from the .dash.json
2. Identify which metrics are needed to answer the intent questions
3. Instrument code if needed
4. Fill the dashboard with widgets
5. Hand off to `iterate-dashboard` for visual refinement

## Guidelines

- **Complete each phase before moving to the next**
- **Use AskUserQuestion at every decision point** — never assume
- **Don't skip to widgets** — intent and audience first, always
- **Keep \_meta accurate** — it guides every downstream skill
- **Brainstorm structure, not details** — section names and purposes, not individual widget queries
- **chart-room init before editing** — the file must be provisioned in Datadog before adding content
