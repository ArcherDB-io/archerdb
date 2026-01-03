//! Index Checkpoint - Periodic persistence of RAM index to disk.
//!
//! Implements an incremental dirty-page checkpoint strategy to avoid
//! massive I/O spikes when persisting large indexes (90GB+ for 1B entities).
//!
//! Key features:
//! - Dirty page tracking via bitset (1 bit per page)
//! - Continuous background flush of dirty pages
//! - Coordination with VSR checkpoint for recovery
//! - Recovery decision tree: WAL replay → LSM scan → Full rebuild
//!
//! Checkpoint coordination:
//! 1. VSR Checkpoint (storage-engine) - Every 256 operations
//! 2. Index Checkpoint (this module) - Continuous background process
//!
//! Recovery paths:
//! - Case A: WAL replay (gap <= journal_slot_count) - Fast
//! - Case B: LSM scan (8K-20K ops gap) - Medium
//! - Case C: Full rebuild (checkpoint very old) - Slow
//!
//! See specs/hybrid-memory/spec.md for full requirements.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const fs = std.fs;

const log = std.log.scoped(.index_checkpoint);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const RamIndex = @import("../ram_index.zig").RamIndex;
const IndexEntry = @import("../ram_index.zig").IndexEntry;

/// Checkpoint file magic number: "ARCH" (0x41524348)
pub const MAGIC: u32 = 0x41524348;

/// Current checkpoint format version.
pub const VERSION: u16 = 1;

/// Default page size for dirty tracking (64KB).
/// This determines checkpoint granularity - smaller = more overhead, larger = more wasted writes.
pub const default_page_size: u32 = 64 * 1024;

/// Maximum checkpoint age before triggering rebuild (7 days in seconds).
pub const max_checkpoint_age_seconds: u64 = 7 * 24 * 60 * 60;

/// CheckpointHeader - 256-byte header for index checkpoint files.
///
/// Layout matches spec requirements with Aegis-128L checksums for integrity.
pub const CheckpointHeader = extern struct {
    /// Magic number: 0x41524348 ("ARCH")
    magic: u32 = MAGIC,

    /// Checkpoint format version
    version: u16 = VERSION,

    /// Reserved padding for alignment
    reserved1: u16 = 0,

    /// Number of index entries in this checkpoint
    entry_count: u64 = 0,

    /// Index capacity (total slots)
    capacity: u64 = 0,

    /// Highest timestamp seen in indexed events
    timestamp_high_water: u64 = 0,

    /// VSR checkpoint op number at index checkpoint time
    vsr_checkpoint_op: u64 = 0,

    /// VSR commit_max at index checkpoint time
    vsr_commit_max: u64 = 0,

    /// Unix timestamp when checkpoint was created (nanoseconds)
    checkpoint_timestamp_ns: u64 = 0,

    /// Checksum of header (Aegis-128L MAC), computed after this field
    header_checksum: u128 = 0,

    /// Padding for u128 alignment
    header_checksum_padding: u128 = 0,

    /// Checksum of all index entries (Aegis-128L MAC)
    body_checksum: u128 = 0,

    /// Padding for u128 alignment
    body_checksum_padding: u128 = 0,

    /// Number of pages in checkpoint
    page_count: u64 = 0,

    /// Page size in bytes
    page_size: u32 = default_page_size,

    /// Reserved padding
    reserved2: u32 = 0,

    /// Reserved for future use (106 bytes to reach 256 total)
    reserved: [106]u8 = [_]u8{0} ** 106,

    /// Validate header fields for sanity.
    pub fn validate(self: CheckpointHeader) bool {
        if (self.magic != MAGIC) return false;
        if (self.version == 0 or self.version > VERSION) return false;
        if (self.capacity == 0) return false;
        if (self.entry_count > self.capacity) return false;
        if (self.page_size == 0) return false;
        return true;
    }

    /// Check if checkpoint is stale (age > max_checkpoint_age_seconds).
    pub fn is_stale(self: CheckpointHeader) bool {
        const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
        const age_ns = now_ns -| self.checkpoint_timestamp_ns;
        const age_seconds = age_ns / std.time.ns_per_s;
        return age_seconds > max_checkpoint_age_seconds;
    }
};

// Compile-time validation of CheckpointHeader layout.
comptime {
    // CheckpointHeader must be exactly 256 bytes.
    assert(@sizeOf(CheckpointHeader) == 256);
}

/// Error codes for checkpoint operations.
pub const CheckpointError = error{
    /// File I/O error
    IoError,

    /// Invalid checkpoint header (magic, version, or validation failed)
    InvalidHeader,

    /// Checkpoint is corrupted (checksum mismatch)
    ChecksumMismatch,

    /// Checkpoint is stale (age > max_checkpoint_age_seconds)
    StaleCheckpoint,

    /// Out of memory
    OutOfMemory,

    /// File not found
    NotFound,

    /// Recovery required (checkpoint too old for WAL replay)
    RecoveryRequired,
};

/// Statistics for checkpoint operations.
pub const CheckpointStats = struct {
    /// Number of checkpoints written
    checkpoint_count: u64 = 0,

    /// Total pages written (across all checkpoints)
    pages_written: u64 = 0,

    /// Total bytes written
    bytes_written: u64 = 0,

    /// Last checkpoint timestamp (nanoseconds)
    last_checkpoint_ns: u64 = 0,

    /// Last checkpoint duration (nanoseconds)
    last_checkpoint_duration_ns: u64 = 0,

    /// Number of recovery operations
    recovery_count: u64 = 0,

    /// Recovery path taken (for metrics)
    last_recovery_path: RecoveryPath = .none,

    /// Last recovery duration (nanoseconds)
    last_recovery_duration_ns: u64 = 0,

    /// Index checkpoint op at last checkpoint
    last_checkpoint_op: u64 = 0,

    /// VSR checkpoint op at last checkpoint (for lag calculation)
    last_vsr_checkpoint_op: u64 = 0,
};

// =============================================================================
// Recovery Metrics (F2.2.9)
// =============================================================================
//
// Prometheus-style metrics for monitoring recovery window health:
//
// archerdb_index_checkpoint_age_seconds (gauge)
//   - Age of the most recent index checkpoint
//   - Alert: Warning if > 120s, Critical if > 300s
//
// archerdb_index_checkpoint_lag_ops (gauge)
//   - Operations between index checkpoint and VSR checkpoint
//   - Alert: Critical if > 15,000 (approaching LSM retention limit)
//
// archerdb_recovery_path_taken (counter)
//   - Labels: path="wal|lsm|rebuild|clean"
//   - Incremented on each startup based on recovery path
//
// archerdb_recovery_duration_seconds (histogram)
//   - Duration of the recovery procedure on startup

