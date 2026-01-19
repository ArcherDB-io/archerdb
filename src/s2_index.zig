// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
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
//! following ArcherDB's static allocation pattern. The `s2_scratch_size`
//! constant defines the required scratch buffer size.

const std = @import("std");
const s2 = @import("s2/s2.zig");
const math = s2.math;
const log = std.log.scoped(.s2_index);

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

        log.debug(
            "coverCap: center_lat_nano={d}, center_lon_nano={d}, radius_m={d:.1}",
            .{ center_lat_nano, center_lon_nano, radius_meters },
        );

        // Create RegionCoverer
        const max_cells: u8 = @intCast(s2_max_cells);
        const coverer = s2.RegionCoverer.initWithParams(min_level, max_level, max_cells);

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
        // For now, compute bounding box and use direct bounding box covering
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

        log.debug(
            "coverPolygon: bbox lat=[{d}, {d}], lon=[{d}, {d}]",
            .{ min_lat, max_lat, min_lon, max_lon },
        );

        // Use bounding box covering instead of cap approximation
        return coverBoundingBox(scratch, min_lat, max_lat, min_lon, max_lon, min_level, max_level);
    }

    /// Cover a rectangular bounding box region
    ///
    /// This algorithm uses a simple approach: find cells at an appropriate level
    /// and compute an inclusive cell range that covers all of them.
    ///
    /// Arguments:
    /// - scratch: Scratch buffer for temporary allocations
    /// - min_lat, max_lat: Latitude bounds in nanodegrees
    /// - min_lon, max_lon: Longitude bounds in nanodegrees
    /// - min_level: Minimum cell level
    /// - max_level: Maximum cell level
    ///
    /// Returns: Fixed-size array of cell ranges
    pub fn coverBoundingBox(
        scratch: []u8,
        min_lat: i64,
        max_lat: i64,
        min_lon: i64,
        max_lon: i64,
        min_level: u8,
        max_level: u8,
    ) [s2_max_cells]CellRange {
        _ = scratch;
        _ = min_level;
        _ = max_level;

        // Simple approach: find all level-30 cells for points in a dense grid,
        // find their common ancestor at a level where we get reasonable coverage,
        // and return that as a range.
        //
        // For polygon queries, the covering doesn't need to be tight - it just
        // needs to be conservative (include all cells that MIGHT be in the polygon).
        // The pointInPolygon filter will do exact filtering.

        // Sample corner cells at level 30
        const sw_cell = s2.latLonToCellId(min_lat, min_lon, 30);
        const nw_cell = s2.latLonToCellId(max_lat, min_lon, 30);
        const ne_cell = s2.latLonToCellId(max_lat, max_lon, 30);
        const se_cell = s2.latLonToCellId(min_lat, max_lon, 30);
        const center_cell = s2.latLonToCellId(
            @divTrunc(min_lat + max_lat, 2),
            @divTrunc(min_lon + max_lon, 2),
            30,
        );

        // Find min and max cell IDs among the corners
        var min_cell = sw_cell;
        var max_cell = sw_cell;
        const all_cells = [_]u64{ sw_cell, nw_cell, ne_cell, se_cell, center_cell };
        for (all_cells) |cell| {
            if (cell < min_cell) min_cell = cell;
            if (cell > max_cell) max_cell = cell;
        }

        log.debug(
            "coverBoundingBox: min_cell=0x{x:0>16}, max_cell=0x{x:0>16}, center=0x{x:0>16}",
            .{ min_cell, max_cell, center_cell },
        );

        // Find common ancestor level - the level at which min_cell and max_cell
        // share a common parent. Go up until they have the same parent.
        var ancestor_level: u8 = 30;
        var min_ancestor = min_cell;
        var max_ancestor = max_cell;

        while (ancestor_level > 0 and min_ancestor != max_ancestor) {
            min_ancestor = s2.parent(min_ancestor);
            max_ancestor = s2.parent(max_ancestor);
            ancestor_level -= 1;
        }

        log.debug("coverBoundingBox: common_ancestor_level={d}", .{ancestor_level});

        // If they have a common ancestor, use that cell's range
        // Otherwise, create a range from min to max
        var ranges: [s2_max_cells]CellRange = undefined;
        for (&ranges) |*range| {
            range.* = .{ .start = 0, .end = 0 };
        }

        if (min_ancestor == max_ancestor) {
            // All corners share this ancestor - use its range
            const lsb = min_ancestor & (~min_ancestor + 1);
            ranges[0] = .{
                .start = min_ancestor - lsb + 1,
                .end = min_ancestor + lsb, // Exclusive end
            };
        } else {
            // No common ancestor at any level - this shouldn't happen for
            // reasonable bounding boxes. Use the full range as fallback.
            // But also add individual ranges for safety.
            const min_lsb = min_cell & (~min_cell + 1);
            const max_lsb = max_cell & (~max_cell + 1);

            // Create a range from min_cell's min to max_cell's max
            ranges[0] = .{
                .start = min_cell - min_lsb + 1,
                .end = max_cell + max_lsb, // Exclusive end
            };
        }

        log.debug(
            "coverBoundingBox: range[0] = 0x{x:0>16} .. 0x{x:0>16}",
            .{ ranges[0].start, ranges[0].end },
        );

        return ranges;
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

    /// Test if a point is inside a polygon with holes (multi-ring polygon)
    ///
    /// A point is inside a polygon with holes if:
    /// 1. The point is inside the outer ring, AND
    /// 2. The point is NOT inside any hole ring
    ///
    /// Arguments:
    /// - point: The point to test
    /// - outer: The outer ring vertices (counter-clockwise winding)
    /// - holes: Array of hole ring vertices (each hole clockwise winding)
    ///
    /// Returns: true if point is inside outer ring and outside all holes
    pub fn pointInPolygonWithHoles(
        point: LatLon,
        outer: []const LatLon,
        holes: []const []const LatLon,
    ) bool {
        // Must be inside outer ring first
        if (!pointInPolygon(point, outer)) {
            return false;
        }

        // Must be outside all holes
        for (holes) |hole| {
            if (pointInPolygon(point, hole)) {
                return false; // Point is inside a hole, so excluded
            }
        }

        return true;
    }

    // =========================================================================
    // Polygon Validation
    // =========================================================================

    /// Check if a polygon is degenerate (all vertices are collinear)
    ///
    /// A degenerate polygon has zero area because all vertices lie on a line.
    /// Uses cross-product to detect collinearity.
    ///
    /// Returns: true if polygon is degenerate (collinear), false if valid
    pub fn isPolygonDegenerate(polygon: []const LatLon) bool {
        if (polygon.len < 3) return true;

        // Check if all vertices are collinear by computing cross products
        // If all cross products are zero (or very small), points are collinear
        const p0 = polygon[0];

        for (2..polygon.len) |i| {
            const p1 = polygon[i - 1];
            const p2 = polygon[i];

            // Cross product: (p1-p0) × (p2-p0)
            // = (p1.lat - p0.lat) * (p2.lon - p0.lon) - (p1.lon - p0.lon) * (p2.lat - p0.lat)
            const dx1 = p1.lat_nano - p0.lat_nano;
            const dy1 = p1.lon_nano - p0.lon_nano;
            const dx2 = p2.lat_nano - p0.lat_nano;
            const dy2 = p2.lon_nano - p0.lon_nano;

            // Use i128 to avoid overflow with nanodegrees
            const cross = @as(i128, dx1) * @as(i128, dy2) - @as(i128, dy1) * @as(i128, dx2);

            // If any cross product is non-zero, polygon is not degenerate
            // Use tolerance for numerical stability (1 square nanodegree)
            if (@abs(cross) > 1_000_000) {
                return false;
            }
        }

        return true; // All points are collinear
    }

    /// Check if two line segments intersect (excluding endpoints)
    ///
    /// Uses the cross-product orientation test.
    fn segmentsIntersect(
        a1: LatLon,
        a2: LatLon,
        b1: LatLon,
        b2: LatLon,
    ) bool {
        // Compute orientations of the four relevant triangles
        const o1 = orientation(a1, a2, b1);
        const o2 = orientation(a1, a2, b2);
        const o3 = orientation(b1, b2, a1);
        const o4 = orientation(b1, b2, a2);

        // General case: segments intersect if orientations differ
        if (o1 != o2 and o3 != o4) {
            return true;
        }

        return false;
    }

    /// Compute orientation of triplet (p, q, r)
    /// Returns: 0 = collinear, 1 = clockwise, 2 = counter-clockwise
    fn orientation(p: LatLon, q: LatLon, r: LatLon) i32 {
        const val = @as(i128, q.lon_nano - p.lon_nano) * @as(i128, r.lat_nano - q.lat_nano) -
            @as(i128, q.lat_nano - p.lat_nano) * @as(i128, r.lon_nano - q.lon_nano);

        if (val == 0) return 0; // Collinear
        return if (val > 0) @as(i32, 1) else @as(i32, 2);
    }

    /// Check if a polygon has self-intersecting edges (bowtie shape)
    ///
    /// Two non-adjacent edges that cross make the polygon invalid.
    /// Adjacent edges share a vertex and are allowed to "touch".
    ///
    /// Returns: true if polygon self-intersects, false if valid
    pub fn isPolygonSelfIntersecting(polygon: []const LatLon) bool {
        if (polygon.len < 4) return false; // Triangle can't self-intersect

        const n = polygon.len;

        // Check each pair of non-adjacent edges
        for (0..n) |i| {
            const a1 = polygon[i];
            const a2 = polygon[(i + 1) % n];

            // Only check edges that are at least 2 apart (non-adjacent)
            // Skip if i + 2 >= n to avoid range overflow
            if (i + 2 >= n) continue;
            for ((i + 2)..n) |j| {
                // Skip if edges share a vertex (adjacent)
                if (j == (i + n - 1) % n) continue;
                if ((j + 1) % n == i) continue;

                const b1 = polygon[j];
                const b2 = polygon[(j + 1) % n];

                if (segmentsIntersect(a1, a2, b1, b2)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Check if a polygon spans more than 350 degrees longitude
    ///
    /// Such polygons effectively cover most of the globe and should be rejected
    /// as they're likely errors or would be extremely expensive to process.
    ///
    /// Returns: true if polygon is too large, false if valid
    pub fn isPolygonTooLarge(polygon: []const LatLon) bool {
        if (polygon.len < 3) return false;

        var min_lon: i64 = std.math.maxInt(i64);
        var max_lon: i64 = std.math.minInt(i64);

        for (polygon) |v| {
            if (v.lon_nano < min_lon) min_lon = v.lon_nano;
            if (v.lon_nano > max_lon) max_lon = v.lon_nano;
        }

        // 350 degrees in nanodegrees
        const max_span: i64 = 350_000_000_000;
        return (max_lon - min_lon) > max_span;
    }

    // =========================================================================
    // Polygon Hole Validation
    // =========================================================================

    /// Bounding box for a polygon ring
    pub const BoundingBox = struct {
        min_lat: i64,
        max_lat: i64,
        min_lon: i64,
        max_lon: i64,

        /// Check if this bounding box contains a point
        pub fn containsPoint(self: BoundingBox, point: LatLon) bool {
            return point.lat_nano >= self.min_lat and
                point.lat_nano <= self.max_lat and
                point.lon_nano >= self.min_lon and
                point.lon_nano <= self.max_lon;
        }

        /// Check if two bounding boxes overlap
        pub fn overlaps(self: BoundingBox, other: BoundingBox) bool {
            return self.min_lat <= other.max_lat and
                self.max_lat >= other.min_lat and
                self.min_lon <= other.max_lon and
                self.max_lon >= other.min_lon;
        }
    };

    /// Compute the bounding box of a polygon ring
    pub fn getPolygonBoundingBox(polygon: []const LatLon) ?BoundingBox {
        if (polygon.len == 0) return null;

        var bbox = BoundingBox{
            .min_lat = polygon[0].lat_nano,
            .max_lat = polygon[0].lat_nano,
            .min_lon = polygon[0].lon_nano,
            .max_lon = polygon[0].lon_nano,
        };

        for (polygon[1..]) |v| {
            if (v.lat_nano < bbox.min_lat) bbox.min_lat = v.lat_nano;
            if (v.lat_nano > bbox.max_lat) bbox.max_lat = v.lat_nano;
            if (v.lon_nano < bbox.min_lon) bbox.min_lon = v.lon_nano;
            if (v.lon_nano > bbox.max_lon) bbox.max_lon = v.lon_nano;
        }

        return bbox;
    }

    /// Check if a hole ring is fully contained within the outer ring
    ///
    /// Uses a conservative approach:
    /// 1. First checks bounding box containment (fast)
    /// 2. Then checks if all hole vertices are inside outer ring
    ///
    /// Returns: true if hole is fully contained, false otherwise
    pub fn isHoleContained(outer: []const LatLon, hole: []const LatLon) bool {
        if (outer.len < 3 or hole.len < 3) return false;

        const outer_bbox = getPolygonBoundingBox(outer) orelse return false;
        const hole_bbox = getPolygonBoundingBox(hole) orelse return false;

        // Quick bounding box check
        if (hole_bbox.min_lat < outer_bbox.min_lat or
            hole_bbox.max_lat > outer_bbox.max_lat or
            hole_bbox.min_lon < outer_bbox.min_lon or
            hole_bbox.max_lon > outer_bbox.max_lon)
        {
            return false;
        }

        // Check that all hole vertices are inside the outer ring
        for (hole) |vertex| {
            if (!pointInPolygon(vertex, outer)) {
                return false;
            }
        }

        return true;
    }

    /// Check if two hole rings have overlapping bounding boxes
    ///
    /// This is a conservative check - overlapping bounding boxes don't
    /// guarantee the holes actually intersect, but non-overlapping boxes
    /// guarantee they don't.
    ///
    /// Returns: true if bounding boxes overlap, false otherwise
    pub fn doHolesBoundingBoxesOverlap(hole1: []const LatLon, hole2: []const LatLon) bool {
        const bbox1 = getPolygonBoundingBox(hole1) orelse return false;
        const bbox2 = getPolygonBoundingBox(hole2) orelse return false;
        return bbox1.overlaps(bbox2);
    }

    /// Compute the signed area of a polygon (for winding order detection)
    ///
    /// Positive area = counter-clockwise winding
    /// Negative area = clockwise winding
    ///
    /// Uses the shoelace formula with i128 to avoid overflow.
    pub fn signedArea(polygon: []const LatLon) i128 {
        if (polygon.len < 3) return 0;

        var area: i128 = 0;
        const n = polygon.len;

        for (0..n) |i| {
            const j = (i + 1) % n;
            // Shoelace formula: sum of (x[i] * y[i+1] - x[i+1] * y[i])
            area += @as(i128, polygon[i].lon_nano) * @as(i128, polygon[j].lat_nano);
            area -= @as(i128, polygon[j].lon_nano) * @as(i128, polygon[i].lat_nano);
        }

        return area; // Divide by 2 for actual area, but sign is what matters
    }

    /// Check if polygon has counter-clockwise winding order
    pub fn isCounterClockwise(polygon: []const LatLon) bool {
        return signedArea(polygon) > 0;
    }

    /// Check if polygon has clockwise winding order
    pub fn isClockwise(polygon: []const LatLon) bool {
        return signedArea(polygon) < 0;
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

test "S2.distance: golden vectors per query-engine spec" {
    // NYC to London: expected 5570.22 km
    // NYC: 40.7128° N, 74.0060° W
    // London: 51.5074° N, 0.1278° W
    const nyc_lat: i64 = 40_712800000;
    const nyc_lon: i64 = -74_006000000;
    const london_lat: i64 = 51_507400000;
    const london_lon: i64 = -127800000; // -0.1278°

    const nyc_london_mm = S2.distance(nyc_lat, nyc_lon, london_lat, london_lon);
    const nyc_london_km = @as(f64, @floatFromInt(nyc_london_mm)) / 1_000_000.0;
    // Allow 0.5% error (expected: 5570.22 km)
    try std.testing.expect(nyc_london_km > 5542.0 and nyc_london_km < 5598.0);

    // SF to Tokyo: expected 8277.95 km
    // SF: 37.7749° N, 122.4194° W
    // Tokyo: 35.6762° N, 139.6503° E
    const sf_lat: i64 = 37_774900000;
    const sf_lon: i64 = -122_419400000;
    const tokyo_lat: i64 = 35_676200000;
    const tokyo_lon: i64 = 139_650300000;

    const sf_tokyo_mm = S2.distance(sf_lat, sf_lon, tokyo_lat, tokyo_lon);
    const sf_tokyo_km = @as(f64, @floatFromInt(sf_tokyo_mm)) / 1_000_000.0;
    // Allow 0.5% error (expected: 8277.95 km)
    try std.testing.expect(sf_tokyo_km > 8236.0 and sf_tokyo_km < 8319.0);
}

test "S2.distance: sub-kilometer precision" {
    // Two points 1 km apart at equator
    // 1 degree of latitude at equator = ~111.32 km
    // So 1 km = ~0.008983 degrees = ~8983000 nanodegrees
    const lat1: i64 = 0;
    const lon1: i64 = 0;
    const lat2: i64 = 8_983000; // ~1km north
    const lon2: i64 = 0;

    const dist_mm = S2.distance(lat1, lon1, lat2, lon2);
    const dist_m = @as(f64, @floatFromInt(dist_mm)) / 1000.0;
    // Should be approximately 1000m (allow 2% error)
    try std.testing.expect(dist_m > 980.0 and dist_m < 1020.0);
}

test "S2.distance: 10m precision" {
    // Two points 10 meters apart
    // 10m = ~0.00008983 degrees = ~89830 nanodegrees
    const lat1: i64 = 0;
    const lon1: i64 = 0;
    const lat2: i64 = 89830; // ~10m north
    const lon2: i64 = 0;

    const dist_mm = S2.distance(lat1, lon1, lat2, lon2);
    const dist_m = @as(f64, @floatFromInt(dist_mm)) / 1000.0;
    // Should be approximately 10m (allow 5% error)
    try std.testing.expect(dist_m > 9.5 and dist_m < 10.5);
}

test "S2.distance: pole regions" {
    // North pole query - within 100km
    const north_pole_lat: i64 = 90_000_000_000;
    const north_pole_lon: i64 = 0;
    // Point 100km from north pole (at ~89.1° latitude)
    const near_pole_lat: i64 = 89_100_000_000; // ~100km from pole
    const near_pole_lon: i64 = 45_000_000_000; // 45°E

    const dist_mm = S2.distance(north_pole_lat, north_pole_lon, near_pole_lat, near_pole_lon);
    const dist_km = @as(f64, @floatFromInt(dist_mm)) / 1_000_000.0;
    // ~100km expected (1 degree = ~111.32km at pole)
    try std.testing.expect(dist_km > 95.0 and dist_km < 105.0);

    // South pole query - within 50km
    const south_pole_lat: i64 = -90_000_000_000;
    const south_pole_lon: i64 = 0;
    const near_south_lat: i64 = -89_550_000_000; // ~50km from pole
    const near_south_lon: i64 = 180_000_000_000; // 180°E

    const south_dist_mm = S2.distance(
        south_pole_lat,
        south_pole_lon,
        near_south_lat,
        near_south_lon,
    );
    const south_dist_km = @as(f64, @floatFromInt(south_dist_mm)) / 1_000_000.0;
    // ~50km expected
    try std.testing.expect(south_dist_km > 47.0 and south_dist_km < 53.0);
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

test "S2.pointInPolygon: SF bounding box rectangle" {
    // This is the exact polygon used in /tmp/test_polygon_query.py
    // CCW winding: SW -> NW -> NE -> SE
    const sf_polygon = [_]LatLon{
        .{ .lat_nano = 37_700_000_000, .lon_nano = -122_500_000_000 }, // SW corner
        .{ .lat_nano = 37_850_000_000, .lon_nano = -122_500_000_000 }, // NW corner
        .{ .lat_nano = 37_850_000_000, .lon_nano = -122_350_000_000 }, // NE corner
        .{ .lat_nano = 37_700_000_000, .lon_nano = -122_350_000_000 }, // SE corner
    };

    // San Francisco test point (should be inside the polygon)
    const sf_point = LatLon{
        .lat_nano = 37_774_900_000,
        .lon_nano = -122_419_400_000,
    };

    // This is the failing case in production - point is clearly within the bounding box
    const result = S2.pointInPolygon(sf_point, &sf_polygon);
    std.debug.print("\nSF polygon test:\n", .{});
    std.debug.print("  Polygon: SW({d},{d}) NW({d},{d}) NE({d},{d}) SE({d},{d})\n", .{
        sf_polygon[0].lat_nano, sf_polygon[0].lon_nano,
        sf_polygon[1].lat_nano, sf_polygon[1].lon_nano,
        sf_polygon[2].lat_nano, sf_polygon[2].lon_nano,
        sf_polygon[3].lat_nano, sf_polygon[3].lon_nano,
    });
    std.debug.print("  Point: ({d}, {d})\n", .{ sf_point.lat_nano, sf_point.lon_nano });
    std.debug.print("  Result: {}\n", .{result});

    try std.testing.expect(result);
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

// =========================================================================
// Polygon Validation Tests
// =========================================================================

test "S2.isPolygonDegenerate: valid triangle" {
    const triangle = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 }, // 10° lat
        .{ .lat_nano = 5_000_000_000, .lon_nano = 10_000_000_000 }, // 5° lat, 10° lon
    };
    try std.testing.expect(!S2.isPolygonDegenerate(&triangle));
}

test "S2.isPolygonDegenerate: collinear points" {
    // All points on the same line (same latitude)
    const line = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 20_000_000_000 },
    };
    try std.testing.expect(S2.isPolygonDegenerate(&line));
}

test "S2.isPolygonDegenerate: too few vertices" {
    const point = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
    };
    try std.testing.expect(S2.isPolygonDegenerate(&point));

    const line_segment = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(S2.isPolygonDegenerate(&line_segment));
}

test "S2.isPolygonSelfIntersecting: valid square" {
    const square = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(!S2.isPolygonSelfIntersecting(&square));
}

test "S2.isPolygonSelfIntersecting: bowtie shape" {
    // Bowtie: edges cross in the middle
    const bowtie = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(S2.isPolygonSelfIntersecting(&bowtie));
}

test "S2.isPolygonSelfIntersecting: triangle (no self-intersection possible)" {
    const triangle = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 5_000_000_000, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(!S2.isPolygonSelfIntersecting(&triangle));
}

test "S2.isPolygonTooLarge: normal polygon" {
    const small_square = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(!S2.isPolygonTooLarge(&small_square));
}

test "S2.isPolygonTooLarge: globe-spanning polygon" {
    // Polygon spanning nearly the entire longitude range
    const huge = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = -179_000_000_000 }, // -179°
        .{ .lat_nano = 10_000_000_000, .lon_nano = -179_000_000_000 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 179_000_000_000 }, // +179°
        .{ .lat_nano = 0, .lon_nano = 179_000_000_000 },
    };
    try std.testing.expect(S2.isPolygonTooLarge(&huge));
}

// =========================================================================
// Polygon with Holes Tests
// =========================================================================

test "S2.pointInPolygonWithHoles: point outside outer ring" {
    // Square outer ring: 0-10° lat, 0-10° lon
    const outer = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Small hole in the center: 4-6° lat, 4-6° lon
    const hole1 = [_]LatLon{
        .{ .lat_nano = 4_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 6_000_000_000 },
        .{ .lat_nano = 4_000_000_000, .lon_nano = 6_000_000_000 },
    };

    const holes = [_][]const LatLon{&hole1};

    // Point completely outside outer ring - should be false
    const outside_point = LatLon{ .lat_nano = 20_000_000_000, .lon_nano = 20_000_000_000 };
    try std.testing.expect(!S2.pointInPolygonWithHoles(outside_point, &outer, &holes));
}

test "S2.pointInPolygonWithHoles: point inside hole" {
    // Square outer ring: 0-10° lat, 0-10° lon
    const outer = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Small hole in the center: 4-6° lat, 4-6° lon
    const hole1 = [_]LatLon{
        .{ .lat_nano = 4_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 6_000_000_000 },
        .{ .lat_nano = 4_000_000_000, .lon_nano = 6_000_000_000 },
    };

    const holes = [_][]const LatLon{&hole1};

    // Point inside the hole (5°, 5°) - should be excluded
    const hole_point = LatLon{ .lat_nano = 5_000_000_000, .lon_nano = 5_000_000_000 };
    try std.testing.expect(!S2.pointInPolygonWithHoles(hole_point, &outer, &holes));
}

test "S2.pointInPolygonWithHoles: point inside outer, outside holes" {
    // Square outer ring: 0-10° lat, 0-10° lon
    const outer = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    // Small hole in the center: 4-6° lat, 4-6° lon
    const hole1 = [_]LatLon{
        .{ .lat_nano = 4_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 4_000_000_000 },
        .{ .lat_nano = 6_000_000_000, .lon_nano = 6_000_000_000 },
        .{ .lat_nano = 4_000_000_000, .lon_nano = 6_000_000_000 },
    };

    const holes = [_][]const LatLon{&hole1};

    // Point inside outer but outside hole (2°, 2°) - should be included
    const valid_point = LatLon{ .lat_nano = 2_000_000_000, .lon_nano = 2_000_000_000 };
    try std.testing.expect(S2.pointInPolygonWithHoles(valid_point, &outer, &holes));
}

test "S2.pointInPolygonWithHoles: multiple holes" {
    // Square outer ring: 0-20° lat, 0-20° lon
    const outer = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 20_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 20_000_000_000, .lon_nano = 20_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 20_000_000_000 },
    };

    // Hole 1: bottom-left quadrant (2-8° lat, 2-8° lon)
    const hole1 = [_]LatLon{
        .{ .lat_nano = 2_000_000_000, .lon_nano = 2_000_000_000 },
        .{ .lat_nano = 8_000_000_000, .lon_nano = 2_000_000_000 },
        .{ .lat_nano = 8_000_000_000, .lon_nano = 8_000_000_000 },
        .{ .lat_nano = 2_000_000_000, .lon_nano = 8_000_000_000 },
    };

    // Hole 2: top-right quadrant (12-18° lat, 12-18° lon)
    const hole2 = [_]LatLon{
        .{ .lat_nano = 12_000_000_000, .lon_nano = 12_000_000_000 },
        .{ .lat_nano = 18_000_000_000, .lon_nano = 12_000_000_000 },
        .{ .lat_nano = 18_000_000_000, .lon_nano = 18_000_000_000 },
        .{ .lat_nano = 12_000_000_000, .lon_nano = 18_000_000_000 },
    };

    const holes = [_][]const LatLon{ &hole1, &hole2 };

    // Point in hole1 (5°, 5°) - excluded
    const in_hole1 = LatLon{ .lat_nano = 5_000_000_000, .lon_nano = 5_000_000_000 };
    try std.testing.expect(!S2.pointInPolygonWithHoles(in_hole1, &outer, &holes));

    // Point in hole2 (15°, 15°) - excluded
    const in_hole2 = LatLon{ .lat_nano = 15_000_000_000, .lon_nano = 15_000_000_000 };
    try std.testing.expect(!S2.pointInPolygonWithHoles(in_hole2, &outer, &holes));

    // Point between holes (10°, 10°) - included
    const between_holes = LatLon{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 };
    try std.testing.expect(S2.pointInPolygonWithHoles(between_holes, &outer, &holes));

    // Point in corner (1°, 1°) - included (outside both holes)
    const corner = LatLon{ .lat_nano = 1_000_000_000, .lon_nano = 1_000_000_000 };
    try std.testing.expect(S2.pointInPolygonWithHoles(corner, &outer, &holes));
}

