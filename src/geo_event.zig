// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GeoEvent - The core data structure for ArcherDB geospatial events.
//!
//! A 128-byte extern struct with explicit memory layout guarantees matching
//! ArcherDB's data-oriented design principles (inherited from ArcherDB).

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const ttl = @import("ttl.zig");

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

    // === TTL Methods ===

    /// Check if this event is expired given the current time.
    ///
    /// Per ttl-retention/spec.md:
    /// - ttl_seconds = 0 means never expires
    /// - Uses timestamp field (lower 64 bits of id) for expiration calculation
    ///
    /// Arguments:
    /// - current_time_ns: Current timestamp in nanoseconds (consensus or wall clock)
    ///
    /// Returns: true if event has expired
    pub fn is_expired(self: *const GeoEvent, current_time_ns: u64) bool {
        return ttl.is_expired(self.timestamp, self.ttl_seconds, current_time_ns).expired;
    }

    /// Check if this event should be copied forward during compaction.
    ///
    /// Per ttl-retention/spec.md, during compaction:
    /// 1. If expired: Skip (don't copy to new table)
    /// 2. If deleted (tombstone): May need to keep for resurrection prevention
    /// 3. Otherwise: Copy forward
    ///
    /// Arguments:
    /// - current_time_ns: Current timestamp for TTL calculation
    /// - is_final_level: True if compacting to the final LSM level
    ///
    /// Returns: true if event should be copied forward
    pub fn should_copy_forward(
        self: *const GeoEvent,
        current_time_ns: u64,
        is_final_level: bool,
    ) bool {
        // Expired events are never copied forward.
        if (self.is_expired(current_time_ns)) {
            return false;
        }

        // Tombstones (deleted entities) need special handling.
        // Per spec: tombstones are kept unless at final level.
        if (self.flags.deleted) {
            // At final level, tombstones can be dropped.
            // Otherwise, keep them to prevent resurrection on restore.
            return !is_final_level;
        }

        // Not expired, not tombstone - copy forward.
        return true;
    }

    /// Get expiration timestamp for this event.
    ///
    /// Returns:
    /// - maxInt(u64) if event never expires (ttl_seconds = 0)
    /// - Calculated expiration timestamp otherwise
    pub fn expiration_time_ns(self: *const GeoEvent) u64 {
        return ttl.is_expired(self.timestamp, self.ttl_seconds, 0).expiration_time_ns;
    }

    /// Get remaining TTL in seconds, if applicable.
    ///
    /// Returns:
    /// - null if event never expires
    /// - 0 if event is already expired
    /// - remaining seconds otherwise
    pub fn remaining_ttl(self: *const GeoEvent, current_time_ns: u64) ?u64 {
        return ttl.remaining_ttl_seconds(self.timestamp, self.ttl_seconds, current_time_ns);
    }

    // === Tombstone Methods ===

    /// Check if this event is a tombstone (deleted entity marker).
    pub fn is_tombstone(self: *const GeoEvent) bool {
        return self.flags.deleted;
    }

    /// Create a tombstone GeoEvent for this entity.
    ///
    /// Tombstones are used for:
    /// - GDPR entity deletion (explicit user request)
    /// - TTL expiration (to prevent resurrection on restore)
    ///
    /// Per ttl-retention/spec.md:
    /// - Tombstones have flags.deleted=true
    /// - Tombstones have ttl_seconds=0 (never expire on their own)
    /// - Tombstones preserve entity_id for resurrection prevention
    ///
    /// Arguments:
    /// - current_time_ns: Current timestamp to use for the tombstone
    ///
    /// Returns: A new GeoEvent that acts as a tombstone
    pub fn create_tombstone(self: *const GeoEvent, current_time_ns: u64) GeoEvent {
        var tombstone = GeoEvent.zero();

        // Preserve entity identity.
        tombstone.entity_id = self.entity_id;
        tombstone.group_id = self.group_id;

        // Create new composite ID with current timestamp.
        // Use the original S2 cell ID from the entity's location.
        const unpacked = GeoEvent.unpack_id(self.id);
        tombstone.id = GeoEvent.pack_id(unpacked.s2_cell_id, current_time_ns);
        tombstone.timestamp = current_time_ns;

        // Preserve location for potential audit/logging.
        tombstone.lat_nano = self.lat_nano;
        tombstone.lon_nano = self.lon_nano;

        // Mark as tombstone - CRITICAL.
        tombstone.flags.deleted = true;

        // Tombstones never expire (remain until final compaction level).
        tombstone.ttl_seconds = 0;

        return tombstone;
    }

    /// Create a minimal tombstone GeoEvent from just entity_id and group_id.
    ///
    /// This is used when we don't have the full event data, only the entity info
    /// from the RAM index entry.
    ///
    /// Arguments:
    /// - entity_id: The UUID of the entity being deleted
    /// - group_id: The fleet/region grouping identifier
    /// - current_time_ns: Current timestamp to use for the tombstone
    ///
    /// Returns: A minimal tombstone GeoEvent
    pub fn create_minimal_tombstone(
        entity_id: u128,
        group_id: u64,
        current_time_ns: u64,
    ) GeoEvent {
        var tombstone = GeoEvent.zero();

        tombstone.entity_id = entity_id;
        tombstone.group_id = group_id;

        // For minimal tombstone, use timestamp in both id fields.
        // S2 cell ID is 0 since we don't know the location.
        tombstone.id = GeoEvent.pack_id(0, current_time_ns);
        tombstone.timestamp = current_time_ns;

        // Mark as tombstone.
        tombstone.flags.deleted = true;
        tombstone.ttl_seconds = 0;

        return tombstone;
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

test "GeoEvent: is_expired with ttl_seconds = 0 never expires" {
    var event = GeoEvent.zero();
    event.timestamp = 1 * ttl.ns_per_second;
    event.ttl_seconds = 0; // Never expires.

    // Should not be expired even at far future time.
    try std.testing.expect(!event.is_expired(std.math.maxInt(u64) - 1));
}

test "GeoEvent: is_expired returns true for expired event" {
    var event = GeoEvent.zero();
    event.timestamp = 5 * ttl.ns_per_second; // Event at 5 seconds.
    event.ttl_seconds = 10; // Expires at 15 seconds.

    // Not expired at 10 seconds.
    try std.testing.expect(!event.is_expired(10 * ttl.ns_per_second));

    // Expired at 20 seconds.
    try std.testing.expect(event.is_expired(20 * ttl.ns_per_second));
}

test "GeoEvent: should_copy_forward with expired event" {
    var event = GeoEvent.zero();
    event.timestamp = 1 * ttl.ns_per_second;
    event.ttl_seconds = 10; // Expires at 11 seconds.

    // At 20 seconds, event is expired - should not copy.
    try std.testing.expect(!event.should_copy_forward(20 * ttl.ns_per_second, false));
    try std.testing.expect(!event.should_copy_forward(20 * ttl.ns_per_second, true));
}

test "GeoEvent: should_copy_forward with tombstone" {
    var event = GeoEvent.zero();
    event.timestamp = 1 * ttl.ns_per_second;
    event.ttl_seconds = 0; // Never expires.
    event.flags.deleted = true; // Tombstone.

    // Not at final level - keep tombstone.
    try std.testing.expect(event.should_copy_forward(0, false));

    // At final level - drop tombstone.
    try std.testing.expect(!event.should_copy_forward(0, true));
}

test "GeoEvent: should_copy_forward with normal event" {
    var event = GeoEvent.zero();
    event.timestamp = 1 * ttl.ns_per_second;
    event.ttl_seconds = 0; // Never expires.
    event.flags.deleted = false; // Not tombstone.

    // Normal event should always be copied.
    try std.testing.expect(event.should_copy_forward(0, false));
    try std.testing.expect(event.should_copy_forward(0, true));
}

test "GeoEvent: remaining_ttl calculation" {
    var event = GeoEvent.zero();
    event.timestamp = 10 * ttl.ns_per_second;
    event.ttl_seconds = 100; // Expires at 110 seconds.

    // At 50 seconds, 60 seconds remaining.
    try std.testing.expectEqual(@as(?u64, 60), event.remaining_ttl(50 * ttl.ns_per_second));

    // Event with ttl_seconds = 0 returns null.
    event.ttl_seconds = 0;
    try std.testing.expectEqual(@as(?u64, null), event.remaining_ttl(50 * ttl.ns_per_second));
}

test "GeoEvent: is_tombstone" {
    var event = GeoEvent.zero();
    try std.testing.expect(!event.is_tombstone());

    event.flags.deleted = true;
    try std.testing.expect(event.is_tombstone());
}

test "GeoEvent: create_tombstone preserves entity identity" {
    const s2_cell: u64 = 0x89C2590000000000;
    const original_ts: u64 = 1000 * ttl.ns_per_second;
    const tombstone_ts: u64 = 2000 * ttl.ns_per_second;

    var event = GeoEvent.zero();
    event.id = GeoEvent.pack_id(s2_cell, original_ts);
    event.entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    event.timestamp = original_ts;
    event.group_id = 42;
    event.lat_nano = GeoEvent.lat_from_float(37.7749);
    event.lon_nano = GeoEvent.lon_from_float(-122.4194);
    event.ttl_seconds = 3600;
    event.flags.linked = true;

    const tombstone = event.create_tombstone(tombstone_ts);

    // Entity identity preserved.
    try std.testing.expectEqual(event.entity_id, tombstone.entity_id);
    try std.testing.expectEqual(event.group_id, tombstone.group_id);

    // Location preserved.
    try std.testing.expectEqual(event.lat_nano, tombstone.lat_nano);
    try std.testing.expectEqual(event.lon_nano, tombstone.lon_nano);

    // Tombstone has new timestamp.
    try std.testing.expectEqual(tombstone_ts, tombstone.timestamp);
    const unpacked = GeoEvent.unpack_id(tombstone.id);
    try std.testing.expectEqual(tombstone_ts, unpacked.timestamp_ns);
    try std.testing.expectEqual(s2_cell, unpacked.s2_cell_id);

    // Tombstone flags set correctly.
    try std.testing.expect(tombstone.is_tombstone());
    try std.testing.expectEqual(@as(u32, 0), tombstone.ttl_seconds);

    // Original event's other flags NOT copied.
    try std.testing.expect(!tombstone.flags.linked);
}

test "GeoEvent: create_minimal_tombstone" {
    const entity_id: u128 = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;
    const group_id: u64 = 100;
    const current_ts: u64 = 5000 * ttl.ns_per_second;

    const tombstone = GeoEvent.create_minimal_tombstone(entity_id, group_id, current_ts);

    // Entity identity set.
    try std.testing.expectEqual(entity_id, tombstone.entity_id);
    try std.testing.expectEqual(group_id, tombstone.group_id);

    // Timestamp set.
    try std.testing.expectEqual(current_ts, tombstone.timestamp);
    const unpacked = GeoEvent.unpack_id(tombstone.id);
    try std.testing.expectEqual(current_ts, unpacked.timestamp_ns);
    try std.testing.expectEqual(@as(u64, 0), unpacked.s2_cell_id);

    // Tombstone flags.
    try std.testing.expect(tombstone.is_tombstone());
    try std.testing.expectEqual(@as(u32, 0), tombstone.ttl_seconds);

    // Location is zero (minimal tombstone).
    try std.testing.expectEqual(@as(i64, 0), tombstone.lat_nano);
    try std.testing.expectEqual(@as(i64, 0), tombstone.lon_nano);
}
