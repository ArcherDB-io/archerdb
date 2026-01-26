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

/// Storage-specific metrics for write/space amplification monitoring.
/// Provides Prometheus-compatible metrics for LSM tree health tracking.
pub const storage = @import("storage_metrics.zig");

/// RAM index metrics for memory monitoring.
/// Provides Prometheus-compatible metrics for index health tracking.
pub const index = @import("index_metrics.zig");
const cluster = @import("cluster_metrics.zig");

/// Query latency breakdown metrics for performance diagnosis.
/// Provides detailed latency breakdown by query phase and type.
const query = @import("query_metrics.zig");

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

/// Extended statistics from histogram data.
/// Provides P50, P75, P90, P95, P99, P99.9, P99.99, and max values.
pub const ExtendedStats = struct {
    p50: f64,
    p75: f64,
    p90: f64,
    p95: f64,
    p99: f64,
    p999: f64, // P99.9
    p9999: f64, // P99.99
    max: f64,
    count: u64,
    sum: f64,
    mean: f64,

    /// Format as human-readable output (times in milliseconds).
    pub fn format(self: *const @This(), writer: anytype) !void {
        try writer.print(
            \\P50={d:.3}ms P75={d:.3}ms P90={d:.3}ms P95={d:.3}ms
            \\P99={d:.3}ms P99.9={d:.3}ms P99.99={d:.3}ms max={d:.3}ms
            \\count={d} mean={d:.3}ms
        , .{
            self.p50 * 1000, self.p75 * 1000, self.p90 * 1000, self.p95 * 1000,
            self.p99 * 1000, self.p999 * 1000, self.p9999 * 1000, self.max * 1000,
            self.count, self.mean * 1000,
        });
    }

    /// Diagnose obvious latency issues.
    pub fn diagnose(self: *const @This(), writer: anytype) !void {
        if (self.p99 > self.p50 * 10) {
            try writer.print("WARNING: P99 > 10x P50 - high tail latency\n", .{});
        }
        if (self.p9999 > self.p99 * 5) {
            try writer.print("WARNING: P99.99 > 5x P99 - extreme outliers present\n", .{});
        }
    }

    /// Check if statistics indicate healthy latency distribution.
    pub fn isHealthy(self: *const @This()) bool {
        // Healthy if P99 is not more than 10x P50
        return self.p99 <= self.p50 * 10;
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

        /// Calculate percentile value (0.0-1.0) from histogram buckets.
        /// Uses linear interpolation within buckets for better accuracy.
        pub fn getPercentile(self: *const @This(), p: f64) f64 {
            const total = self.count.load(.monotonic);
            if (total == 0) return 0;

            const target_count: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * p);
            var cumulative: u64 = 0;

            for (self.bucket_bounds, 0..) |bound, i| {
                cumulative += self.buckets[i].load(.monotonic);
                if (cumulative >= target_count) {
                    return bound;
                }
            }
            return self.bucket_bounds[bucket_count - 1];
        }

        /// Get extended statistics including multiple percentiles.
        pub fn getExtendedStats(self: *const @This()) ExtendedStats {
            const count = self.count.load(.monotonic);
            const sum = self.getSum();
            return .{
                .p50 = self.getPercentile(0.50),
                .p75 = self.getPercentile(0.75),
                .p90 = self.getPercentile(0.90),
                .p95 = self.getPercentile(0.95),
                .p99 = self.getPercentile(0.99),
                .p999 = self.getPercentile(0.999),
                .p9999 = self.getPercentile(0.9999),
                .max = self.bucket_bounds[bucket_count - 1],
                .count = count,
                .sum = sum,
                .mean = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0,
            };
        }

        /// Format extended statistics as Prometheus-compatible output.
        pub fn formatExtended(self: *const @This(), writer: anytype) !void {
            const stats = self.getExtendedStats();
            const label_prefix = if (self.labels) |labels| labels else "";
            const label_sep = if (self.labels != null) "," else "";

            // Output quantiles in Prometheus summary format
            const quantiles = [_]struct { q: f64, v: f64 }{
                .{ .q = 0.5, .v = stats.p50 },
                .{ .q = 0.75, .v = stats.p75 },
                .{ .q = 0.9, .v = stats.p90 },
                .{ .q = 0.95, .v = stats.p95 },
                .{ .q = 0.99, .v = stats.p99 },
                .{ .q = 0.999, .v = stats.p999 },
                .{ .q = 0.9999, .v = stats.p9999 },
            };

            for (quantiles) |q| {
                if (self.labels != null) {
                    try writer.print("{s}{{quantile=\"{d}\",{s}}} {d:.9}\n", .{
                        self.name,
                        q.q,
                        label_prefix,
                        q.v,
                    });
                } else {
                    try writer.print("{s}{{quantile=\"{d}\"}} {d:.9}\n", .{
                        self.name,
                        q.q,
                        q.v,
                    });
                }
            }

            // Max value
            if (self.labels != null) {
                try writer.print("{s}_max{{{s}{s}}} {d:.9}\n", .{
                    self.name,
                    label_prefix,
                    label_sep,
                    stats.max,
                });
            } else {
                try writer.print("{s}_max {d:.9}\n", .{ self.name, stats.max });
            }
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

/// Shard lookup latency histogram buckets: 10μs, 100μs, 1ms, 10ms, 100ms, 1s.
pub const ShardLookupHistogram = HistogramType(6);

pub fn shardLookupHistogram(
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,
) ShardLookupHistogram {
    return ShardLookupHistogram.init(name, help, labels, .{
        0.00001, // 10μs
        0.0001, // 100μs
        0.001, // 1ms
        0.01, // 10ms
        0.1, // 100ms
        1.0, // 1s
    });
}

/// Histogram for number of shards queried (fan-out).
pub const QueryShardsHistogram = HistogramType(3);

pub fn queryShardsHistogram(
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,
) QueryShardsHistogram {
    return QueryShardsHistogram.init(name, help, labels, .{
        1.0,
        4.0,
        16.0,
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

    /// Cluster metrics (pool, shedding, routing)
    pub var cluster_metrics: cluster.ClusterMetrics = cluster.ClusterMetrics.init();

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

    pub var index_entries_total: Gauge = Gauge.init(
        "archerdb_index_entries_total",
        "Total entity count in primary index",
        null,
    );

    pub var index_memory_bytes: Gauge = Gauge.init(
        "archerdb_index_memory_bytes",
        "Estimated RAM index memory usage in bytes",
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

    // TTL-aware compaction: Expired ratio per level (stored as integer scaled by 10000).
    // Value range: 0-10000 represents 0.0000 to 1.0000 ratio.
    pub var lsm_ttl_expired_ratio_by_level: [7]std.atomic.Value(u32) = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0), // Level 0
        std.atomic.Value(u32).init(0), // Level 1
        std.atomic.Value(u32).init(0), // Level 2
        std.atomic.Value(u32).init(0), // Level 3
        std.atomic.Value(u32).init(0), // Level 4
        std.atomic.Value(u32).init(0), // Level 5
        std.atomic.Value(u32).init(0), // Level 6
    };

    // Per-level TTL stats: Estimated total bytes per level.
    pub var lsm_bytes_by_level: [7]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0), // Level 0
        std.atomic.Value(u64).init(0), // Level 1
        std.atomic.Value(u64).init(0), // Level 2
        std.atomic.Value(u64).init(0), // Level 3
        std.atomic.Value(u64).init(0), // Level 4
        std.atomic.Value(u64).init(0), // Level 5
        std.atomic.Value(u64).init(0), // Level 6
    };

    // Per-level TTL stats: Estimated expired bytes per level.
    pub var lsm_ttl_expired_bytes_by_level: [7]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0), // Level 0
        std.atomic.Value(u64).init(0), // Level 1
        std.atomic.Value(u64).init(0), // Level 2
        std.atomic.Value(u64).init(0), // Level 3
        std.atomic.Value(u64).init(0), // Level 4
        std.atomic.Value(u64).init(0), // Level 5
        std.atomic.Value(u64).init(0), // Level 6
    };

    // TTL Extension metrics
    // Total number of TTL extensions performed
    pub var ttl_extensions_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    // Extensions skipped due to cooldown period not elapsed
    pub var ttl_extensions_skipped_cooldown: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    // Extensions skipped due to max TTL already reached
    pub var ttl_extensions_skipped_max_ttl: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    // Extensions skipped due to max extension count reached
    pub var ttl_extensions_skipped_max_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    // Extensions skipped due to entity not configured for auto-extend
    pub var ttl_ext_skipped_no_auto: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    // Sum of extension amounts in seconds (for computing average)
    pub var ttl_extension_amount_seconds_sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

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
    // Multi-Region Replication Metrics
    // ========================================================================

    /// Maximum number of follower regions per primary
    pub const max_followers: usize = 16;

    /// Region role (0=primary, 1=follower)
    pub var region_role: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Region identifier
    pub var region_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Ship queue depth per follower region
    pub var replication_ship_queue_depth: [max_followers]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Total bytes shipped per follower region
    pub var replication_ship_bytes_total: [max_followers]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Ship failures per follower region
    pub var replication_ship_failures_total: [max_followers]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Last ship latency in nanoseconds per follower
    pub var replication_ship_latency_ns: [max_followers]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_followers;

    /// Replication lag in operations (follower perspective)
    pub var replication_lag_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Replication lag in nanoseconds (follower perspective)
    pub var replication_lag_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// WAL entries applied per second (follower perspective)
    pub var replication_apply_rate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Region availability status (1=available, 0=unavailable)
    pub var region_available: std.atomic.Value(u8) = std.atomic.Value(u8).init(1);

    // ========================================================================
    // Spillover Metrics (Disk-based replication durability)
    // ========================================================================

    /// Bytes currently on disk spillover
    pub var replication_spillover_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Number of spillover segments on disk
    pub var replication_spillover_segments: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Replication state: 0=healthy, 1=degraded (spillover active), 2=failed
    pub var replication_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    // ========================================================================
    // Sharding Metrics
    // ========================================================================

    /// Configured sharding strategy (0=modulo, 1=virtual_ring, 2=jump_hash, 3=spatial)
    pub var sharding_strategy: Gauge = Gauge.init(
        "archerdb_sharding_strategy",
        "Configured sharding strategy (0=modulo, 1=virtual_ring, 2=jump_hash, 3=spatial)",
        null,
    );

    /// Configured shard strategy (0=entity, 1=spatial)
    pub var shard_strategy: Gauge = Gauge.init(
        "archerdb_shard_strategy",
        "Configured sharding strategy (0=entity, 1=spatial)",
        null,
    );

    /// Shard lookup latency histogram by strategy
    pub var shard_lookup_latency_modulo: ShardLookupHistogram = shardLookupHistogram(
        "archerdb_shard_lookup_duration_seconds",
        "Shard lookup latency histogram",
        "strategy=\"modulo\"",
    );
    pub var shard_lookup_latency_virtual_ring: ShardLookupHistogram = shardLookupHistogram(
        "archerdb_shard_lookup_duration_seconds",
        "Shard lookup latency histogram",
        "strategy=\"virtual_ring\"",
    );
    pub var shard_lookup_latency_jump_hash: ShardLookupHistogram = shardLookupHistogram(
        "archerdb_shard_lookup_duration_seconds",
        "Shard lookup latency histogram",
        "strategy=\"jump_hash\"",
    );
    pub var shard_lookup_latency_spatial: ShardLookupHistogram = shardLookupHistogram(
        "archerdb_shard_lookup_duration_seconds",
        "Shard lookup latency histogram",
        "strategy=\"spatial\"",
    );

    /// Shards queried per query (spatial fan-out)
    pub var query_shards_queried_radius: QueryShardsHistogram = queryShardsHistogram(
        "archerdb_query_shards_queried",
        "Shards queried per query",
        "type=\"radius\"",
    );
    pub var query_shards_queried_polygon: QueryShardsHistogram = queryShardsHistogram(
        "archerdb_query_shards_queried",
        "Shards queried per query",
        "type=\"polygon\"",
    );

    /// Maximum number of shards
    pub const max_shards: usize = 256;

    /// Number of active shards
    pub var shard_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

    /// Entities per shard (approximate)
    pub var shard_entity_count: [max_shards]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_shards;

    /// Size per shard in bytes (approximate)
    pub var shard_size_bytes: [max_shards]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_shards;

    /// Write rate per shard (ops/sec sampled)
    pub var shard_write_rate: [max_shards]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_shards;

    /// Read rate per shard (ops/sec sampled)
    pub var shard_read_rate: [max_shards]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** max_shards;

    /// Shard balance variance (standard deviation / mean, scaled by 10000)
    pub var shard_balance_variance: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Hottest shard ratio (hottest / average, scaled by 10000)
    pub var shard_hottest_ratio: std.atomic.Value(u32) = std.atomic.Value(u32).init(10000);

    /// Coldest shard ratio (coldest / average, scaled by 10000)
    pub var shard_coldest_ratio: std.atomic.Value(u32) = std.atomic.Value(u32).init(10000);

    /// Hot shard id (-1 if none detected)
    pub var shard_hot_id: Gauge = Gauge.init(
        "archerdb_shard_hot_id",
        "Shard id with the highest hot score (-1 if none)",
        null,
    );

    /// Hot shard composite score (0-100)
    pub var shard_hot_score: Gauge = Gauge.init(
        "archerdb_shard_hot_score",
        "Composite hot shard score (0-100)",
        null,
    );

    /// Rebalance needed flag (1=rebalance recommended, 0=balanced)
    pub var shard_rebalance_needed: Gauge = Gauge.init(
        "archerdb_shard_rebalance_needed",
        "Whether shard rebalancing is recommended (1=yes, 0=no)",
        null,
    );

    /// Active shard migration slots in use
    pub var shard_rebalance_active_moves: Gauge = Gauge.init(
        "archerdb_shard_rebalance_active_moves",
        "Active shard rebalance migration slots",
        null,
    );

    /// Remaining rebalance cooldown time in seconds
    pub var shard_rebalance_cooldown_seconds: Gauge = Gauge.init(
        "archerdb_shard_rebalance_cooldown_seconds",
        "Remaining rebalance cooldown time in seconds",
        null,
    );

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

    // ========================================================================
    // Online Resharding Metrics
    // ========================================================================

    /// Online resharding mode (0=none, 1=offline, 2=online)
    pub var resharding_mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Migration rate (entities per second, scaled by 100 for precision)
    pub var resharding_migration_rate: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Batches processed during online migration
    pub var resharding_batches_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Failed migration attempts
    pub var resharding_migration_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Dual-write enabled (1=true, 0=false)
    pub var resharding_dual_write_enabled: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

    /// Estimated time to completion (seconds)
    pub var resharding_eta_seconds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Scatter-gather queries total
    pub var scatter_gather_queries_total: Counter = Counter.init(
        "archerdb_scatter_gather_queries_total",
        "Total scatter-gather queries across shards",
        null,
    );

    // ========================================================================
    // Tiering Metrics (Hot-Warm-Cold)
    // ========================================================================

    /// Entity count per tier
    pub var tier_entity_count_hot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_entity_count_warm: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_entity_count_cold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Size per tier in bytes
    pub var tier_size_bytes_hot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_size_bytes_warm: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_size_bytes_cold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Access rate per tier (ops/sec)
    pub var tier_access_rate_hot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_access_rate_warm: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tier_access_rate_cold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Migration counts by direction
    pub var tiering_migrations_hot_to_warm: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tiering_migrations_warm_to_cold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tiering_migrations_cold_to_warm: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tiering_migrations_warm_to_hot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Pending migrations queue depth
    pub var tiering_queue_depth_demote: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var tiering_queue_depth_promote: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Migration errors
    pub var tiering_migration_errors_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// Cold tier fetch metrics
    pub var cold_tier_fetches_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var cold_tier_fetch_bytes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var cold_tier_latency_ns_sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // ========================================================================
    // Encryption Metrics
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

    // ========================================================================
    // AES-NI Hardware Acceleration Metrics
    // ========================================================================

    /// AES-NI hardware support available (1=yes, 0=no)
    pub var encryption_aesni_available: Gauge = Gauge.init(
        "archerdb_encryption_aesni_available",
        "AES-NI hardware support available (1=yes, 0=no)",
        null,
    );

    /// Using software crypto fallback (1=yes, 0=no)
    pub var encryption_using_software: Gauge = Gauge.init(
        "archerdb_encryption_using_software",
        "Using software crypto fallback (1=yes, 0=no)",
        null,
    );

    /// Current encryption cipher version (1=AES-GCM, 2=Aegis-256)
    pub var encryption_cipher_version: Gauge = Gauge.init(
        "archerdb_encryption_cipher_version",
        "Current encryption cipher version (1=AES-GCM, 2=Aegis-256)",
        null,
    );

    /// Encryption throughput (bytes/sec, rolling average)
    pub var encryption_throughput_encrypt: Gauge = Gauge.init(
        "archerdb_encryption_throughput_bytes",
        "Encryption throughput in bytes per second",
        "operation=\"encrypt\"",
    );

    /// Decryption throughput (bytes/sec, rolling average)
    pub var encryption_throughput_decrypt: Gauge = Gauge.init(
        "archerdb_encryption_throughput_bytes",
        "Decryption throughput in bytes per second",
        "operation=\"decrypt\"",
    );

    // ========================================================================
    // Coordinator Mode Metrics
    // ========================================================================

    // Connection metrics (Task 5.1)
    /// Active client connections to coordinator
    pub var coordinator_connections_active: Gauge = Gauge.init(
        "archerdb_coordinator_connections_active",
        "Active client connections to coordinator",
        null,
    );

    /// Total connections to coordinator
    pub var coordinator_connections_total: Counter = Counter.init(
        "archerdb_coordinator_connections_total",
        "Total connections to coordinator",
        null,
    );

    /// Rejected connections to coordinator
    pub var coordinator_connections_rejected_total: Counter = Counter.init(
        "archerdb_coordinator_connections_rejected_total",
        "Rejected connections to coordinator",
        null,
    );

    // Query metrics (Task 5.2)
    /// Coordinator queries (single-shard)
    pub var coordinator_queries_single: Counter = Counter.init(
        "archerdb_coordinator_queries_total",
        "Total coordinator queries",
        "type=\"single\"",
    );

    /// Coordinator queries (fan-out)
    pub var coordinator_queries_fanout: Counter = Counter.init(
        "archerdb_coordinator_queries_total",
        "Total coordinator queries",
        "type=\"fanout\"",
    );

    /// Coordinator query latency histogram
    pub var coordinator_query_latency: LatencyHistogram = latencyHistogram(
        "archerdb_coordinator_query_duration_seconds",
        "Coordinator query duration in seconds",
        null,
    );

    /// Coordinator query errors (timeout)
    pub var coordinator_query_errors_timeout: Counter = Counter.init(
        "archerdb_coordinator_query_errors_total",
        "Coordinator query errors",
        "reason=\"timeout\"",
    );

    /// Coordinator query errors (shard unavailable)
    pub var coordinator_query_errors_unavailable: Counter = Counter.init(
        "archerdb_coordinator_query_errors_total",
        "Coordinator query errors",
        "reason=\"shard_unavailable\"",
    );

    // Shard metrics (Task 5.3)
    /// Total shards known to coordinator
    pub var coordinator_shards_total: Gauge = Gauge.init(
        "archerdb_coordinator_shards_total",
        "Total shards known to coordinator",
        null,
    );

    /// Healthy shards count
    pub var coordinator_shards_healthy: Gauge = Gauge.init(
        "archerdb_coordinator_shards_healthy",
        "Number of healthy shards",
        null,
    );

    /// Total shard failures detected
    pub var coordinator_shard_failures_total: Counter = Counter.init(
        "archerdb_coordinator_shard_failures_total",
        "Total shard failures detected",
        null,
    );

    // Topology metrics (Task 5.4)
    /// Current topology version
    pub var coordinator_topology_version: Gauge = Gauge.init(
        "archerdb_coordinator_topology_version",
        "Current topology version",
        null,
    );

    /// Total topology updates
    pub var coordinator_topology_updates_total: Counter = Counter.init(
        "archerdb_coordinator_topology_updates_total",
        "Total topology updates received",
        null,
    );

    /// Topology refresh errors
    pub var coordinator_topology_refresh_errors_total: Counter = Counter.init(
        "archerdb_coordinator_topology_refresh_errors_total",
        "Topology refresh errors",
        null,
    );

    // Fan-out metrics (Task 5.5)
    /// Fan-out shards queried (last operation)
    pub var coordinator_fanout_shards_queried: Gauge = Gauge.init(
        "archerdb_coordinator_fanout_shards_queried",
        "Number of shards queried in last fan-out operation",
        null,
    );

    /// Partial result count
    pub var coordinator_fanout_partial_total: Counter = Counter.init(
        "archerdb_coordinator_fanout_partial_total",
        "Fan-out queries returning partial results",
        null,
    );

    // ========================================================================
    // Index Resize Metrics
    // ========================================================================

    /// Index resize status (0=idle, 1=in_progress, 2=completing, 3=aborting)
    pub var index_resize_status: Gauge = Gauge.init(
        "archerdb_index_resize_status",
        "Index resize status (0=idle, 1=in_progress, 2=completing, 3=aborting)",
        null,
    );

    /// Index resize progress (0.0 to 1.0, stored as fixed-point * 10000)
    pub var index_resize_progress: Gauge = Gauge.init(
        "archerdb_index_resize_progress",
        "Index resize progress (0.0 to 1.0)",
        null,
    );

    /// Entries migrated during resize
    pub var index_resize_entries_migrated: Gauge = Gauge.init(
        "archerdb_index_resize_entries_migrated",
        "Total entries migrated during resize",
        null,
    );

    /// Total entries to migrate
    pub var index_resize_entries_total: Gauge = Gauge.init(
        "archerdb_index_resize_entries_total",
        "Total entries to migrate during resize",
        null,
    );

    /// Source table size (buckets)
    pub var index_resize_source_size: Gauge = Gauge.init(
        "archerdb_index_resize_source_size",
        "Source table size in buckets",
        null,
    );

    /// Target table size (buckets)
    pub var index_resize_target_size: Gauge = Gauge.init(
        "archerdb_index_resize_target_size",
        "Target table size in buckets",
        null,
    );

    /// Resize operations total
    pub var index_resize_operations_total: Counter = Counter.init(
        "archerdb_index_resize_operations_total",
        "Total index resize operations completed",
        null,
    );

    /// Resize aborts total
    pub var index_resize_aborts_total: Counter = Counter.init(
        "archerdb_index_resize_aborts_total",
        "Total index resize operations aborted",
        null,
    );

    // ========================================================================
    // Membership Metrics
    // ========================================================================

    /// Current membership state (0=stable, 1=joint, 2=transitioning)
    pub var membership_state: Gauge = Gauge.init(
        "archerdb_membership_state",
        "Current membership state (0=stable, 1=joint, 2=transitioning)",
        null,
    );

    /// Number of voting members
    pub var membership_voters_count: Gauge = Gauge.init(
        "archerdb_membership_voters_count",
        "Number of voting members in cluster",
        null,
    );

    /// Number of learner members
    pub var membership_learners_count: Gauge = Gauge.init(
        "archerdb_membership_learners_count",
        "Number of learner members in cluster",
        null,
    );

    /// Total membership changes
    pub var membership_changes_total: Counter = Counter.init(
        "archerdb_membership_changes_total",
        "Total membership configuration changes",
        null,
    );

    /// Membership transitions in progress
    pub var membership_transitions_in_progress: Gauge = Gauge.init(
        "archerdb_membership_transitions_in_progress",
        "Number of membership transitions currently in progress",
        null,
    );

    /// Membership transition progress (0.0 to 1.0, stored as * 10000)
    pub var membership_transition_progress: Gauge = Gauge.init(
        "archerdb_membership_transition_progress",
        "Progress of current membership transition (0.0 to 1.0)",
        null,
    );

    /// Learner promotion total
    pub var membership_promotions_total: Counter = Counter.init(
        "archerdb_membership_promotions_total",
        "Total learner to voter promotions",
        null,
    );

    /// Node removal total
    pub var membership_removals_total: Counter = Counter.init(
        "archerdb_membership_removals_total",
        "Total node removals from cluster",
        null,
    );

    // ========================================================================
    // S2 Index Metrics (MET-09)
    // ========================================================================

    /// Total S2 cells indexed
    pub var s2_cells_total: Counter = Counter.init(
        "archerdb_s2_cells_total",
        "Total S2 cells indexed",
        null,
    );

    /// S2 cell counts by level (levels 0-30)
    /// We track a subset of commonly used levels: 0, 10, 15, 20, 25, 30
    pub const s2_tracked_levels: [6]u8 = .{ 0, 10, 15, 20, 25, 30 };
    pub var s2_cell_level_counts: [6]std.atomic.Value(u64) = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    /// S2 coverage ratio (indexed area / total area, scaled by 10000)
    pub var s2_coverage_ratio: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    /// Record S2 cell indexing
    pub fn recordS2CellIndexed(level: u8) void {
        s2_cells_total.inc();
        // Find the closest tracked level bucket
        for (s2_tracked_levels, 0..) |tracked_level, i| {
            if (level <= tracked_level) {
                _ = s2_cell_level_counts[i].fetchAdd(1, .monotonic);
                break;
            }
        }
    }

    /// Update S2 coverage ratio
    /// ratio: f64 value between 0.0 and 1.0
    pub fn updateS2CoverageRatio(ratio: f64) void {
        const scaled: u32 = @intFromFloat(@min(1.0, @max(0.0, ratio)) * 10000.0);
        s2_coverage_ratio.store(scaled, .monotonic);
    }

    // ========================================================================
    // S2 Covering Cache Metrics (14-02)
    // ========================================================================

    /// S2 covering cache hits total
    pub var s2_covering_cache_hits_total: Counter = Counter.init(
        "archerdb_s2_covering_cache_hits_total",
        "Total S2 covering cache hits",
        null,
    );

    /// S2 covering cache misses total
    pub var s2_covering_cache_misses_total: Counter = Counter.init(
        "archerdb_s2_covering_cache_misses_total",
        "Total S2 covering cache misses",
        null,
    );

    // ========================================================================
    // Query Performance Metrics (QUERY-04)
    // ========================================================================

    /// Query latency breakdown metrics (QUERY-04)
    /// Provides per-phase latency histograms for performance diagnosis.
    pub var query_latency_breakdown: query.QueryLatencyBreakdown = query.QueryLatencyBreakdown.init();

    /// Spatial index statistics for query planning insights.
    /// Provides RAM index metrics and S2 covering statistics.
    pub var spatial_index_stats: query.SpatialIndexStats = query.SpatialIndexStats.init();

    // ========================================================================
    // Extended Memory Metrics (MET-07)
    // ========================================================================

    /// RAM index memory usage in bytes
    pub var memory_ram_index_bytes: Gauge = Gauge.init(
        "archerdb_memory_ram_index_bytes",
        "RAM index memory usage in bytes",
        null,
    );

    /// Grid cache memory usage in bytes
    pub var memory_cache_bytes: Gauge = Gauge.init(
        "archerdb_memory_cache_bytes",
        "Grid cache memory usage in bytes",
        null,
    );

    // ========================================================================
    // Connection Pool Metrics (MET-08)
    // ========================================================================

    /// Total connections accepted
    pub var connections_total: Counter = Counter.init(
        "archerdb_connections_total",
        "Total connections accepted",
        null,
    );

    /// Connection errors
    pub var connections_errors_total: Counter = Counter.init(
        "archerdb_connections_errors_total",
        "Total connection errors",
        null,
    );

    // ========================================================================
    // LSM Compaction Extended Metrics (MET-06)
    // ========================================================================

    /// Compaction duration histogram (separate from latency for clarity)
    pub var compaction_duration_seconds: LatencyHistogram = latencyHistogram(
        "archerdb_compaction_duration_seconds",
        "Compaction operation duration histogram",
        null,
    );

    /// Total bytes read during compaction
    pub var compaction_bytes_read_total: Counter = Counter.init(
        "archerdb_compaction_bytes_read_total",
        "Total bytes read during compaction",
        null,
    );

    /// Total bytes written during compaction
    pub var compaction_bytes_written_total: Counter = Counter.init(
        "archerdb_compaction_bytes_written_total",
        "Total bytes written during compaction",
        null,
    );

    /// Current compaction level being processed (0-6)
    pub var compaction_current_level: Gauge = Gauge.init(
        "archerdb_compaction_current_level",
        "Current compaction level being processed",
        null,
    );

    /// Total compaction operations completed
    pub var compaction_operations_total: Counter = Counter.init(
        "archerdb_compaction_total",
        "Total compaction operations completed",
        null,
    );

    /// Record a compaction operation with detailed metrics
    pub fn recordCompactionWithDetails(
        level: u8,
        bytes_read: u64,
        bytes_written: u64,
        duration_ns: u64,
    ) void {
        compaction_operations_total.inc();
        compaction_bytes_read_total.add(bytes_read);
        compaction_bytes_written_total.add(bytes_written);
        compaction_current_level.set(@intCast(level));
        if (duration_ns > 0) {
            compaction_duration_seconds.observeNs(duration_ns);
        }
        // Also record in legacy metrics for compatibility
        recordCompaction(level, bytes_written, duration_ns);
    }

    // ========================================================================
    // Checkpoint Metrics
    // ========================================================================

    /// Checkpoint duration histogram
    pub var checkpoint_duration_seconds: LatencyHistogram = latencyHistogram(
        "archerdb_checkpoint_duration_seconds",
        "Checkpoint operation duration histogram",
        null,
    );

    /// Total checkpoints completed
    pub var checkpoint_total: Counter = Counter.init(
        "archerdb_checkpoint_total",
        "Total checkpoints completed",
        null,
    );

    /// Record a checkpoint operation
    pub fn recordCheckpoint(duration_ns: u64) void {
        checkpoint_total.inc();
        if (duration_ns > 0) {
            checkpoint_duration_seconds.observeNs(duration_ns);
        }
    }

    // ========================================================================
    // Build Info Metric
    // ========================================================================

    /// Build info metric with version and commit labels
    /// This is a constant gauge that always equals 1, with metadata in labels
    pub var build_info: Gauge = Gauge.init(
        "archerdb_build_info",
        "ArcherDB build information",
        "version=\"0.0.1\",commit=\"unknown\"",
    );

    /// Build version (set at startup)
    pub var build_version: [32]u8 = [_]u8{0} ** 32;
    pub var build_version_len: u8 = 7; // "0.0.1" default

    /// Build commit hash (set at startup)
    pub var build_commit: [64]u8 = [_]u8{0} ** 64;
    pub var build_commit_len: u8 = 7; // "unknown" default

    /// Access cluster metrics for pool/shed/routing subsystems.
    pub fn clusterMetrics() *cluster.ClusterMetrics {
        return &cluster_metrics;
    }

    /// Initialize build info with actual version and commit
    pub fn initBuildInfo(version: []const u8, commit: []const u8) void {
        const v_len = @min(version.len, build_version.len);
        for (0..v_len) |i| {
            build_version[i] = version[i];
        }
        build_version_len = @intCast(v_len);

        const c_len = @min(commit.len, build_commit.len);
        for (0..c_len) |i| {
            build_commit[i] = commit[i];
        }
        build_commit_len = @intCast(c_len);
    }

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

        // Cluster metrics (pool, shedding, routing)
        try cluster_metrics.format(writer);
        try writer.writeAll("\n");

        // Resource metrics
        try memory_allocated_bytes.format(writer);
        try memory_used_bytes.format(writer);
        try data_file_size_bytes.format(writer);
        try index_entries.format(writer);
        try index_entries_total.format(writer);
        try index_memory_bytes.format(writer);
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

        // TTL expired ratio per level (per add-ttl-aware-compaction)
        try writer.writeAll("# HELP archerdb_lsm_ttl_expired_ratio " ++
            "Estimated expired data ratio per level (0.0-1.0)\n");
        try writer.writeAll("# TYPE archerdb_lsm_ttl_expired_ratio gauge\n");
        for (lsm_ttl_expired_ratio_by_level, 0..) |scaled_ratio_atomic, level| {
            const scaled_ratio = scaled_ratio_atomic.load(.monotonic);
            const ratio_f64: f64 = @as(f64, @floatFromInt(scaled_ratio)) / 10000.0;
            try writer.print("archerdb_lsm_ttl_expired_ratio{{level=\"{d}\"}} {d:.4}\n", .{
                level,
                ratio_f64,
            });
        }
        try writer.writeAll("\n");

        // Per-level byte estimates (per add-per-level-ttl-stats)
        try writer.writeAll("# HELP archerdb_lsm_bytes_by_level " ++
            "Estimated total bytes per LSM level\n");
        try writer.writeAll("# TYPE archerdb_lsm_bytes_by_level gauge\n");
        for (lsm_bytes_by_level, 0..) |bytes_atomic, level| {
            const bytes = bytes_atomic.load(.monotonic);
            try writer.print("archerdb_lsm_bytes_by_level{{level=\"{d}\"}} {d}\n", .{
                level,
                bytes,
            });
        }
        try writer.writeAll("\n");

        // Per-level expired byte estimates (per add-per-level-ttl-stats)
        try writer.writeAll("# HELP archerdb_lsm_ttl_expired_bytes_by_level " ++
            "Estimated expired bytes per LSM level\n");
        try writer.writeAll("# TYPE archerdb_lsm_ttl_expired_bytes_by_level gauge\n");
        for (lsm_ttl_expired_bytes_by_level, 0..) |bytes_atomic, level| {
            const bytes = bytes_atomic.load(.monotonic);
            try writer.print("archerdb_lsm_ttl_expired_bytes_by_level{{level=\"{d}\"}} {d}\n", .{
                level,
                bytes,
            });
        }
        try writer.writeAll("\n");

        // TTL Extension metrics
        try writer.writeAll(
            "# HELP archerdb_ttl_extensions_total Total TTL extensions performed\n",
        );
        try writer.writeAll("# TYPE archerdb_ttl_extensions_total counter\n");
        const extensions_total = ttl_extensions_total.load(.monotonic);
        try writer.print("archerdb_ttl_extensions_total {d}\n", .{extensions_total});
        try writer.writeAll("\n");

        try writer.writeAll(
            "# HELP archerdb_ttl_extensions_skipped_total TTL extensions skipped by reason\n",
        );
        try writer.writeAll("# TYPE archerdb_ttl_extensions_skipped_total counter\n");
        const skipped_cooldown = ttl_extensions_skipped_cooldown.load(.monotonic);
        const skipped_max_ttl = ttl_extensions_skipped_max_ttl.load(.monotonic);
        const skipped_max_count = ttl_extensions_skipped_max_count.load(.monotonic);
        const skipped_no_auto = ttl_ext_skipped_no_auto.load(.monotonic);
        const skip_fmt = "archerdb_ttl_extensions_skipped_total{{reason=\"{s}\"}} {d}\n";
        try writer.print(skip_fmt, .{ "cooldown", skipped_cooldown });
        try writer.print(skip_fmt, .{ "max_ttl", skipped_max_ttl });
        try writer.print(skip_fmt, .{ "max_count", skipped_max_count });
        try writer.print(skip_fmt, .{ "no_auto_extend", skipped_no_auto });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_ttl_extension_amount_seconds_sum " ++
            "Sum of TTL extension amounts in seconds\n");
        try writer.writeAll("# TYPE archerdb_ttl_extension_amount_seconds_sum counter\n");
        const extension_sum = ttl_extension_amount_seconds_sum.load(.monotonic);
        try writer.print("archerdb_ttl_extension_amount_seconds_sum {d}\n", .{extension_sum});
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
        // Multi-Region Metrics
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
            try writer.print(
                "archerdb_replication_lag_ops {d}\n",
                .{replication_lag_ops.load(.monotonic)},
            );
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
            try writer.print(
                "archerdb_replication_apply_rate {d}\n",
                .{replication_apply_rate.load(.monotonic)},
            );
            try writer.writeAll("\n");
        }

        // ====================================================================
        // Spillover Metrics (Replication Durability)
        // ====================================================================

        // Only output spillover metrics if spillover is active or has data
        const spillover_bytes = replication_spillover_bytes.load(.monotonic);
        const spillover_state = replication_state.load(.monotonic);

        if (spillover_bytes > 0 or spillover_state > 0) {
            try writer.writeAll("# HELP archerdb_replication_spillover_bytes " ++
                "Bytes currently on disk spillover\n");
            try writer.writeAll("# TYPE archerdb_replication_spillover_bytes gauge\n");
            try writer.print("archerdb_replication_spillover_bytes {d}\n", .{spillover_bytes});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_replication_spillover_segments " ++
                "Number of spillover segments on disk\n");
            try writer.writeAll("# TYPE archerdb_replication_spillover_segments gauge\n");
            try writer.print("archerdb_replication_spillover_segments {d}\n", .{
                replication_spillover_segments.load(.monotonic),
            });
            try writer.writeAll("\n");
        }

        // Always output replication state (0=healthy, 1=degraded, 2=failed)
        try writer.writeAll("# HELP archerdb_replication_state " ++
            "Replication state: 0=healthy, 1=degraded (spillover active), 2=failed\n");
        try writer.writeAll("# TYPE archerdb_replication_state gauge\n");
        try writer.print("archerdb_replication_state {d}\n", .{spillover_state});
        try writer.writeAll("\n");

        // ====================================================================
        // Sharding Metrics
        // ====================================================================

        try sharding_strategy.format(writer);
        try shard_strategy.format(writer);
        try writer.writeAll("\n");

        try shard_lookup_latency_modulo.format(writer);
        try shard_lookup_latency_virtual_ring.format(writer);
        try shard_lookup_latency_jump_hash.format(writer);
        try shard_lookup_latency_spatial.format(writer);
        try writer.writeAll("\n");

        try query_shards_queried_radius.format(writer);
        try query_shards_queried_polygon.format(writer);
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_shard_count Number of active shards\n");
        try writer.writeAll("# TYPE archerdb_shard_count gauge\n");
        const active_shards = shard_count.load(.monotonic);
        try writer.print("archerdb_shard_count {d}\n", .{active_shards});
        try writer.writeAll("\n");

        // Per-shard metrics (only output for active shards)
        if (active_shards > 0) {
            const shard_fmt = "archerdb_{s}{{shard=\"{d}\"}} {d}\n";

            try writer.writeAll("# HELP archerdb_shard_entity_count Entities per shard\n");
            try writer.writeAll("# TYPE archerdb_shard_entity_count gauge\n");
            for (0..@min(active_shards, max_shards)) |shard| {
                const count = shard_entity_count[shard].load(.monotonic);
                try writer.print(shard_fmt, .{ "shard_entity_count", shard, count });
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_shard_size_bytes Bytes per shard\n");
            try writer.writeAll("# TYPE archerdb_shard_size_bytes gauge\n");
            for (0..@min(active_shards, max_shards)) |shard| {
                const size = shard_size_bytes[shard].load(.monotonic);
                try writer.print(shard_fmt, .{ "shard_size_bytes", shard, size });
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_shard_write_rate Write ops/sec per shard\n");
            try writer.writeAll("# TYPE archerdb_shard_write_rate gauge\n");
            for (0..@min(active_shards, max_shards)) |shard| {
                const rate = shard_write_rate[shard].load(.monotonic);
                try writer.print(shard_fmt, .{ "shard_write_rate", shard, rate });
            }
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_shard_read_rate Read ops/sec per shard\n");
            try writer.writeAll("# TYPE archerdb_shard_read_rate gauge\n");
            for (0..@min(active_shards, max_shards)) |shard| {
                const rate = shard_read_rate[shard].load(.monotonic);
                try writer.print(shard_fmt, .{ "shard_read_rate", shard, rate });
            }
            try writer.writeAll("\n");

            // Shard balance metrics
            try writer.writeAll("# HELP archerdb_shard_balance_variance " ++
                "Shard load variance (std dev / mean)\n");
            try writer.writeAll("# TYPE archerdb_shard_balance_variance gauge\n");
            const variance_scaled = shard_balance_variance.load(.monotonic);
            const variance: f64 = @as(f64, @floatFromInt(variance_scaled)) / 10000.0;
            try writer.print("archerdb_shard_balance_variance {d:.4}\n", .{variance});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_shard_hottest_ratio " ++
                "Hottest shard load / average\n");
            try writer.writeAll("# TYPE archerdb_shard_hottest_ratio gauge\n");
            const hottest_scaled = shard_hottest_ratio.load(.monotonic);
            const hottest: f64 = @as(f64, @floatFromInt(hottest_scaled)) / 10000.0;
            try writer.print("archerdb_shard_hottest_ratio {d:.4}\n", .{hottest});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_shard_coldest_ratio " ++
                "Coldest shard load / average\n");
            try writer.writeAll("# TYPE archerdb_shard_coldest_ratio gauge\n");
            const coldest_scaled = shard_coldest_ratio.load(.monotonic);
            const coldest: f64 = @as(f64, @floatFromInt(coldest_scaled)) / 10000.0;
            try writer.print("archerdb_shard_coldest_ratio {d:.4}\n", .{coldest});
            try writer.writeAll("\n");
        }

        try writer.writeAll("# HELP archerdb_shard_hot_id Shard id with the highest hot score (-1 if none)\n");
        try writer.writeAll("# TYPE archerdb_shard_hot_id gauge\n");
        const hot_id = shard_hot_id.get();
        try writer.print("archerdb_shard_hot_id {d}\n", .{hot_id});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_shard_hot_score Composite hot shard score (0-100)\n");
        try writer.writeAll("# TYPE archerdb_shard_hot_score gauge\n");
        const hot_score = @as(f64, @floatFromInt(shard_hot_score.get()));
        try writer.print("archerdb_shard_hot_score {d:.2}\n", .{hot_score});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_shard_rebalance_needed " ++
            "Whether shard rebalancing is recommended (1=yes, 0=no)\n");
        try writer.writeAll("# TYPE archerdb_shard_rebalance_needed gauge\n");
        const rebalance_needed = shard_rebalance_needed.get();
        try writer.print("archerdb_shard_rebalance_needed {d}\n", .{rebalance_needed});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_shard_rebalance_active_moves " ++
            "Active shard rebalance migration slots\n");
        try writer.writeAll("# TYPE archerdb_shard_rebalance_active_moves gauge\n");
        const active_moves = shard_rebalance_active_moves.get();
        try writer.print("archerdb_shard_rebalance_active_moves {d}\n", .{active_moves});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_shard_rebalance_cooldown_seconds " ++
            "Remaining rebalance cooldown time in seconds\n");
        try writer.writeAll("# TYPE archerdb_shard_rebalance_cooldown_seconds gauge\n");
        const cooldown_seconds = shard_rebalance_cooldown_seconds.get();
        try writer.print("archerdb_shard_rebalance_cooldown_seconds {d}\n", .{cooldown_seconds});
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
            try writer.print(
                "archerdb_resharding_entities_exported {d}\n",
                .{resharding_entities_exported.load(.monotonic)},
            );
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_entities_imported " ++
                "Entities imported during resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_entities_imported counter\n");
            try writer.print(
                "archerdb_resharding_entities_imported {d}\n",
                .{resharding_entities_imported.load(.monotonic)},
            );
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_source_shards " ++
                "Source shard count before resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_source_shards gauge\n");
            try writer.print(
                "archerdb_resharding_source_shards {d}\n",
                .{resharding_source_shards.load(.monotonic)},
            );
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_target_shards " ++
                "Target shard count for resharding\n");
            try writer.writeAll("# TYPE archerdb_resharding_target_shards gauge\n");
            try writer.print(
                "archerdb_resharding_target_shards {d}\n",
                .{resharding_target_shards.load(.monotonic)},
            );
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

        // Online resharding metrics
        const reshard_mode = resharding_mode.load(.monotonic);
        if (reshard_mode > 0) {
            try writer.writeAll("# HELP archerdb_resharding_mode " ++
                "Resharding mode (0=none, 1=offline, 2=online)\n");
            try writer.writeAll("# TYPE archerdb_resharding_mode gauge\n");
            try writer.print("archerdb_resharding_mode {d}\n", .{reshard_mode});
            try writer.writeAll("\n");

            try writer.writeAll("# HELP archerdb_resharding_dual_write " ++
                "Dual-write mode enabled (1=true, 0=false)\n");
            try writer.writeAll("# TYPE archerdb_resharding_dual_write gauge\n");
            try writer.print(
                "archerdb_resharding_dual_write {d}\n",
                .{resharding_dual_write_enabled.load(.monotonic)},
            );
            try writer.writeAll("\n");

            const migration_rate = resharding_migration_rate.load(.monotonic);
            if (migration_rate > 0) {
                try writer.writeAll("# HELP archerdb_resharding_migration_rate " ++
                    "Migration rate (entities per second)\n");
                try writer.writeAll("# TYPE archerdb_resharding_migration_rate gauge\n");
                const rate_f: f64 = @as(f64, @floatFromInt(migration_rate)) / 100.0;
                try writer.print("archerdb_resharding_migration_rate {d:.2}\n", .{rate_f});
                try writer.writeAll("\n");
            }

            try writer.writeAll("# HELP archerdb_resharding_batches_processed " ++
                "Number of migration batches processed\n");
            try writer.writeAll("# TYPE archerdb_resharding_batches_processed counter\n");
            try writer.print(
                "archerdb_resharding_batches_processed {d}\n",
                .{resharding_batches_processed.load(.monotonic)},
            );
            try writer.writeAll("\n");

            const migration_fail_count = resharding_migration_failures.load(.monotonic);
            if (migration_fail_count > 0) {
                try writer.writeAll("# HELP archerdb_resharding_migration_failures " ++
                    "Number of failed migration attempts\n");
                try writer.writeAll("# TYPE archerdb_resharding_migration_failures counter\n");
                try writer.print(
                    "archerdb_resharding_migration_failures {d}\n",
                    .{migration_fail_count},
                );
                try writer.writeAll("\n");
            }

            const eta = resharding_eta_seconds.load(.monotonic);
            if (eta > 0) {
                try writer.writeAll("# HELP archerdb_resharding_eta_seconds " ++
                    "Estimated time to completion (seconds)\n");
                try writer.writeAll("# TYPE archerdb_resharding_eta_seconds gauge\n");
                try writer.print("archerdb_resharding_eta_seconds {d}\n", .{eta});
                try writer.writeAll("\n");
            }
        }

        try scatter_gather_queries_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Tiering Metrics (Hot-Warm-Cold)
        // ====================================================================

        const tier_fmt = "archerdb_{s}{{tier=\"{s}\"}} {d}\n";

        try writer.writeAll("# HELP archerdb_tier_entity_count Entities per tier\n");
        try writer.writeAll("# TYPE archerdb_tier_entity_count gauge\n");
        const ent_hot = tier_entity_count_hot.load(.monotonic);
        const ent_warm = tier_entity_count_warm.load(.monotonic);
        const ent_cold = tier_entity_count_cold.load(.monotonic);
        try writer.print(tier_fmt, .{ "tier_entity_count", "hot", ent_hot });
        try writer.print(tier_fmt, .{ "tier_entity_count", "warm", ent_warm });
        try writer.print(tier_fmt, .{ "tier_entity_count", "cold", ent_cold });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_tier_size_bytes Bytes per tier\n");
        try writer.writeAll("# TYPE archerdb_tier_size_bytes gauge\n");
        const sz_hot = tier_size_bytes_hot.load(.monotonic);
        const sz_warm = tier_size_bytes_warm.load(.monotonic);
        const sz_cold = tier_size_bytes_cold.load(.monotonic);
        try writer.print(tier_fmt, .{ "tier_size_bytes", "hot", sz_hot });
        try writer.print(tier_fmt, .{ "tier_size_bytes", "warm", sz_warm });
        try writer.print(tier_fmt, .{ "tier_size_bytes", "cold", sz_cold });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_tier_access_rate Access rate per tier\n");
        try writer.writeAll("# TYPE archerdb_tier_access_rate gauge\n");
        const ar_hot = tier_access_rate_hot.load(.monotonic);
        const ar_warm = tier_access_rate_warm.load(.monotonic);
        const ar_cold = tier_access_rate_cold.load(.monotonic);
        try writer.print(tier_fmt, .{ "tier_access_rate", "hot", ar_hot });
        try writer.print(tier_fmt, .{ "tier_access_rate", "warm", ar_warm });
        try writer.print(tier_fmt, .{ "tier_access_rate", "cold", ar_cold });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_tiering_migrations_total Tier migrations\n");
        try writer.writeAll("# TYPE archerdb_tiering_migrations_total counter\n");
        const mig_fmt = "archerdb_tiering_migrations_total" ++
            "{{direction=\"{s}\",from=\"{s}\",to=\"{s}\"}} {d}\n";
        const mig_hw = tiering_migrations_hot_to_warm.load(.monotonic);
        const mig_wc = tiering_migrations_warm_to_cold.load(.monotonic);
        const mig_cw = tiering_migrations_cold_to_warm.load(.monotonic);
        const mig_wh = tiering_migrations_warm_to_hot.load(.monotonic);
        try writer.print(mig_fmt, .{ "demote", "hot", "warm", mig_hw });
        try writer.print(mig_fmt, .{ "demote", "warm", "cold", mig_wc });
        try writer.print(mig_fmt, .{ "promote", "cold", "warm", mig_cw });
        try writer.print(mig_fmt, .{ "promote", "warm", "hot", mig_wh });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_tiering_queue_depth Pending migrations\n");
        try writer.writeAll("# TYPE archerdb_tiering_queue_depth gauge\n");
        const q_demote = tiering_queue_depth_demote.load(.monotonic);
        const q_promote = tiering_queue_depth_promote.load(.monotonic);
        const q_fmt = "archerdb_tiering_queue_depth{{direction=\"{s}\"}} {d}\n";
        try writer.print(q_fmt, .{ "demote", q_demote });
        try writer.print(q_fmt, .{ "promote", q_promote });
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_tiering_migration_errors_total Errors\n");
        try writer.writeAll("# TYPE archerdb_tiering_migration_errors_total counter\n");
        const mig_err = tiering_migration_errors_total.load(.monotonic);
        try writer.print("archerdb_tiering_migration_errors_total {d}\n", .{mig_err});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_cold_tier_fetches_total Cold tier fetches\n");
        try writer.writeAll("# TYPE archerdb_cold_tier_fetches_total counter\n");
        const cold_fetches = cold_tier_fetches_total.load(.monotonic);
        try writer.print("archerdb_cold_tier_fetches_total {d}\n", .{cold_fetches});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_cold_tier_fetch_bytes_total Cold fetched\n");
        try writer.writeAll("# TYPE archerdb_cold_tier_fetch_bytes_total counter\n");
        const cold_bytes = cold_tier_fetch_bytes_total.load(.monotonic);
        try writer.print("archerdb_cold_tier_fetch_bytes_total {d}\n", .{cold_bytes});
        try writer.writeAll("\n");

        // ====================================================================
        // Encryption Metrics
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
        try writer.print(
            "archerdb_encryption_rotation_status {d}\n",
            .{encryption_rotation_status.load(.monotonic)},
        );
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

        // AES-NI Hardware Acceleration Metrics
        try encryption_aesni_available.format(writer);
        try encryption_using_software.format(writer);
        try encryption_cipher_version.format(writer);
        try encryption_throughput_encrypt.format(writer);
        try encryption_throughput_decrypt.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Coordinator Mode Metrics
        // ====================================================================

        // Connection metrics
        try coordinator_connections_active.format(writer);
        try coordinator_connections_total.format(writer);
        try coordinator_connections_rejected_total.format(writer);
        try writer.writeAll("\n");

        // Query metrics
        try coordinator_queries_single.format(writer);
        try coordinator_queries_fanout.format(writer);
        try coordinator_query_latency.format(writer);
        try coordinator_query_errors_timeout.format(writer);
        try coordinator_query_errors_unavailable.format(writer);
        try writer.writeAll("\n");

        // Shard metrics
        try coordinator_shards_total.format(writer);
        try coordinator_shards_healthy.format(writer);
        try coordinator_shard_failures_total.format(writer);
        try writer.writeAll("\n");

        // Topology metrics
        try coordinator_topology_version.format(writer);
        try coordinator_topology_updates_total.format(writer);
        try coordinator_topology_refresh_errors_total.format(writer);
        try writer.writeAll("\n");

        // Fan-out metrics
        try coordinator_fanout_shards_queried.format(writer);
        try coordinator_fanout_partial_total.format(writer);
        try writer.writeAll("\n");

        // Index resize metrics
        try index_resize_status.format(writer);
        try index_resize_progress.format(writer);
        try index_resize_entries_migrated.format(writer);
        try index_resize_entries_total.format(writer);
        try index_resize_source_size.format(writer);
        try index_resize_target_size.format(writer);
        try index_resize_operations_total.format(writer);
        try index_resize_aborts_total.format(writer);
        try writer.writeAll("\n");

        // Membership metrics
        try membership_state.format(writer);
        try membership_voters_count.format(writer);
        try membership_learners_count.format(writer);
        try membership_changes_total.format(writer);
        try membership_transitions_in_progress.format(writer);
        try membership_transition_progress.format(writer);
        try membership_promotions_total.format(writer);
        try membership_removals_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // S2 Index Metrics (MET-09)
        // ====================================================================

        try s2_cells_total.format(writer);
        try writer.writeAll("\n");

        // S2 cell counts by level
        try writer.writeAll("# HELP archerdb_s2_cell_level Cell counts by S2 level\n");
        try writer.writeAll("# TYPE archerdb_s2_cell_level gauge\n");
        for (s2_tracked_levels, 0..) |level, i| {
            const count = s2_cell_level_counts[i].load(.monotonic);
            try writer.print("archerdb_s2_cell_level{{level=\"{d}\"}} {d}\n", .{ level, count });
        }
        try writer.writeAll("\n");

        // S2 coverage ratio
        try writer.writeAll("# HELP archerdb_s2_coverage_ratio Coverage ratio of indexed area\n");
        try writer.writeAll("# TYPE archerdb_s2_coverage_ratio gauge\n");
        const coverage_scaled = s2_coverage_ratio.load(.monotonic);
        const coverage_f: f64 = @as(f64, @floatFromInt(coverage_scaled)) / 10000.0;
        try writer.print("archerdb_s2_coverage_ratio {d:.4}\n", .{coverage_f});
        try writer.writeAll("\n");

        // S2 covering cache metrics (14-02)
        try s2_covering_cache_hits_total.format(writer);
        try s2_covering_cache_misses_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Extended Memory Metrics (MET-07)
        // ====================================================================

        try memory_ram_index_bytes.format(writer);
        try memory_cache_bytes.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Connection Pool Metrics (MET-08)
        // ====================================================================

        try connections_total.format(writer);
        try connections_errors_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // LSM Compaction Extended Metrics (MET-06)
        // ====================================================================

        try compaction_duration_seconds.format(writer);
        try compaction_bytes_read_total.format(writer);
        try compaction_bytes_written_total.format(writer);
        try compaction_current_level.format(writer);
        try compaction_operations_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Storage Amplification Metrics (12-02)
        // ====================================================================

        try storage.format_all(writer);

        // ====================================================================
        // RAM Index Metrics (13-03)
        // ====================================================================

        try index.format_all(writer);

        // ====================================================================
        // Query Performance Metrics (14-03)
        // ====================================================================

        try query_latency_breakdown.toPrometheus(writer);
        try spatial_index_stats.toPrometheus(writer);

        // ====================================================================
        // Checkpoint Metrics
        // ====================================================================

        try checkpoint_duration_seconds.format(writer);
        try checkpoint_total.format(writer);
        try writer.writeAll("\n");

        // ====================================================================
        // Build Info Metric
        // ====================================================================

        // Format build_info with dynamic labels
        try writer.writeAll("# HELP archerdb_build_info ArcherDB build information\n");
        try writer.writeAll("# TYPE archerdb_build_info gauge\n");
        const version_str = build_version[0..build_version_len];
        const commit_str = build_commit[0..build_commit_len];
        try writer.print(
            "archerdb_build_info{{version=\"{s}\",commit=\"{s}\"}} 1\n",
            .{ version_str, commit_str },
        );
        try writer.writeAll("\n");
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
        idx_memory_bytes: u64,
    ) void {
        memory_allocated_bytes.set(@intCast(mem_allocated));
        memory_used_bytes.set(@intCast(mem_used));
        data_file_size_bytes.set(@intCast(storage_size));
        index_entries.set(@intCast(idx_entries));
        index_entries_total.set(@intCast(idx_entries));
        index_capacity.set(@intCast(idx_capacity));
        index_memory_bytes.set(@intCast(idx_memory_bytes));

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

    /// Update TTL expired ratio for a specific level.
    /// ratio: f64 value between 0.0 and 1.0
    /// level: LSM level (0-6)
    pub fn updateTtlExpiredRatio(level: u8, ratio: f64) void {
        if (level < lsm_ttl_expired_ratio_by_level.len) {
            // Scale ratio to integer (0.0-1.0 -> 0-10000)
            const scaled_ratio: u32 = @intFromFloat(@min(1.0, @max(0.0, ratio)) * 10000.0);
            lsm_ttl_expired_ratio_by_level[level].store(scaled_ratio, .monotonic);
        }
    }

    /// Update level byte estimates.
    /// level: LSM level (0-6)
    /// total_bytes: Estimated total bytes in level
    /// expired_bytes: Estimated expired bytes in level
    pub fn updateLevelBytes(level: u8, total_bytes: u64, expired_bytes: u64) void {
        if (level < lsm_bytes_by_level.len) {
            lsm_bytes_by_level[level].store(total_bytes, .monotonic);
            lsm_ttl_expired_bytes_by_level[level].store(expired_bytes, .monotonic);
        }
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

test "Histogram: extended percentiles" {
    var hist = latencyHistogram("test_latency", "Test latency histogram", null);

    // Add observations across buckets
    hist.observe(0.0001); // 100us
    hist.observe(0.001); // 1ms
    hist.observe(0.005); // 5ms
    hist.observe(0.01); // 10ms
    hist.observe(0.1); // 100ms (outlier)

    const stats = hist.getExtendedStats();
    try std.testing.expectEqual(@as(u64, 5), stats.count);
    try std.testing.expect(stats.p50 > 0);
    try std.testing.expect(stats.p99 >= stats.p50);
    try std.testing.expect(stats.mean > 0);
    try std.testing.expect(stats.sum > 0);
}

test "Histogram: percentile calculation" {
    var hist = latencyHistogram("test_latency", "Test percentile", null);

    // All observations in the same bucket (1ms)
    for (0..100) |_| {
        hist.observe(0.001);
    }

    const stats = hist.getExtendedStats();
    try std.testing.expectEqual(@as(u64, 100), stats.count);
    // All percentiles should be in the 1ms bucket
    try std.testing.expectEqual(@as(f64, 0.001), stats.p50);
    try std.testing.expectEqual(@as(f64, 0.001), stats.p99);
}

test "Histogram: empty histogram stats" {
    var hist = latencyHistogram("test_latency", "Test empty", null);

    const stats = hist.getExtendedStats();
    try std.testing.expectEqual(@as(u64, 0), stats.count);
    try std.testing.expectEqual(@as(f64, 0), stats.p50);
    try std.testing.expectEqual(@as(f64, 0), stats.mean);
}

test "Histogram: extended stats format" {
    var hist = latencyHistogram("test_latency", "Test format", null);
    hist.observe(0.001); // 1ms
    hist.observe(0.01); // 10ms

    const stats = hist.getExtendedStats();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try stats.format(fbs.writer());
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "P50=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "P99=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mean=") != null);
}

test "Histogram: extended stats diagnose" {
    const healthy_stats = ExtendedStats{
        .p50 = 0.001, // 1ms
        .p75 = 0.002,
        .p90 = 0.003,
        .p95 = 0.004,
        .p99 = 0.005, // 5ms (5x P50 - healthy)
        .p999 = 0.006,
        .p9999 = 0.007,
        .max = 0.01,
        .count = 100,
        .sum = 0.2,
        .mean = 0.002,
    };

    try std.testing.expect(healthy_stats.isHealthy());

    const unhealthy_stats = ExtendedStats{
        .p50 = 0.001, // 1ms
        .p75 = 0.002,
        .p90 = 0.003,
        .p95 = 0.005,
        .p99 = 0.015, // 15ms (15x P50 - unhealthy tail)
        .p999 = 0.1,
        .p9999 = 0.5,
        .max = 1.0,
        .count = 100,
        .sum = 0.3,
        .mean = 0.003,
    };

    try std.testing.expect(!unhealthy_stats.isHealthy());
}

test "Histogram: formatExtended output" {
    var hist = latencyHistogram("test_latency", "Test quantiles", null);
    hist.observe(0.001);
    hist.observe(0.005);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try hist.formatExtended(fbs.writer());
    const output = fbs.getWritten();

    // Check for Prometheus-style quantile output
    try std.testing.expect(std.mem.indexOf(u8, output, "quantile=\"0.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "quantile=\"0.99\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "quantile=\"0.999\"") != null);
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

test "Registry: sharding metrics format output" {
    Registry.sharding_strategy.set(2);
    Registry.shard_strategy.set(0);
    Registry.shard_lookup_latency_jump_hash.observe(0.00005);
    Registry.query_shards_queried_radius.observe(@as(f64, 4));

    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_sharding_strategy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shard_strategy") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, output, "archerdb_shard_lookup_duration_seconds") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_shards_queried") != null);
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

// ============================================================================
// TTL Expired Ratio Metric Tests
// ============================================================================

test "Registry: TTL expired ratio update" {
    // Test basic update functionality
    Registry.updateTtlExpiredRatio(1, 0.5);
    const scaled = Registry.lsm_ttl_expired_ratio_by_level[1].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 5000), scaled); // 0.5 * 10000 = 5000

    // Test boundary values
    Registry.updateTtlExpiredRatio(2, 0.0);
    const lvl2 = Registry.lsm_ttl_expired_ratio_by_level[2].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 0), lvl2);

    Registry.updateTtlExpiredRatio(3, 1.0);
    const lvl3 = Registry.lsm_ttl_expired_ratio_by_level[3].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 10000), lvl3);
}

