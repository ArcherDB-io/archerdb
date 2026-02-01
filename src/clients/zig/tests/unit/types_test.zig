// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Unit tests for ArcherDB Zig SDK types

const std = @import("std");
const types = @import("../../types.zig");

// ============================================================================
// Coordinate Conversion Tests
// ============================================================================

test "degreesToNano: San Francisco coordinates" {
    const lat = 37.7749;
    const lon = -122.4194;

    const lat_nano = types.degreesToNano(lat);
    const lon_nano = types.degreesToNano(lon);

    try std.testing.expectEqual(@as(i64, 37774900000), lat_nano);
    try std.testing.expectEqual(@as(i64, -122419400000), lon_nano);
}

test "degreesToNano: boundary values" {
    // North pole
    try std.testing.expectEqual(@as(i64, 90_000_000_000), types.degreesToNano(90.0));
    // South pole
    try std.testing.expectEqual(@as(i64, -90_000_000_000), types.degreesToNano(-90.0));
    // Antimeridian east
    try std.testing.expectEqual(@as(i64, 180_000_000_000), types.degreesToNano(180.0));
    // Antimeridian west
    try std.testing.expectEqual(@as(i64, -180_000_000_000), types.degreesToNano(-180.0));
    // Null island
    try std.testing.expectEqual(@as(i64, 0), types.degreesToNano(0.0));
}

test "nanoToDegrees: round trip" {
    const original = 37.7749;
    const nano = types.degreesToNano(original);
    const back = types.nanoToDegrees(nano);

    try std.testing.expectApproxEqAbs(original, back, 0.0001);
}

test "metersToMm: altitude conversion" {
    try std.testing.expectEqual(@as(i32, 100500), types.metersToMm(100.5));
    try std.testing.expectEqual(@as(i32, 0), types.metersToMm(0.0));
    try std.testing.expectEqual(@as(i32, -10000), types.metersToMm(-10.0));
}

test "mmToMeters: round trip" {
    const original = 100.5;
    const mm = types.metersToMm(original);
    const back = types.mmToMeters(mm);

    try std.testing.expectApproxEqAbs(original, back, 0.001);
}

test "mpsToMms: velocity conversion" {
    try std.testing.expectEqual(@as(u32, 15000), types.mpsToMms(15.0));
    try std.testing.expectEqual(@as(u32, 0), types.mpsToMms(0.0));
    try std.testing.expectEqual(@as(u32, 1000), types.mpsToMms(1.0));
}

test "mmsToMps: round trip" {
    const original = 15.5;
    const mms = types.mpsToMms(original);
    const back = types.mmsToMps(mms);

    try std.testing.expectApproxEqAbs(original, back, 0.001);
}

test "degreesToCdeg: heading conversion" {
    try std.testing.expectEqual(@as(u16, 0), types.degreesToCdeg(0.0)); // North
    try std.testing.expectEqual(@as(u16, 9000), types.degreesToCdeg(90.0)); // East
    try std.testing.expectEqual(@as(u16, 18000), types.degreesToCdeg(180.0)); // South
    try std.testing.expectEqual(@as(u16, 27000), types.degreesToCdeg(270.0)); // West
}

test "degreesToCdeg: wrapping" {
    try std.testing.expectEqual(@as(u16, 0), types.degreesToCdeg(360.0));
    try std.testing.expectEqual(@as(u16, 4500), types.degreesToCdeg(405.0)); // 405 mod 360 = 45
}

test "cdegToDegrees: round trip" {
    const original = 135.0;
    const cdeg = types.degreesToCdeg(original);
    const back = types.cdegToDegrees(cdeg);

    try std.testing.expectApproxEqAbs(original, back, 0.01);
}

// ============================================================================
// Validation Tests
// ============================================================================

test "isValidLatitude: valid values" {
    try std.testing.expect(types.isValidLatitude(0));
    try std.testing.expect(types.isValidLatitude(types.MAX_LAT_NANO));
    try std.testing.expect(types.isValidLatitude(types.MIN_LAT_NANO));
    try std.testing.expect(types.isValidLatitude(types.degreesToNano(37.7749)));
}

