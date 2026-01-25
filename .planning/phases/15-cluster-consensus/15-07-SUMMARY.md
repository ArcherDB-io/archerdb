---
phase: 15-cluster-consensus
plan: 07
subsystem: infra
tags: [connection-pool, message-bus, cluster-metrics, prometheus]

# Dependency graph
requires:
  - phase: 15-cluster-consensus
    provides: "ServerConnectionPool and ClusterMetrics definitions"
provides:
  - "Metrics registry exports cluster pool/shed/routing series"
  - "MessageBus accept path acquires/releases pooled connections"
affects: [15-08, 16-sharding-scale-out, observability]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Registry-owned ClusterMetrics singleton with accessor"
    - "Inbound accept path reserves pooled connection slots"

key-files:
  created: []
  modified:
    - src/archerdb/metrics.zig
    - src/archerdb/cluster_metrics.zig
    - src/message_bus.zig

key-decisions:
  - "Partition outbound replica connections from pooled accept slots via client_pool_offset"

patterns-established:
  - "Release pooled connections after state reset in terminate_close_callback"

# Metrics
duration: 14 min
completed: 2026-01-25
---

# Phase 15 Plan 07: Connection Pool Integration Summary

**Prometheus exports now include cluster pool/shed/routing metrics and MessageBus accepts reserve pooled connection slots.**

## Performance

- **Duration:** 14 min
- **Started:** 2026-01-25T07:18:10Z
- **Completed:** 2026-01-25T07:32:51Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Registered ClusterMetrics in the global metrics registry with a stable accessor
- Routed inbound accepts through ServerConnectionPool acquire/release tracking
- Partitioned outbound replica slots from pooled accept slots to avoid conflicts

## Task Commits

Each task was committed atomically:

1. **Task 1: Export ClusterMetrics via Registry.format** - `1dc5f5f` (feat)
2. **Task 2: Route accepts through ServerConnectionPool** - `969e079` (feat)

## Files Created/Modified
- `src/archerdb/metrics.zig` - Registry-owned ClusterMetrics accessor and format output
- `src/archerdb/cluster_metrics.zig` - Silence unused parameter warnings for new export path
- `src/message_bus.zig` - Inbound accept pooling with release on termination

## Decisions Made
- Partitioned outbound replica connection slots from pooled accept slots via `client_pool_offset` to prevent pool/connector contention while preserving inbound capacity.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added unused parameter suppression in ClusterMetrics helpers**

- **Found during:** Task 1 verification (build check)
- **Issue:** New registry wiring compiled `ClusterMetrics` helpers with unused parameters, failing the build.
- **Fix:** Added `_ = self;` in `recordAcquireTimeout` and `recordHealthCheck`.
- **Files modified:** `src/archerdb/cluster_metrics.zig`
- **Verification:** `./zig/zig build -j4 -Dconfig=lite check`
- **Commit:** `1dc5f5f`

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Fix required for compilation; no scope change.

## Issues Encountered
- Build check flagged error-union handling in the accept reject path; corrected during Task 2 implementation.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Connection pool integration and cluster metrics export are complete.
- Ready for remaining Phase 15 gap-closure plans (15-08 onward).

---
*Phase: 15-cluster-consensus*
*Completed: 2026-01-25*
