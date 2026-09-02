# RUM Widget Landmines

Constructs that are valid Datadog dashboard JSON, upload without complaint via
`chart-room test`, and then **fail at render time** — several of them silently. All four
below were found empirically during a single dashboard build, each costing an
upload → screenshot → diagnose cycle.

Read this before writing any widget whose query is a RUM event query
(`rum` data source, `@`-prefixed attributes, `rum.*` measures). None of it applies to
metric queries.

The reason to keep this file: a *loud* failure teaches you something the first time you
hit it. A silent one teaches you nothing, and you will re-derive it every few months
unless it is written down.

## 1. `timeshift()` renders silently empty

**The nastiest of the four.** A RUM query wrapped in `timeshift()` produces **no error, no
warning, and no value** — just an empty widget that looks exactly like a query which
legitimately has no data in the window.

```jsonc
// Renders blank. No error anywhere.
"q": "timeshift(sum:rum.session.count{...}, -604800)"
```

Do not use `timeshift()` on RUM queries. For week-over-week comparison, use two explicit
queries with different `live_span`s, or a `change` widget (subject to §2).

Because the failure is indistinguishable from "no data", an empty widget on a RUM
dashboard should send you here **before** you start rewriting tag filters.

## 2. `compare_to` errors on change widgets over RUM

A `change` widget's `compare_to` field errors out on:

- RUM event queries, and
- a **metrics two-query ratio** (`a/b` style formula)

This one at least fails loudly, with an error visible in `document.body.innerText`.

Use a plain `query_value` or `timeseries` with two explicit time windows instead.

## 3. Every RUM event widget needs its own `live_span` ≤ 30d

RUM event retention is shorter than the dashboard time picker's range. A RUM widget with
no `live_span` of its own inherits the picker, and **reads empty whenever the user
selects a window longer than retention** — including, commonly, on first open.

Set it per-widget, explicitly:

```jsonc
"time": { "live_span": "7d" }   // or any span <= 30d
```

This is not a default you can rely on inheriting correctly. Set it on **every** RUM event
widget, even when the dashboard's own default looks right today — the person who later
changes the picker to 3mo will not know this rule exists.

## 4. Screenshots are not evidence about RUM widgets

Datadog chart canvases paint lazily, so a full-page screenshot of a healthy RUM dashboard
routinely comes back blank or half-blank. Combined with §1, this is genuinely dangerous:
a silently-empty `timeshift()` widget and a merely-unpainted healthy widget are the same
image.

Never diagnose RUM widget health from pixels. Read the DOM text, which is populated
regardless of canvas paint state:

```javascript
document.body.innerText
```

and grep it for `Query Error`, `Missing base`, `No data`, `Invalid query`. The
`dashboard-browser` agent does this; `iterate-dashboard` step 3.1b depends on it.

## Working around all four

The safe RUM widget shape:

- explicit per-widget `"time": { "live_span": "<= 30d>" }`
- no `timeshift()`
- no `change` widget with `compare_to`
- verified by DOM text, not by screenshot