/// Recovery metrics for Prometheus-style monitoring.
///
/// These metrics expose checkpoint health and recovery statistics
/// per the spec (specs/hybrid-memory/spec.md).
pub const RecoveryMetrics = struct {
    /// Counter: Number of WAL replay recoveries
    recovery_wal_count: u64 = 0,

    /// Counter: Number of LSM scan recoveries
    recovery_lsm_count: u64 = 0,

    /// Counter: Number of full rebuild recoveries
    recovery_rebuild_count: u64 = 0,

    /// Counter: Number of clean starts (no checkpoint)
    recovery_clean_count: u64 = 0,

    /// Histogram buckets for recovery duration (nanoseconds).
    /// Buckets: [1s, 5s, 10s, 30s, 60s, 120s, 300s, 600s, 1800s, 3600s, 7200s]
    recovery_duration_bucket_1s: u64 = 0,
    recovery_duration_bucket_5s: u64 = 0,
    recovery_duration_bucket_10s: u64 = 0,
    recovery_duration_bucket_30s: u64 = 0,
    recovery_duration_bucket_60s: u64 = 0,
    recovery_duration_bucket_120s: u64 = 0,
    recovery_duration_bucket_300s: u64 = 0,
    recovery_duration_bucket_600s: u64 = 0,
    recovery_duration_bucket_1800s: u64 = 0,
    recovery_duration_bucket_3600s: u64 = 0,
    recovery_duration_bucket_7200s: u64 = 0,
    recovery_duration_bucket_inf: u64 = 0,

    /// Sum of all recovery durations (nanoseconds)
    recovery_duration_sum_ns: u64 = 0,

    /// Total recovery count (for histogram)
    recovery_duration_count: u64 = 0,

    /// Record a recovery event with duration and path.
    pub fn record_recovery(self: *RecoveryMetrics, path: RecoveryPath, duration_ns: u64) void {
        // Increment path counter
        switch (path) {
            .wal_replay => self.recovery_wal_count += 1,
            .lsm_scan => self.recovery_lsm_count += 1,
            .full_rebuild => self.recovery_rebuild_count += 1,
            .clean_start => self.recovery_clean_count += 1,
            .none => {},
        }

        // Update histogram
        self.recovery_duration_sum_ns += duration_ns;
        self.recovery_duration_count += 1;

        const duration_s = duration_ns / std.time.ns_per_s;
        if (duration_s <= 1) {
            self.recovery_duration_bucket_1s += 1;
        } else if (duration_s <= 5) {
            self.recovery_duration_bucket_5s += 1;
        } else if (duration_s <= 10) {
            self.recovery_duration_bucket_10s += 1;
        } else if (duration_s <= 30) {
            self.recovery_duration_bucket_30s += 1;
        } else if (duration_s <= 60) {
            self.recovery_duration_bucket_60s += 1;
        } else if (duration_s <= 120) {
            self.recovery_duration_bucket_120s += 1;
        } else if (duration_s <= 300) {
            self.recovery_duration_bucket_300s += 1;
        } else if (duration_s <= 600) {
            self.recovery_duration_bucket_600s += 1;
        } else if (duration_s <= 1800) {
            self.recovery_duration_bucket_1800s += 1;
        } else if (duration_s <= 3600) {
            self.recovery_duration_bucket_3600s += 1;
        } else if (duration_s <= 7200) {
            self.recovery_duration_bucket_7200s += 1;
        } else {
            self.recovery_duration_bucket_inf += 1;
        }
    }

    /// Get recovery count by path (for Prometheus labels).
    pub fn get_recovery_count(self: *const RecoveryMetrics, path: RecoveryPath) u64 {
        return switch (path) {
            .wal_replay => self.recovery_wal_count,
            .lsm_scan => self.recovery_lsm_count,
            .full_rebuild => self.recovery_rebuild_count,
            .clean_start => self.recovery_clean_count,
            .none => 0,
        };
    }

    /// Calculate average recovery duration in nanoseconds.
    pub fn get_avg_recovery_duration_ns(self: *const RecoveryMetrics) u64 {
        if (self.recovery_duration_count == 0) return 0;
        return self.recovery_duration_sum_ns / self.recovery_duration_count;
    }
};

/// Calculate checkpoint age in seconds from stats.
pub fn checkpoint_age_seconds(stats: *const CheckpointStats) u64 {
    if (stats.last_checkpoint_ns == 0) return 0;
    const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
    const age_ns = now_ns -| stats.last_checkpoint_ns;
    return age_ns / std.time.ns_per_s;
}

/// Calculate checkpoint lag in operations from stats.
pub fn checkpoint_lag_ops(stats: *const CheckpointStats) u64 {
    return stats.last_vsr_checkpoint_op -| stats.last_checkpoint_op;
}

/// Check if checkpoint age is in warning state (> 2 minutes).
pub fn is_checkpoint_age_warning(stats: *const CheckpointStats) bool {
    return checkpoint_age_seconds(stats) > RecoveryAlertThresholds.warning_age_seconds;
}

/// Check if checkpoint age is in critical state (> 5 minutes).
pub fn is_checkpoint_age_critical(stats: *const CheckpointStats) bool {
    return checkpoint_age_seconds(stats) > RecoveryAlertThresholds.critical_age_seconds;
}

/// Check if checkpoint lag is approaching critical limit (> 15,000 ops).
pub fn is_checkpoint_lag_critical(stats: *const CheckpointStats) bool {
    return checkpoint_lag_ops(stats) > RecoveryAlertThresholds.critical_lag_ops;
}

/// Recovery path taken during startup.
pub const RecoveryPath = enum {
    none,
    wal_replay, // Case A: Fast path via WAL
    lsm_scan, // Case B: Medium path via LSM
    full_rebuild, // Case C: Slow path via full rebuild
    clean_start, // No checkpoint, first startup

    /// Convert to Prometheus-style label value.
    pub fn to_label(self: RecoveryPath) []const u8 {
        return switch (self) {
            .none => "none",
            .wal_replay => "wal",
            .lsm_scan => "lsm",
            .full_rebuild => "rebuild",
            .clean_start => "clean",
        };
    }
};

// =============================================================================
// Recovery Window Guarantees (F2.2.7)
// =============================================================================
//
// The recovery system implements a tiered decision tree to minimize recovery time:
//
// Case A (WAL Replay): Gap <= journal_slot_count ops
//   - Replay WAL from index_checkpoint_op + 1 to vsr_checkpoint_op
//   - SLA: < 1 second (p99)
//   - Most common path for normal restarts
//
// Case B (LSM Scan): Gap > journal_slot_count but LSM tables exist
//   - Query LSM manifest for tables covering the op range
//   - SLA: < 30 seconds (p99)
//   - Occurs when WAL has wrapped but compaction hasn't deleted tables
//
// Case C (Full Rebuild): LSM tables compacted away
//   - Scan all LSM levels newest→oldest with seen_entities bitset
//   - SLA: < 2 hours for 16TB, < 2 minutes for 128GB (p99)
//   - Worst case, only when checkpoint is very old or corrupted
//
// Case D (Stale Checkpoint): Checkpoint age > 1 week
//   - Treat as potentially corrupted, trigger rebuild with alerting
//   - Same SLA as Case C
//   - Prevents silent corruption from causing data loss

/// Recovery SLA thresholds per the spec.
pub const RecoverySLA = struct {
    /// WAL replay must complete within this time (nanoseconds).
    /// Spec: < 1 second (p99)
    pub const wal_replay_ns: u64 = 1 * std.time.ns_per_s;

    /// LSM scan must complete within this time (nanoseconds).
    /// Spec: < 30 seconds (p99)
    pub const lsm_scan_ns: u64 = 30 * std.time.ns_per_s;

    /// Full rebuild SLA depends on data size. For 128GB: ~2 minutes.
    /// Spec: < 2 hours for 16TB
    pub const rebuild_small_ns: u64 = 2 * 60 * std.time.ns_per_s; // 128GB
    pub const rebuild_large_ns: u64 = 2 * 60 * 60 * std.time.ns_per_s; // 16TB

    /// Threshold for small vs large data files (128GB).
    pub const small_data_threshold_bytes: u64 = 128 * 1024 * 1024 * 1024;
};

/// Alert thresholds for recovery window health monitoring.
pub const RecoveryAlertThresholds = struct {
    /// Warning: checkpoint age > 2 minutes
    pub const warning_age_seconds: u64 = 120;

    /// Critical: checkpoint age > 5 minutes
    pub const critical_age_seconds: u64 = 300;

    /// Critical: checkpoint lag > 15,000 ops (approaching LSM retention limit)
    pub const critical_lag_ops: u64 = 15_000;

    /// Stale checkpoint threshold: > 1 week (triggers rebuild)
    pub const stale_checkpoint_seconds: u64 = 7 * 24 * 60 * 60;
};