test "Registry: TTL expired ratio clamps to valid range" {
    // Test that values are clamped to [0, 1]
    Registry.updateTtlExpiredRatio(4, 1.5); // Above 1.0
    const scaled_above = Registry.lsm_ttl_expired_ratio_by_level[4].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 10000), scaled_above); // Clamped to 1.0

    Registry.updateTtlExpiredRatio(5, -0.5); // Below 0.0
    const scaled_below = Registry.lsm_ttl_expired_ratio_by_level[5].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 0), scaled_below); // Clamped to 0.0
}

test "Registry: TTL expired ratio invalid level ignored" {
    // Test that invalid level doesn't cause issues
    // Level 7+ is out of bounds for our 7-element array
    Registry.updateTtlExpiredRatio(10, 0.5); // Should be silently ignored
    // No crash = test passes
}

test "Registry: TTL expired ratio precision" {
    // Test that small ratios are preserved with reasonable precision
    Registry.updateTtlExpiredRatio(0, 0.0001); // 0.01%
    const scaled = Registry.lsm_ttl_expired_ratio_by_level[0].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 1), scaled); // 0.0001 * 10000 = 1

    Registry.updateTtlExpiredRatio(6, 0.3333); // 33.33%
    const scaled_third = Registry.lsm_ttl_expired_ratio_by_level[6].load(.monotonic);
    try std.testing.expectEqual(@as(u32, 3333), scaled_third); // 0.3333 * 10000 = 3333
}

