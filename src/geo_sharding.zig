// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Geo-Sharding: Geographic Partitioning for Data Locality
//!
//! This module provides geo-sharding capabilities for partitioning entities
//! across geographic regions based on their location or explicit assignment.
//!
//! Per replication/spec.md and index-sharding/spec.md:
//! - Entities assigned to regions based on `geo_shard_policy`
//! - Supports by_entity_location, by_entity_id_prefix, and explicit routing
//! - Cross-region query aggregation for spatial queries
//!
//! ## Geo-Shard Policies
//!
//! - **by_entity_location**: Route to nearest region based on entity lat/lon
//! - **by_entity_id_prefix**: Route based on entity_id prefix mapping
//! - **explicit**: Application specifies target region per entity
//!
//! ## Example
//!
//! ```zig
//! var config = GeoShardConfig.init();
//! config.policy = .by_entity_location;
//! config.addRegion("us-east", -74.006, 40.7128);
//! config.addRegion("eu-west", -0.1276, 51.5074);
//!
//! const region = config.routeEntity(entity_lat, entity_lon);
//! ```

const std = @import("std");
const stdx = @import("stdx");

/// Maximum number of geo-regions supported.
pub const max_regions: usize = 16;

/// Maximum length of a region name.
pub const max_region_name_len: usize = 32;

/// Maximum length of a region endpoint address.
pub const max_endpoint_len: usize = 128;

/// Geo-shard policy determining how entities are assigned to regions.
pub const GeoShardPolicy = enum(u8) {
    /// No geo-sharding - all entities stay in local region.
    none = 0,

    /// Route to nearest region based on entity lat/lon coordinates.
    /// Uses Haversine distance calculation for nearest region.
    by_entity_location = 1,

    /// Route based on entity_id prefix mapping to regions.
    /// First N bits of entity_id map to specific regions.
    by_entity_id_prefix = 2,

    /// Application explicitly specifies target region per entity.
    /// Requires `target_region` field in write requests.
    explicit = 3,

    pub fn toString(self: GeoShardPolicy) []const u8 {
        return switch (self) {
            .none => "none",
            .by_entity_location => "by_entity_location",
            .by_entity_id_prefix => "by_entity_id_prefix",
            .explicit => "explicit",
        };
    }

    pub fn fromString(s: []const u8) ?GeoShardPolicy {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "by_entity_location")) return .by_entity_location;
        if (std.mem.eql(u8, s, "by_entity_id_prefix")) return .by_entity_id_prefix;
        if (std.mem.eql(u8, s, "explicit")) return .explicit;
        return null;
    }
};

