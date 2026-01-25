// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! S2 Covering Cache - Caches computed S2 cell coverings for spatial queries
//!
//! S2 RegionCoverer computation is expensive. Dashboard queries often use the same
//! geographic regions (fleet monitoring areas, delivery zones). This cache eliminates
//! redundant computation for repeated spatial query patterns.
//!
//! ## Key Design Decisions
//!
//! - **Integer-only keys**: Cache keys use only integers (nanodegrees, millimeters)
//!   to ensure hash stability. Floating-point representation issues could cause
//!   cache misses for semantically identical queries.
//!
//! - **CLOCK eviction**: Uses set-associative cache with CLOCK (Nth-Chance)
//!   eviction to retain frequently-used coverings while bounding memory.
//!
//! - **No write invalidation needed**: S2 cell coverings are determined purely
//!   by geometry (region parameters), not by data. The same region always produces
//!   the same covering, so cached values never become stale.
//!
//! ## Usage
//!
//! ```zig
//! var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "s2_covering" });
//! defer cache.deinit(allocator);
//!
//! // Try cache first for radius query
//! if (cache.getCapCovering(lat_nano, lon_nano, radius_mm)) |cached| {
//!     // Use cached covering
//!     const ranges = cached.ranges[0..cached.num_ranges];
//! } else {
//!     // Compute and cache
//!     const ranges = S2.coverCap(...);
//!     cache.putCapCovering(lat_nano, lon_nano, radius_mm, ranges);
//! }
//! ```

const std = @import("std");
const s2_index = @import("s2_index.zig");
const SetAssociativeCacheType = @import("lsm/set_associative_cache.zig").SetAssociativeCacheType;
const stdx = @import("stdx");

const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

/// Import CellRange from s2_index
pub const CellRange = s2_index.CellRange;

/// Maximum number of cell ranges in a cached covering
pub const s2_max_cells = s2_index.s2_max_cells;

/// Cached S2 cell covering
///
/// Stores a computed S2 cell covering along with the parameter hash
/// for cache validation. The ranges array is fixed-size with num_ranges
/// indicating how many entries are valid.
///
/// Size is padded to 512 bytes (power of 2) for SetAssociativeCacheType compatibility.
pub const CachedCovering = struct {
    /// Hash of the parameters used to compute this covering.
    /// Used for cache key validation on lookup.
    param_hash: u64,

    /// Number of valid cell ranges (0 to s2_max_cells)
    num_ranges: u8,

    /// Padding to ensure proper alignment after num_ranges
    _reserved1: [7]u8 = [_]u8{0} ** 7,

    /// The computed cell ranges. Only ranges[0..num_ranges] are valid.
    ranges: [s2_max_cells]CellRange,

    /// Padding to reach 512 bytes (power of 2) for SetAssociativeCacheType.
    /// 512 - 8 (param_hash) - 1 (num_ranges) - 7 (reserved1) - 256 (ranges) = 240
    _reserved2: [240]u8 = [_]u8{0} ** 240,

    /// Create a CachedCovering from computed ranges
    pub fn fromRanges(param_hash: u64, ranges: [s2_max_cells]CellRange) CachedCovering {
        // Count valid ranges (non-empty)
        var num_ranges: u8 = 0;
        for (ranges) |range| {
            if (range.start != 0 or range.end != 0) {
                num_ranges += 1;
            }
        }

        return .{
            .param_hash = param_hash,
            .num_ranges = num_ranges,
            .ranges = ranges,
        };
    }

    /// Check if this covering is empty
    pub fn isEmpty(self: CachedCovering) bool {
        return self.num_ranges == 0;
    }
};

// Compile-time assertions for cache layout
comptime {
    // Ensure CachedCovering is power-of-2 size for SetAssociativeCacheType
    // CellRange is 2 x u64 = 16 bytes, s2_max_cells = 16, so ranges = 256 bytes
    // param_hash (8) + num_ranges (1) + reserved1 (7) + ranges (256) + reserved2 (240) = 512 bytes
    assert(@sizeOf(CachedCovering) == 512);
    assert(@alignOf(CachedCovering) == 8);
    assert(std.math.isPowerOfTwo(@sizeOf(CachedCovering)));
}

