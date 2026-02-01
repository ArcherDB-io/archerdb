// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Unit tests for ArcherDB Zig SDK Client
//!
//! These tests verify client initialization, request construction, and response parsing.
//! Integration tests (requiring a running server) are in tests/integration/.

const std = @import("std");
const Client = @import("../../client.zig").Client;
const types = @import("../../types.zig");
const errors = @import("../../errors.zig");
const json = @import("../../json.zig");
const http = @import("../../http.zig");

// ============================================================================
// Client Lifecycle Tests
// ============================================================================

test "Client: init allocates base_url copy" {
    const original = "http://localhost:3001";
    var client = try Client.init(std.testing.allocator, original);
    defer client.deinit();

    // Should have copied the URL
    try std.testing.expectEqualStrings(original, client.base_url);
    try std.testing.expect(!client.closed);
}

test "Client: deinit sets closed flag" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    try std.testing.expect(!client.closed);

    client.deinit();
    try std.testing.expect(client.closed);
}

test "Client: double deinit is safe" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();
    client.deinit(); // Should not crash or double-free
    try std.testing.expect(client.closed);
}

// ============================================================================
// Closed Client Tests
// ============================================================================

test "Client: ping on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    try std.testing.expectError(error.ClientClosed, client.ping());
}

test "Client: insertEvents on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const events = [_]types.GeoEvent{
        .{ .entity_id = 1, .lat_nano = 0, .lon_nano = 0 },
    };
    const result = client.insertEvents(std.testing.allocator, &events);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: upsertEvents on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const events = [_]types.GeoEvent{
        .{ .entity_id = 1, .lat_nano = 0, .lon_nano = 0 },
    };
    const result = client.upsertEvents(std.testing.allocator, &events);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: deleteEntities on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const ids = [_]u128{1};
    const result = client.deleteEntities(std.testing.allocator, &ids);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: getLatestByUUID on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.getLatestByUUID(std.testing.allocator, 1);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: queryUUIDBatch on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const ids = [_]u128{1};
    const result = client.queryUUIDBatch(std.testing.allocator, &ids);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: queryRadius on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const filter = types.QueryRadiusFilter{
        .center_lat_nano = 0,
        .center_lon_nano = 0,
        .radius_mm = 1000,
    };
    const result = client.queryRadius(std.testing.allocator, filter);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: queryPolygon on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const vertices = [_]types.Vertex{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 1000 },
        .{ .lat_nano = 1000, .lon_nano = 0 },
    };
    const filter = types.QueryPolygonFilter{
        .vertices = &vertices,
    };
    const result = client.queryPolygon(std.testing.allocator, filter);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: queryLatest on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const filter = types.QueryLatestFilter{};
    const result = client.queryLatest(std.testing.allocator, filter);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: getStatus on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.getStatus(std.testing.allocator);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: getTopology on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.getTopology(std.testing.allocator);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: setTTL on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.setTTL(std.testing.allocator, 1, 3600);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: extendTTL on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.extendTTL(std.testing.allocator, 1, 1800);
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: clearTTL on closed client returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.clearTTL(std.testing.allocator, 1);
    try std.testing.expectError(error.ClientClosed, result);
}

// ============================================================================
// Empty Input Tests
// ============================================================================

test "Client: insertEvents with empty array returns empty results" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const events = [_]types.GeoEvent{};
    var results = try client.insertEvents(std.testing.allocator, &events);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "Client: upsertEvents with empty array returns empty results" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const events = [_]types.GeoEvent{};
    var results = try client.upsertEvents(std.testing.allocator, &events);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "Client: deleteEntities with empty array returns empty result" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const ids = [_]u128{};
    const result = try client.deleteEntities(std.testing.allocator, &ids);

    try std.testing.expectEqual(@as(u32, 0), result.deleted_count);
    try std.testing.expectEqual(@as(u32, 0), result.not_found_count);
}

test "Client: queryUUIDBatch with empty array returns empty result" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const ids = [_]u128{};
    var result = try client.queryUUIDBatch(std.testing.allocator, &ids);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.events.items.len);
}

// ============================================================================
// Validation Tests
// ============================================================================

test "Client: queryRadius with too large limit returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const filter = types.QueryRadiusFilter{
        .center_lat_nano = 0,
        .center_lon_nano = 0,
        .radius_mm = 1000,
        .limit = types.QUERY_LIMIT_MAX + 1,
    };
    const result = client.queryRadius(std.testing.allocator, filter);
    try std.testing.expectError(error.QueryResultTooLarge, result);
}

test "Client: queryPolygon with too few vertices returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const vertices = [_]types.Vertex{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 1000 },
    };
    const filter = types.QueryPolygonFilter{
        .vertices = &vertices, // Only 2 vertices - need at least 3
    };
    const result = client.queryPolygon(std.testing.allocator, filter);
    try std.testing.expectError(error.InvalidPolygon, result);
}

test "Client: queryPolygon with too large limit returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const vertices = [_]types.Vertex{
        .{ .lat_nano = 0, .lon_nano = 0 },
        .{ .lat_nano = 0, .lon_nano = 1000 },
        .{ .lat_nano = 1000, .lon_nano = 0 },
    };
    const filter = types.QueryPolygonFilter{
        .vertices = &vertices,
        .limit = types.QUERY_LIMIT_MAX + 1,
    };
    const result = client.queryPolygon(std.testing.allocator, filter);
    try std.testing.expectError(error.QueryResultTooLarge, result);
}

test "Client: queryLatest with too large limit returns error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    const filter = types.QueryLatestFilter{
        .limit = types.QUERY_LIMIT_MAX + 1,
    };
    const result = client.queryLatest(std.testing.allocator, filter);
    try std.testing.expectError(error.QueryResultTooLarge, result);
}

