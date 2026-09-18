# Acceptance record — updated 2026-09-18

Status: plugin 260918.1; first live run reported complete; follow-up changes verified
offline; **revised-workflow live acceptance and upstream recovery work pending**.

## First-live-run follow-up

[FEEDBACK-first-live-run.md](FEEDBACK-first-live-run.md) reports the 2026-09-18 real
dashboard run, three failed publications, eleven browser inspections and a final
independent rating of 9/10. That is reported live evidence for the prior workflow;
the private source-bound report, screenshots and user's acceptance were not
re-executed or independently verified during this follow-up.

Plugin 260918.1 adds the cookbook and synthetic native reference,
representative-tile render check, standing browser checklist, generated control
scope, filter-conditional claim review, structured phase handoff, question-status
context for Gemini, and exact evidence-set documentation. Existing preflight,
executed-query, source/screenshot binding, rating and final acceptance gates remain.

All **53 stdlib tests passed in 33.852 seconds**. The installed chart-room 1.10.1
binary matched the recorded release SHA-256 and passed all five compatibility
checks, including offline validation of `examples/reference.omni.jsonc`. The
reference contains synthetic IDs/fields and has not been published or rendered as
a complete dashboard; copying live-derived shapes is not live acceptance.
No remote dashboard mutations or Gemini calls were made for these checks.
Both strict Claude manifest validations, Python/shell syntax, portable-reference
checks and `git diff --check` passed. All five skill frontmatters and the browser
agent YAML were checked. The generic Codex skill validator does not recognize
Claude's existing `argument-hint`; its common-field checks passed with that field
excluded in temporary copies, and the field's string shape was checked separately.

| Feedback / remaining gate | Current outcome |
|---|---|
| P0-1, P0-3, P0-4 | Cookbook/reference, one-tile browser check and explicit evidence boundaries implemented; revised live-run measurements pending. |
| P0-2 automaticVis | Existing upstream source patch confirmed locally. Released 1.10.1 still needs the documented echo workaround; accept a later release only after artifact/schema verification. |
| P0-2 retry recovery | Guarded named-draft discard and test dry-run are not available in verified 1.10.1 and remain chart-room work. Raw Omni discard acts on the current main draft and is not an automatic retry. |
| P1-1 through P1-5 | Browser checklist, conditional claims, programmatic control descriptions, accepted-limitation evaluator context and JSON handoff implemented; live behavior still requires exercise. |
| P2 evidence/layout | Exact tile/section coverage and recapture rules documented; height, title, subtitle and subset-stacking checks added to authoring/browser guidance. An upstream layout linter remains optional work. |
| Release efficiency | Track deliberate representative/final publications separately from failures/rework. A fresh multi-tile expansion now requires two intentional test publications; the original one-publication total target conflicts with the requested early check. Target zero failed publications and one or two ratings; verify inspection counts in a new run. |

The previous version/evidence record below is historical. Version 260918.1 is
recorded in both manifests for this source publication. No chart-room release,
plugin installation or remote dashboard publication was performed by this follow-up.

## Previous 260918.0 offline review

No Omni documents, folders, drafts, roles, policies, credentials or CI secrets were
created or changed during this review-fix work. No paid Gemini calls were made.
The reviewed plugin baseline is `d1955b1a4bcf41a42abbfefcdf198f7ac0587b96`;
these fixes are packaged as plugin version 260918.0.

## Local evidence

The reviewed baseline passed 36 stdlib tests. After these fixes and the v1.10.1
dependency update, all **46 tests** passed in **34.163 seconds** using
`python3 -m unittest discover -s plugins/omni-dashboards/tests -p 'test_*.py'`.
The new overwritten-screenshot regression was also run against the original
`review.py` in a temporary copy: it failed because the old code still returned
`ACCEPTED`. The fixed code rejects that same case.

Shell syntax, Python AST checks for seven script/test files, JSON parsing, both
strict Claude manifest validations, and the two-file metadata invariant passed.
Plugin version is 260918.0 in both manifests; shared metadata agrees. The five skills and browser
agent were not changed; their original frontmatter validation remains historical
evidence. These checks validate local behavior and packaging, not a live
agent/browser/warehouse session.

| Gate | Outcome | Evidence / limit |
|---|---|---|
| Claude plugin and marketplace manifests | DONE | Name, description, version 260918.0 and source registration agree; Claude manifest validation and stdlib checks. |
| Five entry skills and browser agent | DONE | Explicit create → expand → iterate handoffs, scoped preflight and phase ledgers; portable internal references. |
| Shell diagnostic failures | DONE | Fake CLI tests cover missing/outdated dependencies, expired token, wrong host before credential forwarding, denied model/target, PR policy, draft conflict, absent browser, unavailable Gemini and deferred probes. |
| Query and rating gates | DONE | Fixtures retain missing/unrun data, broken query, wrong URL, malformed rating, source/evidence hash, independent evaluator and explicit user-acceptance gates. No Gemini call occurs when query evidence fails. |
| Screenshot integrity | DONE | Ten new tests cover overwrite, deletion, symlink substitution, each of multiple sections, swapped sections, incomplete/legacy image manifests, changed/missing submitted copies, mutation during evaluation, transient recapture and duplicate section IDs. In-call source/browser JSON changes also fail without a rating. |
| HTML report | DONE | Unchanged single/multiple-section fixtures embed the exact evaluated bytes in self-contained HTML and retain links, ratings, decisions, acceptance and ledger. Changed images fail with STALE_EVIDENCE. |
| Initial installation diagnostic | DONE (2026-09-17) | Historical diagnostic detected chart-room 1.9.0 and missing official Omni CLI on PATH; not a claim about current auth or installation health. |
| Official transport capabilities | DONE (2026-09-17) | Historical checksum-verified official Omni CLI 1.3.1 help/schema probes, without installation. Not rerun for these script fixes. |
| Released schema compatibility | DONE | Real chart-room v1.10.1 release binary matches its published asset checksum, passes actual plugin preflight, and materializes the same semantic schema as the reviewed chart-room checkout. An altered native constraint is rejected with SCHEMA_MISMATCH. |

