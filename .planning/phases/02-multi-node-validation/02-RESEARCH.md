# Phase 02: Multi-Node Validation - Research

**Researched:** 2026-01-29
**Domain:** Distributed consensus testing using TigerBeetle-derived Cluster framework
**Confidence:** HIGH

## Summary

This phase validates ArcherDB's 3-node cluster consensus, replication, and failover behavior. The codebase already contains a sophisticated deterministic testing framework derived from TigerBeetle, located in `src/testing/`. This framework provides simulated networking, storage fault injection, and state checking capabilities that enable comprehensive validation without flaky real-network tests.

The existing `replica_test.zig` contains 50+ tests covering recovery, network partitions, view changes, state sync, and more. These serve as both validation patterns and proof that the framework is mature. The research found that all required validation scenarios (MULTI-01 through MULTI-07) can be implemented using existing infrastructure - no new frameworks or libraries needed.

**Primary recommendation:** Leverage the existing Cluster testing framework (`src/testing/cluster.zig`) with deterministic seeds, using the established TestContext/TestReplicas patterns from `replica_test.zig` as templates.

## Standard Stack

The established test infrastructure for this domain is entirely internal to the codebase.

### Core

| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| Cluster | `src/testing/cluster.zig` | Simulated cluster with replicas, clients, network | Deterministic, battle-tested, TigerBeetle-proven |
| PacketSimulator | `src/testing/packet_simulator.zig` | Network simulation with partitions, delays, loss | Built-in fault injection, configurable parameters |
| StateChecker | `src/testing/cluster/state_checker.zig` | Verifies consensus invariants continuously | Automatic correctness validation per tick |
| Storage | `src/testing/storage.zig` | Simulated storage with fault injection | Corruption, crash simulation |

### Supporting

| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| TestContext | `src/vsr/replica_test.zig` | Test harness wrapping Cluster | All validation tests |
| TestReplicas | `src/vsr/replica_test.zig` | Helper for replica operations | Partition, crash, corrupt operations |
| TestClients | `src/vsr/replica_test.zig` | Helper for client operations | Request/reply verification |
| marks | `src/testing/marks.zig` | Code path verification | Validating specific behaviors triggered |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Simulated cluster | Real processes | Non-deterministic, flaky, slower, harder to debug |
| Packet simulator | Real network | Can't control timing, partitions harder to create |
| Storage simulator | Real disk | Can't inject corruption, slower |

**No external dependencies required.** All test infrastructure exists.

## Architecture Patterns

### Recommended Test Structure

```
src/testing/validation/    # New directory for phase 02 tests
├── multi_node_test.zig    # Main validation test file
└── (or add to replica_test.zig for consistency)
```

Alternatively, tests can be added directly to `src/vsr/replica_test.zig` following existing patterns.

### Pattern 1: TestContext-Based Test

**What:** Use TestContext to initialize a cluster with specific configuration
**When to use:** All multi-node validation tests
**Example:**
```zig
// Source: src/vsr/replica_test.zig
test "Cluster: network: partition 2-1 (isolate backup, symmetric)" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);
    t.replica(.B2).drop_all(.__, .bidirectional);
    try c.request(3, 3);
    try expectEqual(t.replica(.A0).commit(), 3);
    try expectEqual(t.replica(.B1).commit(), 3);
    try expectEqual(t.replica(.B2).commit(), 2);
}
```

### Pattern 2: Replica Selection (ProcessSelector)

**What:** Select replicas by role (primary/backup) or index
**When to use:** When targeting specific replicas regardless of view changes
**Example:**
```zig
// Source: src/vsr/replica_test.zig
// A0 = current primary
// B1 = backup immediately after primary
// B2 = second backup
// R_ = all replicas
// __ = all replicas, standbys, clients

var a0 = t.replica(.A0);  // Primary
var b1 = t.replica(.B1);  // First backup
var b2 = t.replica(.B2);  // Second backup

// Role-based addressing survives view changes
try expectEqual(a0.role(), .primary);
try expectEqual(b1.role(), .backup);
```

### Pattern 3: Network Partition Injection

