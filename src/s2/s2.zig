//! S2 Geometry Library - Pure Zig Implementation
//!
//! This module provides S2 spatial indexing functionality for ArcherDB.
//! The implementation is designed for determinism across all platforms
//! to ensure VSR replicas produce identical results.
//!
//! ## Key Features
//!
//! - **Deterministic**: Uses software trigonometry (Chebyshev/CORDIC) instead
//!   of hardware FPU to guarantee bit-exact results across x86, ARM, etc.
//!
//! - **Hierarchical**: S2 cells form a quad-tree with parent/child relationships
//!   obtainable via bit operations.
//!
//! - **Space-filling**: Uses Hilbert curve ordering for spatial locality -
//!   nearby points on Earth have numerically close cell IDs.
//!
//! ## Usage
//!
//! ```zig
//! const s2 = @import("s2/s2.zig");
//!
//! // Convert lat/lon to S2 cell ID
//! const cell_id = s2.latLonToCellId(37_774900000, -122_419400000, 30);
//!
//! // Get cell hierarchy
//! const parent_id = s2.parent(cell_id);
//! const kids = s2.children(cell_id);
//!
//! // Reverse conversion
//! const ll = s2.cellIdToLatLon(cell_id);
//! ```
//!
//! ## References
//!
//! - S2 Geometry Library: https://s2geometry.io/
//! - S2 Cell Hierarchy: https://s2geometry.io/devguide/s2cell_hierarchy

const std = @import("std");

pub const math = @import("math.zig");
pub const cell_id = @import("cell_id.zig");
pub const cap = @import("cap.zig");
pub const region_coverer = @import("region_coverer.zig");

// Re-export commonly used types
pub const Cap = cap.Cap;
pub const RegionCoverer = region_coverer.RegionCoverer;
pub const Covering = region_coverer.Covering;
pub const CellRange = region_coverer.CellRange;

// Re-export commonly used functions at top level

/// Convert latitude and longitude (in nanodegrees) to S2 cell ID.
///
/// Arguments:
/// - lat_nano: Latitude in nanodegrees (-90_000_000_000 to +90_000_000_000)
/// - lon_nano: Longitude in nanodegrees (-180_000_000_000 to +180_000_000_000)
/// - level: S2 level (0-30), where 30 is maximum precision (~7.5mm)
///
/// Returns: 64-bit S2 cell ID
pub const latLonToCellId = cell_id.fromLatLonNano;

/// Convert latitude and longitude (in radians) to S2 cell ID.
pub const latLonRadiansToCellId = cell_id.fromLatLonRadians;

/// Convert S2 cell ID to latitude and longitude (in nanodegrees).
/// Returns the center point of the cell.
pub const cellIdToLatLon = cell_id.toLatLonNano;

/// Convert S2 cell ID to latitude and longitude (in radians).
pub const cellIdToLatLonRadians = cell_id.toLatLonRadians;

/// Get the face (0-5) of the S2 cube that a cell belongs to.
pub const face = cell_id.face;

/// Get the level (0-30) of a cell.
pub const level = cell_id.level;

/// Get the parent cell (one level coarser).
pub const parent = cell_id.parent;

/// Get the parent cell at a specific level.
pub const parentAtLevel = cell_id.parentAtLevel;

/// Get the four child cells (one level finer).
pub const children = cell_id.children;

/// Check if a cell ID is valid.
pub const isValid = cell_id.isValid;

/// Maximum S2 level (finest granularity).
pub const max_level = cell_id.max_level;

/// Number of faces on the S2 cube.
pub const num_faces = cell_id.num_faces;

// =============================================================================
// Integration Tests
// =============================================================================

test "S2 module: basic workflow" {
    // San Francisco coordinates in nanodegrees
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;

    // Convert to cell ID at maximum precision
    const id = latLonToCellId(lat_nano, lon_nano, 30);

    // Verify it's valid
    try std.testing.expect(isValid(id));
    try std.testing.expectEqual(@as(u8, 30), level(id));

    // Get parent at level 20
    const parent_id = parentAtLevel(id, 20);
    try std.testing.expectEqual(@as(u8, 20), level(parent_id));

    // Verify hierarchy
    var current = id;
    while (level(current) > 20) {
        current = parent(current);
    }
    try std.testing.expectEqual(parent_id, current);
}

test "S2 module: round-trip conversion" {
    const test_coords = [_][2]i64{
        .{ 0, 0 }, // Origin
        .{ 37_774900000, -122_419400000 }, // San Francisco
        .{ 51_507400000, -127800000 }, // London
        .{ 35_689500000, 139_691700000 }, // Tokyo
        .{ -33_868800000, 151_209300000 }, // Sydney
    };

    for (test_coords) |coord| {
        const id = latLonToCellId(coord[0], coord[1], 30);
        const result = cellIdToLatLon(id);

        // Allow 1 microdegree tolerance (due to cell discretization)
        const tolerance: i64 = 1000;
        try std.testing.expect(@abs(result.lat_nano - coord[0]) < tolerance);
        try std.testing.expect(@abs(result.lon_nano - coord[1]) < tolerance);
    }
}

test "S2 module: determinism" {
    // Run same computation multiple times, verify identical results
    const lat_nano: i64 = 37_774900000;
    const lon_nano: i64 = -122_419400000;

    const id1 = latLonToCellId(lat_nano, lon_nano, 30);
    const id2 = latLonToCellId(lat_nano, lon_nano, 30);
    const id3 = latLonToCellId(lat_nano, lon_nano, 30);

    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(id2, id3);
}