/// Hash function for cap (radius) query parameters.
///
/// CRITICAL: Uses only integer types to ensure hash stability.
/// Floating-point representations can vary, causing cache misses
/// for semantically identical queries.
///
/// Parameters:
/// - center_lat_nano: Latitude in nanodegrees
/// - center_lon_nano: Longitude in nanodegrees
/// - radius_mm: Radius in millimeters
pub fn hashCapParams(center_lat_nano: i64, center_lon_nano: i64, radius_mm: u32) u64 {
    // Use stdx.hash_inline for deterministic hashing of each component
    // Combine with prime multipliers to spread bits
    // Cast to unsigned for hash_inline which requires unsigned ints
    var h: u64 = 0;
    h ^= stdx.hash_inline(@as(u64, @bitCast(center_lat_nano)));
    h ^= stdx.hash_inline(@as(u64, @bitCast(center_lon_nano))) *% 31;
    h ^= stdx.hash_inline(@as(u32, radius_mm)) *% 17;
    return h;
}

/// Hash function for polygon query parameters.
///
/// CRITICAL: Uses only integer types to ensure hash stability.
/// Hashes all vertex coordinates in order to create a unique key
/// for each distinct polygon.
///
/// Parameters:
/// - vertices: Array of LatLon vertices defining the polygon
pub fn hashPolygonParams(vertices: []const s2_index.LatLon) u64 {
    // Hash all vertices in order
    // Cast to unsigned for hash_inline which requires unsigned ints
    var h: u64 = 0;
    for (vertices) |v| {
        h ^= stdx.hash_inline(@as(u64, @bitCast(v.lat_nano)));
        h ^= stdx.hash_inline(@as(u64, @bitCast(v.lon_nano))) *% 31;
    }
    return h;
}

/// Internal cache key (just the param_hash)
const CacheKey = u64;

/// Key extraction function for SetAssociativeCache
inline fn keyFromValue(value: *const CachedCovering) CacheKey {
    return value.param_hash;
}

/// Hash function for cache keys
inline fn hashKey(key: CacheKey) u64 {
    return key;
}

