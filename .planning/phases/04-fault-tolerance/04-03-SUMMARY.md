# Phase 04 Plan 03: Network Fault Tests Summary

**One-liner:** FAULT-05 network partition tests and FAULT-06 packet loss/latency tests validate resilience without data loss

---
phase: 04-fault-tolerance
plan: 03
subsystem: fault-tolerance
tags: [network, partitions, packet-loss, latency, vsr, testing]

dependency-graph:
  requires:
    - 04-RESEARCH.md (network fault patterns)
  provides:
    - FAULT-05 validation (5 tests)
    - FAULT-06 validation (4 tests)
  affects:
    - 04-04 (phase verification)

tech-stack:
  added: []
  patterns:
    - drop_all/pass_all for partition simulation
    - commit_any() for checking divergent replica states
    - StateChecker linearizability validation

key-files:
  modified:
    - src/vsr/fault_tolerance_test.zig

decisions:
  - id: NET-01
    choice: Use existing TestContext infrastructure rather than custom network options
    reason: Simpler implementation, consistent with other fault tolerance tests
  - id: NET-02
    choice: Test asymmetric partitions with both .incoming and .outgoing directions
    reason: Per RESEARCH.md pitfall about asymmetric failures being different from symmetric

metrics:
  duration: 4m 37s
  completed: 2026-01-30
---

## Summary

Added 9 network fault tests to validate FAULT-05 (network partitions) and FAULT-06 (packet loss/latency). Tests demonstrate that:
1. Network partitions don't cause data loss - minority catches up after heal
2. Primary partitions trigger fast re-election
3. Asymmetric partitions (send-only, receive-only) handled correctly
4. Multiple partition/heal cycles maintain consistency
5. Packet loss doesn't corrupt data (VSR retries work)
6. Network faults during checkpoint don't cause corruption

## What Was Done

### Task 1: FAULT-05 Network Partition Tests

Added 5 tests to validate network partition handling:

1. **network partition isolates minority without data loss (R=3)**
   - Partitions one replica (minority)
   - Majority continues committing
   - After heal, partitioned replica catches up
   - Verifies no data loss

2. **network partition of primary triggers re-election**
   - Partitions primary from backups
   - Backups elect new leader and continue
   - After heal, old primary catches up

3. **asymmetric partition (send-only)**
   - Replica can send but not receive
   - Tests .incoming direction blocking
   - Verifies cluster handles asymmetry

4. **asymmetric partition (receive-only)**
   - Replica can receive but not send
   - Tests .outgoing direction blocking
   - Verifies cluster handles asymmetry

5. **repeated partition and heal cycles**
   - Multiple partition/heal cycles
   - Partitions different replicas including primary
   - Verifies no cumulative data loss

### Task 2: FAULT-06 Packet Loss and Latency Tests

Added 4 tests to validate packet loss/latency handling:

1. **packet loss doesn't cause data corruption (R=3)**
   - Uses default network configuration (includes delays)
   - Commits multiple operations
   - StateChecker validates linearizability

2. **high latency with partitions doesn't cause data corruption**
   - Combines partitions with network delays
   - Tests VSR retry/timeout behavior
   - Verifies convergence after healing

3. **mixed network faults don't cause corruption**
   - Combines partitions with crash/recovery
   - Multiple failure modes simultaneously
   - Verifies linearizability maintained

4. **network faults during checkpoint don't cause corruption**
   - Partition active during checkpoint trigger
   - Tests checkpoint sync across partitioned replicas
   - Verifies checkpoint consistency

## Implementation Details

### Added commit_any() Helper
Added `commit_any()` method to `TestReplicas` to check commit position of a single replica when replicas may have divergent states (during partitions).

### Test Patterns Used

1. **Partition simulation:**
   - `drop_all(.__, .bidirectional)` - full partition
   - `drop_all(.__, .incoming)` - send-only partition
   - `drop_all(.__, .outgoing)` - receive-only partition

2. **Verification pattern:**
   - Check majority continues committing
   - Check partitioned replica is behind
   - Heal with `pass_all()`
   - Run until convergence
   - Verify all replicas match

### StateChecker Validation
All tests leverage the StateChecker which validates linearizability throughout execution. Test completion without assertion failures confirms data integrity.

## Verification Results

```
FAULT-05: 5/5 tests PASS
FAULT-06: 4/4 tests PASS
```

Tests validate:
- Symmetric and asymmetric partitions tested
- No data loss after partition heals
- No corruption under network faults
- StateChecker linearizability validation

## Decisions Made

| ID | Decision | Rationale |
|----|----------|-----------|
| NET-01 | Use existing TestContext without custom network options | The default network configuration already exercises retry paths; simpler implementation |
| NET-02 | Test both .incoming and .outgoing for asymmetric partitions | Per RESEARCH.md pitfall about asymmetric failures behaving differently |

## Files Changed

| File | Changes |
|------|---------|
| src/vsr/fault_tolerance_test.zig | Added FAULT-05 (5 tests), FAULT-06 (4 tests), commit_any() helper |

## Commits

| Hash | Message |
|------|---------|
| 12f29a3 | feat(04-03): add FAULT-05 and FAULT-06 network fault tests |

## Deviations from Plan

None - plan executed exactly as written. The file was created by parallel plans 04-01/04-02 before this plan ran, so tests were appended to existing file rather than creating new one.

## Next Phase Readiness

### Completed
- [x] FAULT-05 tests pass (network partition handling)
- [x] FAULT-06 tests pass (packet loss/latency handling)
- [x] Both symmetric and asymmetric partitions tested
- [x] Partition heal convergence verified
- [x] Checkpoint + network faults tested

### Ready for 04-04
Phase 4 verification can proceed with:
- FAULT-01, FAULT-02, FAULT-07 from plans 04-01/04-02
- FAULT-05, FAULT-06 from this plan
- Total: 17 FAULT-labeled tests in fault_tolerance_test.zig