/// Recovery configuration parameters.
pub const RecoveryConfig = struct {
    /// WAL journal slot count (TigerBeetle default: 8192).
    /// Recovery Case A is viable when gap <= journal_slot_count.
    journal_slot_count: u64 = 8192,

    /// LSM compaction retention ops.
    /// Recovery Case B is viable when gap <= compaction_retention_ops.
    compaction_retention_ops: u64 = 20_000,

    /// Index checkpoint interval (seconds).
    /// Lower = faster recovery, higher = less I/O overhead.
    checkpoint_interval_seconds: u64 = 60,

    /// Force rebuild if checkpoint is stale (age > this threshold).
    stale_checkpoint_threshold_seconds: u64 = RecoveryAlertThresholds.stale_checkpoint_seconds,

    /// Enable LSM manifest check for Case B decision.
    enable_lsm_fallback: bool = true,

    /// Create config with custom journal slot count.
    pub fn with_journal_slots(journal_slots: u64) RecoveryConfig {
        return .{ .journal_slot_count = journal_slots };
    }
};

/// Input data for recovery decision.
pub const RecoveryInput = struct {
    /// Index checkpoint op number (from checkpoint header).
    index_checkpoint_op: u64,

    /// VSR checkpoint op number (from superblock).
    vsr_checkpoint_op: u64,

    /// Index checkpoint timestamp (nanoseconds).
    index_checkpoint_timestamp_ns: u64,

    /// Current timestamp (nanoseconds).
    current_timestamp_ns: u64,

    /// Whether LSM manifest covers the required op range.
    /// Set by querying LSM: tables exist with op_min <= index_op and op_max >= vsr_op.
    lsm_covers_gap: bool,

    /// Whether checkpoint header is valid (checksum OK, magic OK).
    checkpoint_valid: bool,

    /// Calculate the operation gap.
    pub fn op_gap(self: RecoveryInput) u64 {
        return self.vsr_checkpoint_op -| self.index_checkpoint_op;
    }

    /// Calculate checkpoint age in seconds.
    pub fn checkpoint_age_seconds(self: RecoveryInput) u64 {
        const age_ns = self.current_timestamp_ns -| self.index_checkpoint_timestamp_ns;
        return age_ns / std.time.ns_per_s;
    }
};

/// Recovery decision output.
pub const RecoveryDecision = struct {
    /// The recovery path to take.
    path: RecoveryPath,

    /// Human-readable reason for the decision.
    reason: []const u8,

    /// Operations that need to be replayed.
    ops_to_replay: u64,

    /// Estimated recovery time (nanoseconds).
    estimated_time_ns: u64,

    /// Whether an alert should be raised.
    should_alert: bool,

    /// Alert message (if should_alert is true).
    alert_message: []const u8,

    /// Determine recovery path based on input and config.
    ///
    /// Implements the recovery decision tree from specs/hybrid-memory/spec.md:
    ///
    /// ```
    /// 1. Load index checkpoint: index_checkpoint_op = N
    /// 2. Load VSR checkpoint: vsr_checkpoint_op = M
    /// 3. Calculate gap: G = M - N
    ///
    /// Case A: G <= journal_slot_count (8192 ops)
    ///   PATH: WAL Replay (FAST PATH)
    ///
    /// Case B: G > journal_slot_count AND LSM tables cover gap
    ///   PATH: LSM Replay (MEDIUM PATH)
    ///
    /// Case C: LSM tables don't cover gap (compaction occurred)
    ///   PATH: Full Rebuild (SLOW PATH)
    ///
    /// Case D: Checkpoint stale (age > 1 week) or invalid
    ///   PATH: Full Rebuild with alerting
    /// ```
    pub fn decide(input: RecoveryInput, config: RecoveryConfig) RecoveryDecision {
        const gap = input.op_gap();
        const age_seconds = input.checkpoint_age_seconds();

        // Case D: Stale or invalid checkpoint - trigger rebuild with alert
        if (!input.checkpoint_valid or age_seconds > config.stale_checkpoint_threshold_seconds) {
            const reason = if (!input.checkpoint_valid)
                "Checkpoint invalid (checksum or magic mismatch)"
            else
                "Checkpoint stale (age > 1 week)";

            const alert_msg = if (!input.checkpoint_valid)
                "Index checkpoint corrupted, triggering full rebuild"
            else
                "Index checkpoint stale (age > 1 week), triggering full rebuild";

            return .{
                .path = .full_rebuild,
                .reason = reason,
                .ops_to_replay = 0, // Full rebuild doesn't replay ops
                .estimated_time_ns = RecoverySLA.rebuild_large_ns,
                .should_alert = true,
                .alert_message = alert_msg,
            };
        }

        // Case A: Gap within WAL retention - fast WAL replay
        if (gap <= config.journal_slot_count) {
            return .{
                .path = .wal_replay,
                .reason = "Gap within WAL retention (Case A)",
                .ops_to_replay = gap,
                .estimated_time_ns = RecoverySLA.wal_replay_ns,
                .should_alert = false,
                .alert_message = "",
            };
        }

        // Case B: Gap exceeds WAL but LSM tables exist
        if (config.enable_lsm_fallback and input.lsm_covers_gap) {
            const should_warn = gap > RecoveryAlertThresholds.critical_lag_ops;
            return .{
                .path = .lsm_scan,
                .reason = "Gap exceeds WAL, using LSM scan (Case B)",
                .ops_to_replay = gap,
                .estimated_time_ns = RecoverySLA.lsm_scan_ns,
                .should_alert = should_warn,
                .alert_message = if (should_warn)
                    "Index checkpoint lag approaching LSM retention limit"
                else
                    "",
            };
        }

        // Case C: LSM tables compacted away - full rebuild required
        return .{
            .path = .full_rebuild,
            .reason = "LSM tables compacted, full rebuild required (Case C)",
            .ops_to_replay = 0,
            .estimated_time_ns = RecoverySLA.rebuild_large_ns,
            .should_alert = true,
            .alert_message = "Index requires full rebuild (LSM tables compacted away)",
        };
    }

    /// Log the decision for debugging/auditing.
    pub fn log_decision(self: RecoveryDecision) void {
        log.info("Recovery decision: path={s} reason=\"{s}\" ops={d} est_time={d}ns", .{
            self.path.to_label(),
            self.reason,
            self.ops_to_replay,
            self.estimated_time_ns,
        });

        if (self.should_alert) {
            log.warn("Recovery alert: {s}", .{self.alert_message});
        }
    }
};

