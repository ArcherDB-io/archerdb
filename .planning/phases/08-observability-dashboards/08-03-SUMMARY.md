---
phase: 08-observability-dashboards
plan: 03
subsystem: observability
tags: [grafana, prometheus, alertmanager, alerts, cluster, notifications]

# Dependency graph
requires:
  - phase: 08-01
    provides: Overview and queries dashboards, template variables, directory structure
  - phase: 08-02
    provides: Replication and storage dashboards, consistent variable naming
  - phase: 07-01
    provides: Prometheus metrics (archerdb_*, process_*)
provides:
  - Cluster detail dashboard with node health and coordinator metrics
  - Warning-level Prometheus alerting rules (12 rules)
  - Critical-level Prometheus alerting rules (17 rules)
  - Alertmanager notification templates for 5 channels
affects: [09-documentation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Tiered alerting (warning -> critical progression)
    - runbook_url and remediation annotations on all alerts
    - Templated notification messages with severity-based formatting
    - Alert inhibition patterns (critical suppresses warning)

key-files:
  created:
    - observability/grafana/dashboards/archerdb-cluster.json
    - observability/prometheus/rules/archerdb-warnings.yaml
    - observability/prometheus/rules/archerdb-critical.yaml
    - observability/alertmanager/templates/slack.tmpl
    - observability/alertmanager/templates/pagerduty.tmpl
    - observability/alertmanager/templates/opsgenie.tmpl
    - observability/alertmanager/templates/email.tmpl
    - observability/alertmanager/templates/webhook.tmpl
    - observability/alertmanager/README.md
  modified: []

key-decisions:
  - "Alert thresholds follow CONTEXT.md: latency 500ms/2s, memory 70%/85%, replication lag 30s/2min"
  - "All alerts include runbook_url annotation (required per CONTEXT.md)"
  - "for duration: 5m for warnings, 2m for critical (except node down at 1m)"
  - "Alertmanager templates provided as YAML snippets to copy, not Go templates"
  - "Email template includes HTML styling for rich notifications"

patterns-established:
  - "Alert groups organized by category: latency, replication, resource, error, cluster"
  - "Severity label for routing: warning -> Slack, critical -> PagerDuty"
  - "remediation annotation provides quick fix hint for first responders"

# Metrics
duration: 5min
completed: 2026-01-23
---

# Phase 08 Plan 03: Cluster Dashboard and Alerting Summary

**Cluster detail dashboard with 10 panels, 29 Prometheus alerting rules with runbook links, and Alertmanager templates for Slack, PagerDuty, OpsGenie, email, and webhook**

## Performance

- **Duration:** 5 min
- **Started:** 2026-01-23T04:27:59Z
- **Completed:** 2026-01-23T04:33:XX Z
- **Tasks:** 3
- **Files created:** 9

## Accomplishments

- Created cluster detail dashboard (10 panels) covering:
  - Node health table with color-coded status, version, uptime, connections
  - Healthy nodes percentage with threshold-based coloring
  - Active connections and connection errors per instance
  - Coordinator query rate by type (single/fanout)
  - Coordinator query duration histograms (p50/p95/p99)
  - Total shards and healthy shards percentage gauge
  - Version info table and uptime stats
- Created 12 warning-level alerting rules covering latency, replication lag, memory, disk, errors, compaction
- Created 17 critical-level alerting rules covering node down, high latency, replication failures, resource exhaustion
- All 29 alerts have runbook_url and remediation annotations
- Created Alertmanager templates for 5 notification channels with routing examples

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Cluster detail dashboard** - `f94871f` (feat)
2. **Task 2: Create Prometheus alerting rules** - `9cfeae7` (feat)
3. **Task 3: Create Alertmanager notification templates** - `a6c03b7` (feat)

## Files Created

- `observability/grafana/dashboards/archerdb-cluster.json` - 756 lines, 10 panels
- `observability/prometheus/rules/archerdb-warnings.yaml` - 12 warning rules
- `observability/prometheus/rules/archerdb-critical.yaml` - 17 critical rules
- `observability/alertmanager/templates/slack.tmpl` - Slack webhook config
- `observability/alertmanager/templates/pagerduty.tmpl` - PagerDuty Events API config
- `observability/alertmanager/templates/opsgenie.tmpl` - OpsGenie config with priority mapping
- `observability/alertmanager/templates/email.tmpl` - HTML email with styling
- `observability/alertmanager/templates/webhook.tmpl` - Generic webhook config
- `observability/alertmanager/README.md` - Setup guide with routing examples

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Alert thresholds | Matches CONTEXT.md exactly | 500ms/2s latency, 70%/85% memory, 30s/2min replication lag |
| for duration | 5m warning, 2m critical | Prevents flapping while ensuring timely critical alerts |
| Node down timing | 1m for | Faster detection for complete node loss |
| Template format | YAML snippets, not Go templates | Easier to copy-paste into alertmanager.yml |
| Email formatting | HTML with CSS | Rich visual alerts for email-only recipients |

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - all tasks completed successfully on first attempt.

## User Setup Required

To use the alerting system:

1. **Prometheus Rules:**
   - Copy `observability/prometheus/rules/*.yaml` to your Prometheus rules directory
   - Add to `rule_files:` in prometheus.yml
   - Reload Prometheus: `kill -HUP $(pidof prometheus)` or API call

2. **Alertmanager Templates:**
   - Review templates in `observability/alertmanager/templates/`
   - Copy relevant receiver configs to your `alertmanager.yml`
   - Replace placeholder values (webhook URLs, API keys)
   - See `observability/alertmanager/README.md` for routing examples

3. **Grafana Dashboard:**
   - Import `archerdb-cluster.json` via Grafana UI or provisioning
   - Dashboard links are already connected to overview and other detail dashboards

## Phase 8 Complete Summary

With this plan complete, Phase 8 deliverables are:

| Plan | Dashboards | Panels | Other |
|------|-----------|--------|-------|
| 08-01 | Overview, Queries | 18 | Provisioning config, directory structure |
| 08-02 | Replication, Storage | 20 | - |
| 08-03 | Cluster | 10 | 29 alerting rules, 5 notification templates |
| **Total** | **5 dashboards** | **48 panels** | **29 alerts, 5 templates** |

## Next Phase Readiness

- All observability dashboards complete
- Alerting rules ready for production use (pending runbook creation in Phase 9)
- Runbook URLs in alerts point to https://docs.archerdb.io/runbooks/* (to be created in Phase 9)
- Ready for Phase 9 (Documentation)

---
*Phase: 08-observability-dashboards*
*Plan: 03*
*Completed: 2026-01-23*
