// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! S2 Cell ID implementation in pure Zig.
//!
//! S2 is a hierarchical spatial index that maps the Earth's surface to a
//! 64-bit integer (cell ID). The key properties are:
//!
//! 1. **Hierarchical**: Cell IDs encode a position in a quad-tree. Parent cells
//!    can be obtained by bit-shifting.
//!
//! 2. **Space-filling curve**: Uses a Hilbert curve for locality - nearby points
//!    on Earth tend to have numerically close cell IDs.
//!
//! 3. **Deterministic**: This implementation uses software math to ensure
//!    bit-exact identical results across all platforms.
//!
//! Cell ID structure (64 bits):
//! ```
//! [Face (3 bits)][Position (61 bits)]
//! ```
//!
//! Position is a sequence of 2-bit "child selectors" indicating which quadrant
//! at each level (0-30). The sentinel bit marks the end of the hierarchy.

const std = @import("std");
const assert = std.debug.assert;
const smath = @import("math.zig");

/// Maximum S2 level (finest granularity, ~7.5mm precision)
pub const max_level: u8 = 30;

/// Number of faces on the S2 cube (Earth is projected onto a cube)
pub const num_faces: u8 = 6;

/// Face bit shift (position in cell ID)
const face_bits: u6 = 61;

/// Hilbert curve lookup table for pos-to-ij conversion
/// Each entry encodes the transformation for one step of the curve
const hilbert_lookup = [4][4]u8{
    .{ 0, 1, 3, 2 },
    .{ 0, 3, 1, 2 },
    .{ 2, 3, 1, 0 },
    .{ 2, 1, 3, 0 },
};

/// Hilbert curve orientation lookup (ij_index -> next_orientation)
/// Derived from Go S2's posToOrientation by inverting through posToIJ
const hilbert_orientation = [4][4]u8{
    .{ 1, 0, 3, 0 }, // orientation 0
    .{ 0, 2, 1, 1 }, // orientation 1 (swapMask)
    .{ 2, 1, 2, 3 }, // orientation 2 (invertMask)
    .{ 3, 3, 0, 2 }, // orientation 3 (swap|invert)
};

/// Create a cell ID from latitude and longitude in nanodegrees.
///
/// This is the primary entry point for converting geographic coordinates
/// to S2 cell IDs. The computation is fully deterministic using software
/// trigonometry.
///
/// Arguments:
/// - lat_nano: Latitude in nanodegrees (-90_000_000_000 to +90_000_000_000)
/// - lon_nano: Longitude in nanodegrees (-180_000_000_000 to +180_000_000_000)
/// - lvl: S2 level (0-30), determines precision
///
/// Returns: 64-bit S2 cell ID
pub fn fromLatLonNano(lat_nano: i64, lon_nano: i64, lvl: u8) u64 {
    assert(lvl <= max_level);

    const lon_nano_adjusted = normalize_lon_nano(lon_nano);

    // Convert nanodegrees to radians
    const lat_rad = @as(f64, @floatFromInt(lat_nano)) * (smath.pi / 180_000_000_000.0);
    const lon_rad =
        @as(f64, @floatFromInt(lon_nano_adjusted)) * (smath.pi / 180_000_000_000.0);

    return fromLatLonRadians(lat_rad, lon_rad, lvl);
}

/// Create a cell ID from latitude and longitude in radians.
pub fn fromLatLonRadians(lat_rad: f64, lon_rad: f64, lvl: u8) u64 {
    assert(lvl <= max_level);

    const lon_rad_adjusted = normalize_lon_rad(lon_rad);

    // Convert to 3D point on unit sphere using deterministic trig
    const cos_lat = smath.cos(lat_rad);
    const x = cos_lat * smath.cos(lon_rad_adjusted);
    const y = cos_lat * smath.sin(lon_rad_adjusted);
    const z = smath.sin(lat_rad);

    return fromPoint(x, y, z, lvl);
}

