# Review artifacts and independent evaluation

Keep each session outside the repository in a private directory. Save source
snapshots, browser observations, screenshots and Gemini responses by pass. The
report is a single HTML file with embedded screenshots, escaped text, no external
assets or scripts. It is an internal artifact, not a public publication target.

The evaluator sends only screenshots, intent/audience/questions/scope, the
allowlisted question-status context below and the active view to Gemini.
Establish organizational permission for that scope; never attach
raw query exports. `--approved-screenshots` records the caller's confirmation of
that prerequisite; it does not discover policy automatically. Installed llm uses
`--no-log` so dashboard prompts are not also stored in its global conversation log.

## Browser evidence

Write `pass-1/browser.json` after matching real browser observations with actual
query evidence. Compute `definition_sha256` from the exact source bytes (for example
Python hashlib); copy those bytes to `pass-1/source.omni.jsonc`. Do not reformat the
snapshot after hashing. This example contains illustrative values, not executed
query evidence:

```json
{
  "url": "https://zip.omniapp.co/dashboards/ACTUAL_TEST_ID",
  "definition_sha256": "SHA256_OF_SOURCE",
  "publication_verified": true,
  "publication_evidence": "chart-room test result and published readback identifier/time",
  "loading_complete": true,
  "visible_errors": [],
  "query_health": "PASS",
  "viewport": {"width": 1440, "height": 1000},
  "filters": {"business_region": "current selected value"},
  "time_window": "Actual fixed bounds used for this pass",
  "timezone": "America/Los_Angeles",
  "control_checks": ["Control changed the observed data and was restored"],
  "tools": ["Actual discovered MCP tool names"],
  "tiles": {
    "1": {
      "status": "ready",
      "query_executed": true,
      "query_evidence": "Actual request/digest, row count and semantic checks",
      "observed_at": "ISO timestamp"
    }
  },
  "sections": [{"id": "overview", "screenshot": "overview.png"}]
}
```

`tiles` keys must equal **exactly** the query/sql/linked record keys in
`document.queryPresentations.data`. Exclude blank tiles entirely: including one is
a hard failure, as is an extra, omitted or stale data key. For example, with tile
`1` query, `2` blank and `3` linked, evidence keys must be `["1", "3"]`.

`sections` IDs must equal **exactly** `_meta.sections` IDs, each once. If metadata
has `overview` and `detail`, supply exactly those two captures; an extra overview
image can be a supporting file but must not invent a third section. Splitting or
renaming a section changes the source digest and screenshot set: update metadata
and recapture/re-evaluate instead of reusing a prior pass. Capture all pages/tabs
and use the same 1440×1000 viewport. An `expected_empty` tile additionally needs `empty_reason`
and `empty_accepted: true`. Never mark an unresolved missing measure as expected
empty. The gate rejects broken queries, stale source hashes, wrong URLs and missing
screenshots before calling Gemini. The helper validates evidence consistency; it
cannot establish truth of manually authored observations.

Use `control_checks` for concise actual states, mapped/excluded/implicit tile IDs,
expected versus observed changes, on-page claims checked and restoration evidence.
Retain card/body and canvas dimensions, console findings and the privacy sweep in
the private browser artifact. These observations support the browser checklist;
the helper does not execute it or infer interactive correctness from a screenshot.

## Question-status context

Keep `_meta.questions` as the existing 3–5 strings. If supplied,
`_meta.question_status` must contain each exact question string once, with status
`backed`, `partial` or `blocked` and a nonempty `reason`. Example:

```json
{
  "questions": ["How much?", "When?", "Which group?"],
  "question_status": [
    {"question": "How much?", "status": "backed", "reason": "Verified aggregate count."},
    {"question": "When?", "status": "partial", "reason": "Only the current month is available.", "limitation_accepted": true, "acceptance_reason": "Owner explicitly chose a current-month view while historical data is repaired."},
    {"question": "Which group?", "status": "blocked", "reason": "No owned group mapping exists.", "limitation_accepted": false}
  ]
}
```

Do not copy the illustrative acceptance decision. Set `limitation_accepted:true`
only for partial/blocked questions with the user's actual decision recorded in
`acceptance_reason`; it is distinct from final dashboard acceptance. Optional
owner/discovery/raw evidence keys are not sent. Only `question`, `status`, `reason`,
`limitation_accepted` and, when accepted, `acceptance_reason` reach Gemini. Keep
these summaries within the agreed sharing scope. Missing question-status metadata
is supported for older sources but is sent as **unassessed**, never as an accepted
limitation. Malformed, duplicated or stale question mappings stop evaluation.

Gemini judges how clearly accepted limitations and next steps are presented,
alongside the backed content's usefulness. It still penalizes hidden gaps,
misleading claims and unaccepted shortcomings. Query-health, current-source and
screenshot integrity, rating threshold and final user-acceptance gates are unchanged.

