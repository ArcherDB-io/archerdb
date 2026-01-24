---
phase: 12-storage-optimization
plan: 08
subsystem: observability
tags: [grafana, prometheus, dashboards, alerts, monitoring]
requires: [12-02, 12-03, 12-04, 12-05, 12-07]
provides:
  - operator-storage-dashboard
  - developer-deep-dive-dashboard
  - storage-alert-rules
affects: [operations, debugging]
tech-stack:
  added: []
  patterns:
    - grafana-dashboard-json
    - prometheus-alerting-rules
    - health-status-thresholds
key-files:
  created:
    - observability/grafana/dashboards/archerdb-storage-deep.json
    - observability/prometheus/alerts/storage.yml
  modified:
    - observability/grafana/dashboards/archerdb-storage.json
decisions:
  - "Health status calculation: composite score from write amp + space amp + throttle state"
  - "Threshold scheme: green/yellow/red for operator-facing metrics"
  - "Write amplification thresholds: <3 green, 3-5 yellow, >5 red"
  - "Space amplification thresholds: <2 green, 2-3 yellow, >3 red"
  - "Compression ratio thresholds: <0.7 green, 0.7-0.9 yellow, >0.9 red (inverted scale)"
  - "Throttle ratio display: divide by 10 for 0-100% scale (stored as 0-1000)"
  - "Level variable in deep-dive dashboard for per-level metric filtering"
  - "Throttle state change annotations for debugging timeline"
  - "17 alert rules covering 7 categories: write amp, latency, space amp, disk, compaction, compression, emergency"
  - "Alert severity mapping: info for informational, warning for degradation, critical for action required"
metrics:
  duration: ~5min
  completed: 2026-01-24
---

# Phase 12 Plan 08: Storage Dashboards & Alerts Summary

Grafana dashboards extended with Phase 12 metrics and Prometheus alerts defined for storage optimization monitoring.

## One-Liner

Extended storage dashboard with health overview, compression, dedup panels; created developer deep-dive dashboard with per-level metrics; added 17 storage alert rules.

## What Was Delivered

### Task 1: Operator Storage Dashboard Extended

Extended `archerdb-storage.json` with Phase 12 panels:

**Health Overview Row:**
- Storage Health stat (composite green/yellow/red)
- Write Amplification stat with thresholds
- Space Amplification stat with thresholds
- Compression Ratio stat

**Compression Row:**
- Compression ratio time series
- Bytes saved by compression stat
- Compression effectiveness gauge

**Write Amplification Row:**
- Write amplification ratio time series
- Bytes written rate (physical vs logical)

**Compaction Health Row:**
- Throttle ratio gauge (0-100%)
- Compaction duration percentiles
- Compactions per hour stat
- Compaction throughput
- Pending bytes time series

**Block Deduplication Row:**
- Blocks deduplicated stat
- Dedup bytes saved stat
- Deduplication hit rate time series

**Link Added:**
- Storage Deep Dive dashboard for drill-down

### Task 2: Developer Deep-Dive Dashboard Created

Created new `archerdb-storage-deep.json` for debugging:

**Per-Level Statistics Row:**
- Per-level bytes written table
- Per-level write amplification time series
- Per-level compaction rate
- Compaction activity heatmap

**Compaction Details Row:**
- Compaction tables I/O (input vs output)
- Compaction duration percentiles (p50, p90, p99, max)

**Throttle Details Row:**
- Throttle ratio vs P99 latency correlation
- Pending bytes driving throttle decisions

**Deduplication Details Row:**
- Dedup index memory usage
- LRU eviction rate

**Compression Details Row:**
- Compression throughput (bytes in vs out)
- Compression savings rate

**Block I/O Row:**
- Block read/write IOPS
- Cache hit ratio
- Write rate rolling windows (1m, 5m, 1h)

**Features:**
- Level variable for filtering per-level metrics
- Throttle state change annotations
- Links to operator dashboard

### Task 3: Storage Alert Rules Created

Created `observability/prometheus/alerts/storage.yml` with 17 rules in 7 groups:

| Group | Alert | Threshold | Severity |
|-------|-------|-----------|----------|
| write-amp | WriteAmpSpike | >5x for 5m | warning |
| write-amp | WriteAmpCritical | >10x for 10m | critical |
| latency | WriteLatencyHigh | P99 >100ms for 2m | warning |
| latency | ReadLatencyHigh | P99 >100ms for 2m | warning |
| space-amp | SpaceAmpHigh | >3x for 10m | warning |
| space-amp | SpaceAmpCritical | >5x for 15m | critical |
| disk | DiskAlmostFull | >95% for 5m | critical |
| disk | DiskSpaceLow | >85% for 10m | warning |
| compaction | CompactionStall | no writes + throttle 10m | critical |
| compaction | CompactionThrottleExtended | 30m continuous | warning |
| compaction | CompactionPendingHigh | >10GB for 15m | warning |
| compression | CompressionDegraded | ratio >0.7 for 30m | info |
| compression | CompressionVeryPoor | ratio >0.9 for 1h | warning |
| emergency | EmergencyModeActive | instant | critical |
| emergency | L0Backlog | >8 tables for 5m | critical |
| dedup | DedupHighHitRate | >30% for 30m | info |
| dedup | DedupHighEvictions | >100/sec for 10m | warning |

All alerts include runbook URLs and remediation guidance.

## Commits

1. `009842c` - feat(12-08): extend operator storage dashboard with Phase 12 metrics
2. `0bdac50` - feat(12-08): create developer storage deep-dive dashboard
3. `7d651fd` - feat(12-08): create storage alert rules for Phase 12 metrics

## Deviations from Plan

None - plan executed exactly as written.

## Decisions Made

1. **Health calculation**: Composite score from write amp (>5) + space amp (>3) + throttle active, clamped to 0-2 for green/yellow/red display

2. **Metric scaling in queries**: Applied correct divisors for scaled metrics:
   - Write/space amp: divide by 100
   - Compression ratio: divide by 1000
   - Throttle ratio: divide by 10

3. **Dedup metrics fallback**: Added `or vector(0)` to dedup queries since metrics may not exist if dedup is disabled

4. **Alert duration tuning**: Balanced between detecting real issues and avoiding noise:
   - Fast alerts (5m): Write stall, emergency, L0 backlog
   - Medium alerts (10-15m): Amplification warnings
   - Slow alerts (30m-1h): Compression degradation, dedup patterns

## Next Phase Readiness

Phase 12 (Storage Optimization) is now complete:
- [x] 12-01: Block compression codec (LZ4)
- [x] 12-02: Storage metrics infrastructure
- [x] 12-03: Compression read/write integration
- [x] 12-04: Compaction throttle
- [x] 12-05: Tiered compaction strategy
- [x] 12-06: Adaptive compaction tuning
- [x] 12-07: Block-level deduplication
- [x] 12-08: Dashboards and alerts

Ready to proceed to Phase 13 (Memory Optimization) or UAT testing.
