// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Raw configuration values.
//!
//! Code which needs these values should use `constants.zig` instead.
//! Configuration values are set from a combination of:
//! - default values
//! - `root.archerdb_config`
//! - `@import("archerdb_options")`

const builtin = @import("builtin");
const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;

const root = @import("root");

const KiB = stdx.KiB;
const MiB = stdx.MiB;
const GiB = stdx.GiB;
const TiB = stdx.TiB;

const BuildOptions = struct {
    config_verify: bool,
    git_commit: ?[40]u8,
    release: ?[]const u8,
    release_client_min: ?[]const u8,
    config_aof_recovery: bool,
    config_base: ?[]const u8, // Build config preset name as string
    index_format: []const u8, // "standard" or "compact"
};

/// Build configuration presets.
/// Canonical names:
/// - `lite`: High-performance runtime with smallest capacity quotas.
/// - `standard`: High-performance runtime with larger capacity quotas.
/// - `pro`: High-performance runtime with higher capacity quotas.
/// - `enterprise`: High-performance runtime with large capacity quotas.
/// - `ultra`: High-performance runtime with highest capacity quotas.
pub const ConfigBase = enum {
    lite,
    standard,
    pro,
    enterprise,
    ultra,
};

/// RAM index entry format.
/// - `standard`: 64 bytes per entry, includes TTL fields at index level
/// - `compact`: 32 bytes per entry, 50% memory reduction, no index-level TTL
pub const IndexFormat = enum {
    standard,
    compact,
};

/// The configured index format (compile-time constant).
pub const index_format: IndexFormat =
    std.meta.stringToEnum(IndexFormat, build_options.index_format) orelse .standard;

// Allow setting build-time config either via `build.zig` `Options`, or via a struct in the root
// file.
const build_options: BuildOptions = blk: {
    const vsr_options =
        if (@hasDecl(root, "vsr_options"))
            root.vsr_options
        else
            @import("vsr_options");

    // Both the root file and Zig's `addOptions` expose the struct as identical structurally,
    // but a different type from a nominal typing perspective.
    var result: BuildOptions = undefined;
    for (std.meta.fields(BuildOptions)) |field| {
        @field(result, field.name) = launder_type(
            field.type,
            @field(vsr_options, field.name),
        );
    }
    break :blk result;
};

fn launder_type(comptime T: type, comptime value: anytype) T {
    if (T == bool or
        T == []const u8 or
        T == ?[]const u8 or
        T == ?[40]u8)
    {
        return value;
    }
    if (@typeInfo(T) == .@"enum") {
        assert(@typeInfo(@TypeOf(value)) == .@"enum" or @typeInfo(@TypeOf(value)) == .enum_literal);
        return @field(T, @tagName(value));
    }
    // Handle optional enums (e.g., ?ConfigBase)
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (@typeInfo(Child) == .@"enum") {
            if (value) |v| {
                return @field(Child, @tagName(v));
            } else {
                return null;
            }
        }
    }
    unreachable;
}

const vsr = @import("vsr.zig");
const sector_size = @import("constants.zig").sector_size;

pub const Config = struct {
    pub const Cluster = ConfigCluster;
    pub const Process = ConfigProcess;

    cluster: ConfigCluster,
    process: ConfigProcess,

    /// Returns true if the configuration is intended for "production".
    /// Intended solely for extra sanity-checks: all meaningful decisions should be driven by
    /// specific fields of the config.
    pub fn is_production(config: *const Config) bool {
        return config.cluster.journal_slot_count > ConfigCluster.journal_slot_count_min;
    }
};

