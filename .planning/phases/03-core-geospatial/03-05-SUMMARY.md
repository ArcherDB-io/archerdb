---
phase: 03-core-geospatial
plan: 05
subsystem: ram-index
tags: [ram-index, o1-lookup, race-condition, ttl, checkpoint, mmap]

dependency-graph:
  requires: ["03-04"]
  provides: ["RAM index verification", "race condition fix validation"]
  affects: ["04-replication"]

tech-stack:
  added: []
  patterns: ["O(1) hash table", "remove_if_id_matches race prevention"]

key-files:
  created: []
  modified:
    - src/ram_index.zig

decisions:
  - id: ram-stress-testing
    choice: "Stress testing for race condition verification (1000 iterations)"
    rationale: "Per CONTEXT.md discretion, chosen over formal analysis"
    alternatives: ["formal analysis", "model checking"]
  - id: ram-memory-formula
    choice: "Memory = capacity * 64 / 0.70 bytes"
    rationale: "64-byte cache-aligned entries at 70% load factor"
    implications: "91.5GB for 1B entities"

metrics:
  duration: 8 min
  completed: 2026-01-22
---

# Phase 3 Plan 5: RAM Index Verification Summary

RAM index provides O(1) lookup with race-safe TTL expiration and checkpoint recovery.

## Completed Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | O(1) lookup and performance verification | 12f9f1b | src/ram_index.zig |
| 2 | Race condition prevention tests | 5309b86 | src/ram_index.zig |
| 3 | Checkpoint recovery and TTL integration | 81184a9 | src/ram_index.zig |

## What Was Built

### Task 1: O(1) Lookup Performance
- Added test "RAM index: O(1) lookup verification" with timing sanity check
- Added test "RAM index: probe length bounded under load" (70% load factor)
- Added test "RAM index: capacity enforcement returns error"
- Added test "RAM index: memory usage bounded (64 bytes per entry)"

### Task 2: Race Condition Prevention
- Added test "RAM index: remove_if_id_matches semantics (all cases)"
  - Case 1: latest_id matches -> removed
  - Case 2: latest_id mismatch -> race_detected
  - Case 3: entry doesn't exist -> not removed
  - Case 4: tombstone -> not removed
- Added test "RAM index: TTL race condition stress test" (1000 iterations)
- Added test "RAM index: no data loss under concurrent access"
- Added test "RAM index: concurrent upsert during TTL scan preserves data"

### Task 3: Checkpoint and TTL Integration
- Added test "RAM index: checkpoint/restart recovery (mmap mode)"
- Added test "RAM index: mmap mode persistence verification"
- Added test "RAM index: TTL integration full lifecycle"
- Added test "RAM index: scan_expired_batch uses remove_if_id_matches"
- Added documentation section "## Checkpoint and Recovery" to module header

## Requirements Traceability

| Requirement | Test | Status |
|-------------|------|--------|
| RAM-01: O(1) lookup | O(1) lookup verification | PASS |
| RAM-02: Concurrent access | no data loss under concurrent access | PASS |
| RAM-03: Race condition fix | remove_if_id_matches semantics, stress test | PASS |
| RAM-04: Bounded memory | memory usage bounded, capacity enforcement | PASS |
| RAM-05: Checkpoint/restart | checkpoint/restart recovery | PASS |
| RAM-06: Mmap mode | mmap mode persistence verification | PASS |
| RAM-07: Hash collisions | probe length bounded (validates hash function) | PASS |
| RAM-08: TTL integration | TTL integration full lifecycle | PASS |

## Line 1859 Fix Verification

The `remove_if_id_matches` function at line 1866-1920 prevents race conditions:
- TTL scanner captures entry's latest_id before attempting removal
- If concurrent upsert changes latest_id, removal is blocked
- Race detection flag signals the concurrent modification
- Fresh data is never accidentally deleted

Stress test validates this with 1000 iterations:
- 500 races correctly detected (concurrent upsert happened)
- 500 successful removals (no concurrent upsert)

## Deviations from Plan

None - plan executed exactly as written.

## Test Coverage Summary

New tests added: 12
- 4 O(1)/performance tests
- 4 race condition tests
- 4 checkpoint/TTL integration tests

All existing tests continue to pass:
- RamIndex tests: PASS
- IndexEntry tests: PASS
- TTL tests: PASS
- F5.1.5 memory tests: PASS

## Next Phase Readiness

RAM index verification complete. All requirements validated. Ready for:
- Phase 4: Replication (uses RAM index for entity lookup)
- The S3 upload stub in replication.zig:828 remains for Phase 4