// ============================================================================
// Per-Level Byte Stats Metric Tests
// ============================================================================

test "Registry: Level bytes update" {
    // Test basic update functionality
    Registry.updateLevelBytes(1, 1024 * 1024, 512 * 1024); // 1MB total, 512KB expired
    const total = Registry.lsm_bytes_by_level[1].load(.monotonic);
    const expired = Registry.lsm_ttl_expired_bytes_by_level[1].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), total);
    try std.testing.expectEqual(@as(u64, 512 * 1024), expired);
}

test "Registry: Level bytes zero values" {
    // Test zero byte values
    Registry.updateLevelBytes(2, 0, 0);
    const total = Registry.lsm_bytes_by_level[2].load(.monotonic);
    const expired = Registry.lsm_ttl_expired_bytes_by_level[2].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(@as(u64, 0), expired);
}

test "Registry: Level bytes large values" {
    // Test large byte values (100GB)
    const gb_100: u64 = 100 * 1024 * 1024 * 1024;
    const gb_50: u64 = 50 * 1024 * 1024 * 1024;
    Registry.updateLevelBytes(3, gb_100, gb_50);
    const total = Registry.lsm_bytes_by_level[3].load(.monotonic);
    const expired = Registry.lsm_ttl_expired_bytes_by_level[3].load(.monotonic);
    try std.testing.expectEqual(gb_100, total);
    try std.testing.expectEqual(gb_50, expired);
}