/// DirtyPageTracker - Tracks which index pages have been modified since last checkpoint.
///
/// Uses a bitset where each bit represents one page (default 64KB).
/// For 91.5GB index with 64KB pages: ~1.43M pages = ~179KB bitset
pub fn DirtyPageTracker(comptime page_size: u32) type {
    return struct {
        const Self = @This();

        /// Bitset tracking dirty pages (1 = dirty, 0 = clean)
        dirty_bits: std.DynamicBitSet,

        /// Number of pages in the index
        page_count: u64,

        /// Number of currently dirty pages
        dirty_count: std.atomic.Value(u64),

        /// Total bytes in the index
        total_bytes: u64,

        pub fn init(allocator: Allocator, total_bytes: u64) !Self {
            const page_count = (total_bytes + page_size - 1) / page_size;

            const dirty_bits = try std.DynamicBitSet.initEmpty(allocator, @intCast(page_count));

            return Self{
                .dirty_bits = dirty_bits,
                .page_count = page_count,
                .dirty_count = std.atomic.Value(u64).init(0),
                .total_bytes = total_bytes,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = allocator;
            self.dirty_bits.deinit();
            self.* = undefined;
        }

        /// Mark a byte range as dirty.
        /// Called when index entries are modified.
        pub fn mark_dirty(self: *Self, offset: u64, len: u64) void {
            const start_page = offset / page_size;
            const end_page = (offset + len + page_size - 1) / page_size;

            var page = start_page;
            while (page < end_page and page < self.page_count) : (page += 1) {
                if (!self.dirty_bits.isSet(@intCast(page))) {
                    self.dirty_bits.set(@intCast(page));
                    _ = self.dirty_count.fetchAdd(1, .monotonic);
                }
            }
        }

        /// Mark a single page as dirty by page index.
        pub fn mark_page_dirty(self: *Self, page_index: u64) void {
            if (page_index >= self.page_count) return;

            if (!self.dirty_bits.isSet(@intCast(page_index))) {
                self.dirty_bits.set(@intCast(page_index));
                _ = self.dirty_count.fetchAdd(1, .monotonic);
            }
        }

        /// Clear dirty bit for a page after successful flush.
        pub fn clear_dirty(self: *Self, page_index: u64) void {
            if (page_index >= self.page_count) return;

            if (self.dirty_bits.isSet(@intCast(page_index))) {
                self.dirty_bits.unset(@intCast(page_index));
                _ = self.dirty_count.fetchSub(1, .monotonic);
            }
        }

        /// Clear all dirty bits (after full checkpoint).
        pub fn clear_all(self: *Self) void {
            self.dirty_bits.setRangeValue(.{ .start = 0, .end = @intCast(self.page_count) }, false);
            self.dirty_count.store(0, .monotonic);
        }

        /// Get number of dirty pages.
        pub fn get_dirty_count(self: *const Self) u64 {
            return self.dirty_count.load(.monotonic);
        }

        /// Check if a specific page is dirty.
        pub fn is_dirty(self: *const Self, page_index: u64) bool {
            if (page_index >= self.page_count) return false;
            return self.dirty_bits.isSet(@intCast(page_index));
        }

        /// Iterator over dirty pages.
        pub fn dirty_iterator(self: *const Self) DirtyIterator {
            return DirtyIterator{
                .bits = &self.dirty_bits,
                .page_count = self.page_count,
                .current = 0,
            };
        }

        pub const DirtyIterator = struct {
            bits: *const std.DynamicBitSet,
            page_count: u64,
            current: u64,

            pub fn next(self: *DirtyIterator) ?u64 {
                while (self.current < self.page_count) {
                    const page = self.current;
                    self.current += 1;
                    if (self.bits.isSet(@intCast(page))) {
                        return page;
                    }
                }
                return null;
            }
        };
    };
}

/// Default dirty page tracker with 64KB pages.
pub const DefaultDirtyTracker = DirtyPageTracker(default_page_size);

/// IndexCheckpoint - Manages checkpoint persistence for RAM index.
pub fn IndexCheckpoint(comptime page_size: u32) type {
    return struct {
        const Self = @This();
        const DirtyTracker = DirtyPageTracker(page_size);

        /// Dirty page tracker
        dirty_tracker: DirtyTracker,

        /// Checkpoint header (current state)
        header: CheckpointHeader,

        /// Statistics
        stats: CheckpointStats,

        /// Checkpoint file path
        checkpoint_path: []const u8,

        /// Allocator for internal use
        allocator: Allocator,

        /// Initialize checkpoint manager.
        pub fn init(
            allocator: Allocator,
            checkpoint_path: []const u8,
            index_capacity: u64,
        ) !Self {
            const total_bytes = index_capacity * @sizeOf(IndexEntry);

            return Self{
                .dirty_tracker = try DirtyTracker.init(allocator, total_bytes),
                .header = CheckpointHeader{
                    .capacity = index_capacity,
                    .page_size = page_size,
                    .page_count = (total_bytes + page_size - 1) / page_size,
                },
                .stats = CheckpointStats{},
                .checkpoint_path = checkpoint_path,
                .allocator = allocator,
            };
        }

        /// Deinitialize checkpoint manager.
        pub fn deinit(self: *Self) void {
            self.dirty_tracker.deinit(self.allocator);
            self.* = undefined;
        }

        /// Mark index entry as modified (for dirty tracking).
        /// Called by RamIndex on upsert/remove operations.
        pub fn mark_entry_dirty(self: *Self, entry_index: u64) void {
            const byte_offset = entry_index * @sizeOf(IndexEntry);
            self.dirty_tracker.mark_dirty(byte_offset, @sizeOf(IndexEntry));
        }

        /// Write incremental checkpoint (dirty pages only).
        ///
        /// This is the main checkpoint operation, designed to be called
        /// periodically in the background without blocking operations.
        pub fn write_incremental(
            self: *Self,
            index_entries: []const IndexEntry,
            vsr_checkpoint_op: u64,
            vsr_commit_max: u64,
        ) CheckpointError!void {
            const start_time = std.time.nanoTimestamp();

            // Open/create checkpoint file
            var file = fs.cwd().createFile(self.checkpoint_path, .{
                .read = true,
                .truncate = false,
            }) catch return error.IoError;
            defer file.close();

            // Update header
            self.header.entry_count = self.count_entries(index_entries);
            self.header.vsr_checkpoint_op = vsr_checkpoint_op;
            self.header.vsr_commit_max = vsr_commit_max;
            self.header.checkpoint_timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));

            // Calculate body checksum (all entries)
            self.header.body_checksum = self.calculate_body_checksum(index_entries);

            // Write dirty pages
            var pages_written: u64 = 0;
            var iter = self.dirty_tracker.dirty_iterator();
            while (iter.next()) |page_index| {
                const page_offset = page_index * page_size;
                const byte_offset = @sizeOf(CheckpointHeader) + page_offset;

                // Calculate entry range for this page
                const start_entry = page_offset / @sizeOf(IndexEntry);
                const end_entry = @min(
                    (page_offset + page_size) / @sizeOf(IndexEntry),
                    index_entries.len,
                );

                if (start_entry >= index_entries.len) continue;

                // Write page
                const page_entries = index_entries[start_entry..end_entry];
                const page_bytes = mem.sliceAsBytes(page_entries);

                file.seekTo(byte_offset) catch return error.IoError;
                file.writeAll(page_bytes) catch return error.IoError;

                self.dirty_tracker.clear_dirty(page_index);
                pages_written += 1;
            }

            // Calculate and write header checksum
            self.header.header_checksum = self.calculate_header_checksum();

            // Write header
            file.seekTo(0) catch return error.IoError;
            file.writeAll(mem.asBytes(&self.header)) catch return error.IoError;

            // Sync to disk
            file.sync() catch return error.IoError;

            // Update stats
            const end_time = std.time.nanoTimestamp();
            self.stats.checkpoint_count += 1;
            self.stats.pages_written += pages_written;
            self.stats.bytes_written += pages_written * page_size + @sizeOf(CheckpointHeader);
            self.stats.last_checkpoint_ns = @as(u64, @intCast(end_time));
            self.stats.last_checkpoint_duration_ns = @as(u64, @intCast(end_time - start_time));
        }

        /// Write full checkpoint (all pages).
        /// Used for initial checkpoint or recovery.
        pub fn write_full(
            self: *Self,
            index_entries: []const IndexEntry,
            vsr_checkpoint_op: u64,
            vsr_commit_max: u64,
        ) CheckpointError!void {
            const start_time = std.time.nanoTimestamp();

            // Mark all pages as dirty to force full write
            var page: u64 = 0;
            while (page < self.dirty_tracker.page_count) : (page += 1) {
                self.dirty_tracker.mark_page_dirty(page);
            }

            // Use incremental write (which will now write everything)
            try self.write_incremental(index_entries, vsr_checkpoint_op, vsr_commit_max);

            // Update stats
            const end_time = std.time.nanoTimestamp();
            self.stats.last_checkpoint_duration_ns = @as(u64, @intCast(end_time - start_time));
        }

        /// Load checkpoint from disk into index entries.
        /// Returns the VSR checkpoint op for replay coordination.
        pub fn load(
            self: *Self,
            index_entries: []IndexEntry,
        ) CheckpointError!struct { vsr_op: u64, vsr_commit_max: u64 } {
            var file = fs.cwd().openFile(self.checkpoint_path, .{}) catch |err| {
                if (err == error.FileNotFound) return error.NotFound;
                return error.IoError;
            };
            defer file.close();

            // Read header
            var header: CheckpointHeader = undefined;
            const header_bytes = file.reader().readBytesNoEof(@sizeOf(CheckpointHeader)) catch return error.IoError;
            header = @bitCast(header_bytes);

            // Validate header
            if (!header.validate()) return error.InvalidHeader;

            // Verify header checksum
            const expected_checksum = self.calculate_header_checksum_for(&header);
            if (header.header_checksum != expected_checksum) return error.ChecksumMismatch;

            // Check for stale checkpoint
            if (header.is_stale()) {
                self.stats.last_recovery_path = .full_rebuild;
                return error.StaleCheckpoint;
            }

            // Verify capacity matches
            if (header.capacity != self.header.capacity) return error.InvalidHeader;

            // Read index entries
            const entry_bytes = mem.sliceAsBytes(index_entries);
            _ = file.reader().readAll(entry_bytes) catch return error.IoError;

            // Verify body checksum
            const body_checksum = self.calculate_body_checksum(index_entries);
            if (header.body_checksum != body_checksum) return error.ChecksumMismatch;

            // Update our header with loaded state
            self.header = header;

            // Clear dirty bits (just loaded, nothing to flush)
            self.dirty_tracker.clear_all();

            self.stats.recovery_count += 1;
            self.stats.last_recovery_path = .wal_replay;

            return .{
                .vsr_op = header.vsr_checkpoint_op,
                .vsr_commit_max = header.vsr_commit_max,
            };
        }

        /// Check if checkpoint exists on disk.
        pub fn exists(self: *const Self) bool {
            _ = fs.cwd().statFile(self.checkpoint_path) catch return false;
            return true;
        }

        /// Get current dirty page count.
        pub fn get_dirty_count(self: *const Self) u64 {
            return self.dirty_tracker.get_dirty_count();
        }

        /// Get statistics.
        pub fn get_stats(self: *const Self) CheckpointStats {
            return self.stats;
        }

        // Internal helpers

        fn count_entries(self: *const Self, entries: []const IndexEntry) u64 {
            _ = self;
            var count: u64 = 0;
            for (entries) |entry| {
                if (!entry.is_empty() and !entry.is_tombstone()) {
                    count += 1;
                }
            }
            return count;
        }

        fn calculate_header_checksum(self: *Self) u128 {
            return self.calculate_header_checksum_for(&self.header);
        }

        fn calculate_header_checksum_for(self: *const Self, header: *const CheckpointHeader) u128 {
            _ = self;
            // Checksum covers header bytes after the checksum field
            const checksum_offset = @offsetOf(CheckpointHeader, "header_checksum") + @sizeOf(u128) + @sizeOf(u128);
            const header_bytes = mem.asBytes(header);
            const payload = header_bytes[checksum_offset..];
            return vsr.checksum(payload);
        }

        fn calculate_body_checksum(self: *const Self, entries: []const IndexEntry) u128 {
            _ = self;
            return vsr.checksum(mem.sliceAsBytes(entries));
        }
    };
}

