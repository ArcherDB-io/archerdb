//! S2 Determinism Checker for VOPR (F4.1.4)
//!
//! This module verifies that S2 cell computations are deterministic across
//! all replicas in the cluster. Any non-determinism in S2 cell ID calculation
//! would cause replicas to diverge, breaking consensus.
//!
//! ## Invariants Checked
//!
//! 1. **Coordinate-to-CellId Determinism**: Same (lat, lon, level) must always
//!    produce the same S2 cell ID across all calls and all replicas.
//!
//! 2. **Cross-Replica Consistency**: All replicas must compute identical S2 cell
//!    IDs for the same GeoEvent coordinates.
//!
//! 3. **Edge Case Handling**: Poles, anti-meridian, and cell face boundaries
//!    must produce consistent results.
//!
//! ## Usage in VOPR
//!
//! The checker is called whenever:
//! - A GeoEvent is inserted (records the computed S2 cell ID)
//! - A spatial query is executed (verifies covering computation)
//! - Cross-replica state is compared (asserts S2 data matches)

const std = @import("std");
const assert = std.debug.assert;
const s2_cell_id = @import("../../s2/cell_id.zig");

/// S2 Determinism Checker verifies that S2 cell computations are deterministic.
pub const S2DeterminismChecker = struct {
    /// Map of (lat_nano, lon_nano, level) -> expected S2 cell ID
    const CellIdMap = std.AutoHashMap(CoordinateKey, u64);

    /// Key for coordinate lookup
    const CoordinateKey = struct {
        lat_nano: i64,
        lon_nano: i64,
        level: u8,
    };

    /// Statistics for monitoring
    pub const Stats = struct {
        checks_performed: u64 = 0,
        determinism_verified: u64 = 0,
        edge_case_checks: u64 = 0,
        pole_checks: u64 = 0,
        antimeridian_checks: u64 = 0,
        face_boundary_checks: u64 = 0,
    };

    /// Tracked coordinate->cell_id mappings
    cell_ids: CellIdMap,

    /// Statistics
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) S2DeterminismChecker {
        return .{
            .cell_ids = CellIdMap.init(allocator),
        };
    }

    pub fn deinit(checker: *S2DeterminismChecker) void {
        checker.cell_ids.deinit();
    }

    /// Verify that S2 cell ID computation is deterministic.
    /// Called when a GeoEvent is inserted or when comparing replica state.
    ///
    /// Returns the cell ID and asserts it matches any previously recorded value.
    pub fn verify_cell_id(
        checker: *S2DeterminismChecker,
        lat_nano: i64,
        lon_nano: i64,
        level: u8,
    ) u64 {
        checker.stats.checks_performed += 1;

        // Compute the S2 cell ID
        const cell_id = s2_cell_id.fromLatLonNano(lat_nano, lon_nano, level);

        // Track edge cases
        checker.track_edge_case(lat_nano, lon_nano);

        // Check for determinism: same input must produce same output
        const key = CoordinateKey{
            .lat_nano = lat_nano,
            .lon_nano = lon_nano,
            .level = level,
        };

        const result = checker.cell_ids.getOrPut(key) catch unreachable;
        if (result.found_existing) {
            // Verify determinism: must produce same cell ID
            assert(result.value_ptr.* == cell_id);
            checker.stats.determinism_verified += 1;
        } else {
            // First time seeing this coordinate, record it
            result.value_ptr.* = cell_id;
        }

        return cell_id;
    }

    /// Assert that two replicas computed the same cell ID for coordinates.
    /// Called during cross-replica consistency checks.
    pub fn assert_cross_replica_consistency(
        checker: *S2DeterminismChecker,
        lat_nano: i64,
        lon_nano: i64,
        level: u8,
        replica_cell_id: u64,
    ) void {
        // Compute expected cell ID
        const expected = s2_cell_id.fromLatLonNano(lat_nano, lon_nano, level);

        // Assert replica computed the same value
        assert(replica_cell_id == expected);

        // Also verify against our records
        const key = CoordinateKey{
            .lat_nano = lat_nano,
            .lon_nano = lon_nano,
            .level = level,
        };

        if (checker.cell_ids.get(key)) |recorded| {
            assert(recorded == replica_cell_id);
        }

        checker.stats.checks_performed += 1;
        checker.stats.determinism_verified += 1;
    }

    /// Verify determinism at known edge-case coordinates.
    /// Per spec: poles, anti-meridian, equator/prime meridian, cell boundaries.
    pub fn verify_edge_cases(checker: *S2DeterminismChecker, level: u8) void {
        // Edge case coordinates from testing-simulation spec
        const edge_cases = [_]struct { lat: i64, lon: i64 }{
            // Poles
            .{ .lat = 90_000_000_000, .lon = 0 }, // North pole
            .{ .lat = -90_000_000_000, .lon = 0 }, // South pole
            // Anti-meridian
            .{ .lat = 0, .lon = 180_000_000_000 }, // East anti-meridian
            .{ .lat = 0, .lon = -180_000_000_000 }, // West anti-meridian
            // Origin
            .{ .lat = 0, .lon = 0 }, // Equator/Prime meridian
            // Near boundaries
            .{ .lat = 89_999_999_999, .lon = 0 }, // Near north pole
            .{ .lat = 0, .lon = 179_999_999_999 }, // Near anti-meridian
            // Minimum precision difference
            .{ .lat = 0, .lon = 1 }, // One nanodegree from origin
            .{ .lat = 1, .lon = 0 }, // One nanodegree from origin
        };

        for (edge_cases) |coord| {
            _ = checker.verify_cell_id(coord.lat, coord.lon, level);
            checker.stats.edge_case_checks += 1;
        }
    }

    /// Track edge case statistics
    fn track_edge_case(checker: *S2DeterminismChecker, lat_nano: i64, lon_nano: i64) void {
        // Poles (within 1 degree)
        if (@abs(lat_nano) >= 89_000_000_000) {
            checker.stats.pole_checks += 1;
        }

        // Anti-meridian (within 1 degree of ±180°)
        if (@abs(lon_nano) >= 179_000_000_000) {
            checker.stats.antimeridian_checks += 1;
        }

        // S2 face boundaries occur at approximately ±45° and ±135° longitude
        // and ±35.264° latitude (the cube face edges)
        const face_boundary_lons = [_]i64{
            45_000_000_000, 135_000_000_000, -45_000_000_000, -135_000_000_000,
        };
        const face_boundary_lat: i64 = 35_264_389_682; // atan(1/sqrt(2)) in nanodegrees

        for (face_boundary_lons) |boundary_lon| {
            // Within ~1 degree of face boundary
            if (@abs(lon_nano - boundary_lon) < 1_000_000_000) {
                checker.stats.face_boundary_checks += 1;
                break;
            }
        }

        // Check latitude face boundary
        if (@abs(@abs(lat_nano) - face_boundary_lat) < 1_000_000_000) {
            checker.stats.face_boundary_checks += 1;
        }
    }

    /// Get statistics for monitoring
    pub fn get_stats(checker: *const S2DeterminismChecker) Stats {
        return checker.stats;
    }

    /// Reset for next test run (keeps allocations)
    pub fn reset(checker: *S2DeterminismChecker) void {
        checker.cell_ids.clearRetainingCapacity();
        checker.stats = .{};
    }
};

