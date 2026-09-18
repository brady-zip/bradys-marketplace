# Create → expand → iterate handoff

Use one private `handoff.json` outside the repository, beside the review session.
Create its directory with mode 700 and file with mode 600. Each skill reads it on
entry and updates it before invoking the next skill, including after a failure.
Pass its absolute path as `--handoff PATH` alongside the definition path in Skill
arguments. This flag is a skill argument, not a chart-room CLI option. Prose adds
context; it does not replace these fields.

```json
{
  "version": 1,
  "definition": "/absolute/path/dashboard.omni.jsonc",
  "definition_sha256": "SHA256_OF_CURRENT_BYTES",
  "phase": "create",
  "auth": {"source": "profile", "profile": "SELECTED_PROFILE"},
  "instance": "https://zip.omniapp.co",
  "targets": {"prod": "ACTUAL_PROD_ID", "test": "ACTUAL_TEST_ID"},
  "model_id": "ACTUAL_MODEL_UUID",
  "topic": "DISCOVERED_TOPIC",
  "folders": {"prod": "APPROVED_FOLDER_UUID", "test": "APPROVED_FOLDER_UUID"},
  "owner": "Accountable owner",
  "grain": "Agreed grain and aggregation",
  "time_window": {"start_inclusive": "FIXED_START", "end_exclusive": "FIXED_END"},
  "timezone": "UTC",
  "filters": {},
  "measures": [{"field": "DISCOVERED_MEASURE", "definition": "Units, aggregation, denominator and null handling"}],
  "decisions": [{"decision": "User's actual decision", "reason": "Context", "evidence": "Message/time reference"}],
  "sharing": {"status": "UNKNOWN", "scope": "", "evidence": ""},
  "question_status": [],
  "query_evidence": {},
  "discovery_evidence": [],
  "gotchas": [],
  "representative_tile": {"status": "PENDING"},
  "publication": {"status": "PENDING"},
  "review_directory": "/absolute/private/session",
  "ledger": []
}
```

Copy targets, instance and model from the source; do not retype aliases. Preserve
profile selection throughout. Token auth is `{"source":"environment","profile":null}`;
never store a token, config contents or raw query export in this file. Use null and
a reason in `decisions` for facts still unknown (e.g. folders on adoption), not
invented IDs. `sharing.status` is UNKNOWN, PERMITTED or DENIED, with the exact
permitted screenshot/intent/question-status scope and decision evidence.

`question_status` mirrors `_meta.question_status` defined in `review-artifacts.md`;
`query_evidence` uses data tile keys with request/digest, execution time, row-count,
grain/range and health summaries. Store evidence paths relative to this handoff's
directory. Keep detailed query observations private. `discovery_evidence` and
`gotchas` carry verified resources and query-shape findings that prose used to lose.

At entry compare the absolute definition path, source digest, instance, model and
both targets with the file. A mismatch invalidates the handoff's publication,
query and rendering claims for the changed content; reconcile and rerun affected
checks before marking them current. Do not silently redirect work to another pair.
For direct expand/iterate invocation without a handoff, initialize it from current
source and supplied context; unknown evidence starts PENDING, not DONE. Ask only
for necessary missing decisions and reuse authorization already recorded.

Create records discovery, decisions and current metadata, then invokes expand.
Expand records per-tile execution, gaps and the representative check. A DONE
`representative_tile` includes tile ID, source hash, exact test URL, publication
evidence, observation timestamp and browser artifact path. It proves that earlier
source only; it is not the final dashboard review. After completing content, expand
updates the source digest, publication readback and complete ledger, then invokes
iterate. Iterate reads that context, verifies the current source, and records the
review session/report, final ledger and user's actual acceptance decision.

On failures keep identifiers and evidence paths, and record FAILED/SKIPPED with
the reason. Updating the handoff is not itself proof that a phase ran. Final
`browser.json`, evaluation digests and report checks remain authoritative for the
current review; a historical representative-tile success cannot bypass them.
