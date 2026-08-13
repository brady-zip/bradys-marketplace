---
name: iterate-dashboard
description: Use when user wants to visually refine, adjust formatting, fix layout, or make targeted changes to an existing Datadog dashboard .dash.json file
argument-hint: "<path-to.dash.json>"
---

# Iterating on a Datadog Dashboard

Gemini-driven visual iteration loop for refining an existing dashboard through automated screenshot evaluation.

## Overview

**Automated screenshot-driven iteration.** Take a screenshot, send it to Gemini for objective evaluation, apply its suggestions, upload with `chart-room test`, and repeat until the dashboard scores 7+/10 or hits the iteration limit. The user gets final approval.

**The argument is the path to the .dash.json file.** If no argument was provided, ask the user which .dash.json file to iterate on.

## Prerequisites

- An existing `.dash.json` file (created via `create-dashboard` or `chart-room init`)
- The dashboard must be initialized in Datadog (`chart-room status <file>` shows linked test dashboard)
- The bundled `datadog-dashboard-viewer` MCP server (auto-launched by this plugin via `mise x node@22 -- npx -y chrome-devtools-mcp@latest --autoConnect --channel=beta`) — requires Chrome Beta to be running with your Datadog session
- `uvx llm` with `gemini/gemini-2.5-flash` model configured (or `gemini/gemini-3.1-pro-preview` as alternative)

## Workflow

```
Phase 0: Prerequisite check (uvx llm models | grep gemini)
Phase 1: Read .dash.json + ensure _meta exists + get user direction
Phase 2: Session init (mkdir /tmp/dd-eval-{epoch})  ← MUST complete before ANY edits
Phase 3: Auto-loop:
  3.1  Screenshot via dashboard-browser agent → save to /tmp/dd-eval-{epoch}/screenshot-{N}.png
  3.1b Rendering check — if broken queries/no data → fix .dash.json, re-upload, loop back to 3.1 (don't increment N)
  3.2  Gemini eval → cat prompt.txt | uvx llm -m gemini/gemini-2.5-flash --no-stream -a screenshot.png > output.txt
  3.3  Parse RATING (1-10) + SUGGESTIONS → save to eval-{N}.json
  3.4  If RATING >= 7 OR N >= STOP_LIMIT → exit loop
  3.5  Claude applies Gemini's suggestions to .dash.json
  3.6  chart-room test <file> → loop back to 3.1
Phase 4: Present final screenshot + rating to user for approval/override
Phase 5: Generate iteration report playground (HTML)
```

## Phase 0: Prerequisite Check

**STOP if this fails.** Run before anything else:

```bash
uvx llm models | grep gemini
```

If no gemini models appear, STOP and tell the user: "Gemini model not configured. Run `uvx llm models` to check available models and configure a Gemini model before proceeding."

Preferred model: `gemini/gemini-2.5-flash` (faster, more reliable). Fallback: `gemini/gemini-3.1-pro-preview`.

Do NOT fall back to self-evaluation. Do NOT skip this check.

## Phase 1: Context

1. **Read the .dash.json** — load the full file, look for `_meta.intent`, `_meta.audience`, and `_meta.scope`

2. **If `_meta` fields are missing** — STOP and ask the user to provide them before proceeding. Use AskUserQuestion: "This dashboard has no \_meta fields. I need these for Gemini evaluation context. What is the intent/purpose of this dashboard? Who is the target audience?" Write the responses into the .dash.json as `_meta.intent`, `_meta.audience`, and `_meta.scope` before continuing.

3. **Ask the user what they want to change** — use AskUserQuestion with specific options when possible (e.g., "Which section needs work?" with the group titles as options). **This step is MANDATORY even if the user provided a file path.** The file path tells you WHAT to iterate on, not WHAT TO CHANGE. Do not skip this.

## Phase 2: Session Init

**GATE: Do not proceed to Phase 3 until this directory exists on disk.**

1. Create a session directory for screenshots:

```bash
SESSION_DIR="/tmp/dd-eval-$(date +%s)"
mkdir -p "$SESSION_DIR"
```

2. Set iteration counter `N=0`
3. Read `STOP_LIMIT` from `_meta.gemini_stop_limit` in the .dash.json (default: **5** if not set)

Verify the directory was created:

```bash
ls -d "$SESSION_DIR"
```

## Phase 3: Gemini Auto-Loop

Repeat until `RATING >= 7` or `N >= STOP_LIMIT`:

### 3.1 Screenshot

**Use the dashboard-browser agent via the Task tool.** Do NOT call `datadog-dashboard-viewer` MCP tools directly — the agent handles navigation timing, widget load waiting, and viewport sizing.

```
Task(
  subagent_type="datadog-dashboards:dashboard-browser",
  prompt="Navigate to {dashboard_test_url}, wait for all widgets to load, take a full-page screenshot, save to {SESSION_DIR}/screenshot-{N}.png"
)
```

