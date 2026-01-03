//! S2 RegionCoverer - Generate cell ID ranges that cover a region
//!
//! The RegionCoverer produces a set of S2 cells that completely cover a
//! geometric region (Cap, Polygon, etc.). This is used to convert spatial
//! queries into cell ID range scans.
//!
//! Key parameters:
//! - min_level: Minimum cell level (coarsest allowed)
//! - max_level: Maximum cell level (finest allowed)
//! - max_cells: Maximum number of cells in the covering
//!
//! Algorithm:
//! 1. Start with the 6 face cells
//! 2. For each cell, check containment:
//!    - Fully inside region: add to covering
//!    - Partially inside: subdivide into 4 children (if not at max_level)
//!    - Fully outside: discard
//! 3. Stop when max_cells reached or all cells processed
//! 4. Convert cells to normalized cell ranges

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const cell_id = @import("cell_id.zig");
const Cap = @import("cap.zig").Cap;

/// Default maximum cells in a covering (from spec: s2_max_cells = 16)
pub const default_max_cells: u32 = 16;

/// Default maximum level for query covering (from spec: s2_cover_max_level = 18)
pub const default_max_level: u8 = 18;

/// Default minimum level (face level)
pub const default_min_level: u8 = 0;

/// A range of contiguous cell IDs [range_min, range_max].
/// Both endpoints are inclusive.
pub const CellRange = struct {
    range_min: u64,
    range_max: u64,

    /// Check if a cell ID falls within this range.
    pub fn contains(self: CellRange, id: u64) bool {
        return id >= self.range_min and id <= self.range_max;
    }

    /// Check if two ranges overlap.
    pub fn overlaps(self: CellRange, other: CellRange) bool {
        return self.range_min <= other.range_max and other.range_min <= self.range_max;
    }

    /// Merge two adjacent or overlapping ranges.
    pub fn merge(self: CellRange, other: CellRange) ?CellRange {
        // Check if ranges are adjacent or overlapping
        if (self.range_max + 1 >= other.range_min and other.range_max + 1 >= self.range_min) {
            return CellRange{
                .range_min = @min(self.range_min, other.range_min),
                .range_max = @max(self.range_max, other.range_max),
            };
        }
        return null;
    }
};

/// A covering is a set of cell ranges that cover a region.
pub const Covering = struct {
    ranges: []CellRange,
    allocator: Allocator,

    pub fn deinit(self: *Covering) void {
        self.allocator.free(self.ranges);
    }

    /// Get the total number of ranges.
    pub fn numRanges(self: Covering) usize {
        return self.ranges.len;
    }

    /// Check if a cell ID is covered by any range.
    pub fn containsCell(self: Covering, id: u64) bool {
        for (self.ranges) |range| {
            if (range.contains(id)) return true;
        }
        return false;
    }
};

