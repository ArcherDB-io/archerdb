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
const Allocator = std.mem.Allocator;

/// A monotonically increasing counter metric.
/// Thread-safe via atomic operations.
pub const Counter = struct {
    value: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,

    const Self = @This();

    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Self {
        return .{
            .value = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
            .labels = labels,
        };
    }

    /// Increment the counter by 1.
    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Add a value to the counter.
    pub fn add(self: *Self, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Get the current value.
    pub fn get(self: *const Self) u64 {
        return self.value.load(.monotonic);
    }

    /// Format as Prometheus text format.
    pub fn format(self: *const Self, writer: anytype) !void {
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

    const Self = @This();

    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Self {
        return .{
            .value = std.atomic.Value(i64).init(0),
            .name = name,
            .help = help,
            .labels = labels,
        };
    }

    /// Set the gauge to a specific value.
    pub fn set(self: *Self, val: i64) void {
        self.value.store(val, .monotonic);
    }

    /// Increment the gauge by 1.
    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Decrement the gauge by 1.
    pub fn dec(self: *Self) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    /// Add a value to the gauge.
    pub fn add(self: *Self, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    /// Get the current value.
    pub fn get(self: *const Self) i64 {
        return self.value.load(.monotonic);
    }

    /// Format as Prometheus text format.
    pub fn format(self: *const Self, writer: anytype) !void {
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
pub fn Histogram(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count]std.atomic.Value(u64),
        bucket_bounds: [bucket_count]f64,
        sum: std.atomic.Value(u64), // Store as fixed-point (nanoseconds for latency)
        count: std.atomic.Value(u64),
        name: []const u8,
        help: []const u8,
        labels: ?[]const u8,

        const Self = @This();

        /// Initialize with the given bucket boundaries.
        /// Boundaries should be in ascending order (e.g., 0.001, 0.005, 0.01, 0.05, 0.1).
        pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8, bounds: [bucket_count]f64) Self {
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
        pub fn observe(self: *Self, value: f64) void {
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
        pub fn observeNs(self: *Self, value_ns: u64) void {
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
        pub fn getCount(self: *const Self) u64 {
            return self.count.load(.monotonic);
        }

        /// Get the current sum in seconds.
        pub fn getSum(self: *const Self) f64 {
            return @as(f64, @floatFromInt(self.sum.load(.monotonic))) / 1e9;
        }

        /// Format as Prometheus text format.
        pub fn format(self: *const Self, writer: anytype) !void {
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
pub const LatencyHistogram = Histogram(9);

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

    // Read metrics
    pub var read_operations_total: Counter = Counter.init(
        "archerdb_read_operations_total",
        "Total read operations processed",
        null,
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

    // Connection metrics
    pub var active_connections: Gauge = Gauge.init(
        "archerdb_active_connections",
        "Number of active client connections",
        null,
    );

    // Error metrics
    pub var write_errors_total: Counter = Counter.init(
        "archerdb_write_errors_total",
        "Total write operation errors",
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
        try writer.writeAll("\n");

        try read_operations_total.format(writer);
        try read_events_returned_total.format(writer);
        try read_latency.format(writer);
        try writer.writeAll("\n");

        try index_lookups_total.format(writer);
        try index_lookup_latency.format(writer);
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
        try writer.writeAll("# HELP archerdb_lsm_compactions_total Total compactions performed per level\n");
        try writer.writeAll("# TYPE archerdb_lsm_compactions_total counter\n");
        for (lsm_compactions_per_level, 0..) |count, level| {
            try writer.print("archerdb_lsm_compactions_total{{level=\"{d}\"}} {d}\n", .{
                level,
                count.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Per-level bytes moved during compaction
        try writer.writeAll("# HELP archerdb_lsm_compaction_bytes_moved_total Bytes moved during compaction per level\n");
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
        try writer.writeAll("# HELP archerdb_lsm_tables_count Current number of tables per level\n");
        try writer.writeAll("# TYPE archerdb_lsm_tables_count gauge\n");
        for (lsm_tables_per_level, 0..) |count, level| {
            try writer.print("archerdb_lsm_tables_count{{level=\"{d}\"}} {d}\n", .{
                level,
                count.load(.monotonic),
            });
        }
        try writer.writeAll("\n");

        // Per-level size bytes
        try writer.writeAll("# HELP archerdb_lsm_level_size_bytes Current size of each LSM level\n");
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
        try writer.writeAll("# HELP archerdb_lsm_write_amplification_ratio Write amplification (disk_bytes / user_bytes)\n");
        try writer.writeAll("# TYPE archerdb_lsm_write_amplification_ratio gauge\n");
        if (user_bytes > 0) {
            const ratio: f64 = @as(f64, @floatFromInt(disk_bytes)) / @as(f64, @floatFromInt(user_bytes));
            try writer.print("archerdb_lsm_write_amplification_ratio {d:.2}\n", .{ratio});
        } else {
            try writer.writeAll("archerdb_lsm_write_amplification_ratio 0\n");
        }
        try writer.writeAll("\n");

        // Grid cache metrics
        try writer.writeAll("# HELP archerdb_grid_cache_hits_total Cache hits for block reads\n");
        try writer.writeAll("# TYPE archerdb_grid_cache_hits_total counter\n");
        try writer.print("archerdb_grid_cache_hits_total {d}\n", .{grid_cache_hits_total.load(.monotonic)});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_grid_cache_misses_total Cache misses requiring disk read\n");
        try writer.writeAll("# TYPE archerdb_grid_cache_misses_total counter\n");
        try writer.print("archerdb_grid_cache_misses_total {d}\n", .{grid_cache_misses_total.load(.monotonic)});
        try writer.writeAll("\n");

        // Grid cache hit ratio (derived)
        const cache_hits = grid_cache_hits_total.load(.monotonic);
        const cache_misses = grid_cache_misses_total.load(.monotonic);
        const cache_total = cache_hits + cache_misses;
        try writer.writeAll("# HELP archerdb_grid_cache_hit_ratio Cache hit rate (hits / total)\n");
        try writer.writeAll("# TYPE archerdb_grid_cache_hit_ratio gauge\n");
        if (cache_total > 0) {
            const hit_ratio: f64 = @as(f64, @floatFromInt(cache_hits)) / @as(f64, @floatFromInt(cache_total));
            try writer.print("archerdb_grid_cache_hit_ratio {d:.4}\n", .{hit_ratio});
        } else {
            try writer.writeAll("archerdb_grid_cache_hit_ratio 0\n");
        }
        try writer.writeAll("\n");

        // Grid cache size (blocks × block_size)
        const cache_blocks = grid_cache_blocks_count.load(.monotonic);
        const block_size: u64 = 65536; // constants.block_size (64KB)
        try writer.writeAll("# HELP archerdb_grid_cache_size_bytes Current cache size in bytes\n");
        try writer.writeAll("# TYPE archerdb_grid_cache_size_bytes gauge\n");
        try writer.print("archerdb_grid_cache_size_bytes {d}\n", .{cache_blocks * block_size});
        try writer.writeAll("\n");

        // Grid block utilization
        try writer.writeAll("# HELP archerdb_grid_blocks_acquired Acquired blocks (in use)\n");
        try writer.writeAll("# TYPE archerdb_grid_blocks_acquired gauge\n");
        try writer.print("archerdb_grid_blocks_acquired {d}\n", .{grid_blocks_acquired.load(.monotonic)});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_grid_blocks_missing Missing/faulty blocks being repaired\n");
        try writer.writeAll("# TYPE archerdb_grid_blocks_missing gauge\n");
        try writer.print("archerdb_grid_blocks_missing {d}\n", .{grid_blocks_missing.load(.monotonic)});
        try writer.writeAll("\n");

        // Journal/WAL metrics
        try writer.writeAll("# HELP archerdb_journal_dirty_count Dirty journal slots\n");
        try writer.writeAll("# TYPE archerdb_journal_dirty_count gauge\n");
        try writer.print("archerdb_journal_dirty_count {d}\n", .{journal_dirty_count.load(.monotonic)});
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_journal_faulty_count Faulty journal slots\n");
        try writer.writeAll("# TYPE archerdb_journal_faulty_count gauge\n");
        try writer.print("archerdb_journal_faulty_count {d}\n", .{journal_faulty_count.load(.monotonic)});
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

    /// Update grid cache and journal metrics.
    /// Called periodically from the main replica loop.
    pub fn updateGridMetrics(
        cache_hits: u64,
        cache_misses: u64,
        cache_blocks: u64,
        blocks_acquired: u64,
        blocks_missing: u64,
        dirty_count: u64,
        faulty_count: u64,
    ) void {
        grid_cache_hits_total.store(cache_hits, .monotonic);
        grid_cache_misses_total.store(cache_misses, .monotonic);
        grid_cache_blocks_count.store(cache_blocks, .monotonic);
        grid_blocks_acquired.store(blocks_acquired, .monotonic);
        grid_blocks_missing.store(blocks_missing, .monotonic);
        journal_dirty_count.store(dirty_count, .monotonic);
        journal_faulty_count.store(faulty_count, .monotonic);
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
