// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Batch Query API for Dashboard Refresh Scenarios
//!
//! Provides a batch query operation that executes multiple queries in a single request
//! with DynamoDB-style partial success handling. Each query succeeds or fails independently
//! without affecting others.
//!
//! ## Wire Format
//!
//! Request format:
//! ```
//! [BatchQueryRequest header (8 bytes)]
//! [BatchQueryEntry + filter data] (repeated query_count times)
//! ```
//!
//! Response format:
//! ```
//! [BatchQueryResponse header (16 bytes)]
//! [BatchQueryResultEntry] (repeated for each processed query)
//! [Result data bytes] (concatenated query results)
//! ```
//!
//! ## Query ID Correlation
//!
//! Clients assign a `query_id` to each query in the batch. The response includes
//! the same `query_id` for each result, allowing clients to correlate results
//! with their original queries regardless of execution order.
//!
//! ## Partial Success
//!
//! Unlike transactional operations, batch queries use partial success semantics:
//! - Each query is executed independently
//! - A failed query does not affect other queries in the batch
//! - Response includes per-query status (0 = success, non-zero = error code)
//! - Clients should check each result's status

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const log = std.log.scoped(.batch_query);

const stdx = @import("stdx");
const constants = @import("constants.zig");

// Import query filter types from geo_state_machine
const geo_state_machine = @import("geo_state_machine.zig");
const QueryUuidFilter = geo_state_machine.QueryUuidFilter;
const QueryRadiusFilter = geo_state_machine.QueryRadiusFilter;
const QueryPolygonFilter = geo_state_machine.QueryPolygonFilter;
const QueryLatestFilter = geo_state_machine.QueryLatestFilter;

// ============================================================================
// Request Types
// ============================================================================

/// Batch query request header.
/// Followed by query_count BatchQueryEntry structures, each followed by its filter data.
pub const BatchQueryRequest = extern struct {
    /// Number of queries in batch (1 to max_queries_per_batch)
    query_count: u32,
    /// Reserved for future use (must be zero)
    reserved: u32 = 0,

    /// Maximum queries per batch (bounded by response size)
    pub const max_queries_per_batch: u32 = 100;

    comptime {
        assert(@sizeOf(BatchQueryRequest) == 8);
        assert(stdx.no_padding(BatchQueryRequest));
    }
};

/// Query type enumeration for batch queries.
/// Maps to existing query operations.
pub const QueryType = enum(u8) {
    /// UUID lookup (single entity by entity_id)
    uuid = 0,
    /// Radius query (entities within distance of center)
    radius = 1,
    /// Polygon query (entities within polygon boundary)
    polygon = 2,
    /// Latest query (most recent N events globally)
    latest = 3,

    /// Convert to string for logging/metrics.
    pub fn toString(self: QueryType) []const u8 {
        return switch (self) {
            .uuid => "uuid",
            .radius => "radius",
            .polygon => "polygon",
            .latest => "latest",
        };
    }
};

/// Batch query entry header.
/// Each entry is followed by query-specific filter data (variable size).
pub const BatchQueryEntry = extern struct {
    /// Query type determining filter format
    query_type: QueryType,
    /// Reserved for alignment
    _pad: [3]u8 = @splat(0),
    /// Client-assigned query ID for correlation (echoed in response)
    query_id: u32,

    comptime {
        assert(@sizeOf(BatchQueryEntry) == 8);
        assert(stdx.no_padding(BatchQueryEntry));
    }
};

// ============================================================================
// Response Types
// ============================================================================

/// Batch query response header.
/// Followed by total_count BatchQueryResultEntry structures, then result data.
pub const BatchQueryResponse = extern struct {
    /// Total queries in request
    total_count: u32,
    /// Number of successful queries
    success_count: u32,
    /// Number of failed queries
    error_count: u32,
    /// Set to 1 if response was truncated due to size limits
    has_more: u8,
    /// Reserved for future use
    _reserved: [3]u8 = @splat(0),

    comptime {
        assert(@sizeOf(BatchQueryResponse) == 16);
        assert(stdx.no_padding(BatchQueryResponse));
    }
};