/// Default index checkpoint with 64KB pages.
pub const DefaultIndexCheckpoint = IndexCheckpoint(default_page_size);

// ============================================================================
// Full Index Rebuild (F2.2.6)
// ============================================================================

/// SeenEntities bitset for tracking which entity IDs have been processed during rebuild.
/// Uses a bloom filter for memory efficiency (~128MB for 1B entities).
///
/// GDPR-CRITICAL: This bitset ensures newest versions take precedence.
/// By marking entities as "seen" after processing from newest-to-oldest,
/// we guarantee that deleted entities (tombstones) are not resurrected.
pub fn SeenEntitiesBitset(comptime expected_entities: u64) type {
    // Use ~1 bit per expected entity for ~1% false positive rate
    // For 1B entities: 1B / 8 = 128MB
    const bitset_bytes = (expected_entities + 7) / 8;

    return struct {
        const Self = @This();

        bits: []u8,
        allocator: Allocator,
        seen_count: u64 = 0,

        /// Initialize the seen entities bitset.
        pub fn init(allocator: Allocator) !Self {
            const bits = try allocator.alloc(u8, bitset_bytes);
            @memset(bits, 0);
            return Self{
                .bits = bits,
                .allocator = allocator,
            };
        }

        /// Free the bitset memory.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bits);
            self.* = undefined;
        }

        /// Mark an entity as seen. Returns true if this is the first time seeing it.
        /// Uses the hash of entity_id to determine bit position.
        ///
        /// GDPR-CRITICAL: Only the first occurrence (newest version) is processed.
        pub fn mark_seen(self: *Self, entity_id: u128) bool {
            const bit_index = self.hash_to_index(entity_id);
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;

            const already_seen = (self.bits[byte_index] & mask) != 0;
            if (!already_seen) {
                self.bits[byte_index] |= mask;
                self.seen_count += 1;
                return true; // First time seeing this entity
            }
            return false; // Already seen (skip this older version)
        }

        /// Check if an entity has been seen.
        pub fn was_seen(self: *const Self, entity_id: u128) bool {
            const bit_index = self.hash_to_index(entity_id);
            const byte_index = bit_index / 8;
            const bit_offset: u3 = @intCast(bit_index % 8);
            const mask: u8 = @as(u8, 1) << bit_offset;
            return (self.bits[byte_index] & mask) != 0;
        }

        /// Reset the bitset for reuse.
        pub fn reset(self: *Self) void {
            @memset(self.bits, 0);
            self.seen_count = 0;
        }

        /// Get the number of unique entities seen.
        pub fn get_seen_count(self: *const Self) u64 {
            return self.seen_count;
        }

        fn hash_to_index(self: *const Self, entity_id: u128) u64 {
            // Use lower bits of entity_id hash modulo bitset size
            const h = stdx.hash_inline(entity_id);
            return h % (self.bits.len * 8);
        }
    };
}