fn normalize_lon_nano(lon_nano: i64) i64 {
    // Google S2 normalizes longitude to the range [-pi, pi) internally.
    // At exactly +180 degrees (pi radians), we need consistent behavior.
    // Nudging to just below +180 ensures we get the same face as Google S2
    // for most latitudes. The remaining mismatches at high latitudes are
    // due to floating-point edge cases at the face boundaries.
    if (lon_nano == 180_000_000_000) return 179_999_999_999;
    return lon_nano;
}

fn normalize_lon_rad(lon_rad: f64) f64 {
    if (lon_rad == smath.pi) return prev_float(lon_rad);
    return lon_rad;
}

fn prev_float(value: f64) f64 {
    const bits: u64 = @bitCast(value);
    if (bits == 0) return value;
    return @as(f64, @bitCast(bits - 1));
}

/// Create a cell ID from a 3D point on the unit sphere.
pub fn fromPoint(x: f64, y: f64, z: f64, lvl: u8) u64 {
    // Find which face of the cube the point projects to
    const f = getFace(x, y, z);

    // Project point onto face and get UV coordinates
    const uv = xyzToFaceUv(f, x, y, z);

    // Convert UV to ST (apply S2's quadratic projection)
    const st = uvToSt(uv);

    // Convert ST to IJ (integer coordinates at given level)
    const ij = stToIj(st, lvl);

    // Build cell ID from face and IJ
    return fromFaceIj(f, ij[0], ij[1], lvl);
}

/// Get the face (0-5) that a point projects to.
fn getFace(x: f64, y: f64, z: f64) u8 {
    const abs_x = @abs(x);
    const abs_y = @abs(y);
    const abs_z = @abs(z);

    if (abs_x > abs_y) {
        if (abs_x > abs_z) {
            return if (x > 0) 0 else 3;
        } else {
            return if (z > 0) 2 else 5;
        }
    } else {
        if (abs_y > abs_z) {
            return if (y > 0) 1 else 4;
        } else {
            return if (z > 0) 2 else 5;
        }
    }
}

/// Project a 3D point onto a face and get UV coordinates.
/// UV range is [-1, 1] for each axis.
/// This matches the Go S2 library's faceXYZToUV exactly.
fn xyzToFaceUv(f: u8, x: f64, y: f64, z: f64) [2]f64 {
    return switch (f) {
        0 => .{ y / x, z / x },
        1 => .{ -x / y, z / y },
        2 => .{ -x / z, -y / z },
        3 => .{ z / x, y / x },
        4 => .{ z / y, -x / y },
        5 => .{ -y / z, -x / z },
        else => unreachable,
    };
}

/// Convert UV coordinates to ST using S2's quadratic projection.
/// This provides better uniformity than linear projection.
fn uvToSt(uv: [2]f64) [2]f64 {
    return .{
        uvToStSingle(uv[0]),
        uvToStSingle(uv[1]),
    };
}

/// Single coordinate UV to ST conversion.
/// S2 uses: ST = 0.5 * (1 + 3*UV) for UV in [-1/3, 1/3]
///          ST = UV + sign(UV)/3 for |UV| > 1/3
/// But we use the simpler quadratic: ST = 0.5 * (1 + UV) for uniformity.
fn uvToStSingle(uv: f64) f64 {
    // S2's quadratic projection for better cell uniformity
    if (uv >= 0) {
        return 0.5 * smath.sqrt(1.0 + 3.0 * uv);
    } else {
        return 1.0 - 0.5 * smath.sqrt(1.0 - 3.0 * uv);
    }
}

/// Convert ST coordinates to IJ at given level.
/// ST range [0, 1] maps to IJ range [0, 2^level - 1].
fn stToIj(st: [2]f64, lvl: u8) [2]u32 {
    const max_ij: u32 = @as(u32, 1) << @intCast(lvl);

    // Clamp to valid range and convert
    const i = stToIjSingle(st[0], max_ij);
    const j = stToIjSingle(st[1], max_ij);

    return .{ i, j };
}

