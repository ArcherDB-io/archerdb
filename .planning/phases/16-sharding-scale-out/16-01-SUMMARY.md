---
phase: 16-sharding-scale-out
plan: 01
subsystem: observability
tags: [prometheus, metrics, sharding, health, rebalance]

# Dependency graph
requires:
  - phase: 15-cluster-consensus
    provides: Cluster metrics registry and health endpoints
provides:
  - Hot shard and rebalance gauges in Prometheus output
  - Expanded /health/shards payload with resharding and hot-shard signals
affects: [online-resharding, sharding-queries, tracing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Weighted hot-shard scoring using throughput/latency/queue signals
    - Rebalance cooldown tracking surfaced via metrics

key-files:
  created: []
  modified:
    - src/archerdb/metrics.zig
    - src/archerdb/metrics_server.zig
    - src/archerdb/cluster_metrics.zig

key-decisions:
  - "Normalized hot-shard queue and latency scores using load_shedding defaults for consistent weighting"
  - "Rebalance slots decay after cooldown expiry to keep active-move gauges actionable"

patterns-established:
  - "Hot shard scoring: 0-100 gauge derived from throughput, queue depth, and latency P99"
  - "Rebalance gating: threshold + ratio guard + cooldown + max-concurrency"

# Metrics
duration: 8 min
completed: 2026-01-25
---

# Phase 16 Plan 01: Shard Rebalancing Visibility Summary

**Hot-shard alerting now blends throughput, queue, and latency signals with rebalance gating in Prometheus and /health/shards.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-01-25T12:54:09Z
- **Completed:** 2026-01-25T13:03:03Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- Added hot shard and rebalance gauges alongside existing sharding metrics
- Implemented weighted hot-shard scoring with cooldown-aware rebalance state updates
- Expanded /health/shards JSON with resharding, hot shard, and rebalance fields plus tests

## Task Commits

Each task was committed atomically:

1. **Task 1: Add hot shard + rebalance gauges to metrics registry** - `650ffe2` (feat)
2. **Task 2: Compute hot shard score and update rebalance state** - `5524415` (feat)
3. **Task 3: Expand /health/shards response and add coverage** - `233c644` (feat)

**Plan metadata:** _Pending_

## Files Created/Modified
- `src/archerdb/metrics.zig` - Defines hot shard/rebalance gauges and Prometheus formatting
- `src/archerdb/metrics_server.zig` - Computes hot shard scoring, rebalance gating, and expanded health payload
- `src/archerdb/cluster_metrics.zig` - Exposes metrics module for test resets

## Decisions Made
- Normalized hot-shard queue and latency scores using load_shedding defaults for consistent weighting
- Rebalance slots decay after cooldown expiry to keep active-move gauges actionable

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Exported cluster_metrics.metrics for test reset visibility**
- **Found during:** Task 1 (metrics registry verification)
- **Issue:** Metrics unit tests failed because connection_pool test resets referenced a non-public metrics module
- **Fix:** Made cluster_metrics.metrics public to unblock tests
- **Files modified:** src/archerdb/cluster_metrics.zig
- **Verification:** `./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "metrics"`
- **Committed in:** 650ffe2

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Needed to unblock verification; no scope expansion beyond test visibility.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Ready for 16-02-PLAN.md (online resharding controller + topology notifications)

---
*Phase: 16-sharding-scale-out*
*Completed: 2026-01-25*