/// Rebuild progress tracking.
pub const RebuildProgress = struct {
    /// Total records scanned.
    records_scanned: u64 = 0,
    /// Records inserted into index.
    records_inserted: u64 = 0,
    /// Records skipped (already seen).
    records_skipped: u64 = 0,
    /// Records skipped (tombstones).
    tombstones_skipped: u64 = 0,
    /// Current LSM level being processed.
    current_level: u8 = 0,
    /// Previous LSM level (for assertion).
    previous_level: u8 = 255,
    /// Start timestamp (nanoseconds).
    start_time_ns: u64 = 0,
    /// Last progress log timestamp.
    last_log_time_ns: u64 = 0,

    /// Check GDPR-critical ordering invariant.
    /// Levels must be processed in order from L0 (newest) to L_max (oldest).
    /// In LSM, level numbers INCREASE from newest to oldest: L0 → L1 → ... → L6.
    pub fn assert_level_order(self: *RebuildProgress, level: u8) void {
        // GDPR-CRITICAL: newest-to-oldest order required
        // LSM levels: L0 (newest) → L6+ (oldest)
        // Level numbers must increase or stay same as we process
        assert(level >= self.current_level);
        self.previous_level = self.current_level;
        self.current_level = level;
    }

    /// Log progress every 1M records.
    pub fn log_progress_if_needed(self: *RebuildProgress, current_time_ns: u64) void {
        const log_interval_records: u64 = 1_000_000; // 1M records

        // Log every 1M records
        if (self.records_scanned % log_interval_records == 0 and self.records_scanned > 0) {
            const elapsed_ns = current_time_ns - self.start_time_ns;
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const rate = if (elapsed_s > 0)
                @as(f64, @floatFromInt(self.records_scanned)) / elapsed_s
            else
                0.0;

            log.info("Rebuild progress: scanned={} inserted={} skipped={} " ++
                "tombstones={} level={} rate={d:.0} rec/s", .{
                self.records_scanned,
                self.records_inserted,
                self.records_skipped,
                self.tombstones_skipped,
                self.current_level,
                rate,
            });
            self.last_log_time_ns = current_time_ns;
        }
    }

    /// Get completion percentage (based on estimated entries).
    pub fn get_completion_percent(self: *const RebuildProgress, estimated_total: u64) u8 {
        if (estimated_total == 0) return 100;
        const percent = (self.records_scanned * 100) / estimated_total;
        return @intCast(@min(percent, 100));
    }
};

/// Result of a full index rebuild.
pub const RebuildResult = struct {
    /// Number of entries inserted.
    entries_inserted: u64,
    /// Number of entries skipped (duplicates).
    entries_skipped: u64,
    /// Number of tombstones encountered.
    tombstones_encountered: u64,
    /// Duration in nanoseconds.
    duration_ns: u64,
    /// Recovery path used.
    recovery_path: RecoveryPath,
};

/// Full index rebuild from LSM storage (F2.2.6).
///
/// GDPR-CRITICAL: This function MUST process LSM levels in NEWEST-to-OLDEST order.
/// Failure to maintain this order is a CRITICAL security bug that violates GDPR
/// by potentially resurrecting deleted user data.
///
/// The rebuild uses the following strategy:
/// 1. Iterate LSM levels from L0 (newest) to L_max (oldest)
/// 2. For each GeoEvent encountered:
///    - If entity_id already in seen_entities: Skip (we have newer version)
///    - If tombstone: Mark seen but don't insert
///    - Else: Insert into RAM index, mark in seen_entities
/// 3. Progress logged every 1M records
///
/// Parameters:
/// - index: The RAM index to rebuild
/// - lsm_iterator: Iterator that yields GeoEvents from LSM, newest-to-oldest
/// - allocator: Allocator for temporary seen_entities bitset
/// - current_time_ns: Current timestamp for progress logging
///
/// Returns: RebuildResult with statistics
pub fn full_rebuild(
    comptime IndexType: type,
    index: *IndexType,
    lsm_iterator: anytype,
    allocator: Allocator,
    current_time_ns: u64,
) !RebuildResult {
    const GeoEvent = @import("../geo_event.zig").GeoEvent;

    // Allocate seen_entities bitset (~128MB for 1B entities)
    const SeenEntities = SeenEntitiesBitset(1_000_000_000);
    var seen = try SeenEntities.init(allocator);
    defer seen.deinit();

    var progress = RebuildProgress{
        .start_time_ns = current_time_ns,
    };

    log.info("Starting full index rebuild (F2.2.6)", .{});

    // GDPR-CRITICAL: Process LSM levels newest-to-oldest
    while (lsm_iterator.next()) |item| {
        const level = item.level;
        const event: *const GeoEvent = item.event;

        // Assert GDPR-critical ordering invariant
        progress.assert_level_order(level);
        progress.records_scanned += 1;

        // Check if we've already seen this entity (newer version exists)
        const is_first_occurrence = seen.mark_seen(event.entity_id);

        if (!is_first_occurrence) {
            // Already processed newer version, skip this older one
            progress.records_skipped += 1;
            continue;
        }

        // Check for tombstone (entity deleted)
        if (event.flags.deleted) {
            // Mark as seen but don't insert - entity was deleted
            progress.tombstones_skipped += 1;
            continue;
        }

        // Insert into RAM index
        const latest_id = @as(u128, event.timestamp) |
            (@as(u128, event.s2_cell_id) << 64);
        _ = index.upsert(event.entity_id, latest_id, event.ttl_seconds) catch |err| {
            log.err("Rebuild failed: upsert error: {}", .{err});
            return error.RebuildFailed;
        };
        progress.records_inserted += 1;

        // Log progress periodically
        progress.log_progress_if_needed(current_time_ns);
    }

    const duration_ns = current_time_ns - progress.start_time_ns;
    const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;

    log.info("Full index rebuild complete: inserted={} skipped={} tombstones={} " ++
        "duration={d:.1}s", .{
        progress.records_inserted,
        progress.records_skipped,
        progress.tombstones_skipped,
        duration_s,
    });

    return RebuildResult{
        .entries_inserted = progress.records_inserted,
        .entries_skipped = progress.records_skipped,
        .tombstones_encountered = progress.tombstones_skipped,
        .duration_ns = duration_ns,
        .recovery_path = .full_rebuild,
    };
}

/// Default seen entities bitset for 1B entities.
pub const DefaultSeenEntities = SeenEntitiesBitset(1_000_000_000);

// ============================================================================
// Unit Tests
// ============================================================================

test "CheckpointHeader: size and layout" {
    // CheckpointHeader must be exactly 256 bytes.
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(CheckpointHeader));
}

test "CheckpointHeader: validation" {
    var header = CheckpointHeader{};
    header.capacity = 1000;

    // Valid header
    try std.testing.expect(header.validate());

    // Invalid magic
    header.magic = 0x12345678;
    try std.testing.expect(!header.validate());
    header.magic = MAGIC;

    // Invalid version
    header.version = 0;
    try std.testing.expect(!header.validate());
    header.version = VERSION;

    // Zero capacity
    header.capacity = 0;
    try std.testing.expect(!header.validate());
}

test "DirtyPageTracker: mark and clear" {
    const allocator = std.testing.allocator;
    const page_size: u32 = 1024; // 1KB pages for testing
    const Tracker = DirtyPageTracker(page_size);

    var tracker = try Tracker.init(allocator, 10 * page_size);
    defer tracker.deinit(allocator);

    // Initially no dirty pages
    try std.testing.expectEqual(@as(u64, 0), tracker.get_dirty_count());

    // Mark first page dirty
    tracker.mark_dirty(0, 64);
    try std.testing.expectEqual(@as(u64, 1), tracker.get_dirty_count());
    try std.testing.expect(tracker.is_dirty(0));
    try std.testing.expect(!tracker.is_dirty(1));

    // Mark range spanning multiple pages
    tracker.mark_dirty(512, 1024); // Spans pages 0-1
    try std.testing.expectEqual(@as(u64, 2), tracker.get_dirty_count());
    try std.testing.expect(tracker.is_dirty(0));
    try std.testing.expect(tracker.is_dirty(1));

    // Clear one page
    tracker.clear_dirty(0);
    try std.testing.expectEqual(@as(u64, 1), tracker.get_dirty_count());
    try std.testing.expect(!tracker.is_dirty(0));
    try std.testing.expect(tracker.is_dirty(1));

    // Clear all
    tracker.clear_all();
    try std.testing.expectEqual(@as(u64, 0), tracker.get_dirty_count());
}

