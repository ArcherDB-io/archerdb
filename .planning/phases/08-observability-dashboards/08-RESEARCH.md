# Phase 8: Observability Dashboards - Research

**Researched:** 2026-01-23
**Domain:** Grafana Dashboards, Prometheus Alerting Rules, PromQL
**Confidence:** HIGH

## Summary

Phase 8 builds production-ready monitoring infrastructure for ArcherDB operators. The phase creates Grafana dashboard JSON templates (provisioned via files, not UI) and Prometheus alerting rules (YAML format). ArcherDB already has comprehensive Prometheus-format metrics exposed via the metrics endpoint (Phase 7), so this phase focuses entirely on visualization and alerting configuration.

The standard approach uses Grafana's JSON dashboard model with provisioning, template variables for dynamic filtering, and dashboard links for drill-down navigation. Prometheus alerting rules follow the YAML groups/rules structure with the `for` duration for flapping prevention. Alertmanager notification templates provide routing to Slack, PagerDuty, OpsGenie, email, and webhook endpoints.

Per CONTEXT.md decisions: layered dashboard architecture (overview + 4 detail dashboards), spacious 2-panels-per-row layout, terminology toggle via dashboard variable, annotation markers for restarts/failovers/config changes, tiered alert thresholds (conservative for pager-worthy, aggressive for warnings), and runbook links required for all alerts.

**Primary recommendation:** Create Grafana JSON files using the standard dashboard model with template variables for node selection and terminology switching. Create Prometheus rule files with separate groups for warnings vs critical alerts. Provide Alertmanager configuration templates for all required notification channels.

## Standard Stack

The established tools for this domain:

### Core (File Formats)
| Format | Version | Purpose | Why Standard |
|--------|---------|---------|--------------|
| Grafana Dashboard JSON | Schema v17+ | Dashboard definition | Native Grafana format, version-controlled |
| Prometheus Rule YAML | v1 | Alerting rule definition | Native Prometheus format |
| Alertmanager Config YAML | v1 | Notification routing | Native Alertmanager format |

### Grafana Panel Types to Use
| Panel Type | Purpose | When to Use |
|------------|---------|-------------|
| Time Series | Latency, throughput over time | Primary visualization for metrics |
| Stat | Single big number with sparkline | Current values: connections, ops/sec |
| Gauge | Progress toward threshold | Memory usage, disk usage percentages |
| Table | Multi-dimensional data | Per-node status, per-shard health |
| Row | Organizational container | Group related panels, collapsible |

### PromQL Functions Required
| Function | Purpose | Example |
|----------|---------|---------|
| `rate()` | Counter rate per second | `rate(archerdb_write_operations_total[5m])` |
| `histogram_quantile()` | Latency percentiles | `histogram_quantile(0.99, rate(archerdb_write_latency_seconds_bucket[5m]))` |
| `sum()` | Aggregate across instances | `sum(archerdb_active_connections)` |
| `avg()` | Average across instances | `avg(archerdb_memory_used_bytes)` |
| `max()` | Worst-case values | `max(archerdb_vsr_replication_lag_seconds)` |
| `increase()` | Total increase over range | `increase(archerdb_write_errors_total[1h])` |

### Alternatives Considered
| Standard Choice | Alternative | Why Standard |
|----------------|-------------|--------------|
| JSON dashboard files | Grafana UI creation | Version control, reproducible, Infrastructure-as-Code |
| Prometheus alert rules | Grafana alerting | Prometheus rules are portable, standard in k8s |
| Template variables | Hardcoded queries | Single dashboard serves all environments/nodes |
| File provisioning | API provisioning | Simpler deployment, works without API access |

**File Structure:**
```
observability/
├── grafana/
│   ├── dashboards/
│   │   ├── archerdb-overview.json
│   │   ├── archerdb-queries.json
│   │   ├── archerdb-replication.json
│   │   ├── archerdb-storage.json
│   │   └── archerdb-cluster.json
│   └── provisioning/
│       └── dashboards.yaml
├── prometheus/
│   └── rules/
│       ├── archerdb-warnings.yaml
│       └── archerdb-critical.yaml
└── alertmanager/
    └── templates/
        ├── slack.tmpl
        ├── pagerduty.tmpl
        ├── opsgenie.tmpl
        ├── email.tmpl
        └── webhook.tmpl
```

