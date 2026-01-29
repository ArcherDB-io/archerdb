# Phase 3: Data Integrity - Research

**Researched:** 2026-01-29
**Domain:** Data durability, crash recovery, corruption detection, WAL/checkpoint verification
**Confidence:** HIGH

## Summary

This phase validates that ArcherDB's data survives crashes, restores correctly, and maintains consistency under adverse conditions. The codebase follows TigerBeetle's battle-tested patterns for durability verification: the VOPR (Viewstamped Operation Protocol Replication) simulator with configurable fault injection, deterministic testing with fixed seeds, and comprehensive checksum-based corruption detection.

The existing infrastructure in `src/testing/` provides nearly all the building blocks needed for DATA-01 through DATA-09 validation. The key insight is that ArcherDB already implements TigerBeetle's durability patterns - this phase validates that implementation works correctly rather than building new durability mechanisms. The VOPR simulator (src/vopr.zig) already tests crash recovery, torn writes, corruption detection, and concurrent operations with configurable fault probabilities.

**Primary recommendation:** Use the existing VOPR simulator and replica_test.zig infrastructure to validate DATA requirements, creating targeted test scenarios that exercise each requirement explicitly and document the verification.

## Standard Stack

The established testing infrastructure for data integrity validation:

### Core Testing Infrastructure
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| VOPR Simulator | `src/vopr.zig` | Deterministic cluster simulation with fault injection | TigerBeetle's battle-tested approach |
| Testing Storage | `src/testing/storage.zig` | In-memory storage with configurable faults | Simulates all failure modes |
| Testing Cluster | `src/testing/cluster.zig` | Multi-replica cluster for consensus testing | Full VSR protocol testing |
| Replica Tests | `src/vsr/replica_test.zig` | Unit tests for recovery scenarios | Covers WAL, checkpoint, corruption |
| Fuzz Tests | `src/fuzz_tests.zig` | Randomized testing across subsystems | Finds edge cases |

### Supporting Infrastructure
| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| State Checker | `src/testing/cluster/state_checker.zig` | Validates replica state consistency | Verify convergence after recovery |
| Storage Checker | `src/testing/cluster/storage_checker.zig` | Validates storage integrity | Post-crash verification |
| Grid Checker | `src/testing/cluster/grid_checker.zig` | Validates grid block coherence | Checkpoint verification |
| Journal Checker | `src/testing/cluster/journal_checker.zig` | Validates WAL consistency | WAL replay verification |
| sigkill_crash_test.sh | `scripts/sigkill_crash_test.sh` | Process kill crash testing | Cross-platform crash injection |
| dm_flakey_test.sh | `scripts/dm_flakey_test.sh` | Disk failure simulation | Linux power-loss simulation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| VOPR simulator | Real multi-node deployment | VOPR is deterministic, reproducible; real deployment is slower, harder to debug |
| Testing Storage | Direct disk I/O | Testing Storage allows precise fault injection; direct I/O is realistic but non-deterministic |
| Zig unit tests | Shell script tests | Zig tests have full access to internals; shell scripts better for end-to-end but slower |

**Build Commands:**
```bash
# Run VOPR with crash injection
./zig/zig build vopr -Dvopr-state-machine=testing -- --crash-rate=5 --replicas=3 42

# Run replica tests (includes corruption recovery tests)
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "Cluster: recovery"

# Run fuzz tests
./zig/zig build -j4 -Dconfig=lite fuzz -- -- smoke

# Shell-based crash testing
./scripts/sigkill_crash_test.sh --iterations 5 --seed 42
```

## Architecture Patterns

### Existing Test Structure
```
src/
├── vsr/
│   ├── replica_test.zig       # WAL corruption, checkpoint, recovery tests
│   ├── superblock.zig         # Checkpoint state management
│   ├── superblock_fuzz.zig    # Superblock corruption fuzz tests
│   ├── journal.zig            # WAL implementation
│   └── checksum.zig           # Aegis-based checksum (u128)
├── testing/
│   ├── storage.zig            # Fault-injectable storage simulator
│   ├── cluster.zig            # Multi-replica test cluster
│   ├── cluster/
│   │   ├── state_checker.zig  # Replica state validation
│   │   ├── storage_checker.zig# Storage integrity validation
│   │   └── grid_checker.zig   # Grid block validation
│   ├── backup_restore_test.zig# Backup/restore integration tests
│   └── failover_test.zig      # Failover scenario tests
├── vopr.zig                   # VOPR simulator entry point
├── fuzz_tests.zig             # Fuzz test runner
└── archerdb/
    ├── backup_restore_test.zig# Backup queue/config tests
    └── restore.zig            # Point-in-time restore
```

