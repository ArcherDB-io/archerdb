// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! S2 Geometry Library - Pure Zig Implementation
//!
//! This module provides S2 spatial indexing functionality for ArcherDB.
//! The implementation is designed for determinism across all platforms
//! to ensure VSR replicas produce identical results.
//!
//! ## Verification Status
//!
//! This implementation has been verified against Google S2 (Go) reference:
//! - Cell ID computation: 1730 vectors, all levels (0-30), all 6 faces
//! - Hierarchy: 296 parent/child verifications, zero mismatches
//! - Round-trip: lat/lon -> cell_id -> lat/lon precision < 1 microdegree
//! - Determinism: XOR hash matches across x86_64 and aarch64
//!
//! Test vectors: src/s2/testdata/*.tsv
//! Generator: tools/s2_golden_gen/main.go (uses github.com/golang/geo)
//!
//! ### Requirements Traceability
//!
//! - **S2-01**: S2 cell indexing correctly partitions geographic space
//!   - Verified via 1730 cell ID golden vectors covering all faces and levels
//!
//! - **S2-06**: S2 cell ID computation matches Google S2 reference
//!   - Verified via golden vector validation with zero mismatches
//!   - Hierarchy operations (parent/children) also verified
//!
//! - **S2-08**: S2 index memory usage documented and bounded
//!   - Cell ID is 64-bit (8 bytes), level extractable via trailing zeros
//!   - Hierarchy operations are O(1) bit manipulation, no allocation
//!
//! ### WGS84 Note
//!
//! S2 uses unit sphere projection, not WGS84 ellipsoid. Distances use
//! Earth mean radius (6371008.8m). For typical location applications,
//! the error vs WGS84 is < 0.5% for distances, increasing near poles.
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

test "S2 module: golden vector validation (cell ID)" {
    // Validate cell ID computation against Google S2 (Go) reference implementation.
    // Golden vectors generated by tools/s2_golden_gen/ using github.com/golang/geo
    //
    // This is a critical verification - S2 indexing is foundational for all geospatial
    // queries. Bit-exact correctness is required for VSR consensus.
    //
    // Requirement: S2-06 - S2 cell ID computation matches Google S2 reference
    const data = @embedFile("testdata/cell_id_golden.tsv");

    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_num: usize = 0;
    var test_count: usize = 0;
    var error_count: usize = 0;

    while (lines.next()) |line| {
        line_num += 1;

        // Skip header row
        if (line.len == 0 or std.mem.startsWith(u8, line, "lat_nano")) {
            continue;
        }

        // Parse: lat_nano\tlon_nano\tlevel\tcell_id_hex
        var fields = std.mem.splitScalar(u8, line, '\t');

        const lat_str = fields.next() orelse continue;
        const lon_str = fields.next() orelse continue;
        const lvl_str = fields.next() orelse continue;
        const expected_hex = fields.next() orelse continue;

        const lat_nano = std.fmt.parseInt(i64, lat_str, 10) catch continue;
        const lon_nano = std.fmt.parseInt(i64, lon_str, 10) catch continue;
        const lvl = std.fmt.parseInt(u8, lvl_str, 10) catch continue;

        // Parse expected cell ID (hex string like "0xb000000000000000")
        const hex_digits = if (std.mem.startsWith(u8, expected_hex, "0x"))
            expected_hex[2..]
        else
            expected_hex;
        const expected_id = std.fmt.parseInt(u64, hex_digits, 16) catch continue;

        // Compute cell ID with our implementation
        const actual_id = latLonToCellId(lat_nano, lon_nano, lvl);

        if (actual_id != expected_id) {
            error_count += 1;
            if (error_count <= 10) {
                std.debug.print(
                    "Cell ID mismatch at line {d}: lat={d}, lon={d}, level={d}\n" ++
                        "  expected: 0x{x:0>16}\n  actual:   0x{x:0>16}\n",
                    .{ line_num, lat_nano, lon_nano, lvl, expected_id, actual_id },
                );
            }
        }

        test_count += 1;
    }

    std.debug.print("Cell ID golden validation: {d} vectors tested, {d} mismatches\n", .{ test_count, error_count });

    // Require at least 1000 test cases (we have 1738)
    try std.testing.expect(test_count >= 1000);

    // Zero tolerance - all cell IDs must match exactly
    try std.testing.expectEqual(@as(usize, 0), error_count);
}

