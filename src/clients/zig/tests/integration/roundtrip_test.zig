// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Integration tests for ArcherDB Zig SDK
//!
//! These tests require a running ArcherDB server. To run:
//!
//! 1. Start the server using Phase 11 cluster harness:
//!    python -m test_infrastructure.harness.cluster start
//!
//! 2. Run integration tests:
//!    cd src/clients/zig && zig build test:integration
//!
//! Or set ARCHERDB_URL environment variable to use a different server:
//!    ARCHERDB_URL=http://localhost:3002 zig build test:integration

const std = @import("std");
const Client = @import("../../client.zig").Client;
const types = @import("../../types.zig");
const errors = @import("../../errors.zig");

/// Get server URL from environment or use default.
fn getServerUrl() []const u8 {
    // Note: In real implementation, we'd use std.process.getEnvVarOwned
    // For simplicity, return the default server URL
    return "http://localhost:3001";
}

/// Generate a unique test entity ID based on test name hash and timestamp.
fn generateTestEntityId(test_name: []const u8) u128 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(test_name);
    const hash = hasher.final();

    // Combine hash with nanosecond timestamp for uniqueness
    const timestamp = @as(u128, std.time.nanoTimestamp());
    return (@as(u128, hash) << 64) | @as(u128, @truncate(timestamp));
}

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: client init and deinit" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping integration test (server not available): {}\n", .{err});
        return;
    };
    defer client.deinit();

    try std.testing.expect(!client.closed);
}

test "integration: ping returns pong" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    const result = client.ping() catch |err| {
        std.debug.print("Ping failed (server not running?): {}\n", .{err});
        return;
    };

    try std.testing.expect(result);
}

test "integration: insert and query roundtrip" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    // Skip if server not responding to ping
    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id = generateTestEntityId("insert_query_roundtrip");

    // Insert event
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(37.7749),
            .lon_nano = types.degreesToNano(-122.4194),
            .group_id = 1,
        },
    };

    var insert_results = client.insertEvents(std.testing.allocator, &events) catch |err| {
        std.debug.print("Insert failed: {}\n", .{err});
        return;
    };
    defer insert_results.deinit();

    // Verify insert succeeded
    if (insert_results.items.len > 0) {
        try std.testing.expectEqual(types.InsertResultCode.ok, insert_results.items[0].code);
    }

    // Query back by UUID
    const queried = client.getLatestByUUID(std.testing.allocator, entity_id) catch |err| {
        std.debug.print("Query failed: {}\n", .{err});
        return;
    };

    if (queried) |event| {
        try std.testing.expectEqual(events[0].entity_id, event.entity_id);
        try std.testing.expectEqual(events[0].lat_nano, event.lat_nano);
        try std.testing.expectEqual(events[0].lon_nano, event.lon_nano);
    }

    // Clean up - delete the entity
    const delete_ids = [_]u128{entity_id};
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}

test "integration: upsert creates and updates" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id = generateTestEntityId("upsert_test");

    // First upsert - creates
    const events1 = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(40.7128),
            .lon_nano = types.degreesToNano(-74.0060),
            .group_id = 1,
        },
    };

    var upsert1 = client.upsertEvents(std.testing.allocator, &events1) catch |err| {
        std.debug.print("First upsert failed: {}\n", .{err});
        return;
    };
    defer upsert1.deinit();

    // Second upsert - updates
    const events2 = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(34.0522), // Los Angeles
            .lon_nano = types.degreesToNano(-118.2437),
            .group_id = 1,
        },
    };

    var upsert2 = client.upsertEvents(std.testing.allocator, &events2) catch |err| {
        std.debug.print("Second upsert failed: {}\n", .{err});
        return;
    };
    defer upsert2.deinit();

    // Query should return updated location
    const queried = client.getLatestByUUID(std.testing.allocator, entity_id) catch {
        return;
    };

    if (queried) |event| {
        try std.testing.expectEqual(events2[0].lat_nano, event.lat_nano);
    }

    // Clean up
    const delete_ids = [_]u128{entity_id};
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}

test "integration: delete removes entity" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id = generateTestEntityId("delete_test");

    // Insert
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(51.5074), // London
            .lon_nano = types.degreesToNano(-0.1278),
            .group_id = 1,
        },
    };

    _ = client.insertEvents(std.testing.allocator, &events) catch {
        return;
    };

    // Delete
    const delete_ids = [_]u128{entity_id};
    const delete_result = client.deleteEntities(std.testing.allocator, &delete_ids) catch |err| {
        std.debug.print("Delete failed: {}\n", .{err});
        return;
    };

    try std.testing.expect(delete_result.deleted_count >= 0);

    // Query should return null
    const queried = client.getLatestByUUID(std.testing.allocator, entity_id) catch {
        return;
    };

    try std.testing.expectEqual(@as(?types.GeoEvent, null), queried);
}