test "Registry: Level bytes invalid level ignored" {
    // Test that invalid level doesn't cause issues
    Registry.updateLevelBytes(10, 1000, 500); // Level 10 is out of bounds
    // No crash = test passes
}

test "Registry: Level bytes overwrite" {
    // Test that values can be overwritten
    Registry.updateLevelBytes(4, 1000, 500);
    Registry.updateLevelBytes(4, 2000, 1000);
    const total = Registry.lsm_bytes_by_level[4].load(.monotonic);
    const expired = Registry.lsm_ttl_expired_bytes_by_level[4].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 2000), total);
    try std.testing.expectEqual(@as(u64, 1000), expired);
}

// ============================================================================
// Index Resize Metrics Tests
// ============================================================================

test "Registry: Index resize metrics format output" {
    // Set test values
    Registry.index_resize_status.set(1); // in_progress
    Registry.index_resize_progress.set(5000); // 50%
    Registry.index_resize_entries_migrated.set(1000);
    Registry.index_resize_entries_total.set(2000);
    Registry.index_resize_source_size.set(1024);
    Registry.index_resize_target_size.set(2048);

    // Use large buffer to accommodate all metrics
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Verify index resize metrics are present
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_index_resize_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_index_resize_progress") != null);
    const migrated = "archerdb_index_resize_entries_migrated";
    try std.testing.expect(std.mem.indexOf(u8, output, migrated) != null);
    const total = "archerdb_index_resize_entries_total";
    try std.testing.expect(std.mem.indexOf(u8, output, total) != null);
}