/// Configurations which are tunable per-replica (or per-client).
/// - Replica configs need not equal each other.
/// - Client configs need not equal each other.
/// - Client configs need not equal replica configs.
/// - Replica configs can change between restarts.
///
/// Fields are documented within constants.zig.
// TODO: Some of these could be runtime parameters (e.g. grid_scrubber_cycle_ms).
const ConfigProcess = struct {
    log_level: std.log.Level = .info,
    verify: bool,
    release: vsr.Release = vsr.Release.minimum,
    release_client_min: vsr.Release = vsr.Release.minimum,
    git_commit: ?[40]u8 = null,
    port: u16 = 3001,
    address: []const u8 = "127.0.0.1",
    storage_size_limit_default: u64 = 16 * TiB,
    storage_size_limit_max: u64 = 64 * TiB,
    memory_size_max_default: u64 = GiB,
    cache_geo_events_size_default: u64,
    /// Memory budget for the RAM index (entity lookup hash table).
    /// Determines how many entities the node can track before IndexDegraded.
    /// Each slot costs 64 bytes (IndexEntry) plus ~32 bytes for scan buffers.
    /// Usable entities ≈ ram_index_size_default / 96 × 0.70 (load factor).
    ram_index_size_default: u64,
    client_request_queue_max: u32 = 2,
    lsm_manifest_node_size: u64 = 16 * KiB,
    connection_delay_min_ms: u64 = 50,
    connection_delay_max_ms: u64 = 1000,
    tcp_backlog: u31 = 64,
    tcp_rcvbuf: c_int = 4 * MiB,
    tcp_keepalive: bool = true,
    tcp_keepidle: c_int = 5,
    tcp_keepintvl: c_int = 4,
    tcp_keepcnt: c_int = 3,
    tcp_nodelay: bool = true,
    direct_io: bool,
    journal_iops_read_max: u32 = 8,
    journal_iops_write_max: u32 = 32,
    client_replies_iops_read_max: u32 = 1,
    client_replies_iops_write_max: u32 = 2,
    client_request_completion_warn_ms: u64 = 200,
    tick_ms: u63 = 10,
    rtt_ms: u64 = 300,
    rtt_max_ms: u64 = 1000 * 60,
    rtt_multiple: u8 = 2,
    backoff_min_ms: u64 = 10,
    backoff_max_ms: u64 = 10000,
    clock_offset_tolerance_max_ms: u64 = 10000,
    clock_epoch_max_ms: u64 = 60000,
    clock_synchronization_window_min_ms: u64 = 2000,
    clock_synchronization_window_max_ms: u64 = 20000,
    grid_iops_read_max: u64 = 32,
    grid_iops_write_max: u64 = 32,
    grid_cache_size_default: u64 = GiB,
    grid_repair_request_max: u32 = 4,
    grid_repair_reads_max: u32 = 4,
    grid_missing_blocks_max: u32 = 30,
    grid_missing_tables_max: u32 = 6,
    grid_scrubber_reads_max: u32 = 1,
    grid_scrubber_cycle_ms: u64 = std.time.ms_per_day * 180,
    grid_scrubber_interval_ms_min: u64 = std.time.ms_per_s / 20,
    grid_scrubber_interval_ms_max: u64 = std.time.ms_per_s * 10,
    aof_recovery: bool = false,
    multiversion_binary_platform_size_max: u64 = 64 * MiB,
    multiversion_poll_interval_ms: u64 = 1000,

    // =========================================================================
    // Compaction Throttling Configuration
    // =========================================================================
    //
    // Latency-driven compaction throttling prevents I/O spikes from impacting
    // query latency. The throttle has two modes:
    //
    // 1. **Predictive (Primary)**: Monitors pending compaction bytes and
    //    proactively slows compaction before write stalls occur. This is the
    //    preferred path since it prevents degradation before it happens.
    //
    // 2. **Reactive (Fallback)**: Monitors P99 query latency and reduces
    //    compaction throughput when latency exceeds threshold.
    //
    // These settings are tuned for geospatial workloads. For different workloads:
    // - High-throughput, latency-tolerant: increase thresholds
    // - Latency-sensitive: decrease thresholds
    //
    // See Phase 11 benchmarks for tuning guidance.
    // =========================================================================

    /// Enable compaction throttling (default: enabled).
    /// When enabled, compaction throughput is reduced when pending compaction
    /// bytes or P99 query latency exceeds configured thresholds.
    compaction_throttle_enabled: bool = true,

    /// P99 latency threshold in milliseconds to start throttling (default: 50ms).
    /// When P99 query latency exceeds this threshold, compaction throughput
    /// is gradually reduced. This is the "soft" threshold for the reactive path.
    /// Must be > 0.
    compaction_p99_threshold_ms: u32 = 50,

    /// P99 latency critical threshold in milliseconds (default: 100ms).
    /// When P99 exceeds this threshold, compaction immediately drops to
    /// minimum throughput. This is the "emergency" threshold.
    /// Must be > compaction_p99_threshold_ms.
    compaction_p99_critical_ms: u32 = 100,

    /// Minimum compaction throughput ratio (default: 10% = 100).
    /// Compaction never drops below this percentage of full throughput.
    /// Stored as permille (1000 = 100%, 100 = 10%).
    /// Must be between 10 (1%) and 1000 (100%).
    compaction_min_throughput_permille: u32 = 100,

    /// Soft pending compaction bytes threshold in GiB (default: 64 GiB).
    /// When pending compaction bytes exceed this threshold, compaction
    /// throughput is gradually reduced (predictive throttling).
    compaction_soft_pending_gib: u32 = 64,

    /// Hard pending compaction bytes threshold in GiB (default: 256 GiB).
    /// When pending compaction bytes exceed this threshold, compaction
    /// throughput is immediately halved (aggressive predictive throttling).
    compaction_hard_pending_gib: u32 = 256,

    // =========================================================================
    // Adaptive Compaction Configuration
    // =========================================================================
    //
    // Adaptive compaction automatically tunes compaction parameters based on
    // observed workload patterns. This is the "just works" approach - most
    // deployments shouldn't need manual compaction tuning.
    //
    // How it works:
    // 1. Monitors workload metrics (writes/sec, reads/sec, scans/sec)
    // 2. Classifies workload type (write_heavy, read_heavy, scan_heavy, balanced)
    // 3. Adjusts parameters to optimize for detected workload
    //
    // Dual trigger prevents unnecessary parameter churn:
    // - Write throughput must change by >threshold% from baseline
    // - Space amplification must exceed threshold
    // Only when BOTH conditions are met does adaptation occur.
    //
    // Operator overrides: Set override_l0_trigger or override_compaction_threads
    // to lock specific parameters, preventing adaptive adjustment.
    //
    // See src/lsm/compaction_adaptive.zig for implementation details.
    // =========================================================================

    /// Enable adaptive compaction tuning (default: enabled).
    /// When enabled, compaction parameters auto-adjust based on workload patterns.
    /// Disable if you want full manual control over compaction settings.
    adaptive_compaction_enabled: bool = true,

    /// Write throughput change threshold for adaptation (default: 20% = 0.20).
    /// Adaptation triggers when writes/sec changes by more than this percentage
    /// from the baseline. Combined with space_amp_threshold for dual trigger.
    /// Must be between 0.05 (5%) and 0.50 (50%).
    /// Stored as permille (200 = 20%, range: 50-500).
    adaptive_write_change_threshold_permille: u32 = 200,

    /// Space amplification threshold for adaptation (default: 2.0x).
    /// Adaptation triggers when physical_size / logical_size exceeds this ratio.
    /// Combined with write_change_threshold for dual trigger.
    /// Must be between 1.5x and 5.0x.
    /// Stored as percentage (200 = 2.0x, range: 150-500).
    adaptive_space_amp_threshold_percent: u32 = 200,

    /// Operator override for L0 compaction trigger (default: null = use adaptive).
    /// If set, overrides the adaptive L0 trigger with this fixed value.
    /// Useful when you know the optimal L0 trigger for your workload.
    /// Valid range: 2-20.
    override_l0_trigger: ?u32 = null,

    /// Operator override for compaction thread count (default: null = use adaptive).
    /// If set, overrides the adaptive thread count with this fixed value.
    /// Useful when you want to limit compaction I/O impact.
    /// Valid range: 1-4.
    override_compaction_threads: ?u32 = null,
};

