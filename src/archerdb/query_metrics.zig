// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Query latency breakdown metrics for performance diagnosis.
//!
//! Provides detailed latency breakdown by query phase (parse, plan, execute, serialize)
//! and by query type (uuid, radius, polygon, latest) for dashboard operators
//! to identify performance bottlenecks.
//!
//! All metrics follow Prometheus naming conventions (archerdb_query_*).

const std = @import("std");
const metrics = @import("metrics.zig");

const HistogramType = metrics.HistogramType;
const Gauge = metrics.Gauge;

// ============================================================================
// Latency Histogram Configuration
// ============================================================================

/// Latency histogram bucket boundaries in seconds (Prometheus convention).
/// Covers 100us to 1s for typical query latency ranges.
pub const latency_buckets: [11]f64 = .{
    0.0001, // 100us
    0.0005, // 500us
    0.001, // 1ms
    0.005, // 5ms
    0.01, // 10ms
    0.025, // 25ms
    0.05, // 50ms
    0.1, // 100ms
    0.25, // 250ms
    0.5, // 500ms
    1.0, // 1s
};

/// Query latency histogram type with 11 buckets.
pub const LatencyHistogram = HistogramType(11);

// ============================================================================
// Query Types
// ============================================================================

/// Query type enumeration for metrics labeling.
pub const QueryType = enum {
    uuid,
    radius,
    polygon,
    latest,

    /// Convert to string for Prometheus labels.
    pub fn toString(self: QueryType) []const u8 {
        return switch (self) {
            .uuid => "uuid",
            .radius => "radius",
            .polygon => "polygon",
            .latest => "latest",
        };
    }
};

// ============================================================================
// Timing Breakdown
// ============================================================================

/// Breakdown of query execution time by phase.
/// Times are in nanoseconds for precision.
pub const Breakdown = struct {
    /// Query type for labeling.
    query_type: QueryType,
    /// Time spent parsing input filter.
    parse_ns: u64,
    /// Time spent planning (S2 covering computation, cache lookup).
    plan_ns: u64,
    /// Time spent executing (index scan, filtering).
    execute_ns: u64,
    /// Time spent serializing results to output buffer.
    serialize_ns: u64,

    /// Calculate total query time.
    pub fn total_ns(self: Breakdown) u64 {
        return self.parse_ns + self.plan_ns + self.execute_ns + self.serialize_ns;
    }
};

// ============================================================================
// QueryLatencyBreakdown
// ============================================================================

