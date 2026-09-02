# Widget Selection Guide

Decision matrix for choosing the right Datadog widget type based on data characteristics.

## RUM widgets — read this first

If the widget queries RUM events, see @${CLAUDE_PLUGIN_ROOT}/knowledge/rum-widget-landmines.md
before choosing a type. Several RUM constructs upload cleanly and then fail at render —
`timeshift()` most importantly, which produces an empty widget with no error at all. The
guide below assumes those constraints are already respected.

## Decision Flowchart

```
What are you showing?
├── A value changing over time?
│   ├── Single metric, different scopes → Line Graph (timeseries)
│   ├── Need sum + individual contributions → Stacked Area (timeseries)
│   ├── Sparse counts (deploys, events) → Bar Graph (timeseries)
│   └── Single metric, MANY groups (50+) → Heatmap
├── A single important number?
│   └── Query Value (with conditional formatting)
├── A ranking or comparison?
│   ├── Top/bottom N across segments → Top List
│   └── Two timeframes compared → Change Widget
├── A distribution or snapshot?
│   ├── Value spread at a point in time → Distribution
│   └── Infrastructure fleet overview → Host Map
├── Tabular data?
│   └── Multi-metric comparison across groups → Query Table
├── Correlation between two metrics?
│   └── X vs Y relationship → Scatter Plot
├── Proportional breakdown?
│   └── Hierarchical size comparison → Treemap
├── Operational context?
│   ├── Live log tails → Log Stream
│   ├── Events/deploys/alerts → Event Stream
│   ├── Monitor status → Alert Graph
│   └── Agent check health → Check Status
├── Organization?
│   ├── Section headers → Note (with markdown)
│   └── Grouping widgets → Group Widget
└── External content?
    └── Embed web pages → iFrame
```

## Widget Type Reference

### Timeseries

**Best for:** Showing evolution of metrics over time.

**Display types:**

- **Line**: Default. Best for 1-7 series. Use when tracking trends.
- **Area (stacked)**: Shows sum + contribution. Best for breakdowns (e.g., requests by status code).
- **Bars**: Sparse or count data. Best for events, deploys, discrete counts.

**When NOT to use:**

- More than 7-10 lines → use Heatmap or Top List
- Single point-in-time value → use Query Value
- Ranking → use Top List

**Pro tips:**

- Overlay events with `events` parameter for deploy correlation
- Use `markers` for SLO thresholds and ideal ranges
- Use `anomalies()` function for anomaly bands
- Combine `timeshift()` for week-over-week overlay

### Query Value

**Best for:** Single extremely important metrics. KPIs at a glance.

**ALWAYS use conditional formatting:**

```json
"conditional_formats": [
  {"comparator": "<", "value": 100, "palette": "white_on_green"},
  {"comparator": ">=", "value": 100, "palette": "white_on_yellow"},
  {"comparator": ">=", "value": 500, "palette": "white_on_red"}
]
```

**When to use:**

- Error rate, request rate, latency p95
- Availability percentage
- Active incidents count
- Any "glance and know" metric

**Pro tips:**

- Pair with a timeseries below for context
- Use `precision` to control decimal places
- Use `custom_unit` for meaningful labels (req/s, ms, %)

### Top List

**Best for:** Ranking hosts, services, endpoints, or any segment by metric value.

**When to use:**

- Find outliers (highest CPU hosts, slowest endpoints)
- Compare relative values across segments
- Show "top N" anything

**Pro tips:**

- Use `top()` function to limit series count
- Pair with conditional formatting for thresholds
- Great next to a timeseries for drill-down context

### Heatmap

**Best for:** Single metric distributed across many groups over time.

**When to use:**

- Latency distribution across hosts/pods (100+ groups)
- Request distribution showing hot spots
- Any metric where line graph would be spaghetti

**Pro tips:**

- Shows distribution density via color intensity
- Reveals patterns line graphs hide
- Best with percentile-based metrics

### Distribution

**Best for:** Showing the spread of values at a specific point in time.

**When to use:**

- Conveying general health at a glance
- Showing change within a time window
- Histogram-style views of metric values

### Change Widget

**Best for:** Comparing two timeframes directly.

**When to use:**

- Week-over-week comparison
- Before/after deployment comparison
- Trend direction at a glance

**Parameters:** Takes current timeframe and comparison timeframe.

### Host Map

**Best for:** High-level infrastructure overview.

**When to use:**

- Visualize fleet status across hosts/containers
- Color by metric (CPU, memory) with size by another (requests)
- Spot unhealthy nodes visually

### Log Stream

**Best for:** Real-time log viewing in the dashboard.

**When to use:**

- Debugging dashboards (show filtered logs alongside metrics)
- Incident response (tail production logs)
- Correlate log patterns with metric anomalies

**Pro tips:**

- Filter with same template variables as metrics
- Use log facets for focused views

### Event Stream

**Best for:** Monitoring footprints from infrastructure and monitors.

**When to use:**

- Show deploy events alongside metrics
- Track monitor state changes
- Audit trail of infrastructure events

### Alert Graph

**Best for:** Showing current state of configured monitors.

**When to use:**

- Show whether a specific monitor is OK/WARN/ALERT
- Incident response dashboards
- Any dashboard where monitor status matters

### Check Status

**Best for:** Visualizing agent check health.

**When to use:**

- Infrastructure dashboards showing integration health
- Quick view of all checks across hosts
- Monitoring check failures

### Query Table

**Best for:** Showing multiple metrics side-by-side in tabular format.

**When to use:**

- Compare metrics across services/endpoints (throughput, error rate, latency in one table)
- Summary tables at the top of dashboards
- When you need sortable, searchable data

**Pro tips:**

- Supports search bar for filtering rows
- Each column can have its own display mode (number, bar)
- Use `alias` field to give columns readable names
- Supports conditional formatting per column

### Scatter Plot

**Best for:** Showing correlation between two metrics.

**When to use:**

- Latency vs throughput analysis
- Resource usage correlation (CPU vs memory)
- Finding outliers in two-dimensional space

**Pro tips:**

- X and Y axes show different metrics
- Color by group to identify clusters
- Great for capacity planning

### Treemap

**Best for:** Proportional breakdown of a metric across groups.

**When to use:**

- Visualize relative traffic volume across services
- Show resource consumption breakdown
- Any "how much of the total" question

### Note Widget

**Best for:** Section headers, instructions, links.

**When to use:**

- Create visual separation between dashboard sections
- Add context or instructions for dashboard users
- Link to runbooks or documentation

**Pro tips:**

- Supports markdown formatting
- Use `## Headers` for section breaks
- Add links to related dashboards, runbooks, wiki pages

### Group Widget

**Best for:** Organizing related widgets into collapsible sections.

**When to use:**

- Always. Every dashboard should have groups.
- Organizes widgets into logical sections
- Can be collapsed to reduce noise

### iFrame

**Best for:** Embedding external web content.

**When to use:**

- Embed status pages, wikis, or internal tools
- Show Grafana panels alongside Datadog widgets
- Include any web-accessible content

### SLO Widget

**Best for:** Tracking service level objectives.

**When to use:**

- SLO tracking dashboards
- Show remaining error budget
- Display SLO status and burn rate
