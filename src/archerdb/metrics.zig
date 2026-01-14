// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Metrics collection primitives for Prometheus-compatible observability.
//!
//! Provides:
//! - Counter: monotonically increasing values
//! - Gauge: values that can go up or down
//! - Histogram: distribution of values across configurable buckets
//!
//! All types are thread-safe using atomic operations for lock-free access.

const std = @import("std");

/// A monotonically increasing counter metric.
/// Thread-safe via atomic operations.
pub const Counter = struct {
    value: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,

    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Counter {
        return .{
            .value = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
            .labels = labels,
        };
    }

    /// Increment the counter by 1.
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Add a value to the counter.
    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Get the current value.
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }

    /// Format as Prometheus text format.
    pub fn format(self: *const Counter, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} counter\n", .{self.name});
        if (self.labels) |labels| {
            try writer.print("{s}{{{s}}} {d}\n", .{ self.name, labels, self.get() });
        } else {
            try writer.print("{s} {d}\n", .{ self.name, self.get() });
        }
    }
};

/// A gauge metric that can go up or down.
/// Thread-safe via atomic operations.
pub const Gauge = struct {
    // Use i64 to allow negative values for gauges
    value: std.atomic.Value(i64),
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,

    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Gauge {
        return .{
            .value = std.atomic.Value(i64).init(0),
            .name = name,
            .help = help,
            .labels = labels,
        };
    }

    /// Set the gauge to a specific value.
    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }

    /// Increment the gauge by 1.
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Decrement the gauge by 1.
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    /// Add a value to the gauge.
    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Get the current value.
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }

    /// Format as Prometheus text format.
    pub fn format(self: *const Gauge, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} gauge\n", .{self.name});
        if (self.labels) |labels| {
            try writer.print("{s}{{{s}}} {d}\n", .{ self.name, labels, self.get() });
        } else {
            try writer.print("{s} {d}\n", .{ self.name, self.get() });
        }
    }
};

/// A histogram metric for tracking value distributions.
/// Thread-safe via atomic operations.
/// Configurable bucket boundaries at compile time.
pub fn HistogramType(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count]std.atomic.Value(u64),
        bucket_bounds: [bucket_count]f64,
        sum: std.atomic.Value(u64), // Store as fixed-point (nanoseconds for latency)
        count: std.atomic.Value(u64),
        name: []const u8,
        help: []const u8,
        labels: ?[]const u8,

        /// Initialize with the given bucket boundaries.
        /// Boundaries should be in ascending order (e.g., 0.001, 0.005, 0.01, 0.05, 0.1).
        pub fn init(
            name: []const u8,
            help: []const u8,
            labels: ?[]const u8,
            bounds: [bucket_count]f64,
        ) @This() {
            var buckets: [bucket_count]std.atomic.Value(u64) = undefined;
            for (&buckets) |*b| {
                b.* = std.atomic.Value(u64).init(0);
            }
            return .{
                .buckets = buckets,
                .bucket_bounds = bounds,
                .sum = std.atomic.Value(u64).init(0),
                .count = std.atomic.Value(u64).init(0),
                .name = name,
                .help = help,
                .labels = labels,
            };
        }

        /// Observe a value (e.g., latency in seconds).
        pub fn observe(self: *@This(), value: f64) void {
            // Increment count
            _ = self.count.fetchAdd(1, .monotonic);

            // Add to sum (convert to nanoseconds for precision)
            const value_ns: u64 = @intFromFloat(value * 1e9);
            _ = self.sum.fetchAdd(value_ns, .monotonic);

            // Find and increment appropriate bucket
            for (self.bucket_bounds, 0..) |bound, i| {
                if (value <= bound) {
                    _ = self.buckets[i].fetchAdd(1, .monotonic);
                    break;
                }
            }
        }

        /// Observe a duration in nanoseconds (more efficient for timing).
        pub fn observeNs(self: *@This(), value_ns: u64) void {
            _ = self.count.fetchAdd(1, .monotonic);
            _ = self.sum.fetchAdd(value_ns, .monotonic);

            const value: f64 = @as(f64, @floatFromInt(value_ns)) / 1e9;
            for (self.bucket_bounds, 0..) |bound, i| {
                if (value <= bound) {
                    _ = self.buckets[i].fetchAdd(1, .monotonic);
                    break;
                }
            }
        }

        /// Get the current count.
        pub fn getCount(self: *const @This()) u64 {
            return self.count.load(.monotonic);
        }

        /// Get the current sum in seconds.
        pub fn getSum(self: *const @This()) f64 {
            return @as(f64, @floatFromInt(self.sum.load(.monotonic))) / 1e9;
        }

        /// Format as Prometheus text format.
        pub fn format(self: *const @This(), writer: anytype) !void {
            try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
            try writer.print("# TYPE {s} histogram\n", .{self.name});

            const label_prefix = if (self.labels) |labels| labels else "";
            const label_sep = if (self.labels != null) "," else "";

            // Cumulative bucket counts
            var cumulative: u64 = 0;
            for (self.bucket_bounds, 0..) |bound, i| {
                cumulative += self.buckets[i].load(.monotonic);
                if (self.labels != null) {
                    try writer.print("{s}_bucket{{{s}{s}le=\"{d:.6}\"}} {d}\n", .{
                        self.name,
                        label_prefix,
                        label_sep,
                        bound,
                        cumulative,
                    });
                } else {
                    try writer.print("{s}_bucket{{le=\"{d:.6}\"}} {d}\n", .{
                        self.name,
                        bound,
                        cumulative,
                    });
                }
            }

            // +Inf bucket (total count)
            if (self.labels != null) {
                try writer.print("{s}_bucket{{{s}{s}le=\"+Inf\"}} {d}\n", .{
                    self.name,
                    label_prefix,
                    label_sep,
                    self.count.load(.monotonic),
                });
            } else {
                try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{
                    self.name,
                    self.count.load(.monotonic),
                });
            }

            // Sum
            if (self.labels != null) {
                try writer.print("{s}_sum{{{s}}} {d:.6}\n", .{
                    self.name,
                    label_prefix,
                    self.getSum(),
                });
            } else {
                try writer.print("{s}_sum {d:.6}\n", .{ self.name, self.getSum() });
            }

            // Count
            if (self.labels != null) {
                try writer.print("{s}_count{{{s}}} {d}\n", .{
                    self.name,
                    label_prefix,
                    self.count.load(.monotonic),
                });
            } else {
                try writer.print("{s}_count {d}\n", .{ self.name, self.count.load(.monotonic) });
            }
        }
    };
}

/// Standard latency histogram with common bucket boundaries.
/// Buckets: 500μs, 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s
pub const LatencyHistogram = HistogramType(9);

/// Create a standard latency histogram.
pub fn latencyHistogram(name: []const u8, help: []const u8, labels: ?[]const u8) LatencyHistogram {
    return LatencyHistogram.init(name, help, labels, .{
        0.0005, // 500μs
        0.001, // 1ms
        0.005, // 5ms
        0.01, // 10ms
        0.05, // 50ms
        0.1, // 100ms
        0.5, // 500ms
        1.0, // 1s
        5.0, // 5s
    });
}

