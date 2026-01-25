---
phase: 15-cluster-consensus
plan: 10
subsystem: consensus
tags: [vsr, timeout-profiles, jitter, flexible-paxos, quorum, cli]

# Dependency graph
requires:
  - phase: 15-02
    provides: "Timeout profile presets and jitter support"
  - phase: 15-04
    provides: "Flexible Paxos quorum configuration + validation"
provides:
  - "TimeoutConfig applied to replica timeouts with jittered profiles"
  - "CLI configuration for timeout profiles and quorum presets"
  - "Flexible Paxos quorums validated and wired into replica init"
affects: [phase-16, cluster-operations, consensus-tuning]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Profile-driven timeout configuration passed via CLI to replica init"
    - "Flexible Paxos quorum validation at startup"

key-files:
  created: []
  modified:
    - src/archerdb/cli.zig
    - src/archerdb/main.zig
    - src/stdx/flags.zig
    - src/vsr.zig
    - src/vsr/replica.zig

key-decisions:
  - "Replica timeouts use jittered profile values converted to ticks with ceil rounding"
  - "Quorum presets can be overridden per phase while enforcing Q1+Q2>N"

patterns-established:
  - "TimeoutConfig + QuorumConfig flow from CLI parsing into replica init"

# Metrics
duration: 6 min
completed: 2026-01-25
---

# Phase 15 Plan 10: Timeout Profiles + Quorum Wiring Summary

**Replica initialization now applies jittered timeout profiles and validated flexible Paxos quorums from CLI configuration.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-01-25T08:23:47Z
- **Completed:** 2026-01-25T08:29:52Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Wired TimeoutConfig profile values through CLI, main, and replica init with jittered ticks
- Added CLI quorum presets/overrides and validated Flexible Paxos quorums at startup
- Centralized quorum math in vsr.zig for config-driven replicas

## Task Commits

Each task was committed atomically:

1. **Task 1: Apply timeout profiles during replica initialization** - `ca57922` (feat)
2. **Task 2: Integrate flexible Paxos quorum configuration** - `e0b3368` (feat)

**Plan metadata:** Pending

## Files Created/Modified
- `src/archerdb/cli.zig` - CLI flags and parsing for timeout profiles and quorum presets
- `src/archerdb/main.zig` - Pass TimeoutConfig/QuorumConfig into replica open options
- `src/vsr/replica.zig` - Apply jittered profile timeouts and validate quorum configuration
- `src/vsr.zig` - Export timeout/quorum modules and add config-aware quorum helper
- `src/stdx/flags.zig` - Raise comptime branch quota for expanded CLI flags

## Decisions Made
- Applied jittered profile timeouts using ceil-to-ticks conversion to avoid sub-tick zero values
- Derived quorum majority and nack thresholds from configured phase-1/phase-2 quorums

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Increased comptime branch quota for expanded CLI flag parsing**
- **Found during:** Task 1 (timeout profile CLI wiring)
- **Issue:** Zig compile-time branch quota exceeded after adding new CLI flags
- **Fix:** Raised branch quota in stdx/flags parsing and CLI validation
- **Files modified:** src/stdx/flags.zig, src/archerdb/cli.zig
- **Verification:** `./zig/zig build -j4 -Dconfig=lite check`
- **Committed in:** ca57922

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Required for build success; no scope creep.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 15 consensus tuning is fully wired and validated
- Ready to transition to Phase 16 sharding work

---
*Phase: 15-cluster-consensus*
*Completed: 2026-01-25*
