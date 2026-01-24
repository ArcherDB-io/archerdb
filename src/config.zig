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
    config_base: ?[]const u8, // "production" or "lite" as string
    index_format: []const u8, // "standard" or "compact"
};

/// Build configuration presets.
/// - `production`: Full-featured, optimized for throughput (7+ GiB RAM)
/// - `lite`: Minimal footprint for evaluation/testing (~130 MiB RAM)
pub const ConfigBase = enum {
    production,
    lite,
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
    /// A good default config for production.
    pub const default_production = Config{
        .process = .{
            .direct_io = true,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * MiB,
            .verify = true,
        },
        .cluster = .{
            .clients_max = 64,
        },
    };

    // =========================================================================
    // Hardware Tier Configurations for LSM Performance Tuning
    // =========================================================================
    //
    // These configurations are optimized for different hardware tiers to meet
    // the performance targets from CONTEXT.md:
    // - Enterprise: 1M+ writes/sec, 100k+ reads/sec
    // - Mid-tier: 500k+ writes/sec, 50k+ reads/sec
    // - Point queries: < 1ms at p99
    // - No p99 latency spikes during compaction
    //
    // Key tuning parameters:
    // - lsm_levels: More levels = larger capacity, but higher read amplification
    // - lsm_growth_factor: Higher = lower write amp, but higher read amp
    // - lsm_compaction_ops: Larger memtable = fewer flushes, but more memory
    // - block_size: Larger blocks = better seq read, but higher space amp
    // - lsm_manifest_compact_extra_blocks: More = faster manifest compaction
    // - lsm_table_coalescing_threshold_percent: Lower = more aggressive coalescing
    //
    // Bloom filter note: ArcherDB uses key-range based filtering at the index
    // block level rather than traditional bloom filters. The index block stores
    // min/max keys per value block, enabling efficient range pruning.
    //
    // See docs/lsm-tuning.md for detailed explanations.
    // =========================================================================

    /// Enterprise tier configuration — optimized for high-end hardware.
    ///
    /// Target hardware:
    /// - NVMe SSDs (4+ GB/s sequential read/write)
    /// - 16+ CPU cores
    /// - 64+ GB RAM
    ///
    /// Expected performance:
    /// - 1M+ writes/sec
    /// - 100k+ reads/sec
    /// - Point queries < 1ms at p99
    /// - No latency spikes during compaction
    ///
    /// Write amplification: ~10x (excellent for write-heavy workloads)
    pub const enterprise = Config{
        .process = .{
            .direct_io = true,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * 4 * MiB,
            .verify = true,
            // Higher I/O concurrency for NVMe
            .journal_iops_read_max = 16,
            .journal_iops_write_max = 64,
            // Larger grid cache for better read performance
            .grid_cache_size_default = 4 * GiB,
            .grid_iops_read_max = 64,
            .grid_iops_write_max = 64,
            // More concurrent block repairs
            .grid_repair_request_max = 8,
            .grid_repair_reads_max = 8,
            .grid_missing_blocks_max = 64,
            .grid_missing_tables_max = 12,
        },
        .cluster = .{
            .clients_max = 256,
            // 7 levels with growth factor 8:
            // L0: 8 tables, L1: 64, L2: 512, L3: 4K, L4: 32K, L5: 256K, L6: 2M
            // Total capacity: ~2.4M tables, each up to 512KB = ~1.2 TB per tree
            .lsm_levels = 7,
            .lsm_growth_factor = 8,
            // Larger memtable (64 ops) reduces flush frequency
            // More ops per flush = better batching = lower write amplification
            .lsm_compaction_ops = 64,
            // Large blocks optimized for NVMe sequential I/O
            // 512 KB blocks reduce metadata overhead and improve throughput
            .block_size = 512 * KiB,
            // More aggressive manifest compaction for large datasets
            .lsm_manifest_compact_extra_blocks = 2,
            // More aggressive table coalescing (40%) to reduce fragmentation
            // Lower threshold = more frequent coalescing = better space efficiency
            .lsm_table_coalescing_threshold_percent = 40,
            // Larger pipeline for higher throughput
            .pipeline_prepare_queue_max = 16,
            .view_change_headers_suffix_max = 16 + 1,
            // More snapshots for longer-running queries
            .lsm_snapshots_max = 64,
            // More concurrent scans
            .lsm_scans_max = 12,
        },
    };

    /// Mid-tier configuration — optimized for moderate hardware.
    ///
    /// Target hardware:
    /// - SATA SSDs (500 MB/s sequential read/write)
    /// - 8 CPU cores
    /// - 32 GB RAM
    ///
    /// Expected performance:
    /// - 500k+ writes/sec
    /// - 50k+ reads/sec
    /// - Point queries < 2ms at p99
    /// - Minimal latency impact during compaction
    ///
    /// Write amplification: ~12x (good balance)
    pub const mid_tier = Config{
        .process = .{
            .direct_io = true,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * 2 * MiB,
            .verify = true,
            // Moderate I/O concurrency for SATA SSDs
            .journal_iops_read_max = 8,
            .journal_iops_write_max = 32,
            // Moderate grid cache
            .grid_cache_size_default = 2 * GiB,
            .grid_iops_read_max = 32,
            .grid_iops_write_max = 32,
            // Standard block repairs
            .grid_repair_request_max = 4,
            .grid_repair_reads_max = 4,
            .grid_missing_blocks_max = 32,
            .grid_missing_tables_max = 8,
        },
        .cluster = .{
            .clients_max = 128,
            // 6 levels with growth factor 10:
            // L0: 10 tables, L1: 100, L2: 1K, L3: 10K, L4: 100K, L5: 1M
            // Higher growth factor = fewer levels = faster reads
            // Trade-off: higher write amplification
            .lsm_levels = 6,
            .lsm_growth_factor = 10,
            // Standard memtable size
            .lsm_compaction_ops = 32,
            // Smaller blocks for SATA (better latency characteristics)
            // 256 KB blocks balance throughput and latency
            .block_size = 256 * KiB,
            // Standard manifest compaction
            .lsm_manifest_compact_extra_blocks = 1,
            // Standard coalescing threshold
            .lsm_table_coalescing_threshold_percent = 50,
            // Standard pipeline
            .pipeline_prepare_queue_max = 8,
            .view_change_headers_suffix_max = 8 + 1,
            // Standard snapshot limit
            .lsm_snapshots_max = 32,
            // Standard scan concurrency
            .lsm_scans_max = 8,
        },
    };

    /// Lite configuration — minimal memory footprint (~130 MiB) for evaluation and testing.
    /// Uses small WAL, small messages, and minimal caches. Great for trying out ArcherDB
    /// without requiring 7+ GiB of RAM. Tradeoff: smaller batch sizes (~30 events max).
    pub const lite = Config{
        .process = .{
            .storage_size_limit_default = 1 * GiB,
            .storage_size_limit_max = 1 * GiB,
            .direct_io = false,
            .cache_geo_events_size_default = @sizeOf(vsr.archerdb.GeoEvent) * 256,
            .journal_iops_read_max = 3,
            .journal_iops_write_max = 2,
            .grid_repair_request_max = 4,
            .grid_repair_reads_max = 4,
            .grid_missing_blocks_max = 3,
            .grid_missing_tables_max = 2,
            .grid_scrubber_reads_max = 2,
            .grid_scrubber_cycle_ms = std.time.ms_per_hour,
            .verify = true,
        },
        .cluster = .{
            .clients_max = 4 + 3,
            .pipeline_prepare_queue_max = 4,
            .view_change_headers_suffix_max = 4 + 1,
            .journal_slot_count = Config.Cluster.journal_slot_count_min,
            .message_size_max = Config.Cluster.message_size_max_min(4),

            .block_size = sector_size,
            .lsm_compaction_ops = 4,
            .lsm_growth_factor = 4,
            // (This is higher than the production default value because the block size is smaller.)
            .lsm_manifest_compact_extra_blocks = 5,
            // (We need to fuzz more scans merge than in production.)
            .lsm_scans_max = 12,
        },
    };

    pub const current = current: {
        // Priority: 1) build option -Dconfig, 2) root config, 3) test default, 4) production
        var base = if (build_options.config_base) |config_base_str|
            if (std.mem.eql(u8, config_base_str, "lite"))
                lite
            else if (std.mem.eql(u8, config_base_str, "production"))
                default_production
            else
                @compileError("Invalid config_base: expected 'lite' or 'production'")
        else if (@hasDecl(root, "archerdb_config"))
            root.archerdb_config
        else if (builtin.is_test)
            lite
        else
            default_production;

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
};
