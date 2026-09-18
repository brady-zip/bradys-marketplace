# Preflight, completion and authority

Every skill injects preflight on **every invocation**, including handoffs. A manual
run is required if injection is missing. Inline `|| true` keeps error detail in the
skill context; it never turns failure into permission to proceed.

Preflight is deliberately read-only. Setup owns dependency repair. It probes CLI
help/schema before authentication, checks the pinned Omni transport and chart-room
schema, then resolves the official profile/instance before forwarding credentials.
The injected diagnostic uses the official default profile. If the invocation or
handoff supplies a different profile, immediately rerun the diagnostic with that
selection before interpreting default-profile failures; no dependent work proceeds
until the selected-profile checks pass. Unknown model/target context is deferred until discovery supplies it. Run again with
`--file FILE --require-context` before publication, preserving the chosen profile.

| Result | Meaning and required response |
|---|---|
| OK | No failed probes in this scope. Read all deferrals; this is not live workflow acceptance. |
| BLOCKED / exit 1 | At least one dependency/access check failed. Stop its dependent work and show the fixed, redacted diagnostic. |
| DEFERRED / exit 2 with required context | A necessary probe could not finish. Resolve that uncertainty before proceeding. |
| DEFERRED check | Probe did not run, scope is not needed yet, context is missing, or environment prevented inspection. Explain which; do not call the dependency broken or healthy. |

Timeouts, missing tools, rejected credentials, denied models, hidden resources,
main drafts and PR-required policies have separate codes. CLI error bodies are
not echoed because they can contain credentials or internal data. Browser process
presence is only a hint. Actual MCP attachment and exact-URL inspection are required.
Installed llm with llm-gemini is used directly; no plugin-less uvx fallback.

Doctor uses a temporary chart-room config directory to contain automatic schema
materialization. It resolves the current official profile token in memory and
passes it only in the child environment, with an empty diagnostic Omni config
path; no token is copied to disk or an argv. This avoids an OAuth auto-refresh
writing to the user's config. Expired credentials are an explicit failure for the
user to refresh with official tooling. Doctor installs nothing and mutates no
remote documents, permissions, configuration, or models.

A health check cannot prove API publication merely from browser login, whoami,
model permissions or content read access. Test publication through chart-room,
including draft/published readback, supplies that evidence. Target checks reject
PR-required publishing rather than bypassing it. Setup cannot mint credentials,
grant roles or enable AccessBoost. CI `OMNI_DASHBOARD_DEPLOY_TOKEN` stays separate
from personal auth; the plugin never configures CI secrets.

## Evidence boundaries

| Evidence | Proves | Does not prove |
|---|---|---|
| `VALIDATED` | The source satisfies the native schema and local invariants. | A query ran or a chart is visible. |
| `REMOTE_VALIDATED` / `PLAN_VALIDATED` | Omni accepted the query plan. | Returned data; retain `queryResultsVerified: false`. |
| Executed query and semantic checks | Actual results, grain, units and window for the recorded identity/view. | Layout, title visibility or control behavior in the browser. |
| `UPDATED`, `verified:true` | Draft and published content matched the requested definition. | Readable rendered charts or correct claims under changed controls. |
| Current browser observations | Visible content and behavior in the states actually inspected. | Other control states or queries the browser agent did not execute. |

**Schema-valid does not mean renders.** In the first live run, offline validation,
7/7 plan validations and verified publication all passed while charts were blank
whitespace. Expansion now checks one representative tile before authoring the rest;
iteration checks every tile and filter-conditional claim. Follow the
[cookbook](authoring-cookbook.md) and [structured handoff](phase-handoff.md).

## Completion ledger

Every skill prints every phase in order, including phases never reached, using
DONE, SKIPPED or FAILED and a concrete reason for **each** row. Restate incomplete
phases and next steps beneath the table. Check actual observations, not intentions.
The report helper validates these phase lists:

- Create: preflight, intent, model, structure, initialize, metadata, expand, iterate.
- Expand: preflight, intent, inventory, queries, gaps, author, test, iterate.
- Iterate: preflight, context, browser, query-health, gemini, acceptance, report, merge-route.
- Setup: preflight, dependencies, credentials, verification.
- Doctor: preflight, diagnostics.

If create never invokes expand, explicitly say expansion did not run, iteration
was skipped, and no Gemini evaluation/report exists. If a handoff failed, its row
is FAILED and downstream unattempted rows are SKIPPED with the dependency reason.
User-requested stopping is SKIPPED, not a silent disappearance of phases.

A rating below 7 at the pass limit is NOT PASSED. Unavailable Gemini, malformed
output, failed/unrun queries or stale screenshots never yield an accepted score.
An acceptance prompt is PENDING until the user responds. Generate a partial HTML
report on failure when a source exists, showing failed and skipped phases. Before
initialization, report the ledger directly because no dashboard artifact exists yet.

## Publication boundary

Creating an approved new pair publishes its initial documents immediately. This
is a provisioning decision, not a routine production update. After initialization,
all local updates use `chart-room test`. A successful review ends with a source PR
and the consuming repository's merge-to-deploy route. Do not upload to production
as a shortcut or claim Evergreen CI acceptance from local tests.

PR posting is a visible side effect: `chart-room comment FILE` posts/upserts a
provider-specific comment. Only run it if the invoked workflow explicitly requests
posting; name that step before running it and return its URL. Writing an HTML
report or preparing a PR description does not authorize posting a comment.