/// Geographic region definition for geo-sharding.
pub const GeoRegion = struct {
    /// Unique region identifier (e.g., "us-east-1", "eu-west-1").
    name: [max_region_name_len]u8,

    /// Region center latitude in nanodegrees (for by_entity_location).
    center_lat_nano: i64,

    /// Region center longitude in nanodegrees (for by_entity_location).
    center_lon_nano: i64,

    /// Primary endpoint address for this region.
    endpoint: [max_endpoint_len]u8,

    /// Region priority (lower = preferred for tie-breaking).
    priority: u16,

    /// Whether this region is active/available.
    active: bool,

    /// Whether this region accepts writes (vs read-only follower).
    writable: bool,

    /// Entity ID prefix bits (for by_entity_id_prefix policy).
    /// Entities with matching prefix route to this region.
    id_prefix: u32,

    /// Number of bits to match in id_prefix.
    id_prefix_bits: u8,

    /// Reserved for future use.
    _reserved: [7]u8,

    pub const empty_name: [max_region_name_len]u8 = [_]u8{0} ** max_region_name_len;
    pub const empty_endpoint: [max_endpoint_len]u8 = [_]u8{0} ** max_endpoint_len;

    /// Initialize with defaults.
    pub fn init() GeoRegion {
        return .{
            .name = empty_name,
            .center_lat_nano = 0,
            .center_lon_nano = 0,
            .endpoint = empty_endpoint,
            .priority = 0,
            .active = false,
            .writable = false,
            .id_prefix = 0,
            .id_prefix_bits = 0,
            ._reserved = [_]u8{0} ** 7,
        };
    }

    /// Set region name from string.
    pub fn setName(self: *GeoRegion, name: []const u8) void {
        self.name = empty_name;
        const len = @min(name.len, max_region_name_len);
        stdx.copy_disjoint(.exact, u8, self.name[0..len], name[0..len]);
    }

    /// Get region name as string slice.
    pub fn getName(self: *const GeoRegion) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    /// Set endpoint address from string.
    pub fn setEndpoint(self: *GeoRegion, endpoint: []const u8) void {
        self.endpoint = empty_endpoint;
        const len = @min(endpoint.len, max_endpoint_len);
        stdx.copy_disjoint(.exact, u8, self.endpoint[0..len], endpoint[0..len]);
    }

    /// Get endpoint as string slice.
    pub fn getEndpoint(self: *const GeoRegion) []const u8 {
        return std.mem.sliceTo(&self.endpoint, 0);
    }

    /// Set center coordinates from floating-point degrees.
    pub fn setCenter(self: *GeoRegion, lat_deg: f64, lon_deg: f64) void {
        self.center_lat_nano = @intFromFloat(lat_deg * 1e9);
        self.center_lon_nano = @intFromFloat(lon_deg * 1e9);
    }

    /// Get center latitude in degrees.
    pub fn getCenterLatDeg(self: *const GeoRegion) f64 {
        return @as(f64, @floatFromInt(self.center_lat_nano)) / 1e9;
    }

    /// Get center longitude in degrees.
    pub fn getCenterLonDeg(self: *const GeoRegion) f64 {
        return @as(f64, @floatFromInt(self.center_lon_nano)) / 1e9;
    }
};