The dashboard test URL comes from `chart-room status <file>`.

If the Task agent fails, retry once. If it fails again, STOP and tell the user the screenshot step failed — do NOT fall back to calling `datadog-dashboard-viewer` MCP tools directly.

### 3.1b Rendering Check

**Before evaluating aesthetics, verify the dashboard actually rendered correctly.** Read the screenshot from 3.1 and check for:

- **"No data" widgets** — empty widget bodies, "No data" or "N/A" text
- **Query errors** — red error banners, "Invalid query" messages, missing metric warnings
- **Broken template variables** — unresolved `$variable` text visible in widget titles or queries
- **Empty groups** — group widgets that contain no visible content

**If any rendering issues are found:**

1. Diagnose the root cause in the .dash.json (wrong metric name, bad query syntax, missing template variable definition, incorrect tag filter)
2. Fix the .dash.json
3. Re-upload: `chart-room test <file>`
4. **Do NOT increment N** — loop back to 3.1 to take a fresh screenshot

This prevents wasting Gemini evaluation cycles on a broken dashboard. Only proceed to 3.2 when all widgets are rendering data correctly.

### 3.2 Gemini Evaluation

**HARD REQUIREMENT: You MUST run `uvx llm` for evaluation. Do NOT substitute your own visual assessment. Gemini is the evaluator, not you.**

Run the Gemini evaluation via `uvx llm`. **Important:** Write the prompt to a temp file and pipe it in — do NOT pass it as a CLI argument. This prevents hangs when the Bash tool runs the command in the background.

```bash
cat > "{SESSION_DIR}/prompt-{N}.txt" << 'PROMPT_EOF'
You are an expert in data visualization and Datadog dashboard design. You evaluate dashboard screenshots for clarity, usability, and fitness for purpose. Be precise and actionable.

Evaluate this Datadog dashboard screenshot.

DASHBOARD PURPOSE:
{_meta.intent joined as bullet list}

TARGET AUDIENCE:
{_meta.audience}

USER'S CHANGE REQUEST:
{user_direction from Phase 1}

Evaluate against:
1. INTENT ALIGNMENT — Does the layout, widget selection, and information hierarchy serve the stated purpose? Can the audience answer their questions at a glance?
2. VISUAL CLARITY — Are labels readable? Adequate spacing? Colors meaningful? Conditional formats applied where thresholds matter?
3. WIDGET APPROPRIATENESS — Is each widget the right type for its data pattern? (bars for sparse data, lines for trends, query values for KPIs, heatmaps for distributions)
4. INFORMATION DENSITY — Wasted space? Redundant widgets? Missing widgets the intent requires?
5. USER REQUEST — Does the current state address what the user asked to change?

Respond in EXACTLY this format:

RATING: <number 1-10>

SUMMARY: <2-3 sentences on overall quality and biggest gap>

SUGGESTIONS:
1. <suggestion> — STEP: <exact edit action, e.g. 'Change the Error Rate widget from timeseries line to query_value with conditional_formats at 1% yellow and 5% red'>
2. ...

Up to 5 suggestions ordered by impact. If rating >= 7, you may provide 0. Do NOT suggest adding metrics that may not exist — focus on presentation of what is already there.
PROMPT_EOF

cat "{SESSION_DIR}/prompt-{N}.txt" | uvx llm -m gemini/gemini-2.5-flash --no-stream \
  -a "{SESSION_DIR}/screenshot-{N}.png" \
  > "{SESSION_DIR}/gemini-output-{N}.txt" 2>&1
```

Then read the output file:

```bash
cat "{SESSION_DIR}/gemini-output-{N}.txt"
```

Replace `{placeholders}` with actual values from the .dash.json `_meta` and user input before writing the prompt file.

**Why this pattern:** Piping from a file prevents stdin issues when the Bash tool runs commands in the background. `--no-stream` avoids buffering problems. Explicit output redirection ensures the response is captured reliably regardless of how the Bash tool manages the process.

### 3.3 Parse and Save Response

Extract from Gemini's response:

- **RATING**: the integer after `RATING:`
- **SUMMARY**: the text after `SUMMARY:`
- **SUGGESTIONS**: each numbered suggestion with its `STEP:` action

Save each iteration's data to `{SESSION_DIR}/eval-{N}.json` for the Phase 5 report:

```json
{
  "iteration": N,
  "rating": 6,
  "summary": "...",
  "suggestions": ["..."],
  "changes_applied": ["description of each .dash.json edit"]
}
```

Display the full Gemini evaluation to the user for transparency.

### 3.4 Check Exit Conditions

- If `RATING >= 7` → exit loop, proceed to Phase 4
- If `N >= STOP_LIMIT` → exit loop, proceed to Phase 4
- Otherwise → continue to 3.5

### 3.5 Apply Suggestions