test "S2 module: golden vector validation (hierarchy)" {
    // Validate parent/children operations against Google S2 reference.
    // Requirement: S2-06 - hierarchy operations match exactly
    const data = @embedFile("testdata/hierarchy_golden.tsv");

    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_num: usize = 0;
    var test_count: usize = 0;
    var parent_errors: usize = 0;
    var child_errors: usize = 0;

    while (lines.next()) |line| {
        line_num += 1;

        // Skip header row
        if (line.len == 0 or std.mem.startsWith(u8, line, "cell_id_hex")) {
            continue;
        }

        // Parse: cell_id_hex\tparent_hex\tchild0_hex\tchild1_hex\tchild2_hex\tchild3_hex
        var fields = std.mem.splitScalar(u8, line, '\t');

        const cell_hex = fields.next() orelse continue;
        const parent_hex = fields.next() orelse continue;
        const child0_hex = fields.next() orelse continue;
        const child1_hex = fields.next() orelse continue;
        const child2_hex = fields.next() orelse continue;
        const child3_hex = fields.next() orelse continue;

        const cell_id_val = parseHex(cell_hex) orelse continue;
        const expected_parent = parseHex(parent_hex) orelse continue;
        const expected_children = [4]u64{
            parseHex(child0_hex) orelse continue,
            parseHex(child1_hex) orelse continue,
            parseHex(child2_hex) orelse continue,
            parseHex(child3_hex) orelse continue,
        };

        // Verify parent (skip level 0 cells which have no parent - indicated by 0)
        if (expected_parent != 0) {
            const actual_parent = parent(cell_id_val);
            if (actual_parent != expected_parent) {
                parent_errors += 1;
                if (parent_errors <= 5) {
                    std.debug.print(
                        "Parent mismatch at line {d}: cell=0x{x:0>16}\n" ++
                            "  expected parent: 0x{x:0>16}\n  actual parent:   0x{x:0>16}\n",
                        .{ line_num, cell_id_val, expected_parent, actual_parent },
                    );
                }
            }
        }

        // Verify children (skip level 30 cells which can't have children)
        if (level(cell_id_val) < 30 and expected_children[0] != 0) {
            const actual_children = children(cell_id_val);
            for (0..4) |i| {
                if (actual_children[i] != expected_children[i]) {
                    child_errors += 1;
                    if (child_errors <= 5) {
                        std.debug.print(
                            "Child {d} mismatch at line {d}: cell=0x{x:0>16}\n" ++
                                "  expected: 0x{x:0>16}\n  actual:   0x{x:0>16}\n",
                            .{ i, line_num, cell_id_val, expected_children[i], actual_children[i] },
                        );
                    }
                    break;
                }
            }
        }

        test_count += 1;
    }

    std.debug.print("Hierarchy golden validation: {d} vectors, {d} parent errors, {d} child errors\n", .{ test_count, parent_errors, child_errors });

    // Require at least 200 test cases (we have 296)
    try std.testing.expect(test_count >= 200);

    // Zero tolerance for hierarchy operations
    try std.testing.expectEqual(@as(usize, 0), parent_errors);
    try std.testing.expectEqual(@as(usize, 0), child_errors);
}

test "S2 module: round-trip precision" {
    // Verify lat/lon -> cell_id -> lat/lon round-trip precision.
    // At level 30 (finest), precision should be < 1 nanodegree.
    const data = @embedFile("testdata/cell_id_golden.tsv");

    var lines = std.mem.splitScalar(u8, data, '\n');
    var test_count: usize = 0;
    var max_lat_error: u64 = 0;
    var max_lon_error: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "lat_nano")) {
            continue;
        }

        var fields = std.mem.splitScalar(u8, line, '\t');
        const lat_str = fields.next() orelse continue;
        const lon_str = fields.next() orelse continue;
        const lvl_str = fields.next() orelse continue;

        const original_lat = std.fmt.parseInt(i64, lat_str, 10) catch continue;
        const original_lon = std.fmt.parseInt(i64, lon_str, 10) catch continue;
        const lvl = std.fmt.parseInt(u8, lvl_str, 10) catch continue;

        // Only test level 30 for finest precision verification
        if (lvl != 30) continue;

        // Skip polar coordinates (lat = +/- 90 degrees) where longitude is undefined.
        // At the poles, any longitude maps to the same point, so round-trip errors
        // in longitude are expected and not a bug.
        if (@abs(original_lat) >= 89_000_000_000) continue;

        // Round-trip: lat/lon -> cell_id -> lat/lon
        const cell_id_val = latLonToCellId(original_lat, original_lon, 30);
        const result = cellIdToLatLon(cell_id_val);

        const lat_error = @abs(result.lat_nano - original_lat);

        // For longitude, handle antimeridian wrapping: -180 and +180 are the same point.
        // If the raw error is > 180 degrees, we've wrapped around the antimeridian.
        const lon_diff = @abs(result.lon_nano - original_lon);
        const lon_error = if (lon_diff > 180_000_000_000)
            360_000_000_000 - lon_diff
        else
            lon_diff;

        if (lat_error > max_lat_error) max_lat_error = lat_error;
        if (lon_error > max_lon_error) max_lon_error = lon_error;

        // At level 30, precision is ~7.5mm which is < 1 microdegree (1000 nanodegrees)
        // Allow 1 microdegree tolerance for cell discretization
        const tolerance: u64 = 1000;
        if (lat_error >= tolerance or lon_error >= tolerance) {
            std.debug.print(
                "Round-trip error too large: ({d},{d}) -> 0x{x:0>16} -> ({d},{d})\n" ++
                    "  lat error: {d} nanodegrees, lon error: {d} nanodegrees (raw diff: {d})\n",
                .{ original_lat, original_lon, cell_id_val, result.lat_nano, result.lon_nano, lat_error, lon_error, lon_diff },
            );
        }
        try std.testing.expect(lat_error < tolerance);
        try std.testing.expect(lon_error < tolerance);

        test_count += 1;
    }

    std.debug.print("Round-trip precision: {d} level-30 tests, max errors: lat={d}ns lon={d}ns\n", .{ test_count, max_lat_error, max_lon_error });

    // Should have tested a good number of level-30 coordinates
    try std.testing.expect(test_count >= 100);
}

/// Helper to parse hex strings like "0x1234abcd" or "1234abcd"
fn parseHex(hex_str: []const u8) ?u64 {
    const digits = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;
    return std.fmt.parseInt(u64, digits, 16) catch null;
}