/// Query latency breakdown metrics with per-phase and per-query-type histograms.
///
/// Provides detailed visibility into where query time is spent for performance
/// diagnosis and optimization targeting.
pub const QueryLatencyBreakdown = struct {
    // Per-phase latency histograms (aggregate across all query types)
    parse_seconds: LatencyHistogram,
    plan_seconds: LatencyHistogram,
    execute_seconds: LatencyHistogram,
    serialize_seconds: LatencyHistogram,

    // Per-query-type total latency histograms
    uuid_total_seconds: LatencyHistogram,
    radius_total_seconds: LatencyHistogram,
    polygon_total_seconds: LatencyHistogram,
    latest_total_seconds: LatencyHistogram,

    /// Initialize all histograms with standard latency buckets.
    pub fn init() QueryLatencyBreakdown {
        return .{
            // Per-phase histograms
            .parse_seconds = LatencyHistogram.init(
                "archerdb_query_parse_seconds",
                "Query parse phase latency histogram",
                null,
                latency_buckets,
            ),
            .plan_seconds = LatencyHistogram.init(
                "archerdb_query_plan_seconds",
                "Query plan phase latency histogram (S2 covering, cache)",
                null,
                latency_buckets,
            ),
            .execute_seconds = LatencyHistogram.init(
                "archerdb_query_execute_seconds",
                "Query execute phase latency histogram (index scan, filtering)",
                null,
                latency_buckets,
            ),
            .serialize_seconds = LatencyHistogram.init(
                "archerdb_query_serialize_seconds",
                "Query serialize phase latency histogram (output buffer)",
                null,
                latency_buckets,
            ),
            // Per-query-type histograms
            .uuid_total_seconds = LatencyHistogram.init(
                "archerdb_query_total_seconds",
                "Total query latency histogram",
                "type=\"uuid\"",
                latency_buckets,
            ),
            .radius_total_seconds = LatencyHistogram.init(
                "archerdb_query_total_seconds",
                "Total query latency histogram",
                "type=\"radius\"",
                latency_buckets,
            ),
            .polygon_total_seconds = LatencyHistogram.init(
                "archerdb_query_total_seconds",
                "Total query latency histogram",
                "type=\"polygon\"",
                latency_buckets,
            ),
            .latest_total_seconds = LatencyHistogram.init(
                "archerdb_query_total_seconds",
                "Total query latency histogram",
                "type=\"latest\"",
                latency_buckets,
            ),
        };
    }

    /// Record query execution phases.
    pub fn recordPhases(self: *QueryLatencyBreakdown, breakdown: Breakdown) void {
        // Record per-phase latencies (convert ns to seconds)
        self.parse_seconds.observeNs(breakdown.parse_ns);
        self.plan_seconds.observeNs(breakdown.plan_ns);
        self.execute_seconds.observeNs(breakdown.execute_ns);
        self.serialize_seconds.observeNs(breakdown.serialize_ns);

        // Record total latency by query type
        const total = breakdown.total_ns();
        switch (breakdown.query_type) {
            .uuid => self.uuid_total_seconds.observeNs(total),
            .radius => self.radius_total_seconds.observeNs(total),
            .polygon => self.polygon_total_seconds.observeNs(total),
            .latest => self.latest_total_seconds.observeNs(total),
        }
    }

    /// Export all metrics in Prometheus text format.
    pub fn toPrometheus(self: *const QueryLatencyBreakdown, writer: anytype) !void {
        // Per-phase histograms
        try self.parse_seconds.format(writer);
        try writer.writeAll("\n");
        try self.plan_seconds.format(writer);
        try writer.writeAll("\n");
        try self.execute_seconds.format(writer);
        try writer.writeAll("\n");
        try self.serialize_seconds.format(writer);
        try writer.writeAll("\n");

        // Per-query-type histograms (share HELP/TYPE since they have same base name)
        try writer.writeAll("# HELP archerdb_query_total_seconds Total query latency histogram\n");
        try writer.writeAll("# TYPE archerdb_query_total_seconds histogram\n");

        // UUID
        try self.formatHistogramBuckets(&self.uuid_total_seconds, "type=\"uuid\"", writer);
        // Radius
        try self.formatHistogramBuckets(&self.radius_total_seconds, "type=\"radius\"", writer);
        // Polygon
        try self.formatHistogramBuckets(&self.polygon_total_seconds, "type=\"polygon\"", writer);
        // Latest
        try self.formatHistogramBuckets(&self.latest_total_seconds, "type=\"latest\"", writer);
    }

    /// Format histogram buckets without HELP/TYPE (for shared metric names).
    fn formatHistogramBuckets(
        self: *const QueryLatencyBreakdown,
        histogram: *const LatencyHistogram,
        labels: []const u8,
        writer: anytype,
    ) !void {
        _ = self;
        var cumulative: u64 = 0;
        for (histogram.bucket_bounds, 0..) |bound, i| {
            cumulative += histogram.buckets[i].load(.monotonic);
            try writer.print("archerdb_query_total_seconds_bucket{{{s},le=\"{d:.6}\"}} {d}\n", .{
                labels,
                bound,
                cumulative,
            });
        }
        // +Inf bucket
        try writer.print("archerdb_query_total_seconds_bucket{{{s},le=\"+Inf\"}} {d}\n", .{
            labels,
            histogram.count.load(.monotonic),
        });
        // Sum and count
        try writer.print("archerdb_query_total_seconds_sum{{{s}}} {d:.6}\n", .{
            labels,
            histogram.getSum(),
        });
        try writer.print("archerdb_query_total_seconds_count{{{s}}} {d}\n", .{
            labels,
            histogram.count.load(.monotonic),
        });
    }
};