/// S2 Covering Cache
///
/// A set-associative cache with CLOCK eviction for storing computed
/// S2 cell coverings. Optimized for spatial dashboard queries that
/// repeatedly use the same geographic regions.
///
/// The cache uses a 16-way set-associative design with CLOCK eviction
/// (Nth-Chance algorithm) to retain frequently-accessed coverings
/// while bounding memory usage.
pub const S2CoveringCache = struct {
    const Cache = SetAssociativeCacheType(
        CacheKey,
        CachedCovering,
        keyFromValue,
        hashKey,
        .{
            .ways = 16,
            .tag_bits = 8,
            .clock_bits = 2,
            .cache_line_size = 64,
            .value_alignment = 8,
        },
    );

    /// Underlying set-associative cache
    cache: Cache,

    /// Initialize the S2 covering cache
    ///
    /// Parameters:
    /// - allocator: Memory allocator
    /// - value_count_max: Maximum number of cached coverings (must be >= 16)
    /// - options: Cache configuration options
    pub fn init(
        allocator: mem.Allocator,
        value_count_max: u64,
        options: Cache.Options,
    ) !S2CoveringCache {
        // Ensure value_count_max meets SetAssociativeCache requirements
        const aligned_count = alignToMultiple(value_count_max, Cache.value_count_max_multiple);

        return .{
            .cache = try Cache.init(allocator, aligned_count, options),
        };
    }

    /// Deinitialize the cache and free memory
    pub fn deinit(self: *S2CoveringCache, allocator: mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    /// Reset the cache, clearing all entries
    pub fn reset(self: *S2CoveringCache) void {
        self.cache.reset();
    }

    /// Get a cached covering for a cap (radius) query
    ///
    /// Returns the cached covering if found, or null if not cached.
    pub fn getCapCovering(
        self: *const S2CoveringCache,
        center_lat_nano: i64,
        center_lon_nano: i64,
        radius_mm: u32,
    ) ?CachedCovering {
        const param_hash = hashCapParams(center_lat_nano, center_lon_nano, radius_mm);
        if (self.cache.get(param_hash)) |cached| {
            // Validate param_hash matches (handles tag collisions)
            if (cached.param_hash == param_hash) {
                return cached.*;
            }
        }
        return null;
    }

    /// Store a computed covering for a cap (radius) query
    pub fn putCapCovering(
        self: *S2CoveringCache,
        center_lat_nano: i64,
        center_lon_nano: i64,
        radius_mm: u32,
        ranges: [s2_max_cells]CellRange,
    ) void {
        const param_hash = hashCapParams(center_lat_nano, center_lon_nano, radius_mm);
        const covering = CachedCovering.fromRanges(param_hash, ranges);
        _ = self.cache.upsert(&covering);
    }

    /// Get a cached covering for a polygon query by pre-computed hash
    ///
    /// Returns the cached covering if found, or null if not cached.
    pub fn getPolygonCovering(
        self: *const S2CoveringCache,
        vertices_hash: u64,
    ) ?CachedCovering {
        if (self.cache.get(vertices_hash)) |cached| {
            // Validate param_hash matches (handles tag collisions)
            if (cached.param_hash == vertices_hash) {
                return cached.*;
            }
        }
        return null;
    }

    /// Store a computed covering for a polygon query
    pub fn putPolygonCovering(
        self: *S2CoveringCache,
        vertices_hash: u64,
        ranges: [s2_max_cells]CellRange,
    ) void {
        const covering = CachedCovering.fromRanges(vertices_hash, ranges);
        _ = self.cache.upsert(&covering);
    }

    /// Get current cache metrics
    pub fn getMetrics(self: *const S2CoveringCache) struct { hits: u64, misses: u64 } {
        return .{
            .hits = self.cache.metrics.hits,
            .misses = self.cache.metrics.misses,
        };
    }

    /// Helper: Align value to multiple
    fn alignToMultiple(value: u64, multiple: u64) u64 {
        if (value % multiple == 0) return value;
        return ((value / multiple) + 1) * multiple;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "S2CoveringCache: cap covering cache hit/miss" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_cap" });
    defer cache.deinit(allocator);

    // Test parameters (San Francisco)
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;
    const radius_mm: u32 = 1000_000; // 1km

    // Initially should miss
    try std.testing.expect(cache.getCapCovering(lat_nano, lon_nano, radius_mm) == null);

    // Create test covering
    var ranges: [s2_max_cells]CellRange = undefined;
    for (&ranges, 0..) |*range, i| {
        if (i < 3) {
            range.* = .{ .start = @as(u64, i) * 1000 + 1, .end = @as(u64, i) * 1000 + 100 };
        } else {
            range.* = .{ .start = 0, .end = 0 };
        }
    }

    // Cache the covering
    cache.putCapCovering(lat_nano, lon_nano, radius_mm, ranges);

    // Now should hit
    const cached = cache.getCapCovering(lat_nano, lon_nano, radius_mm);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(u8, 3), cached.?.num_ranges);
    try std.testing.expectEqual(ranges[0], cached.?.ranges[0]);
    try std.testing.expectEqual(ranges[1], cached.?.ranges[1]);
    try std.testing.expectEqual(ranges[2], cached.?.ranges[2]);
}

test "S2CoveringCache: different coordinates produce different keys" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_diff" });
    defer cache.deinit(allocator);

    // Two different locations
    const lat1: i64 = 37_774900000;
    const lon1: i64 = -122_419400000;
    const lat2: i64 = 40_712800000; // New York
    const lon2: i64 = -74_006000000;
    const radius_mm: u32 = 1000_000;

    var ranges1: [s2_max_cells]CellRange = undefined;
    var ranges2: [s2_max_cells]CellRange = undefined;
    for (&ranges1, 0..) |*range, i| {
        if (i == 0) {
            range.* = .{ .start = 100, .end = 200 };
        } else {
            range.* = .{ .start = 0, .end = 0 };
        }
    }
    for (&ranges2, 0..) |*range, i| {
        if (i == 0) {
            range.* = .{ .start = 300, .end = 400 };
        } else {
            range.* = .{ .start = 0, .end = 0 };
        }
    }

    // Cache both
    cache.putCapCovering(lat1, lon1, radius_mm, ranges1);
    cache.putCapCovering(lat2, lon2, radius_mm, ranges2);

    // Each should return its own covering
    const cached1 = cache.getCapCovering(lat1, lon1, radius_mm);
    const cached2 = cache.getCapCovering(lat2, lon2, radius_mm);

    try std.testing.expect(cached1 != null);
    try std.testing.expect(cached2 != null);
    try std.testing.expectEqual(@as(u64, 100), cached1.?.ranges[0].start);
    try std.testing.expectEqual(@as(u64, 300), cached2.?.ranges[0].start);
}

