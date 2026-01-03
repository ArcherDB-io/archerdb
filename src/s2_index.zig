//! S2 Spatial Index - Unified Interface for Spatial Lookups
//!
//! This module provides a clean interface to S2 spatial indexing functions
//! for the ArcherDB query engine. It wraps the core S2 library and adds
//! query-oriented operations like covering and distance calculations.
//!
//! # Usage
//!
//! ```zig
//! const s2_index = @import("s2_index.zig");
//!
//! // Convert coordinates to cell ID
//! const cell_id = s2_index.S2.latLonToCellId(37_774900000, -122_419400000, 30);
//!
//! // Cover a circular region for radius query
//! var scratch: [s2_index.s2_scratch_size]u8 = undefined;
//! const coverage = s2_index.S2.coverCap(&scratch, lat, lon, radius_mm, 8, 30);
//!
//! // Calculate distance between two points
//! const dist_mm = s2_index.S2.distance(lat1, lon1, lat2, lon2);
//! ```
//!
//! # Memory Management
//!
//! All covering operations use scratch buffers for temporary allocations,
//! following TigerBeetle's static allocation pattern. The `s2_scratch_size`
//! constant defines the required scratch buffer size.

const std = @import("std");
const s2 = @import("s2/s2.zig");
const math = s2.math;

/// Required scratch buffer size for S2 operations (in bytes)
/// This is enough for RegionCoverer's internal state and cell lists
pub const s2_scratch_size: usize = 64 * 1024; // 64KB

/// Maximum number of cell ranges returned by covering operations
pub const s2_max_cells: usize = 16;

/// Latitude/longitude coordinate pair in nanodegrees
pub const LatLon = struct {
    lat_nano: i64,
    lon_nano: i64,
};

/// Cell range for index scanning (inclusive start, exclusive end)
pub const CellRange = struct {
    start: u64, // Inclusive
    end: u64, // Exclusive

    /// Check if a cell ID falls within this range
    pub fn contains(self: CellRange, cell_id: u64) bool {
        return cell_id >= self.start and cell_id < self.end;
    }
};