Run a pass:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review.py" evaluate \
  --definition "path/to/dashboard.omni.jsonc" \
  --evidence "SESSION/pass-1/browser.json" --out "SESSION/pass-1/gemini" \
  --approved-screenshots
```

Output: `prompt.txt`, `gemini-output.txt`, `screenshots/*.png`, `evaluation.json`
(or `failure.json`).
Gemini returns a finite numeric rating 1–10, summary, and up to five suggestions
with unique `id`, `suggestion`, `action`. Malformed output stops evaluation with
no fallback rating. Each pass directory is new, so a failure cannot reuse an old
successful evaluation. The helper bounds a call to 60 seconds; a timeout stops
with no rating and can be retried only as a new explicitly diagnosed attempt.

Before calling Gemini, the helper reads each PNG once, hashes those bytes and
writes a private read-only copy under `screenshots/` in the new evaluation
directory. Only these copies are attached to llm. Each `evaluation.json`
`screenshots` record binds the section `id`, original `screenshot` path,
evaluation-relative `attachment` path and byte-level `sha256`. Source and browser
JSON hashes remain separate. A recapture during the call cannot replace the
submitted pixels, and changed/missing originals or copies after the call produce
`STALE_EVIDENCE` with no accepted evaluation.

Reporting verifies every section's original and submitted copy against the stored
digest, then embeds those verified copy bytes without rereading the image paths.
Changed, missing or substituted PNGs invalidate the pass even when browser JSON
is unchanged. Preserve the whole pass directory when moving a session; paths
inside the manifest are relative. Evaluations made before screenshot digests were
recorded are rejected and need a new evaluation; do not fill in hashes afterward.

## HTML report input

`session.json` records the workflow, paths relative to its own directory, versions,
all phase outcomes and acceptance. `definition` is the absolute current local path.
`passes` contains only valid completed Gemini evaluations; failed attempts go in
`failures` with their artifact paths/reasons. Set `resolved: true` only after a
new successful observation resolves a prior failure; unresolved failures prevent
acceptance even if an older pass scored well. No valid pass means an incomplete
report, not zero or an invented rating.

```json
{
  "workflow": "iterate",
  "definition": "/absolute/path/to/dashboard.omni.jsonc",
  "versions": {"chart_room": "actual tested version", "omni": "1.3.1", "contract": 1, "llm": "actual version", "gemini_model": "actual model"},
  "passes": [{
    "definition": "pass-1/source.omni.jsonc",
    "evidence": "pass-1/browser.json",
    "evaluation": "pass-1/gemini/evaluation.json",
    "decisions": [{"id": "s1", "status": "DECLINED", "reason": "Concrete reason this suggestion was not applied"}]
  }],
  "acceptance": {"status": "PENDING", "reason": "Awaiting the user's response"},
  "gaps": [],
  "failures": [],
  "merge_route": "Owned source PR, then consuming repo deployment after merge; activation separately verified",
  "pr_url": null,
  "ledger": [
    {"phase": "preflight", "status": "DONE", "reason": "Actual diagnostic result"},
    {"phase": "context", "status": "DONE", "reason": "Intent and directions recorded"},
    {"phase": "browser", "status": "DONE", "reason": "Actual exact-URL evidence"},
    {"phase": "query-health", "status": "DONE", "reason": "Actual per-tile execution evidence"},
    {"phase": "gemini", "status": "DONE", "reason": "Actual final rating at least 7, linked to current source"},
    {"phase": "acceptance", "status": "SKIPPED", "reason": "Awaiting response"},
    {"phase": "report", "status": "DONE", "reason": "This report generated successfully"},
    {"phase": "merge-route", "status": "DONE", "reason": "Reviewed the current deployment route"}
  ]
}
```

Adapt the example to what actually happened. A `DONE` Gemini row without a valid
current rating of at least 7 is rejected. List every suggestion APPLIED or DECLINED
with a reason. Preserve filters/time between passes or record `view_change_reason`.
APPLIED suggestions need a subsequent test publication and independent rating for
the changed revision. A stale final source hash cannot pass. If the loop reaches
its limit below 7, set the Gemini phase FAILED. Acceptance remains independent.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review.py" report --session "SESSION/session.json"
```

The report links test/prod, local source and PR if supplied. Give the user its local
path. It can show a visual pass while acceptance or another phase remains incomplete.
User acceptance below 7 never changes NOT PASSED. A report prepared while acceptance
is pending must be regenerated with the user's actual response. Partial reports
on query/Gemini failure still include the complete ledger, failure reasons, links
and any earlier verified passes; unscored screenshots can be referenced in failures.