/// Global metrics registry.
/// All metrics are statically defined for zero allocation at runtime.
pub const Registry = struct {
    // Build info
    pub var info: Gauge = Gauge.init(
        "archerdb_info",
        "ArcherDB build information",
        "version=\"0.0.1\"",
    );

    // Health status
    pub var health_ready: Gauge = Gauge.init(
        "archerdb_health_status",
        "Current health status (1 = ready)",
        "status=\"ready\"",
    );

    // Write metrics
    pub var write_operations_total: Counter = Counter.init(
        "archerdb_write_operations_total",
        "Total write operations processed",
        null,
    );

    pub var write_events_total: Counter = Counter.init(
        "archerdb_write_events_total",
        "Total GeoEvents written",
        null,
    );

    pub var write_bytes_total: Counter = Counter.init(
        "archerdb_write_bytes_total",
        "Total bytes written to data file",
        null,
    );

    pub var write_latency: LatencyHistogram = latencyHistogram(
        "archerdb_write_latency_seconds",
        "Write operation latency histogram",
        null,
    );

    // Per-operation write metrics (observability/spec.md requirement)
    pub var write_ops_insert: Counter = Counter.init(
        "archerdb_write_operations_total",
        "Total write operations processed",
        "operation=\"insert\"",
    );

    pub var write_ops_upsert: Counter = Counter.init(
        "archerdb_write_operations_total",
        "Total write operations processed",
        "operation=\"upsert\"",
    );

    pub var write_ops_delete: Counter = Counter.init(
        "archerdb_write_operations_total",
        "Total write operations processed",
        "operation=\"delete\"",
    );

    pub var write_errors_total: Counter = Counter.init(
        "archerdb_write_errors_total",
        "Total write errors",
        null,
    );

    // Delete metrics (F2.5.5 - GDPR entity deletion)
    pub var delete_operations_total: Counter = Counter.init(
        "archerdb_delete_operations_total",
        "Total delete operations processed",
        null,
    );

    pub var delete_entities_total: Counter = Counter.init(
        "archerdb_delete_entities_total",
        "Total entities deleted",
        null,
    );

    pub var delete_errors_total: Counter = Counter.init(
        "archerdb_delete_errors_total",
        "Total delete errors",
        null,
    );

    pub var delete_latency: LatencyHistogram = latencyHistogram(
        "archerdb_delete_latency_seconds",
        "Delete operation latency histogram",
        null,
    );

    // Read metrics
    pub var read_operations_total: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        null,
    );

    // Per-operation read metrics (observability/spec.md requirement)
    pub var read_ops_query_uuid: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        "operation=\"query_uuid\"",
    );

    pub var read_ops_query_radius: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        "operation=\"query_radius\"",
    );

    pub var read_ops_query_polygon: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        "operation=\"query_polygon\"",
    );

    pub var read_ops_query_latest: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        "operation=\"query_latest\"",
    );

    pub var read_events_returned_total: Counter = Counter.init(
        "archerdb_read_events_returned_total",
        "Total GeoEvents returned from queries",
        null,
    );

    pub var read_latency: LatencyHistogram = latencyHistogram(
        "archerdb_read_latency_seconds",
        "Read operation latency histogram",
        null,
    );

    // Index metrics
    pub var index_lookups_total: Counter = Counter.init(
        "archerdb_index_lookups_total",
        "Primary index lookup count",
        null,
    );

    pub var index_lookup_latency: LatencyHistogram = latencyHistogram(
        "archerdb_index_lookup_latency_seconds",
        "Index lookup latency",
        null,
    );

    // Index capacity and health metrics (F5.2 - Observability)
    pub var index_capacity_warning_total: Counter = Counter.init(
        "archerdb_index_capacity_warning_total",
        "Index capacity warnings (80% threshold)",
        null,
    );

    pub var index_capacity_critical_total: Counter = Counter.init(
        "archerdb_index_capacity_critical_total",
        "Index capacity critical alerts (90% threshold)",
        null,
    );

    pub var index_capacity_emergency_total: Counter = Counter.init(
        "archerdb_index_capacity_emergency_total",
        "Index capacity emergency alerts (95% threshold)",
        null,
    );

    pub var index_tombstone_ratio: Gauge = Gauge.init(
        "archerdb_index_tombstone_ratio",
        "Current tombstone ratio in RAM index (percentage * 100)",
        null,
    );

    // NOTE: index_load_factor already defined below in existing metrics section

    // Query result size distribution (F5.2 - Observability)
    // Buckets: 1, 10, 100, 500, 1000, 5000, 10000, 50000, 100000 events
    pub const QueryResultSizeHistogram = HistogramType(9);
    pub var query_result_size: QueryResultSizeHistogram = QueryResultSizeHistogram.init(
        "archerdb_query_result_events",
        "Distribution of query result set sizes",
        null,
        .{ 1, 10, 100, 500, 1000, 5000, 10000, 50000, 100000 },
    );

    // I/O latency monitoring (F5.2 - Observability)
    pub var io_latency_exceeded_total: Counter = Counter.init(
        "archerdb_io_latency_exceeded_total",
        "I/O operations exceeding latency threshold (p99 > 100us)",
        null,
    );

    // Connection metrics
    pub var active_connections: Gauge = Gauge.init(
        "archerdb_active_connections",
        "Number of active client connections",
        null,
    );

    // VSR (ViewStamped Replication) metrics (F5.2.2 - Observability)
    pub var vsr_view: Gauge = Gauge.init(
        "archerdb_vsr_view",
        "Current VSR view number",
        null,
    );

    pub var vsr_status: Gauge = Gauge.init(
        "archerdb_vsr_status",
        "Replica status (0=normal, 1=view_change, 2=recovering)",
        null,
    );

    pub var vsr_is_primary: Gauge = Gauge.init(
        "archerdb_vsr_is_primary",
        "Whether this replica is the primary (1=yes, 0=no)",
        null,
    );

    pub var vsr_op_number: Gauge = Gauge.init(
        "archerdb_vsr_op_number",
        "Highest committed operation number",
        null,
    );

    pub var vsr_view_changes_total: Counter = Counter.init(
        "archerdb_vsr_view_changes_total",
        "Total view changes",
        null,
    );

    // Resource metrics (F5.2 - Observability: memory, disk, I/O)
    pub var memory_allocated_bytes: Gauge = Gauge.init(
        "archerdb_memory_allocated_bytes",
        "Total memory allocated by the process",
        null,
    );

    pub var memory_used_bytes: Gauge = Gauge.init(
        "archerdb_memory_used_bytes",
        "Memory currently in use (allocated - freed)",
        null,
    );

    pub var data_file_size_bytes: Gauge = Gauge.init(
        "archerdb_data_file_size_bytes",
        "Data file size in bytes",
        null,
    );

    pub var index_entries: Gauge = Gauge.init(
        "archerdb_index_entries",
        "Current entity count in primary index",
        null,
    );

    pub var index_capacity: Gauge = Gauge.init(
        "archerdb_index_capacity",
        "Maximum index capacity",
        null,
    );

    // I/O metrics
    pub var disk_reads_total: Counter = Counter.init(
        "archerdb_disk_reads_total",
        "Total disk read operations",
        null,
    );

    pub var disk_writes_total: Counter = Counter.init(
        "archerdb_disk_writes_total",
        "Total disk write operations",
        null,
    );

    pub var disk_read_bytes_total: Counter = Counter.init(
        "archerdb_disk_read_bytes_total",
        "Total bytes read from disk",
        null,
    );

    pub var disk_write_bytes_total: Counter = Counter.init(
        "archerdb_disk_write_bytes_total",
        "Total bytes written to disk",
        null,
    );

    // Disk I/O latency histograms
    pub var disk_read_latency: LatencyHistogram = latencyHistogram(
        "archerdb_disk_read_latency_seconds",
        "Disk read latency histogram",
        null,
    );

    pub var disk_write_latency: LatencyHistogram = latencyHistogram(
        "archerdb_disk_write_latency_seconds",
        "Disk write latency histogram",
        null,
    );

    // Index load factor (derived: entries / capacity)
    pub var index_load_factor: Gauge = Gauge.init(
        "archerdb_index_load_factor",
        "Index load factor (entries / capacity, 0.0 to 1.0 scaled by 1000)",
        null,
    );

    // LSM metrics (F5.2 - Observability)
    // Per-level compaction counts (max 6 levels)
    pub var lsm_compactions_per_level: [6]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    // Per-level bytes moved during compaction
    pub var lsm_compaction_bytes_per_level: [6]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    pub var lsm_compaction_latency: LatencyHistogram = latencyHistogram(
        "archerdb_lsm_compaction_latency_seconds",
        "Compaction duration histogram",
        null,
    );

    // Per-level table counts (max 6 levels, updated via updateLsmMetrics)
    // Formatted with labels in format()
    pub var lsm_tables_per_level: [6]std.atomic.Value(u32) = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
    };

    // Per-level size in bytes
    pub var lsm_level_size_bytes: [6]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    // User bytes written (for write amplification calculation)
    pub var lsm_user_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Total disk bytes written by LSM (includes compaction)
    pub var lsm_disk_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Grid cache metrics (F5.2 - Observability)
    pub var grid_cache_hits_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var grid_cache_misses_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var grid_blocks_acquired: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var grid_blocks_missing: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var grid_cache_blocks_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Journal/WAL metrics (F5.2 - Observability)
    pub var journal_dirty_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var journal_faulty_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Free set metrics (F5.2 - Observability)
    pub var free_set_blocks_free: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var free_set_blocks_reserved: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var free_set_total_blocks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Free set exhaustion thresholds (storage-engine/spec.md)
    // - 10% free: Warning threshold
    // - 5% free: Critical threshold (reject writes)
    // - 2% free: Emergency threshold (force compaction)
    pub var free_set_low_warning_total: Counter = Counter.init(
        "archerdb_free_set_low_warning_total",
        "Free set below 10% - warning threshold exceeded",
        null,
    );

    pub var free_set_critical_total: Counter = Counter.init(
        "archerdb_free_set_critical_total",
        "Free set below 5% - writes suspended",
        null,
    );

    pub var free_set_emergency_total: Counter = Counter.init(
        "archerdb_free_set_emergency_total",
        "Free set below 2% - emergency compaction triggered",
        null,
    );

    // Backup metrics (F5.5.6 - Observability)
    // See backup-restore/spec.md for metric definitions
    pub var backup_blocks_uploaded_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_lag_blocks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_failures_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_last_success_timestamp: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_rpo_current_seconds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_blocks_abandoned_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var backup_mandatory_bypass_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Backup upload latency histogram (buckets: 100ms, 500ms, 1s, 5s, 10s, 30s, 60s)
    pub var backup_upload_latency: LatencyHistogram = latencyHistogram(
        "archerdb_backup_upload_latency_seconds",
        "Backup upload latency histogram",
        null,
    );

    // Replication lag metrics (F5.1.6 - Observability)
    // Per-replica replication lag tracking (max 6 replicas as per constants.replicas_max)
    pub const max_replicas: usize = 6;

    /// Replication lag in operations per replica.
    /// Tracked from the primary's perspective: commit_max - replica's commit_min.
    pub var vsr_replication_lag_ops: [max_replicas]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    /// Replication lag in nanoseconds per replica.
    /// Derived from operation lag and average operation rate.
    pub var vsr_replication_lag_ns: [max_replicas]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    /// Number of active replicas in the cluster.
    pub var vsr_replica_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// This replica's index in the cluster.
    pub var vsr_replica_index: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    // ========================================================================
    // v2.0 Multi-Region Replication Metrics
    // See openspec/changes/add-v2-distributed-features/specs/replication/spec.md
    // ========================================================================

    /// Maximum number of follower regions per primary
    pub const max_followers: usize = 16;

    /// Region role (0=primary, 1=follower)
    pub var region_role: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Region identifier
    pub var region_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Ship queue depth per follower region
    pub var replication_ship_queue_depth: [max_followers]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Total bytes shipped per follower region
    pub var replication_ship_bytes_total: [max_followers]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Ship failures per follower region
    pub var replication_ship_failures_total: [max_followers]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Last ship latency in nanoseconds per follower
    pub var replication_ship_latency_ns: [max_followers]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Replication lag in operations (follower perspective)
    pub var replication_lag_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Replication lag in nanoseconds (follower perspective)
    pub var replication_lag_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// WAL entries applied per second (follower perspective)
    pub var replication_apply_rate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Region availability status (1=available, 0=unavailable)
    pub var region_available: std.atomic.Value(u8) = std.atomic.Value(u8).init(1);

    // ========================================================================
    // v2.0 Sharding Metrics
    // See openspec/changes/add-v2-distributed-features/specs/index-sharding/spec.md
    // ========================================================================

    /// Maximum number of shards
    pub const max_shards: usize = 256;

    /// Number of active shards
    pub var shard_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

    /// Entities per shard (approximate)
    pub var shard_entity_count: [max_shards]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_shards;

    /// Resharding status (0=idle, 1=preparing, 2=migrating, 3=finalizing)
    pub var resharding_status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Resharding progress (0.0 to 1.0, stored as fixed-point * 1000)
    pub var resharding_progress: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Entities exported during resharding
    pub var resharding_entities_exported: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Entities imported during resharding
    pub var resharding_entities_imported: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Source shard count before resharding
    pub var resharding_source_shards: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Target shard count for resharding
    pub var resharding_target_shards: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Resharding start timestamp (nanoseconds since epoch)
    pub var resharding_start_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Resharding duration (nanoseconds, updated on completion)
    pub var resharding_duration_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Scatter-gather queries total
    pub var scatter_gather_queries_total: Counter = Counter.init(
        "archerdb_scatter_gather_queries_total",
        "Total scatter-gather queries across shards",
        null,
    );

    // ========================================================================
    // v2.0 Encryption Metrics
    // See openspec/changes/add-v2-distributed-features/specs/security/spec.md
    // ========================================================================

    /// Total encryption operations
    pub var encryption_ops_total: Counter = Counter.init(
        "archerdb_encryption_operations_total",
        "Total encryption operations",
        "op=\"encrypt\"",
    );

    /// Total decryption operations
    pub var decryption_ops_total: Counter = Counter.init(
        "archerdb_encryption_operations_total",
        "Total decryption operations",
        "op=\"decrypt\"",
    );

    /// Key cache hits
    pub var encryption_cache_hits_total: Counter = Counter.init(
        "archerdb_encryption_key_cache_hits_total",
        "Encryption key cache hits",
        null,
    );

    /// Key cache misses
    pub var encryption_cache_misses_total: Counter = Counter.init(
        "archerdb_encryption_key_cache_misses_total",
        "Encryption key cache misses",
        null,
    );

    /// Decryption failures (auth tag mismatch)
    pub var encryption_failures_total: Counter = Counter.init(
        "archerdb_encryption_failures_total",
        "Encryption/decryption failures",
        "reason=\"auth_tag_mismatch\"",
    );

    /// Key rotation status (0=idle, 1=rotating)
    pub var encryption_rotation_status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Key rotation progress (0.0 to 1.0, stored as fixed-point * 1000)
    pub var encryption_rotation_progress: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Format all metrics as Prometheus text format.
    pub fn format(writer: anytype) !void {
        // Set info gauge to 1 (it's always present)
        info.set(1);

        try info.format(writer);
        try writer.writeAll("\n");

        try health_ready.format(writer);
        try writer.writeAll("\n");

        try write_operations_total.format(writer);
        try write_events_total.format(writer);
        try write_bytes_total.format(writer);
        try write_latency.format(writer);
        // Per-operation write metrics
        try write_ops_insert.format(writer);
        try write_ops_upsert.format(writer);
        try write_ops_delete.format(writer);
        try write_errors_total.format(writer);
        try writer.writeAll("\n");

        // Delete metrics (GDPR entity deletion)
        try delete_operations_total.format(writer);
        try delete_entities_total.format(writer);
        try delete_errors_total.format(writer);
        try delete_latency.format(writer);
        try writer.writeAll("\n");

        try read_operations_total.format(writer);
        try read_events_returned_total.format(writer);
        try read_latency.format(writer);
        // Per-operation read metrics
        try read_ops_query_uuid.format(writer);
        try read_ops_query_radius.format(writer);
        try read_ops_query_polygon.format(writer);
        try read_ops_query_latest.format(writer);
        try writer.writeAll("\n");

        try index_lookups_total.format(writer);
        try index_lookup_latency.format(writer);
        try writer.writeAll("\n");

        // Index capacity and health metrics
        try index_capacity_warning_total.format(writer);
        try index_capacity_critical_total.format(writer);
        try index_capacity_emergency_total.format(writer);
        try index_tombstone_ratio.format(writer);
        try writer.writeAll("\n");

        // Query result size distribution
        try query_result_size.format(writer);
        try writer.writeAll("\n");

        // I/O latency monitoring
        try io_latency_exceeded_total.format(writer);
        try writer.writeAll("\n");

        try active_connections.format(writer);
        try writer.writeAll("\n");

        try write_errors_total.format(writer);
        try writer.writeAll("\n");

        // VSR metrics
        try vsr_view.format(writer);
        try vsr_status.format(writer);
        try vsr_is_primary.format(writer);
        try vsr_op_number.format(writer);
        try vsr_view_changes_total.format(writer);
        try writer.writeAll("\n");

        // VSR replication lag metrics (F5.1.6)
        const replica_count = vsr_replica_count.load(.monotonic);
        if (replica_count > 0) {
            try writer.writeAll("# HELP archerdb_vsr_replication_lag_ops " ++
                "Replication lag in operations per replica\n");
            try writer.writeAll("# TYPE archerdb_vsr_replication_lag_ops gauge\n");
            for (0..replica_count) |i| {
                const lag = vsr_replication_lag_ops[i].load(.monotonic);
                try writer.print(
                    "archerdb_vsr_replication_lag_ops{{replica=\"replica-{d}\"}} {d}\n",
                    .{ i, lag },
                );
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_vsr_replication_lag_seconds " ++
                "Replication lag in seconds per replica\n");
            try writer.writeAll("# TYPE archerdb_vsr_replication_lag_seconds gauge\n");
            for (0..replica_count) |i| {
                const lag_ns = vsr_replication_lag_ns[i].load(.monotonic);
                const lag_sec: f64 = @as(f64, @floatFromInt(lag_ns)) / 1e9;
                try writer.print(
                    "archerdb_vsr_replication_lag_seconds{{replica=\"replica-{d}\"}} {d:.6}\n",
                    .{ i, lag_sec },
                );
            }
            try writer.writeAll("\n");
        }

        // Resource metrics
        try memory_allocated_bytes.format(writer);
        try memory_used_bytes.format(writer);
        try data_file_size_bytes.format(writer);
        try index_entries.format(writer);
        try index_capacity.format(writer);
        try writer.writeAll("\n");

        // I/O metrics
        try disk_reads_total.format(writer);
        try disk_writes_total.format(writer);
        try disk_read_bytes_total.format(writer);
        try disk_write_bytes_total.format(writer);
        try disk_read_latency.format(writer);
        try disk_write_latency.format(writer);
        try writer.writeAll("\n");

        // Index load factor
        try index_load_factor.format(writer);
        try writer.writeAll("\n");

        // LSM metrics - per-level compactions
        try writer.writeAll(
            "# HELP archerdb_lsm_compactions_total Total compactions per level\n",
        );
        try writer.writeAll("# TYPE archerdb_lsm_compactions_total counter\n");
        for (lsm_compactions_per_level, 0..) |count, level| {
            try writer.print("archerdb_lsm_compactions_total{{level=\"{d}\"}} {d}\n", .{
                level,
                count.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Per-level bytes moved during compaction
        try writer.writeAll(
            "# HELP archerdb_lsm_compaction_bytes_moved_total Bytes moved per level\n",
        );
        try writer.writeAll("# TYPE archerdb_lsm_compaction_bytes_moved_total counter\n");
        for (lsm_compaction_bytes_per_level, 0..) |bytes, level| {
            try writer.print("archerdb_lsm_compaction_bytes_moved_total{{level=\"{d}\"}} {d}\n", .{
                level,
                bytes.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Compaction latency histogram
        try lsm_compaction_latency.format(writer);
        try writer.writeAll("\n");

        // Per-level table counts
        try writer.writeAll(
            "# HELP archerdb_lsm_tables_count Current table count per level\n",
        );
        try writer.writeAll("# TYPE archerdb_lsm_tables_count gauge\n");
        for (lsm_tables_per_level, 0..) |count, level| {
            try writer.print("archerdb_lsm_tables_count{{level=\"{d}\"}} {d}\n", .{
                level,
                count.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Per-level size bytes
        try writer.writeAll(
            "# HELP archerdb_lsm_level_size_bytes Size of each LSM level\n",
        );
        try writer.writeAll("# TYPE archerdb_lsm_level_size_bytes gauge\n");
        for (lsm_level_size_bytes, 0..) |size, level| {
            try writer.print("archerdb_lsm_level_size_bytes{{level=\"{d}\"}} {d}\n", .{
                level,
                size.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Write amplification ratio
        const user_bytes = lsm_user_bytes_written.load(.monotonic);
        const disk_bytes = lsm_disk_bytes_written.load(.monotonic);
        try writer.writeAll(
            "# HELP archerdb_lsm_write_amplification_ratio disk_bytes/user_bytes\n",
        );
        try writer.writeAll("# TYPE archerdb_lsm_write_amplification_ratio gauge\n");
        if (user_bytes > 0) {
            const disk_f: f64 = @floatFromInt(disk_bytes);
            const user_f: f64 = @floatFromInt(user_bytes);
            const ratio: f64 = disk_f / user_f;
            try writer.print("archerdb_lsm_write_amplification_ratio {d:.2}\n", .{ratio});
        } else {
            try writer.writeAll("archerdb_lsm_write_amplification_ratio 0\n");
        }
        try writer.writeAll("\n");

        // Grid cache metrics
        try writer.writeAll(
            "# HELP archerdb_grid_cache_hits_total Cache hits for block reads\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_cache_hits_total counter\n");
        const cache_hits_val = grid_cache_hits_total.load(.monotonic);
        try writer.print("archerdb_grid_cache_hits_total {d}\n", .{cache_hits_val});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_grid_cache_misses_total Cache misses (disk read)\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_cache_misses_total counter\n");
        const cache_miss_val = grid_cache_misses_total.load(.monotonic);
        try writer.print("archerdb_grid_cache_misses_total {d}\n", .{cache_miss_val});
        try writer.writeAll("\n");

        // Grid cache hit ratio (derived)
        const cache_hits = grid_cache_hits_total.load(.monotonic);
        const cache_misses = grid_cache_misses_total.load(.monotonic);
        const cache_total = cache_hits + cache_misses;
        try writer.writeAll(
            "# HELP archerdb_grid_cache_hit_ratio Cache hit rate (hits/total)\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_cache_hit_ratio gauge\n");
        if (cache_total > 0) {
            const hits_f: f64 = @floatFromInt(cache_hits);
            const total_f: f64 = @floatFromInt(cache_total);
            const hit_ratio: f64 = hits_f / total_f;
            try writer.print("archerdb_grid_cache_hit_ratio {d:.4}\n", .{hit_ratio});
        } else {
            try writer.writeAll("archerdb_grid_cache_hit_ratio 0\n");
        }
        try writer.writeAll("\n");

        // Grid cache size (blocks × block_size)
        const cache_blocks = grid_cache_blocks_count.load(.monotonic);
        const block_size: u64 = 65536; // constants.block_size (64KB)
        try writer.writeAll(
            "# HELP archerdb_grid_cache_size_bytes Cache size in bytes\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_cache_size_bytes gauge\n");
        const cache_size = cache_blocks * block_size;
        try writer.print("archerdb_grid_cache_size_bytes {d}\n", .{cache_size});
        try writer.writeAll("\n");

        // Grid block utilization
        try writer.writeAll(
            "# HELP archerdb_grid_blocks_acquired Acquired blocks (in use)\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_blocks_acquired gauge\n");
        const blocks_acq = grid_blocks_acquired.load(.monotonic);
        try writer.print("archerdb_grid_blocks_acquired {d}\n", .{blocks_acq});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_grid_blocks_missing Missing/faulty blocks\n",
        );
        try writer.writeAll("# TYPE archerdb_grid_blocks_missing gauge\n");
        const blocks_miss = grid_blocks_missing.load(.monotonic);
        try writer.print("archerdb_grid_blocks_missing {d}\n", .{blocks_miss});
        try writer.writeAll("\n");

        // Journal/WAL metrics
        try writer.writeAll(
            "# HELP archerdb_journal_dirty_count Dirty journal slots\n",
        );
        try writer.writeAll("# TYPE archerdb_journal_dirty_count gauge\n");
        const dirty_cnt = journal_dirty_count.load(.monotonic);
        try writer.print("archerdb_journal_dirty_count {d}\n", .{dirty_cnt});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_journal_faulty_count Faulty journal slots\n",
        );
        try writer.writeAll("# TYPE archerdb_journal_faulty_count gauge\n");
        const faulty_cnt = journal_faulty_count.load(.monotonic);
        try writer.print("archerdb_journal_faulty_count {d}\n", .{faulty_cnt});
        try writer.writeAll("\n");

        // Free set metrics
        const blocks_free = free_set_blocks_free.load(.monotonic);
        const blocks_reserved = free_set_blocks_reserved.load(.monotonic);
        const blocks_acquired_val = grid_blocks_acquired.load(.monotonic);
        const total_blocks = free_set_total_blocks.load(.monotonic);

        try writer.writeAll(
            "# HELP archerdb_free_set_blocks_free Free blocks available\n",
        );
        try writer.writeAll("# TYPE archerdb_free_set_blocks_free gauge\n");
        try writer.print("archerdb_free_set_blocks_free {d}\n", .{blocks_free});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_free_set_blocks_reserved Reserved (not acquired)\n",
        );
        try writer.writeAll("# TYPE archerdb_free_set_blocks_reserved gauge\n");
        try writer.print("archerdb_free_set_blocks_reserved {d}\n", .{blocks_reserved});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_free_set_blocks_acquired Acquired blocks (in use)\n",
        );
        try writer.writeAll("# TYPE archerdb_free_set_blocks_acquired gauge\n");
        try writer.print("archerdb_free_set_blocks_acquired {d}\n", .{blocks_acquired_val});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_free_set_utilization Capacity utilization (0-1)\n",
        );
        try writer.writeAll("# TYPE archerdb_free_set_utilization gauge\n");
        if (total_blocks > 0) {
            const acq_f: f64 = @floatFromInt(blocks_acquired_val);
            const tot_f: f64 = @floatFromInt(total_blocks);
            const utilization: f64 = acq_f / tot_f;
            try writer.print("archerdb_free_set_utilization {d:.4}\n", .{utilization});
        } else {
            try writer.writeAll("archerdb_free_set_utilization 0\n");
        }
        try writer.writeAll("\n");

        // Free set exhaustion threshold counters (storage-engine/spec.md)
        try free_set_low_warning_total.format(writer);
        try free_set_critical_total.format(writer);
        try free_set_emergency_total.format(writer);
        try writer.writeAll("\n");

        // Backup metrics (F5.5.6)
        try writer.writeAll("# HELP archerdb_backup_blocks_uploaded_total " ++
            "Total blocks uploaded to object storage\n");
        try writer.writeAll("# TYPE archerdb_backup_blocks_uploaded_total counter\n");
        const uploaded = backup_blocks_uploaded_total.load(.monotonic);
        try writer.print("archerdb_backup_blocks_uploaded_total {d}\n", .{uploaded});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_lag_blocks " ++
            "Blocks pending backup (not yet uploaded)\n");
        try writer.writeAll("# TYPE archerdb_backup_lag_blocks gauge\n");
        const lag = backup_lag_blocks.load(.monotonic);
        try writer.print("archerdb_backup_lag_blocks {d}\n", .{lag});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_failures_total " ++
            "Total backup upload failures\n");
        try writer.writeAll("# TYPE archerdb_backup_failures_total counter\n");
        const failures = backup_failures_total.load(.monotonic);
        try writer.print("archerdb_backup_failures_total {d}\n", .{failures});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_last_success_timestamp " ++
            "Unix timestamp of last successful backup\n");
        try writer.writeAll("# TYPE archerdb_backup_last_success_timestamp gauge\n");
        const last_success = backup_last_success_timestamp.load(.monotonic);
        try writer.print("archerdb_backup_last_success_timestamp {d}\n", .{last_success});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_rpo_current_seconds " ++
            "Current Recovery Point Objective (seconds since oldest un-backed-up block)\n");
        try writer.writeAll("# TYPE archerdb_backup_rpo_current_seconds gauge\n");
        const rpo = backup_rpo_current_seconds.load(.monotonic);
        try writer.print("archerdb_backup_rpo_current_seconds {d}\n", .{rpo});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_blocks_abandoned_total " ++
            "Blocks abandoned without backup (best-effort mode, Free Set pressure)\n");
        try writer.writeAll("# TYPE archerdb_backup_blocks_abandoned_total counter\n");
        const abandoned = backup_blocks_abandoned_total.load(.monotonic);
        try writer.print("archerdb_backup_blocks_abandoned_total {d}\n", .{abandoned});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_backup_mandatory_bypass_total " ++
            "Count of mandatory mode halt timeout bypasses\n");
        try writer.writeAll("# TYPE archerdb_backup_mandatory_bypass_total counter\n");
        const bypass = backup_mandatory_bypass_total.load(.monotonic);
        try writer.print("archerdb_backup_mandatory_bypass_total {d}\n", .{bypass});
        try writer.writeAll("\n");

        // Backup upload latency histogram
        try backup_upload_latency.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // v2.0 Multi-Region Metrics
        // ====================================================================

        // Region info
        try writer.writeAll("# HELP archerdb_region_info Region information\n");
        try writer.writeAll("# TYPE archerdb_region_info gauge\n");
        const role = region_role.load(.monotonic);
        const role_str = if (role == 0) "primary" else "follower";
        try writer.print(
            "archerdb_region_info{{region_id=\"{d}\",role=\"{s}\"}} 1\n",
            .{ region_id.load(.monotonic), role_str },
        );
        try writer.writeAll("\n");

        // Region availability
        try writer.writeAll("# HELP archerdb_region_available Region availability (1=available)\n");
        try writer.writeAll("# TYPE archerdb_region_available gauge\n");
        try writer.print("archerdb_region_available {d}\n", .{region_available.load(.monotonic)});
        try writer.writeAll("\n");

        // Replication shipping metrics (primary only)
        if (role == 0) {
            try writer.writeAll("# HELP archerdb_replication_ship_queue_depth " ++
                "Entries pending shipping per follower\n");
            try writer.writeAll("# TYPE archerdb_replication_ship_queue_depth gauge\n");
            for (replication_ship_queue_depth, 0..) |depth, i| {
                const d = depth.load(.monotonic);
                if (d > 0) {
                    try writer.print(
                        "archerdb_replication_ship_queue_depth{{follower=\"{d}\"}} {d}\n",
                        .{ i, d },
                    );
                }
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_replication_ship_bytes_total " ++
                "Total bytes shipped per follower\n");
            try writer.writeAll("# TYPE archerdb_replication_ship_bytes_total counter\n");
            for (replication_ship_bytes_total, 0..) |bytes, i| {
                const b = bytes.load(.monotonic);
                if (b > 0) {
                    try writer.print(
                        "archerdb_replication_ship_bytes_total{{follower=\"{d}\"}} {d}\n",
                        .{ i, b },
                    );
                }
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_replication_ship_failures_total " ++
                "Ship failures per follower\n");
            try writer.writeAll("# TYPE archerdb_replication_ship_failures_total counter\n");
            for (replication_ship_failures_total, 0..) |fail, i| {
                const f = fail.load(.monotonic);
                if (f > 0) {
                    try writer.print(
                        "archerdb_replication_ship_failures_total{{follower=\"{d}\"}} {d}\n",
                        .{ i, f },
                    );
                }
            }
            try writer.writeAll("\n");
        }

        // Replication lag metrics (follower only)
        if (role == 1) {
            try writer.writeAll("# HELP archerdb_replication_lag_ops " ++
                "Replication lag in operations\n");
            try writer.writeAll("# TYPE archerdb_replication_lag_ops gauge\n");
            try writer.print("archerdb_replication_lag_ops {d}\n", .{replication_lag_ops.load(.monotonic)});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_replication_lag_seconds " ++
                "Replication lag in seconds\n");
            try writer.writeAll("# TYPE archerdb_replication_lag_seconds gauge\n");
            const lag_ns_val = replication_lag_ns.load(.monotonic);
            const lag_sec: f64 = @as(f64, @floatFromInt(lag_ns_val)) / 1e9;
            try writer.print("archerdb_replication_lag_seconds {d:.6}\n", .{lag_sec});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_replication_apply_rate " ++
                "WAL entries applied per second\n");
            try writer.writeAll("# TYPE archerdb_replication_apply_rate gauge\n");
            try writer.print("archerdb_replication_apply_rate {d}\n", .{replication_apply_rate.load(.monotonic)});
            try writer.writeAll("\n");
        }

        // ====================================================================
        // v2.0 Sharding Metrics
        // ====================================================================

        try writer.writeAll("# HELP archerdb_shard_count Number of active shards\n");
        try writer.writeAll("# TYPE archerdb_shard_count gauge\n");
        try writer.print("archerdb_shard_count {d}\n", .{shard_count.load(.monotonic)});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_resharding_status " ++
            "Resharding status (0=idle, 1=preparing, 2=migrating, 3=finalizing)\n");
        try writer.writeAll("# TYPE archerdb_resharding_status gauge\n");
        try writer.print("archerdb_resharding_status {d}\n", .{resharding_status.load(.monotonic)});
        try writer.writeAll("\n");

        const resharding_prog = resharding_progress.load(.monotonic);
        const resharding_stat = resharding_status.load(.monotonic);
        if (resharding_stat > 0 or resharding_prog > 0) {
            try writer.writeAll("# HELP archerdb_resharding_progress " ++
                "Resharding progress (0.0 to 1.0)\n");
            try writer.writeAll("# TYPE archerdb_resharding_progress gauge\n");
            const prog: f64 = @as(f64, @floatFromInt(resharding_prog)) / 1000.0;
            try writer.print("archerdb_resharding_progress {d:.3}\n", .{prog});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_entities_exported " ++
                "Entities exported during resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_entities_exported counter\n");
            try writer.print("archerdb_resharding_entities_exported {d}\n", .{resharding_entities_exported.load(.monotonic)});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_entities_imported " ++
                "Entities imported during resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_entities_imported counter\n");
            try writer.print("archerdb_resharding_entities_imported {d}\n", .{resharding_entities_imported.load(.monotonic)});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_source_shards " ++
                "Source shard count before resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_source_shards gauge\n");
            try writer.print("archerdb_resharding_source_shards {d}\n", .{resharding_source_shards.load(.monotonic)});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_target_shards " ++
                "Target shard count for resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_target_shards gauge\n");
            try writer.print("archerdb_resharding_target_shards {d}\n", .{resharding_target_shards.load(.monotonic)});
            try writer.writeAll("\n");
        }

        // Always show resharding duration if completed (non-zero)
        const duration_ns = resharding_duration_ns.load(.monotonic);
        if (duration_ns > 0) {
            try writer.writeAll("# HELP archerdb_resharding_duration_seconds " ++
                "Duration of last resharding operation\n");
            try writer.writeAll("# TYPE archerdb_resharding_duration_seconds gauge\n");
            const duration_sec: f64 = @as(f64, @floatFromInt(duration_ns)) / 1e9;
            try writer.print("archerdb_resharding_duration_seconds {d:.3}\n", .{duration_sec});
            try writer.writeAll("\n");
        }

        try scatter_gather_queries_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // v2.0 Encryption Metrics
        // ====================================================================

        try encryption_ops_total.format(writer);
        try decryption_ops_total.format(writer);
        try encryption_cache_hits_total.format(writer);
        try encryption_cache_misses_total.format(writer);
        try encryption_failures_total.format(writer);
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_encryption_rotation_status " ++
            "Key rotation status (0=idle, 1=rotating)\n");
        try writer.writeAll("# TYPE archerdb_encryption_rotation_status gauge\n");
        try writer.print("archerdb_encryption_rotation_status {d}\n", .{encryption_rotation_status.load(.monotonic)});
        try writer.writeAll("\n");

        const rotation_prog = encryption_rotation_progress.load(.monotonic);
        if (rotation_prog > 0) {
            try writer.writeAll("# HELP archerdb_encryption_rotation_progress " ++
                "Key rotation progress (0.0 to 1.0)\n");
            try writer.writeAll("# TYPE archerdb_encryption_rotation_progress gauge\n");
            const prog: f64 = @as(f64, @floatFromInt(rotation_prog)) / 1000.0;
            try writer.print("archerdb_encryption_rotation_progress {d:.3}\n", .{prog});
            try writer.writeAll("\n");
        }
    }

    /// Update VSR metrics from replica state.
    /// Called periodically from the main replica loop.
    ///
    /// Status mapping:
    /// - 0 = normal
    /// - 1 = view_change
    /// - 2 = recovering
    /// - 3 = recovering_head
    pub fn updateVsrMetrics(
        view: u32,
        status: i64,
        is_primary: bool,
        op_number: u64,
    ) void {
        vsr_view.set(@intCast(view));
        vsr_status.set(status);
        vsr_is_primary.set(if (is_primary) 1 else 0);
        vsr_op_number.set(@intCast(op_number));
    }

    /// Record a view change event.
    pub fn recordViewChange() void {
        vsr_view_changes_total.inc();
    }

    /// Initialize replication lag tracking for the cluster.
    /// Called once during replica startup.
    pub fn initReplicationLagTracking(replica_count_val: u8, replica_index: u8) void {
        vsr_replica_count.store(replica_count_val, .monotonic);
        vsr_replica_index.store(replica_index, .monotonic);
        // Initialize all lag values to 0
        for (&vsr_replication_lag_ops) |*lag| {
            lag.store(0, .monotonic);
        }
        for (&vsr_replication_lag_ns) |*lag| {
            lag.store(0, .monotonic);
        }
    }

    /// Update replication lag for a specific replica.
    /// Called when the primary receives a PrepareOk or Commit message.
    ///
    /// Args:
    ///   replica_idx: Index of the replica (0-based)
    ///   lag_ops: Replication lag in operations (commit_max - replica's commit_min)
    ///   lag_ns: Estimated lag in nanoseconds (if known, or 0)
    pub fn updateReplicationLag(replica_idx: u8, lag_ops: u64, lag_ns: u64) void {
        if (replica_idx < max_replicas) {
            vsr_replication_lag_ops[replica_idx].store(lag_ops, .monotonic);
            vsr_replication_lag_ns[replica_idx].store(lag_ns, .monotonic);
        }
    }

    /// Update replication lag for all replicas at once.
    /// Called periodically from the primary's main loop.
    ///
    /// Args:
    ///   commit_max: The primary's commit_max (highest committed op)
    ///   commit_mins: Array of commit_min values for each replica (null if unknown)
    ///   avg_op_duration_ns: Average operation duration for time estimation
    pub fn updateAllReplicationLags(
        commit_max: u64,
        commit_mins: []const ?u64,
        avg_op_duration_ns: u64,
    ) void {
        const count = @min(commit_mins.len, max_replicas);
        for (0..count) |i| {
            if (commit_mins[i]) |replica_commit_min| {
                // Saturating subtraction to handle edge cases
                const lag_ops = commit_max -| replica_commit_min;
                const lag_ns = lag_ops * avg_op_duration_ns;
                vsr_replication_lag_ops[i].store(lag_ops, .monotonic);
                vsr_replication_lag_ns[i].store(lag_ns, .monotonic);
            }
        }
    }

    /// Update resource metrics (memory, disk, I/O).
    /// Called periodically from the main replica loop.
    pub fn updateResourceMetrics(
        mem_allocated: u64,
        mem_used: u64,
        storage_size: u64,
        idx_entries: u64,
        idx_capacity: u64,
    ) void {
        memory_allocated_bytes.set(@intCast(mem_allocated));
        memory_used_bytes.set(@intCast(mem_used));
        data_file_size_bytes.set(@intCast(storage_size));
        index_entries.set(@intCast(idx_entries));
        index_capacity.set(@intCast(idx_capacity));

        // Calculate index load factor (scaled by 1000 for gauge precision)
        // e.g., 500 = 0.5 (50% full), 900 = 0.9 (90% full)
        if (idx_capacity > 0) {
            const load_factor_scaled: i64 = @intCast((idx_entries * 1000) / idx_capacity);
            index_load_factor.set(load_factor_scaled);
        }
    }

    /// Record a disk read operation with optional latency.
    /// latency_ns is the operation duration in nanoseconds (0 to skip latency recording).
    pub fn recordDiskRead(bytes: u64, latency_ns: u64) void {
        disk_reads_total.inc();
        disk_read_bytes_total.add(bytes);
        if (latency_ns > 0) {
            disk_read_latency.observeNs(latency_ns);
        }
    }

    /// Record a disk write operation with optional latency.
    /// latency_ns is the operation duration in nanoseconds (0 to skip latency recording).
    pub fn recordDiskWrite(bytes: u64, latency_ns: u64) void {
        disk_writes_total.inc();
        disk_write_bytes_total.add(bytes);
        if (latency_ns > 0) {
            disk_write_latency.observeNs(latency_ns);
        }
    }

    /// Record a completed compaction operation.
    /// level is the destination level (0-5), bytes_moved is total bytes processed.
    /// latency_ns is the compaction duration in nanoseconds.
    pub fn recordCompaction(level: u8, bytes_moved: u64, latency_ns: u64) void {
        // Track per-level compaction count and bytes
        if (level < lsm_compactions_per_level.len) {
            _ = lsm_compactions_per_level[level].fetchAdd(1, .monotonic);
            _ = lsm_compaction_bytes_per_level[level].fetchAdd(bytes_moved, .monotonic);
        }
        // Track total disk bytes for write amplification
        _ = lsm_disk_bytes_written.fetchAdd(bytes_moved, .monotonic);
        if (latency_ns > 0) {
            lsm_compaction_latency.observeNs(latency_ns);
        }
    }

    /// Record user-visible bytes written (for write amplification calculation).
    /// Called when user data is written to LSM.
    pub fn recordUserBytesWritten(bytes: u64) void {
        _ = lsm_user_bytes_written.fetchAdd(bytes, .monotonic);
        _ = lsm_disk_bytes_written.fetchAdd(bytes, .monotonic);
    }

    /// Update LSM level metrics (table counts and sizes per level).
    /// Called periodically or after compaction events.
    /// tables_per_level: array of table counts for each level (max 6 levels)
    /// sizes_per_level: array of sizes in bytes for each level (max 6 levels)
    pub fn updateLsmMetrics(
        tables_per_level: []const u32,
        sizes_per_level: []const u64,
    ) void {
        const max_levels = @min(lsm_tables_per_level.len, tables_per_level.len);
        for (0..max_levels) |i| {
            lsm_tables_per_level[i].store(tables_per_level[i], .monotonic);
        }

        const max_size_levels = @min(lsm_level_size_bytes.len, sizes_per_level.len);
        for (0..max_size_levels) |i| {
            lsm_level_size_bytes[i].store(sizes_per_level[i], .monotonic);
        }
    }

    /// Update grid cache, journal, and free set metrics.
    /// Called periodically from the main replica loop.
    pub fn updateGridMetrics(
        cache_hits: u64,
        cache_misses: u64,
        cache_blocks: u64,
        blocks_acquired: u64,
        blocks_missing: u64,
        dirty_count: u64,
        faulty_count: u64,
        blocks_free: u64,
        blocks_reserved: u64,
        total_blocks: u64,
    ) void {
        grid_cache_hits_total.store(cache_hits, .monotonic);
        grid_cache_misses_total.store(cache_misses, .monotonic);
        grid_cache_blocks_count.store(cache_blocks, .monotonic);
        grid_blocks_acquired.store(blocks_acquired, .monotonic);
        grid_blocks_missing.store(blocks_missing, .monotonic);
        journal_dirty_count.store(dirty_count, .monotonic);
        journal_faulty_count.store(faulty_count, .monotonic);
        free_set_blocks_free.store(blocks_free, .monotonic);
        free_set_blocks_reserved.store(blocks_reserved, .monotonic);
        free_set_total_blocks.store(total_blocks, .monotonic);
    }

    // ==========================================================================
    // Free Set Threshold Monitoring (storage-engine/spec.md)
    // ==========================================================================

    /// Free set exhaustion state for backpressure decisions.
    pub const FreeSetState = enum {
        /// Normal operation - more than 10% free
        normal,
        /// Warning threshold - 5-10% free, log warning
        warning,
        /// Critical threshold - 2-5% free, reject writes
        critical,
        /// Emergency threshold - less than 2% free, force compaction
        emergency,
    };

    /// Check free set exhaustion thresholds and record appropriate metrics.
    /// Returns the current free set state for backpressure decisions.
    ///
    /// Thresholds (storage-engine/spec.md):
    /// - 10% free: Warning - log warning, increment warning counter
    /// - 5% free: Critical - reject new writes, allow compaction
    /// - 2% free: Emergency - force immediate compaction
    ///
    /// Args:
    ///   blocks_free: Number of free blocks available
    ///   total_blocks: Total blocks in the free set
    ///
    /// Returns: The current FreeSetState based on thresholds
    pub fn checkFreeSetThresholds(blocks_free: u64, total_blocks: u64) FreeSetState {
        if (total_blocks == 0) return .normal;

        // Calculate percentage of free blocks (scaled by 1000 for precision)
        const free_pct_scaled = (blocks_free * 1000) / total_blocks;

        // Check thresholds from most severe to least
        if (free_pct_scaled < 20) { // < 2%
            free_set_emergency_total.inc();
            return .emergency;
        } else if (free_pct_scaled < 50) { // < 5%
            free_set_critical_total.inc();
            return .critical;
        } else if (free_pct_scaled < 100) { // < 10%
            free_set_low_warning_total.inc();
            return .warning;
        }

        return .normal;
    }

    /// Check if writes should be rejected due to free set exhaustion.
    /// Returns true if the system should reject new write operations.
    ///
    /// This should be called before accepting write batches. If true,
    /// the operation should return `out_of_space` error.
    pub fn shouldRejectWrites(blocks_free: u64, total_blocks: u64) bool {
        const state = checkFreeSetThresholds(blocks_free, total_blocks);
        return state == .critical or state == .emergency;
    }

    /// Check if emergency compaction should be triggered.
    /// Returns true if the system should force immediate compaction.
    pub fn shouldTriggerEmergencyCompaction(blocks_free: u64, total_blocks: u64) bool {
        if (total_blocks == 0) return false;
        const free_pct_scaled = (blocks_free * 1000) / total_blocks;
        return free_pct_scaled < 20; // < 2%
    }

    // ==========================================================================
    // Backup Metrics Update Functions (F5.5.6)
    // ==========================================================================

    /// Record a successful backup block upload.
    /// latency_ns is the upload duration in nanoseconds.
    /// timestamp is the Unix timestamp (seconds since epoch) of the upload.
    pub fn recordBackupBlockUploaded(latency_ns: u64, timestamp: u64) void {
        _ = backup_blocks_uploaded_total.fetchAdd(1, .monotonic);
        backup_last_success_timestamp.store(timestamp, .monotonic);
        if (latency_ns > 0) {
            backup_upload_latency.observeNs(latency_ns);
        }
    }

    /// Record a backup upload failure.
    pub fn recordBackupFailure() void {
        _ = backup_failures_total.fetchAdd(1, .monotonic);
    }

    /// Update the current backup lag (blocks pending upload).
    /// Also updates RPO based on oldest un-backed-up block age.
    /// lag_blocks: Number of blocks awaiting backup
    /// oldest_block_age_seconds: Age of oldest un-backed-up block in seconds
    pub fn updateBackupLag(lag_blocks: u64, oldest_block_age_seconds: u64) void {
        backup_lag_blocks.store(lag_blocks, .monotonic);
        backup_rpo_current_seconds.store(oldest_block_age_seconds, .monotonic);
    }

    /// Record a block being abandoned without backup (best-effort mode under pressure).
    pub fn recordBackupBlockAbandoned() void {
        _ = backup_blocks_abandoned_total.fetchAdd(1, .monotonic);
    }

    /// Record a mandatory mode halt timeout bypass.
    pub fn recordBackupMandatoryBypass() void {
        _ = backup_mandatory_bypass_total.fetchAdd(1, .monotonic);
    }
};