test "DirtyPageTracker: dirty iterator" {
    const allocator = std.testing.allocator;
    const page_size: u32 = 1024;
    const Tracker = DirtyPageTracker(page_size);

    var tracker = try Tracker.init(allocator, 10 * page_size);
    defer tracker.deinit(allocator);

    // Mark pages 1, 3, 7 dirty
    tracker.mark_page_dirty(1);
    tracker.mark_page_dirty(3);
    tracker.mark_page_dirty(7);

    // Iterate and collect
    var dirty_pages = std.ArrayList(u64).init(allocator);
    defer dirty_pages.deinit();

    var iter = tracker.dirty_iterator();
    while (iter.next()) |page| {
        try dirty_pages.append(page);
    }

    try std.testing.expectEqual(@as(usize, 3), dirty_pages.items.len);
    try std.testing.expectEqual(@as(u64, 1), dirty_pages.items[0]);
    try std.testing.expectEqual(@as(u64, 3), dirty_pages.items[1]);
    try std.testing.expectEqual(@as(u64, 7), dirty_pages.items[2]);
}

test "IndexCheckpoint: initialization" {
    const allocator = std.testing.allocator;

    var checkpoint = try DefaultIndexCheckpoint.init(allocator, "/tmp/test_checkpoint.dat", 1000);
    defer checkpoint.deinit();

    try std.testing.expectEqual(@as(u64, 1000), checkpoint.header.capacity);
    try std.testing.expectEqual(@as(u64, 0), checkpoint.get_dirty_count());
}

test "IndexCheckpoint: mark entry dirty" {
    const allocator = std.testing.allocator;

    var checkpoint = try DefaultIndexCheckpoint.init(allocator, "/tmp/test_checkpoint.dat", 1000);
    defer checkpoint.deinit();

    // Mark entries dirty
    checkpoint.mark_entry_dirty(0);
    checkpoint.mark_entry_dirty(100);
    checkpoint.mark_entry_dirty(999);

    try std.testing.expect(checkpoint.get_dirty_count() > 0);
}

test "SeenEntitiesBitset: basic operations (F2.2.6)" {
    const allocator = std.testing.allocator;

    // Use small bitset for testing
    const TestBitset = SeenEntitiesBitset(1000);
    var bitset = try TestBitset.init(allocator);
    defer bitset.deinit();

    // First occurrence should return true
    try std.testing.expect(bitset.mark_seen(12345));
    try std.testing.expectEqual(@as(u64, 1), bitset.get_seen_count());

    // Second occurrence of same ID should return false
    try std.testing.expect(!bitset.mark_seen(12345));
    try std.testing.expectEqual(@as(u64, 1), bitset.get_seen_count());

    // Different ID should return true
    try std.testing.expect(bitset.mark_seen(67890));
    try std.testing.expectEqual(@as(u64, 2), bitset.get_seen_count());

    // Check was_seen
    try std.testing.expect(bitset.was_seen(12345));
    try std.testing.expect(bitset.was_seen(67890));

    // Reset should clear everything
    bitset.reset();
    try std.testing.expectEqual(@as(u64, 0), bitset.get_seen_count());
    try std.testing.expect(!bitset.was_seen(12345));
}

test "RebuildProgress: GDPR-critical level ordering (F2.2.6)" {
    var progress = RebuildProgress{};

    // Levels should be processed in order: L0 (newest) → L_max (oldest)
    // LSM level numbers INCREASE from newest to oldest
    // This is GDPR-critical to prevent deleted entities from being resurrected
    progress.assert_level_order(0); // L0 (newest)
    progress.assert_level_order(0); // Still L0 (processing within level)
    progress.assert_level_order(1); // L1 (older) - level number increases
    progress.assert_level_order(2); // L2 (even older)
    progress.assert_level_order(2); // Still L2

    // Note: We can't easily test that assert_level_order panics on wrong order
    // since Zig's assert causes program termination. The assertion itself
    // documents the invariant in code.
}

test "RebuildProgress: completion percentage" {
    var progress = RebuildProgress{};

    progress.records_scanned = 0;
    try std.testing.expectEqual(@as(u8, 0), progress.get_completion_percent(100));

    progress.records_scanned = 50;
    try std.testing.expectEqual(@as(u8, 50), progress.get_completion_percent(100));

    progress.records_scanned = 100;
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(100));

    // Edge case: zero total
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(0));

    // Overflow protection
    progress.records_scanned = 200;
    try std.testing.expectEqual(@as(u8, 100), progress.get_completion_percent(100));
}

test "RebuildResult: struct layout" {
    const result = RebuildResult{
        .entries_inserted = 1000000,
        .entries_skipped = 50000,
        .tombstones_encountered = 10000,
        .duration_ns = 45_000_000_000, // 45 seconds
        .recovery_path = .full_rebuild,
    };

    try std.testing.expectEqual(@as(u64, 1000000), result.entries_inserted);
    try std.testing.expectEqual(RecoveryPath.full_rebuild, result.recovery_path);
}

// =============================================================================
// Recovery Decision Tests (F2.2.7)
// =============================================================================

test "RecoveryDecision: Case A - WAL replay when gap within journal slots" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000; // 2024-01-01 00:00:00

    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 5000, // Gap of 4000, within 8192
        .index_checkpoint_timestamp_ns = now_ns - 30 * std.time.ns_per_s, // 30s ago
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = false, // Doesn't matter for Case A
        .checkpoint_valid = true,
    };

    const decision = RecoveryDecision.decide(input, config);

    try std.testing.expectEqual(RecoveryPath.wal_replay, decision.path);
    try std.testing.expectEqual(@as(u64, 4000), decision.ops_to_replay);
    try std.testing.expect(!decision.should_alert);
    try std.testing.expectEqual(RecoverySLA.wal_replay_ns, decision.estimated_time_ns);
}

test "RecoveryDecision: Case B - LSM scan when gap exceeds WAL but LSM covers" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000;

    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 12000, // Gap of 11000, exceeds 8192
        .index_checkpoint_timestamp_ns = now_ns - 60 * std.time.ns_per_s,
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = true, // LSM tables available
        .checkpoint_valid = true,
    };

    const decision = RecoveryDecision.decide(input, config);

    try std.testing.expectEqual(RecoveryPath.lsm_scan, decision.path);
    try std.testing.expectEqual(@as(u64, 11000), decision.ops_to_replay);
    try std.testing.expect(!decision.should_alert); // Gap < 15,000
    try std.testing.expectEqual(RecoverySLA.lsm_scan_ns, decision.estimated_time_ns);
}

test "RecoveryDecision: Case B - LSM scan with warning when approaching limit" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000;

    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 18000, // Gap of 17000, exceeds 15,000 threshold
        .index_checkpoint_timestamp_ns = now_ns - 120 * std.time.ns_per_s,
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = true,
        .checkpoint_valid = true,
    };

    const decision = RecoveryDecision.decide(input, config);

    try std.testing.expectEqual(RecoveryPath.lsm_scan, decision.path);
    try std.testing.expect(decision.should_alert); // Gap > 15,000 triggers warning
}

test "RecoveryDecision: Case C - Full rebuild when LSM tables compacted" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000;

    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 25000, // Large gap
        .index_checkpoint_timestamp_ns = now_ns - 300 * std.time.ns_per_s,
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = false, // LSM tables were compacted away
        .checkpoint_valid = true,
    };

    const decision = RecoveryDecision.decide(input, config);

    try std.testing.expectEqual(RecoveryPath.full_rebuild, decision.path);
    try std.testing.expectEqual(@as(u64, 0), decision.ops_to_replay);
    try std.testing.expect(decision.should_alert);
}