**What:** Use drop_all/pass_all to create partitions
**When to use:** Testing partition scenarios
**Example:**
```zig
// Source: src/vsr/replica_test.zig
// Symmetric partition (isolate one node completely)
t.replica(.B2).drop_all(.__, .bidirectional);

// Asymmetric partition (can send but not receive)
t.replica(.A0).drop_all(.B1, .incoming);

// Isolate primary from backups
p.drop_all(.B1, .bidirectional);
p.drop_all(.B2, .bidirectional);

// Drop specific message types
t.replica(.R_).drop(.R_, .bidirectional, .do_view_change);
```

### Pattern 4: Replica Crash/Recovery

**What:** Use stop() and open() to simulate crashes
**When to use:** Testing failover and recovery
**Example:**
```zig
// Source: src/vsr/replica_test.zig
var b = t.replica(.B1);
b.stop();                          // Crash the replica
b.corrupt(.{ .wal_prepare = 3 });  // Optional: corrupt before recovery
try b.open();                      // Recover
try expectEqual(b.status(), .recovering_head);  // May be recovering
t.run();                           // Let cluster converge
try expectEqual(b.status(), .normal);  // Should stabilize
```

### Pattern 5: State Verification

**What:** Use commit(), op_head(), status() to verify state
**When to use:** Asserting cluster convergence
**Example:**
```zig
// Source: src/vsr/replica_test.zig
// Verify all replicas converged
try expectEqual(t.replica(.R_).status(), .normal);
try expectEqual(t.replica(.R_).commit(), expected_commit);

// Verify individual replica states
try expectEqual(t.replica(.A0).commit(), 3);
try expectEqual(t.replica(.B1).commit(), 3);
try expectEqual(t.replica(.B2).commit(), 2);  // Partitioned, lagging

// Verify roles after view change
try expectEqual(b1.role(), .primary);
try expectEqual(b2.role(), .backup);
```

### Pattern 6: Timing and Convergence

**What:** Use t.run() for convergence, explicit tick counts for timing
**When to use:** Testing timing requirements (e.g., 5s election)
**Example:**
```zig
// Source: src/vsr/replica_test.zig
// Let cluster converge (up to ~4100 ticks)
t.run();

// For timing measurements, count ticks manually
var ticks: u64 = 0;
while (t.replica(.A0).status() == .view_change) : (ticks += 1) {
    _ = t.tick();
}
// tick_ms = 10ms by default, so ticks * 10ms = wall time
const election_ms = ticks * constants.tick_ms;
try expect(election_ms <= 5000);  // 5 second requirement
```

### Anti-Patterns to Avoid

- **Hard-coded tick counts for convergence:** Use t.run() which has built-in convergence detection
- **Testing real networks:** Deterministic simulation is more reliable
- **Single seeds:** Use multiple deterministic seeds for coverage
- **Ignoring intermediate states:** Verify state during failure, not just final state

## Don't Hand-Roll

Problems that have existing solutions in the codebase:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Network partition simulation | Custom socket manipulation | PacketSimulator | Already handles delay, loss, partitions, asymmetry |
| Consensus invariant checking | Manual commit verification | StateChecker | Automatic, continuous, proven correct |
| Storage corruption | File manipulation | Storage.corrupt() | Controlled, deterministic, type-safe |
| Replica lifecycle | Process management | Cluster.replica_crash/restart | Clean state management |
| Time simulation | Real clocks | TimeSim / tick-based | Deterministic, controllable |

**Key insight:** The testing framework has been battle-tested through TigerBeetle's VOPR (Viewstamped Operation Replayer) - a property-based fuzzer that has found and fixed countless edge cases. The infrastructure is mature.

## Common Pitfalls

### Pitfall 1: Non-Deterministic Tests

**What goes wrong:** Tests pass sometimes, fail other times
**Why it happens:** Using random seeds without documenting them
**How to avoid:** Always use fixed seeds; when running multiple seeds, document them
**Warning signs:** Test failures that can't be reproduced

### Pitfall 2: Insufficient Tick Count