Apply **all** of Gemini's suggestions to the .dash.json in a single edit pass. Refer to:

- @${CLAUDE_PLUGIN_ROOT}/knowledge/widget-selection-guide.md for widget type decisions
- @${CLAUDE_PLUGIN_ROOT}/knowledge/dashboard-json-reference.md for JSON schema

### 3.6 Upload and Increment

```bash
chart-room test <file>
```

Increment `N` and loop back to 3.1.

## Phase 4: Present to User

1. Show the final screenshot and Gemini's last rating/summary
2. Ask the user for final approval using AskUserQuestion with options:
   - **Accept** — done, the dashboard is ready
   - **Override direction** — provide new change direction and re-enter Phase 3
   - **Continue iterating** — reset N and keep looping with current direction

## Phase 5: Iteration Report Playground

After the user accepts the final result, generate a single-file HTML playground that documents the full iteration history. Save it to `{SESSION_DIR}/iteration-report.html` and open it with `open`.

### Data to embed

Collect from the session directory:

- **Screenshots**: base64-encode each `screenshot-{N}.png` and embed as data URIs
- **Evaluations**: read each `eval-{N}.json` for rating, summary, suggestions, and changes applied
- **Metadata**: dashboard name from `_meta`, user's change request, total iterations, final rating

### Layout

```
+-----------------------------------------------------+
|  Dashboard: {name}  |  Request: {user_direction}     |
|  Iterations: {N}    |  Final Rating: {rating}/10     |
+---+---+---+-----------------------------------------+
| 0 | 1 | 2 | ...    ← iteration tabs                 |
+---+---+---+-----------------------------------------+
|                                                       |
|  +-----------------------+  +----------------------+  |
|  | Screenshot            |  | Gemini Evaluation    |  |
|  | (embedded image)      |  | Rating: 4/10         |  |
|  |                       |  | Summary: ...         |  |
|  |                       |  | Suggestions:         |  |
|  |                       |  |  1. ...              |  |
|  |                       |  |  2. ...              |  |
|  +-----------------------+  +----------------------+  |
|                                                       |
|  Changes Applied:                                     |
|  • Changed Error Rate widget from line to query_value |
|  • Added conditional_formats to Latency P99           |
+-------------------------------------------------------+
|  Rating Progress: [■■■■□□□□□□] 4 → 5 → 7             |
+-------------------------------------------------------+
```

### Requirements

- **Single HTML file** — inline all CSS and JS, embed screenshots as base64 data URIs
- **Dark theme** — system font for UI, monospace for code/values
- **Tabbed navigation** — one tab per iteration (0 through N), click to switch
- **Rating progress bar** — horizontal bar at the bottom showing rating at each iteration with color gradient (red → yellow → green)
- **Side-by-side** — screenshot on the left, Gemini evaluation on the right within each tab
- **Changes list** — below the side-by-side, show what was changed in that iteration (from `eval-{N}.json` `changes_applied`)
- **No external dependencies** — everything inline

### Building the playground

```javascript
// Embed iteration data collected during Phase 3
const iterations = [
  {
    screenshot: "data:image/png;base64,...", // base64 of screenshot-0.png
    rating: 4,
    summary: "Dashboard lacks visual hierarchy...",
    suggestions: ["Change Error Rate widget...", "Add conditional_formats..."],
    changes: ["Changed widget type for Error Rate", "Added threshold coloring"],
  },
  // ... one entry per iteration
];

const meta = {
  dashboardName: "Service Overview",
  userDirection: "Make thresholds more visible",
  totalIterations: 3,
  finalRating: 7,
};
```

Use the base64 command to encode screenshots:

```bash
base64 -i "{SESSION_DIR}/screenshot-{N}.png"
```

### State management

```javascript
const state = { activeTab: 0 };

function render() {
  // Update tab highlight
  // Show screenshot + eval for state.activeTab
  // Update rating progress bar
}
```

## Common Iteration Patterns

| User Request           | Typical Changes                                                    |
| ---------------------- | ------------------------------------------------------------------ |
| "Widget shows no data" | Fix query tags, template variable references, metric names         |
| "Hard to read"         | Change widget type, adjust display_type, add legend, increase size |
| "Need thresholds"      | Add markers to timeseries, conditional_formats to query_value      |
| "Wrong time range"     | Adjust rollup, add time override, change aggregation               |
| "Too cluttered"        | Remove series, use `top()`, consolidate groups                     |
| "Reorder sections"     | Move group widgets in the widgets array                            |

## Guidelines

- **Apply all Gemini suggestions per iteration** — Gemini evaluates holistically, so its suggestions form a coherent set
- **Always screenshot after upload** — don't assume the change looks right
- **Preserve \_meta** — never remove or modify `_meta.intent` or `_meta.audience` during iteration
- If the user's request implies adding new metrics that don't exist yet, suggest using the `expand-dashboard` skill instead