// Tests
test "Counter: basic operations" {
    var counter = Counter.init("test_counter", "A test counter", null);

    try std.testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(5);
    try std.testing.expectEqual(@as(u64, 6), counter.get());
}

test "Gauge: basic operations" {
    var gauge = Gauge.init("test_gauge", "A test gauge", null);

    try std.testing.expectEqual(@as(i64, 0), gauge.get());

    gauge.set(42);
    try std.testing.expectEqual(@as(i64, 42), gauge.get());

    gauge.inc();
    try std.testing.expectEqual(@as(i64, 43), gauge.get());

    gauge.dec();
    try std.testing.expectEqual(@as(i64, 42), gauge.get());

    gauge.add(-50);
    try std.testing.expectEqual(@as(i64, -8), gauge.get());
}

test "Histogram: basic operations" {
    var hist = latencyHistogram("test_latency", "Test latency histogram", null);

    try std.testing.expectEqual(@as(u64, 0), hist.getCount());

    hist.observe(0.0001); // 100μs - goes in first bucket
    hist.observe(0.001); // 1ms - goes in second bucket
    hist.observe(0.01); // 10ms - goes in fourth bucket

    try std.testing.expectEqual(@as(u64, 3), hist.getCount());
    try std.testing.expect(hist.getSum() > 0);
}