test "S2CoveringCache: same coordinates produce same key (deterministic)" {
    // Test hash determinism
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;
    const radius_mm: u32 = 1000_000;

    const hash1 = hashCapParams(lat_nano, lon_nano, radius_mm);
    const hash2 = hashCapParams(lat_nano, lon_nano, radius_mm);
    const hash3 = hashCapParams(lat_nano, lon_nano, radius_mm);

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expectEqual(hash2, hash3);
}

test "S2CoveringCache: polygon covering cache hit/miss" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_poly" });
    defer cache.deinit(allocator);

    // Test polygon (triangle)
    const vertices = [_]s2_index.LatLon{
        .{ .lat_nano = 37_000_000_000, .lon_nano = -122_000_000_000 },
        .{ .lat_nano = 38_000_000_000, .lon_nano = -122_000_000_000 },
        .{ .lat_nano = 37_500_000_000, .lon_nano = -121_000_000_000 },
    };
    const vertices_hash = hashPolygonParams(&vertices);

    // Initially should miss
    try std.testing.expect(cache.getPolygonCovering(vertices_hash) == null);

    // Create test covering
    var ranges: [s2_max_cells]CellRange = undefined;
    for (&ranges, 0..) |*range, i| {
        if (i < 2) {
            range.* = .{ .start = @as(u64, i) * 500 + 1, .end = @as(u64, i) * 500 + 50 };
        } else {
            range.* = .{ .start = 0, .end = 0 };
        }
    }

    // Cache the covering
    cache.putPolygonCovering(vertices_hash, ranges);

    // Now should hit
    const cached = cache.getPolygonCovering(vertices_hash);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(u8, 2), cached.?.num_ranges);
}

test "S2CoveringCache: different polygons produce different keys" {
    const vertices1 = [_]s2_index.LatLon{
        .{ .lat_nano = 37_000_000_000, .lon_nano = -122_000_000_000 },
        .{ .lat_nano = 38_000_000_000, .lon_nano = -122_000_000_000 },
        .{ .lat_nano = 37_500_000_000, .lon_nano = -121_000_000_000 },
    };
    const vertices2 = [_]s2_index.LatLon{
        .{ .lat_nano = 40_000_000_000, .lon_nano = -74_000_000_000 },
        .{ .lat_nano = 41_000_000_000, .lon_nano = -74_000_000_000 },
        .{ .lat_nano = 40_500_000_000, .lon_nano = -73_000_000_000 },
    };

    const hash1 = hashPolygonParams(&vertices1);
    const hash2 = hashPolygonParams(&vertices2);

    try std.testing.expect(hash1 != hash2);
}

test "S2CoveringCache: integer-only key stability" {
    // Test that hash functions only use integers - no floating point
    // Same nanodegree values should always produce same hash
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;

    // Different radius values should produce different hashes
    const hash_1km = hashCapParams(lat_nano, lon_nano, 1000_000);
    const hash_2km = hashCapParams(lat_nano, lon_nano, 2000_000);
    const hash_1km_again = hashCapParams(lat_nano, lon_nano, 1000_000);

    try std.testing.expect(hash_1km != hash_2km);
    try std.testing.expectEqual(hash_1km, hash_1km_again);
}

