//! Post-Filter Module for Precise Geometry Tests (F3.3.5)
//!
//! This module provides post-filtering utilities for spatial queries, ensuring
//! precise geometric tests after the coarse S2 cell filter. The two-phase
//! filtering approach is:
//!
//! ```
//! Phase 1 (Coarse): S2 cell range filter
//!   - Fast, O(1) per cell check
//!   - May have false positives (cells overlap query region but points don't)
//!
//! Phase 2 (Fine): This module's post-filter
//!   - Haversine distance for radius queries
//!   - Ray-casting for polygon queries
//!   - Deletion tombstone check (GDPR compliance)
//!   - Eliminates all false positives
//! ```
//!
//! ## Deletion Tombstone Handling
//!
//! Per compliance/spec.md, queries must apply `is_deleted(entity_id, consensus_timestamp)`
//! check to ensure deleted entities aren't returned, even if the physical block
//! was read before the delete was processed.
//!
//! ## Performance Characteristics
//!
//! Post-filter operations are more expensive than coarse filtering:
//! - Haversine: ~50ns per point (trig operations)
//! - Point-in-polygon: O(n) where n = vertex count
//! - Deletion check: O(1) with bloom filter, O(log n) LSM lookup if bloom positive
//!
//! The coarse filter typically eliminates 90%+ of candidates, making the
//! post-filter cost acceptable.

const std = @import("std");
const s2_index = @import("s2_index.zig");
const S2 = s2_index.S2;

/// Statistics for post-filter operations.
/// Used for monitoring false positive rates and optimization.
pub const PostFilterStats = struct {
    /// Number of candidates that passed coarse filter
    candidates_from_coarse: u64 = 0,

    /// Number of candidates that passed distance post-filter
    passed_distance_filter: u64 = 0,

    /// Number of candidates that passed polygon post-filter
    passed_polygon_filter: u64 = 0,

    /// Number of candidates that failed distance post-filter (false positives eliminated)
    failed_distance_filter: u64 = 0,

    /// Number of candidates that failed polygon post-filter (false positives eliminated)
    failed_polygon_filter: u64 = 0,

    /// Number of candidates filtered by deletion tombstone check
    filtered_by_deletion: u64 = 0,

    /// Number of candidates filtered by timestamp range
    filtered_by_timestamp: u64 = 0,

    /// Number of candidates filtered by TTL expiration
    filtered_by_ttl: u64 = 0,

    /// Reset statistics for a new query.
    pub fn reset(self: *PostFilterStats) void {
        self.* = .{};
    }

    /// Calculate the false positive rate for distance queries.
    /// A high rate suggests the S2 covering is too coarse.
    pub fn distanceFalsePositiveRate(self: PostFilterStats) f64 {
        const total = self.passed_distance_filter + self.failed_distance_filter;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.failed_distance_filter)) /
            @as(f64, @floatFromInt(total));
    }

    /// Calculate the false positive rate for polygon queries.
    pub fn polygonFalsePositiveRate(self: PostFilterStats) f64 {
        const total = self.passed_polygon_filter + self.failed_polygon_filter;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.failed_polygon_filter)) /
            @as(f64, @floatFromInt(total));
    }

    /// Export statistics in Prometheus format.
    pub fn toPrometheus(self: PostFilterStats, writer: anytype) !void {
        const s = self;
        try writer.print("archerdb_pf_candidates {d}\n", .{s.candidates_from_coarse});
        try writer.print("archerdb_pf_dist_passed {d}\n", .{s.passed_distance_filter});
        try writer.print("archerdb_pf_dist_failed {d}\n", .{s.failed_distance_filter});
        try writer.print("archerdb_pf_poly_passed {d}\n", .{s.passed_polygon_filter});
        try writer.print("archerdb_pf_poly_failed {d}\n", .{s.failed_polygon_filter});
        try writer.print("archerdb_pf_deleted {d}\n", .{s.filtered_by_deletion});
        try writer.print("archerdb_pf_ts_filtered {d}\n", .{s.filtered_by_timestamp});
        try writer.print("archerdb_pf_ttl_filtered {d}\n", .{s.filtered_by_ttl});
        try writer.print("archerdb_pf_dist_fp {d:.4}\n", .{s.distanceFalsePositiveRate()});
        try writer.print("archerdb_pf_poly_fp {d:.4}\n", .{s.polygonFalsePositiveRate()});
    }
};

/// Result of a post-filter check.
pub const FilterResult = enum {
    /// Candidate passes all filters
    pass,
    /// Failed distance filter (outside radius)
    fail_distance,
    /// Failed polygon filter (outside polygon)
    fail_polygon,
    /// Failed deletion check (entity was deleted)
    fail_deleted,
    /// Failed timestamp filter (outside time range)
    fail_timestamp,
    /// Failed TTL check (entity expired)
    fail_ttl,
};