// =============================================================================
// Tests
// =============================================================================

test "S2DeterminismChecker: basic determinism" {
    const allocator = std.testing.allocator;
    var checker = S2DeterminismChecker.init(allocator);
    defer checker.deinit();

    // Same coordinates must produce same cell ID
    const cell1 = checker.verify_cell_id(37_000_000_000, -122_000_000_000, 15);
    const cell2 = checker.verify_cell_id(37_000_000_000, -122_000_000_000, 15);

    try std.testing.expectEqual(cell1, cell2);
    try std.testing.expect(checker.stats.determinism_verified > 0);
}

test "S2DeterminismChecker: edge cases" {
    const allocator = std.testing.allocator;
    var checker = S2DeterminismChecker.init(allocator);
    defer checker.deinit();

    // Verify edge cases at level 15
    checker.verify_edge_cases(15);

    try std.testing.expect(checker.stats.edge_case_checks >= 9);
    try std.testing.expect(checker.stats.pole_checks > 0);
}

test "S2DeterminismChecker: cross-replica consistency" {
    const allocator = std.testing.allocator;
    var checker = S2DeterminismChecker.init(allocator);
    defer checker.deinit();

    const lat: i64 = 51_507_351_000; // London
    const lon: i64 = -127_580_000; // London

    // Compute cell ID
    const cell_id = checker.verify_cell_id(lat, lon, 20);

    // Simulate replica computing same value
    checker.assert_cross_replica_consistency(lat, lon, 20, cell_id);

    try std.testing.expect(checker.stats.determinism_verified >= 2);
}

test "S2DeterminismChecker: different levels produce different cells" {
    const allocator = std.testing.allocator;
    var checker = S2DeterminismChecker.init(allocator);
    defer checker.deinit();

    const lat: i64 = 0;
    const lon: i64 = 0;

    const cell_10 = checker.verify_cell_id(lat, lon, 10);
    const cell_20 = checker.verify_cell_id(lat, lon, 20);
    const cell_30 = checker.verify_cell_id(lat, lon, 30);

    // Different levels should produce different cell IDs
    try std.testing.expect(cell_10 != cell_20);
    try std.testing.expect(cell_20 != cell_30);
    try std.testing.expect(cell_10 != cell_30);
}
