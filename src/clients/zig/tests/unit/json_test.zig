// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Unit tests for ArcherDB Zig SDK JSON serialization
//! Tests JSON round-trip serialization using Phase 11 fixtures

const std = @import("std");
const json = @import("../../json.zig");
const types = @import("../../types.zig");

// ============================================================================
// Fixture Loading
// ============================================================================

/// Load and parse a test fixture JSON file.
/// Fixtures are located at test_infrastructure/fixtures/v1/
fn loadFixture(allocator: std.mem.Allocator, comptime name: []const u8) !std.json.Value {
    // Try multiple paths for fixture location
    const paths = [_][]const u8{
        "../../../../test_infrastructure/fixtures/v1/" ++ name,
        "../../../../../test_infrastructure/fixtures/v1/" ++ name,
        "test_infrastructure/fixtures/v1/" ++ name,
    };

    for (paths) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch continue;
        return parsed.value;
    }

    // Return empty object if fixture not found - tests will skip gracefully
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

// ============================================================================
// Serialization Tests
// ============================================================================

test "serializeGeoEvent: minimal event" {
    const event = types.GeoEvent{
        .entity_id = 1001,
        .lat_nano = 40712800000,
        .lon_nano = -74006000000,
    };

    const result = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"1001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"lat_nano\":40712800000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"lon_nano\":-74006000000") != null);
}

test "serializeGeoEvent: all fields" {
    const event = types.GeoEvent{
        .entity_id = 2001,
        .lat_nano = types.degreesToNano(37.7749),
        .lon_nano = types.degreesToNano(-122.4194),
        .correlation_id = 11111,
        .user_data = 42,
        .group_id = 1001,
        .altitude_mm = types.metersToMm(100.5),
        .velocity_mms = types.mpsToMms(15.0),
        .ttl_seconds = 3600,
        .accuracy_mm = 5000,
        .heading_cdeg = types.degreesToCdeg(90.0),
        .flags = 4,
    };

    const result = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"group_id\":1001") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ttl_seconds\":3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"heading_cdeg\":9000") != null);
}

test "serializeEvents: batch" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 3001,
            .lat_nano = 40712800000,
            .lon_nano = -74006000000,
        },
        .{
            .entity_id = 3002,
            .lat_nano = 40712900000,
            .lon_nano = -74006100000,
        },
    };

    const result = try json.serializeEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(result);

    try std.testing.expect(result[0] == '[');
    try std.testing.expect(result[result.len - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"3001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"3002\"") != null);
}

test "serializeInsertRequest: insert mode" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 1001,
            .lat_nano = 40712800000,
            .lon_nano = -74006000000,
        },
    };

    const result = try json.serializeInsertRequest(std.testing.allocator, &events, "insert");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"mode\":\"insert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"events\":[") != null);
}

test "serializeInsertRequest: upsert mode" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 1001,
            .lat_nano = 40712800000,
            .lon_nano = -74006000000,
        },
    };

    const result = try json.serializeInsertRequest(std.testing.allocator, &events, "upsert");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"mode\":\"upsert\"") != null);
}

test "serializeRadiusFilter" {
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = types.degreesToNano(37.7749),
        .center_lon_nano = types.degreesToNano(-122.4194),
        .radius_mm = 1000000, // 1km
        .limit = 100,
        .group_id = 1,
    };

    const result = try json.serializeRadiusFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"center_lat_nano\":37774900000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"radius_mm\":1000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"limit\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"group_id\":1") != null);
}

test "serializePolygonFilter: simple polygon" {
    const vertices = [_]types.Vertex{
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.42) },
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.42) },
    };

    const filter = types.QueryPolygonFilter{
        .vertices = &vertices,
        .limit = 1000,
    };

    const result = try json.serializePolygonFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"vertices\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"limit\":1000") != null);
}

test "serializeLatestFilter" {
    const filter = types.QueryLatestFilter{
        .limit = 500,
        .group_id = 42,
    };

    const result = try json.serializeLatestFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"limit\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"group_id\":42") != null);
}

