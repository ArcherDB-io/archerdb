// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK - Type definitions
//!
//! This module defines the core types used by the ArcherDB Zig SDK, including:
//! - GeoEvent: The main data structure for geospatial events
//! - Query filters: RadiusFilter, PolygonFilter, LatestFilter
//! - Response types: QueryResult, InsertResult, DeleteResult
//! - Helper functions for coordinate conversions

const std = @import("std");

// ============================================================================
// Core Types
// ============================================================================

/// GeoEvent represents a single location update for an entity.
/// All coordinates use integer types for precision (nanodegrees, millimeters).
pub const GeoEvent = struct {
    /// Composite key (entity_id + timestamp). Auto-generated, do not set manually.
    id: u128 = 0,
    /// Unique identifier for the tracked entity. Must not be zero.
    entity_id: u128,
    /// Trip, session, or job correlation ID.
    correlation_id: u128 = 0,
    /// Application-specific metadata.
    user_data: u128 = 0,
    /// Latitude in nanodegrees (-90e9 to +90e9).
    lat_nano: i64,
    /// Longitude in nanodegrees (-180e9 to +180e9).
    lon_nano: i64,
    /// Fleet, region, or tenant identifier.
    group_id: u64 = 0,
    /// Timestamp in nanoseconds since epoch.
    timestamp: u64 = 0,
    /// Altitude in millimeters (-10,000,000 to +100,000,000).
    altitude_mm: i32 = 0,
    /// Speed in millimeters per second (0 to 1,000,000,000).
    velocity_mms: u32 = 0,
    /// Time-to-live in seconds (0 = never expire).
    ttl_seconds: u32 = 0,
    /// GPS accuracy radius in millimeters.
    accuracy_mm: u32 = 0,
    /// Heading in centidegrees (0 = North, 9000 = East).
    heading_cdeg: u16 = 0,
    /// Status flags (application-defined).
    flags: u16 = 0,
};

/// Vertex represents a coordinate point for polygon queries.
pub const Vertex = struct {
    lat_nano: i64,
    lon_nano: i64,
};

/// Hole represents a polygon hole (interior ring) to exclude from query.
pub const Hole = struct {
    vertices: []const Vertex,
};

// ============================================================================
// Query Filters
// ============================================================================

/// Filter for radius-based spatial queries.
pub const QueryRadiusFilter = struct {
    /// Center latitude in nanodegrees.
    center_lat_nano: i64,
    /// Center longitude in nanodegrees.
    center_lon_nano: i64,
    /// Radius in millimeters.
    radius_mm: u64,
    /// Maximum results to return.
    limit: u32 = 1000,
    /// Minimum timestamp (optional filter).
    timestamp_min: u64 = 0,
    /// Maximum timestamp (optional filter).
    timestamp_max: u64 = 0,
    /// Group ID filter (0 = all groups).
    group_id: u64 = 0,
    /// Cursor for pagination.
    cursor: u64 = 0,
};

/// Filter for polygon-based spatial queries.
pub const QueryPolygonFilter = struct {
    /// Outer boundary vertices (counter-clockwise).
    vertices: []const Vertex,
    /// Interior holes to exclude (clockwise).
    holes: []const Hole = &[_]Hole{},
    /// Maximum results to return.
    limit: u32 = 1000,
    /// Minimum timestamp (optional filter).
    timestamp_min: u64 = 0,
    /// Maximum timestamp (optional filter).
    timestamp_max: u64 = 0,
    /// Group ID filter (0 = all groups).
    group_id: u64 = 0,
    /// Cursor for pagination.
    cursor: u64 = 0,
};

/// Filter for querying most recent events.
pub const QueryLatestFilter = struct {
    /// Maximum results to return.
    limit: u32 = 1000,
    /// Group ID filter (0 = all groups).
    group_id: u64 = 0,
    /// Cursor for pagination.
    cursor: u64 = 0,
};

/// Filter for querying by UUID.
pub const QueryUUIDFilter = struct {
    entity_id: u128,
};

// ============================================================================
// Response Types
// ============================================================================

/// Result from query operations.
pub const QueryResult = struct {
    /// Matching events.
    events: std.ArrayList(GeoEvent),
    /// True if more results are available.
    has_more: bool = false,
    /// Cursor for next page.
    cursor: u64 = 0,

    pub fn deinit(self: *QueryResult) void {
        self.events.deinit();
    }
};

/// Result from batch UUID query.
pub const QueryUUIDBatchResult = struct {
    /// Found events.
    events: std.ArrayList(GeoEvent),
    /// Number of entities found.
    found_count: u32 = 0,
    /// Number of entities not found.
    not_found_count: u32 = 0,
    /// Indices of not-found entities.
    not_found_indices: std.ArrayList(u16),

    pub fn deinit(self: *QueryUUIDBatchResult) void {
        self.events.deinit();
        self.not_found_indices.deinit();
    }
};

/// Result code for individual event insert/upsert.
pub const InsertResultCode = enum(u16) {
    ok = 0,
    entity_id_must_not_be_zero = 7,
    lat_out_of_range = 9,
    lon_out_of_range = 10,
    heading_out_of_range = 11,
    invalid_timestamp = 12,
    unknown = 255,
};

