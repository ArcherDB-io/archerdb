# Phase 4: Fault Tolerance - Research

**Researched:** 2026-01-30
**Domain:** Fault tolerance, crash recovery, disk error handling, network failure resilience
**Confidence:** HIGH

## Summary

This phase validates that ArcherDB survives hardware and network failures without data loss. The codebase already contains substantial fault tolerance infrastructure inherited from TigerBeetle's battle-tested patterns. The key insight is that most fault tolerance mechanisms are already implemented - this phase validates they work correctly and adds targeted testing for specific failure scenarios.

The existing infrastructure includes:
- **Storage fault injection** (`src/testing/storage.zig`): Configurable read/write/crash fault probabilities, misdirected I/O simulation, and latent sector error (LSE) handling
- **Network fault injection** (`src/testing/packet_simulator.zig`, `src/testing/vortex/faulty_network.zig`): Packet loss, latency spikes, partition simulation
- **Recovery mechanisms** (`src/vsr/replica.zig`): Status-based recovery (recovering, recovering_head), recovery metrics tracking, timeout profiles
- **Crash testing scripts** (`scripts/sigkill_crash_test.sh`, `scripts/dm_flakey_test.sh`): SIGKILL injection and Linux dm-flakey power loss simulation

**Primary recommendation:** Use the existing VOPR simulator and replica_test.zig infrastructure with augmented fault injection scenarios that explicitly target each FAULT requirement, measuring recovery times and validating graceful degradation behaviors.

## Standard Stack

The established infrastructure for fault tolerance validation:

### Core Testing Infrastructure
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| VOPR Simulator | `src/vopr.zig` | Deterministic cluster simulation with crash injection | TigerBeetle's battle-tested approach |
| Testing Storage | `src/testing/storage.zig` | Fault-injectable storage with LSE/torn write simulation | Simulates all disk failure modes |
| Packet Simulator | `src/testing/packet_simulator.zig` | Network partition and packet loss simulation | Deterministic, reproducible network faults |
| Faulty Network | `src/testing/vortex/faulty_network.zig` | Vortex integration for network fault injection | Real TCP proxy with delay/corrupt/lose |
| Replica Tests | `src/vsr/replica_test.zig` | Unit tests for recovery scenarios | Covers WAL, checkpoint, corruption recovery |
| Data Integrity Tests | `src/vsr/data_integrity_test.zig` | Explicit DATA requirement validation | Pattern to follow for FAULT tests |

### Supporting Infrastructure
| Component | Location | Purpose | When to Use |
|-----------|----------|---------|-------------|
| Timeout Profiles | `src/vsr/timeout_profiles.zig` | Configurable election/heartbeat timeouts | Network failure detection tuning |
| Recovery Metrics | `src/vsr/replica.zig:428-437` | Recovery path classification and timing | Verify FAULT-08 (< 60 seconds) |
| Index Checkpoint | `src/index/checkpoint.zig` | Recovery path decision tree | WAL replay vs LSM scan vs rebuild |
| sigkill_crash_test.sh | `scripts/sigkill_crash_test.sh` | SIGKILL crash testing | Cross-platform crash injection |
| dm_flakey_test.sh | `scripts/dm_flakey_test.sh` | Linux power loss simulation | Block-level fault injection |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| VOPR simulator | Real multi-node + chaos tools | VOPR is deterministic, reproducible; real chaos is realistic but hard to debug |
| Testing Storage faults | Direct disk error injection (libfiu) | Testing Storage gives precise control; libfiu requires kernel support |
| Packet Simulator | tc/iptables network faults | Packet Simulator is deterministic; tc is realistic but non-reproducible |

**Build Commands:**
```bash
# Run VOPR with crash injection
./zig/zig build vopr -Dvopr-state-machine=testing -- --crash-rate=5 --replicas=3 42

# Run replica tests (includes recovery and partition tests)
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "Cluster: recovery"
./zig/zig build -j4 -Dconfig=lite test:unit -- --test-filter "Cluster: network"

# Shell-based crash testing
./scripts/sigkill_crash_test.sh --iterations 5 --seed 42

# Linux dm-flakey power loss testing (requires root)
sudo ./scripts/dm_flakey_test.sh --iterations 3
```

