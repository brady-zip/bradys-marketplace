# Datadog Dashboard JSON Reference

API schema for dashboard JSON. Used when generating importable dashboard configs.

## Top-Level Structure

```json
{
  "title": "Dashboard Title",
  "description": "What this dashboard monitors and why",
  "layout_type": "ordered",
  "template_variables": [],
  "widgets": [],
  "notify_list": [],
  "reflow_type": "auto"
}
```

| Field         | Values                                           | Notes                                       |
| ------------- | ------------------------------------------------ | ------------------------------------------- |
| `layout_type` | `"ordered"` (timeboard) / `"free"` (screenboard) | Ordered auto-layouts, free requires x/y/w/h |
| `reflow_type` | `"auto"` / `"fixed"`                             | Only for ordered layouts                    |

## Template Variables

```json
{
  "template_variables": [
    {
      "name": "env",
      "prefix": "env",
      "default": "production",
      "available_values": ["production", "staging", "development"]
    },
    {
      "name": "service",
      "prefix": "service",
      "default": "*"
    }
  ]
}
```

Use `$env.value` in queries: `avg:metric{env:$env.value,service:$service.value}`

## Query Format: Formulas and Queries (Preferred)

The modern query format uses named queries and formulas. **Prefer this format over the legacy `"q"` format.**

### Single query:

```json
"requests": [{
  "formulas": [{"formula": "query1"}],
  "queries": [{
    "data_source": "metrics",
    "name": "query1",
    "query": "avg:system.cpu.user{env:$env.value} by {host}"
  }],
  "response_format": "timeseries"
}]
```

### Multi-query formula (e.g., error percentage):

```json
"requests": [{
  "formulas": [{"formula": "100 * query1 / query2"}],
  "queries": [
    {
      "data_source": "metrics",
      "name": "query1",
      "query": "sum:trace.http.request.errors{service:$service.value}.as_count()"
    },
    {
      "data_source": "metrics",
      "name": "query2",
      "query": "sum:trace.http.request.hits{service:$service.value}.as_count()"
    }
  ],
  "response_format": "scalar"
}]
```

### Multiple series on same chart:

```json
"requests": [
  {
    "formulas": [{"formula": "query1"}],
    "queries": [{"data_source": "metrics", "name": "query1", "query": "p50 query..."}],
    "response_format": "timeseries",
    "style": {"palette": "cool", "line_type": "solid", "line_width": "normal"},
    "display_type": "line"
  },
  {
    "formulas": [{"formula": "query2"}],
    "queries": [{"data_source": "metrics", "name": "query2", "query": "p95 query..."}],
    "response_format": "timeseries",
    "style": {"palette": "warm", "line_type": "dashed", "line_width": "normal"},
    "display_type": "line"
  }
]
```

### Data sources:

| `data_source`        | Use for                             |
| -------------------- | ----------------------------------- |
| `"metrics"`          | Infrastructure, APM, custom metrics |
| `"logs"`             | Log analytics queries               |
| `"spans"`            | APM trace span queries              |
| `"rum"`              | Real User Monitoring                |
| `"security_signals"` | Security monitoring                 |
| `"ci_pipelines"`     | CI Visibility                       |

### Response formats:

| `response_format` | Widget types                  |
| ----------------- | ----------------------------- |
| `"timeseries"`    | Timeseries, Heatmap           |
| `"scalar"`        | Query Value, Top List, Change |

### Formula functions in formulas field:

```json
"formulas": [
  {"formula": "query1 / query2 * 100"},
  {"formula": "clamp_min(query1, 0)"},
  {"formula": "cutoff_min(query1, 10)"},
  {"formula": "default_zero(query1)"},
  {"formula": "query1", "limit": {"count": 10, "order": "desc"}}
]
```

## Widget Wrapper

Every widget follows this structure:

```json
{
  "definition": {
    "type": "<widget_type>",
    "title": "Widget Title",
    "title_size": "16",
    "title_align": "left",
    ...type-specific fields
  }
}
```

For `layout_type: "free"`, add layout coordinates:

```json
{
  "definition": {...},
  "layout": {"x": 0, "y": 0, "width": 4, "height": 2}
}
```

Per-widget time override (useful in screenboards):

```json
{
  "definition": {
    ...
    "time": {"live_span": "1h"}
  }
}
```