/// Region coverer for generating cell coverings.
pub const RegionCoverer = struct {
    min_level: u8,
    max_level: u8,
    max_cells: u32,

    /// Create a RegionCoverer with default parameters.
    pub fn init() RegionCoverer {
        return RegionCoverer{
            .min_level = default_min_level,
            .max_level = default_max_level,
            .max_cells = default_max_cells,
        };
    }

    /// Create a RegionCoverer with custom parameters.
    pub fn initWithParams(min_level: u8, max_level: u8, max_cells: u32) RegionCoverer {
        assert(min_level <= max_level);
        assert(max_level <= cell_id.max_level);
        return RegionCoverer{
            .min_level = min_level,
            .max_level = max_level,
            .max_cells = max_cells,
        };
    }

    /// Compute min_level from radius in meters (per spec).
    /// min_level = floor(log2(7842 km / radius_km))
    /// Clamped to [0, 18]
    pub fn levelForRadius(radius_meters: f64) u8 {
        if (radius_meters <= 0) return default_max_level;

        const radius_km = radius_meters / 1000.0;
        const earth_radius_km = 7842.0; // Approximate for level calculation

        // level = floor(log2(earth_radius / radius))
        const ratio = earth_radius_km / radius_km;
        if (ratio <= 1.0) return 0;

        // Use deterministic log2 calculation
        const log2_ratio = log2Approx(ratio);
        const level_float = @floor(log2_ratio);

        if (level_float < 0) return 0;
        if (level_float > default_max_level) return default_max_level;

        return @intFromFloat(level_float);
    }

    /// Generate a covering for a Cap (used for radius queries).
    pub fn coverCap(self: RegionCoverer, cap: Cap, allocator: Allocator) !Covering {
        // Calculate appropriate levels based on cap radius
        const radius = cap.radiusMeters();
        const suggested_min = levelForRadius(radius);

        const actual_min = @max(self.min_level, suggested_min);
        const actual_max = @min(self.max_level, @min(actual_min + 4, default_max_level));

        // Work list of cells to process
        var candidates = std.ArrayList(u64).init(allocator);
        defer candidates.deinit();

        // Result cells
        var result_cells = std.ArrayList(u64).init(allocator);
        defer result_cells.deinit();

        // Start with the 6 face cells at LEVEL 0 (face cells only exist at level 0)
        // Then we'll subdivide down to actual_min
        for (0..6) |f| {
            const face_cell = makeFaceCell(@intCast(f), 0);
            if (cap.mayIntersectCell(face_cell)) {
                try candidates.append(face_cell);
            }
        }

        // Process candidates
        while (candidates.items.len > 0 and result_cells.items.len < self.max_cells) {
            const current = candidates.pop().?;
            const current_level = cell_id.level(current);

            // For cells below actual_min, always subdivide
            if (current_level < actual_min) {
                const kids = cell_id.children(current);
                for (kids) |kid| {
                    if (cap.mayIntersectCell(kid)) {
                        try candidates.append(kid);
                    }
                }
                continue;
            }

            if (cap.containsCell(current)) {
                // Cell fully inside - add to result
                try result_cells.append(current);
            } else if (cap.mayIntersectCell(current)) {
                // Cell partially inside
                if (current_level < actual_max and
                    result_cells.items.len + candidates.items.len < self.max_cells * 4)
                {
                    // Subdivide into children
                    const kids = cell_id.children(current);
                    for (kids) |kid| {
                        if (cap.mayIntersectCell(kid)) {
                            try candidates.append(kid);
                        }
                    }
                } else {
                    // At max level or too many candidates, add as-is
                    try result_cells.append(current);
                }
            }
            // Else: fully outside, discard
        }

        // If we hit max_cells limit, add remaining candidates
        while (candidates.items.len > 0 and result_cells.items.len < self.max_cells) {
            try result_cells.append(candidates.pop().?);
        }

        // Convert cells to ranges
        return cellsToRanges(result_cells.items, allocator);
    }

    /// Generate a covering for a cell (used for testing/debugging).
    pub fn coverCell(self: RegionCoverer, target: u64, allocator: Allocator) !Covering {
        _ = self;
        // Single cell covering is just the cell's range
        const range = cellToRange(target);
        const ranges = try allocator.alloc(CellRange, 1);
        ranges[0] = range;
        return Covering{ .ranges = ranges, .allocator = allocator };
    }
};

/// Create a face cell at a given level.
fn makeFaceCell(f: u8, lvl: u8) u64 {
    // Face cell has face bits set and sentinel at appropriate position
    const face_bits: u64 = @as(u64, f) << 61;
    const sentinel: u64 = @as(u64, 1) << @intCast((cell_id.max_level - lvl) * 2);
    return face_bits | sentinel;
}

/// Convert a cell ID to a range [min, max].
/// The range covers all descendant cells at any level.
fn cellToRange(id: u64) CellRange {
    const lsb = id & (~id + 1);
    // range_min: cell ID with lowest bits cleared
    // range_max: cell ID with all position bits set up to level
    return CellRange{
        .range_min = id - lsb + 1,
        .range_max = id + lsb - 1,
    };
}

/// Convert a list of cells to normalized, non-overlapping ranges.
fn cellsToRanges(cells: []const u64, allocator: Allocator) !Covering {
    if (cells.len == 0) {
        const empty = try allocator.alloc(CellRange, 0);
        return Covering{ .ranges = empty, .allocator = allocator };
    }

    // Convert cells to ranges
    var ranges = std.ArrayList(CellRange).init(allocator);
    defer ranges.deinit();

    for (cells) |c| {
        try ranges.append(cellToRange(c));
    }

    // Sort by range_min
    std.mem.sort(CellRange, ranges.items, {}, struct {
        fn lessThan(_: void, a: CellRange, b: CellRange) bool {
            return a.range_min < b.range_min;
        }
    }.lessThan);

    // Merge adjacent/overlapping ranges
    var merged = std.ArrayList(CellRange).init(allocator);
    errdefer merged.deinit();

    var current = ranges.items[0];
    for (ranges.items[1..]) |next| {
        if (current.merge(next)) |m| {
            current = m;
        } else {
            try merged.append(current);
            current = next;
        }
    }
    try merged.append(current);

    return Covering{ .ranges = try merged.toOwnedSlice(), .allocator = allocator };
}