/// Result for a single insert/upsert operation.
pub const InsertResult = struct {
    /// Index of the event in the original batch.
    index: u32,
    /// Result code (0 = success).
    code: InsertResultCode,
};

/// Result from delete operations.
pub const DeleteResult = struct {
    /// Number of entities deleted.
    deleted_count: u32 = 0,
    /// Number of entities not found.
    not_found_count: u32 = 0,
};

/// Response from TTL set operation.
pub const TtlSetResponse = struct {
    /// True if operation succeeded.
    success: bool,
    /// New TTL expiry timestamp (nanoseconds since epoch).
    expiry_ns: u64,
    /// Previous TTL seconds (0 if none).
    previous_ttl: u32,
};

/// Response from TTL extend operation.
pub const TtlExtendResponse = struct {
    /// True if operation succeeded.
    success: bool,
    /// New TTL expiry timestamp (nanoseconds since epoch).
    new_expiry_ns: u64,
    /// Previous TTL expiry timestamp.
    previous_expiry_ns: u64,
};

/// Response from TTL clear operation.
pub const TtlClearResponse = struct {
    /// True if operation succeeded.
    success: bool,
    /// True if entity had a TTL that was cleared.
    had_ttl: bool,
};

/// Shard status values.
pub const ShardStatus = enum(u8) {
    active = 0,
    migrating = 1,
    inactive = 2,
    unknown = 255,
};

/// Information about a single shard.
pub const ShardInfo = struct {
    id: u32,
    primary: []const u8,
    replicas: std.ArrayList([]const u8),
    status: ShardStatus,
    entity_count: u64,
    size_bytes: u64,

    pub fn deinit(self: *ShardInfo, allocator: std.mem.Allocator) void {
        for (self.replicas.items) |replica| {
            allocator.free(replica);
        }
        self.replicas.deinit();
        if (self.primary.len > 0) {
            allocator.free(self.primary);
        }
    }
};

/// Response from status operation.
pub const StatusResponse = struct {
    /// Server version.
    version: []const u8,
    /// Current entity count.
    entity_count: u64,
    /// RAM index utilization (bytes).
    ram_bytes: u64,
    /// Tombstone count.
    tombstone_count: u64,
    /// Cluster state (e.g., "healthy", "degraded").
    cluster_state: []const u8,
};

/// Response from topology operation.
pub const TopologyResponse = struct {
    /// Topology version.
    version: u64,
    /// Number of shards.
    num_shards: u32,
    /// Cluster ID.
    cluster_id: u128,
    /// Last topology change timestamp.
    last_change_ns: i64,
    /// Resharding status.
    resharding_status: u8,
    /// Shard information.
    shards: std.ArrayList(ShardInfo),

    pub fn deinit(self: *TopologyResponse, allocator: std.mem.Allocator) void {
        for (self.shards.items) |*shard| {
            shard.deinit(allocator);
        }
        self.shards.deinit();
    }
};

// ============================================================================
// Coordinate Conversion Helpers
// ============================================================================

/// Nanodegrees per degree.
pub const NANO_PER_DEGREE: i64 = 1_000_000_000;

/// Millimeters per meter.
pub const MM_PER_METER: i32 = 1_000;

/// Centidegrees per degree.
pub const CDEG_PER_DEGREE: u16 = 100;

/// Convert degrees to nanodegrees.
pub fn degreesToNano(degrees: f64) i64 {
    return @intFromFloat(degrees * @as(f64, @floatFromInt(NANO_PER_DEGREE)));
}

/// Convert nanodegrees to degrees.
pub fn nanoToDegrees(nano: i64) f64 {
    return @as(f64, @floatFromInt(nano)) / @as(f64, @floatFromInt(NANO_PER_DEGREE));
}

/// Convert meters to millimeters.
pub fn metersToMm(meters: f64) i32 {
    return @intFromFloat(meters * @as(f64, @floatFromInt(MM_PER_METER)));
}

/// Convert millimeters to meters.
pub fn mmToMeters(mm: i32) f64 {
    return @as(f64, @floatFromInt(mm)) / @as(f64, @floatFromInt(MM_PER_METER));
}

/// Convert meters to millimeters (unsigned).
pub fn metersToMmUnsigned(meters: f64) u32 {
    return @intFromFloat(meters * @as(f64, @floatFromInt(MM_PER_METER)));
}

/// Convert meters per second to millimeters per second.
pub fn mpsToMms(mps: f64) u32 {
    return @intFromFloat(mps * 1000.0);
}

/// Convert millimeters per second to meters per second.
pub fn mmsToMps(mms: u32) f64 {
    return @as(f64, @floatFromInt(mms)) / 1000.0;
}

/// Convert heading degrees to centidegrees.
pub fn degreesToCdeg(degrees: f64) u16 {
    const normalized = @mod(degrees, 360.0);
    return @intFromFloat(normalized * @as(f64, @floatFromInt(CDEG_PER_DEGREE)));
}