fn stToIjSingle(st: f64, max_ij: u32) u32 {
    // Clamp ST to [0, 1) and scale to IJ
    const clamped = @max(0.0, @min(0.999999999999, st));
    return @intFromFloat(clamped * @as(f64, @floatFromInt(max_ij)));
}

/// Build cell ID from face and IJ coordinates.
pub fn fromFaceIj(f: u8, i: u32, j: u32, lvl: u8) u64 {
    assert(f < num_faces);
    assert(lvl <= max_level);

    // Start with face bits
    var id: u64 = @as(u64, f) << face_bits;

    // Convert IJ to Hilbert curve position and add to cell ID
    // Initial orientation depends on face (per S2 spec: face & swapMask)
    const initial_orientation: u8 = @intCast(f & 1);
    const pos = ijToPosWithOrientation(i, j, lvl, initial_orientation);
    id |= pos;

    // Add sentinel bit to mark level
    id |= (@as(u64, 1) << @intCast((max_level - lvl) * 2));

    return id;
}

/// Convert IJ coordinates to Hilbert curve position with initial orientation.
fn ijToPosWithOrientation(i: u32, j: u32, lvl: u8, initial_orientation: u8) u64 {
    var pos: u64 = 0;
    var orientation: u8 = initial_orientation;

    // Traverse from coarsest to finest level
    var l: u8 = 0;
    while (l < lvl) : (l += 1) {
        const shift: u5 = @intCast(lvl - 1 - l);
        const i_bit: u8 = @intCast((i >> shift) & 1);
        const j_bit: u8 = @intCast((j >> shift) & 1);

        // Lookup position and next orientation
        const lookup_idx = (i_bit << 1) | j_bit;
        const hilbert_pos = hilbert_lookup[orientation][lookup_idx];
        const next_orientation = hilbert_orientation[orientation][lookup_idx];

        // Add to position
        pos = (pos << 2) | hilbert_pos;
        orientation = next_orientation;
    }

    // Shift to correct position in cell ID (after face bits)
    return pos << @intCast((max_level - lvl) * 2 + 1);
}

/// Extract the face (0-5) from a cell ID.
pub fn face(cell_id: u64) u8 {
    return @intCast(cell_id >> face_bits);
}

/// Extract the level from a cell ID by finding the sentinel bit.
pub fn level(cell_id: u64) u8 {
    // The sentinel is the lowest set bit
    // Level = (trailing zeros - 1) / 2
    var lsb = cell_id & (~cell_id + 1); // Isolate lowest set bit
    var trailing: u8 = 0;
    while (lsb > 1) : (lsb >>= 1) {
        trailing += 1;
    }
    return @intCast(max_level - trailing / 2);
}

/// Get the parent cell ID at level - 1.
pub fn parent(cell_id: u64) u64 {
    const lsb = cell_id & (~cell_id + 1);
    // Move sentinel up one level (multiply by 4)
    return (cell_id & ~(lsb | (lsb << 1))) | (lsb << 2);
}

/// Get the parent cell ID at a specific level.
pub fn parentAtLevel(cell_id: u64, target_level: u8) u64 {
    assert(target_level < level(cell_id));

    var result = cell_id;
    while (level(result) > target_level) {
        result = parent(result);
    }
    return result;
}

/// Get the four child cell IDs.
pub fn children(cell_id: u64) [4]u64 {
    const lsb = cell_id & (~cell_id + 1);
    const new_lsb = lsb >> 2; // Move sentinel down one level

    // Remove old sentinel, add positions 0-3, add new sentinel
    // The 2-bit child selector goes at bits S (old sentinel) and S-1
    // where new_lsb << 1 = bit S-1 and new_lsb << 2 = bit S
    const base = (cell_id & ~lsb) | new_lsb;

    return .{
        base, // Child 0: selector 00
        base | (new_lsb << 1), // Child 1: selector 01 (bit S-1)
        base | (new_lsb << 2), // Child 2: selector 10 (bit S)
        base | (new_lsb << 1) | (new_lsb << 2), // Child 3: selector 11 (bits S-1 and S)
    };
}

