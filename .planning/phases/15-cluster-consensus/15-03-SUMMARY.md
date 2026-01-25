---
phase: 15-cluster-consensus
plan: 03
subsystem: cluster
tags: [load-shedding, overload-protection, 429, retry-after, prometheus, metrics]

# Dependency graph
requires:
  - phase: 15-01
    provides: cluster_metrics module for Prometheus metrics
provides:
  - Load shedding with composite overload detection
  - Hard cutoff shedding behavior with configurable threshold
  - Retry-After calculation based on overload severity
  - Prometheus metrics for shedding decisions
affects: [15-05, 15-06, cluster-integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Composite signal overload detection (queue depth + latency P99 + memory pressure)
    - Hard cutoff shedding curve
    - Configurable thresholds with guardrails

key-files:
  created:
    - src/load_shedding.zig
  modified:
    - src/archerdb/cluster_metrics.zig

key-decisions:
  - "Composite signal: equal weighting of queue depth (0.34), latency P99 (0.33), resource pressure (0.33)"
  - "Hard cutoff shedding: below threshold accept all, at or above reject all"
  - "Threshold guardrails: cannot set below 0.5 or above 0.95 (cannot disable)"
  - "Retry-After calculation: base_retry_ms * (1 + (score - threshold) * 10), capped at max_retry_ms"
  - "Score scaled 0-100 for Prometheus integer gauges"

patterns-established:
  - "LoadShedder pattern: atomic signal updates, thread-safe shouldShed() check"
  - "ShedDecision pattern: accept/reject with score and reason tracking"

# Metrics
duration: 4min
completed: 2026-01-25
---

# Phase 15 Plan 03: Load Shedding Summary

**Composite signal load shedding with hard cutoff, configurable threshold with guardrails, and Prometheus metrics integration**

## Performance

- **Duration:** 4 min
- **Started:** 2026-01-25T05:40:28Z
- **Completed:** 2026-01-25T05:44:24Z
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments
- LoadShedder struct with composite overload detection (queue depth + latency P99 + memory pressure)
- Hard cutoff shedding behavior: below threshold accept, at/above threshold reject with 429
- Configurable threshold with guardrails (0.5-0.95 range, cannot disable)
- Retry-After calculation based on overload severity with exponential backoff
- Full Prometheus metrics for shedding decisions and signals

## Task Commits

Each task was committed atomically:

1. **Task 1: Create load shedding module** - `5c16a36` (feat)
2. **Task 2: Add load shedding metrics** - `59651a9` (feat)
3. **Task 3: Add load shedding tests** - included in `5c16a36` (tests added with module)

## Files Created/Modified
- `src/load_shedding.zig` - Load shedding implementation with LoadShedder, ShedConfig, ShedDecision structs, composite scoring, 15 unit tests
- `src/archerdb/cluster_metrics.zig` - Extended with 7 shed metrics (archerdb_shed_*), helper functions updateShedMetrics() and recordShedRequest()

## Decisions Made
- **Composite signal weighting:** Equal weighting (0.34/0.33/0.33) for balanced consideration of all signals
- **Hard cutoff vs gradual:** Hard cutoff chosen for simplicity and predictability (below=accept, at/above=reject)
- **Threshold guardrails:** Min 0.5, max 0.95 to prevent operator from disabling protection entirely
- **Retry-After exponential:** `base * (1 + overage * 10)` gives meaningful backoff proportional to overload severity
- **Score scaling:** 0-100 integer for Prometheus gauges (avoids float precision issues in alerting)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Load shedding ready for integration with request handlers
- Metrics exposed for Prometheus scraping via cluster_metrics.format()
- LoadShedder can be instantiated with custom config or initDefault()
- Signal updates (updateQueueDepth, updateLatencyP99, updateMemoryPressure) thread-safe for concurrent use

---
*Phase: 15-cluster-consensus*
*Completed: 2026-01-25*