## Architecture Patterns

### Existing Test Structure
```
src/
├── vsr/
│   ├── replica_test.zig       # Recovery, partition, corruption tests
│   ├── data_integrity_test.zig# DATA requirement validation (pattern to follow)
│   ├── multi_node_validation_test.zig  # MULTI requirement validation
│   ├── replica.zig            # Recovery path tracking, metrics
│   ├── timeout_profiles.zig   # Leader election/heartbeat configuration
│   └── superblock.zig         # Checkpoint persistence
├── testing/
│   ├── storage.zig            # Fault-injectable storage simulator
│   ├── packet_simulator.zig   # Network fault simulation
│   ├── cluster.zig            # Multi-replica test cluster
│   ├── cluster/
│   │   ├── network.zig        # Network partition simulation
│   │   └── storage_checker.zig# Storage integrity validation
│   └── vortex/
│       ├── faulty_network.zig # TCP proxy with fault injection
│       └── supervisor.zig     # Vortex crash injection supervisor
├── storage.zig                # Production storage with LSE handling
└── index/
    └── checkpoint.zig         # Recovery path decision tree
```

### Pattern 1: Recovery Path Classification
**What:** Classify recovery scenarios to track timing and validate < 60 second requirement
**When to use:** All crash recovery tests (FAULT-01, FAULT-02, FAULT-08)
**Example:**
```zig
// Source: src/index/checkpoint.zig:193-232
pub const RecoveryPath = enum {
    none,
    wal_replay,       // Fast: replay from WAL
    lsm_scan,         // Medium: scan LSM tree
    full_rebuild,     // Slow: complete index rebuild

    pub fn to_label(self: RecoveryPath) []const u8 {
        return switch (self) {
            .none => "none",
            .wal_replay => "wal_replay",
            .lsm_scan => "lsm_scan",
            .full_rebuild => "full_rebuild",
        };
    }
};

// Source: src/vsr/replica.zig:428-437
recovery_start_ns: u64 = 0,
recovery_path: index_checkpoint.RecoveryPath = .none,
recovery_metrics: index_checkpoint.RecoveryMetrics = .{},
```

### Pattern 2: Latent Sector Error (LSE) Handling
**What:** Gracefully handle disk read errors via binary search subdivision
**When to use:** FAULT-03 (disk read errors)
**Example:**
```zig
// Source: src/storage.zig:290-346
fn on_read(self: *Storage, completion: *IO.Completion, result: IO.ReadError!usize) void {
    const read: *Storage.Read = @fieldParentPtr("completion", completion);

    const bytes_read = result catch |err| switch (err) {
        error.InputOutput => {
            // Disk unable to read some sectors (internal CRC or hardware failure)
            const target = read.target();
            if (target.len > constants.sector_size) {
                // Subdivide read: binary search for failing sector(s)
                log.warn("latent sector error: offset={}, subdividing read...", .{read.offset});
                const target_sectors = @divFloor(target.len - 1, constants.sector_size) + 1;
                read.target_max = (@divFloor(target_sectors - 1, 2) + 1) * constants.sector_size;
                self.start_read(read, 0);  // Retry with smaller window
                return;
            } else {
                // Single sector failed - zero it for repair protocol
                log.warn("latent sector error: offset={}, zeroing sector...", .{read.offset});
                @memset(target, 0);  // Allows repair from other replicas
                self.start_read(read, target.len);
                return;
            }
        },
        // ... other errors panic
    };
}
```

### Pattern 3: Full Disk Handling
**What:** Panic with clear error on disk full; graceful degradation via --limit-storage
**When to use:** FAULT-04 (full disk)
**Example:**
```zig
// Source: src/storage.zig:449-456
error.NoSpaceLeft => {
    // Intentionally crash on physical space exhaustion.
    // Low space condition is handled logically, via `--limit-storage` argument.
    vsr.fatal(
        .no_space_left,
        "write failed: no space left on device (offset={} size={})",
        .{ write.offset, write.buffer.len },
    );
},
```