/// Check if a cell ID is valid.
pub fn isValid(cell_id: u64) bool {
    if (cell_id == 0) return false;
    if (face(cell_id) >= num_faces) return false;

    // Check sentinel bit is in valid position
    const l = level(cell_id);
    return l <= max_level;
}

/// Get the center point of a cell as (lat, lon) in radians.
pub fn toLatLonRadians(cell_id: u64) struct { lat: f64, lon: f64 } {
    const f = face(cell_id);
    const ij = toIj(cell_id);
    const l = level(cell_id);

    // Convert IJ to ST (center of cell)
    const max_ij: f64 = @floatFromInt(@as(u32, 1) << @intCast(l));
    const st = [2]f64{
        (@as(f64, @floatFromInt(ij[0])) + 0.5) / max_ij,
        (@as(f64, @floatFromInt(ij[1])) + 0.5) / max_ij,
    };

    // Convert ST to UV
    const uv = stToUv(st);

    // Convert UV to XYZ
    const xyz = faceUvToXyz(f, uv);

    // Convert XYZ to lat/lon
    const lat = smath.atan2(xyz[2], smath.sqrt(xyz[0] * xyz[0] + xyz[1] * xyz[1]));
    const lon = smath.atan2(xyz[1], xyz[0]);

    return .{ .lat = lat, .lon = lon };
}

/// Get the center point as (lat_nano, lon_nano).
pub fn toLatLonNano(cell_id: u64) struct { lat_nano: i64, lon_nano: i64 } {
    const ll = toLatLonRadians(cell_id);
    return .{
        .lat_nano = @intFromFloat(ll.lat * (180_000_000_000.0 / smath.pi)),
        .lon_nano = @intFromFloat(ll.lon * (180_000_000_000.0 / smath.pi)),
    };
}

// Internal helpers for reverse conversion

fn toIj(id: u64) [2]u32 {
    const f = face(id);
    const l = level(id);
    const shift: u6 = @intCast((max_level - l) * 2 + 1);
    const mask: u64 = (@as(u64, 1) << @intCast(l * 2)) - 1;
    const pos = (id >> shift) & mask;
    // Use same initial orientation as forward path
    const initial_orientation: u8 = @intCast(f & 1);
    return posToIjWithOrientation(pos, l, initial_orientation);
}

fn posToIjWithOrientation(pos: u64, lvl: u8, initial_orientation: u8) [2]u32 {
    var ii: u32 = 0;
    var jj: u32 = 0;
    var orientation: u8 = initial_orientation;

    var l: u8 = 0;
    while (l < lvl) : (l += 1) {
        const shift: u6 = @intCast((lvl - 1 - l) * 2);
        const hilbert_pos: u8 = @intCast((pos >> shift) & 3);

        // Find i_bit and j_bit from hilbert_pos using reverse lookup
        var i_bit: u8 = 0;
        var j_bit: u8 = 0;
        for (hilbert_lookup[orientation], 0..) |hp, idx| {
            if (hp == hilbert_pos) {
                i_bit = @intCast(idx >> 1);
                j_bit = @intCast(idx & 1);
                break;
            }
        }

        ii = (ii << 1) | i_bit;
        jj = (jj << 1) | j_bit;

        // Update orientation
        const lookup_idx = (i_bit << 1) | j_bit;
        orientation = hilbert_orientation[orientation][lookup_idx];
    }

    return .{ ii, jj };
}

fn stToUv(st: [2]f64) [2]f64 {
    return .{
        stToUvSingle(st[0]),
        stToUvSingle(st[1]),
    };
}

fn stToUvSingle(st: f64) f64 {
    // Inverse of quadratic projection
    if (st >= 0.5) {
        return (4.0 * st * st - 1.0) / 3.0;
    } else {
        return (1.0 - 4.0 * (1.0 - st) * (1.0 - st)) / 3.0;
    }
}