test "isValidLatitude: invalid values" {
    try std.testing.expect(!types.isValidLatitude(types.MAX_LAT_NANO + 1));
    try std.testing.expect(!types.isValidLatitude(types.MIN_LAT_NANO - 1));
    try std.testing.expect(!types.isValidLatitude(types.degreesToNano(91.0)));
    try std.testing.expect(!types.isValidLatitude(types.degreesToNano(-91.0)));
}

test "isValidLongitude: valid values" {
    try std.testing.expect(types.isValidLongitude(0));
    try std.testing.expect(types.isValidLongitude(types.MAX_LON_NANO));
    try std.testing.expect(types.isValidLongitude(types.MIN_LON_NANO));
    try std.testing.expect(types.isValidLongitude(types.degreesToNano(-122.4194)));
}

test "isValidLongitude: invalid values" {
    try std.testing.expect(!types.isValidLongitude(types.MAX_LON_NANO + 1));
    try std.testing.expect(!types.isValidLongitude(types.MIN_LON_NANO - 1));
    try std.testing.expect(!types.isValidLongitude(types.degreesToNano(181.0)));
    try std.testing.expect(!types.isValidLongitude(types.degreesToNano(-181.0)));
}

test "isValidHeading: valid values" {
    try std.testing.expect(types.isValidHeading(0));
    try std.testing.expect(types.isValidHeading(types.MAX_HEADING_CDEG));
    try std.testing.expect(types.isValidHeading(9000)); // 90 degrees
}

test "isValidHeading: invalid values" {
    try std.testing.expect(!types.isValidHeading(types.MAX_HEADING_CDEG + 1));
}

// ============================================================================
// GeoEvent Validation Tests
// ============================================================================

test "validateGeoEvent: valid event" {
    const event = types.GeoEvent{
        .entity_id = 12345,
        .lat_nano = types.degreesToNano(37.7749),
        .lon_nano = types.degreesToNano(-122.4194),
        .group_id = 1,
    };

    try std.testing.expectEqual(@as(?types.InsertResultCode, null), types.validateGeoEvent(event));
}

test "validateGeoEvent: zero entity_id" {
    const event = types.GeoEvent{
        .entity_id = 0,
        .lat_nano = 0,
        .lon_nano = 0,
    };

    try std.testing.expectEqual(types.InsertResultCode.entity_id_must_not_be_zero, types.validateGeoEvent(event).?);
}

test "validateGeoEvent: latitude out of range" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = types.degreesToNano(91.0), // Invalid
        .lon_nano = 0,
    };

    try std.testing.expectEqual(types.InsertResultCode.lat_out_of_range, types.validateGeoEvent(event).?);
}

test "validateGeoEvent: longitude out of range" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = 0,
        .lon_nano = types.degreesToNano(181.0), // Invalid
    };

    try std.testing.expectEqual(types.InsertResultCode.lon_out_of_range, types.validateGeoEvent(event).?);
}

test "validateGeoEvent: heading out of range" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = 0,
        .lon_nano = 0,
        .heading_cdeg = types.MAX_HEADING_CDEG + 1, // Invalid
    };

    try std.testing.expectEqual(types.InsertResultCode.heading_out_of_range, types.validateGeoEvent(event).?);
}

// ============================================================================
// GeoEvent Struct Tests
// ============================================================================

test "GeoEvent: default values" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = 0,
        .lon_nano = 0,
    };

    try std.testing.expectEqual(@as(u128, 0), event.id);
    try std.testing.expectEqual(@as(u128, 0), event.correlation_id);
    try std.testing.expectEqual(@as(u128, 0), event.user_data);
    try std.testing.expectEqual(@as(u64, 0), event.group_id);
    try std.testing.expectEqual(@as(u64, 0), event.timestamp);
    try std.testing.expectEqual(@as(i32, 0), event.altitude_mm);
    try std.testing.expectEqual(@as(u32, 0), event.velocity_mms);
    try std.testing.expectEqual(@as(u32, 0), event.ttl_seconds);
    try std.testing.expectEqual(@as(u32, 0), event.accuracy_mm);
    try std.testing.expectEqual(@as(u16, 0), event.heading_cdeg);
    try std.testing.expectEqual(@as(u16, 0), event.flags);
}