**What goes wrong:** Test times out before cluster converges
**Why it happens:** t.run() has a default max tick count (4100 ticks)
**How to avoid:** Use t.run() which auto-detects convergence; only increase if needed
**Warning signs:** Tests failing with status still in view_change

### Pitfall 3: Forgetting to Clear In-Flight Packets

**What goes wrong:** Crashed replica receives old messages after restart
**Why it happens:** Messages in network queue survive crash
**How to avoid:** TestReplicas.stop() already clears incoming packets
**Warning signs:** Unexpected state after replica restart

### Pitfall 4: Tick vs Time Confusion

**What goes wrong:** Timing assertions fail despite correct behavior
**Why it happens:** Confusing ticks (simulation steps) with wall-clock time
**How to avoid:** Use formula: `wall_time_ms = ticks * constants.tick_ms` (default tick_ms = 10)
**Warning signs:** Timing tests off by 10x

### Pitfall 5: Testing Only Final State

**What goes wrong:** Missing bugs that only manifest during transitions
**Why it happens:** Only asserting after t.run() completes
**How to avoid:** Verify intermediate states: before failure, during partition, after recovery
**Warning signs:** Passing tests despite incorrect intermediate behavior

### Pitfall 6: Ignoring Standby Count

**What goes wrong:** Cluster initialization fails or behaves unexpectedly
**Why it happens:** Some tests need standbys for certain scenarios
**How to avoid:** Explicitly set .standby_count = 0 or desired value in TestContext.init
**Warning signs:** Unexpected replica count in logs

## Code Examples

Verified patterns from the codebase:

### MULTI-01: 3-Node Consensus and Replication

```zig
// Source: src/vsr/replica_test.zig (adapted)
test "MULTI-01: 3-node cluster achieves consensus and replicates" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});

    // Write data
    try c.request(10, 10);  // request(expected_commit, expected_replies)

    // Verify all 3 nodes have same commit
    try expectEqual(t.replica(.R0).commit(), 10);
    try expectEqual(t.replica(.R1).commit(), 10);
    try expectEqual(t.replica(.R2).commit(), 10);

    // All should be in normal status
    try expectEqual(t.replica(.R_).status(), .normal);
}
```

### MULTI-02: Leader Election Within 5 Seconds

```zig
// Source: Pattern from replica_test.zig timing tests
test "MULTI-02: leader election within 5 seconds" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);  // Establish baseline

    const primary_before = t.replica(.A0);
    try expectEqual(primary_before.role(), .primary);

    // Kill the primary
    t.replica(.A0).stop();

    // Count ticks until new primary elected
    var ticks: u64 = 0;
    const tick_limit = 5000 / constants.tick_ms;  // 5000ms / 10ms = 500 ticks

    while (ticks < tick_limit) : (ticks += 1) {
        _ = t.tick();
        // Check if new primary established
        for ([_]ProcessSelector{.R1, .R2}) |sel| {
            const r = t.replica(sel);
            if (r.health() == .up and r.status() == .normal and r.role() == .primary) {
                // New primary elected
                const election_ms = ticks * constants.tick_ms;
                try expect(election_ms <= 5000);
                return;  // Pass
            }
        }
    }
    return error.ElectionTimeout;
}
```

### MULTI-03: Replica Rejoin After Crash

```zig
// Source: src/vsr/replica_test.zig (adapted from recovery tests)
test "MULTI-03: replica rejoins and catches up" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(5, 5);

    var b2 = t.replica(.B2);
    b2.stop();  // Crash one replica

    // Cluster continues without it
    try c.request(10, 10);
    try expectEqual(t.replica(.A0).commit(), 10);
    try expectEqual(t.replica(.B1).commit(), 10);

    // Replica rejoins
    try b2.open();
    t.run();  // Let it catch up

    // Verify it caught up
    try expectEqual(b2.status(), .normal);
    try expectEqual(b2.commit(), 10);
}
```

### MULTI-05: Network Partition (No Split-Brain)

