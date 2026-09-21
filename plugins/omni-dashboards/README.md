# omni-dashboards

Create, expand and review Omni dashboards with intent discovery, executed query
evidence, chart-room test publication and independent Gemini screenshot review.
Each skill reports a completion ledger. Iteration produces a self-contained HTML
report and ends at a reviewed merge-to-deploy route.

**Implementation status:** packaged for Claude Code, with offline regression tests.
Schema compatibility was verified on 2026-09-18 against the checksum-matched
chart-room v1.10.2 release executable, including the upstream review fixes.
The [first live-run feedback](FEEDBACK-first-live-run.md) reports a completed real
dashboard and final independent rating of 9/10, with substantial authoring/review
rework. The follow-up adds reference shapes and earlier rendering checks; live
acceptance of this revised workflow remains pending. See [ACCEPTANCE.md](ACCEPTANCE.md)
for historical evidence, current checks and remaining upstream release work.

## Install

To install from a local repository checkout, run from its root:

```bash
claude plugin marketplace add "$PWD"
claude plugin install omni-dashboards@bradys-marketplace
```

If the marketplace is already registered from GitHub, use this isolated local
plugin load while reviewing local changes:

```bash
claude --plugin-dir "$PWD/plugins/omni-dashboards"
```

To install or refresh the published plugin from GitHub:

```bash
claude plugin marketplace add brady-zip/bradys-marketplace
claude plugin marketplace update bradys-marketplace
claude plugin install omni-dashboards@bradys-marketplace
```

Restart Claude Code after installation/update. No Omni API MCP is required. The
bundled browser MCP matches the existing marketplace browser setup: mise, Node 22,
`chrome-devtools-mcp@latest --autoConnect --channel=beta`. It attaches to your
existing authenticated Chrome Beta. The browser agent recognizes capabilities
under different MCP namespaces; a process check alone does not prove attachment.

## Setup and diagnose

In Claude Code:

```text
/omni-dashboards:setup
/omni-dashboards:doctor
```

Or from the marketplace checkout:

```bash
bash plugins/omni-dashboards/scripts/setup.sh --install
bash plugins/omni-dashboards/scripts/check-setup.sh --profile zip-omni
bash plugins/omni-dashboards/scripts/check-setup.sh --offline
bash plugins/omni-dashboards/scripts/check-setup.sh --profile zip-omni --smoke
```

Scripts require Python 3.9 or later and use only the standard library.
Setup can install ordinary dependencies. Official Omni CLI 1.3.1 is installed from
its checksum-verified macOS release; an existing different CLI is not overwritten.
It preserves installed llm plugins and uses persistent llm with llm-gemini. It
installs mise/Node 22 as needed. Chart-room must be a **released** Omni-capable
1.10.2+ build whose native schema matches [dependencies.json](knowledge/dependencies.json).
Its presence or version string alone is insufficient. The exact schema content is
hashed using sorted, compact UTF-8 JSON so generator escaping/formatting does not
create a false mismatch. Schema changes require a deliberate compatibility update.
The tested release asset and its checksum are also recorded in the dependency
file so the separate compatibility check can exercise the actual binary.
Version 1.10.1 includes the filter-clearing, completion and machine-output fixes.
Its schema retains the v1.10.0 `$id` and content; both are still checked exactly.

Credentials are entered by the user through official tooling in their own terminal:

```bash
omni config init --name zip-omni --endpoint https://zip.omniapp.co
llm keys set gemini
```

Do not paste tokens into the assistant or pass token flags. The pinned Omni CLI
supports official config initialization, not a top-level login command. The user
may also run `setup.sh --configure-auth --profile zip-omni` interactively; it delegates
to that CLI. Securely injected `OMNI_API_TOKEN` is supported instead of a profile.
Use the same selected auth source throughout a session. The sole credential store
is Omni's official config (and llm's own Gemini keystore); no plugin `.env` is
created. Config path overrides supported by the CLI remain supported.

Doctor installs nothing and does not mutate configuration, dashboards or permissions.
It snapshots the selected profile's current credential in memory for diagnostic
calls; expired credentials are reported instead of automatically refreshed. Probe
failures are distinct from probes that could not run. Raw API error bodies and
tokens are not printed. `--smoke` makes a tiny billable Gemini API call without
internal dashboard content; iteration always includes a smoke check.

API identity, model permissions, target read access and publishing are separate
gates. Being signed into the website does not establish API publishing authority.
Setup cannot mint credentials, grant roles, enable AccessBoost or change Omni
publication policy. Personal auth is separate from CI's deployment credential.

## Workflows

```text
/omni-dashboards:create-dashboard Weekly revenue performance
/omni-dashboards:expand-dashboard path/to/revenue.omni.jsonc
/omni-dashboards:iterate-dashboard path/to/revenue.omni.jsonc
/omni-dashboards:doctor path/to/revenue.omni.jsonc
```

Create records 3–5 questions, audience, scope and owner; selects an existing model
and topic; agrees on grain, dates/timezone, filters and sections; initializes or
imports through chart-room; records `_meta`; and explicitly invokes expand.
New-pair provisioning publishes its initial documents immediately, so the exact
model and prod/test folders must already be approved before running it.

Expand inventories semantic fields and existing tiles, executes bounded queries,
records unanswered questions and first authors one representative backed tile.
It publishes that tile to test and verifies visible rendering through the browser
agent before completing the remaining content and invoking iterate. Missing data
or semantic work becomes a concrete owner handoff, not a model/schema edit or a
plausible-looking empty tile.