// ============================================================================
// SpatialIndexStats
// ============================================================================

/// Spatial index statistics for query planning insights.
///
/// Provides visibility into RAM index state and S2 covering statistics
/// to help operators understand query performance characteristics.
pub const SpatialIndexStats = struct {
    // RAM index statistics
    ram_index_entries: Gauge,
    ram_index_capacity: Gauge,
    ram_index_load_factor: Gauge, // Scaled by 1000 (500 = 50%)

    // S2 covering statistics (EMA averages)
    avg_cells_radius: i64, // Scaled by 100 (250 = 2.5 cells avg)
    avg_cells_polygon: i64, // Scaled by 100
    covering_cache_entries: Gauge,

    // Query planning hints
    estimated_scan_ratio: Gauge, // Scaled by 1000 (how much of index scanned)

    // EMA state for running averages
    radius_query_count: u64,
    polygon_query_count: u64,

    /// Initialize spatial index statistics.
    pub fn init() SpatialIndexStats {
        return .{
            .ram_index_entries = Gauge.init(
                "archerdb_ram_index_entries",
                "Number of entries in RAM index",
                null,
            ),
            .ram_index_capacity = Gauge.init(
                "archerdb_ram_index_capacity",
                "Total capacity of RAM index",
                null,
            ),
            .ram_index_load_factor = Gauge.init(
                "archerdb_ram_index_load_factor",
                "RAM index load factor (scaled by 1000, e.g., 500 = 50%)",
                null,
            ),
            .covering_cache_entries = Gauge.init(
                "archerdb_covering_cache_entries",
                "Number of entries in S2 covering cache",
                null,
            ),
            .estimated_scan_ratio = Gauge.init(
                "archerdb_query_estimated_scan_ratio",
                "Estimated ratio of index scanned per query (scaled by 1000)",
                null,
            ),
            .avg_cells_radius = 0,
            .avg_cells_polygon = 0,
            .radius_query_count = 0,
            .polygon_query_count = 0,
        };
    }

    /// Update statistics from RAM index state.
    pub fn updateFromIndex(self: *SpatialIndexStats, entry_count: u64, capacity: u64) void {
        self.ram_index_entries.set(@intCast(entry_count));
        self.ram_index_capacity.set(@intCast(capacity));

        // Calculate load factor (scaled by 1000)
        if (capacity > 0) {
            const load_factor = (entry_count * 1000) / capacity;
            self.ram_index_load_factor.set(@intCast(load_factor));
        }
    }

    /// Record S2 covering size for a query.
    /// Uses EMA with alpha=0.1 for smooth averaging.
    pub fn recordCoveringSize(self: *SpatialIndexStats, query_type: QueryType, num_cells: u8) void {
        const cells_scaled: i64 = @as(i64, num_cells) * 100; // Scale by 100

        switch (query_type) {
            .radius => {
                if (self.radius_query_count == 0) {
                    self.avg_cells_radius = cells_scaled;
                } else {
                    // EMA: new_avg = alpha * new_value + (1 - alpha) * old_avg
                    // With alpha = 0.1: new_avg = (new_value + 9 * old_avg) / 10
                    self.avg_cells_radius = @divFloor(cells_scaled + 9 * self.avg_cells_radius, 10);
                }
                self.radius_query_count += 1;
            },
            .polygon => {
                if (self.polygon_query_count == 0) {
                    self.avg_cells_polygon = cells_scaled;
                } else {
                    self.avg_cells_polygon = @divFloor(cells_scaled + 9 * self.avg_cells_polygon, 10);
                }
                self.polygon_query_count += 1;
            },
            else => {}, // UUID and latest don't use S2 covering
        }
    }

    /// Update scan ratio estimate based on query selectivity.
    pub fn updateScanRatio(self: *SpatialIndexStats, entries_scanned: u64, total_entries: u64) void {
        if (total_entries == 0) return;
        const ratio = (entries_scanned * 1000) / total_entries;
        // EMA update
        const current = self.estimated_scan_ratio.get();
        if (current == 0) {
            self.estimated_scan_ratio.set(@intCast(ratio));
        } else {
            const new_ratio = @divFloor(@as(i64, @intCast(ratio)) + 9 * current, 10);
            self.estimated_scan_ratio.set(new_ratio);
        }
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: *const SpatialIndexStats, writer: anytype) !void {
        // RAM index metrics
        try self.ram_index_entries.format(writer);
        try self.ram_index_capacity.format(writer);
        try self.ram_index_load_factor.format(writer);
        try writer.writeAll("\n");

        // S2 covering statistics (as gauges with labels)
        try writer.writeAll("# HELP archerdb_query_covering_cells_avg Average S2 cells per query (scaled by 100)\n");
        try writer.writeAll("# TYPE archerdb_query_covering_cells_avg gauge\n");
        try writer.print("archerdb_query_covering_cells_avg{{type=\"radius\"}} {d}\n", .{self.avg_cells_radius});
        try writer.print("archerdb_query_covering_cells_avg{{type=\"polygon\"}} {d}\n", .{self.avg_cells_polygon});
        try writer.writeAll("\n");

        try self.covering_cache_entries.format(writer);
        try self.estimated_scan_ratio.format(writer);
        try writer.writeAll("\n");
    }
};