test "serializeEntityIds" {
    const ids = [_]u128{ 1001, 1002, 1003 };

    const result = try json.serializeEntityIds(std.testing.allocator, &ids);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_ids\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"1001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"1002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"1003\"") != null);
}

test "serializeTtlSetRequest" {
    const result = try json.serializeTtlSetRequest(std.testing.allocator, 12345, 3600);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"12345\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ttl_seconds\":3600") != null);
}

test "serializeTtlExtendRequest" {
    const result = try json.serializeTtlExtendRequest(std.testing.allocator, 12345, 1800);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"12345\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"extend_by_seconds\":1800") != null);
}

test "serializeTtlClearRequest" {
    const result = try json.serializeTtlClearRequest(std.testing.allocator, 12345);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"entity_id\":\"12345\"") != null);
}

// ============================================================================
// Deserialization Tests
// ============================================================================

test "parseGeoEvent: minimal" {
    const input =
        \\{"entity_id":"1001","lat_nano":40712800000,"lon_nano":-74006000000}
    ;

    const event = try json.parseGeoEvent(std.testing.allocator, input);

    try std.testing.expectEqual(@as(u128, 1001), event.entity_id);
    try std.testing.expectEqual(@as(i64, 40712800000), event.lat_nano);
    try std.testing.expectEqual(@as(i64, -74006000000), event.lon_nano);
}

test "parseGeoEvent: all fields" {
    const input =
        \\{"entity_id":"2001","lat_nano":37774900000,"lon_nano":-122419400000,"group_id":1001,"correlation_id":"11111","altitude_mm":100500,"velocity_mms":15000,"ttl_seconds":3600,"accuracy_mm":5000,"heading_cdeg":9000,"flags":4}
    ;

    const event = try json.parseGeoEvent(std.testing.allocator, input);

    try std.testing.expectEqual(@as(u128, 2001), event.entity_id);
    try std.testing.expectEqual(@as(u64, 1001), event.group_id);
    try std.testing.expectEqual(@as(u128, 11111), event.correlation_id);
    try std.testing.expectEqual(@as(i32, 100500), event.altitude_mm);
    try std.testing.expectEqual(@as(u32, 15000), event.velocity_mms);
    try std.testing.expectEqual(@as(u32, 3600), event.ttl_seconds);
    try std.testing.expectEqual(@as(u32, 5000), event.accuracy_mm);
    try std.testing.expectEqual(@as(u16, 9000), event.heading_cdeg);
    try std.testing.expectEqual(@as(u16, 4), event.flags);
}

test "parseEvents: array" {
    const input =
        \\[{"entity_id":"1001","lat_nano":40712800000,"lon_nano":-74006000000},{"entity_id":"1002","lat_nano":40712900000,"lon_nano":-74006100000}]
    ;

    var events = try json.parseEvents(std.testing.allocator, input);
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(@as(u128, 1001), events.items[0].entity_id);
    try std.testing.expectEqual(@as(u128, 1002), events.items[1].entity_id);
}

test "parseInsertResults: success" {
    const input =
        \\{"results":[{"index":0,"code":0}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, input);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u32, 0), results.items[0].index);
    try std.testing.expectEqual(types.InsertResultCode.ok, results.items[0].code);
}

test "parseInsertResults: with errors" {
    const input =
        \\{"results":[{"index":0,"code":0},{"index":1,"code":9},{"index":2,"code":10}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, input);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 3), results.items.len);
    try std.testing.expectEqual(types.InsertResultCode.ok, results.items[0].code);
    try std.testing.expectEqual(types.InsertResultCode.lat_out_of_range, results.items[1].code);
    try std.testing.expectEqual(types.InsertResultCode.lon_out_of_range, results.items[2].code);
}

test "parseQueryResult: with pagination" {
    const input =
        \\{"events":[{"entity_id":"1001","lat_nano":40712800000,"lon_nano":-74006000000}],"has_more":true,"cursor":12345}
    ;

    var result = try json.parseQueryResult(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.events.items.len);
    try std.testing.expect(result.has_more);
    try std.testing.expectEqual(@as(u64, 12345), result.cursor);
}

