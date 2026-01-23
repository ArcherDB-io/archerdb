---
phase: 08-observability-dashboards
plan: 02
subsystem: dashboards
tags: [grafana, vsr, replication, lsm, storage, observability]
requires: [07-01]
provides: [replication-dashboard, storage-dashboard]
affects: [08-03]
tech-stack:
  added: []
  patterns: [grafana-dashboard-json, promql-histogram-quantile, threshold-lines]
key-files:
  created:
    - observability/grafana/dashboards/archerdb-replication.json
    - observability/grafana/dashboards/archerdb-storage.json
  modified: []
decisions:
  - key: "Replica health derived metric"
    choice: "Calculate from lag thresholds using clamp_max"
    reason: "Single panel shows healthy/degraded/unhealthy without additional metric"
  - key: "Write amplification thresholds"
    choice: "15x warning, 30x critical"
    reason: "Enterprise tuning targets <15x per RESEARCH.md"
  - key: "Disk latency thresholds"
    choice: "10ms p99 for SSDs"
    reason: "Standard SSD expectations documented in panel descriptions"
metrics:
  duration: "5 min"
  completed: "2026-01-23"
---

# Phase 08 Plan 02: Replication and Storage Dashboards Summary

VSR replication and LSM storage detail dashboards with comprehensive PromQL queries, threshold lines, and panel descriptions for technical operators.

## Completed Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create Replication detail dashboard | d9133d1 | observability/grafana/dashboards/archerdb-replication.json |
| 2 | Create Storage detail dashboard | b7e213b | observability/grafana/dashboards/archerdb-storage.json |

## Key Deliverables

### Replication Dashboard (8 panels)

**Row 1 - Cluster State:**
- Node Status table: Instance, VSR status (mapped to Normal/View Change/Recovering), is_primary (mapped to Replica/PRIMARY), view, op_number
- Current View stat: max(archerdb_vsr_view) with sparkline

**Row 2 - Replication Lag:**
- Lag by Time: archerdb_vsr_replication_lag_seconds with 30s warning, 120s critical threshold lines
- Lag by Operations: archerdb_vsr_replication_lag_ops with 1000/10000 threshold lines

**Row 3 - View History:**
- View Changes: increase(archerdb_vsr_view_changes_total[5m]) showing leader election frequency
- Operation Number: archerdb_vsr_op_number showing commit progress per node

**Row 4 - Primary & Replica Status:**
- Primary Node: Displays which instance has is_primary=1
- Replica Health: Derived metric from lag (0=healthy, 1=degraded, 2=unhealthy)

**Annotations:**
- View changes: Orange markers when changes(archerdb_vsr_view[5m]) > 0
- Primary changes: Red markers when changes(archerdb_vsr_is_primary[5m]) > 0 (failover events)

### Storage Dashboard (12 panels)

**Row 1 - LSM Overview:**
- LSM Level Sizes: Stacked area of archerdb_lsm_level_size_bytes by level (L0-L6)
- Tables per Level: Stacked bar of archerdb_lsm_tables_count by level

**Row 2 - Compaction:**
- Compaction Duration: histogram_quantile p50/p95/p99 of archerdb_compaction_duration_seconds
- Compaction Throughput: rate(bytes_read_total) and rate(bytes_written_total)

**Row 3 - Write Amplification:**
- Write Amplification Ratio: archerdb_lsm_write_amplification_ratio with 15x/30x threshold lines
- Compactions/hour: increase(archerdb_compaction_total[1h]) stat

**Row 4 - Disk I/O:**
- Disk Read Latency: histogram_quantile p50/p95/p99 with 10ms p99 threshold
- Disk Write Latency: histogram_quantile p50/p95/p99 with 10ms p99 threshold

**Row 5 - Memory Breakdown:**
- Memory by Component: Stacked chart (RAM Index, Cache, Other)
- Data File Size: archerdb_data_file_size_bytes per instance

**Row 6 - Checkpoint:**
- Checkpoint Duration: histogram_quantile p50/p95/p99
- Checkpoints/hour: increase(archerdb_checkpoint_total[1h]) stat

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replica health calculation | Derived from lag metrics using clamp_max | Single panel shows health state without requiring additional metric |
| Write amplification thresholds | 15x warning, 30x critical | Aligns with enterprise tuning targets from RESEARCH.md |
| Disk latency thresholds | 10ms p99 for SSDs | Industry standard expectation, documented in panel descriptions |
| Level visualization | L0-L6 color-coded by level | Follows LSM convention, L0 smallest to L6 largest |

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

All verification criteria passed:
- Both JSON files are valid
- Both use consistent variables (datasource, instance, terminology)
- Replication dashboard covers all archerdb_vsr_* metrics
- Storage dashboard covers LSM, compaction, disk I/O, memory, checkpoint
- All panels have descriptions
- Threshold lines added for key metrics
- Panel counts match requirements (8 and 12)
- Dashboard links in place

## Technical Notes

**PromQL Patterns Used:**
- `histogram_quantile(0.99, sum(rate(metric_bucket[5m])) by (le))` for latency percentiles
- `increase(counter[1h])` for hourly counts
- `changes(metric[5m]) > 0` for event detection annotations
- `clamp_max(expression, 2)` for bounded health status

**Grafana Schema:**
- schemaVersion: 39
- All panels use gridPos with w=12 for 2 panels per row
- Table panel uses transformations for multi-query merge
- Value mappings for enum displays (VSR status, primary designation)

## Next Phase Readiness

Ready for Plan 08-03 (Alerting Rules and Cluster Dashboard):
- Consistent variable naming established
- Dashboard linking convention in place
- archerdb-cluster dashboard placeholder in links