test "S2CoveringCache: CLOCK eviction under pressure" {
    const allocator = std.testing.allocator;

    // Use small cache to force eviction
    var cache = try S2CoveringCache.init(allocator, 32, .{ .name = "test_evict" });
    defer cache.deinit(allocator);

    var ranges: [s2_max_cells]CellRange = undefined;
    for (&ranges) |*range| {
        range.* = .{ .start = 0, .end = 0 };
    }
    ranges[0] = .{ .start = 1, .end = 100 };

    // Fill cache with many entries
    const base_lat: i64 = 37_000_000_000;
    const base_lon: i64 = -122_000_000_000;
    const radius_mm: u32 = 1000_000;

    // Insert more entries than cache can hold
    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        cache.putCapCovering(base_lat + i * 1_000_000, base_lon, radius_mm, ranges);
    }

    // Cache should still be functional (not crash, not grow unbounded)
    // Recent entries should be findable (CLOCK favors recently accessed)
    var found_count: usize = 0;
    i = 90; // Check last 10 entries
    while (i < 100) : (i += 1) {
        if (cache.getCapCovering(base_lat + i * 1_000_000, base_lon, radius_mm) != null) {
            found_count += 1;
        }
    }

    // At least some recent entries should be found
    // (Exact count depends on CLOCK eviction timing)
    try std.testing.expect(found_count > 0);
}

test "S2CoveringCache: edge case - zero radius" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_zero" });
    defer cache.deinit(allocator);

    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;
    const zero_radius: u32 = 0;

    // Zero radius should work (hash is still deterministic)
    var ranges: [s2_max_cells]CellRange = undefined;
    for (&ranges) |*range| {
        range.* = .{ .start = 0, .end = 0 };
    }

    cache.putCapCovering(lat_nano, lon_nano, zero_radius, ranges);
    const cached = cache.getCapCovering(lat_nano, lon_nano, zero_radius);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(u8, 0), cached.?.num_ranges);
}

test "S2CoveringCache: edge case - poles" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_poles" });
    defer cache.deinit(allocator);

    // North pole
    const north_pole_lat: i64 = 90_000_000_000;
    // South pole
    const south_pole_lat: i64 = -90_000_000_000;
    const lon_nano: i64 = 0;
    const radius_mm: u32 = 1000_000;

    var ranges: [s2_max_cells]CellRange = undefined;
    for (&ranges, 0..) |*range, i| {
        if (i == 0) {
            range.* = .{ .start = 1, .end = 10 };
        } else {
            range.* = .{ .start = 0, .end = 0 };
        }
    }

    // Cache polar regions
    cache.putCapCovering(north_pole_lat, lon_nano, radius_mm, ranges);
    cache.putCapCovering(south_pole_lat, lon_nano, radius_mm, ranges);

    // Both should be retrievable
    try std.testing.expect(cache.getCapCovering(north_pole_lat, lon_nano, radius_mm) != null);
    try std.testing.expect(cache.getCapCovering(south_pole_lat, lon_nano, radius_mm) != null);
}

test "S2CoveringCache: edge case - antimeridian" {
    const allocator = std.testing.allocator;

    var cache = try S2CoveringCache.init(allocator, 512, .{ .name = "test_am" });
    defer cache.deinit(allocator);

    const lat_nano: i64 = 0;
    const radius_mm: u32 = 1000_000;

    // Both sides of antimeridian
    const east_lon: i64 = 180_000_000_000;
    const west_lon: i64 = -180_000_000_000;

    var ranges_east: [s2_max_cells]CellRange = undefined;
    var ranges_west: [s2_max_cells]CellRange = undefined;
    for (&ranges_east) |*range| {
        range.* = .{ .start = 0, .end = 0 };
    }
    for (&ranges_west) |*range| {
        range.* = .{ .start = 0, .end = 0 };
    }
    ranges_east[0] = .{ .start = 100, .end = 200 };
    ranges_west[0] = .{ .start = 300, .end = 400 };

    // Cache both
    cache.putCapCovering(lat_nano, east_lon, radius_mm, ranges_east);
    cache.putCapCovering(lat_nano, west_lon, radius_mm, ranges_west);

    // They should be different cache entries
    const cached_east = cache.getCapCovering(lat_nano, east_lon, radius_mm);
    const cached_west = cache.getCapCovering(lat_nano, west_lon, radius_mm);

    try std.testing.expect(cached_east != null);
    try std.testing.expect(cached_west != null);
    try std.testing.expectEqual(@as(u64, 100), cached_east.?.ranges[0].start);
    try std.testing.expectEqual(@as(u64, 300), cached_west.?.ranges[0].start);
}