Valid `live_span` values: `"1m"`, `"5m"`, `"10m"`, `"15m"`, `"30m"`, `"1h"`, `"4h"`, `"1d"`, `"2d"`, `"1w"`, `"1mo"`

## Group Widget

Wraps related widgets into a collapsible section:

```json
{
  "definition": {
    "type": "group",
    "layout_type": "ordered",
    "title": "Section Name",
    "show_title": true,
    "widgets": [
      ...child widgets
    ]
  }
}
```

## Timeseries Widget

```json
{
  "definition": {
    "type": "timeseries",
    "title": "Request Rate",
    "show_legend": true,
    "legend_layout": "auto",
    "legend_columns": ["avg", "min", "max", "value", "sum"],
    "requests": [
      {
        "formulas": [{ "formula": "query1" }],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "avg:trace.http.request.hits{service:$service.value,env:$env.value} by {resource_name}"
          }
        ],
        "response_format": "timeseries",
        "style": {
          "palette": "dog_classic",
          "line_type": "solid",
          "line_width": "normal"
        },
        "display_type": "line"
      }
    ],
    "yaxis": {
      "include_zero": true,
      "scale": "linear",
      "min": "auto",
      "max": "auto"
    },
    "markers": [
      {
        "value": "y = 100",
        "display_type": "error dashed",
        "label": "SLO: 100ms"
      },
      {
        "value": "50 < y < 100",
        "display_type": "warning dashed",
        "label": "Warning range"
      }
    ]
  }
}
```

**Display types:** `"line"`, `"area"`, `"bars"`

**Marker display_types:** `"error dashed"`, `"warning dashed"`, `"ok dashed"`, `"info dashed"` (+ `"solid"` variant)

**Line types:** `"solid"`, `"dashed"`, `"dotted"`

**Palettes:** `"dog_classic"`, `"warm"`, `"cool"`, `"purple"`, `"orange"`, `"gray"`

## Query Value Widget

```json
{
  "definition": {
    "type": "query_value",
    "title": "Error Rate",
    "autoscale": true,
    "precision": 2,
    "custom_unit": "%",
    "requests": [
      {
        "formulas": [{ "formula": "100 * query1 / query2" }],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "sum:trace.http.request.errors{service:$service.value,env:$env.value}.as_count()"
          },
          {
            "data_source": "metrics",
            "name": "query2",
            "query": "sum:trace.http.request.hits{service:$service.value,env:$env.value}.as_count()"
          }
        ],
        "response_format": "scalar",
        "conditional_formats": [
          { "comparator": "<", "value": 1, "palette": "white_on_green" },
          { "comparator": ">=", "value": 1, "palette": "white_on_yellow" },
          { "comparator": ">=", "value": 5, "palette": "white_on_red" }
        ]
      }
    ]
  }
}
```

**Conditional format palettes:** `"white_on_green"`, `"white_on_yellow"`, `"white_on_red"`, `"green_on_white"`, `"yellow_on_white"`, `"red_on_white"`, `"black_on_light_green"`, `"black_on_light_yellow"`, `"black_on_light_red"`

## Top List Widget

```json
{
  "definition": {
    "type": "toplist",
    "title": "Top Endpoints by Latency",
    "requests": [
      {
        "formulas": [
          {
            "formula": "query1",
            "limit": { "count": 10, "order": "desc" }
          }
        ],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "avg:trace.http.request.duration{service:$service.value,env:$env.value} by {resource_name}"
          }
        ],
        "response_format": "scalar",
        "conditional_formats": [
          { "comparator": "<", "value": 100, "palette": "white_on_green" },
          { "comparator": ">=", "value": 100, "palette": "white_on_yellow" },
          { "comparator": ">=", "value": 500, "palette": "white_on_red" }
        ]
      }
    ]
  }
}
```

## Heatmap Widget

```json
{
  "definition": {
    "type": "heatmap",
    "title": "Latency Distribution by Host",
    "requests": [
      {
        "formulas": [{ "formula": "query1" }],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "avg:trace.http.request.duration{service:$service.value,env:$env.value} by {host}"
          }
        ],
        "response_format": "timeseries",
        "style": { "palette": "dog_classic" }
      }
    ],
    "yaxis": { "include_zero": true }
  }
}
```

## Distribution Widget

