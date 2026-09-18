# Omni contract v1 authoring reference

The interoperability source is Evergreen's `bin/ci/omni_dashboards/handoffs/contract.md`,
`chart-room-handoff.md`, and `deployment.md` (read 2026-09-17). The implementation
pins are machine-readable in [dependencies.json](dependencies.json). chart-room
1.10.1 is the minimum accepted version. On 2026-09-18 the actual v1.10.1
release executable passed schema compatibility against commit
`66c29d7cde1c5585b43ddb554fd3dd7c4a405837`. It includes the filter-clearing,
completion and machine-output review fixes. Its schema and v1.10.0 `$id` are
unchanged from release v1.10.0, which added
`QueryPresentationsPatchExternal.properties.data.minProperties: 1` to the earlier
candidate, requiring at least one tile record. Native schemas remain exactly
pinned; version alone never establishes compatibility. See
[acceptance evidence](../ACCEPTANCE.md) for the artifact checksum and remaining
live workflow gates.

Official sources:

- [Omni CLI v1.3.1](https://github.com/exploreomni/cli/releases/tag/v1.3.1) and its
  [OpenAPI](https://github.com/exploreomni/cli/blob/v1.3.1/api/openapi.json).
- [chart-room](https://github.com/brady-zip/chart-room) and expected versioned
  [Omni schema](https://raw.githubusercontent.com/brady-zip/chart-room/v1.10.0/schema/omni-dashboard.schema.json).
- [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp).
- [LLM usage and attachments](https://llm.datasette.io/en/stable/usage.html) and
  [llm-gemini](https://github.com/simonw/llm-gemini).

Do not infer command availability from newer Omni agent-skill docs. Probe the
installed pinned CLI with `--help` and `--schema` **offline** first. CLI 1.3.1
advertises `omni config init`; it has no top-level login command.

## Source envelope

Use `<name>.omni.jsonc` beside its owning domain with normal CODEOWNER coverage.
Chart-room stamps the versioned `$schema`. Contract v1 has `version: 1`,
`provider: "omni"`, `instance: "https://zip.omniapp.co"`, distinct provisioned
`targets.prod`/`targets.test`, `_meta`, and native `document`.

All seven document fields are required: `name`, `description`, `modelId`,
`queryPresentations`, `controls`, `settings`, `containers`. Chart-room creates the
initial structure. Let its pinned native schema validate `visConfig`, `resultConfig`,
controls and containers; never replace them with a universal widget grammar or
untyped objects to make validation green. This plugin does not vendor a second
native schema which could drift from chart-room and deployment.

Metadata example (merge into an initialized definition; this is not a dashboard):

```json
{
  "intent": "Understand conversion, revenue and where the funnel loses customers.",
  "audience": "Revenue operations reviewing the weekly pipeline",
  "scope": "The selected shared model and verified opportunity topic",
  "questions": ["How is conversion trending?", "Which segment drives revenue?", "Where do opportunities stall?"],
  "owner": "The accountable domain owner selected by the user",
  "model_id": "the discovered shared model UUID",
  "topic": "the discovered topic name",
  "grain": "One opportunity, aggregated by completed week",
  "time_window": "Last 12 completed weeks",
  "timezone": "America/Los_Angeles",
  "filters": {"business_region": "All permitted regions"},
  "refresh_assumptions": "Record the verified upstream refresh and query-cache expectations",
  "sections": [{"id": "overview", "title": "Overview", "questions": [0, 1, 2]}],
  "gemini_stop_limit": 5
}
```

The required intent/audience/scope values are nonempty **strings**, not arrays or
objects. Additional fields hold structured questions/evidence. Do not record
secrets or raw customer exports in metadata. Definitions/limitations also belong
in visible descriptions when they help readers interpret a metric.

Supported tiles: `blank`, `query`, `sql`, and `linked`. Keep stable numeric tile
record keys, exact tile/control sets and ordering, stable container `instanceKey`
values, and all five native settings. Remove a key to delete it; do not author
null deletion tombstones. Linked tiles need their supported source dependencies.
The schema must preserve native visualization configuration through publication.

Unsupported: apps, base-model changes, branch/draft-bound query models, workbook-local
semantic extensions, uploads, foreign tabs, dataset/dbt/query-view edits and query
binding changes. Keep unsupported existing content in Omni and hand its migration
to the owner. Do not flatten it, silently omit it, change shared models, or claim
that arbitrary workbook exports are portable dashboards.

## Official command surfaces

Always select `--base-url https://zip.omniapp.co --format json`; add the chosen
`--profile NAME`, or consistently use securely injected `OMNI_API_TOKEN`.
Credentials are never command arguments. JSON bodies use stdin or a local body file,
never shell strings assembled from dashboard text.

```bash
omni documents --help
omni documents v2-create --schema
omni query run --help
omni query run --schema
omni whoami whoami --help
omni config init --help
omni --base-url https://zip.omniapp.co --format json --profile PROFILE whoami whoami
omni --base-url https://zip.omniapp.co --format json --profile PROFILE whoami whoami --model-id MODEL_UUID
omni --base-url https://zip.omniapp.co --format json --profile PROFILE models list-topics MODEL_UUID
omni --base-url https://zip.omniapp.co --format json --profile PROFILE models get-topic MODEL_UUID TOPIC_NAME
```

Use `omni models list` and `omni folders list` with explicit pagination; read their
help/schema for selectors and permissions. File operations go through chart-room:
`validate` (offline), `validate --remote` (query plans), `test` (publish test),
`status --json` (target/draft/drift evidence). Every one uses the definition's
instance and selected profile. Status IDs alone are not successful publication.

The native Documents v2 transport creates published content, reads published state,
creates/patches a main draft, reads the specific draft and publishes it. Chart-room
owns reconciliation: upsert tiles in batches of at most 48, replace layout/controls/
settings, delete removed tiles in batches, set order, verify draft and published
readback. Do not implement a parallel publisher in this plugin. It must refuse
pre-existing drafts, unsupported resources and PR-required targets. A timeout may
mean the write succeeded; preserve recovery IDs and inspect before any retry.

## Deployment route and limits

Evergreen tracks definitions anywhere in its repository. CI validates the full
inventory on PRs and reconciles production on relevant master pushes, using
`OMNI_DASHBOARD_DEPLOY_TOKEN` only as an environment secret. Definitions and Git
are never rewritten by deployment. Codeowners/review and production credential
activation belong to the deployment workstream. As of the source runbook, no
live deployment was accepted; recheck its current status before onboarding.

Test titles get `[TEST]` and descriptions link production. Production provenance
uses the exact checked-out commit/file permalink. These are generated transforms,
not text to accumulate in canonical source. A dirty preview must not claim exact
commit identity. Preserve name/description limits after added provenance.

Use a reviewed Git revert to restore desired content to the same production ID.
Deleting a definition stops management and does not delete the remote dashboard.
No API compare-and-swap lock exists in this contract: avoid concurrent UI edits
while chart-room or deployment owns the content.