/// Context for post-filter operations.
/// Holds the query parameters and accumulates statistics.
pub const PostFilterContext = struct {
    /// Statistics for this query
    stats: PostFilterStats = .{},

    /// Consensus timestamp for deletion and TTL checks
    consensus_timestamp: u64 = 0,

    /// Optional: Function to check if an entity is deleted
    /// Returns true if the entity has a deletion tombstone <= consensus_timestamp
    /// When LSM Forest is integrated, this will perform the actual lookup.
    is_deleted_fn: ?*const fn (entity_id: u128, timestamp: u64) bool = null,

    /// Check if a point passes the distance post-filter.
    ///
    /// Arguments:
    /// - point_lat_nano: Point latitude in nanodegrees
    /// - point_lon_nano: Point longitude in nanodegrees
    /// - center_lat_nano: Query center latitude in nanodegrees
    /// - center_lon_nano: Query center longitude in nanodegrees
    /// - radius_mm: Query radius in millimeters
    ///
    /// Returns: true if point is within radius
    pub fn checkDistance(
        self: *PostFilterContext,
        point_lat_nano: i64,
        point_lon_nano: i64,
        center_lat_nano: i64,
        center_lon_nano: i64,
        radius_mm: u64,
    ) bool {
        self.stats.candidates_from_coarse += 1;

        const passes = S2.isWithinDistance(
            center_lat_nano,
            center_lon_nano,
            point_lat_nano,
            point_lon_nano,
            radius_mm,
        );

        if (passes) {
            self.stats.passed_distance_filter += 1;
        } else {
            self.stats.failed_distance_filter += 1;
        }

        return passes;
    }

    /// Check if a point passes the polygon post-filter.
    ///
    /// Arguments:
    /// - point_lat_nano: Point latitude in nanodegrees
    /// - point_lon_nano: Point longitude in nanodegrees
    /// - polygon: Array of polygon vertices
    ///
    /// Returns: true if point is inside polygon
    pub fn checkPolygon(
        self: *PostFilterContext,
        point_lat_nano: i64,
        point_lon_nano: i64,
        polygon: []const s2_index.LatLon,
    ) bool {
        self.stats.candidates_from_coarse += 1;

        const point = s2_index.LatLon{
            .lat_nano = point_lat_nano,
            .lon_nano = point_lon_nano,
        };

        const passes = S2.pointInPolygon(point, polygon);

        if (passes) {
            self.stats.passed_polygon_filter += 1;
        } else {
            self.stats.failed_polygon_filter += 1;
        }

        return passes;
    }

    /// Check if an entity passes the deletion tombstone filter.
    ///
    /// Per compliance/spec.md: "Query engine applies `is_deleted(entity_id,
    /// consensus_timestamp)` check post-filter"
    ///
    /// Arguments:
    /// - entity_id: The entity to check
    ///
    /// Returns: true if entity is NOT deleted (passes filter)
    pub fn checkNotDeleted(self: *PostFilterContext, entity_id: u128) bool {
        if (self.is_deleted_fn) |check_fn| {
            if (check_fn(entity_id, self.consensus_timestamp)) {
                self.stats.filtered_by_deletion += 1;
                return false;
            }
        }
        // If no deletion check function is provided, assume not deleted
        // This is the case until LSM Forest integration is complete
        return true;
    }

    /// Check if a timestamp is within the query range.
    ///
    /// Arguments:
    /// - timestamp: Event timestamp to check
    /// - timestamp_min: Minimum timestamp (0 = no minimum)
    /// - timestamp_max: Maximum timestamp (0 = no maximum)
    ///
    /// Returns: true if timestamp is within range
    pub fn checkTimestamp(
        self: *PostFilterContext,
        timestamp: u64,
        timestamp_min: u64,
        timestamp_max: u64,
    ) bool {
        if (timestamp_min > 0 and timestamp < timestamp_min) {
            self.stats.filtered_by_timestamp += 1;
            return false;
        }
        if (timestamp_max > 0 and timestamp > timestamp_max) {
            self.stats.filtered_by_timestamp += 1;
            return false;
        }
        return true;
    }

    /// Check if an event has expired based on TTL.
    ///
    /// Arguments:
    /// - event_timestamp: When the event was created
    /// - ttl_seconds: Time-to-live in seconds (0 = no expiration)
    ///
    /// Returns: true if event is NOT expired (passes filter)
    pub fn checkNotExpired(
        self: *PostFilterContext,
        event_timestamp: u64,
        ttl_seconds: u32,
    ) bool {
        if (ttl_seconds == 0) {
            return true; // No TTL set
        }

        // Check if event has expired relative to consensus timestamp
        const ttl_ns: u64 = @as(u64, ttl_seconds) * 1_000_000_000;
        const expiry_time = event_timestamp +| ttl_ns; // Saturating add to prevent overflow

        if (self.consensus_timestamp > expiry_time) {
            self.stats.filtered_by_ttl += 1;
            return false;
        }

        return true;
    }

    /// Perform all post-filter checks for a radius query candidate.
    ///
    /// Returns: FilterResult indicating pass or failure reason
    pub fn filterRadiusCandidate(
        self: *PostFilterContext,
        entity_id: u128,
        point_lat_nano: i64,
        point_lon_nano: i64,
        event_timestamp: u64,
        ttl_seconds: u32,
        center_lat_nano: i64,
        center_lon_nano: i64,
        radius_mm: u64,
        timestamp_min: u64,
        timestamp_max: u64,
    ) FilterResult {
        // Check deletion first (cheapest if bloom filter says no)
        if (!self.checkNotDeleted(entity_id)) {
            return .fail_deleted;
        }

        // Check timestamp range
        if (!self.checkTimestamp(event_timestamp, timestamp_min, timestamp_max)) {
            return .fail_timestamp;
        }

        // Check TTL expiration
        if (!self.checkNotExpired(event_timestamp, ttl_seconds)) {
            return .fail_ttl;
        }

        // Check distance (most expensive, do last)
        const in_radius = self.checkDistance(
            point_lat_nano,
            point_lon_nano,
            center_lat_nano,
            center_lon_nano,
            radius_mm,
        );
        if (!in_radius) {
            return .fail_distance;
        }

        return .pass;
    }

    /// Perform all post-filter checks for a polygon query candidate.
    ///
    /// Returns: FilterResult indicating pass or failure reason
    pub fn filterPolygonCandidate(
        self: *PostFilterContext,
        entity_id: u128,
        point_lat_nano: i64,
        point_lon_nano: i64,
        event_timestamp: u64,
        ttl_seconds: u32,
        polygon: []const s2_index.LatLon,
        timestamp_min: u64,
        timestamp_max: u64,
    ) FilterResult {
        // Check deletion first
        if (!self.checkNotDeleted(entity_id)) {
            return .fail_deleted;
        }

        // Check timestamp range
        if (!self.checkTimestamp(event_timestamp, timestamp_min, timestamp_max)) {
            return .fail_timestamp;
        }

        // Check TTL expiration
        if (!self.checkNotExpired(event_timestamp, ttl_seconds)) {
            return .fail_ttl;
        }

        // Check polygon containment (expensive, do last)
        if (!self.checkPolygon(point_lat_nano, point_lon_nano, polygon)) {
            return .fail_polygon;
        }

        return .pass;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PostFilterStats: initialization" {
    const stats = PostFilterStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.candidates_from_coarse);
    try std.testing.expectEqual(@as(u64, 0), stats.passed_distance_filter);
    try std.testing.expectEqual(@as(u64, 0), stats.failed_distance_filter);
}