## Tested dependency and schema change

The accepted **schema compatibility baseline** is
[chart-room v1.10.1](https://github.com/brady-zip/chart-room/releases/tag/v1.10.1),
tag target `66c29d7cde1c5585b43ddb554fd3dd7c4a405837`. Its
`chart-room-darwin-arm64` executable was downloaded to a temporary directory and
matched the published release asset SHA-256:
`611da8ee7e8ad7cc6680bab1746cde4f55e7a14108cb5eb6809830906b3edf35`.
The release metadata, tag and downloaded binary checksum were rechecked on
2026-09-18. No installed executable was replaced; the existing PATH executable
was still v1.10.0 and now requires an upgrade before authoring.

The native schema still derives from official OpenAPI SHA-256
`12a9bc485e8bcd3d09c2a7cff646e0cd2c2090eb83899c860d31829d426e5a94`.
Its entire wrapped schema's normalized SHA-256, computed with
`common.schema_digest`, is:

`9ad370d2ffb7f72e0a74a425417d7002f534f69ead9dd3a4622ac4cdc55fbec7`.

The v1.10.1 schema is unchanged from v1.10.0 and deliberately retains the
v1.10.0 `$id`. The minimum executable version is now 1.10.1 so matching the schema
cannot admit v1.10.0 without the required runtime fixes. Offline regression
coverage explicitly rejects both v1.9.0 and v1.10.0.

The sole semantic difference from the plugin's original candidate pin is
`components.schemas.QueryPresentationsPatchExternal.properties.data.minProperties: 1`.
It rejects zero tile records, retaining chart-room's seed tile during provisioning.
Removing that constraint exactly reproduces the old digest
`e5214d44fe6e13f06bab1d2ea4674f2dadd7a2249e395c2553e28275e639e9fc`.
No native schema was widened or bypassed.

The repeatable check in [tests/check_chart_room_compatibility.py](tests/check_chart_room_compatibility.py)
passed all four checks: release asset checksum, actual binary capability/schema
preflight, source/materialized schema equality, and altered-native-schema rejection.
It uses a temporary config directory with `CHART_ROOM_NO_UPDATE=1` and invokes
no authenticated or Gemini operation. Run it with the actual release executable
and the optional reviewed source schema as documented in [README.md](README.md).

The user identified v1.10.1 as the intended follow-up release. Its source diff
contains filter-clearing synchronization, completion parsing and machine-output
update suppression fixes. The plugin now requires that release and its actual
binary passed the compatibility check; these fixes remain owned by chart-room.
This closes release coordination and offline interoperability, not the plugin's
live create/expand/review workflow. Repeat the artifact check before accepting any
later release; this evidence does not automatically carry forward to a new binary.

## Pre-first-run completion ledger (historical)

| Phase | Status | Reason / next evidence |
|---|---|---|
| Released schema dependency | DONE | v1.10.1 release asset and exact schema verified offline as above; this does not establish full authoring acceptance. |
| Chart-room release coordination | DONE | User selected the released v1.10.1 follow-up. Source changes were reviewed, the minimum version raised, and the actual release artifact/schema pair verified offline. |
| Personal Omni authentication | SKIPPED | No authenticated API profile was selected for a live run; user configures official CLI auth. Browser login alone is insufficient. |
| Approved disposable pair | SKIPPED | No approved model plus concrete prod/test folder IDs or disposable target pair supplied. |
| Real create | SKIPPED | Waiting for dependency, auth and approved pair; must record distinct stable test/prod IDs and URLs. |
| Real expand | SKIPPED | Requires actual model/field discovery and bounded successful queries; fixtures are not warehouse evidence. |
| Missing-data case | SKIPPED | Must show an actual verified gap becoming an owner handoff with no plausible empty tile. Offline refusal fixtures passed. |
| Broken-query case | SKIPPED | Must observe a real failed query stopping visual acceptance. Offline gate fixture passed. |
| Browser inspection | SKIPPED | Requires test publication, actual loading/filter/control behavior and screenshots of every section. |
| Independent Gemini review | SKIPPED | No internal screenshots sent. Requires authorized screenshot-sharing scope, real rendered evidence and exact Gemini output. |
| Unavailable-Gemini case | SKIPPED | Demonstrate provider unavailability prevents any claimed rating in the real session; offline fixture passed. |
| Final user acceptance | SKIPPED | Requires real current-source review and user response. |
| Evergreen deployment | SKIPPED | Separate workstream owns automation identity, runner/network access, production/revert and CI activation acceptance. |

For the revised workflow, select the approved pair and profile, run the five-skill
workflow, record actual chart-room/Omni/llm/Gemini versions, source digest, query
health, test publication readback, screenshots, rating history and all phase
outcomes. Exercise successful content and a missing-data gap. Preserve test-only
updates until the merge-to-deploy route, and link the private HTML report here
without committing screenshots or query exports. Do not convert these pending
rows to DONE using the synthetic offline fixtures.