test "GeoEvent: all fields populated" {
    const event = types.GeoEvent{
        .entity_id = 0x12345678_12345678_12345678_12345678,
        .correlation_id = 11111,
        .user_data = 42,
        .lat_nano = types.degreesToNano(37.7749),
        .lon_nano = types.degreesToNano(-122.4194),
        .group_id = 1001,
        .timestamp = 1234567890,
        .altitude_mm = types.metersToMm(100.5),
        .velocity_mms = types.mpsToMms(15.0),
        .ttl_seconds = 3600,
        .accuracy_mm = types.metersToMmUnsigned(5.0),
        .heading_cdeg = types.degreesToCdeg(90.0),
        .flags = 4,
    };

    try std.testing.expectEqual(@as(u128, 0x12345678_12345678_12345678_12345678), event.entity_id);
    try std.testing.expectEqual(@as(u64, 1001), event.group_id);
    try std.testing.expectEqual(@as(u32, 3600), event.ttl_seconds);
    try std.testing.expectEqual(@as(u16, 9000), event.heading_cdeg);

    // Verify validation passes
    try std.testing.expectEqual(@as(?types.InsertResultCode, null), types.validateGeoEvent(event));
}

// ============================================================================
// Query Filter Tests
// ============================================================================

test "QueryRadiusFilter: default values" {
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = 0,
        .center_lon_nano = 0,
        .radius_mm = 1000000,
    };

    try std.testing.expectEqual(@as(u32, 1000), filter.limit);
    try std.testing.expectEqual(@as(u64, 0), filter.timestamp_min);
    try std.testing.expectEqual(@as(u64, 0), filter.timestamp_max);
    try std.testing.expectEqual(@as(u64, 0), filter.group_id);
    try std.testing.expectEqual(@as(u64, 0), filter.cursor);
}

test "QueryLatestFilter: default values" {
    const filter = types.QueryLatestFilter{};

    try std.testing.expectEqual(@as(u32, 1000), filter.limit);
    try std.testing.expectEqual(@as(u64, 0), filter.group_id);
    try std.testing.expectEqual(@as(u64, 0), filter.cursor);
}

// ============================================================================
// Response Type Tests
// ============================================================================

test "InsertResultCode: enum values" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(types.InsertResultCode.ok));
    try std.testing.expectEqual(@as(u16, 7), @intFromEnum(types.InsertResultCode.entity_id_must_not_be_zero));
    try std.testing.expectEqual(@as(u16, 9), @intFromEnum(types.InsertResultCode.lat_out_of_range));
    try std.testing.expectEqual(@as(u16, 10), @intFromEnum(types.InsertResultCode.lon_out_of_range));
}

test "DeleteResult: default values" {
    const result = types.DeleteResult{};

    try std.testing.expectEqual(@as(u32, 0), result.deleted_count);
    try std.testing.expectEqual(@as(u32, 0), result.not_found_count);
}

// ============================================================================
// Constant Tests
// ============================================================================

test "constants: coordinate ranges" {
    try std.testing.expectEqual(@as(i64, 90_000_000_000), types.MAX_LAT_NANO);
    try std.testing.expectEqual(@as(i64, -90_000_000_000), types.MIN_LAT_NANO);
    try std.testing.expectEqual(@as(i64, 180_000_000_000), types.MAX_LON_NANO);
    try std.testing.expectEqual(@as(i64, -180_000_000_000), types.MIN_LON_NANO);
}

test "constants: limits" {
    try std.testing.expectEqual(@as(usize, 10_000), types.BATCH_SIZE_MAX);
    try std.testing.expectEqual(@as(u32, 81_000), types.QUERY_LIMIT_MAX);
    try std.testing.expectEqual(@as(usize, 10_000), types.POLYGON_VERTICES_MAX);
    try std.testing.expectEqual(@as(usize, 100), types.POLYGON_HOLES_MAX);
}

test "constants: conversion factors" {
    try std.testing.expectEqual(@as(i64, 1_000_000_000), types.NANO_PER_DEGREE);
    try std.testing.expectEqual(@as(i32, 1_000), types.MM_PER_METER);
    try std.testing.expectEqual(@as(u16, 100), types.CDEG_PER_DEGREE);
}