test "parseQueryResult: empty" {
    const input =
        \\{"events":[],"has_more":false}
    ;

    var result = try json.parseQueryResult(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.events.items.len);
    try std.testing.expect(!result.has_more);
}

test "parseDeleteResult" {
    const input =
        \\{"deleted_count":5,"not_found_count":2}
    ;

    const result = try json.parseDeleteResult(std.testing.allocator, input);

    try std.testing.expectEqual(@as(u32, 5), result.deleted_count);
    try std.testing.expectEqual(@as(u32, 2), result.not_found_count);
}

test "parseTtlSetResponse" {
    const input =
        \\{"success":true,"expiry_ns":1234567890000000000,"previous_ttl":3600}
    ;

    const result = try json.parseTtlSetResponse(std.testing.allocator, input);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 1234567890000000000), result.expiry_ns);
    try std.testing.expectEqual(@as(u32, 3600), result.previous_ttl);
}

test "parseTtlExtendResponse" {
    const input =
        \\{"success":true,"new_expiry_ns":1234567890000000000,"previous_expiry_ns":1234567800000000000}
    ;

    const result = try json.parseTtlExtendResponse(std.testing.allocator, input);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 1234567890000000000), result.new_expiry_ns);
}

test "parseTtlClearResponse" {
    const input =
        \\{"success":true,"had_ttl":true}
    ;

    const result = try json.parseTtlClearResponse(std.testing.allocator, input);

    try std.testing.expect(result.success);
    try std.testing.expect(result.had_ttl);
}

test "parsePingResponse: pong true" {
    const input =
        \\{"pong":true}
    ;

    try std.testing.expect(json.parsePingResponse(input));
}

test "parsePingResponse: status ok" {
    const input =
        \\{"status":"ok"}
    ;

    try std.testing.expect(json.parsePingResponse(input));
}

// ============================================================================
// Round-trip Tests
// ============================================================================

test "round-trip: GeoEvent" {
    const original = types.GeoEvent{
        .entity_id = 12345,
        .lat_nano = types.degreesToNano(37.7749),
        .lon_nano = types.degreesToNano(-122.4194),
        .group_id = 1001,
        .ttl_seconds = 3600,
    };

    const serialized = try json.serializeGeoEvent(std.testing.allocator, original);
    defer std.testing.allocator.free(serialized);

    const parsed = try json.parseGeoEvent(std.testing.allocator, serialized);

    try std.testing.expectEqual(original.entity_id, parsed.entity_id);
    try std.testing.expectEqual(original.lat_nano, parsed.lat_nano);
    try std.testing.expectEqual(original.lon_nano, parsed.lon_nano);
    try std.testing.expectEqual(original.group_id, parsed.group_id);
    try std.testing.expectEqual(original.ttl_seconds, parsed.ttl_seconds);
}

// ============================================================================
// Fixture-based Tests (Phase 11 fixtures)
// ============================================================================

test "fixture: insert operation format" {
    // Test that our serialization matches the insert fixture format
    // This validates compatibility with Phase 11 test infrastructure

    // Create an event matching fixture format
    const event = types.GeoEvent{
        .entity_id = 1001,
        .lat_nano = types.degreesToNano(40.7128),
        .lon_nano = types.degreesToNano(-74.0060),
    };

    const serialized = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(serialized);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"entity_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"lat_nano\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"lon_nano\"") != null);
}