test "RecoveryDecision: Case D - Full rebuild on stale checkpoint" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000;

    // Checkpoint is 8 days old (exceeds 7 day threshold)
    const eight_days_ns = 8 * 24 * 60 * 60 * std.time.ns_per_s;
    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 2000, // Small gap, would be Case A normally
        .index_checkpoint_timestamp_ns = now_ns - eight_days_ns,
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = true,
        .checkpoint_valid = true,
    };

    const decision = RecoveryDecision.decide(input, config);

    // Stale checkpoint forces rebuild even with small gap
    try std.testing.expectEqual(RecoveryPath.full_rebuild, decision.path);
    try std.testing.expect(decision.should_alert);
    try std.testing.expect(std.mem.indexOf(u8, decision.reason, "stale") != null);
}

test "RecoveryDecision: Case D - Full rebuild on invalid checkpoint" {
    const config = RecoveryConfig{};
    const now_ns: u64 = 1704067200_000_000_000;

    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 2000,
        .index_checkpoint_timestamp_ns = now_ns - 30 * std.time.ns_per_s,
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = true,
        .checkpoint_valid = false, // Checksum failed
    };

    const decision = RecoveryDecision.decide(input, config);

    try std.testing.expectEqual(RecoveryPath.full_rebuild, decision.path);
    try std.testing.expect(decision.should_alert);
    try std.testing.expect(std.mem.indexOf(u8, decision.reason, "invalid") != null);
}

test "RecoveryInput: op_gap calculation" {
    const input = RecoveryInput{
        .index_checkpoint_op = 1000,
        .vsr_checkpoint_op = 5000,
        .index_checkpoint_timestamp_ns = 0,
        .current_timestamp_ns = 0,
        .lsm_covers_gap = false,
        .checkpoint_valid = true,
    };

    try std.testing.expectEqual(@as(u64, 4000), input.op_gap());
}

test "RecoveryInput: checkpoint_age_seconds calculation" {
    const now_ns: u64 = 1704067200_000_000_000;
    const input = RecoveryInput{
        .index_checkpoint_op = 0,
        .vsr_checkpoint_op = 0,
        .index_checkpoint_timestamp_ns = now_ns - 120 * std.time.ns_per_s, // 2 min ago
        .current_timestamp_ns = now_ns,
        .lsm_covers_gap = false,
        .checkpoint_valid = true,
    };

    try std.testing.expectEqual(@as(u64, 120), input.checkpoint_age_seconds());
}

test "RecoveryConfig: custom journal slots" {
    const config = RecoveryConfig.with_journal_slots(16384);
    try std.testing.expectEqual(@as(u64, 16384), config.journal_slot_count);
    try std.testing.expectEqual(@as(u64, 20_000), config.compaction_retention_ops);
}

test "RecoveryPath: to_label conversion" {
    try std.testing.expectEqualStrings("wal", RecoveryPath.wal_replay.to_label());
    try std.testing.expectEqualStrings("lsm", RecoveryPath.lsm_scan.to_label());
    try std.testing.expectEqualStrings("rebuild", RecoveryPath.full_rebuild.to_label());
    try std.testing.expectEqualStrings("clean", RecoveryPath.clean_start.to_label());
    try std.testing.expectEqualStrings("none", RecoveryPath.none.to_label());
}

test "RecoverySLA: thresholds are sensible" {
    // WAL replay should be fastest
    try std.testing.expect(RecoverySLA.wal_replay_ns < RecoverySLA.lsm_scan_ns);
    // LSM scan should be faster than full rebuild
    try std.testing.expect(RecoverySLA.lsm_scan_ns < RecoverySLA.rebuild_small_ns);
    // Small rebuild should be faster than large
    try std.testing.expect(RecoverySLA.rebuild_small_ns < RecoverySLA.rebuild_large_ns);
}

test "RecoveryAlertThresholds: ordering" {
    // Warning should trigger before critical
    try std.testing.expect(
        RecoveryAlertThresholds.warning_age_seconds < RecoveryAlertThresholds.critical_age_seconds,
    );
}

// =============================================================================
// Recovery Metrics Tests (F2.2.9)
// =============================================================================

test "RecoveryMetrics: record_recovery increments counters" {
    var metrics = RecoveryMetrics{};

    // Record WAL recovery
    metrics.record_recovery(.wal_replay, 500_000_000); // 0.5s
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_wal_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.recovery_lsm_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.recovery_rebuild_count);

    // Record LSM recovery
    metrics.record_recovery(.lsm_scan, 15_000_000_000); // 15s
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_wal_count);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_lsm_count);

    // Record rebuild recovery
    metrics.record_recovery(.full_rebuild, 120_000_000_000); // 120s
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_rebuild_count);

    // Total count
    try std.testing.expectEqual(@as(u64, 3), metrics.recovery_duration_count);
}

test "RecoveryMetrics: histogram buckets" {
    var metrics = RecoveryMetrics{};

    // Under 1s
    metrics.record_recovery(.wal_replay, 500_000_000);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_duration_bucket_1s);

    // Between 5-10s
    metrics.record_recovery(.lsm_scan, 7_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_duration_bucket_10s);

    // Between 30-60s
    metrics.record_recovery(.lsm_scan, 45_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_duration_bucket_60s);

    // Between 60-120s
    metrics.record_recovery(.full_rebuild, 90_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_duration_bucket_120s);

    // Over 7200s (2 hours)
    metrics.record_recovery(.full_rebuild, 8000_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), metrics.recovery_duration_bucket_inf);
}

test "RecoveryMetrics: get_recovery_count" {
    var metrics = RecoveryMetrics{};

    metrics.record_recovery(.wal_replay, 100_000_000);
    metrics.record_recovery(.wal_replay, 200_000_000);
    metrics.record_recovery(.lsm_scan, 5_000_000_000);
    metrics.record_recovery(.clean_start, 10_000_000);

    try std.testing.expectEqual(@as(u64, 2), metrics.get_recovery_count(.wal_replay));
    try std.testing.expectEqual(@as(u64, 1), metrics.get_recovery_count(.lsm_scan));
    try std.testing.expectEqual(@as(u64, 0), metrics.get_recovery_count(.full_rebuild));
    try std.testing.expectEqual(@as(u64, 1), metrics.get_recovery_count(.clean_start));
}

test "RecoveryMetrics: average duration" {
    var metrics = RecoveryMetrics{};

    // No recoveries yet
    try std.testing.expectEqual(@as(u64, 0), metrics.get_avg_recovery_duration_ns());

    // Add two recoveries: 1s and 3s
    metrics.record_recovery(.wal_replay, 1_000_000_000);
    metrics.record_recovery(.wal_replay, 3_000_000_000);

    // Average should be 2s
    try std.testing.expectEqual(@as(u64, 2_000_000_000), metrics.get_avg_recovery_duration_ns());
}

test "checkpoint_lag_ops: basic calculation" {
    var stats = CheckpointStats{};
    stats.last_checkpoint_op = 1000;
    stats.last_vsr_checkpoint_op = 5000;

    try std.testing.expectEqual(@as(u64, 4000), checkpoint_lag_ops(&stats));
}

test "checkpoint_lag_ops: saturating subtraction" {
    var stats = CheckpointStats{};
    stats.last_checkpoint_op = 5000;
    stats.last_vsr_checkpoint_op = 1000; // Unusual case: index ahead of VSR

    // Should saturate to 0, not wrap around
    try std.testing.expectEqual(@as(u64, 0), checkpoint_lag_ops(&stats));
}

test "is_checkpoint_lag_critical: threshold check" {
    var stats = CheckpointStats{};

    // Under threshold
    stats.last_checkpoint_op = 1000;
    stats.last_vsr_checkpoint_op = 10000; // Gap of 9000
    try std.testing.expect(!is_checkpoint_lag_critical(&stats));

    // Over threshold
    stats.last_vsr_checkpoint_op = 20000; // Gap of 19000
    try std.testing.expect(is_checkpoint_lag_critical(&stats));
}