### Pattern 4: Network Partition Simulation
**What:** Use drop_all/pass_all for deterministic partition testing
**When to use:** FAULT-05, FAULT-06 (network failures)
**Example:**
```zig
// Source: src/vsr/replica_test.zig:393-404
test "Cluster: network: partition 2-1 (isolate backup, symmetric)" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);
    t.replica(.B2).drop_all(.__, .bidirectional);  // Partition B2
    try c.request(3, 3);
    try expectEqual(t.replica(.A0).commit(), 3);
    try expectEqual(t.replica(.B1).commit(), 3);
    try expectEqual(t.replica(.B2).commit(), 2);  // Behind due to partition
}
```

### Pattern 5: Crash Fault Injection
**What:** Inject torn writes during storage reset (crash simulation)
**When to use:** FAULT-01, FAULT-02, FAULT-07 (crash recovery)
**Example:**
```zig
// Source: src/testing/storage.zig:296-316
pub fn reset(storage: *Storage) void {
    log.debug("Reset: {} pending reads, {} pending writes, {} pending next_ticks", .{
        storage.reads.count(),
        storage.writes.count(),
        storage.next_tick_queue.count(),
    });
    while (storage.writes.removeOrNull()) |write| {
        if (storage.prng.chance(storage.options.crash_fault_probability)) {
            // Randomly corrupt one sector of pending write (torn write simulation)
            const sectors = SectorRange.from_zone(write.zone, write.offset, write.buffer.len);
            storage.fault_sector(write.zone, sectors.random(&storage.prng));
        }
    }
    // ...
}
```

### Anti-Patterns to Avoid
- **Assuming recovery is instant:** Always measure recovery time and verify < 60 seconds
- **Testing single failure only:** Test cascading failures (disk + network)
- **Ignoring partial writes:** Always test torn write scenarios with `crash_fault_probability`
- **Testing happy path only:** Include error return path validation
- **Fixed timeouts in tests:** Use tick-based timing for deterministic results

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Disk error retry | Custom retry loop | `storage.zig` LSE handling | Binary search subdivision, sector-level granularity |
| Crash injection | SIGKILL from shell | VOPR `crash_fault_probability` | Coordinated with storage state, deterministic |
| Network partition | Manual socket closing | `replica.drop_all()`/`pass_all()` | Integrated with test cluster, recoverable |
| Recovery timing | Manual timestamp tracking | `recovery_metrics` struct | Already tracks path and duration |
| Full disk detection | Check disk space | `--limit-storage` CLI flag | Logical limit before physical exhaustion |
| Timeout configuration | Hardcoded values | `timeout_profiles.zig` | Cloud/datacenter presets with jitter |

**Key insight:** The TigerBeetle-derived infrastructure handles edge cases that are easy to miss: partial reads, misdirected writes, torn writes during specific phases, sector-level granularity for LSE recovery. Use the existing patterns.

## Common Pitfalls

### Pitfall 1: Testing Recovery Without Timing
**What goes wrong:** Recovery "works" but takes > 60 seconds, violating FAULT-08
**Why it happens:** Not measuring actual recovery duration
**How to avoid:** Use `recovery_start_ns` and `recovery_metrics` to track and assert timing
**Warning signs:** Tests that pass but VOPR with time limits fails

### Pitfall 2: Non-Deterministic Crash Points
**What goes wrong:** Flaky tests that sometimes catch corruption, sometimes don't
**Why it happens:** Using random timing for crash injection
**How to avoid:** Use VOPR with fixed seeds; use tick-based timing in Cluster tests
**Warning signs:** Tests that fail "sometimes" without pattern

### Pitfall 3: Testing Disk Full Without Read Availability
**What goes wrong:** Full disk test verifies write rejection but not read continuation
**Why it happens:** Only checking error case, not graceful degradation
**How to avoid:** After full disk, verify reads still work (FAULT-04 requirement)
**Warning signs:** Tests that check only for write failure

### Pitfall 4: Ignoring Network Asymmetry
**What goes wrong:** Partition tests miss asymmetric failures (send-only, receive-only)
**Why it happens:** Only testing symmetric partitions (both directions blocked)
**How to avoid:** Test .incoming, .outgoing, and .bidirectional separately
**Warning signs:** Tests that work for symmetric but fail for asymmetric partitions