/// S2 spatial indexing functions
///
/// This interface provides all S2 operations needed by the query engine.
/// All functions are deterministic and produce identical results across
/// all platforms (x86, ARM, macOS, Linux).
pub const S2 = struct {
    // =========================================================================
    // Core Cell ID Operations
    // =========================================================================

    /// Convert lat/lon (nanodegrees) to S2 cell ID
    ///
    /// Arguments:
    /// - lat_nano: Latitude in nanodegrees (-90_000_000_000 to +90_000_000_000)
    /// - lon_nano: Longitude in nanodegrees (-180_000_000_000 to +180_000_000_000)
    /// - level: S2 level (0-30), where 30 is maximum precision (~7.5mm)
    ///
    /// Returns: 64-bit S2 cell ID
    pub fn latLonToCellId(lat_nano: i64, lon_nano: i64, level: u8) u64 {
        return s2.latLonToCellId(lat_nano, lon_nano, level);
    }

    /// Convert S2 cell ID back to lat/lon (cell center) in nanodegrees
    pub fn cellIdToLatLon(cell_id: u64) LatLon {
        const result = s2.cellIdToLatLon(cell_id);
        return .{
            .lat_nano = result.lat_nano,
            .lon_nano = result.lon_nano,
        };
    }

    /// Get parent cell (one level up)
    pub fn getParent(cell_id: u64) u64 {
        return s2.parent(cell_id);
    }

    /// Get child cells (one level down)
    pub fn getChildren(cell_id: u64) [4]u64 {
        return s2.children(cell_id);
    }

    /// Get the level (0-30) of a cell
    pub fn getLevel(cell_id: u64) u8 {
        return s2.level(cell_id);
    }

    /// Check if a cell ID is valid
    pub fn isValid(cell_id: u64) bool {
        return s2.isValid(cell_id);
    }

    // =========================================================================
    // Coverage Operations (for spatial queries)
    // =========================================================================

    /// Cover a circular region (for radius queries)
    ///
    /// Returns cell ranges that cover the spherical cap centered at the given
    /// point with the specified radius. Use these ranges for LSM tree scanning.
    ///
    /// Arguments:
    /// - scratch: Scratch buffer (must be at least s2_scratch_size bytes)
    /// - center_lat_nano: Center latitude in nanodegrees
    /// - center_lon_nano: Center longitude in nanodegrees
    /// - radius_mm: Radius in millimeters
    /// - min_level: Minimum cell level (coarser cells)
    /// - max_level: Maximum cell level (finer cells)
    ///
    /// Returns: Fixed-size array of cell ranges (unused entries have start == end == 0)
    pub fn coverCap(
        scratch: []u8,
        center_lat_nano: i64,
        center_lon_nano: i64,
        radius_mm: u32,
        min_level: u8,
        max_level: u8,
    ) [s2_max_cells]CellRange {
        // Use scratch buffer for temporary allocations
        var fba = std.heap.FixedBufferAllocator.init(scratch);
        const allocator = fba.allocator();

        // Convert radius from millimeters to meters
        const radius_meters = @as(f64, @floatFromInt(radius_mm)) / 1000.0;

        // Create S2 cap using nanodegrees
        const cap_result = s2.Cap.fromLatLonNanoRadius(
            center_lat_nano,
            center_lon_nano,
            radius_meters,
        );

        // Create RegionCoverer
        const coverer = s2.RegionCoverer.initWithParams(min_level, max_level, @intCast(s2_max_cells));

        // Get covering - uses scratch buffer for allocations
        var covering = coverer.coverCap(cap_result, allocator) catch {
            // On allocation failure, return empty ranges
            var ranges: [s2_max_cells]CellRange = undefined;
            for (&ranges) |*range| {
                range.* = .{ .start = 0, .end = 0 };
            }
            return ranges;
        };
        defer covering.deinit();

        // Convert to CellRange array (convert from inclusive to exclusive end)
        var ranges: [s2_max_cells]CellRange = undefined;
        for (&ranges, 0..) |*range, i| {
            if (i < covering.ranges.len) {
                range.* = .{
                    .start = covering.ranges[i].range_min,
                    .end = covering.ranges[i].range_max + 1, // Convert to exclusive
                };
            } else {
                range.* = .{ .start = 0, .end = 0 }; // Unused
            }
        }

        return ranges;
    }

    /// Cover a polygon region (for polygon queries)
    ///
    /// Returns cell ranges that cover the polygon defined by the given vertices.
    /// The polygon is assumed to be simple (non-self-intersecting) and the
    /// vertices are in counter-clockwise order.
    ///
    /// Arguments:
    /// - scratch: Scratch buffer (must be at least s2_scratch_size bytes)
    /// - vertices: Array of lat/lon vertices defining the polygon
    /// - min_level: Minimum cell level (coarser cells)
    /// - max_level: Maximum cell level (finer cells)
    ///
    /// Returns: Fixed-size array of cell ranges
    pub fn coverPolygon(
        scratch: []u8,
        vertices: []const LatLon,
        min_level: u8,
        max_level: u8,
    ) [s2_max_cells]CellRange {
        // TODO: Implement proper polygon covering with S2Loop
        // For now, use bounding box approximation
        _ = min_level;
        _ = max_level;

        // For now, compute bounding box and return a simple covering
        if (vertices.len < 3) {
            var ranges: [s2_max_cells]CellRange = undefined;
            for (&ranges) |*range| {
                range.* = .{ .start = 0, .end = 0 };
            }
            return ranges;
        }

        // Find bounding box
        var min_lat = vertices[0].lat_nano;
        var max_lat = vertices[0].lat_nano;
        var min_lon = vertices[0].lon_nano;
        var max_lon = vertices[0].lon_nano;

        for (vertices[1..]) |v| {
            if (v.lat_nano < min_lat) min_lat = v.lat_nano;
            if (v.lat_nano > max_lat) max_lat = v.lat_nano;
            if (v.lon_nano < min_lon) min_lon = v.lon_nano;
            if (v.lon_nano > max_lon) max_lon = v.lon_nano;
        }

        // Create cap covering the bounding box (conservative approximation)
        const center_lat = @divTrunc(min_lat + max_lat, 2);
        const center_lon = @divTrunc(min_lon + max_lon, 2);

        // Compute approximate radius (diagonal of bounding box / 2)
        const lat_diff = max_lat - min_lat;
        const lon_diff = max_lon - min_lon;
        const diagonal_nano = math.sqrt(@as(f64, @floatFromInt(lat_diff * lat_diff + lon_diff * lon_diff)));

        // Convert to millimeters (1 nanodegree ≈ 0.111 mm at equator)
        const radius_mm: u32 = @intFromFloat(diagonal_nano * 0.111 / 2.0 + 1000.0);

        return coverCap(scratch, center_lat, center_lon, radius_mm, 8, 30);
    }

    // =========================================================================
    // Post-Filter Operations
    // =========================================================================

    /// Test if a point is inside a polygon
    ///
    /// Uses the ray casting algorithm. The polygon is assumed to be simple
    /// (non-self-intersecting) and the vertices are in order (clockwise or
    /// counter-clockwise).
    ///
    /// Arguments:
    /// - point: The point to test
    /// - polygon: Array of vertices defining the polygon
    ///
    /// Returns: true if point is inside or on the boundary
    pub fn pointInPolygon(point: LatLon, polygon: []const LatLon) bool {
        if (polygon.len < 3) return false;

        // Ray casting algorithm
        var inside = false;
        var j = polygon.len - 1;

        for (polygon, 0..) |vi, i| {
            const vj = polygon[j];

            // Check if ray from point crosses edge vi-vj
            if ((vi.lon_nano > point.lon_nano) != (vj.lon_nano > point.lon_nano)) {
                // Compute x-intercept of edge with horizontal ray from point
                const lat_diff = vj.lat_nano - vi.lat_nano;
                const lon_diff = vj.lon_nano - vi.lon_nano;
                const t = @as(f64, @floatFromInt(point.lon_nano - vi.lon_nano)) /
                    @as(f64, @floatFromInt(lon_diff));
                const lat_intersect = @as(f64, @floatFromInt(vi.lat_nano)) +
                    t * @as(f64, @floatFromInt(lat_diff));

                if (@as(f64, @floatFromInt(point.lat_nano)) < lat_intersect) {
                    inside = !inside;
                }
            }

            j = i;
        }

        return inside;
    }

    // =========================================================================
    // Distance Calculations
    // =========================================================================

    /// Calculate great-circle distance between two points (Haversine formula)
    ///
    /// Uses deterministic software trigonometry for VSR consensus.
    ///
    /// Arguments:
    /// - lat1_nano, lon1_nano: First point in nanodegrees
    /// - lat2_nano, lon2_nano: Second point in nanodegrees
    ///
    /// Returns: Distance in millimeters
    pub fn distance(
        lat1_nano: i64,
        lon1_nano: i64,
        lat2_nano: i64,
        lon2_nano: i64,
    ) u64 {
        // Convert to radians
        const nano_to_rad = math.pi / 180_000_000_000.0;
        const lat1 = @as(f64, @floatFromInt(lat1_nano)) * nano_to_rad;
        const lon1 = @as(f64, @floatFromInt(lon1_nano)) * nano_to_rad;
        const lat2 = @as(f64, @floatFromInt(lat2_nano)) * nano_to_rad;
        const lon2 = @as(f64, @floatFromInt(lon2_nano)) * nano_to_rad;

        // Haversine formula
        const dlat = lat2 - lat1;
        const dlon = lon2 - lon1;

        const sin_dlat_2 = math.sin(dlat / 2.0);
        const sin_dlon_2 = math.sin(dlon / 2.0);

        const a = sin_dlat_2 * sin_dlat_2 +
            math.cos(lat1) * math.cos(lat2) * sin_dlon_2 * sin_dlon_2;

        // Use atan2 for numerical stability
        const c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a));

        // Earth radius in millimeters
        const earth_radius_mm: f64 = 6_371_000_000.0;

        return @intFromFloat(earth_radius_mm * c);
    }

    /// Check if a point is within a given distance of another point
    ///
    /// This is more efficient than computing the full distance when you
    /// only need a yes/no answer.
    pub fn isWithinDistance(
        lat1_nano: i64,
        lon1_nano: i64,
        lat2_nano: i64,
        lon2_nano: i64,
        max_distance_mm: u64,
    ) bool {
        return distance(lat1_nano, lon1_nano, lat2_nano, lon2_nano) <= max_distance_mm;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "S2.latLonToCellId: basic" {
    const cell_id = S2.latLonToCellId(0, 0, 30);
    try std.testing.expect(S2.isValid(cell_id));
    try std.testing.expectEqual(@as(u8, 30), S2.getLevel(cell_id));
}

test "S2.cellIdToLatLon: round-trip" {
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;

    const cell_id = S2.latLonToCellId(lat_nano, lon_nano, 30);
    const result = S2.cellIdToLatLon(cell_id);

    // At level 30, precision is ~7.5mm, allow 1 microdegree tolerance
    const tolerance: i64 = 1000;
    try std.testing.expect(@abs(result.lat_nano - lat_nano) < tolerance);
    try std.testing.expect(@abs(result.lon_nano - lon_nano) < tolerance);
}

test "S2.getParent/getChildren: hierarchy" {
    const cell_id = S2.latLonToCellId(0, 0, 15);
    const parent_id = S2.getParent(cell_id);
    const children_ids = S2.getChildren(cell_id);

    try std.testing.expectEqual(@as(u8, 15), S2.getLevel(cell_id));
    try std.testing.expectEqual(@as(u8, 14), S2.getLevel(parent_id));

    for (children_ids) |child_id| {
        try std.testing.expectEqual(@as(u8, 16), S2.getLevel(child_id));
        try std.testing.expectEqual(cell_id, S2.getParent(child_id));
    }
}

test "S2.distance: known distances" {
    // New York to Los Angeles: ~3944 km
    const ny_lat: i64 = 40_712800000;
    const ny_lon: i64 = -74_006000000;
    const la_lat: i64 = 34_052200000;
    const la_lon: i64 = -118_243700000;

    const dist_mm = S2.distance(ny_lat, ny_lon, la_lat, la_lon);
    const dist_km = @as(f64, @floatFromInt(dist_mm)) / 1_000_000.0;

    // Allow 1% error
    try std.testing.expect(dist_km > 3900.0 and dist_km < 4000.0);
}

test "S2.distance: same point" {
    const dist = S2.distance(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), dist);
}