### Pattern 1: Deterministic Fault Injection
**What:** Use fixed seeds with configurable fault probabilities for reproducible testing
**When to use:** All data integrity validation
**Example:**
```zig
// Source: src/testing/storage.zig:89-118
pub const Options = struct {
    seed: u64 = 0,
    /// Simulates LSE (latent sector errors) and bit rot
    read_fault_probability: Ratio = Ratio.zero(),
    /// Simulates incomplete or corrupt writes
    write_fault_probability: Ratio = Ratio.zero(),
    /// Simulates firmware bugs causing misdirected I/O
    write_misdirect_probability: Ratio = Ratio.zero(),
    /// Simulates torn writes from power loss during I/O
    crash_fault_probability: Ratio = Ratio.zero(),
    // ...
};
```

### Pattern 2: Crash-then-Verify Protocol
**What:** Inject crash during operation, then verify recovery with same seed
**When to use:** WAL replay (DATA-01), checkpoint/restore (DATA-02), torn write handling (DATA-06)
**Example:**
```zig
// Source: src/vsr/replica_test.zig:77-94
test "Cluster: recovery: WAL prepare corruption (R=3, corrupt right of head)" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    t.replica(.R_).stop();
    t.replica(.R0).corrupt(.{ .wal_prepare = 2 });  // Inject corruption

    try t.replica(.R0).open();  // Recovery attempt
    try expectEqual(t.replica(.R0).status(), .recovering_head);
    // ... cluster repairs from other replicas
}
```

### Pattern 3: Byte-for-Byte State Verification
**What:** Compare exact state after recovery using checksums
**When to use:** All state restoration verification
**Example:**
```zig
// Source: src/vsr/checksum.zig:65-74
pub fn checksum(source: []const u8) u128 {
    var stream = ChecksumStream.init();
    stream.add(source);
    return stream.checksum();
}

// Used in superblock validation
pub fn valid_checksum(superblock: *const SuperBlockHeader) bool {
    return superblock.checksum == superblock.calculate_checksum() and
        superblock.checksum_padding == 0;
}
```

### Pattern 4: ClusterFaultAtlas for Distributed Faults
**What:** Coordinate fault injection across replicas to ensure at least one valid copy
**When to use:** Multi-replica corruption testing (ensures recoverability)
**Example:**
```zig
// Source: src/testing/storage.zig:17-27
//! - wal_headers, wal_prepares:
//!   - Read/write faults are distributed between replicas according to ClusterFaultAtlas,
//!     to ensure that at least one replica will have a valid copy to help others repair.
//!   - When a replica crashes, it may fault the WAL outside of ClusterFaultAtlas.
//!   - When replica_count=1, its WAL can only be corrupted by a crash, never a read/write.
```

### Anti-Patterns to Avoid
- **Testing only happy path:** Always include corruption injection in tests
- **Non-deterministic crash timing:** Use fixed seeds for reproducibility
- **Ignoring torn writes:** Always test partial write scenarios
- **Single-replica corruption testing:** Must test cluster recovery with f+1 valid copies
- **Skipping internal state verification:** Check LSM tree structure, not just observable behavior

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Checksum computation | Custom CRC/hash | `vsr.checksum()` (Aegis128) | Hardware-accelerated, cryptographically strong |
| Crash injection | Custom signal handling | VOPR's `crash_fault_probability` | Coordinated with storage state, deterministic |
| Torn write simulation | Manual partial writes | `testing/storage.zig` reset() | Handles all pending writes correctly |
| State comparison | Manual field comparison | `stdx.equal_bytes()` | Handles alignment, padding correctly |
| Multi-replica coordination | Custom sync code | `testing/cluster.zig` | Full VSR protocol, state checker integration |
| Corruption injection | Random bit flips | `corrupt()` method on TestReplicas | Zone-aware, checksum-preserving when needed |

**Key insight:** TigerBeetle spent years building this infrastructure. The testing patterns in src/testing/ and src/vsr/replica_test.zig encode hard-won knowledge about what actually breaks in distributed storage systems.

## Common Pitfalls

### Pitfall 1: Testing Corruption Without Recovery Path
**What goes wrong:** Corrupting data that cannot be recovered (all copies corrupted)
**Why it happens:** Not using ClusterFaultAtlas to coordinate faults
**How to avoid:** Use `fault_atlas` option in Storage.Options; set `faulty_grid = replica_count > 2`
**Warning signs:** Tests that always fail or require specific corruption locations

### Pitfall 2: Non-Deterministic Crash Timing
**What goes wrong:** Flaky tests that pass/fail randomly
**Why it happens:** Using real time or randomness for crash injection
**How to avoid:** Use VOPR's tick-based timing; provide explicit seeds
**Warning signs:** Tests that fail "sometimes" without clear pattern