test "Counter: prometheus format" {
    var counter = Counter.init("test_total", "Test counter", null);
    counter.add(42);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try counter.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE test_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test_total 42") != null);
}

test "Counter: prometheus format with labels" {
    var counter = Counter.init("test_total", "Test counter", "method=\"GET\"");
    counter.add(100);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try counter.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "test_total{method=\"GET\"} 100") != null);
}

test "Registry: replication lag initialization" {
    // Initialize with 3 replicas, this replica is index 1
    Registry.initReplicationLagTracking(3, 1);

    try std.testing.expectEqual(@as(u8, 3), Registry.vsr_replica_count.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 1), Registry.vsr_replica_index.load(.monotonic));

    // All lag values should be initialized to 0
    for (0..3) |i| {
        const lag = Registry.vsr_replication_lag_ops[i].load(.monotonic);
        try std.testing.expectEqual(@as(u64, 0), lag);
    }
}

test "Registry: update single replica lag" {
    // Initialize
    Registry.initReplicationLagTracking(3, 0);

    // Update lag for replica 1: 5 ops behind, 5ms estimated lag
    Registry.updateReplicationLag(1, 5, 5_000_000);

    const lag_ops_1 = Registry.vsr_replication_lag_ops[1].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 5), lag_ops_1);
    const lag_ns_1 = Registry.vsr_replication_lag_ns[1].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 5_000_000), lag_ns_1);

    // Other replicas should still be at 0
    try std.testing.expectEqual(@as(u64, 0), Registry.vsr_replication_lag_ops[0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), Registry.vsr_replication_lag_ops[2].load(.monotonic));
}

