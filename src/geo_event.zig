//! GeoEvent - The core data structure for ArcherDB geospatial events.
//!
//! A 128-byte extern struct with explicit memory layout guarantees matching
//! TigerBeetle's data-oriented design principles.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");

/// Packed flags for GeoEvent status.
/// Uses explicit padding bits for forward compatibility.
pub const GeoEventFlags = packed struct(u16) {
    /// Event is part of a linked chain
    linked: bool = false,
    /// Event was imported with client-provided timestamp
    imported: bool = false,
    /// Entity is not moving
    stationary: bool = false,
    /// GPS accuracy below threshold
    low_accuracy: bool = false,
    /// Entity is offline/unreachable
    offline: bool = false,
    /// Entity has been deleted (for GDPR compliance)
    deleted: bool = false,
    /// Reserved, must be zero
    padding: u10 = 0,

    pub const none: GeoEventFlags = .{};
};

/// GeoEvent - 128-byte geospatial event record.
///
/// Fields ordered largest-to-smallest within each alignment class
/// (u128s first, then u64s, then u32s, then u16s) to avoid padding.
pub const GeoEvent = extern struct {
    /// Composite key: [S2 Cell ID (upper 64) | Timestamp (lower 64)]
    /// Enables space-major range queries via LSM tree
    id: u128,

    /// UUID identifying the moving entity (vehicle, device, person)
    entity_id: u128,

    /// UUID for trip/session/job correlation across events
    correlation_id: u128,

    /// Opaque application metadata (sidecar database FK)
    user_data: u128,

    /// Latitude in nanodegrees (10^-9 degrees)
    /// Valid range: -90_000_000_000 to +90_000_000_000
    lat_nano: i64,

    /// Longitude in nanodegrees (10^-9 degrees)
    /// Valid range: -180_000_000_000 to +180_000_000_000
    lon_nano: i64,

    /// Fleet/region grouping identifier
    group_id: u64,

    /// Event timestamp in nanoseconds since Unix epoch.
    /// Required by GrooveType for object tree ordering.
    /// Should match the lower 64 bits of the composite `id`.
    timestamp: u64,

    /// Altitude in millimeters above WGS84 ellipsoid
    altitude_mm: i32,

    /// Speed in millimeters per second
    velocity_mms: u32,

    /// Time-to-live in seconds (0 = never expires)
    ttl_seconds: u32,

    /// GPS accuracy radius in millimeters
    accuracy_mm: u32,

    /// Heading in centidegrees (0-36000)
    heading_cdeg: u16,

    /// Packed status flags
    flags: GeoEventFlags,

    /// Reserved for future use (must be zero)
    reserved: [12]u8,

    // === Constants ===

    /// Latitude bounds in nanodegrees (±90°)
    pub const lat_nano_min: i64 = -90_000_000_000;
    pub const lat_nano_max: i64 = 90_000_000_000;

    /// Longitude bounds in nanodegrees (±180°)
    pub const lon_nano_min: i64 = -180_000_000_000;
    pub const lon_nano_max: i64 = 180_000_000_000;

    /// Maximum heading value (360.00° in centidegrees)
    pub const heading_max: u16 = 36000;

    // === Helper Functions ===

    /// Pack S2 cell ID and timestamp into composite ID.
    /// Space-major ordering enables efficient spatial range queries.
    pub fn pack_id(s2_cell_id: u64, timestamp_ns: u64) u128 {
        return (@as(u128, s2_cell_id) << 64) | @as(u128, timestamp_ns);
    }

    /// Unpack composite ID into S2 cell ID and timestamp.
    pub fn unpack_id(id: u128) struct { s2_cell_id: u64, timestamp_ns: u64 } {
        return .{
            .s2_cell_id = @as(u64, @truncate(id >> 64)),
            .timestamp_ns = @as(u64, @truncate(id)),
        };
    }

    /// Convert floating-point latitude to nanodegrees.
    pub fn lat_from_float(lat_float: f64) i64 {
        return @as(i64, @intFromFloat(lat_float * 1_000_000_000.0));
    }

    /// Convert floating-point longitude to nanodegrees.
    pub fn lon_from_float(lon_float: f64) i64 {
        return @as(i64, @intFromFloat(lon_float * 1_000_000_000.0));
    }

    /// Convert nanodegrees latitude to floating-point.
    pub fn lat_to_float(lat_nano_val: i64) f64 {
        return @as(f64, @floatFromInt(lat_nano_val)) / 1_000_000_000.0;
    }

    /// Convert nanodegrees longitude to floating-point.
    pub fn lon_to_float(lon_nano_val: i64) f64 {
        return @as(f64, @floatFromInt(lon_nano_val)) / 1_000_000_000.0;
    }

    /// Validate coordinate bounds.
    pub fn validate_coordinates(lat_nano_val: i64, lon_nano_val: i64) bool {
        return lat_nano_val >= lat_nano_min and
            lat_nano_val <= lat_nano_max and
            lon_nano_val >= lon_nano_min and
            lon_nano_val <= lon_nano_max;
    }

    /// Create a zeroed GeoEvent.
    pub fn zero() GeoEvent {
        return std.mem.zeroes(GeoEvent);
    }
};

// === Comptime Assertions ===

