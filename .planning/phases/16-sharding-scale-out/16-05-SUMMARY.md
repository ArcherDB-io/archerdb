---
phase: 16-sharding-scale-out
plan: 05
subsystem: infra
tags: [sharding, metrics, cli, topology]

# Dependency graph
requires:
  - phase: 16-02
    provides: Online resharding controller and sharding metrics scaffolding
provides:
  - Runtime online resharding control hook with CLI trigger
  - Live resharding progress/dual-write metrics updates in /health/shards
affects: [operations, sharding]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Metrics server control endpoint for online resharding"
    - "Runtime resharding tick loop driven from main event loop"

key-files:
  created: []
  modified:
    - src/archerdb/cli.zig
    - src/archerdb/main.zig
    - src/archerdb/metrics_server.zig
    - src/sharding.zig

key-decisions:
  - "Route online resharding triggers through a metrics-server control endpoint so the running replica can execute controller ticks."

patterns-established:
  - "Control-plane requests are queued via metrics_server and consumed in the runtime loop."

# Metrics
duration: 16 min
completed: 2026-01-25
---

# Phase 16 Plan 05: Online Resharding Runtime Summary

**Online resharding now runs in the live replica loop with CLI-triggered control requests and observable progress metrics.**

## Performance

- **Duration:** 16 min
- **Started:** 2026-01-25T20:37:45Z
- **Completed:** 2026-01-25T20:53:37Z
- **Tasks:** 3
- **Files modified:** 4

## Accomplishments
- Added a metrics-server control hook so `archerdb shard reshard --mode=online` triggers runtime migration ticks.
- Wired the main event loop to drive OnlineReshardingController batches and cutover with live metrics updates.
- Ensured /health/shards reports active resharding, source/target shards, and progress telemetry.

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement online resharding runtime entrypoint** - `9f0888b` (feat)
2. **Task 2: Wire shard CLI to trigger online resharding** - `d26c1c3` (feat)
3. **Task 3: Runtime online resharding command that drives controller ticks** - `8763acc` (fix)

## Files Created/Modified
- `src/archerdb/main.zig` - drive online resharding ticks from the runtime loop.
- `src/archerdb/metrics_server.zig` - accept control requests and report active resharding status.
- `src/sharding.zig` - set online resharding metrics (source/target/start).
- `src/archerdb/cli.zig` - allow online resharding control requests via CLI.

## Decisions Made
- Route online resharding triggers through the metrics server so the running replica can execute controller ticks.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added control endpoint to trigger runtime resharding**
- **Found during:** Task 3 (Runtime online resharding command that drives controller ticks)
- **Issue:** CLI invocation did not reach the running replica, so online resharding never started in runtime.
- **Fix:** Added `/control/reshard/<target>` handling in metrics_server with a request queue and runtime polling loop.
- **Files modified:** src/archerdb/metrics_server.zig, src/archerdb/main.zig, src/archerdb/cli.zig
- **Verification:** `./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "OnlineReshardingController"`
- **Committed in:** 8763acc

**2. [Rule 1 - Bug] Corrected resharding status/metrics reporting**
- **Found during:** Task 3 (Runtime online resharding command that drives controller ticks)
- **Issue:** /health/shards only treated status=preparing as active and online resharding never set source/target/start metrics.
- **Fix:** Treat any non-idle status as resharding and set source/target/start metrics in OnlineReshardingController.
- **Files modified:** src/archerdb/metrics_server.zig, src/sharding.zig
- **Verification:** `./zig/zig build -j4 -Dconfig=lite check`
- **Committed in:** 8763acc

---

**Total deviations:** 2 auto-fixed (1 missing critical, 1 bug)
**Impact on plan:** Both fixes were required for online resharding to start and report metrics in runtime. No scope creep.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Ready for 16-06-PLAN.md.
- Online resharding now updates runtime progress metrics during migration.

---
*Phase: 16-sharding-scale-out*
*Completed: 2026-01-25*
