# First live run: what it cost, and what to fix before release

Run: 2026-09-18, real dashboard ("Frontend Coverage & Production Defects") against zip.omniapp.co,
real shared model, real warehouse data, new prod/test pair. Plugin 260918.0, chart-room 1.10.1.
`ACCEPTANCE.md` said "live workflow acceptance pending" — this was that run. It completed and the
output is good (final independent rating 9/10), but the path there is not yet fit for other users.

## The headline number

Producing eight backed tiles took **three failed publishes, roughly a dozen further revisions, and
eleven browser inspection cycles**. Almost none of that was analysis. It was rediscovering how to
author a tile that renders. A second user starting today repeats nearly all of it.

Target for release: **one publish, one or two inspections, one or two ratings.**

## What already works — do not change it

1. **The preflight deferral model.** OK / DEFERRED / BLOCKED with a reason per row, and the refusal
   to let a deferral read as healthy, is genuinely good. "Process presence is not attachment proof"
   was correct and load-bearing: the browser process was up the whole time, and attachment still had
   to be proven separately.
2. **Separating plan evidence from executed evidence from rendered evidence.** All three mattered
   independently here. `REMOTE_VALIDATED` with 7/7 `PLAN_VALIDATED` was true while every chart on the
   page was invisible. Keep `queryResultsVerified: false` exactly as blunt as it is.
3. **`review.py`'s gates.** Screenshot digests, source-hash binding, refusing a rating that is not
   bound to the current source, `MALFORMED_RATING` with no fallback. These stop the exact corner-cutting
   an agent under time pressure will reach for.
4. **The missing-data discipline.** "A missing metric must not become a plausible-looking zero" drove
   the single best decision in the run — deferring the whole coverage half rather than inventing it.
5. **The dashboard-browser agent.** Every real defect came from it. See P1-1: it deserves more authority,
   not less.

## P0 — blocks other users from succeeding

### P0-1. Ship a golden reference definition and an authoring cookbook

This is the highest-leverage fix by a wide margin. Everything below was discovered by trial and error,
each costing at least one publish round trip. None of it is in `knowledge/`:

| Discovery | Symptom when you get it wrong |
| --- | --- |
| Chart type lives at `visConfig.visConfig.visType`; `chartType` alone is discarded | Server blanks the vis; `VERIFICATION_FAILED` |
| `visType` is its own enum (`vegalite`, `omni-kpi`, `omni-table`, `single-record`, …), distinct from `chartType` | Guessing `chartType` values into `visType` fails |
| Tile `query` requires all ten of `calculations, column_totals, fields, fill_fields, filters, pivots, row_totals, sorts, table, userEditedSQL` | `INVALID_DEFINITION` on the first tile you author |
| A tile's title/subtitle renders only if the layout includes `as:"metadata"` items (`format:"name"` / `"subtitle"`) | Every authored title is invisible; definitions silently absent |
| Height must sit on the **card stack wrapper**; the chart body is a flex item with `flex:1 1 0%` and `min-height:32px`, so `height` on it is ignored | Every chart collapses to a 32px sliver with `overflow:hidden` |
| `StackContainer.style` is a **string preset**, not an object; sizing uses direct props (`height`, `minHeight`, `fillSpace`) | `INVALID_DEFINITION` pointing at `/document/containers/0` with a misleading "must have required property 'children'" |
| `StackContainer.direction` enum is `row`/`column`, not `horizontal`/`vertical` | Same misleading container error |
| Layout content items: `{id, type:"query", as:"chart"\|"result"\|"metadata"}`, plus `inline-text` (markdown), `inline-divider`, `inline-spacer`, `placeholder` | Authors reach for blank tiles to hold text, which renders worse |
| Query filters need a `type` discriminator (`string`, `date`, `number`, `boolean`, `composite`, …) **and** a `kind` | Opaque Jackson deserialization errors |
| Sorts use `column_name`, not `field` | Same |
| `custom_summary_types` does **not** aggregate a dimension, with or without `default_group_by:false` | Silent wrong grain; looks like it worked |
| Date `BETWEEN` has an **exclusive** right bound | Off-by-one week, silently |
| `resultType:"json"` collapses real errors to `Unable to parse data stream` | You debug the wrong thing; drop it to see the real error |
| Omni mounts chart canvases **lazily on scroll** | Screenshots of correctly-sized empty slots |

**Ship:** `knowledge/authoring-cookbook.md` with the table above, and
`examples/reference.omni.jsonc` — one validated definition containing a KPI, a line, a bar, a table,
a single-record, a blank, both metadata item types, a divider, a placeholder, a row stack with
`fillSpace`, and two controls with a `map`. Point create/expand at it: *"copy the shape from the
reference, do not derive it from the schema."* The JSON Schema describes what validates, not what renders
— that gap is the whole problem.

### P0-2. Make `chart-room test` survivable

Two distinct traps, both hit in this run:

- **`automaticVis` makes verification unsatisfiable.** Omni returns `automaticVis:true` on auto-visualized
  tiles; `normalizePresentation` strips it only when it equals `null`/`false`, so any definition that
  omits it can never verify. Patched in `~/dev/chart-room` (+4 lines, +16 test, 103/103 pass, negative
  control confirms) — **needs releasing**, or the cookbook must tell authors to echo the field.