test "S2.pointInPolygonWithHoles: no holes (backwards compatible)" {
    // Square outer ring: 0-10° lat, 0-10° lon
    const outer = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    const holes = [_][]const LatLon{};

    // With no holes, should behave like simple pointInPolygon
    const inside = LatLon{ .lat_nano = 5_000_000_000, .lon_nano = 5_000_000_000 };
    try std.testing.expect(S2.pointInPolygonWithHoles(inside, &outer, &holes));

    const outside = LatLon{ .lat_nano = 20_000_000_000, .lon_nano = 20_000_000_000 };
    try std.testing.expect(!S2.pointInPolygonWithHoles(outside, &outer, &holes));
}

test "S2.getPolygonBoundingBox: basic square" {
    const square = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };

    const bbox = S2.getPolygonBoundingBox(&square).?;
    try std.testing.expectEqual(@as(i64, 0), bbox.min_lat);
    try std.testing.expectEqual(@as(i64, 10_000_000_000), bbox.max_lat);
    try std.testing.expectEqual(@as(i64, 0), bbox.min_lon);
    try std.testing.expectEqual(@as(i64, 10_000_000_000), bbox.max_lon);
}

test "S2.BoundingBox.containsPoint" {
    const bbox = S2.BoundingBox{
        .min_lat = 0,
        .max_lat = 10_000_000_000,
        .min_lon = 0,
        .max_lon = 10_000_000_000,
    };

    // Inside
    try std.testing.expect(bbox.containsPoint(.{
        .lat_nano = 5_000_000_000,
        .lon_nano = 5_000_000_000,
    }));

    // On boundary (inclusive)
    try std.testing.expect(bbox.containsPoint(.{ .lat_nano = 0, .lon_nano = 0 }));
    try std.testing.expect(bbox.containsPoint(.{
        .lat_nano = 10_000_000_000,
        .lon_nano = 10_000_000_000,
    }));

    // Outside
    try std.testing.expect(!bbox.containsPoint(.{
        .lat_nano = -1,
        .lon_nano = 5_000_000_000,
    }));
    try std.testing.expect(!bbox.containsPoint(.{
        .lat_nano = 20_000_000_000,
        .lon_nano = 5_000_000_000,
    }));
}