```json
{
  "definition": {
    "type": "distribution",
    "title": "Request Latency Distribution",
    "requests": [
      {
        "query": "avg:trace.http.request.duration{service:$service.value,env:$env.value} by {resource_name}",
        "style": { "palette": "dog_classic" }
      }
    ]
  }
}
```

## Change Widget

```json
{
  "definition": {
    "type": "change",
    "title": "Error Rate Change (week over week)",
    "requests": [
      {
        "formulas": [
          {
            "formula": "query1",
            "limit": { "count": 10, "order": "desc" }
          }
        ],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "sum:trace.http.request.errors{service:$service.value,env:$env.value} by {resource_name}.as_count()"
          }
        ],
        "response_format": "scalar",
        "change_type": "absolute",
        "compare_to": "week_before",
        "increase_good": false,
        "order_by": "change",
        "order_dir": "desc"
      }
    ]
  }
}
```

## Host Map Widget

```json
{
  "definition": {
    "type": "hostmap",
    "title": "Host CPU Usage",
    "requests": {
      "fill": {
        "q": "avg:system.cpu.user{env:$env.value} by {host}"
      },
      "size": {
        "q": "avg:system.mem.used{env:$env.value} by {host}"
      }
    },
    "style": {
      "palette": "green_to_orange",
      "palette_flip": false
    },
    "group": ["availability-zone"],
    "scope": ["env:$env.value"],
    "no_metric_hosts": false,
    "no_group_hosts": true
  }
}
```

## Note Widget

```json
{
  "definition": {
    "type": "note",
    "content": "## Traffic & Throughput\nRequest volume and endpoint breakdown",
    "background_color": "gray",
    "font_size": "14",
    "text_align": "left",
    "vertical_align": "center",
    "show_tick": false,
    "tick_pos": "50%",
    "tick_edge": "left",
    "has_padding": true
  }
}
```

**Background colors:** `"gray"`, `"white"`, `"yellow"`, `"blue"`, `"green"`, `"orange"`, `"pink"`, `"vivid_blue"`, `"vivid_green"`, `"vivid_orange"`, `"vivid_yellow"`, `"vivid_purple"`

## Log Stream Widget

```json
{
  "definition": {
    "type": "log_stream",
    "title": "Application Logs",
    "query": "service:$service.value env:$env.value status:error",
    "columns": ["host", "service", "status"],
    "show_date_column": true,
    "show_message_column": true,
    "message_display": "expanded-md",
    "sort": { "column": "time", "order": "desc" },
    "indexes": []
  }
}
```

## Event Stream Widget

```json
{
  "definition": {
    "type": "event_stream",
    "title": "Deploy Events",
    "query": "tags:deploy service:$service.value",
    "tags_execution": "and",
    "event_size": "s"
  }
}
```

## Alert Graph Widget

```json
{
  "definition": {
    "type": "alert_graph",
    "title": "Service Health Monitor",
    "alert_id": "<MONITOR_ID>",
    "viz_type": "timeseries"
  }
}
```

## Check Status Widget

```json
{
  "definition": {
    "type": "check_status",
    "title": "Agent Checks",
    "check": "datadog.agent.up",
    "grouping": "cluster",
    "group_by": ["env", "host"],
    "tags": ["env:$env.value"]
  }
}
```

## SLO Widget

```json
{
  "definition": {
    "type": "slo",
    "title": "API Availability SLO",
    "slo_id": "<SLO_ID>",
    "view_type": "detail",
    "time_windows": ["7d", "30d", "90d"],
    "show_error_budget": true
  }
}
```

## Query Table Widget

```json
{
  "definition": {
    "type": "query_table",
    "title": "Service Metrics Summary",
    "requests": [
      {
        "formulas": [
          {
            "formula": "query1",
            "cell_display_mode": "bar",
            "alias": "Request Rate"
          },
          {
            "formula": "query2",
            "cell_display_mode": "number",
            "alias": "Error %"
          },
          {
            "formula": "query3",
            "cell_display_mode": "number",
            "alias": "P95 (ms)"
          }
        ],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "sum:trace.http.request.hits{env:$env.value} by {service}.as_rate()",
            "aggregator": "avg"
          },
          {
            "data_source": "metrics",
            "name": "query2",
            "query": "100*sum:trace.http.request.errors{env:$env.value} by {service}.as_count()/sum:trace.http.request.hits{env:$env.value} by {service}.as_count()",
            "aggregator": "avg"
          },
          {
            "data_source": "metrics",
            "name": "query3",
            "query": "avg:trace.http.request.duration.by.service.95p{env:$env.value} by {service}",
            "aggregator": "avg"
          }
        ],
        "response_format": "scalar"
      }
    ],
    "has_search_bar": "auto"
  }
}
```

