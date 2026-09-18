# Review artifacts and independent evaluation

Keep each session outside the repository in a private directory. Save source
snapshots, browser observations, screenshots and Gemini responses by pass. The
report is a single HTML file with embedded screenshots, escaped text, no external
assets or scripts. It is an internal artifact, not a public publication target.

The evaluator sends only screenshots, intent/audience/questions/scope and the active
view to Gemini. Establish organizational permission for that scope; never attach
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

Tiles must cover every query/sql/linked tile. Blank notes do not need data evidence.
Screenshots must cover every `_meta.sections` ID; capture all pages/tabs and use the
same 1440×1000 viewport. An `expected_empty` tile additionally needs `empty_reason`
and `empty_accepted: true`. Never mark an unresolved missing measure as expected
empty. The gate rejects broken queries, stale source hashes, wrong URLs and missing
screenshots before calling Gemini. The helper validates evidence consistency; it
cannot establish truth of manually authored observations.

Run a pass:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review.py" evaluate \
  --definition "path/to/dashboard.omni.jsonc" \
  --evidence "SESSION/pass-1/browser.json" --out "SESSION/pass-1/gemini" \
  --approved-screenshots
```

Output: `prompt.txt`, `gemini-output.txt`, `evaluation.json` (or `failure.json`).
Gemini returns a finite numeric rating 1–10, summary, and up to five suggestions
with unique `id`, `suggestion`, `action`. Malformed output stops evaluation with
no fallback rating. Each pass directory is new, so a failure cannot reuse an old
successful evaluation. The helper bounds a call to 60 seconds; a timeout stops
with no rating and can be retried only as a new explicitly diagnosed attempt.

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
