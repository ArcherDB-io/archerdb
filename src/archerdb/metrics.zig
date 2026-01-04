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

    // Free set metrics (F5.2 - Observability)
    pub var free_set_blocks_free: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var free_set_blocks_reserved: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var free_set_total_blocks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    // Backup metrics (F5.5.6 - Backup Monitoring)
    // See: openspec/changes/add-geospatial-core/specs/backup-restore/spec.md

    /// Total blocks uploaded to object storage
    pub var backup_blocks_uploaded_total: Counter = Counter.init(
        "archerdb_backup_blocks_uploaded_total",
        "Total blocks uploaded to object storage",
        null,
    );

    /// Current backup lag (blocks not yet uploaded)
    pub var backup_lag_blocks: Gauge = Gauge.init(
        "archerdb_backup_lag_blocks",
        "Backup lag (blocks pending upload)",
        null,
    );

    /// Total backup upload failures
    pub var backup_failures_total: Counter = Counter.init(
        "archerdb_backup_failures_total",
        "Total backup upload failures",
        null,
    );

    /// Timestamp of last successful backup
    pub var backup_last_success_timestamp: Gauge = Gauge.init(
        "archerdb_backup_last_success_timestamp",
        "Timestamp of last successful backup (Unix seconds)",
        null,
    );

    /// Backup upload latency histogram
    pub var backup_upload_latency: LatencyHistogram = latencyHistogram(
        "archerdb_backup_upload_latency_seconds",
        "Backup upload latency histogram",
        null,
    );

    /// Current Recovery Point Objective (seconds since oldest un-backed-up block)
    pub var backup_rpo_current_seconds: Gauge = Gauge.init(
        "archerdb_backup_rpo_current_seconds",
        "Current RPO (seconds since oldest un-backed-up block)",
        null,
    );

    /// Blocks abandoned without backup (best-effort mode only)
    pub var backup_blocks_abandoned_total: Counter = Counter.init(
        "archerdb_backup_blocks_abandoned_total",
        "Blocks abandoned without backup (best-effort mode)",
        null,
    );

    /// Emergency mandatory bypass counter (when mandatory timeout hit)
    pub var backup_mandatory_bypass_total: Counter = Counter.init(
        "archerdb_backup_mandatory_bypass_total",
        "Emergency bypasses of mandatory backup (timeout hit)",
        null,
    );

    /// Backup enabled status (1 = enabled, 0 = disabled)
    pub var backup_enabled: Gauge = Gauge.init(
        "archerdb_backup_enabled",
        "Whether backup is enabled (1 = yes, 0 = no)",
        null,
    );

    /// Backup mode (0 = best-effort, 1 = mandatory)
    pub var backup_mode: Gauge = Gauge.init(
        "archerdb_backup_mode",
        "Backup mode (0 = best-effort, 1 = mandatory)",
        null,
    );

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

        // Backup metrics (F5.5.6)
        try backup_enabled.format(writer);
        try backup_mode.format(writer);
        try backup_blocks_uploaded_total.format(writer);
        try backup_lag_blocks.format(writer);
        try backup_failures_total.format(writer);
        try backup_last_success_timestamp.format(writer);
        try backup_upload_latency.format(writer);
        try backup_rpo_current_seconds.format(writer);
        try backup_blocks_abandoned_total.format(writer);
        try backup_mandatory_bypass_total.format(writer);
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

    // =========================================================================
    // Backup Metrics Update Functions (F5.5.6)
    // =========================================================================

    /// Initialize backup metrics from config.
    /// Call once during startup after backup config is loaded.
    pub fn initBackupMetrics(enabled: bool, is_mandatory: bool) void {
        backup_enabled.set(if (enabled) 1 else 0);
        backup_mode.set(if (is_mandatory) 1 else 0);
    }

    /// Record a successful block upload.
    /// latency_ns is the upload duration in nanoseconds.
    pub fn recordBackupUpload(latency_ns: u64) void {
        backup_blocks_uploaded_total.inc();
        if (latency_ns > 0) {
            backup_upload_latency.observeNs(latency_ns);
        }
        // Update last success timestamp (Unix seconds)
        const now = std.time.timestamp();
        backup_last_success_timestamp.set(now);
    }

    /// Record a backup upload failure.
    pub fn recordBackupFailure() void {
        backup_failures_total.inc();
    }

    /// Update backup lag (blocks pending upload).
    pub fn updateBackupLag(pending_blocks: u64) void {
        backup_lag_blocks.set(@intCast(pending_blocks));
    }

    /// Update current RPO (seconds since oldest un-backed-up block).
    pub fn updateBackupRpo(rpo_seconds: u64) void {
        backup_rpo_current_seconds.set(@intCast(rpo_seconds));
    }

    /// Record a block abandoned without backup (best-effort mode).
    pub fn recordBackupAbandoned() void {
        backup_blocks_abandoned_total.inc();
    }

    /// Record an emergency mandatory bypass (timeout hit).
    pub fn recordMandatoryBypass() void {
        backup_mandatory_bypass_total.inc();
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

// =============================================================================
// Backup Metrics Tests (F5.5.6)
// =============================================================================

test "Backup: initBackupMetrics" {
    // Test enabled with best-effort mode
    Registry.initBackupMetrics(true, false);
    try std.testing.expectEqual(@as(i64, 1), Registry.backup_enabled.get());
    try std.testing.expectEqual(@as(i64, 0), Registry.backup_mode.get());

    // Test enabled with mandatory mode
    Registry.initBackupMetrics(true, true);
    try std.testing.expectEqual(@as(i64, 1), Registry.backup_enabled.get());
    try std.testing.expectEqual(@as(i64, 1), Registry.backup_mode.get());

    // Test disabled
    Registry.initBackupMetrics(false, false);
    try std.testing.expectEqual(@as(i64, 0), Registry.backup_enabled.get());
}

test "Backup: recordBackupUpload" {
    // Reset counter for test
    Registry.backup_blocks_uploaded_total = Counter.init(
        "archerdb_backup_blocks_uploaded_total",
        "Total blocks uploaded to object storage",
        null,
    );

    try std.testing.expectEqual(@as(u64, 0), Registry.backup_blocks_uploaded_total.get());

    Registry.recordBackupUpload(1_000_000); // 1ms latency
    try std.testing.expectEqual(@as(u64, 1), Registry.backup_blocks_uploaded_total.get());

    Registry.recordBackupUpload(2_000_000); // 2ms latency
    try std.testing.expectEqual(@as(u64, 2), Registry.backup_blocks_uploaded_total.get());

    // Last success timestamp should be set
    try std.testing.expect(Registry.backup_last_success_timestamp.get() > 0);
}

test "Backup: recordBackupFailure" {
    // Reset counter for test
    Registry.backup_failures_total = Counter.init(
        "archerdb_backup_failures_total",
        "Total backup upload failures",
        null,
    );

    try std.testing.expectEqual(@as(u64, 0), Registry.backup_failures_total.get());

    Registry.recordBackupFailure();
    try std.testing.expectEqual(@as(u64, 1), Registry.backup_failures_total.get());

    Registry.recordBackupFailure();
    Registry.recordBackupFailure();
    try std.testing.expectEqual(@as(u64, 3), Registry.backup_failures_total.get());
}

test "Backup: updateBackupLag" {
    Registry.updateBackupLag(0);
    try std.testing.expectEqual(@as(i64, 0), Registry.backup_lag_blocks.get());

    Registry.updateBackupLag(10);
    try std.testing.expectEqual(@as(i64, 10), Registry.backup_lag_blocks.get());

    Registry.updateBackupLag(100);
    try std.testing.expectEqual(@as(i64, 100), Registry.backup_lag_blocks.get());
}

test "Backup: updateBackupRpo" {
    Registry.updateBackupRpo(0);
    try std.testing.expectEqual(@as(i64, 0), Registry.backup_rpo_current_seconds.get());

    Registry.updateBackupRpo(60); // 1 minute
    try std.testing.expectEqual(@as(i64, 60), Registry.backup_rpo_current_seconds.get());

    Registry.updateBackupRpo(3600); // 1 hour
    try std.testing.expectEqual(@as(i64, 3600), Registry.backup_rpo_current_seconds.get());
}

test "Backup: recordBackupAbandoned" {
    // Reset counter for test
    Registry.backup_blocks_abandoned_total = Counter.init(
        "archerdb_backup_blocks_abandoned_total",
        "Blocks abandoned without backup (best-effort mode)",
        null,
    );

    try std.testing.expectEqual(@as(u64, 0), Registry.backup_blocks_abandoned_total.get());

    Registry.recordBackupAbandoned();
    try std.testing.expectEqual(@as(u64, 1), Registry.backup_blocks_abandoned_total.get());
}

test "Backup: recordMandatoryBypass" {
    // Reset counter for test
    Registry.backup_mandatory_bypass_total = Counter.init(
        "archerdb_backup_mandatory_bypass_total",
        "Emergency bypasses of mandatory backup (timeout hit)",
        null,
    );

    try std.testing.expectEqual(@as(u64, 0), Registry.backup_mandatory_bypass_total.get());

    Registry.recordMandatoryBypass();
    try std.testing.expectEqual(@as(u64, 1), Registry.backup_mandatory_bypass_total.get());
}

test "Backup: metrics in prometheus format" {
    // Initialize with known values
    Registry.initBackupMetrics(true, true);
    Registry.updateBackupLag(5);
    Registry.updateBackupRpo(120);

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try Registry.format(fbs.writer());

    const output = fbs.getWritten();

    // Check backup metrics are present
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_lag_blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_rpo_current_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_blocks_uploaded_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_backup_failures_total") != null);
}