- **A failed verification leaves a draft that blocks every retry**, and the only exit is raw
  `omni documents discard-draft`, which discards *the* main draft rather than a named one — a blunter
  instrument than the tool is trying to be. Add `chart-room test --discard-draft <identifier>` that
  discards only the named draft after confirming it is chart-room's own failed attempt (author identity,
  `draftOutOfDate:false`, digest matches the prior failed request).

Also worth it: a `chart-room test --dry-run` mirroring `prod --dry-run`, so an author can see the batch
plan without creating a draft at all.

### P0-3. Author one tile, verify it renders, then author the rest

The skill currently has expand author the whole dashboard, publish, and only then hand to iterate for
rendering checks. That is why a single systematic mistake (no heights, no metadata items) hit **eight
tiles at once** and took three revisions to unwind.

Change expand's step 5 to: author **one** representative query tile plus its layout → `chart-room test`
→ one browser check confirming it renders visibly with a readable title → then author the remainder.
A five-minute check would have caught the 32px collapse before any of the other seven tiles existed.

### P0-4. Warn that schema-valid does not mean renders

Put this in `workflow-contract.md` beside the existing evidence table, because all three of these were
simultaneously true in this run: `VALIDATED` offline, `REMOTE_VALIDATED` 7/7, `UPDATED verified:true` —
and every chart on the page was blank whitespace.

## P1 — quality of the result

### P1-1. Move the inspection checklist into the agent definition

The browser agent found every real defect, but only because the caller's prompt kept telling it what to
check. Encode the standing checklist in `agents/dashboard-browser.md` so it does not depend on caller
diligence: emulate 1440x1000 (note `resize_page` may not work; `emulate` does), two scroll sweeps for
lazy canvases, computed height of every chart container, canvas dimensions, per-tile rendered values vs
expectation, toggle each control and confirm the mapped set changes and the unmapped set does not, restore
and re-verify pristine before capturing, privacy sweep, and console errors.

### P1-2. Add filter-conditional truth to the review criteria

Four separate defects in this run were sentences that were **true in the pristine view and false once a
control moved**: "All teams, including unassigned" beside a team-filtered 104; "rows reconcile exactly to
the headline" when the table and the KPI follow different controls; a filter bullet that omitted the one
control it did not mention; a subtitle saying severity is not plotted on a chart that becomes
severity-restricted under Priority.

Nothing in `query-evidence.md` or `review-artifacts.md` mentions this class, and it is invisible to every
static gate. Add to iterate step 3: *re-read every on-page claim under each control state, not just at
rest.* This is the highest-value single addition to the review.

### P1-3. Generate control documentation from `controls.map`

The root cause of two of those four defects was that I hand-wrote prose describing a mapping I had also
hand-written, and they diverged. The fix that worked was reading `controls.map` out of the definition and
generating the sentences from it. Either give chart-room a `chart-room explain-controls FILE` that emits
the mapping in prose, or instruct expand to derive it programmatically. Hand-written filter documentation
should be treated as a known defect source.

### P1-4. Tell the evaluator which questions are known-blocked

Pass 1 scored **4/10**, driven almost entirely by "fails to address its primary questions" — a data
availability fact the owner had already decided, not a dashboard defect. The same artifact reached **9/10**
after adding a status line, a question-status table and a clearer blocked section: the dashboard barely
changed, its *self-description* did.

That is a real finding worth teaching — transparency scaffolding is how a partial dashboard earns its
rating — but the evaluator should be given `_meta` question status so it grades *how well the limitation is
handled* rather than double-penalizing a decision the user already made. Otherwise the `>= 7` gate is
unreachable for legitimately partial dashboards, and an author is nudged toward hiding gaps to score.

### P1-5. Structure the phase handoffs

Everything carried across create → expand → iterate was prose I wrote by hand: profile, model, targets,
window, measures, decisions, sharing scope, query-shape gotchas. It worked, but it is lossy and entirely
dependent on the caller. Define a handoff JSON the skills read and write, with the prose as commentary.

## P2 — polish

- **Document `review.py`'s evidence contract precisely.** `tiles` must equal *exactly* the `query`/`sql`/`linked`
  tiles (blank tiles excluded, and including one is a hard failure), and `sections` must match `_meta.sections`
  IDs exactly. I read the source to learn both. The example in `review-artifacts.md` shows neither.
- **`_meta.sections` is coupled to the screenshot set.** Splitting a section mid-review means updating metadata
  and recapturing. Worth one sentence.
- **Consider a layout linter** in `chart-room validate`: warn on a chart tile whose placement has no height on
  an ancestor stack, on a query tile with no `as:"metadata"` name item, and on a chart plotting two measures
  where one is a filtered subset of the other (the stacked-subset double-count — it inflated a bar from 108 to
  ~124 and inverted the sort order, and no gate caught it).
- **KPI subtitle rows are `overflow:visible`**, so an over-long subtitle overprints the measure label instead of
  clipping — silent, and invisible to every check except a magnified look. Both KPIs here now sit at 4px headroom.

## Metrics worth tracking for release

| | This run | Target |
| --- | --- | --- |
| Publishes to first rendering-correct dashboard | 6 | 1 |
| Failed publishes | 3 | 0 |
| Browser inspection cycles | 11 | 2 |
| Defects found after "verified: true" | 6 | 0–1 |
| Rating passes to reach >= 7 | 3 | 1–2 |

P0-1 alone should move the first three rows most of the way.
