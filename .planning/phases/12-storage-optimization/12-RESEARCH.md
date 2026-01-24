# Phase 12: Storage Optimization - Research

**Researched:** 2026-01-24
**Domain:** LSM-tree storage optimization, compression, compaction tuning, write amplification
**Confidence:** HIGH

## Summary

Phase 12 optimizes ArcherDB's LSM-tree storage for write-heavy geospatial workloads. The codebase already has a mature LSM implementation (`src/lsm/`) with leveled compaction, block-based storage (`64 KiB blocks`), and existing compaction infrastructure including TTL-aware prioritization. The existing Grafana storage dashboard (`observability/grafana/dashboards/archerdb-storage.json`) and Prometheus metrics infrastructure from Phase 11 provide the observability foundation.

The primary work involves:
1. Adding block-level LZ4 compression to value blocks (preserving index blocks uncompressed for fast key lookups)
2. Implementing tiered compaction strategy as default with latency-driven throttling
3. Adding write amplification monitoring and space amplification metrics
4. Building adaptive compaction that auto-tunes based on write throughput and space amplification
5. Implementing block-level deduplication for repeated geospatial values (common in trajectory data)
6. Creating operator controls with guardrails and emergency mode

**Primary recommendation:** Integrate compression at the block level using the `allyourcodebase/lz4` Zig binding for the C LZ4 library. Implement tiered compaction as a configuration option alongside existing leveled compaction, with latency-driven throttling based on P99 query latency.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| [allyourcodebase/lz4](https://github.com/allyourcodebase/lz4) | 1.10.0-6 | Block compression | Zig build system integration, LZ4 is fastest decompression, industry standard |
| Existing LSM implementation | N/A | Block storage, compaction | Already mature, battle-tested in ArcherDB |
| Existing metrics.zig | N/A | Prometheus metrics | Phase 11 infrastructure, histogram support |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| [LZig4](https://github.com/BarabasGitHub/LZig4) | Latest | Pure Zig LZ4 | If C dependency is problematic |
| Existing archerdb-storage.json dashboard | N/A | Storage visualization | Extend with new metrics |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| LZ4 | Zstd | Zstd better ratio but slower decompression; LZ4 prioritizes latency (user decision) |
| allyourcodebase/lz4 | LZig4 | Pure Zig avoids C deps but less tested, may have perf differences |
| Tiered compaction | Leveled (current) | Leveled has lower space amp, tiered has lower write amp |

**Installation:**
```bash
# Add LZ4 dependency
cd /home/g/archerdb
zig fetch --save git+https://github.com/allyourcodebase/lz4.git#1.10.0-6
```

## Architecture Patterns

### Recommended Project Structure

```
src/
├── lsm/
│   ├── compression.zig          # NEW: Block compression/decompression
│   ├── compaction.zig           # MODIFY: Add tiered strategy, throttling
│   ├── compaction_metrics.zig   # NEW: Write amp, space amp tracking
│   ├── compaction_adaptive.zig  # NEW: Workload-aware auto-tuning
│   ├── dedup.zig                # NEW: Block-level deduplication
│   ├── table.zig                # MODIFY: Compressed block support
│   └── schema.zig               # MODIFY: Compression flag in header
├── archerdb/
│   ├── storage_metrics.zig      # NEW: Storage-specific Prometheus metrics
│   ├── storage_alerts.zig       # NEW: Alert conditions and thresholds
│   └── emergency_mode.zig       # NEW: Emergency mode controller
└── config.zig                   # MODIFY: Add compression, compaction config

observability/grafana/dashboards/
├── archerdb-storage.json        # MODIFY: Add new panels
└── archerdb-storage-deep.json   # NEW: Developer/debug dashboard
```

### Pattern 1: Block-Level Compression with Header Flag

**What:** Compress value blocks using LZ4, store compression metadata in block header
**When to use:** All value blocks by default, configurable per-block-type
**Why:** Block-level compression works with existing LSM structure, no schema changes needed

```zig
// Source: Based on ArcherDB src/lsm/schema.zig header pattern
const CompressionType = enum(u4) {
    none = 0,
    lz4 = 1,
    // Reserved for future: zstd = 2
};

// Extend existing block header metadata
pub const BlockMetadata = extern struct {
    // Existing fields...
    compression: CompressionType = .none,
    uncompressed_size: u32 = 0,  // Original size before compression
    reserved: [76]u8 = @splat(0),

    comptime {
        assert(@sizeOf(BlockMetadata) == vsr.Header.Block.metadata_size);
    }
};

// Compression wrapper
pub fn compress_block(input: []const u8, output: []u8) !struct { size: usize, type: CompressionType } {
    const compressed_size = lz4.compress(input.ptr, output.ptr, @intCast(input.len), @intCast(output.len));

    // Only use compression if it saves space
    if (compressed_size > 0 and compressed_size < input.len * 9 / 10) {
        return .{ .size = @intCast(compressed_size), .type = .lz4 };
    }
    // Fall back to uncompressed
    @memcpy(output[0..input.len], input);
    return .{ .size = input.len, .type = .none };
}

pub fn decompress_block(input: []const u8, output: []u8, compression: CompressionType) !usize {
    switch (compression) {
        .none => {
            @memcpy(output[0..input.len], input);
            return input.len;
        },
        .lz4 => {
            const size = lz4.decompress(input.ptr, output.ptr, @intCast(input.len), @intCast(output.len));
            if (size < 0) return error.DecompressionFailed;
            return @intCast(size);
        },
    }
}
```

### Pattern 2: Tiered Compaction Strategy

**What:** Merge multiple sorted runs at same size tier before promoting to next level
**When to use:** Write-heavy workloads (default for geospatial)
**Why:** Reduces write amplification by 2-3x for update-heavy workloads

```zig
// Source: Based on RocksDB Universal Compaction and LSM research
pub const CompactionStrategy = enum {
    leveled,   // Current: aggressive merge, lower space amp
    tiered,    // New: delayed merge, lower write amp
};

pub const TieredCompactionConfig = struct {
    // Number of sorted runs to accumulate before merging
    size_ratio: f64 = 2.0,          // Merge when total size > size_ratio * largest_run
    min_merge_width: u32 = 2,        // Minimum runs to merge
    max_merge_width: u32 = 8,        // Maximum runs to merge at once
    max_size_amplification_percent: u32 = 200,  // Trigger compaction if space amp exceeds this
};

// Tiered compaction decision logic
pub fn should_compact_tiered(level: *const Level, config: TieredCompactionConfig) bool {
    const runs = level.sorted_run_count();
    if (runs < config.min_merge_width) return false;

    // Check space amplification
    const space_amp = level.total_size() / level.logical_size();
    if (space_amp * 100 > config.max_size_amplification_percent) return true;

    // Check size ratio trigger
    const largest_run_size = level.largest_run_size();
    const total_other_size = level.total_size() - largest_run_size;
    return total_other_size >= config.size_ratio * @as(f64, @floatFromInt(largest_run_size));
}
```

### Pattern 3: Latency-Driven Compaction Throttling

**What:** Slow down compaction when P99 query latency exceeds threshold
**When to use:** All compaction operations
**Why:** Prevents compaction I/O from impacting query performance

```zig
// Source: SILK and DLC research papers, RocksDB Write Stalls wiki
pub const ThrottleConfig = struct {
    p99_latency_threshold_ms: f64 = 50.0,     // Start throttling above this
    p99_latency_critical_ms: f64 = 100.0,     // Emergency throttle above this
    check_interval_ms: u64 = 1000,            // How often to check latency
    throttle_ratio_step: f64 = 0.1,           // How much to reduce/increase per check
    min_throughput_ratio: f64 = 0.1,          // Never go below 10% throughput
    recovery_hysteresis_ms: f64 = 10.0,       // Wait for latency to drop this much below threshold
};

pub const ThrottleState = struct {
    current_throughput_ratio: f64 = 1.0,  // 1.0 = full speed, 0.1 = 10%
    last_check_ns: i64 = 0,
    consecutive_good_checks: u32 = 0,

    pub fn update(self: *ThrottleState, current_p99_ms: f64, config: ThrottleConfig) void {
        if (current_p99_ms > config.p99_latency_critical_ms) {
            // Emergency: immediately drop to minimum
            self.current_throughput_ratio = config.min_throughput_ratio;
            self.consecutive_good_checks = 0;
        } else if (current_p99_ms > config.p99_latency_threshold_ms) {
            // Throttle down
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio - config.throttle_ratio_step
            );
            self.consecutive_good_checks = 0;
        } else if (current_p99_ms < config.p99_latency_threshold_ms - config.recovery_hysteresis_ms) {
            // Good latency, can recover
            self.consecutive_good_checks += 1;
            if (self.consecutive_good_checks >= 3) {
                self.current_throughput_ratio = @min(
                    1.0,
                    self.current_throughput_ratio + config.throttle_ratio_step
                );
            }
        }
    }
};
```

### Pattern 4: Write Amplification Monitoring

**What:** Track ratio of physical writes to logical writes
**When to use:** All write paths
**Why:** Key metric for LSM health, validates optimization effectiveness

```zig
// Source: CockroachDB Storage Layer docs, LSM-tree research
pub const WriteAmpMetrics = struct {
    // Rolling window counters
    logical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    physical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Per-level tracking for debugging
    level_writes: [constants.lsm_levels]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** constants.lsm_levels,

    pub fn record_write(self: *WriteAmpMetrics, level: u8, bytes: u64) void {
        _ = self.physical_bytes_written.fetchAdd(bytes, .monotonic);
        if (level < constants.lsm_levels) {
            _ = self.level_writes[level].fetchAdd(bytes, .monotonic);
        }
    }

    pub fn record_logical_write(self: *WriteAmpMetrics, bytes: u64) void {
        _ = self.logical_bytes_written.fetchAdd(bytes, .monotonic);
    }

    pub fn write_amplification(self: *const WriteAmpMetrics) f64 {
        const logical = @as(f64, @floatFromInt(self.logical_bytes_written.load(.monotonic)));
        const physical = @as(f64, @floatFromInt(self.physical_bytes_written.load(.monotonic)));
        if (logical == 0) return 1.0;
        return physical / logical;
    }

    pub fn space_amplification(logical_size: u64, physical_size: u64) f64 {
        if (logical_size == 0) return 1.0;
        return @as(f64, @floatFromInt(physical_size)) / @as(f64, @floatFromInt(logical_size));
    }
};
```

### Pattern 5: Adaptive Compaction Auto-Tuning

**What:** Automatically adjust compaction parameters based on workload
**When to use:** Default behavior, operators can override
**Why:** "Just works" for 90% of deployments without manual tuning

```zig
// Source: ArceKV, Endure, ELMo-Tune-V2 research
pub const AdaptiveConfig = struct {
    // Triggers for adaptation
    write_throughput_change_threshold: f64 = 0.20,  // 20% change triggers re-evaluation
    space_amp_threshold: f64 = 2.0,                  // 2x logical size triggers aggressive compaction

    // Sliding window for workload detection
    window_duration_ms: u64 = 60_000,  // 1 minute window
    sample_interval_ms: u64 = 1000,    // Sample every second

    // Bounds on auto-tuning (guardrails)
    min_compaction_threads: u32 = 1,
    max_compaction_threads: u32 = 4,
    min_l0_compaction_trigger: u32 = 2,
    max_l0_compaction_trigger: u32 = 20,
};

pub const WorkloadType = enum {
    write_heavy,    // >70% writes
    read_heavy,     // >70% reads
    balanced,       // 30-70% writes
    scan_heavy,     // >30% range scans
};

pub const AdaptiveState = struct {
    detected_workload: WorkloadType = .balanced,
    current_strategy: CompactionStrategy = .tiered,

    // Rolling statistics
    writes_per_second: f64 = 0,
    reads_per_second: f64 = 0,
    scans_per_second: f64 = 0,
    current_space_amp: f64 = 1.0,
    current_write_amp: f64 = 1.0,

    pub fn recommend_strategy(self: *const AdaptiveState) CompactionStrategy {
        // Per user decision: tiered as default for geospatial
        // Only switch to leveled if read-heavy or space constrained
        if (self.detected_workload == .read_heavy and self.current_space_amp > 1.5) {
            return .leveled;
        }
        return .tiered;
    }

    pub fn should_trigger_compaction(self: *const AdaptiveState, config: AdaptiveConfig) bool {
        // Dual trigger per user decision
        const write_change_trigger = self.write_throughput_changed(config.write_throughput_change_threshold);
        const space_amp_trigger = self.current_space_amp > config.space_amp_threshold;
        return write_change_trigger and space_amp_trigger;
    }
};
```

### Pattern 6: Block-Level Deduplication

**What:** Detect and reference duplicate value blocks via content hash
**When to use:** Trajectory data with repeated locations, common in geospatial workloads
**Why:** Can reduce storage by 10-30% for trajectory-heavy workloads

```zig
// Source: Data deduplication research, Duplicati architecture
pub const DedupConfig = struct {
    enabled: bool = true,
    hash_algorithm: enum { xxhash, cityhash } = .xxhash,  // Fast, non-crypto hash
    index_memory_limit: usize = 64 * 1024 * 1024,  // 64 MiB for dedup index
    min_block_size_for_dedup: usize = 4096,  // Don't dedup tiny blocks
};

pub const DedupIndex = struct {
    // Hash -> (address, reference_count)
    entries: std.AutoHashMap(u64, DedupEntry),

    pub const DedupEntry = struct {
        block_address: u64,
        reference_count: u32,
    };

    pub fn lookup_or_insert(self: *DedupIndex, block_hash: u64, new_address: u64) ?u64 {
        if (self.entries.get(block_hash)) |existing| {
            // Duplicate found, return existing address
            var entry = self.entries.getPtr(block_hash).?;
            entry.reference_count += 1;
            return existing.block_address;
        }
        // New block, insert
        self.entries.put(block_hash, .{
            .block_address = new_address,
            .reference_count = 1,
        }) catch return null;
        return null;
    }
};
```

### Anti-Patterns to Avoid

- **Compressing index blocks:** Index blocks need fast key lookups; compression adds latency
- **Synchronous compression in write path:** Compress during compaction, not during initial write
- **Ignoring write stall conditions:** Always check for stall conditions before aggressive compaction
- **Global dedup index:** Dedup index must be per-level or bounded to avoid memory explosion
- **Disabling compaction entirely:** Even in emergency, maintain minimum compaction to prevent L0 explosion

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| LZ4 compression | Custom compressor | allyourcodebase/lz4 | Battle-tested C library, optimal performance |
| Content hashing | Custom hash | xxHash via Zig stdlib | Extremely fast, well-tested |
| Histogram buckets | Custom percentile calc | Extend existing metrics.zig | Already has ExtendedStats pattern |
| Rate limiting | Custom limiter | Token bucket in stdx | Standard algorithm, already available |
| Rolling window stats | Custom accumulator | Sliding window counters | Well-known pattern |

**Key insight:** ArcherDB already has the LSM infrastructure. This phase adds compression at block level and tuning knobs, not wholesale rewrites.

## Common Pitfalls

### Pitfall 1: Compression Ratio Expectations

**What goes wrong:** Expecting 40-60% reduction on all data types
**Why it happens:** Geospatial data varies wildly in compressibility
**How to avoid:** Track per-block-type compression ratios; some blocks won't compress well
**Warning signs:** Average compression ratio < 20%; compression adding latency without space savings

### Pitfall 2: Write Amplification Misattribution

**What goes wrong:** Blaming compaction for write amp when flush is the issue
**Why it happens:** Not tracking writes at each stage separately
**How to avoid:** Track memtable flush writes, L0 writes, and per-level compaction writes separately
**Warning signs:** L0 size growing unbounded; write amp appears high but compaction is idle

### Pitfall 3: Throttling Oscillation

**What goes wrong:** Throttle bounces between full speed and minimum
**Why it happens:** Threshold too sensitive, no hysteresis
**How to avoid:** Add hysteresis (recovery threshold lower than activation threshold); require consecutive good checks before recovery
**Warning signs:** Throughput ratio changing every check interval; compaction CPU cycling

### Pitfall 4: Emergency Mode Stuck

**What goes wrong:** Database enters emergency mode and never recovers
**Why it happens:** Recovery conditions not achievable under current load
**How to avoid:** Emergency mode should be time-limited; auto-recovery attempt after cooldown; alert operator
**Warning signs:** Emergency mode > 5 minutes; disk usage not decreasing despite emergency measures

### Pitfall 5: Deduplication Memory Explosion

**What goes wrong:** Dedup index consumes all available memory
**Why it happens:** Index grows unbounded as data volume increases
**How to avoid:** Bound dedup index size; use LRU eviction; per-level dedup instead of global
**Warning signs:** Dedup index memory > configured limit; OOM during compaction

### Pitfall 6: Tiered Compaction Space Amplification

**What goes wrong:** Disk fills up faster than expected with tiered compaction
**Why it happens:** Tiered delays compaction, increasing space amplification
**How to avoid:** Set space amplification threshold (2x); switch to leveled if space-constrained
**Warning signs:** Space amp > 2.5x; disk usage growing faster than data volume

## Code Examples

Verified patterns from official sources:

### LZ4 Integration with Zig Build System

```zig
// Source: https://github.com/allyourcodebase/lz4
// build.zig integration
const lz4_dep = b.dependency("lz4", .{
    .target = target,
    .optimize = optimize,
});
exe.linkLibrary(lz4_dep.artifact("lz4"));

// Usage in code
const lz4 = @cImport({
    @cInclude("lz4.h");
});

pub fn compress(src: []const u8, dst: []u8) !usize {
    const result = lz4.LZ4_compress_default(
        src.ptr,
        dst.ptr,
        @intCast(src.len),
        @intCast(dst.len),
    );
    if (result <= 0) return error.CompressionFailed;
    return @intCast(result);
}

pub fn decompress(src: []const u8, dst: []u8, original_size: usize) !void {
    const result = lz4.LZ4_decompress_safe(
        src.ptr,
        dst.ptr,
        @intCast(src.len),
        @intCast(original_size),
    );
    if (result < 0) return error.DecompressionFailed;
}
```

### Prometheus Metrics for Storage

```zig
// Source: Extend existing src/archerdb/metrics.zig
// Per Prometheus naming conventions
pub var archerdb_compaction_write_amplification = Gauge.init(
    "archerdb_compaction_write_amplification",
    "Ratio of physical to logical bytes written (1.0 = no amplification)",
    null,
);

pub var archerdb_storage_space_amplification = Gauge.init(
    "archerdb_storage_space_amplification",
    "Ratio of physical to logical storage used",
    null,
);

pub var archerdb_compaction_throttle_ratio = Gauge.init(
    "archerdb_compaction_throttle_ratio",
    "Current compaction throughput ratio (1.0 = full speed)",
    null,
);

pub var archerdb_compression_ratio_total = Gauge.init(
    "archerdb_compression_ratio",
    "Ratio of compressed to uncompressed data size",
    "type=\"total\"",
);

pub var archerdb_dedup_ratio = Gauge.init(
    "archerdb_dedup_ratio",
    "Ratio of unique to total blocks",
    null,
);
```

### CLI Surface for Storage Operations

```zig
// Source: Extend existing src/archerdb/cli.zig patterns
// Per user decision: follow existing CLI patterns

// New inspect subcommand for storage
pub const Inspect = union(enum) {
    // Existing...
    storage: StorageInspect,
    compaction: CompactionInspect,
};

pub const StorageInspect = struct {
    verbose: bool = false,  // Show developer details
    level: ?u8 = null,      // Filter to specific level
};

pub const CompactionInspect = struct {
    show_throttle: bool = false,
    show_adaptive: bool = false,
};

// Runtime control API (temporary overrides)
// archerdb start --compaction-strategy=tiered
// archerdb start --compression=lz4
// archerdb start --emergency-mode-threshold=95

// Emergency mode trigger
// archerdb control emergency-mode enable
// archerdb control emergency-mode status
// archerdb control compaction pause
// archerdb control compaction resume
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Leveled compaction only | Tiered + leveled hybrid | 2020+ | 2-3x write amp reduction for write-heavy |
| Fixed compaction rate | Latency-driven throttling | 2019 (SILK) | Stable query latency |
| Manual tuning | Adaptive auto-tuning | 2023+ | 90% deployments need no manual tuning |
| No compression | Block-level LZ4 | Standard | 40-60% storage reduction |
| Fixed L0 threshold | Dynamic thresholds | 2024+ | Better responsiveness to workload changes |

**Deprecated/outdated:**
- **Zstd for all blocks:** Too slow for latency-sensitive geospatial queries
- **File-level deduplication:** Block-level is more granular and effective
- **Global dedup index:** Memory explosion; use bounded per-level indexes

## Open Questions

Things that couldn't be fully resolved:

1. **Exact throttling thresholds**
   - What we know: P99 threshold should be workload-dependent
   - What's unclear: Optimal default threshold for geospatial workloads
   - Recommendation: Start with 50ms P99 threshold, expose as config, tune based on Phase 11 benchmarks

2. **Emergency mode recovery**
   - What we know: Need auto-recovery to prevent stuck state
   - What's unclear: Best recovery strategy (time-based? load-based?)
   - Recommendation: 5-minute timeout with exponential backoff retry; alert after 3 failures

3. **Deduplication hash collision handling**
   - What we know: Hash collisions are rare but possible
   - What's unclear: Whether to verify block content on collision
   - Recommendation: Use 128-bit hash (collision probability negligible); add optional verification flag for paranoid mode

4. **Compression during compaction vs flush**
   - What we know: Compaction is better for avoiding write path latency
   - What's unclear: Whether to compress L0 blocks (frequently rewritten)
   - Recommendation: Start with compression only at L1+, measure L0 compression benefit separately

## Sources

### Primary (HIGH confidence)
- [allyourcodebase/lz4](https://github.com/allyourcodebase/lz4) - Zig LZ4 binding, verified API
- [RocksDB Write Stalls Wiki](https://github.com/facebook/rocksdb/wiki/Write-Stalls) - Throttling mechanisms
- [RocksDB Universal Compaction](https://github.com/facebook/rocksdb/wiki/universal-compaction) - Tiered compaction reference
- ArcherDB src/lsm/*.zig - Existing LSM implementation
- ArcherDB src/archerdb/metrics.zig - Existing metrics infrastructure

### Secondary (MEDIUM confidence)
- [Alibaba LSM Compaction Discussion](https://www.alibabacloud.com/blog/an-in-depth-discussion-on-the-lsm-compaction-mechanism_596780) - Tiered vs leveled tradeoffs
- [CockroachDB Storage Layer](https://www.cockroachlabs.com/docs/stable/architecture/storage-layer) - Write amplification monitoring
- [ArceKV Paper](https://arxiv.org/html/2508.03565v1) - Adaptive compaction research
- [Endure Paper](https://www.vldb.org/pvldb/vol15/p1605-huynh.pdf) - Robust LSM tuning

### Tertiary (LOW confidence)
- [DLC Paper](https://openproceedings.org/2021/conf/edbt/p137.pdf) - Latency-driven compaction (needs validation)
- Block deduplication techniques from backup systems (may need adaptation for LSM)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - allyourcodebase/lz4 verified, existing LSM code reviewed
- Architecture patterns: HIGH - Based on RocksDB, academic papers, and existing ArcherDB patterns
- Pitfalls: MEDIUM - Some pitfalls from research papers, some from general LSM knowledge

**Research date:** 2026-01-24
**Valid until:** 2026-02-24 (30 days - stable domain)

---

## Existing Infrastructure Summary

Key existing components that Phase 12 builds upon:

| Component | Location | Status | Phase 12 Action |
|-----------|----------|--------|-----------------|
| LSM compaction | `src/lsm/compaction.zig` | Mature | Add tiered strategy, throttling |
| Block structure | `src/lsm/schema.zig` | Mature | Add compression metadata |
| Table builder | `src/lsm/table.zig` | Mature | Add compression to value blocks |
| Forest controller | `src/lsm/forest.zig` | Mature | Add adaptive tuning hooks |
| Prometheus metrics | `src/archerdb/metrics.zig` | Phase 11 | Add storage-specific metrics |
| Storage dashboard | `observability/grafana/dashboards/archerdb-storage.json` | Exists | Add compression, write amp panels |
| CLI structure | `src/archerdb/cli.zig` | Mature | Add storage control commands |
| Constants/config | `src/config.zig` | Mature | Add compression, compaction config |
| Grid block I/O | `src/vsr/grid.zig` | Mature | No changes needed |

This infrastructure means Phase 12 is primarily **integration of compression at block level** and **compaction strategy enhancements**, not greenfield LSM development.