test "PostFilterStats: false positive rate calculation" {
    var stats = PostFilterStats{
        .passed_distance_filter = 80,
        .failed_distance_filter = 20,
    };

    // 20 out of 100 were false positives = 0.20
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), stats.distanceFalsePositiveRate(), 0.001);

    // Edge case: no candidates
    stats.reset();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), stats.distanceFalsePositiveRate(), 0.001);
}

test "PostFilterContext: distance filter" {
    var ctx = PostFilterContext{};

    // Point at origin, center at origin, 1km radius
    // Should pass
    try std.testing.expect(ctx.checkDistance(0, 0, 0, 0, 1_000_000));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.passed_distance_filter);
    try std.testing.expectEqual(@as(u64, 0), ctx.stats.failed_distance_filter);

    // Point at 10km away, center at origin, 1km radius
    // 10km ≈ 0.09 degrees latitude ≈ 90,000,000 nanodegrees
    // Should fail
    try std.testing.expect(!ctx.checkDistance(90_000_000_000, 0, 0, 0, 1_000_000));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.passed_distance_filter);
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.failed_distance_filter);
}

test "PostFilterContext: polygon filter" {
    var ctx = PostFilterContext{};

    // Simple square polygon: (0,0), (10°,0), (10°,10°), (0,10°)
    const polygon = [_]s2_index.LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Point inside square
    try std.testing.expect(ctx.checkPolygon(5_000_000_000, 5_000_000_000, &polygon));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.passed_polygon_filter);

    // Point outside square
    try std.testing.expect(!ctx.checkPolygon(15_000_000_000, 5_000_000_000, &polygon));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.failed_polygon_filter);
}