### Pitfall 3: Incomplete Torn Write Handling
**What goes wrong:** Missing corner cases where partial writes leave inconsistent state
**Why it happens:** Only testing complete writes or complete failures
**How to avoid:** Use `crash_fault_probability` during writes; verify redundant headers
**Warning signs:** Corruption detected only on restart, not immediately

### Pitfall 4: Verifying Observable State Only
**What goes wrong:** Internal corruption that doesn't manifest until later
**Why it happens:** Only checking query results, not internal structures
**How to avoid:** Use Grid Checker, Journal Checker, Manifest Checker
**Warning signs:** Tests pass but VOPR fails on longer runs

### Pitfall 5: Ignoring Quorum Requirements
**What goes wrong:** Tests assume single-replica recovery when f+1 needed
**Why it happens:** Not accounting for VSR quorum rules
**How to avoid:** For R=3, need 2 valid copies for recovery; R=1 cannot recover from corruption
**Warning signs:** Tests that work for R=3 but fail for R=1 unexpectedly

### Pitfall 6: Mixing Read-Your-Writes with Eventual Consistency
**What goes wrong:** Tests checking for data before commit is acknowledged
**Why it happens:** Not waiting for commit before verification
**How to avoid:** Use client callback to know when operation is committed
**Warning signs:** Intermittent "data not found" errors in tests

## Code Examples

Verified patterns from the existing codebase:

### WAL Corruption and Recovery (DATA-01)
```zig
// Source: src/vsr/replica_test.zig:115-131
test "Cluster: recovery: WAL prepare corruption (R=3, corrupt root)" {
    // A replica can recover from a corrupt root prepare.
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_prepare = 0 });  // Corrupt root
    try t.replica(.R0).open();

    try c.request(1, 1);
    try expectEqual(t.replica(.R_).commit(), 1);

    // Verify corruption was repaired
    const r0 = t.replica(.R0);
    const r0_storage = &t.cluster.storages[r0.replicas.get(0)];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 0 } }));
}
```

### Checkpoint Recovery (DATA-02)
```zig
// Source: src/vsr/replica_test.zig:208-251
test "Cluster: recovery: grid corruption (disjoint)" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // Checkpoint to ensure grid is used for recovery
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    t.replica(.R_).stop();

    // Corrupt the whole grid - each block intact on exactly one replica
    for ([_]TestReplicas{t.replica(.R0), t.replica(.R1), t.replica(.R2)}, 0..) |replica, i| {
        var address: u64 = 1 + i;
        while (address <= address_max) : (address += 3) {
            replica.corrupt(.{ .grid_block = address + 1 });
            replica.corrupt(.{ .grid_block = address + 2 });
        }
    }

    try t.replica(.R_).open();
    t.run();

    // Verify full recovery
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
}
```

### Checksum Verification (DATA-03)
```zig
// Source: src/vsr/checksum.zig:129-158
test "checksum simple fuzzing" {
    var prng = stdx.PRNG.from_seed(42);
    var msg_buf = try testing.allocator.alloc(u8, msg_max);
    defer testing.allocator.free(msg_buf);

    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        const msg_len = prng.range_inclusive(usize, msg_min, msg_max);
        const msg = msg_buf[0..msg_len];
        prng.fill(msg);

        const msg_checksum = checksum(msg);

        // Verify pure function
        try testing.expectEqual(msg_checksum, checksum(msg));

        // Change message, checksum must change
        msg[prng.index(msg)] +%= 1;
        try testing.expect(checksum(msg) != msg_checksum);
    }
}
```

### Torn Write Detection (DATA-06)
```zig
// Source: src/vsr/replica_test.zig:186-206
test "Cluster: recovery: WAL torn prepare, standby with intact prepare (R=1 S=1)" {
    // R=1 recovers to find that its last prepare was a torn write, so it is truncated.
    const t = try TestContext.init(.{
        .replica_count = 1,
        .standby_count = 1,
    });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_header = 2 });  // Simulate torn write
    try t.replica(.R0).open();
    try c.request(3, 3);
    try expectEqual(t.replica(.R0).commit(), 3);
    try expectEqual(t.replica(.S0).commit(), 3);
}
```

### Concurrent Write Safety (DATA-05)
```zig
// Source: src/vopr.zig:310-337 (VOPR main loop)
// VOPR inherently tests concurrent writes through:
// - Multiple clients sending requests simultaneously
// - request_probability controlling load
// - Pipeline allowing multiple in-flight operations

// Example configuration for stress testing:
const workload_options = StateMachine.Workload.Options.generate(prng, .{
    .batch_size_limit = batch_size_limit,
    .multi_batch_per_request_limit = multi_batch_per_request_limit,
    .client_count = client_count,
    .in_flight_max = ReplySequence.stalled_queue_capacity * multi_batch_per_request_limit,
});
```