comptime {
    // Size must be exactly 128 bytes
    assert(@sizeOf(GeoEvent) == 128);

    // Alignment must be 16 bytes (u128 boundary)
    assert(@alignOf(GeoEvent) == 16);

    // No implicit padding (efficient layout)
    assert(stdx.no_padding(GeoEvent));

    // Flags must be exactly u16
    assert(@sizeOf(GeoEventFlags) == @sizeOf(u16));
    assert(@bitSizeOf(GeoEventFlags) == @sizeOf(GeoEventFlags) * 8);
}

// === Tests ===

test "GeoEvent size and alignment" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(GeoEvent));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(GeoEvent));
    // no_padding verified in comptime block above
    comptime assert(stdx.no_padding(GeoEvent));
}

test "GeoEventFlags size" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(GeoEventFlags));
}

test "pack_id and unpack_id roundtrip" {
    const s2_cell: u64 = 0x89C2590000000000; // Example S2 cell ID
    const timestamp: u64 = 1704067200000000000; // 2024-01-01 00:00:00 UTC in ns

    const id = GeoEvent.pack_id(s2_cell, timestamp);
    const unpacked = GeoEvent.unpack_id(id);

    try std.testing.expectEqual(s2_cell, unpacked.s2_cell_id);
    try std.testing.expectEqual(timestamp, unpacked.timestamp_ns);
}

test "coordinate conversion roundtrip" {
    const lat_float: f64 = 37.7749; // San Francisco
    const lon_float: f64 = -122.4194;

    const lat_nano_val = GeoEvent.lat_from_float(lat_float);
    const lon_nano_val = GeoEvent.lon_from_float(lon_float);

    const lat_back = GeoEvent.lat_to_float(lat_nano_val);
    const lon_back = GeoEvent.lon_to_float(lon_nano_val);

    // Should be within 1 nanodegree (< 0.0001mm precision)
    try std.testing.expectApproxEqAbs(lat_float, lat_back, 1e-9);
    try std.testing.expectApproxEqAbs(lon_float, lon_back, 1e-9);
}

test "coordinate validation" {
    // Valid coordinates
    try std.testing.expect(GeoEvent.validate_coordinates(0, 0));
    try std.testing.expect(GeoEvent.validate_coordinates(
        GeoEvent.lat_nano_max,
        GeoEvent.lon_nano_max,
    ));
    try std.testing.expect(GeoEvent.validate_coordinates(
        GeoEvent.lat_nano_min,
        GeoEvent.lon_nano_min,
    ));

    // Invalid coordinates
    try std.testing.expect(!GeoEvent.validate_coordinates(
        GeoEvent.lat_nano_max + 1,
        0,
    ));
    try std.testing.expect(!GeoEvent.validate_coordinates(
        0,
        GeoEvent.lon_nano_min - 1,
    ));
}

test "field layout verification" {
    // Verify field offsets match expected layout (no padding)
    const offsets = .{
        .id = @offsetOf(GeoEvent, "id"),
        .entity_id = @offsetOf(GeoEvent, "entity_id"),
        .correlation_id = @offsetOf(GeoEvent, "correlation_id"),
        .user_data = @offsetOf(GeoEvent, "user_data"),
        .lat_nano = @offsetOf(GeoEvent, "lat_nano"),
        .lon_nano = @offsetOf(GeoEvent, "lon_nano"),
        .group_id = @offsetOf(GeoEvent, "group_id"),
        .timestamp = @offsetOf(GeoEvent, "timestamp"),
        .altitude_mm = @offsetOf(GeoEvent, "altitude_mm"),
        .velocity_mms = @offsetOf(GeoEvent, "velocity_mms"),
        .ttl_seconds = @offsetOf(GeoEvent, "ttl_seconds"),
        .accuracy_mm = @offsetOf(GeoEvent, "accuracy_mm"),
        .heading_cdeg = @offsetOf(GeoEvent, "heading_cdeg"),
        .flags = @offsetOf(GeoEvent, "flags"),
        .reserved = @offsetOf(GeoEvent, "reserved"),
    };

    // u128 fields (16 bytes each)
    try std.testing.expectEqual(@as(usize, 0), offsets.id);
    try std.testing.expectEqual(@as(usize, 16), offsets.entity_id);
    try std.testing.expectEqual(@as(usize, 32), offsets.correlation_id);
    try std.testing.expectEqual(@as(usize, 48), offsets.user_data);

    // u64/i64 fields (8 bytes each)
    try std.testing.expectEqual(@as(usize, 64), offsets.lat_nano);
    try std.testing.expectEqual(@as(usize, 72), offsets.lon_nano);
    try std.testing.expectEqual(@as(usize, 80), offsets.group_id);
    try std.testing.expectEqual(@as(usize, 88), offsets.timestamp);

    // u32/i32 fields (4 bytes each)
    try std.testing.expectEqual(@as(usize, 96), offsets.altitude_mm);
    try std.testing.expectEqual(@as(usize, 100), offsets.velocity_mms);
    try std.testing.expectEqual(@as(usize, 104), offsets.ttl_seconds);
    try std.testing.expectEqual(@as(usize, 108), offsets.accuracy_mm);

    // u16 fields (2 bytes each)
    try std.testing.expectEqual(@as(usize, 112), offsets.heading_cdeg);
    try std.testing.expectEqual(@as(usize, 114), offsets.flags);

    // Reserved (12 bytes)
    try std.testing.expectEqual(@as(usize, 116), offsets.reserved);

    // Verify total: 116 + 12 = 128
    try std.testing.expectEqual(@as(usize, 128), offsets.reserved + 12);
}