test "Registry: Index resize counters" {
    // Reset counters
    Registry.index_resize_operations_total = Counter.init(
        "archerdb_index_resize_operations_total",
        "Total index resize operations completed",
        null,
    );
    Registry.index_resize_aborts_total = Counter.init(
        "archerdb_index_resize_aborts_total",
        "Total index resize operations aborted",
        null,
    );

    // Test counter increments
    Registry.index_resize_operations_total.inc();
    Registry.index_resize_operations_total.inc();
    try std.testing.expectEqual(@as(u64, 2), Registry.index_resize_operations_total.get());

    Registry.index_resize_aborts_total.inc();
    try std.testing.expectEqual(@as(u64, 1), Registry.index_resize_aborts_total.get());
}

// ============================================================================
// Membership Metrics Tests
// ============================================================================

test "Registry: Membership metrics format output" {
    // Set test values
    Registry.membership_state.set(1); // joint consensus
    Registry.membership_voters_count.set(5);
    Registry.membership_learners_count.set(2);
    Registry.membership_transitions_in_progress.set(1);
    Registry.membership_transition_progress.set(7500); // 75%

    // Use large buffer to accommodate all metrics
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Verify membership metrics are present
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_membership_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_membership_voters_count") != null);
    const learners = "archerdb_membership_learners_count";
    try std.testing.expect(std.mem.indexOf(u8, output, learners) != null);
    const transitions = "archerdb_membership_transitions_in_progress";
    try std.testing.expect(std.mem.indexOf(u8, output, transitions) != null);
}