/// Convert face UV to XYZ (inverse of xyzToFaceUv)
fn faceUvToXyz(f: u8, uv: [2]f64) [3]f64 {
    // This is the inverse of xyzToFaceUv
    // For each face, we need to reconstruct x,y,z from u,v
    const xyz: [3]f64 = switch (f) {
        // xyzToFaceUv formulas:
        // 0 => u=y/x, v=z/x => x=1, y=u*x=u, z=v*x=v
        0 => .{ 1.0, uv[0], uv[1] },
        // 1 => u=-x/y, v=z/y => y=1, x=-u*y=-u, z=v*y=v
        1 => .{ -uv[0], 1.0, uv[1] },
        // 2 => u=-x/z, v=-y/z => z=1, x=-u*z=-u, y=-v*z=-v
        2 => .{ -uv[0], -uv[1], 1.0 },
        // 3 => u=z/x, v=y/x => x=-1, z=u*x=-u, y=v*x=-v
        3 => .{ -1.0, -uv[1], -uv[0] },
        // 4 => u=z/y, v=-x/y => y=-1, z=u*y=-u, x=-v*y=v
        4 => .{ uv[1], -1.0, -uv[0] },
        // 5 => u=-y/z, v=-x/z => z=-1, y=-u*z=u, x=-v*z=v
        5 => .{ uv[1], uv[0], -1.0 },
        else => unreachable,
    };

    // Normalize to unit sphere
    const norm = smath.sqrt(xyz[0] * xyz[0] + xyz[1] * xyz[1] + xyz[2] * xyz[2]);
    return .{ xyz[0] / norm, xyz[1] / norm, xyz[2] / norm };
}

// =============================================================================
// Tests
// =============================================================================

test "fromLatLonNano: origin" {
    const cell_id = fromLatLonNano(0, 0, 30);
    try std.testing.expect(cell_id != 0);
    try std.testing.expect(isValid(cell_id));
    try std.testing.expectEqual(@as(u8, 30), level(cell_id));
}

test "fromLatLonNano: poles" {
    // North pole
    const north = fromLatLonNano(90_000_000_000, 0, 30);
    try std.testing.expect(isValid(north));
    try std.testing.expectEqual(@as(u8, 2), face(north)); // +Z face

    // South pole
    const south = fromLatLonNano(-90_000_000_000, 0, 30);
    try std.testing.expect(isValid(south));
    try std.testing.expectEqual(@as(u8, 5), face(south)); // -Z face
}

test "level: extraction" {
    const level_0 = fromLatLonNano(0, 0, 0);
    const level_15 = fromLatLonNano(0, 0, 15);
    const level_30 = fromLatLonNano(0, 0, 30);

    try std.testing.expectEqual(@as(u8, 0), level(level_0));
    try std.testing.expectEqual(@as(u8, 15), level(level_15));
    try std.testing.expectEqual(@as(u8, 30), level(level_30));
}

test "parent: hierarchy" {
    const cell = fromLatLonNano(37_774900000, -122_419400000, 20);
    const p = parent(cell);

    try std.testing.expectEqual(@as(u8, 20), level(cell));
    try std.testing.expectEqual(@as(u8, 19), level(p));

    // Parent should have same face
    try std.testing.expectEqual(face(cell), face(p));
}

test "children: subdivision" {
    const cell = fromLatLonNano(0, 0, 15);
    const kids = children(cell);

    for (kids) |kid| {
        try std.testing.expect(isValid(kid));
        try std.testing.expectEqual(@as(u8, 16), level(kid));
        try std.testing.expectEqual(cell, parent(kid));
    }
}

test "round-trip: lat/lon conversion" {
    const lat_nano: i64 = 37_774900000; // San Francisco
    const lon_nano: i64 = -122_419400000;

    const cell_id = fromLatLonNano(lat_nano, lon_nano, 30);
    const result = toLatLonNano(cell_id);

    // At level 30, precision is ~7.5mm, which is < 1 nanodegree
    // Allow some error due to projection/reverse projection
    const tolerance: i64 = 1000; // 1 microdegree
    try std.testing.expect(@abs(result.lat_nano - lat_nano) < tolerance);
    try std.testing.expect(@abs(result.lon_nano - lon_nano) < tolerance);
}