/// Convert centidegrees to degrees.
pub fn cdegToDegrees(cdeg: u16) f64 {
    return @as(f64, @floatFromInt(cdeg)) / @as(f64, @floatFromInt(CDEG_PER_DEGREE));
}

// ============================================================================
// Validation Constants
// ============================================================================

/// Maximum latitude in nanodegrees (+90 degrees).
pub const MAX_LAT_NANO: i64 = 90_000_000_000;

/// Minimum latitude in nanodegrees (-90 degrees).
pub const MIN_LAT_NANO: i64 = -90_000_000_000;

/// Maximum longitude in nanodegrees (+180 degrees).
pub const MAX_LON_NANO: i64 = 180_000_000_000;

/// Minimum longitude in nanodegrees (-180 degrees).
pub const MIN_LON_NANO: i64 = -180_000_000_000;

/// Maximum heading in centidegrees (360 degrees).
pub const MAX_HEADING_CDEG: u16 = 36000;

/// Maximum batch size for insert/upsert/delete operations.
pub const BATCH_SIZE_MAX: usize = 10_000;

/// Maximum query limit.
pub const QUERY_LIMIT_MAX: u32 = 81_000;

/// Maximum polygon vertices.
pub const POLYGON_VERTICES_MAX: usize = 10_000;

/// Maximum polygon holes.
pub const POLYGON_HOLES_MAX: usize = 100;

// ============================================================================
// Validation Functions
// ============================================================================

/// Validate that latitude is within valid range.
pub fn isValidLatitude(lat_nano: i64) bool {
    return lat_nano >= MIN_LAT_NANO and lat_nano <= MAX_LAT_NANO;
}

/// Validate that longitude is within valid range.
pub fn isValidLongitude(lon_nano: i64) bool {
    return lon_nano >= MIN_LON_NANO and lon_nano <= MAX_LON_NANO;
}

/// Validate that heading is within valid range.
pub fn isValidHeading(heading_cdeg: u16) bool {
    return heading_cdeg <= MAX_HEADING_CDEG;
}

/// Validate a GeoEvent for insert/upsert.
pub fn validateGeoEvent(event: GeoEvent) ?InsertResultCode {
    if (event.entity_id == 0) {
        return .entity_id_must_not_be_zero;
    }
    if (!isValidLatitude(event.lat_nano)) {
        return .lat_out_of_range;
    }
    if (!isValidLongitude(event.lon_nano)) {
        return .lon_out_of_range;
    }
    if (!isValidHeading(event.heading_cdeg)) {
        return .heading_out_of_range;
    }
    return null; // Valid
}

// ============================================================================
// Tests
// ============================================================================

test "degreesToNano and nanoToDegrees" {
    const lat = 37.7749;
    const nano = degreesToNano(lat);
    try std.testing.expectEqual(@as(i64, 37774900000), nano);

    const back = nanoToDegrees(nano);
    try std.testing.expectApproxEqAbs(lat, back, 0.0001);
}

test "metersToMm and mmToMeters" {
    const meters = 100.5;
    const mm = metersToMm(meters);
    try std.testing.expectEqual(@as(i32, 100500), mm);

    const back = mmToMeters(mm);
    try std.testing.expectApproxEqAbs(meters, back, 0.001);
}

test "degreesToCdeg and cdegToDegrees" {
    const degrees = 90.0;
    const cdeg = degreesToCdeg(degrees);
    try std.testing.expectEqual(@as(u16, 9000), cdeg);

    const back = cdegToDegrees(cdeg);
    try std.testing.expectApproxEqAbs(degrees, back, 0.01);
}

test "validateGeoEvent valid" {
    const event = GeoEvent{
        .entity_id = 12345,
        .lat_nano = degreesToNano(37.7749),
        .lon_nano = degreesToNano(-122.4194),
    };
    try std.testing.expectEqual(@as(?InsertResultCode, null), validateGeoEvent(event));
}

test "validateGeoEvent invalid entity_id" {
    const event = GeoEvent{
        .entity_id = 0,
        .lat_nano = 0,
        .lon_nano = 0,
    };
    try std.testing.expectEqual(InsertResultCode.entity_id_must_not_be_zero, validateGeoEvent(event).?);
}

test "validateGeoEvent invalid latitude" {
    const event = GeoEvent{
        .entity_id = 1,
        .lat_nano = 100_000_000_000, // 100 degrees - invalid
        .lon_nano = 0,
    };
    try std.testing.expectEqual(InsertResultCode.lat_out_of_range, validateGeoEvent(event).?);
}

test "boundary coordinates" {
    try std.testing.expect(isValidLatitude(MAX_LAT_NANO));
    try std.testing.expect(isValidLatitude(MIN_LAT_NANO));
    try std.testing.expect(isValidLongitude(MAX_LON_NANO));
    try std.testing.expect(isValidLongitude(MIN_LON_NANO));

    try std.testing.expect(!isValidLatitude(MAX_LAT_NANO + 1));
    try std.testing.expect(!isValidLongitude(MAX_LON_NANO + 1));
}