// ============================================================================
// Request Body Construction Tests (via JSON module)
// ============================================================================

test "Client: insert request body format" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 1001,
            .lat_nano = types.degreesToNano(40.7128),
            .lon_nano = types.degreesToNano(-74.0060),
        },
    };

    const body = try json.serializeInsertRequest(std.testing.allocator, &events, "insert");
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"insert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"events\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"entity_id\":\"1001\"") != null);
}

test "Client: upsert request body format" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 1001,
            .lat_nano = types.degreesToNano(40.7128),
            .lon_nano = types.degreesToNano(-74.0060),
        },
    };

    const body = try json.serializeInsertRequest(std.testing.allocator, &events, "upsert");
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"upsert\"") != null);
}

test "Client: delete request body format" {
    const ids = [_]u128{ 1001, 1002 };

    const body = try json.serializeEntityIds(std.testing.allocator, &ids);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"entity_ids\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"1001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"1002\"") != null);
}

test "Client: radius query request body format" {
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = types.degreesToNano(37.7749),
        .center_lon_nano = types.degreesToNano(-122.4194),
        .radius_mm = 1000000, // 1km
        .limit = 100,
        .group_id = 1,
    };

    const body = try json.serializeRadiusFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"center_lat_nano\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"center_lon_nano\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"radius_mm\":1000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"limit\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"group_id\":1") != null);
}

test "Client: polygon query request body format" {
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

    const body = try json.serializePolygonFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"vertices\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lat_nano\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lon_nano\":") != null);
}

test "Client: TTL set request body format" {
    const body = try json.serializeTtlSetRequest(std.testing.allocator, 1001, 3600);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"entity_id\":\"1001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ttl_seconds\":3600") != null);
}

test "Client: TTL extend request body format" {
    const body = try json.serializeTtlExtendRequest(std.testing.allocator, 1001, 1800);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"entity_id\":\"1001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"extend_by_seconds\":1800") != null);
}

test "Client: TTL clear request body format" {
    const body = try json.serializeTtlClearRequest(std.testing.allocator, 1001);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"entity_id\":\"1001\"") != null);
}

// ============================================================================
// Response Parsing Tests (via JSON module)
// ============================================================================

test "Client: insert response parsing" {
    const response =
        \\{"results":[{"index":0,"code":0},{"index":1,"code":9}]}
    ;

    var results = try json.parseInsertResults(std.testing.allocator, response);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(types.InsertResultCode.ok, results.items[0].code);
    try std.testing.expectEqual(types.InsertResultCode.lat_out_of_range, results.items[1].code);
}

test "Client: query response parsing" {
    const response =
        \\{"events":[{"entity_id":"1001","lat_nano":40712800000,"lon_nano":-74006000000}],"has_more":true,"cursor":12345}
    ;

    var result = try json.parseQueryResult(std.testing.allocator, response);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.events.items.len);
    try std.testing.expect(result.has_more);
    try std.testing.expectEqual(@as(u64, 12345), result.cursor);
}

test "Client: delete response parsing" {
    const response =
        \\{"deleted_count":5,"not_found_count":2}
    ;

    const result = try json.parseDeleteResult(std.testing.allocator, response);

    try std.testing.expectEqual(@as(u32, 5), result.deleted_count);
    try std.testing.expectEqual(@as(u32, 2), result.not_found_count);
}

test "Client: TTL set response parsing" {
    const response =
        \\{"success":true,"expiry_ns":1234567890000000000,"previous_ttl":3600}
    ;

    const result = try json.parseTtlSetResponse(std.testing.allocator, response);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 1234567890000000000), result.expiry_ns);
    try std.testing.expectEqual(@as(u32, 3600), result.previous_ttl);
}

test "Client: ping response parsing - pong true" {
    try std.testing.expect(json.parsePingResponse("{\"pong\":true}"));
}

test "Client: ping response parsing - status ok" {
    try std.testing.expect(json.parsePingResponse("{\"status\":\"ok\"}"));
}

// ============================================================================
// URL Building Tests
// ============================================================================

test "Client: URL building basic" {
    const url = try http.buildUrl(std.testing.allocator, "http://localhost:3001", "/events");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/events", url);
}

test "Client: URL building with trailing slash" {
    const url = try http.buildUrl(std.testing.allocator, "http://localhost:3001/", "/events");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/events", url);
}

test "Client: URL building with param" {
    const url = try http.buildUrlWithParam(std.testing.allocator, "http://localhost:3001", "/entity/{}", 12345);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:3001/entity/12345", url);
}

test "Client: URL building with large u128 param" {
    const large_id: u128 = 12345678901234567890;
    const url = try http.buildUrlWithParam(std.testing.allocator, "http://localhost:3001", "/entity/{}", large_id);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "12345678901234567890") != null);
}

// ============================================================================
// Re-export Tests
// ============================================================================

test "Client: re-exports are accessible" {
    const client_mod = @import("../../client.zig");

    // Types
    _ = client_mod.GeoEvent;
    _ = client_mod.QueryRadiusFilter;
    _ = client_mod.QueryPolygonFilter;
    _ = client_mod.QueryLatestFilter;
    _ = client_mod.QueryResult;
    _ = client_mod.InsertResult;
    _ = client_mod.DeleteResult;
    _ = client_mod.Vertex;

    // Errors
    _ = client_mod.ClientError;
    _ = client_mod.isRetryable;
    _ = client_mod.isNetworkError;

    // Helpers
    _ = client_mod.degreesToNano;
    _ = client_mod.nanoToDegrees;
    _ = client_mod.metersToMm;
}

// ============================================================================
// HttpClient Tests
// ============================================================================

test "HttpClient: init and deinit" {
    var client = http.HttpClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(true); // Just verify no crash
}