test "Registry: update all replication lags" {
    // Initialize
    Registry.initReplicationLagTracking(3, 0);

    // Simulate: commit_max = 1000, replicas at 1000, 995, 998
    const commit_mins = [_]?u64{ 1000, 995, 998 };
    const avg_op_ns: u64 = 1_000_000; // 1ms per op

    Registry.updateAllReplicationLags(1000, &commit_mins, avg_op_ns);

    // Replica 0: 0 ops behind (primary)
    try std.testing.expectEqual(@as(u64, 0), Registry.vsr_replication_lag_ops[0].load(.monotonic));
    // Replica 1: 5 ops behind, 5ms lag
    const r1_ops = Registry.vsr_replication_lag_ops[1].load(.monotonic);
    const r1_ns = Registry.vsr_replication_lag_ns[1].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 5), r1_ops);
    try std.testing.expectEqual(@as(u64, 5_000_000), r1_ns);
    // Replica 2: 2 ops behind, 2ms lag
    const r2_ops = Registry.vsr_replication_lag_ops[2].load(.monotonic);
    const r2_ns = Registry.vsr_replication_lag_ns[2].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 2), r2_ops);
    try std.testing.expectEqual(@as(u64, 2_000_000), r2_ns);
}

test "Registry: replication lag metrics format" {
    // Initialize with 2 replicas
    Registry.initReplicationLagTracking(2, 0);
    Registry.updateReplicationLag(0, 0, 0);
    Registry.updateReplicationLag(1, 3, 3_000_000); // 3ms lag

    // Use same buffer size as metrics_server.zig (65536)
    // to accommodate all metrics including LSM per-level stats
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Should contain lag_ops metrics
    const has_lag_ops = std.mem.indexOf(u8, output, "archerdb_vsr_replication_lag_ops") != null;
    try std.testing.expect(has_lag_ops);

    // Should contain lag_seconds metrics
    const has_lag_sec = std.mem.indexOf(u8, output, "archerdb_vsr_replication_lag_seconds") != null;
    try std.testing.expect(has_lag_sec);

    // Should have per-replica labels
    const has_replica0 = std.mem.indexOf(u8, output, "replica=\"replica-0\"") != null;
    const has_replica1 = std.mem.indexOf(u8, output, "replica=\"replica-1\"") != null;
    try std.testing.expect(has_replica0);
    try std.testing.expect(has_replica1);
}