// ============================================================================
// Tests
// ============================================================================

test "QueryLatencyBreakdown: init creates valid histograms" {
    const breakdown = QueryLatencyBreakdown.init();

    // Verify histograms are initialized with correct bucket count
    try std.testing.expectEqual(@as(usize, 11), breakdown.parse_seconds.bucket_bounds.len);
    try std.testing.expectEqual(@as(usize, 11), breakdown.plan_seconds.bucket_bounds.len);
    try std.testing.expectEqual(@as(usize, 11), breakdown.execute_seconds.bucket_bounds.len);
    try std.testing.expectEqual(@as(usize, 11), breakdown.serialize_seconds.bucket_bounds.len);
}

test "QueryLatencyBreakdown: recordPhases updates histograms" {
    var breakdown = QueryLatencyBreakdown.init();

    // Record a query with known timings
    breakdown.recordPhases(.{
        .query_type = .radius,
        .parse_ns = 100_000, // 100us
        .plan_ns = 500_000, // 500us
        .execute_ns = 5_000_000, // 5ms
        .serialize_ns = 200_000, // 200us
    });

    // Verify counts incremented
    try std.testing.expectEqual(@as(u64, 1), breakdown.parse_seconds.getCount());
    try std.testing.expectEqual(@as(u64, 1), breakdown.plan_seconds.getCount());
    try std.testing.expectEqual(@as(u64, 1), breakdown.execute_seconds.getCount());
    try std.testing.expectEqual(@as(u64, 1), breakdown.serialize_seconds.getCount());
    try std.testing.expectEqual(@as(u64, 1), breakdown.radius_total_seconds.getCount());
    try std.testing.expectEqual(@as(u64, 0), breakdown.uuid_total_seconds.getCount());
}

test "QueryLatencyBreakdown: toPrometheus produces valid output" {
    var breakdown = QueryLatencyBreakdown.init();
    breakdown.recordPhases(.{
        .query_type = .uuid,
        .parse_ns = 50_000,
        .plan_ns = 0,
        .execute_ns = 100_000,
        .serialize_ns = 50_000,
    });

    var buffer: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try breakdown.toPrometheus(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_parse_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_plan_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_execute_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_total_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type=\"uuid\"") != null);
}

test "Breakdown: total_ns calculates correctly" {
    const b = Breakdown{
        .query_type = .polygon,
        .parse_ns = 100,
        .plan_ns = 200,
        .execute_ns = 300,
        .serialize_ns = 400,
    };
    try std.testing.expectEqual(@as(u64, 1000), b.total_ns());
}