## Architecture Patterns

### Pattern 1: Grafana Dashboard JSON Structure
**What:** Complete dashboard definition as JSON
**When to use:** All dashboards
**Example:**
```json
{
  "uid": "archerdb-overview",
  "title": "ArcherDB Overview",
  "tags": ["archerdb", "overview"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "refresh": "30s",
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "templating": {
    "list": []
  },
  "annotations": {
    "list": []
  },
  "panels": [],
  "links": []
}
```
Source: [Grafana Dashboard JSON Model](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/view-dashboard-json-model/)

### Pattern 2: Template Variable for Terminology Toggle
**What:** Custom variable to switch display strings
**When to use:** Overview dashboard (per CONTEXT.md decision)
**Example:**
```json
{
  "templating": {
    "list": [
      {
        "name": "terminology",
        "type": "custom",
        "label": "Terminology",
        "description": "Display terminology style",
        "current": {
          "text": "ArcherDB",
          "value": "archerdb"
        },
        "options": [
          {"text": "ArcherDB", "value": "archerdb", "selected": true},
          {"text": "Database", "value": "database", "selected": false},
          {"text": "Plain English", "value": "plain", "selected": false}
        ],
        "query": "archerdb,database,plain",
        "multi": false,
        "includeAll": false
      }
    ]
  }
}
```
Source: [Grafana Variables](https://grafana.com/docs/grafana/latest/dashboards/variables/add-template-variables/)

### Pattern 3: Node Selection Variable
**What:** Query variable to filter by instance
**When to use:** All dashboards for node drill-down
**Example:**
```json
{
  "name": "instance",
  "type": "query",
  "label": "Node",
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "query": "label_values(archerdb_info, instance)",
  "refresh": 1,
  "multi": true,
  "includeAll": true,
  "allValue": ".*"
}
```

### Pattern 4: Panel with Grid Position (2 per row)
**What:** Spacious panel layout per CONTEXT.md decision
**When to use:** All panels
**Example:**
```json
{
  "panels": [
    {
      "type": "timeseries",
      "title": "Query Latency (p99)",
      "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
      "id": 1,
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket{instance=~\"$instance\"}[5m])) by (le))",
          "legendFormat": "p99"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        }
      }
    },
    {
      "type": "timeseries",
      "title": "Query Throughput",
      "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
      "id": 2
    }
  ]
}
```
Note: w=12 gives exactly 2 panels per row (24-column grid)

### Pattern 5: Dashboard Links for Drill-Down
**What:** Navigation between overview and detail dashboards
**When to use:** Overview dashboard linking to detail dashboards
**Example:**
```json
{
  "links": [
    {
      "title": "Queries Detail",
      "type": "link",
      "url": "/d/archerdb-queries/archerdb-queries?orgId=1&${__url_time_range}&${__all_variables}",
      "icon": "external link",
      "tooltip": "Detailed query performance metrics",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false
    }
  ]
}
```
Source: [Grafana Dashboard Links](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/manage-dashboard-links/)

### Pattern 6: Annotation for Events
**What:** Markers for restarts, failovers, config changes (per CONTEXT.md)
**When to use:** All dashboards
**Example:**
```json
{
  "annotations": {
    "list": [
      {
        "name": "Restarts",
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "enable": true,
        "expr": "(archerdb_info * 1000) >= $__from",
        "iconColor": "red",
        "tagKeys": "instance",
        "textFormat": "Node restart: {{ instance }}"
      },
      {
        "name": "View Changes",
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "enable": true,
        "expr": "changes(archerdb_vsr_view[5m]) > 0",
        "iconColor": "orange",
        "tagKeys": "instance",
        "textFormat": "VSR view change"
      }
    ]
  }
}
```
Source: [Grafana Annotations](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/annotate-visualizations/)

### Pattern 7: Prometheus Alerting Rule
**What:** YAML rule with tiered thresholds (per CONTEXT.md)
**When to use:** All alerting rules
**Example:**
```yaml
groups:
  - name: archerdb-latency
    rules:
      - alert: ArcherDBHighQueryLatencyWarning
        expr: |
          histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket[5m])) by (le, instance)) > 0.5
        for: 5m
        labels:
          severity: warning
          team: database
        annotations:
          summary: "High query latency on {{ $labels.instance }}"
          description: "p99 query latency is {{ $value | humanizeDuration }} (threshold: 500ms)"
          runbook_url: "https://docs.archerdb.io/runbooks/high-query-latency"
          remediation: "Check for slow queries, index health, or resource contention"

      - alert: ArcherDBHighQueryLatencyCritical
        expr: |
          histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket[5m])) by (le, instance)) > 2
        for: 5m
        labels:
          severity: critical
          team: database
        annotations:
          summary: "Critical query latency on {{ $labels.instance }}"
          description: "p99 query latency is {{ $value | humanizeDuration }} (threshold: 2s)"
          runbook_url: "https://docs.archerdb.io/runbooks/high-query-latency"
          remediation: "Immediate investigation required: check active queries, disk I/O, memory pressure"
```
Source: [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

### Pattern 8: Alertmanager Receiver Configuration
**What:** Notification channel templates (per CONTEXT.md: Slack, PagerDuty, OpsGenie, email, webhook)
**When to use:** Alertmanager configuration templates
**Example:**
```yaml
# Slack receiver template
receivers:
  - name: 'slack-warnings'
    slack_configs:
      - api_url: '{{ .SlackWebhookURL }}'
        channel: '#archerdb-alerts'
        title: '{{ template "slack.default.title" . }}'
        text: |
          {{ range .Alerts }}
          *Alert:* {{ .Labels.alertname }}
          *Severity:* {{ .Labels.severity }}
          *Summary:* {{ .Annotations.summary }}
          *Runbook:* {{ .Annotations.runbook_url }}
          *Remediation:* {{ .Annotations.remediation }}
          {{ end }}
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'

  - name: 'pagerduty-critical'
    pagerduty_configs:
      - routing_key: '{{ .PagerDutyKey }}'
        severity: 'critical'
        description: '{{ .CommonAnnotations.summary }}'
        details:
          runbook: '{{ .CommonAnnotations.runbook_url }}'
          remediation: '{{ .CommonAnnotations.remediation }}'
```
Source: [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)

### Anti-Patterns to Avoid
- **Too many panels per row:** More than 2 panels becomes hard to read on most screens. Use 2 per row (w=12 each).
- **Hardcoded instance names:** Use template variables instead for portability.
- **Missing runbook links:** Per CONTEXT.md, every alert MUST include runbook_url annotation.
- **Alert without `for` duration:** Always use `for: 5m` minimum to prevent flapping.
- **Mixing warning and critical in same group:** Separate rule groups for easier routing.
- **Region annotations from Prometheus:** Prometheus only supports point-in-time annotations, not regions.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Percentile calculation | Manual bucket math | `histogram_quantile()` PromQL function | Prometheus does interpolation server-side correctly |
| Dashboard refresh | Custom polling logic | Grafana's built-in refresh (`"refresh": "30s"`) | Handles all edge cases, user control |
| Alert deduplication | Custom logic in rules | Alertmanager grouping (`group_by`) | Handles timing, batching, state |
| Alert escalation | Multiple rules | Alertmanager routing (`routes`) | Single source of truth for routing policy |
| Time range in links | Manual URL construction | `${__url_time_range}` variable | Always correct format |
| Panel tooltips | Custom HTML | Grafana description field | Renders markdown, theme-aware |
| Variable interpolation | String concatenation | `$variable` or `${variable}` syntax | Handles escaping, multi-value |

**Key insight:** Grafana and Prometheus have mature solutions for every dashboard/alerting pattern. The work is configuration, not code.

## Common Pitfalls

### Pitfall 1: High Cardinality in Dashboard Queries
**What goes wrong:** Dashboard loads slowly or times out
**Why it happens:** Queries returning too many time series (e.g., per-entity metrics)
**How to avoid:** Use `sum()`, `avg()`, or `topk()` to limit series count. Filter by `instance=~"$instance"`.
**Warning signs:** Dashboard load time >5s, browser memory spike

### Pitfall 2: Alert Flapping
**What goes wrong:** Alert fires and resolves repeatedly
**Why it happens:** Missing or too-short `for` duration
**How to avoid:** Always use `for: 5m` minimum for warnings, `for: 2m` for critical
**Warning signs:** Notification spam, PagerDuty fatigue

### Pitfall 3: Prometheus Annotation Limitations
**What goes wrong:** Region annotations don't work
**Why it happens:** Prometheus only supports point-in-time annotations, not spans
**How to avoid:** Use single-point annotations (restart time, config change time). For spans, use separate visualization.
**Warning signs:** Empty annotation queries when expecting regions

### Pitfall 4: Dashboard Variable Conflicts
**What goes wrong:** Variables don't work after navigation
**Why it happens:** Variable names differ between dashboards
**How to avoid:** Use consistent variable names across all dashboards (`instance`, `datasource`, `terminology`)
**Warning signs:** "No data" panels after clicking dashboard links

### Pitfall 5: Missing Datasource Variable
**What goes wrong:** Dashboard only works in one environment
**Why it happens:** Hardcoded datasource UID
**How to avoid:** Always use `$datasource` variable, set as first variable in list
**Warning signs:** Dashboard shows errors in staging/production after working in dev

### Pitfall 6: Incorrect Histogram Bucket Queries
**What goes wrong:** Latency percentiles are inaccurate
**Why it happens:** Using `sum()` without preserving `le` label
**How to avoid:** Always include `by (le)` or `by (le, instance)` in histogram aggregations
**Warning signs:** p99 lower than p95, or wildly different from actual latency
**Correct pattern:** `histogram_quantile(0.99, sum(rate(metric_bucket[5m])) by (le))`

### Pitfall 7: Alert Annotations Not Templated
**What goes wrong:** Alert messages show literal `{{ $value }}` text
**Why it happens:** Wrong template syntax or missing template block
**How to avoid:** Use Go template syntax in annotations: `{{ $value }}`, `{{ $labels.instance }}`
**Warning signs:** Literal template strings in notifications

## Code Examples

### Complete Time Series Panel (Query Latency)
```json
{
  "type": "timeseries",
  "title": "Query Latency",
  "description": "Read query latency percentiles. Lower is better. p99 >500ms triggers warning, >2s triggers critical alert.",
  "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
  "id": 1,
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "targets": [
    {
      "expr": "histogram_quantile(0.50, sum(rate(archerdb_read_latency_seconds_bucket{instance=~\"$instance\"}[5m])) by (le))",
      "legendFormat": "p50"
    },
    {
      "expr": "histogram_quantile(0.95, sum(rate(archerdb_read_latency_seconds_bucket{instance=~\"$instance\"}[5m])) by (le))",
      "legendFormat": "p95"
    },
    {
      "expr": "histogram_quantile(0.99, sum(rate(archerdb_read_latency_seconds_bucket{instance=~\"$instance\"}[5m])) by (le))",
      "legendFormat": "p99"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "s",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 0.5},
          {"color": "red", "value": 2}
        ]
      }
    }
  },
  "options": {
    "tooltip": {"mode": "multi"},
    "legend": {"displayMode": "table", "placement": "bottom"}
  }
}
```

### Complete Stat Panel (Operations per Second)
```json
{
  "type": "stat",
  "title": "Write Ops/sec",
  "description": "Current write operations per second across all nodes.",
  "gridPos": {"x": 0, "y": 8, "w": 6, "h": 4},
  "id": 2,
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "targets": [
    {
      "expr": "sum(rate(archerdb_write_operations_total{instance=~\"$instance\"}[5m]))",
      "legendFormat": "writes/s"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "ops",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "green", "value": null}
        ]
      }
    }
  },
  "options": {
    "colorMode": "value",
    "graphMode": "area",
    "justifyMode": "auto",
    "textMode": "auto"
  }
}
```

### Complete Gauge Panel (Memory Usage)
```json
{
  "type": "gauge",
  "title": "Memory Usage",
  "description": "Current memory utilization. Warning at 70%, Critical at 85%.",
  "gridPos": {"x": 6, "y": 8, "w": 6, "h": 4},
  "id": 3,
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "targets": [
    {
      "expr": "avg(archerdb_memory_used_bytes{instance=~\"$instance\"} / archerdb_memory_allocated_bytes{instance=~\"$instance\"}) * 100",
      "legendFormat": "memory %"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "min": 0,
      "max": 100,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 70},
          {"color": "red", "value": 85}
        ]
      }
    }
  },
  "options": {
    "showThresholdLabels": false,
    "showThresholdMarkers": true
  }
}
```

### Complete Replication Lag Alert (Time + Ops)
```yaml
# Per CONTEXT.md: alert on whichever breaches first
groups:
  - name: archerdb-replication-warnings
    rules:
      - alert: ArcherDBReplicationLagTimeWarning
        expr: |
          max(archerdb_vsr_replication_lag_seconds) by (instance) > 30
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag >30s on {{ $labels.instance }}"
          description: "Current lag: {{ $value | humanizeDuration }}"
          runbook_url: "https://docs.archerdb.io/runbooks/replication-lag"
          remediation: "Check network connectivity, replica health, and disk I/O"

      - alert: ArcherDBReplicationLagOpsWarning
        expr: |
          max(archerdb_vsr_replication_lag_ops) by (instance) > 1000
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag >1000 ops on {{ $labels.instance }}"
          description: "Current lag: {{ $value }} operations behind"
          runbook_url: "https://docs.archerdb.io/runbooks/replication-lag"
          remediation: "Check network connectivity, replica health, and disk I/O"

  - name: archerdb-replication-critical
    rules:
      - alert: ArcherDBReplicationLagTimeCritical
        expr: |
          max(archerdb_vsr_replication_lag_seconds) by (instance) > 120
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Critical replication lag >2min on {{ $labels.instance }}"
          description: "Current lag: {{ $value | humanizeDuration }}"
          runbook_url: "https://docs.archerdb.io/runbooks/replication-lag"
          remediation: "Immediate investigation: replica may need resync"

      - alert: ArcherDBReplicationLagOpsCritical
        expr: |
          max(archerdb_vsr_replication_lag_ops) by (instance) > 10000
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Critical replication lag >10000 ops on {{ $labels.instance }}"
          description: "Current lag: {{ $value }} operations behind"
          runbook_url: "https://docs.archerdb.io/runbooks/replication-lag"
          remediation: "Immediate investigation: replica may need resync"
```

### Grafana Provisioning Configuration
```yaml
# observability/grafana/provisioning/dashboards.yaml
apiVersion: 1
providers:
  - name: 'archerdb'
    orgId: 1
    folder: 'ArcherDB'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/dashboards/archerdb
      foldersFromFilesStructure: false
```
Source: [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)

## Available ArcherDB Metrics

Based on metrics.zig, the following metrics are available for dashboards:

### Write Operations
- `archerdb_write_operations_total` (counter, labels: operation=insert|upsert|delete)
- `archerdb_write_events_total` (counter)
- `archerdb_write_bytes_total` (counter)
- `archerdb_write_latency_seconds` (histogram)
- `archerdb_write_errors_total` (counter)

### Read Operations
- `archerdb_read_operations_total` (counter, labels: query_type=uuid|radius|polygon|latest)
- `archerdb_read_events_returned_total` (counter)
- `archerdb_read_latency_seconds` (histogram)

### Replication (VSR)
- `archerdb_vsr_view` (gauge)
- `archerdb_vsr_status` (gauge)
- `archerdb_vsr_is_primary` (gauge)
- `archerdb_vsr_op_number` (gauge)
- `archerdb_vsr_view_changes_total` (counter)
- `archerdb_vsr_replication_lag_ops` (gauge, per replica)
- `archerdb_vsr_replication_lag_seconds` (gauge, per replica)

### Storage/Memory
- `archerdb_memory_allocated_bytes` (gauge)
- `archerdb_memory_used_bytes` (gauge)
- `archerdb_memory_ram_index_bytes` (gauge)
- `archerdb_memory_cache_bytes` (gauge)
- `archerdb_data_file_size_bytes` (gauge)
- `archerdb_disk_read_latency_seconds` (histogram)
- `archerdb_disk_write_latency_seconds` (histogram)

### LSM/Compaction
- `archerdb_compaction_duration_seconds` (histogram)
- `archerdb_compaction_total` (counter)
- `archerdb_compaction_bytes_read_total` (counter)
- `archerdb_compaction_bytes_written_total` (counter)
- `archerdb_lsm_tables_count` (gauge, per level)
- `archerdb_lsm_level_size_bytes` (gauge, per level)
- `archerdb_lsm_write_amplification_ratio` (gauge)

### Index
- `archerdb_index_entries` (gauge)
- `archerdb_index_capacity` (gauge)
- `archerdb_index_load_factor` (gauge)
- `archerdb_index_tombstone_ratio` (gauge)
- `archerdb_index_lookup_latency_seconds` (histogram)

### Cluster/Coordinator
- `archerdb_coordinator_connections_active` (gauge)
- `archerdb_coordinator_queries_total` (counter, labels: type=single|fanout)
- `archerdb_coordinator_query_duration_seconds` (histogram)
- `archerdb_coordinator_shards_total` (gauge)
- `archerdb_coordinator_shards_healthy` (gauge)

### Health/Info
- `archerdb_info` (gauge, labels: version, commit)
- `archerdb_health_status` (gauge)
- `archerdb_build_info` (gauge)
- `archerdb_active_connections` (gauge)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Grafana UI dashboard creation | JSON provisioning + git | 2020+ | Version control, IaC |
| Prometheus recording rules for percentiles | Direct histogram_quantile | Prometheus 2.0 | Simpler, native |
| Alertmanager inline templates | External template files | Alertmanager 0.20 | Reusable, maintainable |
| Static dashboards | Template variables | Always | Single dashboard, multiple envs |
| Per-alert routing | Label-based routing | Always | Scalable routing policy |

**Deprecated/outdated:**
- **Graph panel:** Use Time Series instead (Graph is legacy)
- **Singlestat panel:** Use Stat instead (Singlestat is deprecated)
- **Legacy Alertmanager webhook format:** Use v2 API format

## Open Questions

Things that couldn't be fully resolved:

1. **Restart/failover annotation detection**
   - What we know: `archerdb_info` metric exists with start time semantics
   - What's unclear: Best PromQL expression for detecting restart events
   - Recommendation: Use `changes(archerdb_vsr_view[5m]) > 0` for view changes, `(time() - process_start_time_seconds) < 300` pattern for recent restarts

2. **Terminology toggle implementation**
   - What we know: Custom variable can hold archerdb|database|plain values
   - What's unclear: How to switch panel titles/descriptions based on variable
   - Recommendation: Use panel title transformations or conditional text panels; may require Grafana 10+ features

3. **Exact panel layouts for detail dashboards**
   - What we know: Overview + 4 detail dashboards, 2 panels per row
   - What's unclear: Exact panel selection for each detail dashboard
   - Recommendation: Claude's discretion per CONTEXT.md; research provides metric inventory

4. **Alertmanager config vs templates**
   - What we know: Users need Slack, PagerDuty, OpsGenie, email, webhook
   - What's unclear: Should we provide full alertmanager.yml or just receiver snippets?
   - Recommendation: Provide modular receiver templates users can copy into their config

## Sources

### Primary (HIGH confidence)
- [Grafana Dashboard JSON Model](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/view-dashboard-json-model/) - JSON structure
- [Grafana Variables](https://grafana.com/docs/grafana/latest/dashboards/variables/add-template-variables/) - Template variables
- [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/) - Layout patterns
- [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/) - File-based provisioning
- [Grafana Dashboard Links](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/manage-dashboard-links/) - Navigation
- [Grafana Annotations](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/annotate-visualizations/) - Event markers
- [Grafana Data Links](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/configure-data-links/) - Drill-down links
- [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/) - Rule YAML syntax
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/) - Receiver config
- [Prometheus Histograms](https://prometheus.io/docs/practices/histograms/) - histogram_quantile usage
- `/home/g/archerdb/src/archerdb/metrics.zig` - Available metrics (verified)

### Secondary (MEDIUM confidence)
- [Awesome Prometheus Alerts](https://samber.github.io/awesome-prometheus-alerts/rules.html) - Alert examples
- [Grafana Step-by-Step Alertmanager Guide](https://grafana.com/blog/step-by-step-guide-to-setting-up-prometheus-alertmanager-with-slack-pagerduty-and-gmail/) - Integration patterns

### Tertiary (LOW confidence)
- WebSearch results for dashboard patterns - Community practices

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Official Grafana/Prometheus documentation
- Architecture: HIGH - JSON/YAML formats are stable, well-documented
- Pitfalls: HIGH - Common issues documented in official guides
- Code examples: HIGH - Based on official docs + verified metrics

**Research date:** 2026-01-23
**Valid until:** 90 days (Grafana/Prometheus formats are very stable)
