# Acceptance record — 2026-09-17

Status: implementation and offline verification; **live workflow acceptance pending**.
No Omni documents, folders, drafts, roles, policies, credentials or CI secrets were
created or changed while implementing this plugin. No commit, push or PR publication
has been performed for this change.

## Local evidence

The stdlib suite passed 36 tests. Shell syntax, Python static checks, both Claude
manifest validations, and all five skill frontmatter checks passed. Skill checks
retain Claude-specific argument hints; the Codex skill validator was applied to
a temporary projection omitting that unsupported Codex key. These checks validate
packaging and instruction structure, not a live agent/browser/warehouse session.

| Gate | Outcome | Evidence / limit |
|---|---|---|
| Claude plugin and marketplace manifests | DONE | Name, description, version 260917.0 and source registration agree; Claude manifest validation and stdlib checks. |
| Five entry skills and browser agent | DONE | Explicit create → expand → iterate handoffs, scoped preflight and phase ledgers; portable internal references. |
| Shell diagnostic failures | DONE | Fake CLI tests cover missing/outdated dependencies, expired token, wrong host before credential forwarding, denied model/target, PR policy, draft conflict, absent browser, unavailable Gemini and deferred probes. |
| Query and rating gates | DONE | Fixtures refuse missing/unrun data, broken queries, wrong URL, missing sections, malformed ratings and stale source; no Gemini call occurs when query evidence fails. |
| HTML report | DONE | Fixture evaluation embeds screenshots, records exact rating, acceptance and ledger, links source/test/prod, and distinguishes below-7 and incomplete runs. |
| Real installed dependency diagnostic | DONE | Detected installed chart-room 1.9.0 and missing official Omni CLI on normal PATH. No authentication claim made. |
| Official transport capabilities | DONE | Downloaded checksum-verified official Omni CLI 1.3.1 into a temporary directory and probed help/schema offline. Nothing installed to the user's PATH. |
| Candidate native schema | DONE | Local chart-room 1.10.0 candidate and generated schema agree after semantic JSON normalization. This is offline candidate evidence, not a released/live acceptance result. |

The native schema pin derives from official OpenAPI SHA-256
`12a9bc485e8bcd3d09c2a7cff646e0cd2c2090eb83899c860d31829d426e5a94`.
The entire wrapped native schema's normalized SHA-256 is
`e5214d44fe6e13f06bab1d2ea4674f2dadd7a2249e395c2553e28275e639e9fc`.

## Live completion ledger

| Phase | Status | Reason / next evidence |
|---|---|---|
| Released authoring dependency | FAILED | Latest released chart-room is v1.9.0; local 1.10.0 Omni candidate is not released. Require the accepted release and matching contract schema. |
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

After chart-room ships, select the approved pair and profile, run the five-skill
workflow, record actual chart-room/Omni/llm/Gemini versions, source digest, query
health, test publication readback, screenshots, rating history and all phase
outcomes. Exercise successful content and a missing-data gap. Preserve test-only
updates until the merge-to-deploy route, and link the private HTML report here
without committing screenshots or query exports. Do not convert these pending
rows to DONE using the synthetic offline fixtures.