test "SpatialIndexStats: init and update" {
    var stats = SpatialIndexStats.init();

    stats.updateFromIndex(5000, 10000);
    try std.testing.expectEqual(@as(i64, 5000), stats.ram_index_entries.get());
    try std.testing.expectEqual(@as(i64, 10000), stats.ram_index_capacity.get());
    try std.testing.expectEqual(@as(i64, 500), stats.ram_index_load_factor.get()); // 50%
}

test "SpatialIndexStats: recordCoveringSize EMA" {
    var stats = SpatialIndexStats.init();

    // First query sets initial value
    stats.recordCoveringSize(.radius, 8);
    try std.testing.expectEqual(@as(i64, 800), stats.avg_cells_radius); // 8 * 100

    // Subsequent queries use EMA
    stats.recordCoveringSize(.radius, 4);
    // EMA: (400 + 9 * 800) / 10 = 760
    try std.testing.expectEqual(@as(i64, 760), stats.avg_cells_radius);
}

test "SpatialIndexStats: toPrometheus produces valid output" {
    var stats = SpatialIndexStats.init();
    stats.updateFromIndex(1000, 2000);
    stats.recordCoveringSize(.radius, 6);

    var buffer: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try stats.toPrometheus(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_load_factor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_covering_cells_avg") != null);
}

test "QueryType: toString returns correct labels" {
    try std.testing.expectEqualStrings("uuid", QueryType.uuid.toString());
    try std.testing.expectEqualStrings("radius", QueryType.radius.toString());
    try std.testing.expectEqualStrings("polygon", QueryType.polygon.toString());
    try std.testing.expectEqualStrings("latest", QueryType.latest.toString());
}

// ============================================================================
// Dashboard Metrics Verification (14-06)
// ============================================================================
// This test documents all metrics used by the query performance dashboard
// (observability/grafana/dashboards/archerdb-query-performance.json) and
// verifies they are properly exported in Prometheus format.
//
// Metric sources:
// - QueryLatencyBreakdown: per-phase histograms, per-type total histograms
// - SpatialIndexStats: RAM index metrics, covering cell averages
// - QueryMetrics (geo_state_machine.zig): cache hit/miss counters
// - BatchQueryMetrics (batch_query.zig): batch operation counters
// - PreparedQueryMetrics (prepared_queries.zig): prepared query counters
// - metrics.zig global: s2_covering_cache_hits/misses_total

test "Dashboard metrics: QueryLatencyBreakdown exports all phase metrics" {
    var breakdown = QueryLatencyBreakdown.init();
    breakdown.recordPhases(.{
        .query_type = .radius,
        .parse_ns = 100_000,
        .plan_ns = 500_000,
        .execute_ns = 5_000_000,
        .serialize_ns = 200_000,
    });

    var buffer: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try breakdown.toPrometheus(writer);
    const output = stream.getWritten();

    // Per-phase histograms (dashboard: "Latency by Phase" panel)
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_parse_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_plan_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_execute_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_serialize_seconds") != null);

    // Per-type total histogram (dashboard: "Query Latency P99 by Type" panel)
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_total_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type=\"radius\"") != null);
}

test "Dashboard metrics: SpatialIndexStats exports RAM index and covering metrics" {
    var stats = SpatialIndexStats.init();
    stats.updateFromIndex(5000, 10000);
    stats.recordCoveringSize(.radius, 6);
    stats.recordCoveringSize(.polygon, 12);

    var buffer: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try stats.toPrometheus(writer);
    const output = stream.getWritten();

    // RAM index metrics (dashboard: "RAM Index Load Factor" and "RAM Index Entries" panels)
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_capacity") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_ram_index_load_factor") != null);

    // S2 covering cell statistics (dashboard: "Average Covering Cells" panel)
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_query_covering_cells_avg") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type=\"radius\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type=\"polygon\"") != null);
}