/// Configurations which are tunable per-cluster.
/// - All replicas within a cluster must have the same configuration.
/// - Replicas must reuse the same configuration when the binary is upgraded — they do not change
///   over the cluster lifetime.
/// - The storage formats generated by different ConfigClusters are incompatible.
///
/// Fields are documented within constants.zig.
const ConfigCluster = struct {
    cache_line_size: comptime_int = 64,
    clients_max: u32,
    pipeline_prepare_queue_max: u32 = 8,
    view_change_headers_suffix_max: u32 = 8 + 1,
    quorum_replication_max: u8 = 3,
    journal_slot_count: u32 = 1024,
    /// Maximum message size (header + body). Default: 1 MiB.
    /// NOTE: The spec (constants/spec.md) defines message_size_max = 10 MiB for production,
    /// which enables batch_events_max = 10,000 and query_result_max = 81,918 (~82k events).
    /// This provides excellent query performance for spatial queries returning large result sets.
    /// WAL implication: prepares_ring_size = journal_slot_count × message_size_max
    message_size_max: u32 = 10 * MiB,
    superblock_copies: comptime_int = 4,
    block_size: comptime_int = 512 * KiB,
    lsm_levels: u6 = 7,
    lsm_growth_factor: u32 = 8,
    lsm_compaction_ops: comptime_int = 32,
    lsm_snapshots_max: u32 = 32,
    lsm_manifest_compact_extra_blocks: comptime_int = 1,
    lsm_table_coalescing_threshold_percent: comptime_int = 50,
    vsr_releases_max: u32 = 64,

    // =========================================================================
    // Block Compression Configuration
    // =========================================================================
    //
    // Value blocks are compressed using LZ4 to reduce storage footprint by 40-60%.
    // Index blocks remain uncompressed for fast key lookups.
    //
    // Why compression is enabled by default:
    // - Typical geospatial data achieves 40-60% compression ratio
    // - LZ4 decompression is extremely fast (~4 GB/s), minimal query latency impact
    // - Significant storage cost reduction for large datasets
    //
    // When to disable compression:
    // - Data is already compressed (JPEG, PNG, encrypted)
    // - Extreme latency sensitivity (every microsecond matters)
    // - Storage is not a constraint
    //
    // =========================================================================

    /// Enable LZ4 compression for LSM value blocks (0 = disabled, 1 = enabled).
    /// Index blocks remain uncompressed for fast key lookups.
    /// Default: 1 (enabled, recommended for 40-60% storage reduction).
    lsm_compaction_block_compression: comptime_int = 1,

    /// Compression threshold as a percentage (1-100).
    /// Only use compression if compressed size <= (threshold% × original size).
    /// Example: 90 means only compress if output is ≤90% of input (≥10% savings).
    /// Default: 90 (require at least 10% compression savings to be worthwhile).
    lsm_compaction_compression_threshold_percent: comptime_int = 90,

    /// Minimum block body size (bytes) to attempt compression.
    /// Blocks smaller than this are stored uncompressed.
    /// Small blocks have poor compression ratios and high overhead.
    /// Default: 512 bytes (below this, compression overhead exceeds benefit).
    lsm_compaction_compression_min_size: comptime_int = 512,

    // =========================================================================
    // Compaction Strategy Configuration
    // =========================================================================
    //
    // Tiered compaction reduces write amplification by 2-3x compared to leveled
    // compaction, at the cost of higher space amplification. This is ideal for
    // write-heavy geospatial workloads with frequent location updates.
    //
    // Strategy comparison:
    // - Leveled: Aggressive merge, ~10-30x write amp, ~1.1x space amp
    //   Best for read-heavy workloads or space-constrained environments.
    //
    // - Tiered: Delayed merge, ~3-10x write amp, ~2-3x space amp
    //   Best for write-heavy workloads like geospatial tracking.
    //
    // See src/lsm/compaction_tiered.zig for implementation details.
    // =========================================================================

    /// Compaction strategy selection (0 = leveled, 1 = tiered).
    /// - 0 (leveled): Aggressive merge, lower space amplification.
    ///   Best for read-heavy workloads or space-constrained environments.
    /// - 1 (tiered): Delayed merge, lower write amplification.
    ///   Best for write-heavy workloads like geospatial location updates.
    /// Default: 1 (tiered, optimized for geospatial write-heavy workloads).
    lsm_compaction_strategy: comptime_int = 1,

    /// Tiered compaction: size ratio threshold for triggering compaction.
    /// Compaction triggers when: sum(smaller_runs) >= size_ratio * largest_run
    /// Scaled by 10 (so 20 = 2.0x ratio). Must be >= 10 (1.0x).
    /// Default: 20 (2.0x ratio, good balance for geospatial workloads).
    lsm_tiered_size_ratio_scaled: comptime_int = 20,

    /// Tiered compaction: space amplification threshold percentage.
    /// Compaction triggers when: physical_size > (threshold/100) * logical_size.
    /// Must be >= 100 (1.0x). Default: 200 (allow up to 2x space overhead).
    lsm_tiered_max_space_amp_percent: comptime_int = 200,

    /// Tiered compaction: maximum sorted runs per level before forced compaction.
    /// Prevents unbounded run growth which hurts read performance.
    /// Must be >= 2. Default: 10.
    lsm_tiered_max_sorted_runs: comptime_int = 10,

    // =========================================================================
    // Block Deduplication Configuration
    // =========================================================================
    //
    // Block-level deduplication detects repeated value blocks via content hashing
    // and stores references instead of duplicate data. This can reduce storage by
    // 10-30% for trajectory-heavy workloads where vehicles visit common locations.
    //
    // How it works:
    // - Content hash (XxHash64) computed for each value block
    // - If hash matches existing block, reference existing storage
    // - Per-level index with LRU eviction to bound memory usage
    // - Reference counting tracks block lifecycle
    //
    // Memory usage: dedup_index_memory_mb per LSM level
    // Example: 7 levels x 64 MiB = 448 MiB total for dedup indexes
    //
    // When to disable deduplication:
    // - Unique data with no repetition (randomized IDs, no trajectory patterns)
    // - Memory constrained environments
    // - Already achieving good compression ratios without dedup
    //
    // =========================================================================

    /// Enable block-level deduplication for LSM value blocks (0 = disabled, 1 = enabled).
    /// Detects duplicate blocks via content hashing and references existing storage.
    /// Default: 1 (enabled, recommended for 10-30% storage reduction on trajectory data).
    lsm_dedup_enabled: comptime_int = 1,

    /// Maximum memory for deduplication index per LSM level (in MiB).
    /// Higher values allow tracking more unique blocks, improving dedup hit rate.
    /// Total memory = dedup_index_memory_mb x lsm_levels
    /// Example: 64 MiB x 7 levels = 448 MiB total
    /// Default: 64 MiB per level.
    /// Valid range: 1-512 MiB.
    lsm_dedup_index_memory_mb: comptime_int = 64,

    /// Minimum block size (bytes) to consider for deduplication.
    /// Small blocks have high metadata overhead relative to savings.
    /// Default: 4096 bytes (4 KiB).
    /// Valid range: 1024-65536 bytes.
    lsm_dedup_min_block_size: comptime_int = 4096,

    /// Minimal value.
    // TODO(batiati): Maybe this constant should be derived from `grid_iops_read_max`,
    // since each scan can read from `lsm_levels` in parallel.
    lsm_scans_max: comptime_int = 6,

    /// The WAL requires at least two sectors of redundant headers — otherwise we could lose them
    /// all to a single torn write. A replica needs at least one valid redundant header to
    /// determine an (untrusted) maximum op in recover_torn_prepare(), without which it cannot
    /// truncate a torn prepare.
    pub const journal_slot_count_min = 2 * @divExact(sector_size, @sizeOf(vsr.Header));

    pub const clients_max_min = 1;

    /// The smallest possible message_size_max (for use in the simulator to improve performance).
    /// The message body must have room for pipeline_prepare_queue_max headers in the DVC.
    pub fn message_size_max_min(clients_max: u32) u32 {
        return @max(
            sector_size,
            std.mem.alignForward(
                u32,
                @sizeOf(vsr.Header) + clients_max * @sizeOf(vsr.Header),
                sector_size,
            ),
        );
    }

    /// Fingerprint of the cluster-wide configuration.
    /// It is used to assert that all cluster members share the same config.
    pub fn checksum(comptime config: ConfigCluster) u128 {
        @setEvalBranchQuota(10_000);
        comptime var config_bytes: []const u8 = &.{};
        comptime for (std.meta.fields(ConfigCluster)) |field| {
            const value = @field(config, field.name);
            const value_64 = @as(u64, value);
            assert(builtin.target.cpu.arch.endian() == .little);
            config_bytes = config_bytes ++ std.mem.asBytes(&value_64);
        };
        return vsr.checksum(config_bytes);
    }
};

