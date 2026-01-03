// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! S2 Cap - A spherical cap (circular region on the sphere)
//!
//! A Cap represents a circular region on the unit sphere, defined by a center
//! point and an angular radius. This is the primary geometric primitive for
//! radius queries in ArcherDB.
//!
//! Key properties:
//! - Center: Unit vector (x, y, z) on the sphere
//! - Height: 1 - cos(radius), where radius is the angular radius
//!
//! A cap with height h contains all points where dot(center, point) >= 1 - h.
//! This is equivalent to angular distance <= arccos(1 - h) from center.

const std = @import("std");
const smath = @import("math.zig");
const cell_id = @import("cell_id.zig");

/// Earth's mean radius in meters (WGS84 approximation)
pub const earth_radius_meters: f64 = 6371008.8;

/// A spherical cap on the unit sphere.
pub const Cap = struct {
    /// Center point on unit sphere (must be normalized)
    center_x: f64,
    center_y: f64,
    center_z: f64,

    /// Height of the cap: 1 - cos(radius)
    /// Height = 0: empty cap
    /// Height = 2: full sphere
    height: f64,

    /// Create a cap from center point (lat/lon in radians) and radius in meters.
    pub fn fromLatLonRadius(lat_rad: f64, lon_rad: f64, radius_meters: f64) Cap {
        // Convert lat/lon to unit vector
        const cos_lat = smath.cos(lat_rad);
        const center_x = cos_lat * smath.cos(lon_rad);
        const center_y = cos_lat * smath.sin(lon_rad);
        const center_z = smath.sin(lat_rad);

        // Convert radius in meters to angular radius
        const angular_radius = radius_meters / earth_radius_meters;

        // Height = 1 - cos(angular_radius)
        // Use identity: 1 - cos(x) = 2*sin^2(x/2) for numerical stability
        const half_angle = angular_radius / 2.0;
        const sin_half = smath.sin(half_angle);
        const height = 2.0 * sin_half * sin_half;

        return Cap{
            .center_x = center_x,
            .center_y = center_y,
            .center_z = center_z,
            .height = height,
        };
    }

    /// Create a cap from center point (lat/lon in nanodegrees) and radius in meters.
    pub fn fromLatLonNanoRadius(lat_nano: i64, lon_nano: i64, radius_meters: f64) Cap {
        const lat_rad = @as(f64, @floatFromInt(lat_nano)) * (smath.pi / 180_000_000_000.0);
        const lon_rad = @as(f64, @floatFromInt(lon_nano)) * (smath.pi / 180_000_000_000.0);
        return fromLatLonRadius(lat_rad, lon_rad, radius_meters);
    }

    /// Create an empty cap (contains nothing).
    pub fn empty() Cap {
        return Cap{
            .center_x = 1.0,
            .center_y = 0.0,
            .center_z = 0.0,
            .height = 0.0,
        };
    }

    /// Create a full cap (contains everything).
    pub fn full() Cap {
        return Cap{
            .center_x = 1.0,
            .center_y = 0.0,
            .center_z = 0.0,
            .height = 2.0,
        };
    }

    /// Check if this cap is empty.
    pub fn isEmpty(self: Cap) bool {
        return self.height <= 0.0;
    }

    /// Check if this cap is the full sphere.
    pub fn isFull(self: Cap) bool {
        return self.height >= 2.0;
    }

    /// Check if a point (unit vector) is contained in this cap.
    pub fn containsPoint(self: Cap, x: f64, y: f64, z: f64) bool {
        // Point is in cap if dot(center, point) >= 1 - height
        const dot = self.center_x * x + self.center_y * y + self.center_z * z;
        return dot >= 1.0 - self.height;
    }

    /// Check if a point (lat/lon in radians) is contained in this cap.
    pub fn containsLatLon(self: Cap, lat_rad: f64, lon_rad: f64) bool {
        const cos_lat = smath.cos(lat_rad);
        const x = cos_lat * smath.cos(lon_rad);
        const y = cos_lat * smath.sin(lon_rad);
        const z = smath.sin(lat_rad);
        return self.containsPoint(x, y, z);
    }

    /// Check if a cell is fully contained in this cap.
    /// This checks all 4 corner vertices of the cell.
    pub fn containsCell(self: Cap, id: u64) bool {
        const vertices = getCellVertices(id);
        for (vertices) |v| {
            if (!self.containsPoint(v[0], v[1], v[2])) {
                return false;
            }
        }
        return true;
    }

    /// Check if a cell may intersect this cap.
    /// Returns false only if the cell is definitely outside the cap.
    pub fn mayIntersectCell(self: Cap, id: u64) bool {
        // Fast check: if center is in cell, definitely intersects
        const lvl = cell_id.level(id);
        const center_cell = cell_id.fromPoint(
            self.center_x,
            self.center_y,
            self.center_z,
            lvl,
        );
        if (center_cell == id) {
            return true;
        }

        // Check if any vertex of the cell is in the cap
        const vertices = getCellVertices(id);
        for (vertices) |v| {
            if (self.containsPoint(v[0], v[1], v[2])) {
                return true;
            }
        }

        // Check if the cap center is close enough to the cell center
        // This is an approximation - the cell might still intersect
        const cell_center = getCellCenter(id);
        const dot = self.center_x * cell_center[0] +
            self.center_y * cell_center[1] +
            self.center_z * cell_center[2];

        // The cell's angular radius is ~2^(-(level+1)) * pi for face diagonal
        // Conservative estimate: cell angular radius ≈ sqrt(2) * 2^(-level) rad
        const scale: u32 = @as(u32, 1) << @intCast(lvl);
        const cell_angular_radius = 1.5 * smath.pi / @as(f64, @floatFromInt(scale));

        // Cap angular radius from height: radius = arccos(1 - height)
        // For small heights: radius ≈ sqrt(2*height)
        const cap_radius_approx = smath.sqrt(2.0 * self.height);

        // Conservative intersection test
        const combined_radius = cap_radius_approx + cell_angular_radius;
        const min_dot = smath.cos(combined_radius);

        return dot >= min_dot;
    }

    /// Get the radius of the cap in meters.
    pub fn radiusMeters(self: Cap) f64 {
        // radius = arccos(1 - height), but use stable formula for small heights
        // arccos(1-h) = 2*arcsin(sqrt(h/2))
        if (self.height <= 0.0) return 0.0;
        if (self.height >= 2.0) return smath.pi * earth_radius_meters;

        const angular_radius = 2.0 * smath.asin(smath.sqrt(self.height / 2.0));
        return angular_radius * earth_radius_meters;
    }
};

