---
name: create-data-source
description: Create a warehouse table or view and its scheduled pipeline for an Omni dashboard when existing data cannot answer the question. Use for Evergreen Snowflake/Airflow source changes, including missing-data handoffs from dashboard skills; does not provision Omni connections.
argument-hint: "[metric or source requirement] [--repo PATH] [--handoff PATH]"
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill
---

# Create an Omni dashboard data source

Read @${CLAUDE_PLUGIN_ROOT}/knowledge/data-source-authoring.md and
@${CLAUDE_PLUGIN_ROOT}/knowledge/phase-handoff.md. Implement the source in the
consuming repository, following its instructions and data-owner conventions.
This workflow produces warehouse SQL, pipeline wiring and acceptance evidence;
chart-room manages dashboard documents and cannot deploy these source changes.

## 1. Repository preflight and scope

Resolve `--repo PATH` or the current consuming checkout. Check repository identity,
branch, working changes, applicable instructions, ownership and available local
validation tools before editing. Reuse a supplied handoff's question, definition,
grain, target model/topic, auth selection and existing authorization.

Warehouse code authoring does not require chart-room, Omni credentials, a browser
or Gemini. Run dashboard preflight only before dependent Omni discovery/query work;
missing remote access does not prevent preparing and checking local source code.
If the checkout is missing, identify it before writing guessed files elsewhere.

An explicit request to create a source authorizes the necessary local SQL and DAG
changes. If a dashboard request already includes filling missing sources, continue
without asking again. A dashboard-only request supplies no authority for unrelated
shared-model, warehouse or instrumentation changes: prepare the concrete source
requirement and ask only for the additional scope needed. Reuse existing consent
for live actions; source authoring alone does not authorize executing replacement
DDL, triggering/backfilling production DAGs, publishing a shared model, or granting
access. Finish the reviewable local change before seeking any required live approval.

## 2. Establish the source contract

Record the business question, metric definition, accountable owner, source tables,
destination, row grain/key, dimensions, aggregation/denominator, null/deletion
behavior, date/timezone semantics, refresh expectation and acceptance query.
Inspect current application models/enums, exports and nearby SQL/DAG tasks. Verify
that an existing source cannot meet the requirement before duplicating it.

Separate missing warehouse data from a missing Omni topic/measure and from access
failures. If the table already exists, implement only the needed exposure using
the consuming repository's supported model workflow and authorized scope. A 403,
hidden resource or stale schema is not proof that a new table is needed.

## 3. Implement SQL and scheduling

Follow the Evergreen recipe in the reference when applicable: add the SQL file,
register its stem in `sql_queries`, add all verified upstreams to `dep_dict`, and
update the data DAG inventory and its plugin version when required by that repo.
Use the actual owning pipeline for other domains; not every source belongs in
`core_dashboards`. Preserve unrelated work, grants and existing downstream contracts.

Validate enum mappings against source definitions, current-versus-event semantics,
deletions and join fanout. Reuse existing upstream readiness sensors where suitable;
do not add a dated-table sensor for an unpartitioned export. The reference PR is
an example, not permission to copy its business rules to another metric.

## 4. Validate code and data separately

Run relevant repository SQL/style checks and local DAG import/graph checks when
available. Confirm SQL filename/task identity, destination/connection, valid
upstream IDs and no dependency cycles. Inspect the diff and add focused semantic
checks for the new grain and counts. Record checks that could not run honestly.

Where warehouse read access exists, run bounded acceptance SELECTs with explicit
dates, organization scope and timeout. Compare aggregates to source counts and
test uniqueness, nulls, enums, deletions and join fanout. Do not execute a file
containing `CREATE OR REPLACE` to get sample results: use a bounded SELECT of the
transform. Keep sanitized query IDs, timestamps and invariant summaries private.
Local lint/import or a SELECT of the transform cannot prove scheduled table creation.

## 5. Deployment and Omni exposure

Prepare the source change for the consuming repository's review/deployment route;
commit, push and PR creation follow the user's requested delivery scope. If live
deployment is authorized, follow that repo's current runbook and verify the actual
task run, destination schema, refresh and grants. Otherwise record deployment as
pending and provide the concrete next action. Do not substitute manual DDL for
the reviewed scheduled pipeline.

After the table exists, verify the selected Omni connection/model can read it.
Use the supported schema-refresh and model/topic workflow in that environment;
inspect CLI help/schema and repository model-sync rules before a mutation. Preserve
RLS and model ownership. A warehouse table is not automatically an Omni topic.
New connection provisioning or customer embedded-analytics export changes need
their own supported workflow; this internal-table recipe does not implement them.

Rediscover actual topics/fields and execute a bounded Omni acceptance query using
the selected profile. First run the selected-context diagnostic:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill expand --profile PROFILE --model MODEL_UUID
```

Omit `--profile` consistently for environment-token auth. Resolve required model
checks before discovery/execution; document/target checks can remain deferred for
source-only work. For an aggregate count column, normally use a sum of that
column; counting aggregate rows measures buckets. Verify the discovered measure's
definition before using it. Mark dashboard readiness only after Omni execution
matches the contract. Plans and schema refresh alone are insufficient.

## 6. Return evidence and resume

Update the private handoff's `data_sources` record as described in the reference.
Bind code evidence to the repository revision and SQL digest; keep warehouse and
Omni evidence separate. Do not mark the dashboard question backed until actual
Omni execution succeeds. If a dashboard phase invoked this skill, return to that
caller with the result; do not recursively invoke it. For a standalone request,
give the resume command for create/expand when a dashboard was requested and its
source is ready. Pending deployment remains an explicit blocker for dependent tiles.

Always print this ledger with DONE, SKIPPED or FAILED and evidence/reason in each
row, including unreached phases. Link the changed files and PR if one exists;
state independently whether code is ready, the table is deployed, and Omni can
query it. No screenshot review is required for source-only work.

| Phase | Status | Reason / evidence |
|---|---|---|
| repository | | |
| contract | | |
| sql | | |
| pipeline | | |
| local-validation | | |
| warehouse-validation | | |
| deployment | | |
| omni-exposure | | |
| resume | | |
