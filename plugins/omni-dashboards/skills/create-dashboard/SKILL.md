---
name: create-dashboard
description: Create or adopt an Omni dashboard from intent, select an existing shared model and topic, then explicitly invoke expansion and independent visual review. Use for dashboard content, not semantic-model development.
argument-hint: "[business topic or existing dashboard URL]"
allowed-tools: Bash(bash:*), Bash(chart-room:*), Bash(omni:*), Read, Write, Edit, AskUserQuestion, Skill
---

# Create an Omni dashboard

Read @${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-contract.md and
@${CLAUDE_PLUGIN_ROOT}/knowledge/omni-reference.md. Work only on `.omni.jsonc`.

## 0. Preflight — every invocation

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill create --brief 2>&1 || true`

If injection produced no report, run that command manually. `|| true` preserves the
report in context; it does not authorize ignoring failures. On `BLOCKED`, stop and
print the complete ledger. Explain every deferral now. A deferred required check
must be resolved before its dependent action. Browser/Gemini are checked by iterate.

## 1. Discover intent

Use supplied context first; ask only for missing decisions. Record 3–5 specific
business questions, the audience and its decisions, scope, and accountable owner.
Ask whether this is a new pair or adoption of an existing dashboard. An existing
URL does not authorize replacing its production content.

## 2. Select the model and topic

Use the official CLI through chart-room discovery, with the selected profile:

```bash
chart-room omni models --profile PROFILE --format json
chart-room omni topics --model MODEL_UUID --profile PROFILE --format json
chart-room omni fields --model MODEL_UUID --topic TOPIC_NAME --profile PROFILE --format json
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill create --profile PROFILE --model MODEL_UUID
```

Omit `--profile` consistently when using `OMNI_API_TOKEN`. Select an existing shared
model/topic based on actual discovery. Verify model permissions, not just web login.
An inaccessible model is not an empty catalog. Follow error classification in the
reference; no guessed field names or shared-model edits. Unsupported workbook-local
models, upload-backed content or apps require a separate owner handoff.

## 3. Agree on structure and provisioning

Agree on grain, time window, timezone, date defaults, business filters, title and
section layout. Each section must answer recorded questions. Record metric
ownership and refresh expectations. Reuse decisions already provided.

For a new pair, identify explicit prod and test folder UUIDs and their inherited
access. Read folder discovery/permissions via official CLI help/schema. Show the
intended locations: creation publishes both documents immediately. Obtain approval
for these concrete locations if this has not already been authorized. No roles,
AccessBoost, folder permissions or organization publishing policies are changed.

For adoption, inspect the published v2 document and its supported-resource boundary
before import. Preserve tile record keys and container instance keys. An unsupported
resource is a blocker, not permission to flatten or drop it.

## 4. Initialize or import

```bash
chart-room init "path/to/dashboard.omni.jsonc" --provider omni \
  --instance https://zip.omniapp.co --model MODEL_UUID \
  --prod-folder PROD_FOLDER_UUID --test-folder TEST_FOLDER_UUID --profile PROFILE
```

For adoption, use this instead:

```bash
chart-room import PROD_IDENTIFIER "path/to/dashboard.omni.jsonc" --provider omni \
  --instance https://zip.omniapp.co --test-folder TEST_FOLDER_UUID --profile PROFILE
```

Chart-room must preserve every successfully provisioned ID before the next create.
If a write is ambiguous, stop and inspect its recovery identifiers; never retry
blindly or create another pair. Verify distinct canonical targets across the entire
repository inventory; do not mix slug and UUID aliases. Import adopts production
and creates a separate test target; it must not duplicate production.

## 5. Record metadata

Read the generated file and preserve its envelope, `$schema`, target IDs and native
document fields. `_meta.intent`, `_meta.audience`, and `_meta.scope` are **strings**
in contract v1. Put the question list in the additional `_meta.questions` array.
Record the owner, model/topic, grain, time window/timezone, filters, refresh
assumptions and stable `_meta.sections` IDs as shown in the reference.

For new dashboards, write metadata, title/description and intentional empty
containers only. Do not author data tiles here. For imports retain existing tiles
for expansion to inventory and verify. Validate with `chart-room validate FILE`.
Schema validity proves shape, not useful data or rendering.

## 6. Invoke expansion — required handoff

Tell the user which file you are handing off. Actually invoke the Skill tool:

`Skill(skill="omni-dashboards:expand-dashboard", args="path/to/dashboard.omni.jsonc")`

Carry the selected profile, model/topic, questions, grain, filters, folders, owner
and discovery evidence into the handoff. Do not do expansion inline because the
queries already seem obvious. Expansion must in turn invoke iteration.

If the user asks to stop, record the handoff as `SKIPPED` with their reason. If the
invocation fails, record `FAILED`. In either case say explicitly: **Expansion did
not run; iteration was skipped; there is no Gemini evaluation or iteration report.**
Use `/omni-dashboards:expand-dashboard FILE` to resume.

## 7. Completion ledger — always print, including on failure

Use `DONE`, `SKIPPED`, or `FAILED`, with a concrete reason/evidence in every row:

| Phase | Status | Reason / evidence |
|---|---|---|
| preflight | | |
| intent | | |
| model | | |
| structure | | |
| initialize | | |
| metadata | | |
| expand | | |
| iterate | | |

A handoff invocation can be DONE even if its downstream workflow fails; report
that downstream failure accurately in the reason. If expand was not invoked,
iterate must be SKIPPED. Restate every skipped/failed phase and its next action in
prose. End with the definition path, exact target links and explicit acceptance
state. Do not claim a completed dashboard from a successfully created skeleton.