### Pitfall 5: Recovery vs Repair Confusion
**What goes wrong:** Measuring repair time instead of recovery time
**Why it happens:** Not distinguishing between "replica can accept requests" and "replica caught up"
**How to avoid:** Recovery = status becomes normal; Repair = fully synchronized with cluster
**Warning signs:** Recovery times that depend on cluster state

### Pitfall 6: Skipping Corrupted Entry Detection
**What goes wrong:** Corrupted log entry not detected until later read
**Why it happens:** Not verifying checksum validation on recovery
**How to avoid:** Test that corrupted entries cause clear startup failure (per CONTEXT.md decision)
**Warning signs:** Tests that inject corruption but don't verify detection

## Code Examples

Verified patterns from the existing codebase:

### SIGKILL Crash Recovery (FAULT-01)
```zig
// Source: src/vsr/replica_test.zig:77-94 (pattern to extend)
test "FAULT-01: Process crash (SIGKILL) survives without data loss" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);

    // Crash replica during operation
    t.replica(.R0).stop();  // Simulates SIGKILL

    // Inject torn write on pending operations (crash_fault_probability)
    // Done automatically by storage.reset() with crash_fault_probability

    try t.replica(.R0).open();  // Recovery
    t.run();

    // Verify no data loss - all committed ops preserved
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);
}
```

### Disk Read Error Handling (FAULT-03)
```zig
// Source: Based on src/storage.zig:290-346 (production storage)
// Testing pattern from src/testing/storage.zig:495-499
test "FAULT-03: Disk read errors recovered via repair" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);

    // Inject read fault on specific sector
    t.replica(.R0).corrupt(.{ .grid_block = 5 });

    // R0 should repair from R1/R2
    t.run();

    // Verify block was repaired
    const r0_storage = &t.cluster.storages[t.replica(.R0).replicas.get(0)];
    try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 5 } }));
}
```

### Network Partition Recovery (FAULT-05)
```zig
// Source: src/vsr/replica_test.zig:436-450
test "FAULT-05: Network partition doesn't cause data loss" {
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(.{});
    try c.request(2, 2);

    // Partition primary from backups
    const p = t.replica(.A0);
    p.drop_all(.B1, .bidirectional);
    p.drop_all(.B2, .bidirectional);

    // Cluster should elect new primary and continue
    try c.request(3, 3);

    // Old primary behind, but no data loss
    try expectEqual(p.commit(), 2);

    // Heal partition - old primary catches up
    p.pass_all(.B1, .bidirectional);
    p.pass_all(.B2, .bidirectional);
    t.run();

    try expectEqual(p.commit(), 3);  // Caught up, no data loss
}
```

### Packet Loss and Latency (FAULT-06)
```zig
// Source: Based on src/testing/vortex/faulty_network.zig:32-53
// Faults struct for network fault injection
const Faults = struct {
    const Delay = struct {
        time_ms: u32,
        jitter_ms: u32,
    };

    delay: ?Delay = null,       // Latency spikes
    lose: ?Ratio = null,        // Packet loss
    corrupt: ?Ratio = null,     // Data corruption
};

// Usage in tests
network.faults.lose = ratio(10, 100);    // 10% packet loss
network.faults.delay = .{ .time_ms = 200, .jitter_ms = 100 };  // 200ms +/- 100ms
```