/// Geo-sharding configuration for a cluster.
pub const GeoShardConfig = struct {
    /// Active geo-shard policy.
    policy: GeoShardPolicy,

    /// Configured regions.
    regions: [max_regions]GeoRegion,

    /// Number of configured regions.
    region_count: u8,

    /// Local region index (this node's region).
    local_region_idx: u8,

    /// Whether cross-region queries are enabled.
    cross_region_queries_enabled: bool,

    /// Maximum cross-region query timeout in milliseconds.
    cross_region_timeout_ms: u32,

    /// Reserved for future use.
    _reserved: [16]u8,

    /// Initialize with defaults.
    pub fn init() GeoShardConfig {
        return .{
            .policy = .none,
            .regions = [_]GeoRegion{GeoRegion.init()} ** max_regions,
            .region_count = 0,
            .local_region_idx = 0,
            .cross_region_queries_enabled = true,
            .cross_region_timeout_ms = 5000,
            ._reserved = [_]u8{0} ** 16,
        };
    }

    /// Add a region to the configuration.
    /// Returns region index on success, null if max regions reached.
    pub fn addRegion(
        self: *GeoShardConfig,
        name: []const u8,
        lat_deg: f64,
        lon_deg: f64,
        endpoint: []const u8,
    ) ?u8 {
        if (self.region_count >= max_regions) return null;

        const idx = self.region_count;
        self.regions[idx].setName(name);
        self.regions[idx].setCenter(lat_deg, lon_deg);
        self.regions[idx].setEndpoint(endpoint);
        self.regions[idx].active = true;
        self.regions[idx].writable = true;
        self.regions[idx].priority = idx;

        self.region_count += 1;
        return idx;
    }

    /// Get a region by index.
    pub fn getRegion(self: *const GeoShardConfig, idx: u8) ?*const GeoRegion {
        if (idx >= self.region_count) return null;
        return &self.regions[idx];
    }

    /// Get a region by name.
    pub fn getRegionByName(self: *const GeoShardConfig, name: []const u8) ?*const GeoRegion {
        for (self.regions[0..self.region_count]) |*region| {
            if (std.mem.eql(u8, region.getName(), name)) {
                return region;
            }
        }
        return null;
    }

    /// Get region index by name.
    pub fn getRegionIndexByName(self: *const GeoShardConfig, name: []const u8) ?u8 {
        for (self.regions[0..self.region_count], 0..) |*region, i| {
            if (std.mem.eql(u8, region.getName(), name)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Route an entity to a region based on the configured policy.
    /// For by_entity_location: uses entity coordinates.
    /// For by_entity_id_prefix: uses entity_id.
    /// Returns region index or null if no matching region.
    pub fn routeEntity(
        self: *const GeoShardConfig,
        entity_lat_nano: i64,
        entity_lon_nano: i64,
        entity_id: u128,
    ) ?u8 {
        return switch (self.policy) {
            .none => self.local_region_idx,
            .by_entity_location => self.routeByLocation(entity_lat_nano, entity_lon_nano),
            .by_entity_id_prefix => self.routeByIdPrefix(entity_id),
            .explicit => null, // Caller must specify region
        };
    }

    /// Route by geographic location - find nearest region.
    fn routeByLocation(self: *const GeoShardConfig, lat_nano: i64, lon_nano: i64) ?u8 {
        if (self.region_count == 0) return null;

        var nearest_idx: u8 = 0;
        var nearest_dist: f64 = std.math.floatMax(f64);

        for (self.regions[0..self.region_count], 0..) |*region, i| {
            if (!region.active or !region.writable) continue;

            const dist = haversineDistanceNano(
                lat_nano,
                lon_nano,
                region.center_lat_nano,
                region.center_lon_nano,
            );

            if (dist < nearest_dist) {
                nearest_dist = dist;
                nearest_idx = @intCast(i);
            }
        }

        return nearest_idx;
    }

    /// Route by entity ID prefix.
    fn routeByIdPrefix(self: *const GeoShardConfig, entity_id: u128) ?u8 {
        if (self.region_count == 0) return null;

        const high_bits: u32 = @truncate(entity_id >> 96);

        for (self.regions[0..self.region_count], 0..) |*region, i| {
            if (!region.active or !region.writable) continue;
            if (region.id_prefix_bits == 0) continue;

            const mask: u32 = @as(u32, 0xFFFFFFFF) << @intCast(32 - region.id_prefix_bits);
            if ((high_bits & mask) == (region.id_prefix & mask)) {
                return @intCast(i);
            }
        }

        // Default to first active region
        for (self.regions[0..self.region_count], 0..) |*region, i| {
            if (region.active and region.writable) return @intCast(i);
        }
        return null;
    }

    /// Get all regions that should receive a spatial query.
    /// For cross-region queries, returns all active regions.
    /// Returns number of regions written to output buffer.
    pub fn getQueryRegions(
        self: *const GeoShardConfig,
        output: []u8,
    ) u8 {
        if (!self.cross_region_queries_enabled) {
            if (output.len > 0) {
                output[0] = self.local_region_idx;
                return 1;
            }
            return 0;
        }

        var count: u8 = 0;
        for (self.regions[0..self.region_count], 0..) |*region, i| {
            if (region.active and count < output.len) {
                output[count] = @intCast(i);
                count += 1;
            }
        }
        return count;
    }

    /// Check if entity should be forwarded to another region.
    pub fn shouldForward(self: *const GeoShardConfig, target_region: u8) bool {
        return target_region != self.local_region_idx and target_region < self.region_count;
    }

    /// Get local region.
    pub fn getLocalRegion(self: *const GeoShardConfig) ?*const GeoRegion {
        return self.getRegion(self.local_region_idx);
    }
};

/// Entity-to-region metadata for tracking entity assignments.
pub const EntityRegionMetadata = struct {
    /// Entity ID.
    entity_id: u128,

    /// Assigned region index.
    region_idx: u8,

    /// Whether assignment was explicit (vs computed).
    explicit: bool,

    /// Timestamp of assignment (nanoseconds since epoch).
    assigned_ns: i128,

    /// Reserved for future use.
    _reserved: [6]u8,

    pub fn init(entity_id: u128, region_idx: u8, explicit: bool) EntityRegionMetadata {
        return .{
            .entity_id = entity_id,
            .region_idx = region_idx,
            .explicit = explicit,
            .assigned_ns = std.time.nanoTimestamp(),
            ._reserved = [_]u8{0} ** 6,
        };
    }
};

/// Cross-region query aggregation result.
pub const CrossRegionQueryResult = struct {
    /// Number of regions queried.
    regions_queried: u8,

    /// Number of regions that responded.
    regions_responded: u8,

    /// Number of regions that failed.
    regions_failed: u8,

    /// Total result count across all regions.
    total_count: u32,

    /// Whether result was truncated due to limit.
    truncated: bool,

    /// List of failed region indices.
    failed_regions: [max_regions]u8,

    /// Latency per region in microseconds.
    latencies_us: [max_regions]u32,

    pub fn init() CrossRegionQueryResult {
        return .{
            .regions_queried = 0,
            .regions_responded = 0,
            .regions_failed = 0,
            .total_count = 0,
            .truncated = false,
            .failed_regions = [_]u8{0} ** max_regions,
            .latencies_us = [_]u32{0} ** max_regions,
        };
    }

    /// Check if query had partial failures.
    pub fn hasPartialFailure(self: *const CrossRegionQueryResult) bool {
        return self.regions_failed > 0 and self.regions_responded > 0;
    }

    /// Check if query completely failed.
    pub fn hasTotalFailure(self: *const CrossRegionQueryResult) bool {
        return self.regions_failed > 0 and self.regions_responded == 0;
    }
};

// =============================================================================
// Haversine Distance Calculation
// =============================================================================

/// Earth radius in meters.
const earth_radius_m: f64 = 6_371_000.0;

/// Calculate Haversine distance between two points in nanodegrees.
/// Returns distance in meters.
pub fn haversineDistanceNano(
    lat1_nano: i64,
    lon1_nano: i64,
    lat2_nano: i64,
    lon2_nano: i64,
) f64 {
    const lat1 = @as(f64, @floatFromInt(lat1_nano)) / 1e9 * std.math.pi / 180.0;
    const lon1 = @as(f64, @floatFromInt(lon1_nano)) / 1e9 * std.math.pi / 180.0;
    const lat2 = @as(f64, @floatFromInt(lat2_nano)) / 1e9 * std.math.pi / 180.0;
    const lon2 = @as(f64, @floatFromInt(lon2_nano)) / 1e9 * std.math.pi / 180.0;

    const dlat = lat2 - lat1;
    const dlon = lon2 - lon1;

    const a = std.math.sin(dlat / 2.0) * std.math.sin(dlat / 2.0) +
        std.math.cos(lat1) * std.math.cos(lat2) *
            std.math.sin(dlon / 2.0) * std.math.sin(dlon / 2.0);
    const c = 2.0 * std.math.atan2(@sqrt(a), @sqrt(1.0 - a));

    return earth_radius_m * c;
}

// =============================================================================
// Tests
// =============================================================================

test "GeoShardPolicy toString and fromString" {
    const none_str = GeoShardPolicy.none.toString();
    const by_loc_str = GeoShardPolicy.by_entity_location.toString();
    const by_prefix_str = GeoShardPolicy.by_entity_id_prefix.toString();
    const explicit_str = GeoShardPolicy.explicit.toString();
    try std.testing.expectEqualStrings("none", none_str);
    try std.testing.expectEqualStrings("by_entity_location", by_loc_str);
    try std.testing.expectEqualStrings("by_entity_id_prefix", by_prefix_str);
    try std.testing.expectEqualStrings("explicit", explicit_str);

    const none = GeoShardPolicy.fromString("none").?;
    const by_loc = GeoShardPolicy.fromString("by_entity_location").?;
    try std.testing.expectEqual(GeoShardPolicy.none, none);
    try std.testing.expectEqual(GeoShardPolicy.by_entity_location, by_loc);
    try std.testing.expect(GeoShardPolicy.fromString("invalid") == null);
}

test "GeoRegion basic operations" {
    var region = GeoRegion.init();
    try std.testing.expect(!region.active);

    region.setName("us-east-1");
    try std.testing.expectEqualStrings("us-east-1", region.getName());

    region.setEndpoint("192.168.1.10:5000");
    try std.testing.expectEqualStrings("192.168.1.10:5000", region.getEndpoint());

    region.setCenter(40.7128, -74.006);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7128), region.getCenterLatDeg(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -74.006), region.getCenterLonDeg(), 1e-6);
}

test "GeoShardConfig add and get regions" {
    var config = GeoShardConfig.init();
    try std.testing.expectEqual(@as(u8, 0), config.region_count);

    const idx1 = config.addRegion("us-east", 40.7128, -74.006, "us.example.com:5000");
    try std.testing.expect(idx1 != null);
    try std.testing.expectEqual(@as(u8, 0), idx1.?);
    try std.testing.expectEqual(@as(u8, 1), config.region_count);

    const idx2 = config.addRegion("eu-west", 51.5074, -0.1276, "eu.example.com:5000");
    try std.testing.expect(idx2 != null);
    try std.testing.expectEqual(@as(u8, 1), idx2.?);
    try std.testing.expectEqual(@as(u8, 2), config.region_count);

    const region = config.getRegion(0);
    try std.testing.expect(region != null);
    try std.testing.expectEqualStrings("us-east", region.?.getName());

    const region_by_name = config.getRegionByName("eu-west");
    try std.testing.expect(region_by_name != null);
    try std.testing.expectEqualStrings("eu-west", region_by_name.?.getName());
}

test "GeoShardConfig route by location" {
    var config = GeoShardConfig.init();
    config.policy = .by_entity_location;

    // Add US East (New York)
    _ = config.addRegion("us-east", 40.7128, -74.006, "us.example.com:5000");

    // Add EU West (London)
    _ = config.addRegion("eu-west", 51.5074, -0.1276, "eu.example.com:5000");

    // Entity in Boston (closer to US East)
    const boston_lat: i64 = @intFromFloat(42.3601 * 1e9);
    const boston_lon: i64 = @intFromFloat(-71.0589 * 1e9);
    const boston_region = config.routeEntity(boston_lat, boston_lon, 0);
    try std.testing.expect(boston_region != null);
    try std.testing.expectEqual(@as(u8, 0), boston_region.?); // us-east

    // Entity in Paris (closer to EU West)
    const paris_lat: i64 = @intFromFloat(48.8566 * 1e9);
    const paris_lon: i64 = @intFromFloat(2.3522 * 1e9);
    const paris_region = config.routeEntity(paris_lat, paris_lon, 0);
    try std.testing.expect(paris_region != null);
    try std.testing.expectEqual(@as(u8, 1), paris_region.?); // eu-west
}

test "GeoShardConfig route by ID prefix" {
    var config = GeoShardConfig.init();
    config.policy = .by_entity_id_prefix;

    // Add regions with prefix mappings
    const idx1 = config.addRegion("us-east", 0, 0, "us.example.com:5000");
    config.regions[idx1.?].id_prefix = 0x00000000; // 00xx...
    config.regions[idx1.?].id_prefix_bits = 2;

    const idx2 = config.addRegion("eu-west", 0, 0, "eu.example.com:5000");
    config.regions[idx2.?].id_prefix = 0x80000000; // 10xx...
    config.regions[idx2.?].id_prefix_bits = 2;

    // Entity with 00xx prefix should go to us-east
    const entity1: u128 = 0x00000001_00000000_00000000_00000001;
    const region1 = config.routeEntity(0, 0, entity1);
    try std.testing.expect(region1 != null);
    try std.testing.expectEqual(@as(u8, 0), region1.?);

    // Entity with 10xx prefix should go to eu-west (high bit set)
    const entity2: u128 = 0x80000001_00000000_00000000_00000001;
    const region2 = config.routeEntity(0, 0, entity2);
    try std.testing.expect(region2 != null);
    try std.testing.expectEqual(@as(u8, 1), region2.?);
}

test "GeoShardConfig policy none routes to local" {
    var config = GeoShardConfig.init();
    config.policy = .none;
    config.local_region_idx = 2;
    _ = config.addRegion("region-0", 0, 0, "r0.example.com:5000");
    _ = config.addRegion("region-1", 0, 0, "r1.example.com:5000");
    _ = config.addRegion("region-2", 0, 0, "r2.example.com:5000");

    const region = config.routeEntity(0, 0, 0);
    try std.testing.expectEqual(@as(u8, 2), region.?);
}

test "haversineDistanceNano calculation" {
    // New York to London ~5570 km
    const ny_lat: i64 = @intFromFloat(40.7128 * 1e9);
    const ny_lon: i64 = @intFromFloat(-74.006 * 1e9);
    const london_lat: i64 = @intFromFloat(51.5074 * 1e9);
    const london_lon: i64 = @intFromFloat(-0.1276 * 1e9);

    const dist = haversineDistanceNano(ny_lat, ny_lon, london_lat, london_lon);

    // Should be approximately 5570 km (allow 5% tolerance)
    try std.testing.expect(dist > 5300000.0);
    try std.testing.expect(dist < 5800000.0);
}

test "CrossRegionQueryResult partial failure detection" {
    var result = CrossRegionQueryResult.init();
    result.regions_queried = 3;
    result.regions_responded = 2;
    result.regions_failed = 1;

    try std.testing.expect(result.hasPartialFailure());
    try std.testing.expect(!result.hasTotalFailure());

    result.regions_responded = 0;
    try std.testing.expect(!result.hasPartialFailure());
    try std.testing.expect(result.hasTotalFailure());
}

test "EntityRegionMetadata initialization" {
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const metadata = EntityRegionMetadata.init(entity_id, 2, true);

    try std.testing.expectEqual(entity_id, metadata.entity_id);
    try std.testing.expectEqual(@as(u8, 2), metadata.region_idx);
    try std.testing.expect(metadata.explicit);
    try std.testing.expect(metadata.assigned_ns > 0);
}

test "GeoShardConfig getQueryRegions" {
    var config = GeoShardConfig.init();
    config.cross_region_queries_enabled = true;

    _ = config.addRegion("region-0", 0, 0, "r0.example.com:5000");
    _ = config.addRegion("region-1", 0, 0, "r1.example.com:5000");
    _ = config.addRegion("region-2", 0, 0, "r2.example.com:5000");

    var output: [16]u8 = undefined;
    const count = config.getQueryRegions(&output);

    try std.testing.expectEqual(@as(u8, 3), count);
    try std.testing.expectEqual(@as(u8, 0), output[0]);
    try std.testing.expectEqual(@as(u8, 1), output[1]);
    try std.testing.expectEqual(@as(u8, 2), output[2]);
}

test "GeoShardConfig cross region disabled" {
    var config = GeoShardConfig.init();
    config.cross_region_queries_enabled = false;
    config.local_region_idx = 1;

    _ = config.addRegion("region-0", 0, 0, "r0.example.com:5000");
    _ = config.addRegion("region-1", 0, 0, "r1.example.com:5000");
    _ = config.addRegion("region-2", 0, 0, "r2.example.com:5000");

    var output: [16]u8 = undefined;
    const count = config.getQueryRegions(&output);

    try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(@as(u8, 1), output[0]); // local only
}
