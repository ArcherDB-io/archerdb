# Phase 2: VSR & Storage - Research

**Researched:** 2026-01-22
**Domain:** Distributed consensus (VSR), LSM storage, encryption at rest
**Confidence:** HIGH

## Summary

This phase verifies the correctness of ArcherDB's core storage and consensus layers. The codebase already implements VSR (Viewstamped Replication), LSM tree storage, and encryption at rest. The work involves:

1. **VSR Protocol Fixes**: Remove deprecated message types, enable disabled snapshot verification, and verify consensus correctness through exhaustive VOPR fuzzing
2. **Durability Verification**: Prove WAL replay and checkpoint recovery work correctly under failure scenarios including power loss simulation with dm-flakey
3. **LSM Optimization**: Tune compaction parameters to meet 1M+ writes/sec and 100k+ reads/sec targets
4. **Encryption Verification**: Validate both AES-256-GCM and Aegis-256 against NIST test vectors and document key rotation procedures

**Primary recommendation:** Extend the existing VOPR fuzzer with deterministic replay capabilities and run 8-hour verification sessions. Address the disabled snapshot verification in `src/vsr/message_header.zig:1623` before considering VSR verified.

## Standard Stack

The codebase uses existing infrastructure. No new libraries required.

### Core Components (Already Implemented)

| Component | Location | Purpose | Status |
|-----------|----------|---------|--------|
| VSR Protocol | `src/vsr/replica.zig` | Viewstamped Replication consensus | Production, needs verification |
| Journal/WAL | `src/vsr/journal.zig` | Write-ahead log for durability | Production, needs verification |
| Superblock | `src/vsr/superblock.zig` | Checkpoint state persistence | Production, needs verification |
| LSM Tree | `src/lsm/tree.zig` | Sorted key-value storage | Production, needs tuning |
| Compaction | `src/lsm/compaction.zig` | Level-based compaction | Production, needs optimization |
| Encryption | `src/encryption.zig` | AES-256-GCM and Aegis-256 | Production, needs NIST verification |
| VOPR Fuzzer | `src/vopr.zig` | Deterministic simulation testing | Production, needs extensions |

### Testing Infrastructure

| Component | Location | Purpose |
|-----------|----------|---------|
| Cluster Simulation | `src/testing/cluster.zig` | Multi-replica test harness |
| Storage Simulation | `src/testing/storage.zig` | In-memory storage with fault injection |
| Packet Simulator | `src/testing/packet_simulator.zig` | Network partition simulation |
| State Checker | `src/testing/cluster/state_checker.zig` | Correctness validation |

### External Tools (dm-flakey)

| Tool | Source | Purpose |
|------|--------|---------|
| dm-flakey | Linux kernel device-mapper | Disk failure injection for power-loss testing |

**Installation (Linux only):**
```bash
# Load device-mapper module
sudo modprobe dm-flakey

# Create flakey device (example)
sudo dmsetup create flakey-test --table "0 204800 flakey /dev/loop0 0 10 5"
# Format: 0 <sectors> flakey <underlying> <offset> <up_interval> <down_interval>
```

## Architecture Patterns

### Existing VSR Architecture

```
src/
├── vsr/
│   ├── replica.zig          # Core consensus state machine (12,447 lines)
│   ├── journal.zig          # WAL implementation
│   ├── superblock.zig       # Checkpoint persistence
│   ├── message_header.zig   # Protocol messages (contains deprecated types)
│   ├── sync.zig             # State synchronization
│   ├── grid.zig             # Block-level storage
│   └── checkpoint_trailer.zig
├── lsm/
│   ├── tree.zig             # LSM tree implementation
│   ├── compaction.zig       # Level compaction logic
│   ├── manifest.zig         # Table metadata
│   └── manifest_log.zig     # Manifest persistence
├── testing/
│   ├── cluster.zig          # Test cluster harness
│   ├── storage.zig          # Simulated storage with faults
│   └── packet_simulator.zig # Network simulation
├── constants.zig            # Tunable parameters
├── config.zig               # Configuration presets
├── encryption.zig           # Encryption implementations
└── vopr.zig                 # VOPR fuzzer entry point
```