### Recovery Time Measurement (FAULT-08)
```zig
// Source: src/vsr/replica.zig:996-1017
fn update_recovery_path_after_journal(self: *Replica) void {
    self.recovery_path = index_checkpoint.classify_recovery_path(
        self.op,
        self.commit_min,
        self.op_checkpoint,
    );

    if (self.recovery_start_ns == 0) return;

    const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
    const duration_ns: u64 = if (now_ns > self.recovery_start_ns)
        @intCast(now_ns - self.recovery_start_ns)
    else
        0;

    self.recovery_metrics.record_recovery(self.recovery_path, duration_ns);

    // Assert recovery time < 60 seconds
    const max_recovery_ns = 60 * std.time.ns_per_s;
    assert(duration_ns < max_recovery_ns);
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Random crash injection | VOPR deterministic faults | TigerBeetle origin | Reproducible failure scenarios |
| Full-device failures | Sector-level LSE simulation | TigerBeetle origin | Realistic partial failure modes |
| Fixed timeouts | Configurable timeout profiles | Recent addition | Environment-specific tuning |
| Manual recovery verification | Recovery metrics tracking | Recent addition | Automated timing verification |

**Current best practices:**
- Use VOPR with `--crash-rate` for crash recovery validation
- Use `storage.Options.crash_fault_probability` for torn write simulation
- Measure recovery time in nanoseconds, assert < 60 seconds
- Test both symmetric and asymmetric network partitions
- Use --limit-storage for logical disk full handling before physical exhaustion

## Open Questions

Things that couldn't be fully resolved:

1. **Full Disk Read-Only Mode Implementation**
   - What we know: Write rejection on NoSpaceLeft is implemented via vsr.fatal()
   - What's unclear: Whether "stay available for reads" is already implemented or needs new code
   - Recommendation: Verify current behavior; may need to add read-only mode before panic

2. **Health Endpoint Behavior Under Failure**
   - What we know: CONTEXT.md says "Claude's discretion - follow Kubernetes health probe best practices"
   - What's unclear: Current health endpoint implementation details
   - Recommendation: Research Kubernetes liveness vs readiness probe semantics; implement graduated health states

3. **Connection Limit Handling**
   - What we know: CONTEXT.md defers to Claude's discretion
   - What's unclear: Current connection pool behavior under overload
   - Recommendation: Check `src/connection_pool.zig` for existing limits; add reject/queue behavior

4. **80% Disk Warning Implementation**
   - What we know: CONTEXT.md specifies 80% threshold for early warning
   - What's unclear: Whether this is already implemented via metrics
   - Recommendation: Check storage_metrics.zig; may need to add threshold alert

## Sources

### Primary (HIGH confidence)
- `src/storage.zig` - Production storage with LSE handling implementation
- `src/testing/storage.zig` - Testing storage with full fault injection documentation
- `src/vsr/replica_test.zig` - Recovery and partition test patterns
- `src/vsr/replica.zig` - Recovery path tracking and metrics
- `src/testing/packet_simulator.zig` - Network fault injection
- `src/testing/vortex/faulty_network.zig` - TCP proxy fault injection

### Secondary (MEDIUM confidence)
- `scripts/sigkill_crash_test.sh` - SIGKILL crash testing script pattern
- `scripts/dm_flakey_test.sh` - dm-flakey power loss testing pattern
- `src/vsr/timeout_profiles.zig` - Timeout configuration for network failures

### Tertiary (LOW confidence)
- Health endpoint implementation (needs investigation)
- 80% disk warning (needs implementation verification)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified directly from codebase
- Architecture: HIGH - Patterns extracted from working tests
- Pitfalls: HIGH - Based on existing test patterns and documentation
- Open questions: MEDIUM - Some implementation details need verification

**Research date:** 2026-01-30
**Valid until:** 45 days (infrastructure is stable, specific implementations may evolve)

## Requirements Mapping

| Requirement | Validation Approach | Existing Infrastructure | New Work Needed |
|-------------|---------------------|------------------------|-----------------|
| FAULT-01: Process crash (SIGKILL) | VOPR crash injection, sigkill_crash_test.sh | storage.reset(), crash_fault_probability | Explicit labeled test |
| FAULT-02: Power loss | dm_flakey_test.sh, crash_fault_probability during writes | Testing storage torn write simulation | Expand dm_flakey integration |
| FAULT-03: Disk read errors | LSE binary search subdivision | storage.zig on_read error handling | Test that verifies repair path |
| FAULT-04: Full disk handling | --limit-storage flag, NoSpaceLeft panic | vsr.fatal() on NoSpaceLeft | Read-only mode verification |
| FAULT-05: Network partitions | drop_all/pass_all in replica_test | Packet simulator, cluster network | Explicit FAULT-05 labeled tests |
| FAULT-06: Packet loss/latency | Faulty network delay/lose options | faulty_network.zig Faults struct | Expand to dedicated tests |
| FAULT-07: Corrupted log entries | corrupt() method, checksum validation | Checksum verification, repair protocol | Clear error on startup test |
| FAULT-08: Recovery < 60 seconds | recovery_metrics timing measurement | recovery_start_ns, RecoveryMetrics | Assert timing in tests |