/// Get the 4 corner vertices of a cell as unit vectors.
fn getCellVertices(id: u64) [4][3]f64 {
    const f = cell_id.face(id);
    const lvl = cell_id.level(id);
    const ij = getIj(id);

    const max_ij: f64 = @floatFromInt(@as(u32, 1) << @intCast(lvl));
    const ij_i: f64 = @floatFromInt(ij[0]);
    const ij_i1: f64 = @floatFromInt(ij[0] + 1);
    const ij_j: f64 = @floatFromInt(ij[1]);
    const ij_j1: f64 = @floatFromInt(ij[1] + 1);

    // Get corner ST coordinates
    const corners = [4][2]f64{
        .{ ij_i / max_ij, ij_j / max_ij },
        .{ ij_i1 / max_ij, ij_j / max_ij },
        .{ ij_i / max_ij, ij_j1 / max_ij },
        .{ ij_i1 / max_ij, ij_j1 / max_ij },
    };

    var vertices: [4][3]f64 = undefined;
    for (corners, 0..) |st, idx| {
        vertices[idx] = stFaceToXyz(f, st);
    }

    return vertices;
}

/// Get the center of a cell as a unit vector.
fn getCellCenter(id: u64) [3]f64 {
    const f = cell_id.face(id);
    const lvl = cell_id.level(id);
    const ij = getIj(id);

    const max_ij: f64 = @floatFromInt(@as(u32, 1) << @intCast(lvl));
    const st = [2]f64{
        (@as(f64, @floatFromInt(ij[0])) + 0.5) / max_ij,
        (@as(f64, @floatFromInt(ij[1])) + 0.5) / max_ij,
    };

    return stFaceToXyz(f, st);
}

/// Convert ST coordinates on a face to XYZ unit vector.
fn stFaceToXyz(f: u8, st: [2]f64) [3]f64 {
    // Convert ST to UV using inverse quadratic projection
    const uv = [2]f64{
        stToUv(st[0]),
        stToUv(st[1]),
    };

    // Convert UV to XYZ based on face
    return faceUvToXyz(f, uv);
}

fn stToUv(s: f64) f64 {
    if (s >= 0.5) {
        return (4.0 * s * s - 1.0) / 3.0;
    } else {
        return (1.0 - 4.0 * (1.0 - s) * (1.0 - s)) / 3.0;
    }
}

/// Face UV axes mapping (same as in cell_id.zig)
const face_uv_axes = [6][2]i8{
    .{ 1, 2 }, // Face 0: +X
    .{ 2, 0 }, // Face 1: +Y
    .{ 0, 1 }, // Face 2: +Z
    .{ 1, 2 }, // Face 3: -X
    .{ 2, 0 }, // Face 4: -Y
    .{ 0, 1 }, // Face 5: -Z
};

fn faceUvToXyz(f: u8, uv: [2]f64) [3]f64 {
    const axes = face_uv_axes[f];
    const u_axis: usize = @intCast(axes[0]);
    const v_axis: usize = @intCast(axes[1]);
    const face_axis: usize = f % 3;
    const face_sign: f64 = if (f < 3) 1.0 else -1.0;

    var xyz: [3]f64 = .{ 0, 0, 0 };
    xyz[face_axis] = face_sign;
    xyz[u_axis] = uv[0] * face_sign;
    xyz[v_axis] = uv[1] * face_sign;

    // Normalize to unit sphere
    const norm = smath.sqrt(xyz[0] * xyz[0] + xyz[1] * xyz[1] + xyz[2] * xyz[2]);
    return .{ xyz[0] / norm, xyz[1] / norm, xyz[2] / norm };
}