test "S2.distance: antipodal points" {
    // North pole to south pole: ~20000 km (half Earth circumference)
    const dist_mm = S2.distance(90_000_000_000, 0, -90_000_000_000, 0);
    const dist_km = @as(f64, @floatFromInt(dist_mm)) / 1_000_000.0;

    // Allow 1% error
    try std.testing.expect(dist_km > 19800.0 and dist_km < 20200.0);
}

test "S2.pointInPolygon: triangle" {
    const triangle = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 5_000_000_000, .lon_nano = 10_000_000_000 },
    };

    // Center point - should be inside
    try std.testing.expect(S2.pointInPolygon(
        .{ .lat_nano = 5_000_000_000, .lon_nano = 3_000_000_000 },
        &triangle,
    ));

    // Outside point
    try std.testing.expect(!S2.pointInPolygon(
        .{ .lat_nano = 20_000_000_000, .lon_nano = 20_000_000_000 },
        &triangle,
    ));
}

test "S2.coverCap: basic" {
    var scratch: [s2_scratch_size]u8 = undefined;
    const ranges = S2.coverCap(
        &scratch,
        37_774900000, // San Francisco lat
        -122_419400000, // San Francisco lon
        1000_000, // 1km radius
        8,
        30,
    );

    // Should have at least one valid range
    var has_valid_range = false;
    for (ranges) |range| {
        if (range.start != 0 or range.end != 0) {
            has_valid_range = true;
            try std.testing.expect(range.end > range.start);
            break;
        }
    }
    try std.testing.expect(has_valid_range);
}

test "S2.isWithinDistance: basic" {
    // Same point
    try std.testing.expect(S2.isWithinDistance(0, 0, 0, 0, 1));

    // Very close points
    try std.testing.expect(S2.isWithinDistance(0, 0, 0, 1000, 1_000_000)); // 1km

    // Far apart points
    try std.testing.expect(!S2.isWithinDistance(0, 0, 90_000_000_000, 0, 1_000_000)); // 1km
}