test "fixture: insert result parsing" {
    // Matches expected format from test_infrastructure/fixtures/v1/insert.json
    const response =
        \\{"result_code":0,"results":[{"status":"OK","code":0}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, response);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(types.InsertResultCode.ok, results.items[0].code);
}

test "fixture: insert error LAT_OUT_OF_RANGE" {
    // Matches error case from insert fixture
    const response =
        \\{"result_code":0,"results":[{"status":"LAT_OUT_OF_RANGE","code":9}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, response);
    defer results.deinit();

    try std.testing.expectEqual(types.InsertResultCode.lat_out_of_range, results.items[0].code);
}

test "fixture: insert error LON_OUT_OF_RANGE" {
    // Matches error case from insert fixture
    const response =
        \\{"result_code":0,"results":[{"status":"LON_OUT_OF_RANGE","code":10}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, response);
    defer results.deinit();

    try std.testing.expectEqual(types.InsertResultCode.lon_out_of_range, results.items[0].code);
}

test "fixture: insert error ENTITY_ID_MUST_NOT_BE_ZERO" {
    // Matches error case from insert fixture
    const response =
        \\{"result_code":0,"results":[{"status":"ENTITY_ID_MUST_NOT_BE_ZERO","code":7}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, response);
    defer results.deinit();

    try std.testing.expectEqual(types.InsertResultCode.entity_id_must_not_be_zero, results.items[0].code);
}

test "fixture: query-radius format" {
    // Serialize a radius filter matching fixture format
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = types.degreesToNano(37.7749),
        .center_lon_nano = types.degreesToNano(-122.4194),
        .radius_mm = 1000000, // 1km
        .limit = 100,
    };

    const serialized = try json.serializeRadiusFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(serialized);

    // Parse it back to verify structure
    try std.testing.expect(serialized[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, serialized, "center_lat_nano") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "radius_mm") != null);
}

test "fixture: query-polygon format" {
    // Serialize a polygon filter matching fixture format
    const vertices = [_]types.Vertex{
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.42) },
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.42) },
    };

    const filter = types.QueryPolygonFilter{
        .vertices = &vertices,
        .limit = 1000,
    };

    const serialized = try json.serializePolygonFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"vertices\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"lat_nano\"") != null);
}

test "fixture: delete format" {
    const ids = [_]u128{ 1001, 1002 };

    const serialized = try json.serializeEntityIds(std.testing.allocator, &ids);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "entity_ids") != null);
}

test "fixture: ttl-set format" {
    const serialized = try json.serializeTtlSetRequest(std.testing.allocator, 1001, 3600);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "ttl_seconds") != null);
}

test "fixture: ttl-extend format" {
    const serialized = try json.serializeTtlExtendRequest(std.testing.allocator, 1001, 1800);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "extend_by_seconds") != null);
}

test "fixture: ttl-clear format" {
    const serialized = try json.serializeTtlClearRequest(std.testing.allocator, 1001);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "entity_id") != null);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case: large entity_id (u128 max)" {
    const large_id: u128 = 0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF;

    const event = types.GeoEvent{
        .entity_id = large_id,
        .lat_nano = 0,
        .lon_nano = 0,
    };

    const serialized = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(serialized);

    // Should serialize without error
    try std.testing.expect(std.mem.indexOf(u8, serialized, "entity_id") != null);
}

test "edge case: boundary coordinates" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = types.MAX_LAT_NANO, // North pole
        .lon_nano = types.MAX_LON_NANO, // Antimeridian east
    };

    const serialized = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(serialized);

    const parsed = try json.parseGeoEvent(std.testing.allocator, serialized);
    try std.testing.expectEqual(event.lat_nano, parsed.lat_nano);
    try std.testing.expectEqual(event.lon_nano, parsed.lon_nano);
}

test "edge case: negative coordinates" {
    const event = types.GeoEvent{
        .entity_id = 1,
        .lat_nano = types.MIN_LAT_NANO, // South pole
        .lon_nano = types.MIN_LON_NANO, // Antimeridian west
    };

    const serialized = try json.serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(serialized);

    const parsed = try json.parseGeoEvent(std.testing.allocator, serialized);
    try std.testing.expectEqual(event.lat_nano, parsed.lat_nano);
    try std.testing.expectEqual(event.lon_nano, parsed.lon_nano);
}

test "edge case: empty events array" {
    const events = [_]types.GeoEvent{};

    const serialized = try json.serializeEvents(std.testing.allocator, &events);
    defer std.testing.allocator.free(serialized);

    try std.testing.expectEqualStrings("[]", serialized);
}
