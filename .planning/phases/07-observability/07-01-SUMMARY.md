---
phase: 07-observability
plan: 01
subsystem: metrics
tags: [prometheus, histogram, trace-id, observability, logging]

dependency-graph:
  requires: [06-security-hardening]
  provides: [updated-histogram-buckets, short-trace-ids, internal-metrics]
  affects: [07-02-alert-rules, 07-03-dashboard, 07-04-logging]

tech-stack:
  added: []
  patterns: [short-trace-id-for-incidents, context-md-driven-bucket-config]

file-tracking:
  key-files:
    created: []
    modified:
      - src/archerdb/metrics.zig
      - src/archerdb/observability/correlation.zig
      - src/archerdb/observability/json_logger.zig

decisions:
  - id: OBS-HIST-BUCKETS
    choice: "10-bucket histogram: 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s"
    reason: "Matches CONTEXT.md specification, removes 500us bucket, adds 25ms and 250ms"
  - id: OBS-SHORT-TRACE
    choice: "12-character short trace ID from first 6 bytes"
    reason: "Easier verbal communication during incidents while remaining greppable"
  - id: OBS-INTERNAL-METRICS
    choice: "Add 11 new internal metrics for compaction, WAL, replication, cache"
    reason: "Comprehensive observability into database internals per CONTEXT.md"

metrics:
  duration: 3 min
  completed: 2026-01-31
---

# Phase 07 Plan 01: Metrics Infrastructure Update Summary

**One-liner:** Updated histogram buckets to CONTEXT.md spec and added 12-char short trace IDs for incident response.

## What Was Done

### Task 1: Update histogram buckets and add internal metrics
- **Changed:** `latencyHistogram()` function in metrics.zig
  - Old: 9 buckets (500us, 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s)
  - New: 10 buckets (1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s)
  - Type changed from `HistogramType(9)` to `HistogramType(10)`
- **Added:** 11 new internal metrics in Registry:
  - Compaction (3): `compaction_pending_bytes`, `compaction_stall_duration_seconds`, `compaction_level_bytes` (with level labels 0-5)
  - WAL (3): `wal_sync_duration_seconds`, `wal_entries_written_total`, `wal_buffer_usage_bytes`
  - Replication (3): `replication_lag_seconds`, `replication_apply_rate_gauge`, `replication_queue_depth`
  - Cache (2): `cache_hit_ratio` (block/index), `cache_evictions_total` (block/index)
- **Updated:** format() function to export all new metrics

### Task 2: Add short trace ID and update JSON logger
- **Added:** `shortTraceId()` method to CorrelationContext returning `[12]u8`
  - Returns first 12 characters of the 32-char trace ID hex
  - Preserves full trace ID internally for W3C compatibility
- **Updated:** JSON logger to use 12-char short trace ID in output
- **Updated:** Log schema documentation in json_logger.zig header
- **Added:** Unit test for shortTraceId() method

## Commits

| Commit | Description | Files |
|--------|-------------|-------|
| 5cd8431 | feat(07-01): update histogram buckets and add internal metrics | metrics.zig |
| 0cc62dd | feat(07-01): add short trace ID and update JSON logger | correlation.zig, json_logger.zig |

## Verification Results

1. **Build passes:** Yes - `./zig/zig build -j4 -Dconfig=lite check` succeeded
2. **Histogram buckets contain 0.025 and 0.25:** Yes - verified with grep
3. **shortTraceId function exists:** Yes - 3 occurrences in correlation.zig
4. **JSON logger uses short trace ID:** Yes - `ctx.shortTraceId()` call present

## Deviations from Plan

None - plan executed exactly as written.

## Key Artifacts

### Updated Files

1. **src/archerdb/metrics.zig**
   - Updated `LatencyHistogram` to use 10 buckets
   - Added 11 new internal metrics for compaction/WAL/replication/cache
   - Updated `format()` function to export new metrics

2. **src/archerdb/observability/correlation.zig**
   - Added `shortTraceId()` method
   - Added test case for the new method

3. **src/archerdb/observability/json_logger.zig**
   - Changed trace_id output from 32-char to 12-char
   - Updated schema documentation

### New Metric Names

```
# Compaction
archerdb_compaction_pending_bytes
archerdb_compaction_stall_duration_seconds
archerdb_compaction_level_bytes{level="0..5"}

# WAL
archerdb_wal_sync_duration_seconds
archerdb_wal_entries_written_total
archerdb_wal_buffer_usage_bytes

# Replication
archerdb_replication_lag_seconds
archerdb_replication_apply_rate
archerdb_replication_queue_depth

# Cache
archerdb_cache_hit_ratio{cache_type="block|index"}
archerdb_cache_evictions_total{cache_type="block|index"}
```

## Next Phase Readiness

- **Dashboard updates:** New metrics available for 07-03 dashboard design
- **Alert rules:** Histogram bucket changes may require updating latency thresholds in 07-02
- **Logging config:** Short trace IDs ready for 07-04 structured logging configuration