// =============================================================================
// F5.5.6: Backup Metrics Tests
// =============================================================================

test "Registry: backup block uploaded tracking" {
    // Reset state
    Registry.backup_blocks_uploaded_total.store(0, .monotonic);
    Registry.backup_last_success_timestamp.store(0, .monotonic);

    // Record an upload with 100ms latency at timestamp 1704067200 (2024-01-01 00:00:00)
    Registry.recordBackupBlockUploaded(100_000_000, 1704067200);

    const uploaded = Registry.backup_blocks_uploaded_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), uploaded);

    const timestamp = Registry.backup_last_success_timestamp.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1704067200), timestamp);

    // Record another upload
    Registry.recordBackupBlockUploaded(50_000_000, 1704067260);

    const uploaded2 = Registry.backup_blocks_uploaded_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 2), uploaded2);
}

test "Registry: backup failure tracking" {
    // Reset state
    Registry.backup_failures_total.store(0, .monotonic);

    Registry.recordBackupFailure();
    Registry.recordBackupFailure();
    Registry.recordBackupFailure();

    const failures = Registry.backup_failures_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 3), failures);
}

test "Registry: backup lag and RPO tracking" {
    // Reset state
    Registry.backup_lag_blocks.store(0, .monotonic);
    Registry.backup_rpo_current_seconds.store(0, .monotonic);

    // Update lag: 5 blocks pending, oldest is 30 seconds old
    Registry.updateBackupLag(5, 30);

    const lag = Registry.backup_lag_blocks.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 5), lag);

    const rpo = Registry.backup_rpo_current_seconds.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 30), rpo);
}

