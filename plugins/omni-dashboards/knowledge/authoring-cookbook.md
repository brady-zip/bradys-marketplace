# Authoring tiles that render

Copy the shape from [reference.omni.jsonc](../examples/reference.omni.jsonc); do not
derive a tile from the schema alone. The reference includes a KPI, line, bar, table,
single-record, blank, name/subtitle metadata, inline text, divider, spacer,
placeholder, row stacks with `fillSpace`, and two explicitly mapped controls.
Its targets/model/fields are synthetic. Copy selected tile and layout shapes into
the definition created by chart-room, preserve its real IDs, and substitute only
discovered fields backed by executed queries. Never publish the reference as-is.

The shapes incorporate the 2026-09-18 live-run findings. The complete synthetic
example passes offline chart-room 1.10.1 validation; it has **not** been published
or rendered as a complete dashboard. In particular, placeholder/control placements
still need the representative-tile browser check. Schema describes accepted
structure, not whether useful content is visible.

## First tile before the full dashboard

Author one representative backed query tile with its name/subtitle metadata and
sized card stack. Validate locally and remotely, run `chart-room test`, then invoke
the dashboard-browser agent on the exact test URL. Require a visible, non-collapsed
visual, readable title/subtitle and values matching the executed query. Record the
source digest, publication result and browser observation in the phase handoff.
Only then reuse that card shape for the remaining tiles. For an existing dashboard,
preserve its other content and check one changed tile first. A new visualization
family still needs its own rendering check during full inspection.

## Live-run traps

| Authoring rule | Failure it prevents |
|---|---|
| Set `visConfig.visConfig.visType` as well as `visConfig.chartType`. | `chartType` alone was discarded on readback, blanking the authored vis and causing `VERIFICATION_FAILED`. |
| Use the separate `visType` enum: `vegalite` for line/bar/area, `omni-kpi`, `omni-table`, `single-record`, etc. | A `chartType` string is not necessarily a valid `visType`. |
| Include all ten query members: `calculations`, `column_totals`, `fields`, `fill_fields`, `filters`, `pivots`, `row_totals`, `sorts`, `table`, `userEditedSQL`. | First-tile `INVALID_DEFINITION`. Empty arrays/objects and an empty SQL string still belong in the query. |
| Place `{id, type:"query", as:"metadata", format:"name"}` and `format:"subtitle"` items, each with its own `instanceKey`. | Authored titles/subtitles otherwise remain invisible. |
| Put `height` and `minHeight` on the **card stack**, with `fillSpace` on cards in rows. The chart body may use `style.fillSpace`/`minHeight`. | Height on the chart body alone was ignored by its flex layout, leaving a clipped 32px sliver. |
| `StackContainer.style` is a string preset; `height`, `minHeight`, `fillSpace` are direct stack properties. | Style objects cause misleading container/required-children errors. Content-item `style` is a different object shape. |
| Stack `direction` is `row` or `column`. | `horizontal`/`vertical` are divider directions, not stack directions. |
| Query placements use `as:"chart"`, `"result"`, or `"metadata"`; use `inline-text` for markdown, plus `inline-divider`, `inline-spacer`, `placeholder`. | Blank query tiles used as prose render poorly; a placeholder is not evidence of a metric. |
| Query filters need their `type` discriminator and the members for that variant (e.g. `kind` and `values` for string filters). | Opaque Jackson errors. Do not assume every variant has `kind`: boolean and composite have different shapes. |
| Sorts use `column_name` and `sort_descending`. | `field` belongs to other Omni representations, not this native query shape. |
| `custom_summary_types` does not turn a dimension into an aggregate measure, even with `default_group_by:false`. | Silent wrong grain. Discover an existing measure or hand off the missing semantic work. |
| Date `BETWEEN` has an exclusive right bound; label and query the same interval/timezone. | Off-by-one days/weeks. For August, use Aug 1 inclusive through Sep 1 exclusive. |
| If `resultType:"json"` yields `Unable to parse data stream`, remove that option to inspect the original job/error stream. | Debugging a parser wrapper instead of the actual query failure. A retry is still not success until the completed stream says so. |
| Scroll through the whole dashboard twice, waiting for lazy canvases, before capture. | Empty screenshots of correctly sized charts that have not mounted. |

The date-bound convention also appears in Omni's official
[filter examples](https://docs.omni.co/modeling/filters/examples). Native document
shapes are checked against the exact schema pinned in `dependencies.json`; the
rendering observations above come from [the first live run](../FEEDBACK-first-live-run.md).

## Chart-room 1.10.1 verification and recovery

Omni can return `automaticVis:true` even when the source omits it. Released 1.10.1
does not normalize that unauthored true value away. The reference echoes the
observed values for its shapes: true for KPI/line/bar, false for table/single-record.
These are observed values, not a universal chart-type rule. For adopted tiles,
preserve the actual published value; after a mismatch, inspect the exact failed
draft readback. Do not copy a mismatching field blindly or relax other comparisons.
When adopting canonical document content, restore the production name/description
and exclude server-owned query model bindings such as `workbookModelId`.

An upstream patch to ignore unauthored `automaticVis` exists, but release and
artifact compatibility must be verified before dropping this workaround. The
plugin's minimum remains 1.10.1 until that release is accepted.

A failed verification can leave a main draft and cause `DRAFT_CONFLICT` on retry.
Stop, preserve the failed request/digest and draft identifier, and read the draft
list/readback. In 1.10.1, `omni documents discard-draft DOCUMENT` discards the
document's **current main draft**, not a named draft. It is not a safe automatic
retry command. Do not discard merely because author/timestamp look familiar; a
new edit may have arrived. Recover with the owner's explicit decision about that
concrete current draft, or leave it for the owner. No successful readback means no
permission to retry an ambiguous write blindly.

Upstream follow-up: a guarded `chart-room test --discard-draft IDENTIFIER` must
match the failed attempt's author, request digest and `draftOutOfDate:false`, and
refuse a different/changed draft; `test --dry-run` should expose the batch plan.
Neither option exists in the verified 1.10.1 executable. Local validation and
`validate --remote` (plans only) are the available checks before a test write.

## Control scope and truthful labels

Derive filter documentation from the actual definition after each mapping edit:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/explain-controls.py" FILE
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/explain-controls.py" FILE --format json
```

The helper reads tile names and `controls.data[ID].map`. A string is a field
override; `false` explicitly excludes a tile. An absent entry has **implicit**
native behavior and must not be described as excluded. Resolve that behavior in
the browser. Prefer explicit maps for new controls; do not change imported maps
without verifying their meaning. Regenerate the on-page scope sentences from this
output; do not independently hand-write a second mapping in prose.

Toggle each control to a value that distinguishes mapped from excluded tiles.
Reread every on-page claim in each tested state: totals, "all teams", denominators,
reconciliation, subtitles and definitions. Compare values to query expectations,
then restore and re-verify the original view. Two measures may reconcile only when
their windows and control scopes match. A total and its filtered subset must not
be stacked as additive series; use separate/grouped series or a verified disjoint
remainder. Inspect long KPI subtitles at readable scale: overflowing rows can
overprint measure labels even when the outer card has a valid height.
