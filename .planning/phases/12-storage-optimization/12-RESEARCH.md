# Phase 12: Storage Optimization - Research

**Researched:** 2026-01-24 (re-research update)
**Domain:** LSM-tree storage optimization, compression, compaction tuning, write amplification
**Confidence:** HIGH

## Summary

Phase 12 optimizes ArcherDB's LSM-tree storage for write-heavy geospatial workloads. The codebase already has a mature LSM implementation (`src/lsm/`) with leveled compaction, block-based storage (`64 KiB blocks` configurable via `config.cluster.block_size`), and existing compaction infrastructure including TTL-aware prioritization. The existing Grafana storage dashboard (`observability/grafana/dashboards/archerdb-storage.json`) and Prometheus metrics infrastructure from Phase 11 provide the observability foundation.

This re-research validates and updates the original findings with 2025-2026 developments:
- **LZ4 library recommendation remains valid:** `allyourcodebase/lz4` wrapping LZ4 v1.10.0 (July 2024) is still the best option for Zig. LZ4 v1.10.0 adds multithreading support, dictionary compression, and a new Level 2 compression mode. Alternative pure-Zig `LZig4` supports Zig 0.13 but remains less mature.
- **Tiered compaction patterns validated:** 2025 research (SIGMOD, ICPP, Journal of Big Data) confirms hybrid tiered+leveled approaches for write-heavy workloads.
- **Adaptive compaction research updated:** ELMo-Tune-V2 (Feb 2025) and comprehensive LSM survey (July 2025) provide new insights on auto-tuning. LLM-based tuning shows 14x gains but has 100s startup time - not suitable for real-time. Rule-based adaptive tuning remains practical.
- **TiKV flow control pattern:** TiKV's predictive throttling (replacing RocksDB's reactive stall) is a validated pattern for smoother write latency.

**Primary recommendation:** Integrate compression at the block level using `allyourcodebase/lz4` (LZ4 v1.10.0) with the Zig build system. Implement tiered compaction as a configuration option alongside existing leveled compaction, with predictive throttling based on pending compaction bytes (TiKV-style) rather than purely reactive P99 latency threshold.

## Standard Stack