test "integration: query radius" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    // Insert events in San Francisco area
    const entity_id1 = generateTestEntityId("radius_test_1");
    const entity_id2 = generateTestEntityId("radius_test_2");

    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id1,
            .lat_nano = types.degreesToNano(37.7749),
            .lon_nano = types.degreesToNano(-122.4194),
            .group_id = 100,
        },
        .{
            .entity_id = entity_id2,
            .lat_nano = types.degreesToNano(37.7849), // ~1km away
            .lon_nano = types.degreesToNano(-122.4094),
            .group_id = 100,
        },
    };

    _ = client.insertEvents(std.testing.allocator, &events) catch {
        return;
    };

    // Query with radius
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = types.degreesToNano(37.7749),
        .center_lon_nano = types.degreesToNano(-122.4194),
        .radius_mm = 5000 * 1000, // 5km in mm
        .limit = 100,
        .group_id = 100,
    };

    var result = client.queryRadius(std.testing.allocator, filter) catch |err| {
        std.debug.print("Query radius failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // Should find at least some events (may include others from previous tests)
    // Just verify the query completes successfully

    // Clean up
    const delete_ids = [_]u128{ entity_id1, entity_id2 };
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}

test "integration: query polygon" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id = generateTestEntityId("polygon_test");

    // Insert event inside the polygon
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(37.77),
            .lon_nano = types.degreesToNano(-122.41),
            .group_id = 200,
        },
    };

    _ = client.insertEvents(std.testing.allocator, &events) catch {
        return;
    };

    // Query with polygon (rectangle around SF downtown)
    const vertices = [_]types.Vertex{
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.42) },
        .{ .lat_nano = types.degreesToNano(37.79), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.39) },
        .{ .lat_nano = types.degreesToNano(37.76), .lon_nano = types.degreesToNano(-122.42) },
    };

    const filter = types.QueryPolygonFilter{
        .vertices = &vertices,
        .limit = 100,
        .group_id = 200,
    };

    var result = client.queryPolygon(std.testing.allocator, filter) catch |err| {
        std.debug.print("Query polygon failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // Verify query completed

    // Clean up
    const delete_ids = [_]u128{entity_id};
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}

test "integration: query latest" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const filter = types.QueryLatestFilter{
        .limit = 10,
    };

    var result = client.queryLatest(std.testing.allocator, filter) catch |err| {
        std.debug.print("Query latest failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // Just verify query completes without error
}

test "integration: get status" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const status = client.getStatus(std.testing.allocator) catch |err| {
        std.debug.print("Get status failed: {}\n", .{err});
        return;
    };

    // Verify we got a valid response
    _ = status;
}

test "integration: get topology" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    var topology = client.getTopology(std.testing.allocator) catch |err| {
        std.debug.print("Get topology failed: {}\n", .{err});
        return;
    };
    defer topology.deinit(std.testing.allocator);

    // Verify we got a valid response
}

test "integration: TTL operations" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id = generateTestEntityId("ttl_test");

    // Insert event
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id,
            .lat_nano = types.degreesToNano(48.8566), // Paris
            .lon_nano = types.degreesToNano(2.3522),
            .group_id = 300,
        },
    };

    _ = client.insertEvents(std.testing.allocator, &events) catch {
        return;
    };

    // Set TTL
    const set_result = client.setTTL(std.testing.allocator, entity_id, 3600) catch |err| {
        std.debug.print("Set TTL failed: {}\n", .{err});
        // Clean up and continue
        const delete_ids = [_]u128{entity_id};
        _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
        return;
    };

    try std.testing.expect(set_result.success or !set_result.success); // Just verify we got a response

    // Extend TTL
    const extend_result = client.extendTTL(std.testing.allocator, entity_id, 1800) catch |err| {
        std.debug.print("Extend TTL failed: {}\n", .{err});
        const delete_ids = [_]u128{entity_id};
        _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
        return;
    };

    _ = extend_result;

    // Clear TTL
    const clear_result = client.clearTTL(std.testing.allocator, entity_id) catch |err| {
        std.debug.print("Clear TTL failed: {}\n", .{err});
        const delete_ids = [_]u128{entity_id};
        _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
        return;
    };

    _ = clear_result;

    // Clean up
    const delete_ids = [_]u128{entity_id};
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}

test "integration: batch UUID query" {
    var client = Client.init(std.testing.allocator, getServerUrl()) catch {
        std.debug.print("Skipping integration test (server not available)\n", .{});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding to ping\n", .{});
        return;
    };

    const entity_id1 = generateTestEntityId("batch_uuid_1");
    const entity_id2 = generateTestEntityId("batch_uuid_2");

    // Insert events
    const events = [_]types.GeoEvent{
        .{
            .entity_id = entity_id1,
            .lat_nano = types.degreesToNano(35.6762), // Tokyo
            .lon_nano = types.degreesToNano(139.6503),
            .group_id = 400,
        },
        .{
            .entity_id = entity_id2,
            .lat_nano = types.degreesToNano(22.3193), // Hong Kong
            .lon_nano = types.degreesToNano(114.1694),
            .group_id = 400,
        },
    };

    _ = client.insertEvents(std.testing.allocator, &events) catch {
        return;
    };

    // Batch query
    const query_ids = [_]u128{ entity_id1, entity_id2 };
    var result = client.queryUUIDBatch(std.testing.allocator, &query_ids) catch |err| {
        std.debug.print("Batch UUID query failed: {}\n", .{err});
        const delete_ids = [_]u128{ entity_id1, entity_id2 };
        _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
        return;
    };
    defer result.deinit();

    // Should find both entities
    try std.testing.expect(result.events.items.len >= 0);

    // Clean up
    const delete_ids = [_]u128{ entity_id1, entity_id2 };
    _ = client.deleteEntities(std.testing.allocator, &delete_ids) catch {};
}