// ConfigBase enum is now defined earlier in the file

pub const configs = struct {
    /// Shared high-performance runtime profile used by standard–ultra tiers.
    /// Tier differentiation is handled by RAM/disk capacity quotas only.
    const runtime_high_perf = Config{
        .process = .{
            .direct_io = true,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * 4 * MiB,
            .ram_index_size_default = 2 * GiB, // Overridden per tier.
            .verify = true,
            .journal_iops_read_max = 24,
            .journal_iops_write_max = 32,
            .grid_cache_size_default = 4 * GiB,
            .grid_iops_read_max = 96,
            .grid_iops_write_max = 96,
            .grid_repair_request_max = 12,
            .grid_repair_reads_max = 12,
            .grid_missing_blocks_max = 128,
            .grid_missing_tables_max = 16,
        },
        .cluster = .{
            .clients_max = 256,
            .pipeline_prepare_queue_max = 24,
            .view_change_headers_suffix_max = 24 + 1,
            .journal_slot_count = 1024,
            .message_size_max = 10 * MiB,
            .lsm_levels = 8,
            .lsm_growth_factor = 8,
            .lsm_compaction_ops = 128,
            .block_size = 1 * MiB,
            .lsm_manifest_compact_extra_blocks = 3,
            .lsm_table_coalescing_threshold_percent = 35,
            .lsm_snapshots_max = 128,
            .lsm_scans_max = 16,
        },
    };

    /// Lightweight runtime profile for lite/demo tier.
    /// Reduces clients, pipeline depth, and journal slots to cut fixed overhead,
    /// making the data file small enough to run on a dev laptop.
    const runtime_lite = Config{
        .process = .{
            .direct_io = true,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * 4 * MiB,
            .ram_index_size_default = 128 * MiB, // Overridden below.
            .verify = true,
            .journal_iops_read_max = 8,
            .journal_iops_write_max = 8,
            .grid_cache_size_default = 4 * GiB,
            .grid_iops_read_max = 96,
            .grid_iops_write_max = 96,
            .grid_repair_request_max = 12,
            .grid_repair_reads_max = 12,
            .grid_missing_blocks_max = 128,
            .grid_missing_tables_max = 16,
        },
        .cluster = .{
            .clients_max = 64,
            .pipeline_prepare_queue_max = 8,
            .view_change_headers_suffix_max = 8 + 1,
            .journal_slot_count = 256,
            .message_size_max = 10 * MiB,
            .lsm_levels = 8,
            .lsm_growth_factor = 8,
            // Reduced from 128 so checkpoint interval fits in 256 journal slots.
            // vsr_checkpoint_ops = 256 - 32 - 32*ceil(16/32) = 192, which satisfies
            // all assertions (>= pipeline=8, >= compaction=32, % 32 == 0).
            .lsm_compaction_ops = 32,
            .block_size = 1 * MiB,
            .lsm_manifest_compact_extra_blocks = 3,
            .lsm_table_coalescing_threshold_percent = 35,
            .lsm_snapshots_max = 128,
            .lsm_scans_max = 16,
        },
    };

    fn with_capacity(
        comptime storage_default: u64,
        comptime storage_max: u64,
        comptime ram_index_default: u64,
    ) Config {
        var process = runtime_high_perf.process;
        process.storage_size_limit_default = storage_default;
        process.storage_size_limit_max = storage_max;
        process.ram_index_size_default = ram_index_default;
        return Config{
            .process = process,
            .cluster = runtime_high_perf.cluster,
        };
    }

    /// Demo/evaluation tier — small footprint, fast startup, runnable on a dev laptop.
    pub const lite = lite: {
        var process = runtime_lite.process;
        process.storage_size_limit_default = 4 * GiB;
        process.storage_size_limit_max = 4 * GiB;
        process.ram_index_size_default = 128 * MiB;
        break :lite Config{
            .process = process,
            .cluster = runtime_lite.cluster,
        };
    };

    /// Baseline production capacity tier.
    pub const standard = with_capacity(
        64 * GiB,
        256 * GiB,
        4 * GiB,
    );

    /// Mid-tier capacity profile for larger datasets.
    pub const pro = with_capacity(
        512 * GiB,
        2 * TiB,
        16 * GiB,
    );

    /// Large production capacity profile.
    pub const enterprise = with_capacity(
        4 * TiB,
        16 * TiB,
        32 * GiB,
    );

    /// Highest-capacity profile.
    pub const ultra = with_capacity(
        16 * TiB,
        64 * TiB,
        64 * GiB,
    );

    pub const current = current: {
        // Priority: 1) build option -Dconfig, 2) root config, 3) test default, 4) standard
        var base = if (build_options.config_base) |config_base_str|
            if (std.mem.eql(u8, config_base_str, "lite"))
                lite
            else if (std.mem.eql(u8, config_base_str, "standard"))
                standard
            else if (std.mem.eql(u8, config_base_str, "pro"))
                pro
            else if (std.mem.eql(u8, config_base_str, "enterprise"))
                enterprise
            else if (std.mem.eql(u8, config_base_str, "ultra"))
                ultra
            else
                @compileError(
                    "Invalid config_base: expected 'lite', 'standard', 'pro', " ++
                        "'enterprise', or 'ultra'",
                )
        else if (@hasDecl(root, "archerdb_config"))
            root.archerdb_config
        else if (builtin.is_test)
            lite
        else
            standard;

        if (build_options.release == null and build_options.release_client_min != null) {
            @compileError("must set release if setting release_client_min");
        }

        if (build_options.release_client_min == null and build_options.release != null) {
            @compileError("must set release_client_min if setting release");
        }

        const release = if (build_options.release) |release|
            vsr.Release.from(vsr.ReleaseTriple.parse(release) catch {
                @compileError("invalid release version");
            })
        else
            vsr.Release.minimum;

        const release_client_min = if (build_options.release_client_min) |release_client_min|
            vsr.Release.from(vsr.ReleaseTriple.parse(release_client_min) catch {
                @compileError("invalid release_client_min version");
            })
        else
            vsr.Release.minimum;

        base.process.release = release;
        base.process.release_client_min = release_client_min;
        base.process.git_commit = build_options.git_commit;
        base.process.aof_recovery = build_options.config_aof_recovery;
        base.process.verify = build_options.config_verify;

        assert(base.process.release.value >= base.process.release_client_min.value);

        break :current base;
    };

    /// The name of the active build configuration tier ("lite", "standard", etc.).
    /// Used by tests to skip resource-intensive cluster tests in lite mode.
    pub const config_name: []const u8 = if (build_options.config_base) |name|
        name
    else if (builtin.is_test)
        "lite"
    else
        "standard";
};