test "Registry: backup block abandoned tracking" {
    // Reset state
    Registry.backup_blocks_abandoned_total.store(0, .monotonic);

    Registry.recordBackupBlockAbandoned();
    Registry.recordBackupBlockAbandoned();

    const abandoned = Registry.backup_blocks_abandoned_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 2), abandoned);
}

test "Registry: backup mandatory bypass tracking" {
    // Reset state
    Registry.backup_mandatory_bypass_total.store(0, .monotonic);

    Registry.recordBackupMandatoryBypass();

    const bypass = Registry.backup_mandatory_bypass_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), bypass);
}

test "Registry: backup metrics format output" {
    // Reset state for consistent test
    Registry.backup_blocks_uploaded_total.store(100, .monotonic);
    Registry.backup_lag_blocks.store(5, .monotonic);
    Registry.backup_failures_total.store(2, .monotonic);
    Registry.backup_last_success_timestamp.store(1704067200, .monotonic);
    Registry.backup_rpo_current_seconds.store(15, .monotonic);
    Registry.backup_blocks_abandoned_total.store(0, .monotonic);
    Registry.backup_mandatory_bypass_total.store(0, .monotonic);

    // Use same buffer size as metrics_server.zig (65536)
    // to accommodate all metrics including LSM per-level stats
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Verify all backup metrics are present
    const uploaded_key = "archerdb_backup_blocks_uploaded_total";
    try std.testing.expect(std.mem.indexOf(u8, output, uploaded_key) != null);

    const lag_key = "archerdb_backup_lag_blocks";
    try std.testing.expect(std.mem.indexOf(u8, output, lag_key) != null);

    const failures_key = "archerdb_backup_failures_total";
    try std.testing.expect(std.mem.indexOf(u8, output, failures_key) != null);

    const last_success_key = "archerdb_backup_last_success_timestamp";
    try std.testing.expect(std.mem.indexOf(u8, output, last_success_key) != null);

    const rpo_key = "archerdb_backup_rpo_current_seconds";
    try std.testing.expect(std.mem.indexOf(u8, output, rpo_key) != null);

    const abandoned_key = "archerdb_backup_blocks_abandoned_total";
    try std.testing.expect(std.mem.indexOf(u8, output, abandoned_key) != null);

    const bypass_key = "archerdb_backup_mandatory_bypass_total";
    try std.testing.expect(std.mem.indexOf(u8, output, bypass_key) != null);
}

