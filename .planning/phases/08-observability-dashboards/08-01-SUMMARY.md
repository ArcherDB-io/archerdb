---
phase: 08-observability-dashboards
plan: 01
subsystem: observability
tags: [grafana, dashboards, prometheus, visualization, monitoring]

# Dependency graph
requires:
  - phase: 07-observability-core
    provides: Prometheus metrics endpoints and health checks
provides:
  - Overview dashboard with cluster health, throughput, latency, replication
  - Queries detail dashboard with latency by type, error rates, index health
  - Grafana file provisioning configuration
  - Observability directory structure for alerts/rules
affects: [08-02, 08-03, 08-04, 09-documentation]

# Tech tracking
tech-stack:
  added:
    - Grafana Dashboard JSON (schemaVersion 39)
  patterns:
    - Template variables for datasource/instance filtering
    - Dashboard links for drill-down navigation
    - Prometheus annotations for event markers
    - Threshold-based color mapping (green/yellow/red)

key-files:
  created:
    - observability/grafana/dashboards/archerdb-overview.json
    - observability/grafana/dashboards/archerdb-queries.json
    - observability/grafana/provisioning/dashboards.yaml
    - observability/grafana/dashboards/.gitkeep
    - observability/prometheus/rules/.gitkeep
    - observability/alertmanager/templates/.gitkeep
  modified: []

key-decisions:
  - "Template variables: datasource, instance, terminology in that order"
  - "2 panels per row (w=12) with h=8 for spacious layout"
  - "Latency thresholds: 500ms warning, 2s critical (per CONTEXT.md)"
  - "Memory thresholds: 70% warning, 85% critical"
  - "Index load factor thresholds: 70% warning, 90% critical"
  - "Tombstone ratio thresholds: 10% warning, 30% critical"

patterns-established:
  - "All panels use ${datasource} and instance=~$instance filter"
  - "Rich descriptions explaining what each panel shows and why it matters"
  - "Dashboard links pass time range and variables via ${__url_time_range} and ${__all_variables}"
  - "Annotations mark VSR view changes (orange) and recent node starts (red)"

# Metrics
duration: 4min
completed: 2026-01-23
---

# Phase 8 Plan 1: Overview and Queries Dashboards Summary

**Grafana overview dashboard with health/throughput/latency/replication and queries detail dashboard with latency by type, error rates, and index health**

## Performance

- **Duration:** 4 min
- **Started:** 2026-01-23T04:19:24Z
- **Completed:** 2026-01-23T04:23:21Z
- **Tasks:** 3
- **Files created:** 6

## Accomplishments

- Created observability directory structure with grafana/prometheus/alertmanager subdirectories
- Created Grafana file provisioning configuration pointing to dashboards folder
- Created Overview dashboard with 8 panels covering:
  - Cluster Health stat (worst health status across nodes)
  - Active Nodes stat (healthy count / total count)
  - Write Throughput by operation type (insert/upsert/delete)
  - Read Throughput by query type (uuid/radius/polygon/latest)
  - Write Latency percentiles (p50/p95/p99)
  - Read Latency percentiles (p50/p95/p99)
  - Replication Lag (seconds and ops)
  - Memory Usage gauge with 70%/85% thresholds
- Created Queries detail dashboard with 10 panels covering:
  - Read Latency by Query Type (uuid/radius/polygon/latest p99)
  - Write Latency by Operation (insert/upsert/delete p99)
  - Read Operations Rate (stacked by type)
  - Write Operations Rate (stacked by type)
  - Events Processed (read/write events per second)
  - Write Bytes throughput
  - Error Rate with zero baseline highlight
  - Index Lookup Latency (p50/p95/p99)
  - Index Load Factor gauge (70%/90% thresholds)
  - Tombstone Ratio gauge (10%/30% thresholds)
- Implemented template variables: datasource selector, instance filter, terminology toggle
- Added dashboard links for drill-down navigation between dashboards
- Added annotations for VSR view changes and recent node starts

## Task Commits

Each task was committed atomically:

1. **Task 1: Create directory structure and provisioning config** - `7198885` (chore)
2. **Task 2: Create Overview dashboard** - `7b22bdc` (feat)
3. **Task 3: Create Queries detail dashboard** - `0edb817` (feat)

## Files Created

- `observability/grafana/dashboards/archerdb-overview.json` - 594 lines, 8 panels
- `observability/grafana/dashboards/archerdb-queries.json` - 703 lines, 10 panels
- `observability/grafana/provisioning/dashboards.yaml` - File provisioning config
- `observability/grafana/dashboards/.gitkeep` - Preserve directory
- `observability/prometheus/rules/.gitkeep` - Preserve directory
- `observability/alertmanager/templates/.gitkeep` - Preserve directory

## Decisions Made

- **Template variable order:** datasource first (enables instance query), instance second (for filtering), terminology third (display customization)
- **Panel layout:** 2 panels per row (w=12 each) with h=8 for spacious, readable layout per CONTEXT.md
- **Threshold consistency:** All latency panels use 500ms/2s thresholds, all memory/index panels use percentage-based thresholds
- **Annotation markers:** VSR view changes in orange (potential failover), recent starts in red (node restart)
- **Terminology toggle:** Custom variable with archerdb/database/plain options for user preference

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - all tasks completed successfully on first attempt.

## User Setup Required

To use these dashboards:

1. Copy `observability/grafana/dashboards/*.json` to `/etc/grafana/dashboards/archerdb/`
2. Copy `observability/grafana/provisioning/dashboards.yaml` to `/etc/grafana/provisioning/dashboards/`
3. Restart Grafana to load provisioned dashboards
4. Configure Prometheus datasource pointing to your metrics endpoint

## Next Phase Readiness

- Overview and Queries dashboards complete and validated
- Directory structure ready for additional dashboards (replication, storage, cluster)
- Directory structure ready for Prometheus alerting rules
- Directory structure ready for Alertmanager notification templates
- Ready for Phase 8 Plan 2 (Replication dashboard) or Plan 3 (Storage dashboard)

---
*Phase: 08-observability-dashboards*
*Plan: 01*
*Completed: 2026-01-23*