```zig
// Source: src/vsr/replica_test.zig partition tests
test "MULTI-05: network partition prevents split-brain" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);

    // Create 2-1 partition (isolate one backup)
    t.replica(.B2).drop_all(.__, .bidirectional);

    // Majority can still commit
    try c.request(5, 5);
    try expectEqual(t.replica(.A0).commit(), 5);
    try expectEqual(t.replica(.B1).commit(), 5);
    try expectEqual(t.replica(.B2).commit(), 2);  // Isolated, stale

    // Heal partition
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // Verify convergence (no data divergence)
    try expectEqual(t.replica(.R_).commit(), 5);
    try expectEqual(t.replica(.R_).status(), .normal);
}
```

### MULTI-06: Tolerate f Failures (f=1 for N=3)

```zig
// Source: src/vsr/replica_test.zig
test "MULTI-06: cluster tolerates f=1 failure in 3-node" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);

    // Kill one replica
    t.replica(.B2).stop();

    // Cluster should still be able to commit (2/3 quorum)
    try c.request(10, 10);
    try expectEqual(t.replica(.A0).commit(), 10);
    try expectEqual(t.replica(.B1).commit(), 10);
}
```

## Tick-to-Time Conversion

**Formula:** `wall_time_ms = ticks * constants.tick_ms`

| tick_ms (default) | Example |
|-------------------|---------|
| 10 | 500 ticks = 5000ms = 5 seconds |

**Configuration:** `tick_ms` is set in `src/config.zig` (default 10ms).

For the 5-second leader election requirement (MULTI-02):
- 5000ms / 10ms = 500 ticks maximum

**In test code:**
```zig
const tick_limit = 5000 / constants.tick_ms;  // = 500 ticks
```

## Deterministic Seed Strategy

For comprehensive coverage with deterministic testing:

| Scenario | Seeds | Rationale |
|----------|-------|-----------|
| Basic consensus | 3-5 | Different timing variations |
| Partition handling | 5-10 | Various partition timings |
| Recovery | 5-10 | Different corruption patterns |
| Election timing | 10+ | Statistical confidence |

**Implementation:**
```zig
test "MULTI-XX with multiple seeds" {
    for ([_]u64{ 123, 456, 789, 1011, 1213 }) |seed| {
        const t = try TestContext.init(.{ .replica_count = 3, .seed = seed });
        defer t.deinit();
        // ... test body ...
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Real network testing | Deterministic simulation | TigerBeetle origin | 100% reproducibility |
| Manual invariant checks | StateChecker | Original design | Automatic correctness |
| Random fault injection | Seeded PRNG | Original design | Reproducible failures |

**Deprecated/outdated:** None - the framework is current and actively used.

## Open Questions

1. **Test organization**
   - What we know: Tests can go in `replica_test.zig` or new file
   - What's unclear: Whether to add to existing file or create new module
   - Recommendation: Add to `replica_test.zig` for consistency with existing patterns

2. **Number of seeds for CI**
   - What we know: More seeds = more coverage
   - What's unclear: CI time budget
   - Recommendation: Start with 5 seeds per scenario; adjust based on CI time

3. **Marks for specific scenarios**
   - What we know: marks module provides code path verification
   - What's unclear: Whether all MULTI scenarios have existing marks
   - Recommendation: Use marks where available; add new ones if needed

## Sources

### Primary (HIGH confidence)
- `src/testing/cluster.zig` - Full Cluster implementation examined
- `src/testing/packet_simulator.zig` - Network simulation examined
- `src/testing/cluster/state_checker.zig` - Consensus checking examined
- `src/vsr/replica_test.zig` - 50+ existing tests examined (lines 1-2600+)
- `src/constants.zig` - tick_ms and configuration examined
- `src/config.zig` - Configuration defaults examined

### Secondary (MEDIUM confidence)
- `src/vopr.zig` - VOPR fuzzer structure examined
- TigerBeetle heritage (framework lineage known)

### Tertiary (LOW confidence)
- None - all findings from codebase inspection

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components exist in codebase, actively used
- Architecture: HIGH - Patterns extracted from working tests
- Pitfalls: HIGH - Derived from real code patterns and comments
- Timing: HIGH - tick_ms constant verified in multiple locations

**Research date:** 2026-01-29
**Valid until:** Indefinite (internal codebase, stable patterns)