// =============================================================================
// Free Set Threshold Tests (storage-engine/spec.md)
// =============================================================================

test "Registry: free set threshold - normal" {
    // Reset counters
    Registry.free_set_low_warning_total = Counter.init(
        "archerdb_free_set_low_warning_total",
        "Free set below 10% - warning threshold exceeded",
        null,
    );

    // 50% free - should be normal
    const state = Registry.checkFreeSetThresholds(500, 1000);
    try std.testing.expectEqual(Registry.FreeSetState.normal, state);
    try std.testing.expectEqual(@as(u64, 0), Registry.free_set_low_warning_total.get());
}

test "Registry: free set threshold - warning" {
    // Reset counters
    Registry.free_set_low_warning_total = Counter.init(
        "archerdb_free_set_low_warning_total",
        "Free set below 10% - warning threshold exceeded",
        null,
    );

    // 8% free - should trigger warning
    const state = Registry.checkFreeSetThresholds(80, 1000);
    try std.testing.expectEqual(Registry.FreeSetState.warning, state);
    try std.testing.expectEqual(@as(u64, 1), Registry.free_set_low_warning_total.get());
}

test "Registry: free set threshold - critical" {
    // Reset counters
    Registry.free_set_critical_total = Counter.init(
        "archerdb_free_set_critical_total",
        "Free set below 5% - writes suspended",
        null,
    );

    // 3% free - should trigger critical
    const state = Registry.checkFreeSetThresholds(30, 1000);
    try std.testing.expectEqual(Registry.FreeSetState.critical, state);
    try std.testing.expectEqual(@as(u64, 1), Registry.free_set_critical_total.get());
}

test "Registry: free set threshold - emergency" {
    // Reset counters
    Registry.free_set_emergency_total = Counter.init(
        "archerdb_free_set_emergency_total",
        "Free set below 2% - emergency compaction triggered",
        null,
    );

    // 1% free - should trigger emergency
    const state = Registry.checkFreeSetThresholds(10, 1000);
    try std.testing.expectEqual(Registry.FreeSetState.emergency, state);
    try std.testing.expectEqual(@as(u64, 1), Registry.free_set_emergency_total.get());
}

test "Registry: shouldRejectWrites" {
    // Normal state - don't reject
    try std.testing.expect(!Registry.shouldRejectWrites(500, 1000)); // 50% free
    try std.testing.expect(!Registry.shouldRejectWrites(100, 1000)); // 10% free

    // Warning state (5-10%) - don't reject
    try std.testing.expect(!Registry.shouldRejectWrites(80, 1000)); // 8% free

    // Critical state (<5%) - reject
    try std.testing.expect(Registry.shouldRejectWrites(40, 1000)); // 4% free

    // Emergency state (<2%) - reject
    try std.testing.expect(Registry.shouldRejectWrites(10, 1000)); // 1% free
}

test "Registry: shouldTriggerEmergencyCompaction" {
    // Above 2% - no emergency
    try std.testing.expect(!Registry.shouldTriggerEmergencyCompaction(100, 1000)); // 10%
    try std.testing.expect(!Registry.shouldTriggerEmergencyCompaction(30, 1000)); // 3%

    // Below 2% - trigger emergency
    try std.testing.expect(Registry.shouldTriggerEmergencyCompaction(19, 1000)); // 1.9%
    try std.testing.expect(Registry.shouldTriggerEmergencyCompaction(10, 1000)); // 1%
    try std.testing.expect(Registry.shouldTriggerEmergencyCompaction(0, 1000)); // 0%
}

test "Registry: free set threshold with zero total" {
    // Edge case: zero total blocks should return normal
    const state = Registry.checkFreeSetThresholds(0, 0);
    try std.testing.expectEqual(Registry.FreeSetState.normal, state);

    // Zero total should not trigger emergency compaction
    try std.testing.expect(!Registry.shouldTriggerEmergencyCompaction(0, 0));
}
