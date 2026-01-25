---
phase: 15-cluster-consensus
plan: 04
subsystem: consensus
tags: [paxos, quorum, flexible-paxos, consensus, distributed-systems]

# Dependency graph
requires:
  - phase: 15-cluster-consensus
    provides: cluster metrics foundation
provides:
  - QuorumConfig struct with independent phase-1/phase-2 quorum sizes
  - QuorumPreset with classic, fast_commit, strong_leader configurations
  - FlexiblePaxos helper struct for quorum checks
  - validateQuorums function enforcing Q1 + Q2 > N invariant
affects: [replica, leader-election, commit-protocol]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Flexible Paxos quorum configuration (Q1 + Q2 > N)"
    - "Preset-based quorum configuration for common use cases"
    - "Table-driven tests for quorum validation"

key-files:
  created:
    - src/vsr/flexible_paxos.zig
  modified: []

key-decisions:
  - "Q1 + Q2 > N invariant enforced at validation time, not construction time"
  - "fast_commit falls back to classic for N < 3 (can't meaningfully reduce Q2)"
  - "strong_leader uses Q1=N, Q2=1 for maximum commit speed at election availability cost"
  - "u16 cast for invariant check to prevent u8 overflow on large quorums"
  - "Fault tolerance helpers (phase1FaultTolerance, phase2FaultTolerance) for operational insight"

patterns-established:
  - "Preset pattern: static functions returning validated configurations"
  - "Comprehensive doc comments with academic reference and ASCII diagrams"

# Metrics
duration: 3min
completed: 2026-01-25
---

# Phase 15 Plan 04: Flexible Paxos Summary

**Flexible Paxos quorum configuration with independent phase-1/phase-2 quorums enabling reduced commit latency**

## Performance

- **Duration:** 3 min
- **Started:** 2026-01-25T05:39:59Z
- **Completed:** 2026-01-25T05:42:44Z
- **Tasks:** 3
- **Files modified:** 1

## Accomplishments

- QuorumConfig struct with configurable phase-1 (election) and phase-2 (commit) quorum sizes
- Three presets: classic (balanced), fast_commit (reduced Q2 for speed), strong_leader (Q2=1)
- FlexiblePaxos wrapper providing hasPhase1Quorum/hasPhase2Quorum helpers
- Validation enforcing the Flexible Paxos invariant Q1 + Q2 > N
- 18 comprehensive unit tests covering all presets, validation, and edge cases
- Extensive documentation with academic reference and usage examples

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Flexible Paxos module** - `7929b24` (feat)
2. **Task 2: Add Flexible Paxos tests** - included in `7929b24` (Zig standard: tests in same file)
3. **Task 3: Document Flexible Paxos theory and usage** - included in `7929b24` (doc comments)

_Note: All three tasks were completed together as idiomatic Zig places tests and documentation in the same source file._

## Files Created/Modified

- `src/vsr/flexible_paxos.zig` - Flexible Paxos quorum configuration (562 lines)
  - QuorumConfig: configuration struct with cluster_size, phase1_quorum, phase2_quorum
  - QuorumPreset: static functions for classic/fast_commit/strong_leader presets
  - FlexiblePaxos: helper struct for quorum checking
  - validateQuorums: standalone validation function
  - 18 unit tests covering all cases
  - 72 doc comment lines with theory and usage

## Decisions Made

1. **Validation at explicit call, not construction**: QuorumConfig can be created with invalid values; validate() must be called explicitly. This allows inspection and custom configurations while ensuring safety at the point of use.

2. **fast_commit fallback for small clusters**: For N < 3, fast_commit returns classic quorums because reducing Q2 isn't meaningful with only 1-2 nodes.

3. **u16 cast for invariant check**: Used `@as(u16, ...)` when adding Q1 + Q2 to prevent overflow when both are near 255.

4. **Fault tolerance helpers**: Added phase1FaultTolerance() and phase2FaultTolerance() methods for operational visibility into how many nodes can fail.

5. **Comprehensive error types**: Separate error types for each validation failure (InvalidQuorumIntersection, InvalidQuorumZero, InvalidQuorumExceedsCluster, InvalidClusterSize) for precise error handling.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Flexible Paxos module ready for integration with replica.zig
- QuorumConfig can be used to configure consensus quorums
- Fast commit preset enables lower latency for write-heavy workloads
- Strong leader preset available for single-datacenter deployments

---
*Phase: 15-cluster-consensus*
*Completed: 2026-01-25*