test "Registry: Membership counters" {
    // Reset counters
    Registry.membership_changes_total = Counter.init(
        "archerdb_membership_changes_total",
        "Total membership configuration changes",
        null,
    );
    Registry.membership_promotions_total = Counter.init(
        "archerdb_membership_promotions_total",
        "Total learner to voter promotions",
        null,
    );
    Registry.membership_removals_total = Counter.init(
        "archerdb_membership_removals_total",
        "Total node removals from cluster",
        null,
    );

    // Test counter increments
    Registry.membership_changes_total.inc();
    Registry.membership_changes_total.inc();
    Registry.membership_changes_total.inc();
    try std.testing.expectEqual(@as(u64, 3), Registry.membership_changes_total.get());

    Registry.membership_promotions_total.inc();
    try std.testing.expectEqual(@as(u64, 1), Registry.membership_promotions_total.get());

    Registry.membership_removals_total.inc();
    Registry.membership_removals_total.inc();
    try std.testing.expectEqual(@as(u64, 2), Registry.membership_removals_total.get());
}

test "Registry: index health metrics update" {
    Registry.updateResourceMetrics(1024, 512, 4096, 42, 100, 8192);
    try std.testing.expectEqual(@as(i64, 42), Registry.index_entries.get());
    try std.testing.expectEqual(@as(i64, 42), Registry.index_entries_total.get());
    try std.testing.expectEqual(@as(i64, 8192), Registry.index_memory_bytes.get());
    try std.testing.expectEqual(@as(i64, 100), Registry.index_capacity.get());
}

