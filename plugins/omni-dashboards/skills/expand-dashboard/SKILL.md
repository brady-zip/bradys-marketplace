---
name: expand-dashboard
description: Expand an existing Omni dashboard with tiles backed by discovered semantic fields and executed representative queries, then invoke browser and Gemini iteration. Does not edit shared models or warehouse schemas.
argument-hint: "<path/to/dashboard.omni.jsonc> [--handoff PATH]"
allowed-tools: Bash(bash:*), Bash(python3:*), Bash(chart-room:*), Bash(omni:*), Read, Write, Edit, Grep, Glob, Task, AskUserQuestion, Skill
---

# Expand an Omni dashboard

Read @${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-contract.md,
@${CLAUDE_PLUGIN_ROOT}/knowledge/omni-reference.md,
@${CLAUDE_PLUGIN_ROOT}/knowledge/query-evidence.md,
@${CLAUDE_PLUGIN_ROOT}/knowledge/authoring-cookbook.md and
@${CLAUDE_PLUGIN_ROOT}/knowledge/phase-handoff.md.

## 0. Preflight — every invocation, including handoffs

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill expand --brief 2>&1 || true`

If absent, run manually. Stop on BLOCKED and print the ledger. Explain deferred
probes without calling a dependency broken when the probe could not run. After
reading the supplied file and selected profile, rerun against the actual context:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill expand \
  --file "path/to/dashboard.omni.jsonc" --profile PROFILE --require-context
```

Resolve all required deferrals before publication. Browser attachment is required
for the representative-tile check in step 5; Gemini remains an iteration
requirement. An offline schema operation does not require either.

## 1. Read intent

Read `_meta.intent`, `questions`, `audience`, `scope`, `owner`, `sections`, grain,
time window/timezone and filters. Recover missing decisions from the user; do not
silently replace them. Identify which new questions or existing gaps matter.
Read and verify `--handoff PATH`, or initialize a private `handoff.json` using the
phase-handoff contract. Preserve auth, decisions, sharing scope and evidence paths;
source/target mismatches require reconciliation before using earlier evidence.

## 2. Inventory real resources

Inventory every existing tile, query, control, section and linked dependency.
Discover the chosen model's topics, dimensions and semantic measures with
`chart-room omni topics` and `chart-room omni fields` (selected profile, JSON).
Follow official `omni <group> <command> --help` and `--schema` for extra discovery;
fully paginate lists before declaring absence. Prefer existing semantic measures.

Check the contract v1 resource boundary before editing. Stop on workbook-local
semantic extensions, draft/branch query bindings, upload-backed resources, foreign
tabs, apps or unsupported tile kinds. Do not silently turn them into SQL tiles.

## 3. Run bounded representative queries

For each candidate and existing data tile, run a real representative query through
`omni --base-url https://zip.omniapp.co --format json --profile PROFILE query run`.
Inspect `query run --help` and `--schema` offline before sending JSON via stdin or
`--body @FILE`. Choose a finite date range, verified result-row limit, few fields,
intentional filters/timezone and a timeout. A result-row limit alone does not bound
warehouse scanning. Do not use refresh/rebuild modes just to check a dashboard.

Use actual discovered field names and supported query shapes, not example names.
Record successful execution time, query/request identifier or digest, row count,
expected grain and range, null coverage, units, aggregation, denominator and
refresh/caching assumptions. Retain minimal health summaries locally; do not add
raw data exports to source or send them to Gemini. A query plan or static schema
inspection is never evidence that a query ran.

A missing field, inaccessible model, expired credential, successful empty result
and failed query are different outcomes. Classify them using the evidence guide.
A missing metric must not become a plausible-looking zero or empty tile.

## 4. Record gaps and owners

Map each question to evidence and mark it backed, missing, inaccessible, empty or
failed. Create a concrete separate handoff for missing model/data work: question,
expected measure/grain/denominator, verified missing resource, target model/topic,
owner and acceptance query/result. Do not modify shared models, warehouse schemas
or instrumentation in this dashboard-only workflow. Do not create/send a ticket
or message unless the invoked workflow explicitly requests posting.

Explain how unanswered questions affect usefulness. If sufficient backed content
remains, continue with it and record the gap. If it defeats the dashboard's purpose,
stop and show the blocker. A healthy empty result can be retained only when it is
intentional, clearly labeled and explicitly accepted, with its verified reason.

Record each question in `_meta.question_status` using the shape in
@${CLAUDE_PLUGIN_ROOT}/knowledge/review-artifacts.md. Mark a limitation accepted
only from the user's actual decision. Mirror this in the handoff and make the
partial/blocked status, effect on interpretation and owner next steps visible on
the dashboard. A gap in a question does not excuse a broken or unrun data tile.

## 5. Author one backed tile and verify it renders

Copy the shape from @${CLAUDE_PLUGIN_ROOT}/examples/reference.omni.jsonc; do not
derive it from the schema. Preserve the initialized envelope and use real fields.
First author **one** representative query tile plus its sized card stack and
name/subtitle metadata placements. Preserve other content on existing dashboards.
Validate and publish it with step 6's commands, then invoke the Task tool with
`subagent_type="omni-dashboards:dashboard-browser"` on the exact test URL. Supply
the source hash, tile ID, expected values, control map and evidence directory.
For this focused check, require an actual non-collapsed visual, readable title and
subtitle, and rendered values consistent with the executed query. Record the
publication/readback and browser evidence in `handoff.json.representative_tile`.
If the agent cannot attach or the tile is blank/collapsed, stop expansion and
report the failed author phase. Do not multiply the same unverified shape across
the dashboard. This check has no Gemini score and does not replace full iteration.

After the representative tile passes, author the remainder:

Use native query/sql/linked/blank tiles supported by the pinned schema. SQL tiles
still need actual query evidence. Preserve numeric tile keys, linked dependencies,
container instance keys and `_meta`. Make filters relevant to the business question.
Choose intentional date defaults, units/number formats, labeled axes, metric
definitions, null/zero behavior, sorting, comparability and an ordered narrative.
Document aggregation, grain, denominator, timezone and refresh assumptions beside
metrics or in the description/metadata. Avoid reimplementing a semantic measure
without an owner-approved definition.
Regenerate control-scope documentation with
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/explain-controls.py" FILE` after mapping
edits. Use the output for on-page filter sentences, recording implicit scope for
browser verification rather than calling absent map entries excluded. Check
totals/subsets before stacking, and leave sufficient subtitle headroom.

Validate native `visConfig`, `resultConfig`, controls, settings and containers:

```bash
chart-room validate "path/to/dashboard.omni.jsonc"
chart-room validate "path/to/dashboard.omni.jsonc" --remote --profile PROFILE
```

Remote validation checks plans. Keep executed-query evidence as a separate gate.
Neither gate proves visible rendering. Do not relax the schema to get a
visualization accepted. Record both the early representative publication and final
publication separately; a fresh dashboard normally needs these two test writes.

## 6. Publish to test

```bash
chart-room test "path/to/dashboard.omni.jsonc" --profile PROFILE --format json
chart-room status "path/to/dashboard.omni.jsonc" --profile PROFILE --json
```

Require successful draft and published readback and capture the exact test URL.
Confirm the target ID is the test ID and production was not updated. Failed or
ambiguous writes stop the workflow; preserve recovery identifiers. Never delete
someone's draft or retry a possibly successful write automatically.
Use the cookbook's 1.10.2 `automaticVis` normalization guidance and failed-draft recovery
guidance. Do not invoke the proposed `test --dry-run` or `--discard-draft` options
unless a later verified release actually supports them.

## 7. Invoke iteration — required handoff

Update the structured handoff with the current hash, all per-tile query evidence,
question statuses, control scope and final publication. State the handoff and
actually invoke:

`Skill(skill="omni-dashboards:iterate-dashboard", args="path/to/dashboard.omni.jsonc --handoff /absolute/private/handoff.json")`

Carry exact test URL, profile, query evidence, current filters/time window,
unanswered questions and owner handoffs. Do not perform your own visual score.
The `author` ledger reason includes the representative-tile render evidence;
`test` refers to the completed dashboard's publication, not just the first tile.
If not invoked, record SKIPPED only for a user stop, otherwise FAILED; explicitly
say no independent Gemini review occurred and give the resume command.

## 8. Completion ledger — always print

| Phase | Status | Reason / evidence |
|---|---|---|
| preflight | | |
| intent | | |
| inventory | | |
| queries | | |
| gaps | | |
| author | | |
| test | | |
| iterate | | |

Every row uses DONE, SKIPPED or FAILED with a reason. `gaps` can be DONE when no gaps
were found; say that. Report unresolved questions even if useful backed tiles were
added. Restate skipped/failed phases in prose, link the source/test/report, and
preserve the merge-to-deploy route; no direct production upload is part of expansion.
