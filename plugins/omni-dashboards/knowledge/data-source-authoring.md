# Warehouse sources for Omni dashboards

## Evergreen reference pattern

Reviewed on 2026-09-29: [Evergreen PR #135308](https://github.com/Greenbax/evergreen/pull/135308/changes),
head `efa46fb27d922073b5ee719cc08e4f817338b931`. It adds
`dime.core_dashboards.risk_findings_created_daily` from
`admincoin.objects.risk_finding_current`. It changes warehouse SQL and Airflow
registration, plus the data-team skill inventory/version. It does **not** add an
Omni connection, model/topic or dashboard, or prove that the table was deployed.
Recheck the consuming checkout before using these paths or business rules.

| Artifact | Change |
|---|---|
| `airflow/dags/core_data/core_dashboards/sql/<name>.sql` | Define the destination table and transform. |
| `airflow/dags/core_data/core_dashboards/core_dashboards.py` | Register `<name>` in `sql_queries` and wire its upstreams in `dep_dict`. |
| `.agents/team/data/skills/data-dags/SKILL.md` | Add the task/file/output meaning to the owning DAG inventory when present. |
| `.agents/team/data/.claude-plugin/plugin.json` | Follow the consuming repo's version rule when updating its packaged skill. |

At that revision the SQL registration loop creates `SnowflakeOperator` tasks with
`task_id=q`, `sql=f"sql/{q}.sql"`, `snowflake_conn_id="snowflake_default"`, and
`database="dime"`. `dep_dict` is applied via `dag.set_dependency(task, downstream)`.
Adding only a SQL file leaves it unscheduled; registering it without readiness
dependencies can consume stale inputs.

The PR uses `"risk_findings_created_daily": ["wf_db_export"]`. The existing
`wf_db_export` is an `ExternalTaskSensor` waiting on `db_exports_import` /
`send_complete_emails`. Reuse this for sources actually covered by that export;
derived dimensions or other imports need their own existing upstream tasks too.
Some current-object exports lack `ds` partitions: check before using
`SnowflakeDatedTableSensor`, which would otherwise wait indefinitely.

## SQL and metric semantics

The reference transform uses `CREATE OR REPLACE TABLE ... COPY GRANTS AS SELECT`.
For an existing table, `COPY GRANTS` preserves applicable grants during replacement;
it does not grant first-time access to a new table. Check the actual warehouse role,
schema grant conventions, ownership and Omni read access. Prefer the owning
pipeline's established table/view or stage/exchange pattern for other destinations.

The reference's grain is `(day, organization_guid, is_ai_generated, status)`:

- `day` is `created_at::DATE`; verify source timestamp type and date timezone for a
  new metric rather than assuming a UTC conversion occurred.
- AI generation is `source = 3`; this predicate can be null when `source` is null.
- Status codes 1–6 map to Open, Accepted, Not applicable, Mitigated, Resolved,
  Waived; every other code maps to Unknown.
- Only `object_status = 0` rows are counted; verify application/export enum meanings
  before applying the same exclusion to another object.
- `created` is `COUNT(*)` at the grain above, from a **current** object table.

These are counts by creation day and **current** status among retained objects.
A later status change can move an older day's counts between status buckets;
deletion can remove older counts. This does not measure findings created *in each
status at creation*, status-transition events, or immutable daily snapshots.
If those are the requested questions, use verified event/history data instead.
Do not silently invent a zero for absent days or null AI classifications.

For any source, write the grain and metric contract before SQL. Verify entity keys,
join cardinalities, filters, deletion policy, time conversion, late-arrival handling
and whether full rebuild, incremental refresh or snapshot semantics fit the need.
Use discovered application enums, not magic numbers borrowed from this example.
Preserve organization keys needed for filtering/tenant boundaries. An organization
column alone does not establish row-level access control.

## Acceptance checks

Use representative organizations and a finite date range. Derive concrete SELECTs
from the authored transform and verified columns; quote identifiers according to
Snowflake and the repository's conventions. Bound source scanning, not just output
rows. When the transform rebuilds all history, review expected production cost
separately from the bounded acceptance sample.

Check at least the invariants that apply to the source:

- Grain uniqueness: grouping the transform/destination by its grain has no key
  with multiple rows. Distinguish nullable dimensions from accidental duplication.
- Reconciliation: `SUM(created)` over the agreed scope equals the source entity
  count with identical date, organization and deletion filters.
- Slice semantics: enum/AI partitions reconcile, including Unknown/null buckets;
  joins do not multiply counts; date boundaries use the documented timezone.
- Freshness: source export completion, downstream task run and table contents
  reflect the intended refresh. A successful old run proves only that old revision.
- Access: the actual Omni connection role can read the new table under the intended
  audience/RLS context. Do not widen grants to bypass missing access.

Keep local code checks, executed warehouse SELECTs, scheduled destination creation,
Omni field discovery and executed Omni query results as separate gates. Record
query/task IDs and sanitized summaries, not customer rows or credentials in source.

## Exposing the table and returning to dashboards

A new Snowflake table may require schema refresh and owner-reviewed view/topic or
measure definitions in the existing shared model. Discover the supported workflow
from the consuming repository and installed Omni tooling. `chart-room`'s dashboard
contract does not publish warehouse SQL, connection settings or shared-model edits.
If model publishing is not in scope, prepare the exact exposure change/owner handoff
after completing the source code. Do not replace it with workbook-local extensions.

The data team's `data-dags` and `airflow-setup` skills may help when available in
Evergreen; read their local files rather than depending on this plugin installing
them. Customer embedded analytics and internal analytics use different export
paths; inspect the repository's embedded-analytics/data-sharing guidance for those
requests rather than copying the internal `dime.core_dashboards` pattern.

The returned private handoff can add a `data_sources` array with one record per
requirement: question, owner, repository path/revision, SQL path/digest, destination,
grain, metric semantics, task/upstreams, local checks, warehouse query evidence,
deployment state/run evidence, Omni model/topic/field evidence, and next action.
Record states as READY, PENDING or FAILED for code, deployment and Omni readiness
individually, each with a reason. Unknown facts stay null/pending. Before dashboard
initialization `definition`/targets may be unknown; use a source-only handoff rather
than inventing document IDs. When resuming, preserve and reconcile the dashboard
handoff's source/target/auth binding and invalidate affected prior query evidence.

Only mark a question backed after a successful bounded Omni query using real
discovered fields. For this aggregate-table pattern, the dashboard's count measure
must aggregate `created`, usually `SUM(created)`, rather than `COUNT(*)` of daily
buckets. Rediscover after exposure, then resume normal expansion and iteration.