test "Registry: index health metrics format output" {
    Registry.updateResourceMetrics(1, 1, 1, 7, 11, 2048);

    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Registry.format(fbs.writer());
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_index_entries_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_index_memory_bytes") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, output, "archerdb_index_lookup_latency_seconds") != null,
    );
}

// ============================================================================
// S2 Index Metrics Tests (MET-09)
// ============================================================================

test "Registry: S2 cells total counter" {
    // Reset counter for clean test
    Registry.s2_cells_total = Counter.init(
        "archerdb_s2_cells_total",
        "Total S2 cells indexed",
        null,
    );

    // Verify starts at 0
    try std.testing.expectEqual(@as(u64, 0), Registry.s2_cells_total.get());

    // Record some cells at different levels
    Registry.recordS2CellIndexed(15);
    Registry.recordS2CellIndexed(15);
    Registry.recordS2CellIndexed(20);

    // Total should be 3
    try std.testing.expectEqual(@as(u64, 3), Registry.s2_cells_total.get());
}

test "Registry: S2 cell level counts" {
    // Reset level counts
    for (&Registry.s2_cell_level_counts) |*count| {
        count.store(0, .monotonic);
    }

    // Record cells at various levels
    Registry.recordS2CellIndexed(5); // Goes to level 10 bucket (index 1)
    Registry.recordS2CellIndexed(10); // Goes to level 10 bucket (index 1)
    Registry.recordS2CellIndexed(15); // Goes to level 15 bucket (index 2)
    Registry.recordS2CellIndexed(25); // Goes to level 25 bucket (index 4)

    // Verify bucket counts
    // tracked_levels = { 0, 10, 15, 20, 25, 30 }
    try std.testing.expectEqual(@as(u64, 0), Registry.s2_cell_level_counts[0].load(.monotonic)); // level 0
    try std.testing.expectEqual(@as(u64, 2), Registry.s2_cell_level_counts[1].load(.monotonic)); // level 10
    try std.testing.expectEqual(@as(u64, 1), Registry.s2_cell_level_counts[2].load(.monotonic)); // level 15
    try std.testing.expectEqual(@as(u64, 0), Registry.s2_cell_level_counts[3].load(.monotonic)); // level 20
    try std.testing.expectEqual(@as(u64, 1), Registry.s2_cell_level_counts[4].load(.monotonic)); // level 25
}