### Pattern 1: VOPR Deterministic Simulation

**What:** Randomized testing with deterministic replay from seed

**When to use:** All consensus and durability verification

**Current Implementation (from `src/vopr.zig`):**
```zig
// Seeds from Git commit hash for reproducible CI failures
pub fn parse_seed(bytes: []const u8) u64 {
    if (bytes.len == 40) {
        // Git hash special case
        const commit_hash = std.fmt.parseUnsigned(u160, bytes, 16) catch ...;
        return @truncate(commit_hash);
    }
    return std.fmt.parseUnsigned(u64, bytes, 10) catch ...;
}
```

**Extension needed:** Add deterministic replay for debugging failures.

### Pattern 2: Fault Injection via Storage Simulation

**What:** Simulated storage with configurable fault probabilities

**Source:** `src/testing/storage.zig:53-91`
```zig
pub const Options = struct {
    read_latency_min: Duration = .{ .ns = 0 },
    read_latency_mean: Duration = .{ .ns = 0 },
    write_latency_min: Duration = .{ .ns = 0 },
    write_latency_mean: Duration = .{ .ns = 0 },
    read_fault_probability: Ratio = Ratio.zero(),
    write_fault_probability: Ratio = Ratio.zero(),
    write_misdirect_probability: Ratio = Ratio.zero(),
    crash_fault_probability: Ratio = Ratio.zero(),
    fault_atlas: ?*const ClusterFaultAtlas = null,
    // ...
};
```

**Use for:** WAL corruption injection, misdirected writes, crash simulation.

### Pattern 3: Deprecated Message Type Handling

**What:** Four deprecated VSR message types that need removal

**Source:** `src/vsr.zig:288-295`
```zig
pub const Command = enum(u8) {
    // ... active commands ...

    // Deprecated message types - slots reserved forever
    deprecated_12 = 12, // start_view was moved to 24
    deprecated_21 = 21,
    deprecated_22 = 22,
    deprecated_23 = 23,
};
```

**Removal approach:**
1. Keep enum values reserved (never reuse)
2. Remove handler code from `src/vsr/replica.zig`
3. Update `src/vsr/message_header.zig` to always reject
4. Add comments explaining why slots are reserved

### Anti-Patterns to Avoid

- **Removing enum value slots:** Would break wire compatibility - keep reserved
- **Testing only happy path:** Must test crash-during-checkpoint, corruption, partitions
- **Assuming single-node works like cluster:** Many VSR paths only exercised with 3+ nodes
- **Running VOPR in Debug mode:** Too slow - use ReleaseSafe for CI

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Power-loss simulation | Custom crash injection | dm-flakey device-mapper | Kernel-level guarantees, industry standard |
| Encryption primitives | Custom AEAD | Zig std `crypto.aead.aes_gcm` and `crypto.aead.aegis` | Audited implementations |
| Network partitions | Custom network layer | `packet_simulator.zig` | Already implements symmetric, asymmetric, partial modes |
| State machine verification | Manual invariant checks | `StateChecker` in cluster tests | Comprehensive correctness validation |
| Coverage tracking | Manual test enumeration | VOPR swarm testing | Automatically varies test scenarios |

**Key insight:** The existing testing infrastructure is sophisticated. Extend it rather than building parallel systems.

## Common Pitfalls

### Pitfall 1: Snapshot Verification Disabled

**What goes wrong:** Snapshot verification is disabled in manifest block checks
**Why it happens:** Comment at `src/vsr/message_header.zig:1623` says "TODO When manifest blocks include a snapshot, verify that snapshot != 0"
**How to avoid:** Investigate why snapshot numbers don't match op numbers, fix the root cause, enable verification
**Warning signs:** Tests pass but snapshot corruption goes undetected