/// Extract IJ coordinates from cell ID (reimplemented to avoid circular dep)
fn getIj(id: u64) [2]u32 {
    const lvl = cell_id.level(id);
    const pos_shift: u6 = @intCast((cell_id.max_level - lvl) * 2 + 1);
    const pos = (id >> pos_shift) & ((@as(u64, 1) << @intCast(lvl * 2)) - 1);

    return posToIj(pos, lvl);
}

/// Hilbert lookup tables (same as cell_id.zig)
const hilbert_lookup = [4][4]u8{
    .{ 0, 1, 3, 2 },
    .{ 0, 3, 1, 2 },
    .{ 2, 3, 1, 0 },
    .{ 2, 1, 3, 0 },
};

const hilbert_orientation = [4][4]u8{
    .{ 0, 0, 3, 3 },
    .{ 1, 1, 2, 2 },
    .{ 2, 2, 1, 1 },
    .{ 3, 3, 0, 0 },
};

fn posToIj(pos: u64, lvl: u8) [2]u32 {
    var i: u32 = 0;
    var j: u32 = 0;
    var orientation: u8 = 0;

    var l: u8 = 0;
    while (l < lvl) : (l += 1) {
        const shift: u6 = @intCast((lvl - 1 - l) * 2);
        const hilbert_pos: u8 = @intCast((pos >> shift) & 3);

        var i_bit: u8 = 0;
        var j_bit: u8 = 0;
        for (hilbert_lookup[orientation], 0..) |hp, idx| {
            if (hp == hilbert_pos) {
                i_bit = @intCast(idx >> 1);
                j_bit = @intCast(idx & 1);
                break;
            }
        }

        i = (i << 1) | i_bit;
        j = (j << 1) | j_bit;

        const lookup_idx = (i_bit << 1) | j_bit;
        orientation = hilbert_orientation[orientation][lookup_idx];
    }

    return .{ i, j };
}

// =============================================================================
// Tests
// =============================================================================

test "Cap: empty and full" {
    const e = Cap.empty();
    try std.testing.expect(e.isEmpty());
    try std.testing.expect(!e.isFull());

    const f = Cap.full();
    try std.testing.expect(!f.isEmpty());
    try std.testing.expect(f.isFull());
}

test "Cap: contains point" {
    // Cap centered at origin with 1000km radius
    const cap = Cap.fromLatLonNanoRadius(0, 0, 1_000_000.0);

    // Origin should be in cap
    try std.testing.expect(cap.containsLatLon(0.0, 0.0));

    // Point 500km away should be in cap (roughly 4.5 degrees at equator)
    const lat_500km = 4.5 * smath.pi / 180.0;
    try std.testing.expect(cap.containsLatLon(lat_500km, 0.0));

    // Point 2000km away should NOT be in cap
    const lat_2000km = 18.0 * smath.pi / 180.0;
    try std.testing.expect(!cap.containsLatLon(lat_2000km, 0.0));
}

test "Cap: radius round-trip" {
    const radius_m = 100_000.0; // 100km
    const cap = Cap.fromLatLonNanoRadius(37_774900000, -122_419400000, radius_m);

    // Radius should round-trip approximately
    const result_radius = cap.radiusMeters();
    const tolerance = 1.0; // 1 meter tolerance
    try std.testing.expect(@abs(result_radius - radius_m) < tolerance);
}

test "Cap: contains cell" {
    // Large cap (1000km radius at equator)
    const cap = Cap.fromLatLonNanoRadius(0, 0, 1_000_000.0);

    // Cell at origin should be contained
    const origin_cell = cell_id.fromLatLonNano(0, 0, 10);
    try std.testing.expect(cap.mayIntersectCell(origin_cell));

    // Cell at antipodal point should NOT be contained
    const antipodal_cell = cell_id.fromLatLonNano(0, 180_000_000_000, 10);
    try std.testing.expect(!cap.mayIntersectCell(antipodal_cell));
}

test "Cap: polar cap" {
    // Cap centered at north pole with 1000km radius
    const cap = Cap.fromLatLonNanoRadius(90_000_000_000, 0, 1_000_000.0);

    // North pole should be in cap
    try std.testing.expect(cap.containsLatLon(smath.pi / 2.0, 0.0));

    // Point 500km from pole (lat ~85.5) should be in cap
    const lat_near_pole = 85.5 * smath.pi / 180.0;
    try std.testing.expect(cap.containsLatLon(lat_near_pole, 0.0));

    // Equator should NOT be in cap
    try std.testing.expect(!cap.containsLatLon(0.0, 0.0));
}