test "PostFilterContext: timestamp filter" {
    var ctx = PostFilterContext{};

    // Timestamp in range
    try std.testing.expect(ctx.checkTimestamp(500, 100, 1000));
    try std.testing.expectEqual(@as(u64, 0), ctx.stats.filtered_by_timestamp);

    // Timestamp below minimum
    try std.testing.expect(!ctx.checkTimestamp(50, 100, 1000));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.filtered_by_timestamp);

    // Timestamp above maximum
    try std.testing.expect(!ctx.checkTimestamp(1500, 100, 1000));
    try std.testing.expectEqual(@as(u64, 2), ctx.stats.filtered_by_timestamp);

    // No timestamp filter (0 = no limit)
    try std.testing.expect(ctx.checkTimestamp(500, 0, 0));
}

test "PostFilterContext: TTL expiration filter" {
    var ctx = PostFilterContext{
        .consensus_timestamp = 10_000_000_000, // 10 seconds in nanoseconds
    };

    // Event with no TTL (0 = never expires)
    try std.testing.expect(ctx.checkNotExpired(5_000_000_000, 0));
    try std.testing.expectEqual(@as(u64, 0), ctx.stats.filtered_by_ttl);

    // Event with TTL not expired (created at 5s, TTL 10s, consensus at 10s)
    try std.testing.expect(ctx.checkNotExpired(5_000_000_000, 10));

    // Event with TTL expired (created at 1s, TTL 5s = expires at 6s, consensus at 10s)
    try std.testing.expect(!ctx.checkNotExpired(1_000_000_000, 5));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.filtered_by_ttl);
}

test "PostFilterContext: deletion check with mock" {
    // Mock deletion check function
    const mock_is_deleted = struct {
        fn check(entity_id: u128, _: u64) bool {
            // Entity 42 is deleted, others are not
            return entity_id == 42;
        }
    }.check;

    var ctx = PostFilterContext{
        .consensus_timestamp = 1000,
        .is_deleted_fn = &mock_is_deleted,
    };

    // Non-deleted entity
    try std.testing.expect(ctx.checkNotDeleted(100));
    try std.testing.expectEqual(@as(u64, 0), ctx.stats.filtered_by_deletion);

    // Deleted entity
    try std.testing.expect(!ctx.checkNotDeleted(42));
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.filtered_by_deletion);
}

test "PostFilterContext: full radius candidate filter" {
    var ctx = PostFilterContext{
        .consensus_timestamp = 10_000_000_000,
    };

    // Candidate that passes all filters
    const result1 = ctx.filterRadiusCandidate(
        1, // entity_id
        0, // point_lat_nano
        0, // point_lon_nano
        5_000_000_000, // event_timestamp
        0, // ttl_seconds (no expiration)
        0, // center_lat_nano
        0, // center_lon_nano
        1_000_000, // radius_mm (1km)
        0, // timestamp_min
        0, // timestamp_max
    );
    try std.testing.expectEqual(FilterResult.pass, result1);

    // Candidate that fails distance filter
    const result2 = ctx.filterRadiusCandidate(
        2,
        90_000_000_000, // 90 degrees away
        0,
        5_000_000_000,
        0,
        0,
        0,
        1_000_000, // 1km radius
        0,
        0,
    );
    try std.testing.expectEqual(FilterResult.fail_distance, result2);
}

test "PostFilterContext: full polygon candidate filter" {
    var ctx = PostFilterContext{
        .consensus_timestamp = 10_000_000_000,
    };

    const polygon = [_]s2_index.LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Candidate inside polygon
    const result1 = ctx.filterPolygonCandidate(
        1,
        5_000_000_000,
        5_000_000_000,
        5_000_000_000,
        0,
        &polygon,
        0,
        0,
    );
    try std.testing.expectEqual(FilterResult.pass, result1);

    // Candidate outside polygon
    const result2 = ctx.filterPolygonCandidate(
        2,
        15_000_000_000,
        5_000_000_000,
        5_000_000_000,
        0,
        &polygon,
        0,
        0,
    );
    try std.testing.expectEqual(FilterResult.fail_polygon, result2);
}

test "PostFilterStats: prometheus export" {
    const stats = PostFilterStats{
        .candidates_from_coarse = 100,
        .passed_distance_filter = 80,
        .failed_distance_filter = 20,
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try stats.toPrometheus(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pf_candidates 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pf_dist_passed 80") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pf_dist_failed 20") != null);
}