### Pitfall 2: Journal Prepare Checksums Assertion

**What goes wrong:** An assertion is commented out in `src/vsr/journal.zig:303`
**Why it happens:** Assertion was causing failures during recovery
**How to avoid:** Investigate root cause, don't just comment out assertions
**Warning signs:** Silent data corruption during journal recovery

### Pitfall 3: Single-Node vs Multi-Node Testing

**What goes wrong:** View change and replica recovery paths not tested
**Why it happens:** Single-node clusters never trigger view changes
**How to avoid:** Test with both 3-node and 5-node configurations as specified in CONTEXT.md
**Warning signs:** Tests pass on single node but fail in production clusters

### Pitfall 4: VOPR Performance vs Correctness Mode

**What goes wrong:** Insufficient test iterations in Debug mode
**Why it happens:** Debug builds 10-100x slower than ReleaseSafe
**How to avoid:** Run VOPR in `--performance` mode (ReleaseSafe) for 8-hour sessions
**Warning signs:** CI passing but rare race conditions escaping to production

### Pitfall 5: Darwin Fsync Fallback

**What goes wrong:** Durability guarantees may not hold on macOS
**Why it happens:** Fallback to `posix.fsync` when `F_FULLFSYNC` unavailable (see `src/io/darwin.zig:1071`)
**How to avoid:** Per CONTEXT.md - validate F_FULLFSYNC once at startup, fail immediately if unavailable
**Warning signs:** Data loss after crash on macOS

### Pitfall 6: Compaction Impact on p99 Latency

**What goes wrong:** Latency spikes during compaction
**Why it happens:** Compaction competing for disk I/O with foreground queries
**How to avoid:** Per CONTEXT.md - dedicate resources to compaction, cannot be background/low-priority
**Warning signs:** Periodic latency spikes correlating with compaction cycles

## Code Examples

### VSR Deprecated Message Handling (Current)

**Source:** `src/vsr/message_header.zig:340-374`
```zig
pub const Deprecated = extern struct {
    // ... header fields ...

    fn invalid_header(_: *const @This()) ?[]const u8 {
        return "deprecated message type";
    }
};
```

**Removal pattern:** Keep the struct but ensure all code paths that could generate these messages are removed.

### VOPR Cluster Configuration

**Source:** `src/vopr.zig` (inferred from options)
```zig
// For 8-hour verification runs
const options = .{
    .replica_count = 5,           // Test 5-node configuration
    .ticks_max_requests = 40_000_000,
    .ticks_max_convergence = 10_000_000,
    .packet_loss_ratio = ratio(1, 100), // 1% packet loss
    // Partition modes: symmetric, asymmetric, random
};
```

### LSM Constants for Tuning

**Source:** `src/constants.zig:580-700`
```zig
// Key tuning parameters for LSM optimization
pub const lsm_levels = config.cluster.lsm_levels;              // Number of levels
pub const lsm_growth_factor = config.cluster.lsm_growth_factor; // Level size ratio
pub const lsm_compaction_ops = config.cluster.lsm_compaction_ops; // Ops before flush
pub const lsm_manifest_compact_extra_blocks = config.cluster.lsm_manifest_compact_extra_blocks;
pub const lsm_table_coalescing_threshold_percent = config.cluster.lsm_table_coalescing_threshold_percent;
```

### Encryption Algorithm Selection

**Source:** `src/encryption.zig:34-41`
```zig
/// Encryption version 1: AES-256-GCM (legacy, still readable)
pub const ENCRYPTION_VERSION_GCM: u16 = 1;

/// Encryption version 2: Aegis-256 (current, faster with AES-NI)
pub const ENCRYPTION_VERSION_AEGIS: u16 = 2;

/// Current encryption format version (new files use this)
pub const ENCRYPTION_VERSION: u16 = ENCRYPTION_VERSION_AEGIS;
```