The established libraries/tools for this domain:

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| [allyourcodebase/lz4](https://github.com/allyourcodebase/lz4) | 1.10.0-6 (wraps LZ4 v1.10.0) | Block compression | Zig build system integration, LZ4 fastest decompression, multithreading support in v1.10.0, industry standard |
| Existing LSM implementation | N/A | Block storage, compaction | Already mature, battle-tested in ArcherDB |
| Existing metrics.zig | N/A | Prometheus metrics | Phase 11 infrastructure, histogram/ExtendedStats support |
| std.hash.XxHash64 | Zig stdlib | Content hashing for dedup | Built into Zig, extremely fast, well-tested |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| [LZig4](https://github.com/BarabasGitHub/LZig4) | Latest (Zig 0.13) | Pure Zig LZ4 | If C dependency is problematic; less mature |
| std.hash.CityHash64 | Zig stdlib | Alternative content hash | Alternative to xxhash if needed |
| Existing archerdb-storage.json dashboard | N/A | Storage visualization | Extend with new metrics |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| LZ4 | Zstd | Zstd better ratio (30-40% smaller) but 3-5x slower decompression; LZ4 prioritizes latency (user decision: LZ4) |
| allyourcodebase/lz4 | LZig4 | Pure Zig avoids C deps but less tested, only 16 commits, may have perf differences |
| Tiered compaction | Leveled (current) | Leveled has lower space amp (1.1-1.2x), tiered has lower write amp (2-3x reduction) |
| Reactive P99 throttling | Predictive throttling (TiKV-style) | Predictive prevents stalls before they happen; reactive responds after degradation starts |

**Installation:**
```bash
# Add LZ4 dependency to build.zig.zon
cd /home/g/archerdb
zig fetch --save git+https://github.com/allyourcodebase/lz4.git#1.10.0-6
```

**build.zig integration:**
```zig
const lz4_dep = b.dependency("lz4", .{
    .target = target,
    .optimize = optimize,
});
exe.linkLibrary(lz4_dep.artifact("lz4"));
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
// Source: Based on ArcherDB src/lsm/schema.zig header pattern + LZ4 v1.10.0 API
const CompressionType = enum(u4) {
    none = 0,
    lz4 = 1,
    // Reserved for future: zstd = 2
};

// Extend existing block header metadata (in schema.zig)
// Uses reserved bytes in current TableIndex.Metadata
pub const CompressionMetadata = extern struct {
    compression: CompressionType = .none,
    uncompressed_size: u32 = 0,  // Original size before compression
    // Fits within existing reserved: [82]u8 field in TableIndex.Metadata
};

// Compression wrapper using LZ4 v1.10.0 API
const lz4 = @cImport({
    @cInclude("lz4.h");
});

pub fn compress_block(input: []const u8, output: []u8) !struct { size: usize, type: CompressionType } {
    const compressed_size = lz4.LZ4_compress_default(
        input.ptr,
        output.ptr,
        @intCast(input.len),
        @intCast(output.len),
    );

    // Only use compression if it saves at least 10% space
    if (compressed_size > 0 and compressed_size < input.len * 9 / 10) {
        return .{ .size = @intCast(compressed_size), .type = .lz4 };
    }
    // Fall back to uncompressed
    @memcpy(output[0..input.len], input);
    return .{ .size = input.len, .type = .none };
}

pub fn decompress_block(
    input: []const u8,
    output: []u8,
    compression: CompressionType,
    uncompressed_size: u32,
) !usize {
    switch (compression) {
        .none => {
            @memcpy(output[0..input.len], input);
            return input.len;
        },
        .lz4 => {
            const result = lz4.LZ4_decompress_safe(
                input.ptr,
                output.ptr,
                @intCast(input.len),
                @intCast(uncompressed_size),
            );
            if (result < 0) return error.DecompressionFailed;
            return @intCast(result);
        },
    }
}
```

### Pattern 2: Tiered Compaction Strategy

**What:** Merge multiple sorted runs at same size tier before promoting to next level
**When to use:** Write-heavy workloads (recommended default for geospatial)
**Why:** Reduces write amplification by 2-3x for update-heavy workloads (validated by 2025 research)

```zig
// Source: RocksDB Universal Compaction, SIGMOD 2025 "How to Grow an LSM-tree?"
pub const CompactionStrategy = enum {
    leveled,   // Current: aggressive merge, lower space amp (1.1-1.2x)
    tiered,    // New: delayed merge, lower write amp (2-3x reduction)
};

pub const TieredCompactionConfig = struct {
    // Number of sorted runs to accumulate before merging
    size_ratio: f64 = 2.0,          // Merge when total size > size_ratio * largest_run
    min_merge_width: u32 = 2,        // Minimum runs to merge
    max_merge_width: u32 = 8,        // Maximum runs to merge at once (RocksDB default)
    max_size_amplification_percent: u32 = 200,  // Trigger compaction if space amp exceeds this

    // From 2025 research: partial vs full compaction tradeoff
    // Full compaction: better average throughput but worse tail latency
    // Partial compaction: worse average but better tail latency
    prefer_partial_compaction: bool = true,  // Better for latency-sensitive workloads
};

// Tiered compaction decision logic
pub fn should_compact_tiered(level: *const Level, config: TieredCompactionConfig) bool {
    const runs = level.sorted_run_count();
    if (runs < config.min_merge_width) return false;

    // Check space amplification (primary trigger per user decision)
    const space_amp = level.total_size() / level.logical_size();
    if (space_amp * 100 > config.max_size_amplification_percent) return true;

    // Check size ratio trigger
    const largest_run_size = level.largest_run_size();
    const total_other_size = level.total_size() - largest_run_size;
    return total_other_size >= config.size_ratio * @as(f64, @floatFromInt(largest_run_size));
}
```

### Pattern 3: Predictive Compaction Throttling (TiKV-Style)

**What:** Proactively slow compaction based on pending compaction bytes, not just reactive P99 latency
**When to use:** All compaction operations
**Why:** Prevents write stalls before they happen (TiKV's production-validated approach)

```zig
// Source: TiKV Flow Control (2025), RocksDB Write Stalls wiki
// Key insight: RocksDB's default limiter is reactive, not predictive.
// By the time P99 reacts, stall is unavoidable. TiKV predicts and smooths pressure.

pub const ThrottleConfig = struct {
    // Predictive thresholds (pending compaction bytes)
    soft_pending_compaction_bytes: u64 = 64 * 1024 * 1024 * 1024,  // 64 GiB: start slowing
    hard_pending_compaction_bytes: u64 = 256 * 1024 * 1024 * 1024, // 256 GiB: aggressive slow

    // Reactive fallback (P99 latency)
    p99_latency_threshold_ms: f64 = 50.0,     // Start throttling above this
    p99_latency_critical_ms: f64 = 100.0,     // Emergency throttle above this

    check_interval_ms: u64 = 1000,            // How often to check
    throttle_ratio_step: f64 = 0.1,           // How much to reduce/increase per check
    min_throughput_ratio: f64 = 0.1,          // Never go below 10% throughput
    recovery_hysteresis_ms: f64 = 10.0,       // Wait for latency to drop this much below threshold
};

pub const ThrottleState = struct {
    current_throughput_ratio: f64 = 1.0,  // 1.0 = full speed, 0.1 = 10%
    last_check_ns: i64 = 0,
    consecutive_good_checks: u32 = 0,

    // Predictive mode (preferred)
    pending_compaction_bytes: u64 = 0,

    pub fn update(self: *ThrottleState, metrics: ThrottleMetrics, config: ThrottleConfig) void {
        // Predictive path: check pending compaction bytes first
        if (metrics.pending_compaction_bytes > config.hard_pending_compaction_bytes) {
            // Aggressive slowdown before stall
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio * 0.5  // Halve immediately
            );
            self.consecutive_good_checks = 0;
            return;
        }

        if (metrics.pending_compaction_bytes > config.soft_pending_compaction_bytes) {
            // Gradual slowdown
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio - config.throttle_ratio_step
            );
            self.consecutive_good_checks = 0;
            return;
        }

        // Reactive fallback: check P99 latency
        if (metrics.current_p99_ms > config.p99_latency_critical_ms) {
            self.current_throughput_ratio = config.min_throughput_ratio;
            self.consecutive_good_checks = 0;
        } else if (metrics.current_p99_ms > config.p99_latency_threshold_ms) {
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio - config.throttle_ratio_step
            );
            self.consecutive_good_checks = 0;
        } else if (metrics.current_p99_ms < config.p99_latency_threshold_ms - config.recovery_hysteresis_ms) {
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

const ThrottleMetrics = struct {
    pending_compaction_bytes: u64,
    current_p99_ms: f64,
};
```

### Pattern 4: Write Amplification Monitoring

**What:** Track ratio of physical writes to logical writes at each stage
**When to use:** All write paths
**Why:** Key metric for LSM health, validates optimization effectiveness

```zig
// Source: CockroachDB Storage Layer, 2025 LSM Survey, EDBT 2025 partial compaction research
pub const WriteAmpMetrics = struct {
    // Rolling window counters (per user decision: 1min, 5min, 1hr windows)
    logical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    physical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Per-stage tracking (critical for debugging per research)
    memtable_flush_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    l0_compaction_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Per-level tracking for deeper analysis
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
**Why:** "Just works" for 90% of deployments without manual tuning (user requirement)

```zig
// Source: ELMo-Tune-V2 (2025), Endure paper, 2025 LSM Survey
// Note: LLM-based tuning (ELMo-Tune-V2) achieves 14x gains but requires ~100s startup
// For real-time, use rule-based adaptive tuning with user-specified triggers

pub const AdaptiveConfig = struct {
    // Triggers for adaptation (per user decision: dual trigger)
    write_throughput_change_threshold: f64 = 0.20,  // 20% change triggers re-evaluation
    space_amp_threshold: f64 = 2.0,                  // 2x logical size triggers aggressive compaction

    // Sliding window for workload detection
    window_duration_ms: u64 = 60_000,  // 1 minute window
    sample_interval_ms: u64 = 1000,    // Sample every second

    // Bounds on auto-tuning (guardrails per user decision)
    min_compaction_threads: u32 = 1,
    max_compaction_threads: u32 = 4,
    min_l0_compaction_trigger: u32 = 2,
    max_l0_compaction_trigger: u32 = 20,

    // Prevent obviously bad settings (guardrails per user decision)
    disk_usage_compaction_required_threshold: f64 = 0.90,  // >90% disk: must compact
    min_throughput_ratio_at_high_disk: f64 = 0.5,          // At least 50% compaction at high disk
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

    // Throughput change tracking
    previous_write_throughput: f64 = 0,

    pub fn recommend_strategy(self: *const AdaptiveState) CompactionStrategy {
        // Per user decision: tiered as default for geospatial
        // Only switch to leveled if read-heavy or space constrained
        if (self.detected_workload == .read_heavy and self.current_space_amp > 1.5) {
            return .leveled;
        }
        return .tiered;
    }

    pub fn should_trigger_compaction(self: *const AdaptiveState, config: AdaptiveConfig) bool {
        // Dual trigger per user decision: both conditions must be met
        const write_change = @abs(self.writes_per_second - self.previous_write_throughput) /
            @max(self.previous_write_throughput, 1.0);
        const write_change_trigger = write_change > config.write_throughput_change_threshold;
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
// Source: Data deduplication research, std.hash.XxHash64 from Zig stdlib
const std = @import("std");

pub const DedupConfig = struct {
    enabled: bool = true,
    index_memory_limit: usize = 64 * 1024 * 1024,  // 64 MiB for dedup index
    min_block_size_for_dedup: usize = 4096,  // Don't dedup tiny blocks
};

pub const DedupIndex = struct {
    // Hash -> (address, reference_count)
    // Use std.hash.XxHash64 for fast, high-quality hashing
    entries: std.AutoHashMap(u64, DedupEntry),
    memory_used: usize = 0,
    config: DedupConfig,

    pub const DedupEntry = struct {
        block_address: u64,
        reference_count: u32,
    };

    pub fn lookup_or_insert(self: *DedupIndex, block_data: []const u8, new_address: u64) ?u64 {
        if (block_data.len < self.config.min_block_size_for_dedup) return null;

        // Use XxHash64 from std.hash (built into Zig)
        const block_hash = std.hash.XxHash64.hash(0, block_data);

        if (self.entries.get(block_hash)) |existing| {
            // Duplicate found, return existing address
            var entry = self.entries.getPtr(block_hash).?;
            entry.reference_count += 1;
            return existing.block_address;
        }

        // Check memory limit before inserting
        if (self.memory_used + @sizeOf(DedupEntry) > self.config.index_memory_limit) {
            // Memory limit reached, skip dedup for this block
            return null;
        }

        // New block, insert
        self.entries.put(block_hash, .{
            .block_address = new_address,
            .reference_count = 1,
        }) catch return null;
        self.memory_used += @sizeOf(DedupEntry);
        return null;
    }
};
```

### Anti-Patterns to Avoid

- **Compressing index blocks:** Index blocks need fast key lookups; compression adds latency on critical path
- **Synchronous compression in write path:** Compress during compaction, not during initial write (avoid write latency spikes)
- **Ignoring write stall conditions:** Always check for stall conditions before aggressive compaction (TiKV lesson)
- **Global dedup index:** Dedup index must be per-level or bounded to avoid memory explosion
- **Disabling compaction entirely:** Even in emergency, maintain minimum compaction to prevent L0 explosion
- **Reactive-only throttling:** Use predictive (pending bytes) + reactive (P99 latency) for smoother control

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| LZ4 compression | Custom compressor | allyourcodebase/lz4 | Battle-tested C library, LZ4 v1.10.0 with multithreading |
| Content hashing | Custom hash | std.hash.XxHash64 | Built into Zig stdlib, extremely fast, well-tested |
| Histogram buckets | Custom percentile calc | Extend existing metrics.zig ExtendedStats | Already has P50-P99.99 support |
| Rate limiting | Custom limiter | Token bucket pattern | Well-known algorithm, simple to implement correctly |
| Rolling window stats | Custom accumulator | Sliding window counters | Well-known pattern |

**Key insight:** ArcherDB already has the LSM infrastructure. This phase adds compression at block level and tuning knobs, not wholesale rewrites. Use existing patterns from `src/archerdb/metrics.zig`, `src/lsm/compaction.zig`, and `src/config.zig`.

## Common Pitfalls

### Pitfall 1: Compression Ratio Expectations

**What goes wrong:** Expecting 40-60% reduction on all data types
**Why it happens:** Geospatial data varies wildly in compressibility; S2 cell IDs are high-entropy
**How to avoid:** Track per-block-type compression ratios; some blocks won't compress well (e.g., pre-hashed data)
**Warning signs:** Average compression ratio < 20%; compression adding latency without space savings

### Pitfall 2: Write Amplification Misattribution

**What goes wrong:** Blaming compaction for write amp when flush is the issue
**Why it happens:** Not tracking writes at each stage separately (2025 research emphasizes this)
**How to avoid:** Track memtable flush writes, L0 writes, and per-level compaction writes separately
**Warning signs:** L0 size growing unbounded; write amp appears high but compaction is idle

### Pitfall 3: Throttling Oscillation

**What goes wrong:** Throttle bounces between full speed and minimum
**Why it happens:** Threshold too sensitive, no hysteresis; reactive-only approach
**How to avoid:** Use predictive throttling (pending bytes) + hysteresis for reactive; require consecutive good checks before recovery
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
**Why it happens:** Tiered delays compaction, increasing space amplification (can reach 2.5-3x)
**How to avoid:** Set space amplification threshold (2x per user decision); switch to leveled if space-constrained
**Warning signs:** Space amp > 2.5x; disk usage growing faster than data volume

### Pitfall 7: Partial vs Full Compaction Tradeoff (2025 Research)

**What goes wrong:** Full compaction causes write stalls at large levels
**Why it happens:** Full compaction has better average throughput but worse tail latency
**How to avoid:** Use partial compaction for latency-sensitive workloads; accept slightly higher write amp
**Warning signs:** Significant write stalls during L5-L6 compaction; latency spikes during peak hours

## Code Examples

Verified patterns from official sources:

### LZ4 Integration with Zig Build System

```zig
// Source: https://github.com/allyourcodebase/lz4, LZ4 v1.10.0 API
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

pub var archerdb_compaction_pending_bytes = Gauge.init(
    "archerdb_compaction_pending_bytes",
    "Bytes waiting to be compacted",
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

// Runtime control API (temporary overrides, revert on restart per user decision)
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
| Reactive throttling | Predictive + reactive (TiKV) | 2025 | Prevents stalls before they happen |
| Manual tuning | Adaptive auto-tuning | 2023+ | 90% deployments need no manual tuning |
| No compression | Block-level LZ4 | Standard | 40-60% storage reduction |
| Fixed L0 threshold | Dynamic thresholds | 2024+ | Better responsiveness to workload changes |
| Full compaction only | Partial compaction option | 2025 | Better tail latency at large levels |

**Deprecated/outdated:**
- **Zstd for all blocks:** Too slow for latency-sensitive geospatial queries (3-5x slower decompression)
- **File-level deduplication:** Block-level is more granular and effective
- **Global dedup index:** Memory explosion; use bounded per-level indexes
- **Reactive-only throttling:** TiKV's experience shows predictive is superior

## Open Questions

Things that couldn't be fully resolved:

1. **Exact throttling thresholds**
   - What we know: P99 threshold should be workload-dependent; TiKV uses pending bytes as primary signal
   - What's unclear: Optimal `soft_pending_compaction_bytes` default for geospatial workloads
   - Recommendation: Start with 64 GiB soft / 256 GiB hard pending bytes, expose as config, tune based on Phase 11 benchmarks

2. **Emergency mode recovery**
   - What we know: Need auto-recovery to prevent stuck state
   - What's unclear: Best recovery strategy (time-based? load-based?)
   - Recommendation: 5-minute timeout with exponential backoff retry; alert after 3 failures

3. **Deduplication hash collision handling**
   - What we know: Hash collisions are rare with 64-bit hashes (1 in 2^64)
   - What's unclear: Whether to verify block content on collision
   - Recommendation: XxHash64 collision probability negligible; add optional verification flag for paranoid mode

4. **Compression during compaction vs flush**
   - What we know: Compaction is better for avoiding write path latency
   - What's unclear: Whether to compress L0 blocks (frequently rewritten)
   - Recommendation: Start with compression only at L1+, measure L0 compression benefit separately

5. **LZ4 Level 2 vs Level 1**
   - What we know: LZ4 v1.10.0 adds Level 2 which balances speed and ratio better than Level 1
   - What's unclear: Whether Level 2's slight slowdown is acceptable for geospatial workloads
   - Recommendation: Start with Level 1 (fastest), benchmark Level 2 as option

## Sources

### Primary (HIGH confidence)
- [allyourcodebase/lz4](https://github.com/allyourcodebase/lz4) - Zig LZ4 binding, version 1.10.0-6
- [LZ4 v1.10.0 Release Notes](https://github.com/lz4/lz4/releases/tag/v1.10.0) - Multicores edition features
- [RocksDB Compaction Wiki](https://github.com/facebook/rocksdb/wiki/Compaction) - Universal/tiered compaction reference
- [RocksDB Write Stalls Wiki](https://github.com/facebook/rocksdb/wiki/Write-Stalls) - Throttling mechanisms
- [Zig std.hash](https://github.com/ziglang/zig/blob/master/lib/std/hash.zig) - XxHash64 built-in
- ArcherDB src/lsm/*.zig - Existing LSM implementation
- ArcherDB src/archerdb/metrics.zig - Existing metrics infrastructure

### Secondary (MEDIUM confidence)
- [SIGMOD 2025: How to Grow an LSM-tree?](https://arxiv.org/pdf/2504.17178) - Tiered vs leveled analysis
- [ICPP 2025: Revisiting Multi-threaded Compaction](https://discos.sogang.ac.kr/file/2025/intl_conf/ICPP_2025_H_Byun.pdf) - DownForce design
- [Journal of Big Data 2025: Hybrid Compaction Strategies](https://link.springer.com/article/10.1186/s40537-025-01298-0) - Local-Range/Global-Range partitioning
- [2025 LSM Survey](https://arxiv.org/html/2507.09642v1) - Comprehensive review (100+ papers)
- [Alibaba LSM Compaction Discussion](https://www.alibabacloud.com/blog/an-in-depth-discussion-on-the-lsm-compaction-mechanism_596780) - Tiered vs leveled tradeoffs
- [CockroachDB Storage Layer](https://www.cockroachlabs.com/docs/stable/architecture/storage-layer) - Write amplification monitoring

### Tertiary (LOW confidence)
- [ELMo-Tune-V2](https://arxiv.org/abs/2502.17606) - LLM-based tuning (14x gains, but 100s startup time)
- [EDBT 2025: Partial Compaction](https://disc.bu.edu/papers/edbt25-wei) - Partial vs full compaction tradeoffs
- TiKV Flow Control article - Predictive throttling (URL inaccessible, pattern validated by multiple sources)
- [LZig4](https://github.com/BarabasGitHub/LZig4) - Pure Zig alternative (less mature)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - allyourcodebase/lz4 verified (v1.10.0), existing LSM code reviewed, std.hash.XxHash64 in stdlib
- Architecture patterns: HIGH - Based on RocksDB, 2025 academic papers, TiKV production experience, and existing ArcherDB patterns
- Pitfalls: HIGH - Updated with 2025 research (partial compaction, predictive throttling)

**Research date:** 2026-01-24 (re-research update)
**Valid until:** 2026-02-24 (30 days - stable domain)

---

## Existing Infrastructure Summary

Key existing components that Phase 12 builds upon:

| Component | Location | Status | Phase 12 Action |
|-----------|----------|--------|-----------------|
| LSM compaction | `src/lsm/compaction.zig` | Mature (2700+ lines) | Add tiered strategy, throttling |
| Block structure | `src/lsm/schema.zig` | Mature | Add compression metadata (use reserved bytes) |
| Table builder | `src/lsm/table.zig` | Mature | Add compression to value blocks |
| Forest controller | `src/lsm/forest.zig` | Mature | Add adaptive tuning hooks |
| Prometheus metrics | `src/archerdb/metrics.zig` | Phase 11 | Add storage-specific metrics |
| Storage dashboard | `observability/grafana/dashboards/archerdb-storage.json` | Exists (42KB) | Add compression, write amp panels |
| CLI structure | `src/archerdb/cli.zig` | Mature | Add storage control commands |
| Constants/config | `src/config.zig`, `src/constants.zig` | Mature | Add compression, compaction config |
| Grid block I/O | `src/vsr/grid.zig` | Mature | No changes needed |
| Build configuration | `build.zig.zon` | Exists | Add lz4 dependency |

This infrastructure means Phase 12 is primarily **integration of compression at block level** and **compaction strategy enhancements**, not greenfield LSM development.

## Changes from Original Research

Key updates in this re-research:

1. **LZ4 version clarified:** allyourcodebase/lz4 wraps LZ4 v1.10.0 (July 2024), which adds multithreading, dictionary compression, and Level 2 mode
2. **Throttling pattern updated:** TiKV's predictive throttling (pending bytes) is superior to purely reactive P99 latency approach
3. **2025 research incorporated:** SIGMOD, ICPP, Journal of Big Data papers validate tiered+leveled hybrid approaches
4. **Partial compaction tradeoff added:** EDBT 2025 research shows partial compaction has better tail latency at large levels
5. **std.hash.XxHash64 confirmed:** Built into Zig stdlib, no external dependency needed for content hashing
6. **ELMo-Tune-V2 noted but not recommended:** LLM-based tuning has impressive results (14x) but 100s startup time makes it unsuitable for real-time adaptive tuning