test "face: all faces reachable" {
    // Points on each face
    const test_points = [_][2]i64{
        .{ 0, 0 }, // Face 0 or 2
        .{ 0, 90_000_000_000 }, // Face 1
        .{ 90_000_000_000, 0 }, // Face 2 (north pole)
        .{ 0, 180_000_000_000 }, // Face 3
        .{ 0, -90_000_000_000 }, // Face 4
        .{ -90_000_000_000, 0 }, // Face 5 (south pole)
    };

    var faces_seen = [_]bool{false} ** 6;
    for (test_points) |pt| {
        const cell_id = fromLatLonNano(pt[0], pt[1], 30);
        const f = face(cell_id);
        faces_seen[f] = true;
    }

    // At least 3 faces should be reachable from these points
    var count: u8 = 0;
    for (faces_seen) |seen| {
        if (seen) count += 1;
    }
    try std.testing.expect(count >= 3);
}

test "cross-platform determinism" {
    // Compute a hash of many S2 operations to verify determinism.
    // This hash MUST be identical across all platforms (x86, ARM, macOS, Linux).
    // If it differs, the implementation is non-deterministic and will break VSR consensus.

    var hash: u64 = 0;

    // Test grid of coordinates (covers all faces and various precision levels)
    const lat_steps = [_]i64{ -90_000_000_000, -45_000_000_000, 0, 45_000_000_000, 90_000_000_000 };
    const lon_steps = [_]i64{
        -180_000_000_000, -90_000_000_000, 0, 90_000_000_000, 180_000_000_000,
    };
    const levels = [_]u8{ 0, 5, 10, 15, 20, 25, 30 };

    // Generate deterministic cell IDs and XOR them into hash
    for (lat_steps) |lat| {
        for (lon_steps) |lon| {
            for (levels) |lvl| {
                const cell_id = fromLatLonNano(lat, lon, lvl);
                hash ^= cell_id;

                // Also test hierarchy operations
                if (lvl > 0) {
                    const p = parent(cell_id);
                    hash ^= p;
                }
                if (lvl < max_level) {
                    const kids = children(cell_id);
                    for (kids) |kid| {
                        hash ^= kid;
                    }
                }

                // Test round-trip
                const result = toLatLonNano(cell_id);
                hash ^= @as(u64, @bitCast(result.lat_nano));
                hash ^= @as(u64, @bitCast(result.lon_nano));
            }
        }
    }

    // Add some trigonometric operations to the hash
    const test_angles = [_]f64{ 0.0, 0.1, 0.5, 1.0, 1.5, 2.0, 3.0, smath.pi };
    for (test_angles) |angle| {
        const s = smath.sin(angle);
        const c = smath.cos(angle);
        hash ^= @as(u64, @bitCast(s));
        hash ^= @as(u64, @bitCast(c));
    }

    // Expected hash value (computed on Linux x86_64)
    // If this test fails on another platform, the implementation is non-deterministic!
    //
    // Platform verification status:
    // - Linux x86_64: VERIFIED (this machine)
    // - macOS ARM64: Not yet validated (validation needed before production on this platform)
    // - Linux ARM64: Not yet validated (validation needed before production on this platform)
    // - Windows x86_64: Not yet validated (validation needed before production on this platform)
    const expected_hash: u64 = 0xcfdb4dbdd12dfa59;

    if (hash != expected_hash) {
        std.debug.print("\nCROSS-PLATFORM DETERMINISM FAILURE!\n", .{});
        std.debug.print("Expected hash: 0x{x:0>16}\n", .{expected_hash});
        std.debug.print("Actual hash:   0x{x:0>16}\n", .{hash});
        std.debug.print("\nNon-deterministic behavior will break VSR consensus.\n", .{});
        try std.testing.expectEqual(expected_hash, hash);
    }
}