test "Registry: S2 coverage ratio" {
    // Test coverage ratio update
    Registry.updateS2CoverageRatio(0.5); // 50% coverage
    const scaled = Registry.s2_coverage_ratio.load(.monotonic);
    try std.testing.expectEqual(@as(u32, 5000), scaled);

    // Test boundary values
    Registry.updateS2CoverageRatio(0.0);
    try std.testing.expectEqual(@as(u32, 0), Registry.s2_coverage_ratio.load(.monotonic));

    Registry.updateS2CoverageRatio(1.0);
    try std.testing.expectEqual(@as(u32, 10000), Registry.s2_coverage_ratio.load(.monotonic));

    // Test clamping
    Registry.updateS2CoverageRatio(1.5);
    try std.testing.expectEqual(@as(u32, 10000), Registry.s2_coverage_ratio.load(.monotonic));

    Registry.updateS2CoverageRatio(-0.5);
    try std.testing.expectEqual(@as(u32, 0), Registry.s2_coverage_ratio.load(.monotonic));
}

test "Registry: S2 metrics format output" {
    // Reset for clean test
    Registry.s2_cells_total = Counter.init(
        "archerdb_s2_cells_total",
        "Total S2 cells indexed",
        null,
    );
    Registry.s2_cells_total.add(100);
    Registry.updateS2CoverageRatio(0.75);

    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Verify S2 metrics are present in output
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_s2_cells_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_s2_cell_level") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_s2_coverage_ratio") != null);
}

// ============================================================================
// Extended Memory Metrics Tests (MET-07)
// ============================================================================

test "Registry: Memory metrics gauges" {
    // Test memory metrics can be set to arbitrary values
    Registry.memory_ram_index_bytes.set(1024 * 1024); // 1MB
    try std.testing.expectEqual(@as(i64, 1024 * 1024), Registry.memory_ram_index_bytes.get());

    Registry.memory_cache_bytes.set(256 * 1024 * 1024); // 256MB
    try std.testing.expectEqual(@as(i64, 256 * 1024 * 1024), Registry.memory_cache_bytes.get());
}

test "Registry: Memory metrics format output" {
    Registry.memory_ram_index_bytes.set(8192);
    Registry.memory_cache_bytes.set(16384);

    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_memory_ram_index_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_memory_cache_bytes") != null);
}

// ============================================================================
// Connection Pool Metrics Tests (MET-08)
// ============================================================================

test "Registry: Connection counters" {
    // Reset counters
    Registry.connections_total = Counter.init(
        "archerdb_connections_total",
        "Total connections accepted",
        null,
    );
    Registry.connections_errors_total = Counter.init(
        "archerdb_connections_errors_total",
        "Total connection errors",
        null,
    );

    // Test increments
    Registry.connections_total.inc();
    Registry.connections_total.inc();
    Registry.connections_total.inc();
    try std.testing.expectEqual(@as(u64, 3), Registry.connections_total.get());

    Registry.connections_errors_total.inc();
    try std.testing.expectEqual(@as(u64, 1), Registry.connections_errors_total.get());
}

test "Registry: Connection metrics format output" {
    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_connections_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_connections_errors_total") != null);
}

// ============================================================================
// LSM Compaction Extended Metrics Tests (MET-06)
// ============================================================================

test "Registry: Compaction metrics recording" {
    // Reset counters
    Registry.compaction_operations_total = Counter.init(
        "archerdb_compaction_total",
        "Total compaction operations completed",
        null,
    );
    Registry.compaction_bytes_read_total = Counter.init(
        "archerdb_compaction_bytes_read_total",
        "Total bytes read during compaction",
        null,
    );
    Registry.compaction_bytes_written_total = Counter.init(
        "archerdb_compaction_bytes_written_total",
        "Total bytes written during compaction",
        null,
    );

    // Record compaction
    Registry.recordCompactionWithDetails(2, 1024, 512, 100_000_000); // 100ms

    // Verify counters
    try std.testing.expectEqual(@as(u64, 1), Registry.compaction_operations_total.get());
    try std.testing.expectEqual(@as(u64, 1024), Registry.compaction_bytes_read_total.get());
    try std.testing.expectEqual(@as(u64, 512), Registry.compaction_bytes_written_total.get());
    try std.testing.expectEqual(@as(i64, 2), Registry.compaction_current_level.get());
}

test "Registry: Compaction histogram buckets" {
    // Reset histogram
    Registry.compaction_duration_seconds = latencyHistogram(
        "archerdb_compaction_duration_seconds",
        "Compaction operation duration histogram",
        null,
    );

    // Record observations
    Registry.compaction_duration_seconds.observe(0.01); // 10ms
    Registry.compaction_duration_seconds.observe(0.1); // 100ms
    Registry.compaction_duration_seconds.observe(1.0); // 1s

    try std.testing.expectEqual(@as(u64, 3), Registry.compaction_duration_seconds.getCount());
    try std.testing.expect(Registry.compaction_duration_seconds.getSum() > 1.0);
}

test "Registry: Compaction metrics format output" {
    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_duration_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_bytes_read_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_bytes_written_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_compaction_total") != null);
}

// ============================================================================
// Checkpoint Metrics Tests
// ============================================================================

test "Registry: Checkpoint recording" {
    // Reset counters
    Registry.checkpoint_total = Counter.init(
        "archerdb_checkpoint_total",
        "Total checkpoints completed",
        null,
    );

    // Record checkpoints
    Registry.recordCheckpoint(50_000_000); // 50ms
    Registry.recordCheckpoint(100_000_000); // 100ms

    try std.testing.expectEqual(@as(u64, 2), Registry.checkpoint_total.get());
    try std.testing.expect(Registry.checkpoint_duration_seconds.getCount() >= 2);
}

test "Registry: Checkpoint metrics format output" {
    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_checkpoint_duration_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_checkpoint_total") != null);
}

// ============================================================================
// Build Info Metrics Tests
// ============================================================================

test "Registry: Build info initialization" {
    // Initialize with test values
    Registry.initBuildInfo("1.2.3", "abc123def");

    // Verify version was stored
    const version = Registry.build_version[0..Registry.build_version_len];
    try std.testing.expectEqualStrings("1.2.3", version);

    // Verify commit was stored
    const commit = Registry.build_commit[0..Registry.build_commit_len];
    try std.testing.expectEqualStrings("abc123def", commit);
}

test "Registry: Build info format output" {
    Registry.initBuildInfo("0.1.0", "deadbeef");

    var buf: [131072]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Verify build info metric is present with labels
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_build_info") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "version=\"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "commit=\"deadbeef\"") != null);
    // Value should always be 1
    try std.testing.expect(std.mem.indexOf(u8, output, "} 1") != null);
}

test "Registry: Build info truncation" {
    // Test that long strings are truncated
    const long_version = "v1.2.3-beta.4567890123456789012345678901234567890";
    const long_commit = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    Registry.initBuildInfo(long_version, long_commit);

    // Version should be truncated to 32 chars
    try std.testing.expectEqual(@as(u8, 32), Registry.build_version_len);

    // Commit should be truncated to 64 chars
    try std.testing.expectEqual(@as(u8, 64), Registry.build_commit_len);
}