### AES-NI Hardware Detection

**Source:** `src/encryption.zig:67-82`
```zig
pub fn hasAesNi() bool {
    const arch = builtin.cpu.arch;
    const features = builtin.cpu.features;

    return switch (arch) {
        .x86_64 => std.Target.x86.featureSetHas(features, .aes),
        .aarch64 => std.Target.aarch64.featureSetHas(features, .aes),
        else => false,
    };
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| AES-256-GCM only | Aegis-256 default, GCM fallback | Version 2 | 2-3x faster encryption with AES-NI |
| Manual crash testing | dm-flakey disk failure injection | Phase 2 | Kernel-level power-loss simulation |
| Single-seed VOPR | Git-commit-hash seeding | Current | Reproducible CI failures |

**Deprecated/outdated:**
- Message types 12, 21, 22, 23: Deprecated for backwards compatibility, removal planned this phase
- `--aof` flag: Deprecated, suggest `--aof-file` instead

## Open Questions

1. **Snapshot Verification Root Cause**
   - What we know: Verification disabled at `message_header.zig:1623`
   - What's unclear: Why snapshot numbers don't align with op numbers
   - Recommendation: Deep investigation before enabling, document findings

2. **Journal Checksum Assertion**
   - What we know: Assertion commented out at `journal.zig:303`
   - What's unclear: Root cause of failures
   - Recommendation: Investigate with VOPR, don't ship with assertion disabled

3. **dm-flakey macOS Alternative**
   - What we know: dm-flakey is Linux-only
   - What's unclear: How to test power-loss on macOS
   - Recommendation: SIGKILL-based testing for macOS, dm-flakey for Linux CI

4. **Linearizability vs Sequential Consistency**
   - What we know: VSR provides linearizable consistency
   - What's unclear: Best verification approach (Jepsen-style vs custom)
   - Recommendation: Claude's discretion per CONTEXT.md, suggest extending StateChecker

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `src/vsr/`, `src/lsm/`, `src/encryption.zig`
- CONCERNS.md: `.planning/codebase/CONCERNS.md`
- CONTEXT.md: `.planning/phases/02-vsr-storage/02-CONTEXT.md`
- Constants: `src/constants.zig`

### Secondary (MEDIUM confidence)
- dm-flakey documentation: Linux kernel device-mapper documentation
- VOPR patterns: Inferred from `src/vopr.zig` and `scripts/run_vopr.sh`

### Tertiary (LOW confidence)
- None - all findings verified from codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - verified from codebase
- Architecture patterns: HIGH - directly from source files
- Pitfalls: HIGH - documented in CONCERNS.md
- LSM tuning: MEDIUM - targets from CONTEXT.md, implementation needs benchmarking

**Research date:** 2026-01-22
**Valid until:** 60 days (stable codebase, no external dependencies at risk)

---

## Appendix: Key File Locations

| Concern | Files | Notes |
|---------|-------|-------|
| Deprecated messages | `src/vsr.zig:288-295`, `src/vsr/message_header.zig:102-105,340-374`, `src/vsr/replica.zig` | Remove from replica, keep enum reserved |
| Snapshot verification | `src/vsr/message_header.zig:1623` | TODO needs investigation |
| Journal assertion | `src/vsr/journal.zig:303` | Commented out, needs root cause |
| LSM tuning | `src/constants.zig:580-700`, `src/config.zig:188-210` | ConfigCluster parameters |
| Encryption | `src/encryption.zig` | Both GCM and Aegis-256 |
| VOPR | `src/vopr.zig`, `scripts/run_vopr.sh` | Extend for deterministic replay |
| Storage fault injection | `src/testing/storage.zig` | Options struct for fault rates |
| Cluster testing | `src/testing/cluster.zig` | 3-node and 5-node configs |