/// Compute log2 using deterministic math.
/// log2(x) = ln(x) / ln(2)
fn log2Approx(x: f64) f64 {
    // Simple approximation using bit manipulation for positive floats
    if (x <= 0) return -std.math.inf(f64);
    if (x == 1.0) return 0.0;

    // Get the exponent from the float representation
    const bits = @as(u64, @bitCast(x));
    const exp_bits = (bits >> 52) & 0x7FF;
    const exp = @as(i32, @intCast(exp_bits)) - 1023;

    // Get mantissa part: log2(1.m) using polynomial approximation
    const mantissa_bits = (bits & 0xFFFFFFFFFFFFF) | 0x3FF0000000000000;
    const m = @as(f64, @bitCast(mantissa_bits)) - 1.0;

    // Polynomial approximation for log2(1+m) where 0 <= m < 1
    // Coefficients: a=1.4426950408889634, b=0.7213475204444817, c=0.4808983469629878
    const a = 1.4426950408889634;
    const b = 0.7213475204444817;
    const c = 0.4808983469629878;
    const log2_mantissa = m * (a - m * (b - m * c));

    return @as(f64, @floatFromInt(exp)) + log2_mantissa;
}

// =============================================================================
// Tests
// =============================================================================

test "RegionCoverer: init" {
    const rc = RegionCoverer.init();
    try std.testing.expectEqual(@as(u8, default_min_level), rc.min_level);
    try std.testing.expectEqual(@as(u8, default_max_level), rc.max_level);
    try std.testing.expectEqual(@as(u32, default_max_cells), rc.max_cells);
}

test "RegionCoverer: level for radius" {
    // Large radius (1000km) should give low level
    const level_1000km = RegionCoverer.levelForRadius(1_000_000.0);
    try std.testing.expect(level_1000km <= 5);

    // Small radius (100m) should give high level
    const level_100m = RegionCoverer.levelForRadius(100.0);
    try std.testing.expect(level_100m >= 15);

    // Very small radius should cap at max_level
    const level_tiny = RegionCoverer.levelForRadius(1.0);
    try std.testing.expect(level_tiny == default_max_level);
}

test "RegionCoverer: cover cap basic" {
    const allocator = std.testing.allocator;

    // Create a cap centered at origin with 1000km radius
    const cap = Cap.fromLatLonNanoRadius(0, 0, 1_000_000.0);

    const rc = RegionCoverer.init();
    var covering = try rc.coverCap(cap, allocator);
    defer covering.deinit();

    // Should produce some ranges
    try std.testing.expect(covering.numRanges() > 0);
    try std.testing.expect(covering.numRanges() <= default_max_cells);
}

test "RegionCoverer: cover cap small" {
    const allocator = std.testing.allocator;

    // Small cap (100m radius) at San Francisco
    const cap = Cap.fromLatLonNanoRadius(37_774900000, -122_419400000, 100.0);

    const rc = RegionCoverer.init();
    var covering = try rc.coverCap(cap, allocator);
    defer covering.deinit();

    // Should produce a covering (number depends on cell boundaries)
    try std.testing.expect(covering.numRanges() > 0);
    try std.testing.expect(covering.numRanges() <= default_max_cells);
}

test "CellRange: merge adjacent" {
    const r1 = CellRange{ .range_min = 100, .range_max = 200 };
    const r2 = CellRange{ .range_min = 201, .range_max = 300 };

    const merged = r1.merge(r2);
    try std.testing.expect(merged != null);
    try std.testing.expectEqual(@as(u64, 100), merged.?.range_min);
    try std.testing.expectEqual(@as(u64, 300), merged.?.range_max);
}

test "CellRange: no merge disjoint" {
    const r1 = CellRange{ .range_min = 100, .range_max = 200 };
    const r2 = CellRange{ .range_min = 300, .range_max = 400 };

    const merged = r1.merge(r2);
    try std.testing.expect(merged == null);
}

test "cellToRange: basic" {
    // Create a cell at level 10
    const c = cell_id.fromLatLonNano(0, 0, 10);
    const range = cellToRange(c);

    // range_min should be less than cell ID
    try std.testing.expect(range.range_min <= c);
    // range_max should be greater than or equal to cell ID
    try std.testing.expect(range.range_max >= c);

    // Cell itself should be in range
    try std.testing.expect(range.contains(c));
}
