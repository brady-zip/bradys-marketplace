---
name: create-dashboard
description: Use when user wants to create a new Datadog dashboard from scratch
argument-hint: "[service or topic]"
allowed-tools: Bash(bash:*), Bash(chart-room:*), Bash(jq:*), Read, Write, Edit, AskUserQuestion, Skill
---

# Creating Datadog Dashboards

Create a new dashboard from intent through initialization, then hand off to expand and iterate.

## Overview

**Intent and audience first.** A dashboard exists to answer specific questions for a specific audience. Nail those down, create the file with `chart-room init`, record the intent and audience as `_meta` in the .dash.json, then hand off to `expand-dashboard` to fill it with content.

**If an argument was provided**, use it as the starting context for Phase 1 (e.g., if the user said `/create-dashboard payments-service`, start by asking about the payments service).

**If no argument**, begin Phase 1: Intent Discovery by asking about the dashboard's purpose.

## Workflow

```
Preflight → Intent → Audience → Brainstorm sections → chart-room init → Record _meta → Handoff to expand → Ledger
```

## Phase 0: Preflight — MANDATORY, EVERY INVOCATION

**This runs automatically, before Phase 1, on every single invocation of this skill — no exceptions, no caching, no "the user already ran it."**

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill create --brief 2>&1 || true`

**The block above already ran.** It is an inline bash block, so Claude Code executed it the moment this skill was invoked — its output is in your context right now, above this line. You do not run it again, and there is no path through this skill where it did not run. That is the point: the check no longer depends on anyone remembering to perform it.

If you see no preflight output above, the injection failed. Run it manually and treat the result exactly the same way:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill create --brief
```

The script checks every dependency the create → expand → iterate chain needs, and installs the ones that can be installed without a human decision (`uv`, `llm` + `llm-gemini`, `mise`, `node@22`, `jq`). It is idempotent — on a healthy machine it no-ops in a couple of seconds.

`--brief` keeps a healthy machine down to two lines. It does **not** hide problems: on anything other than a clean pass the full repaired / deferred / `USER ACTION REQUIRED` blocks are printed inline, and the complete report is written to a log file whose path comes back as `PREFLIGHT_LOG:`. Drop `--brief` (or `cat` that log) when a check itself is misbehaving.

Read the machine-readable tail of the output and act on it:

- **`PREFLIGHT_STATUS: OK`** → say so in one line, proceed to Phase 1.
- **`PREFLIGHT_STATUS: REPAIRED`** → **tell the user exactly what was installed on their machine**, then proceed. It is their machine; never modify it silently.
- **`PREFLIGHT_STATUS: BLOCKED`** → **STOP.** Show the user the `USER ACTION REQUIRED` block verbatim, with its exact fix commands. Do not start Phase 1. Do not work around it.

If `PREFLIGHT_DEFERRED > 0`, the dependency is not needed by *this* skill but will be needed by `expand-dashboard` or `iterate-dashboard`. **Tell the user now, at the start** — not when the handoff walks into it three phases later.

**Never substitute your own judgement for a missing dependency.** A degraded run that looks successful is worse than one that stops, because the user cannot tell the difference.

Full rationale: @${CLAUDE_PLUGIN_ROOT}/knowledge/preflight-contract.md

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
- An initial skeleton of `widgets` — **empty** group widgets matching the section outline from Phase 2

**Empty means empty.** No queries, no `requests`, no `conditional_formats`, no child widgets. Filling them is `expand-dashboard`'s job, and it does something this skill cannot: it verifies each metric actually exists and is emitting before anything references it. See Phase 5 — writing widget content here is the specific mistake that broke a real run.

Write the updated .dash.json back to the file.

## Phase 5: Handoff to Expand — THE MOST IMPORTANT PHASE IN THIS SKILL

**Read this even if you think you know what it says. This is the phase that failed, and the way it failed will feel reasonable to you at the time.**

### What actually happened

A real run completed Phases 1–4 cleanly — discovery, structure, `chart-room init`, `_meta` — and then did not invoke `expand-dashboard`. Nothing went wrong. There was no error, no context exhaustion, no lost thread. In the running session's own words:

> "By Phase 5 I already had the RUM app id, validated metric queries and a route census in hand, so continuing felt like finishing work in progress. Phase 5 is one line at the tail of a long document with nothing checking it happened. I treated a handoff as optional because nothing made it mandatory."

It authored every widget inline instead, then ran its own ad-hoc verify-and-fix loop.

**The cost was not one phase.** Because `expand-dashboard` never ran, it never handed off to `iterate-dashboard`, so there was no Gemini evaluation and no iteration report. **One skipped line silently deleted two entire skills from the run**, and the user was never told any of it.

### The trap, stated plainly

By the time you reach Phase 5 you will be holding exactly the context that makes handing off feel wasteful: the service names, the working queries, the tag structure. Authoring the widgets yourself will feel like momentum, and invoking another skill will feel like throwing that away.

**That feeling is the failure mode, not a signal.** `expand-dashboard` exists to verify metrics actually exist and emit before any widget references them, and it hands to `iterate-dashboard`, which has Gemini — an evaluator that is not you — score the result. Doing it inline skips both, and produces something that looks finished.

### The rule

**Do not author widget content in this skill. Ever.**

Phase 4 writes `_meta`, `title`, `description`, `layout_type`, `template_variables`, and **empty group widgets only**. If you find yourself writing a `q:` query string, a `conditional_formats` block, or a non-empty group in `create-dashboard`, you have left this skill's scope — stop and hand off.

### Do this

1. **State the handoff** — tell the user you are moving from `create-dashboard` to `expand-dashboard`, and on which file.
2. **Invoke the `expand-dashboard` skill** with the `.dash.json` path as its argument, using the Skill tool. Actually invoke it. Describing what it would do, or doing its work yourself, is the failure above.
3. **Carry your context across, don't spend it here.** Anything you already learned — validated queries, service and tag names, app ids, route inventories — goes into the handoff message so `expand-dashboard` starts from it. Handing off does not throw that away; that is the objection this phase exists to overrule.

### Skipping

**The only acceptable reason to skip is that the user explicitly told you to stop.** Record it as `SKIPPED` in the ledger with their words, tell them the dashboard is an unfilled skeleton, and tell them how to resume: `/expand-dashboard <path>`.

"It felt like finishing work in progress", "I already had the queries", "running the other skill seemed redundant", running low on context, or an unrelated error are **not** acceptable reasons. If you genuinely cannot complete the handoff, mark it `FAILED`, say why, and tell the user that `expand-dashboard` and `iterate-dashboard` did not run — so they know two skills are missing from the result rather than discovering it later.

## Phase 6: Completion Ledger — ALWAYS PRINT

Before you finish, print this table. Fill `Status` with `DONE`, `SKIPPED`, or `FAILED`, and check each row against what you **actually did**, not what you intended to do.

```
| Phase | Status | Notes |
|---|---|---|
| 0. Preflight        |  | |
| 1. Intent discovery |  | |
| 2. Brainstorm structure |  | |
| 3. chart-room init  |  | |
| 4. Record _meta     |  | |
| 5. Handoff to expand |  | |
```

If row 5 is not `DONE`, say so in bold prose immediately under the table, and spell out the cascade: `expand-dashboard` did not run, therefore `iterate-dashboard` did not run, therefore there was no Gemini evaluation and no iteration report. The user needs to know two skills are missing from this run, not just one phase.

**Every `SKIPPED` or `FAILED` row must carry a reason in Notes, and must also be restated in prose below the table** — a user skimming past a markdown table still has to see it. Say what they should do about each one.

Skipping a phase is allowed. Skipping it without telling anyone is not.

## Guidelines

- **Preflight runs every invocation** — before Phase 1, always, and its result goes to the user
- **Complete each phase before moving to the next** — and print the Phase 6 ledger even when phases were skipped
- **Never silently skip or degrade** — a skipped phase, a failed dependency, or a substituted approach is reported to the user the moment it happens, not discovered by them later
- **Use AskUserQuestion at every decision point** — never assume
- **Don't skip to widgets** — intent and audience first, always
- **Keep \_meta accurate** — it guides every downstream skill
- **Brainstorm structure, not details** — section names and purposes, not individual widget queries
- **chart-room init before editing** — the file must be provisioned in Datadog before adding content