### Backup and Point-in-Time Recovery (DATA-07, DATA-08, DATA-09)
```zig
// Source: src/archerdb/backup_restore_test.zig:266-298
test "Integration: PointInTime parsing and formatting" {
    // Parse sequence
    const pit = PointInTime.parse("seq:12345");
    try testing.expect(pit != null);
    try testing.expectEqual(@as(u64, 12345), pit.?.sequence);

    // Parse timestamp
    const pit_ts = PointInTime.parse("ts:1704067200");
    try testing.expectEqual(@as(i64, 1704067200), pit_ts.?.timestamp);

    // Parse latest
    const pit_latest = PointInTime.parse("latest");
    try testing.expectEqual(PointInTime.latest, pit_latest.?);
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CRC32 checksums | Aegis128 MAC (u128) | TigerBeetle origin | Cryptographic strength, hardware acceleration |
| Random crash injection | Deterministic VOPR | TigerBeetle origin | Reproducible failures, easier debugging |
| Single-node testing | Multi-replica with fault atlas | TigerBeetle origin | Realistic distributed failure modes |
| Manual recovery testing | Automated state checkers | Ongoing | Catches subtle inconsistencies |

**Current best practices (from TigerBeetle patterns):**
- Use VOPR with `--crash-rate` for durability verification
- Always test with R>=3 for realistic quorum behavior
- Verify internal state, not just observable behavior
- Use fixed seeds for all tests
- Run longer VOPR sessions for production readiness

## Open Questions

Things that couldn't be fully resolved:

1. **DATA-04 Read-Your-Writes Scope**
   - What we know: VSR guarantees linearizable commits; clients get acknowledgment after commit
   - What's unclear: Whether this should test client-level API or replica-level commits
   - Recommendation: Test at both levels - replica tests for VSR guarantees, integration tests for client API

2. **Point-in-Time Recovery Coverage**
   - What we know: `PointInTime` struct exists, parsing works; backup/restore infrastructure exists
   - What's unclear: Whether full PITR is implemented end-to-end
   - Recommendation: Verify restore.zig actually implements PITR, may need integration test

3. **Corruption Injection Granularity**
   - What we know: Can corrupt at sector, block, and slot level
   - What's unclear: Whether single-bit flip testing needs custom implementation
   - Recommendation: Current approach zeros/corrupts sectors; single-bit flips are detected by checksums anyway

## Sources

### Primary (HIGH confidence)
- `src/vsr/replica_test.zig` - WAL recovery, checkpoint, corruption handling tests
- `src/testing/storage.zig` - Fault injection implementation and documentation
- `src/vopr.zig` - VOPR simulator with all fault configuration options
- `src/vsr/checksum.zig` - Aegis128 checksum implementation
- `src/vsr/superblock.zig` - Checkpoint state management
- `src/archerdb/backup_restore_test.zig` - Backup/restore integration tests

### Secondary (MEDIUM confidence)
- `scripts/sigkill_crash_test.sh` - Process kill crash testing pattern
- `scripts/dm_flakey_test.sh` - Linux disk failure simulation pattern
- `src/testing/cluster.zig` - Multi-replica test infrastructure

### Tertiary (LOW confidence)
- Point-in-time recovery end-to-end implementation (needs verification)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified directly from codebase
- Architecture: HIGH - Patterns extracted from working tests
- Pitfalls: HIGH - Documented in code comments and test patterns
- Backup/restore: MEDIUM - Infrastructure exists but PITR end-to-end unclear

**Research date:** 2026-01-29
**Valid until:** 60 days (infrastructure is stable, patterns are established)

## Requirements Mapping

| Requirement | Validation Approach | Existing Tests | Confidence |
|-------------|---------------------|----------------|------------|
| DATA-01: WAL replay | replica_test.zig corruption tests | "Cluster: recovery: WAL prepare corruption" | HIGH |
| DATA-02: Checkpoint/restore | replica_test.zig grid corruption tests | "Cluster: recovery: grid corruption" | HIGH |
| DATA-03: Checksums detect corruption | checksum.zig tests + replica_test corruption | checksum tests, faulty sector detection | HIGH |
| DATA-04: Read-your-writes | VOPR state checker | StateChecker validates commits | HIGH |
| DATA-05: Concurrent writes | VOPR multi-client workload | VOPR swarm mode | HIGH |
| DATA-06: Torn writes | replica_test.zig torn prepare tests | "WAL torn prepare" test | HIGH |
| DATA-07: Backup creates snapshot | backup_restore_test.zig | "Full backup workflow simulation" | MEDIUM |
| DATA-08: Restore from backup | backup_restore_test.zig | "Full restore workflow simulation" | MEDIUM |
| DATA-09: Point-in-time recovery | PointInTime parsing tests | PointInTime tests exist | MEDIUM |