/// Per-query result entry header.
/// Points to result data within the response body.
pub const BatchQueryResultEntry = extern struct {
    /// Client-assigned query ID (echoed from request)
    query_id: u32,
    /// Status code: 0 = success, non-zero = error code
    status: u8,
    /// Reserved for alignment
    _pad: [3]u8 = @splat(0),
    /// Offset to result data from start of result data section
    result_offset: u32,
    /// Length of result data in bytes
    result_length: u32,

    comptime {
        assert(@sizeOf(BatchQueryResultEntry) == 16);
        assert(stdx.no_padding(BatchQueryResultEntry));
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Returns the fixed filter size for a query type.
/// For variable-length types (polygon), returns 0 (caller must parse header).
pub fn filterSizeForType(query_type: QueryType) usize {
    return switch (query_type) {
        .uuid => @sizeOf(QueryUuidFilter),
        .radius => @sizeOf(QueryRadiusFilter),
        .polygon => 0, // Variable size: QueryPolygonFilter + vertices + holes
        .latest => @sizeOf(QueryLatestFilter),
    };
}

/// Returns the minimum filter size for a query type.
/// For variable-length types, returns the header size.
pub fn minFilterSizeForType(query_type: QueryType) usize {
    return switch (query_type) {
        .uuid => @sizeOf(QueryUuidFilter),
        .radius => @sizeOf(QueryRadiusFilter),
        .polygon => @sizeOf(QueryPolygonFilter), // Minimum is header
        .latest => @sizeOf(QueryLatestFilter),
    };
}

/// Calculate total filter size for a polygon query.
/// Polygon filter size = header + (vertex_count * sizeof(PolygonVertex)) + (hole_count * sizeof(HoleDescriptor))
pub fn polygonFilterSize(filter: *const QueryPolygonFilter) usize {
    const PolygonVertex = geo_state_machine.PolygonVertex;
    const HoleDescriptor = geo_state_machine.HoleDescriptor;

    return @sizeOf(QueryPolygonFilter) +
        @as(usize, filter.vertex_count) * @sizeOf(PolygonVertex) +
        @as(usize, filter.hole_count) * @sizeOf(HoleDescriptor);
}

// ============================================================================
// Batch Query Execution Result
// ============================================================================

/// Result of executing a single query within a batch.
pub const QueryExecutionResult = struct {
    /// Status code: 0 = success, non-zero = error
    status: u8,
    /// Length of result data written
    length: u32,
};

// ============================================================================
// Batch Query Metrics
// ============================================================================

/// Metrics for batch query operations.
pub const BatchQueryMetrics = struct {
    /// Total batch query operations
    batch_queries_total: u64 = 0,
    /// Total individual queries across all batches
    batch_query_size_total: u64 = 0,
    /// Total successful queries
    batch_query_success_total: u64 = 0,
    /// Total failed queries
    batch_query_error_total: u64 = 0,
    /// Total truncated responses
    batch_query_truncated_total: u64 = 0,

    /// Record a batch query execution.
    pub fn recordBatch(
        self: *BatchQueryMetrics,
        query_count: u32,
        success_count: u32,
        error_count: u32,
        truncated: bool,
    ) void {
        self.batch_queries_total += 1;
        self.batch_query_size_total += query_count;
        self.batch_query_success_total += success_count;
        self.batch_query_error_total += error_count;
        if (truncated) {
            self.batch_query_truncated_total += 1;
        }
    }

    /// Calculate average queries per batch.
    pub fn avgQueriesPerBatch(self: BatchQueryMetrics) f64 {
        if (self.batch_queries_total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.batch_query_size_total)) /
            @as(f64, @floatFromInt(self.batch_queries_total));
    }

    /// Calculate success rate (0.0 to 1.0).
    pub fn successRate(self: BatchQueryMetrics) f64 {
        const total = self.batch_query_success_total + self.batch_query_error_total;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.batch_query_success_total)) /
            @as(f64, @floatFromInt(total));
    }

    /// Export metrics in Prometheus text format.
    pub fn toPrometheus(self: BatchQueryMetrics, writer: anytype) !void {
        try writer.print(
            \\# HELP archerdb_batch_queries_total Total batch query operations
            \\# TYPE archerdb_batch_queries_total counter
            \\archerdb_batch_queries_total {d}
            \\# HELP archerdb_batch_query_size_total Total queries across all batches
            \\# TYPE archerdb_batch_query_size_total counter
            \\archerdb_batch_query_size_total {d}
            \\# HELP archerdb_batch_query_success_total Successful queries in batches
            \\# TYPE archerdb_batch_query_success_total counter
            \\archerdb_batch_query_success_total {d}
            \\# HELP archerdb_batch_query_error_total Failed queries in batches
            \\# TYPE archerdb_batch_query_error_total counter
            \\archerdb_batch_query_error_total {d}
            \\# HELP archerdb_batch_query_truncated_total Truncated batch responses
            \\# TYPE archerdb_batch_query_truncated_total counter
            \\archerdb_batch_query_truncated_total {d}
            \\
        , .{
            self.batch_queries_total,
            self.batch_query_size_total,
            self.batch_query_success_total,
            self.batch_query_error_total,
            self.batch_query_truncated_total,
        });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BatchQueryRequest: size and padding" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BatchQueryRequest));
}