**Cell display modes:** `"number"`, `"bar"`

## Scatter Plot Widget

```json
{
  "definition": {
    "type": "scatterplot",
    "title": "Latency vs Throughput by Service",
    "requests": {
      "x": {
        "q": "avg:trace.http.request.hits{env:$env.value} by {service}.as_rate()",
        "aggregator": "avg"
      },
      "y": {
        "q": "avg:trace.http.request.duration{env:$env.value} by {service}",
        "aggregator": "avg"
      }
    },
    "xaxis": { "label": "Throughput (req/s)", "include_zero": true },
    "yaxis": { "label": "Latency (ms)", "include_zero": true },
    "color_by_groups": ["service"]
  }
}
```

## Treemap Widget

```json
{
  "definition": {
    "type": "treemap",
    "title": "Request Volume by Service",
    "requests": [
      {
        "formulas": [{ "formula": "query1" }],
        "queries": [
          {
            "data_source": "metrics",
            "name": "query1",
            "query": "sum:trace.http.request.hits{env:$env.value} by {service}.as_count()"
          }
        ],
        "response_format": "scalar"
      }
    ]
  }
}
```

## iFrame Widget

```json
{
  "definition": {
    "type": "iframe",
    "url": "https://status.example.com"
  }
}
```

## Event Overlay on Timeseries

Add event markers to any timeseries widget:

```json
{
  "definition": {
    "type": "timeseries",
    "title": "Request Rate with Deploys",
    "requests": [...],
    "events": [
      {"q": "tags:deployment service:$service.value"},
      {"q": "tags:incident"}
    ]
  }
}
```

## Custom Links (Drilldowns)

Add clickable links to any widget for drill-down navigation:

```json
{
  "definition": {
    "type": "timeseries",
    "custom_links": [
      {
        "label": "View in APM",
        "link": "https://app.datadoghq.com/apm/services/{{service.value}}"
      },
      {
        "label": "View Logs",
        "link": "https://app.datadoghq.com/logs?query=service:{{service.value}}"
      }
    ]
  }
}
```

Template variables in links use `{{var.value}}` syntax.

## Common Query Patterns

### APM / Tracing

```
avg:trace.http.request.hits{service:X,env:Y}                    # Request rate
avg:trace.http.request.errors{service:X,env:Y}                  # Error count
avg:trace.http.request.duration.by.service.95p{service:X,env:Y} # P95 latency
avg:trace.http.request.duration.by.resource_name.95p{...}       # P95 by endpoint
```

### Infrastructure

```
avg:system.cpu.user{host:X}          # CPU usage
avg:system.mem.used{host:X}          # Memory used
avg:system.disk.used{host:X}         # Disk used
avg:system.net.bytes_rcvd{host:X}    # Network in
avg:system.net.bytes_sent{host:X}    # Network out
avg:system.load.1{host:X}            # Load average
```

### Kubernetes

```
avg:kubernetes.cpu.usage.total{kube_deployment:X}
avg:kubernetes.memory.usage{kube_deployment:X}
avg:kubernetes_state.pod.status_phase{kube_deployment:X} by {pod_phase}
avg:kubernetes_state.deployment.replicas_available{kube_deployment:X}
```

### Database

```
avg:postgresql.queries.count{service:X}
avg:postgresql.queries.time{service:X}
avg:postgresql.connections{service:X}
avg:redis.commands_per_sec{service:X}
avg:redis.mem.used{service:X}
```

### Custom Metrics with Functions

```
per_second(sum:custom.metric{*})                    # Rate
anomalies(avg:metric{*}, 'basic', 2)               # Anomaly detection
forecast(avg:metric{*}, 'linear', 7)               # Forecast
ewma_3(avg:metric{*})                              # Smoothing
100 * sum:errors{*}.as_count() / sum:total{*}.as_count()  # Error percentage
top(avg:metric{*} by {host}, 10, 'mean', 'desc')   # Top 10
timeshift(avg:metric{*}, -1w)                       # Week ago comparison
```