Iterate verifies the exact test hostname/ID, actual loading/error/empty states,
control behavior and query evidence, then captures every section. The installed
Gemini model evaluates intent, hierarchy, readability, density, comparability and
labeling. Changes go through the source and `chart-room test`. Default exit is a
healthy rating ≥7 or five completed passes; reaching five below 7 is **not a pass**.
Unavailable Gemini or malformed ratings stop evaluation without an author score.
User acceptance remains a separate recorded decision.

Every skill runs preflight on every invocation. The completion ledger contains
DONE, SKIPPED or FAILED and a reason for every phase. If create cannot invoke
expand, it explicitly reports both the missing expansion and skipped iteration.
Read the [workflow contract](knowledge/workflow-contract.md) for deferred probes
and the distinction between dependency health and completed work.

Create, expand and iterate read/write a private [structured handoff](knowledge/phase-handoff.md)
containing the source digest, selected auth, targets, decisions and evidence. The
browser agent checks geometry, lazy charts, expected values and claims under each
tested control state. Gemini receives recorded question status so accepted data
limitations are evaluated for clarity; hidden gaps and broken tiles remain defects.

## Authoring commands

These require approved real IDs discovered through Omni, not example identifiers:

```bash
omni documents v2-create --schema
omni query run --help
omni query run --schema
omni --base-url https://zip.omniapp.co --format json --profile zip-omni whoami whoami
chart-room omni models --profile zip-omni --format json
chart-room omni topics --model MODEL_UUID --profile zip-omni --format json
chart-room omni fields --model MODEL_UUID --topic TOPIC_NAME --profile zip-omni --format json
chart-room init "path/to/revenue.omni.jsonc" --provider omni \
  --model MODEL_UUID --prod-folder PROD_FOLDER_UUID --test-folder TEST_FOLDER_UUID \
  --instance https://zip.omniapp.co --profile zip-omni
chart-room validate "path/to/revenue.omni.jsonc"
chart-room validate "path/to/revenue.omni.jsonc" --remote --profile zip-omni
chart-room test "path/to/revenue.omni.jsonc" --profile zip-omni --format json
chart-room status "path/to/revenue.omni.jsonc" --profile zip-omni --json
```

Use existing semantic measures, stable tile/container keys and native `visConfig`,
`resultConfig`, controls and containers validated by the pinned schema. Plan
validation is not executed-query evidence. Contract v1 supports blank/query/sql/linked
tiles; unsupported workbook-local models, uploads, apps and other dependent
resources are blockers. See [Omni reference](knowledge/omni-reference.md) and
[query evidence](knowledge/query-evidence.md).

Start with the [authoring cookbook](knowledge/authoring-cookbook.md) and
[reference definition](examples/reference.omni.jsonc). Copy the native shapes,
preserve your initialized targets and discover real model fields. The reference
is synthetic and offline validated; it is not a live dashboard acceptance receipt.
Generate scope sentences after control edits with
`python3 plugins/omni-dashboards/scripts/explain-controls.py FILE`.
The cookbook covers the released 1.10.2 `automaticVis` normalization and draft recovery.
Guarded draft discard and test dry-run remain upstream requests.

## Reports and deployment

Keep private review sessions outside source control, for example under
`~/.local/share/omni-dashboards/reviews/`. Follow organizational rules before
sending internal screenshots to Gemini; raw query exports are outside this review
scope. The helper uses llm's `--no-log` and records a private per-pass response.
See [review artifact shapes and commands](knowledge/review-artifacts.md).

The HTML report embeds all reviewed sections, exact ratings, applied/declined
suggestions, query-health evidence, tested versions, gaps and final acceptance.
It links test/prod, local definition and the PR when one exists. A failed run gets
an incomplete report and phase ledger. Each evaluation submits private screenshot
copies and records their hashes. Changed or missing captures/copies, stale source
or changed browser evidence cannot reuse an old rating. Reports embed the verified
evaluated bytes; older evaluations without image hashes require a new pass.

The next step after successful acceptance is an owned source change reviewed and
merged through the consuming repo's deployment route. The plugin never performs
an unsolicited direct production upload. Evergreen CI activation and deployment
acceptance are a separate workstream. PR posting (`chart-room comment FILE`) is
performed only if the invoked workflow explicitly requests it, and is announced.

## Maintainer checks

```bash
python3 -m unittest discover -s plugins/omni-dashboards/tests -v
claude plugin validate plugins/omni-dashboards --strict --json
claude plugin validate .claude-plugin/marketplace.json --strict --json
bash -n plugins/omni-dashboards/scripts/preflight.sh
bash -n plugins/omni-dashboards/scripts/check-setup.sh
bash -n plugins/omni-dashboards/scripts/setup.sh

# Separate offline interoperability gate: use the actual pinned release asset.
CHART_ROOM_NO_UPDATE=1 python3 plugins/omni-dashboards/tests/check_chart_room_compatibility.py \
  --binary "$(command -v chart-room)" \
  --source-schema ../chart-room/schema/omni-dashboard.schema.json
```

The shell tests use fake external executables and never query/publish real data.
They test auth/host/capability failures, inaccessible models/targets, policy and
draft conflicts, absent browsers, unavailable Gemini and deferred probes. Review
fixtures test broken queries, missing data, malformed ratings, stale screenshots,
skipped handoffs and report acceptance. Packaging tests verify metadata agreement,
portable references, workflow transitions and absence of legacy commands.
The compatibility check is separate from the fake-tool suite. It verifies the
recorded release asset checksum, runs the real version/help/schema preflight and
validates the authoring reference offline in a temporary config directory,
compares the optional source schema, and rejects a
changed native constraint. It downloads nothing, disables updates and makes no
authenticated or Gemini calls. Omit `--source-schema` when only the release binary
is available. Repeat it for any later chart-room artifact before updating
the tested release/schema pair.
Real create → expand → iterate acceptance must still be recorded separately.