test "S2.signedArea and winding order" {
    // Counter-clockwise square (positive area)
    const ccw_square = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
    };
    try std.testing.expect(S2.signedArea(&ccw_square) > 0);
    try std.testing.expect(S2.isCounterClockwise(&ccw_square));
    try std.testing.expect(!S2.isClockwise(&ccw_square));

    // Clockwise square (negative area)
    const cw_square = [_]LatLon{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 0 },
        .{ .lat_nano = 10_000_000_000, .lon_nano = 10_000_000_000 },
        .{ .lat_nano = 0, .lon_nano = 10_000_000_000 },
    };
    try std.testing.expect(S2.signedArea(&cw_square) < 0);
    try std.testing.expect(!S2.isCounterClockwise(&cw_square));
    try std.testing.expect(S2.isClockwise(&cw_square));
}

test "S2.coverPolygon: SF bounding box covers SF point" {
    // This test verifies the polygon covering algorithm properly covers
    // points within the polygon's bounding box. This was a regression
    // where the cap-based approximation missed cells near polygon corners.

    // SF bounding box polygon (same as used in integration tests)
    const sf_polygon = [_]LatLon{
        .{ .lat_nano = 37_700_000_000, .lon_nano = -122_500_000_000 }, // SW
        .{ .lat_nano = 37_850_000_000, .lon_nano = -122_500_000_000 }, // NW
        .{ .lat_nano = 37_850_000_000, .lon_nano = -122_350_000_000 }, // NE
        .{ .lat_nano = 37_700_000_000, .lon_nano = -122_350_000_000 }, // SE
    };

    // Point in San Francisco (should be inside the polygon)
    const sf_lat: i64 = 37_774_900_000;
    const sf_lon: i64 = -122_419_400_000;

    // Get cell ID for the SF point at level 30
    const sf_cell_id = S2.latLonToCellId(sf_lat, sf_lon, 30);

    // Get covering for the polygon
    var scratch: [s2_scratch_size]u8 = undefined;
    const covering = S2.coverPolygon(&scratch, &sf_polygon, 8, 30);

    // The SF point's cell must be within one of the covering ranges
    var found = false;
    var range_count: usize = 0;
    for (covering) |range| {
        if (range.start == 0 and range.end == 0) continue;
        range_count += 1;
        if (range.contains(sf_cell_id)) {
            found = true;
        }
    }

    std.debug.print("\ncoverPolygon test:\n", .{});
    std.debug.print("  SF cell: 0x{x:0>16}\n", .{sf_cell_id});
    std.debug.print("  Covering has {d} ranges\n", .{range_count});
    for (covering, 0..) |range, i| {
        if (range.start == 0 and range.end == 0) continue;
        const contains_sf = if (range.contains(sf_cell_id)) " <- contains SF" else "";
        std.debug.print(
            "  Range {d}: 0x{x:0>16} .. 0x{x:0>16}{s}\n",
            .{ i, range.start, range.end, contains_sf },
        );
    }
    std.debug.print("  Result: found={}\n", .{found});

    try std.testing.expect(found);
}
