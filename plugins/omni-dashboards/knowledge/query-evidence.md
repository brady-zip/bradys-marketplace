# Evidence before tiles

Build a question → measure → query → tile matrix. Use semantic measures already
owned by the model where possible. Record the aggregation, grain, denominator,
null handling, timezone, units and refresh assumptions before choosing a visual.
A total of entity counts after a join is not automatically an entity count; verify
fanout and distinctness. A percentage needs a documented denominator and zero/null
behavior. Comparable series need the same window, grain and units.

| Observation | Classification | Action |
|---|---|---|
| Successful complete field/topic discovery lacks the requested field | NONEXISTENT_FIELD | Create an owner handoff with the question, desired definition and acceptance query; no invented tile. |
| 401 or expired credential | UNAUTHENTICATED | Stop discovery/query work; official credential refresh. Never interpret as an empty catalog. |
| 403, model omitted from resolved roles, or inaccessible shared model | MODEL_INACCESSIBLE | Ask the owner for appropriate access or an accessible existing model. |
| 404 on model/target | NOT_FOUND_OR_HIDDEN | Confirm identity and owner visibility before calling it nonexistent. |
| Successful bounded query returns no rows | EMPTY_DATA | Check actual window, timezone, filters, row-level access and refresh; record evidence. Do not invent a zero. |
| Nonzero query exit, timeout, malformed stream, FAILED job or incomplete footer | QUERY_FAILED / UNKNOWN | Record failure; stop visual acceptance for that tile; repair source or hand off. |
| Successful query plan/static inspection only | NOT_EXECUTED | Run a real bounded query before making a data claim. |

Raw error output can contain internal data; report sanitized status/reason and
request IDs. Save no tokens. A timeout is unknown health, not proof of a nonexistent
field. RLS can make valid data invisible to one identity; preserve the audience and
auth context without disclosing credentials.

## Bounded query procedure

1. Inspect installed `omni query run --help` and `--schema`. Use a known supported
   query shape from verified native content/discovery. Prefer actual shared-model
   field identifiers; never turn the illustrative metadata into a query.
2. Set a short representative date range, verified row limit, selected fields,
   filters and timezone. Bound scanning with filters, not just output size. Preserve
   the agreed grain and leave `planOnly` false. The default NDJSON job stream needs
   complete job/footer checks; HTTP success alone does not mean the job completed.
   `resultType: "json"` can simplify successful rows but can hide a real error behind
   `Unable to parse data stream`. On that diagnostic, rerun the same bounded query
   without `resultType` to inspect the actual job/error stream; do not treat the
   wrapper error or the retry as success. Follow pinned response schemas.
   `chart-room validate --remote` supplies plan evidence only. Native filter/sort
   shapes and aggregation traps are in [the cookbook](authoring-cookbook.md).
3. Send the JSON via `--body @query.json` or `--body -` on stdin, with selected profile
   and fixed Zip base URL. Do not pass credentials or interpolate field content into
   shell commands. Do not enable warehouse refresh/rebuild operations for sampling.
4. Record start/end time, actual request/hash/identifier, success/failure, row count,
   window/grain, null coverage and expected invariant checks. Store minimal summaries,
   not full row exports. Verify existing tiles as well as additions.
5. Check whether the results actually answer a recorded question. Document gaps,
   never claim a query ran from inspection of the source file.

For a missing-data handoff include an accountable owner, question, discovered
model/topic, missing field/measure or failed upstream behavior, expected aggregation
and grain, denominator/null/timezone rules, minimal reproducible query and a concrete
acceptance condition. Do not edit their model/schema/instrumentation here. A file
prepared for the owner is not authorization to send them a message.

## Layout choices

Use KPIs for a meaningful headline with units/window, lines for continuous time
trends, sorted bars for category comparisons, and tables for precise investigation.
Choose readable native formatting and labeled axes. Make comparability explicit
with consistent units/scales; distinguish nulls from zero. Controls should reflect
business dimensions and audience decisions, with intentional date defaults.
Organize sections in the order the recorded questions should be answered.

Publication, executed data checks and rendered behavior are separate evidence.
Inspect loading/alerts/control behavior and query outcomes before Gemini sees the
screenshots. Blank pixels alone are not a query-health signal. A valid expected
empty state needs a confirmed reason, clear labeling and explicit acceptance.

## Claims under controls

Derive scope documentation from `controls.map` with `scripts/explain-controls.py`;
an absent entry is not the same as explicit `false`. Compare the headline, table
and chart scopes before claiming reconciliation. Re-read all titles, subtitles,
totals, denominator and "all teams" claims under each tested control state, then
restore and re-verify the original view. Record mapped and excluded tile behavior
and any state still unknown. Query correctness at rest does not establish truth
after a filter moves. Do not stack a total and its subset as additive measures.

For partial dashboards, record the question's status/reason and the user's actual
limitation decision in `_meta.question_status` (see `review-artifacts.md`). Display
that status and its implications on the page. Missing metrics remain missing;
accepting a question limitation never waives execution evidence for displayed tiles.