test "BatchQueryEntry: size and padding" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BatchQueryEntry));
}

test "BatchQueryResponse: size and padding" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(BatchQueryResponse));
}

test "BatchQueryResultEntry: size and padding" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(BatchQueryResultEntry));
}

test "QueryType: toString returns correct labels" {
    try std.testing.expectEqualStrings("uuid", QueryType.uuid.toString());
    try std.testing.expectEqualStrings("radius", QueryType.radius.toString());
    try std.testing.expectEqualStrings("polygon", QueryType.polygon.toString());
    try std.testing.expectEqualStrings("latest", QueryType.latest.toString());
}

test "filterSizeForType: returns correct sizes" {
    try std.testing.expectEqual(@as(usize, 32), filterSizeForType(.uuid));
    try std.testing.expectEqual(@as(usize, 128), filterSizeForType(.radius));
    try std.testing.expectEqual(@as(usize, 0), filterSizeForType(.polygon)); // Variable
    try std.testing.expectEqual(@as(usize, 128), filterSizeForType(.latest));
}

test "minFilterSizeForType: returns correct minimum sizes" {
    try std.testing.expectEqual(@as(usize, 32), minFilterSizeForType(.uuid));
    try std.testing.expectEqual(@as(usize, 128), minFilterSizeForType(.radius));
    try std.testing.expectEqual(@as(usize, 128), minFilterSizeForType(.polygon));
    try std.testing.expectEqual(@as(usize, 128), minFilterSizeForType(.latest));
}

test "BatchQueryMetrics: record and calculate" {
    var metrics = BatchQueryMetrics{};

    // Record first batch: 5 queries, 4 success, 1 error
    metrics.recordBatch(5, 4, 1, false);
    try std.testing.expectEqual(@as(u64, 1), metrics.batch_queries_total);
    try std.testing.expectEqual(@as(u64, 5), metrics.batch_query_size_total);
    try std.testing.expectEqual(@as(u64, 4), metrics.batch_query_success_total);
    try std.testing.expectEqual(@as(u64, 1), metrics.batch_query_error_total);
    try std.testing.expectEqual(@as(u64, 0), metrics.batch_query_truncated_total);

    // Record second batch: 3 queries, 3 success, truncated
    metrics.recordBatch(3, 3, 0, true);
    try std.testing.expectEqual(@as(u64, 2), metrics.batch_queries_total);
    try std.testing.expectEqual(@as(u64, 8), metrics.batch_query_size_total);
    try std.testing.expectEqual(@as(u64, 1), metrics.batch_query_truncated_total);

    // Average: 8 queries / 2 batches = 4.0
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), metrics.avgQueriesPerBatch(), 0.001);

    // Success rate: 7 / 8 = 0.875
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), metrics.successRate(), 0.001);
}

test "BatchQueryMetrics: toPrometheus produces valid output" {
    var metrics = BatchQueryMetrics{};
    metrics.recordBatch(10, 9, 1, false);

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try metrics.toPrometheus(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_batch_queries_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_batch_query_size_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_batch_query_success_total") != null);
}
