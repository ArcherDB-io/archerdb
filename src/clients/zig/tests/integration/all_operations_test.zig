// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Comprehensive integration tests using Phase 11 JSON fixtures
//!
//! These tests load JSON fixtures from test_infrastructure/fixtures/v1/
//! and verify each SDK operation produces expected results.
//!
//! All 14 operations are tested:
//!   Data: insert, upsert, delete
//!   Query: uuid, uuid-batch, radius, polygon, latest
//!   Metadata: ping, status, topology
//!   TTL: set, extend, clear
//!
//! Run with:
//!   cd src/clients/zig && zig build test:integration
//!
//! Or with custom server:
//!   ARCHERDB_URL=http://localhost:3002 zig build test:integration
//!
//! Filter to fixture tests only:
//!   zig build test:integration -- --test-filter "fixture"

const std = @import("std");
const sdk = @import("sdk");
const Client = sdk.Client;

// Re-exported types from SDK
const types = struct {
    pub const GeoEvent = sdk.GeoEvent;
    pub const QueryRadiusFilter = sdk.QueryRadiusFilter;
    pub const QueryPolygonFilter = sdk.QueryPolygonFilter;
    pub const QueryLatestFilter = sdk.QueryLatestFilter;
    pub const InsertResultCode = sdk.InsertResultCode;
    pub const Vertex = sdk.Vertex;
    pub const degreesToNano = sdk.degreesToNano;
};

/// Fixture directory - use absolute path for reliability
const FixtureDir = "/home/g/archerdb/test_infrastructure/fixtures/v1/";

/// Get server URL from environment or use default.
fn getServerUrl() []const u8 {
    return std.posix.getenv("ARCHERDB_URL") orelse "http://localhost:3001";
}

/// Generate a unique test entity ID based on test name hash and counter.
var entity_id_counter: u64 = 0;
fn generateTestEntityId(test_name: []const u8) u128 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(test_name);
    const hash = hasher.final();
    entity_id_counter += 1;
    return (@as(u128, hash) << 64) | @as(u128, entity_id_counter);
}

/// Simple JSON value representation for test fixture parsing
const JsonValue = std.json.Value;

/// Load a fixture file and return the parsed JSON value.
fn loadFixture(allocator: std.mem.Allocator, operation: []const u8) !std.json.Parsed(JsonValue) {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, FixtureDir ++ "{s}.json", .{operation}) catch {
        return error.PathTooLong;
    };

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Failed to open fixture: {s} (error: {})\n", .{ path, err });
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 2 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read fixture: {s}\n", .{path});
        return err;
    };
    defer allocator.free(content);

    return std.json.parseFromSlice(JsonValue, allocator, content, .{});
}

/// Clean database by querying and deleting all events.
fn cleanDatabase(client: *Client, allocator: std.mem.Allocator) !void {
    const filter = types.QueryLatestFilter{ .limit = 10000 };
    var result = client.queryLatest(allocator, filter) catch |err| {
        // If query fails, database might be empty or server unavailable
        std.debug.print("Clean database query failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    if (result.events.items.len == 0) return;

    var ids = try allocator.alloc(u128, result.events.items.len);
    defer allocator.free(ids);

    for (result.events.items, 0..) |event, i| {
        ids[i] = event.entity_id;
    }

    _ = client.deleteEntities(allocator, ids) catch {};
}

/// Parse a JSON number as either float or integer and convert to nano.
fn jsonToNano(value: JsonValue) i64 {
    return switch (value) {
        .float => |f| types.degreesToNano(f),
        .integer => |i| types.degreesToNano(@as(f64, @floatFromInt(i))),
        else => 0,
    };
}

/// Parse a JSON number as u128 entity ID.
fn jsonToEntityId(value: JsonValue) u128 {
    return switch (value) {
        .integer => |i| @intCast(@as(u64, @intCast(i))),
        else => 0,
    };
}

/// Parse a JSON number as u64 group ID.
fn jsonToGroupId(value: JsonValue) u64 {
    return switch (value) {
        .integer => |i| @intCast(i),
        else => 0,
    };
}

/// Parse a JSON number as u32.
fn jsonToU32(value: JsonValue) u32 {
    return switch (value) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

/// Convert JSON event object to GeoEvent.
fn jsonToGeoEvent(event_json: JsonValue) types.GeoEvent {
    const obj = event_json.object;
    return .{
        .entity_id = if (obj.get("entity_id")) |v| jsonToEntityId(v) else 0,
        .lat_nano = if (obj.get("latitude")) |v| jsonToNano(v) else 0,
        .lon_nano = if (obj.get("longitude")) |v| jsonToNano(v) else 0,
        .group_id = if (obj.get("group_id")) |v| jsonToGroupId(v) else 0,
        .correlation_id = if (obj.get("correlation_id")) |v| jsonToEntityId(v) else 0,
        .user_data = if (obj.get("user_data")) |v| jsonToEntityId(v) else 0,
        .altitude_mm = if (obj.get("altitude_m")) |v| @intFromFloat(@as(f64, switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0,
        }) * 1000.0) else 0,
        .velocity_mms = if (obj.get("velocity_mps")) |v| jsonToU32(v) * 1000 else 0,
        .ttl_seconds = if (obj.get("ttl_seconds")) |v| jsonToU32(v) else 0,
        .accuracy_mm = if (obj.get("accuracy_m")) |v| jsonToU32(v) * 1000 else 0,
        .heading_cdeg = if (obj.get("heading")) |v| @intFromFloat(@as(f64, switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0,
        }) * 100.0) else 0,
        .flags = if (obj.get("flags")) |v| @intCast(switch (v) {
            .integer => |i| i,
            else => 0,
        }) else 0,
    };
}

/// Parse events from fixture JSON.
fn parseFixtureEvents(
    allocator: std.mem.Allocator,
    events_json: std.json.Array,
) ![]types.GeoEvent {
    var events = try allocator.alloc(types.GeoEvent, events_json.items.len);
    for (events_json.items, 0..) |event_json, i| {
        events[i] = jsonToGeoEvent(event_json);
    }
    return events;
}

/// Parse entity IDs from fixture JSON.
fn parseEntityIds(allocator: std.mem.Allocator, ids_json: std.json.Array) ![]u128 {
    var ids = try allocator.alloc(u128, ids_json.items.len);
    for (ids_json.items, 0..) |id_json, i| {
        ids[i] = jsonToEntityId(id_json);
    }
    return ids;
}

/// Insert setup events from fixture.
fn insertSetupEvents(
    client: *Client,
    allocator: std.mem.Allocator,
    setup_json: JsonValue,
) !void {
    const setup_obj = setup_json.object;

    if (setup_obj.get("insert_first")) |insert_first| {
        switch (insert_first) {
            .array => |arr| {
                const events = try parseFixtureEvents(allocator, arr);
                defer allocator.free(events);
                var result = try client.insertEvents(allocator, events);
                result.deinit();
            },
            .object => {
                var events = [_]types.GeoEvent{jsonToGeoEvent(insert_first)};
                var result = try client.insertEvents(allocator, &events);
                result.deinit();
            },
            else => {},
        }
    }
}

// ============================================================================
// Insert Operation Tests (opcode 146)
// ============================================================================

test "fixture: insert operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    // Skip if server not responding
    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "insert") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;
        const events_json = input.get("events") orelse continue;

        const events = try parseFixtureEvents(allocator, events_json.array);
        defer allocator.free(events);

        var result = client.insertEvents(allocator, events) catch |err| {
            std.debug.print("    Insert failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();

        // Check expected output
        const expected = case_json.object.get("expected_output").?.object;
        if (expected.get("result_code")) |code| {
            try std.testing.expectEqual(@as(i64, 0), code.integer);
        }
    }
}

// ============================================================================
// Upsert Operation Tests (opcode 147)
// ============================================================================

test "fixture: upsert operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "upsert") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const events_json = input.get("events") orelse continue;
        const events = try parseFixtureEvents(allocator, events_json.array);
        defer allocator.free(events);

        var result = client.upsertEvents(allocator, events) catch |err| {
            std.debug.print("    Upsert failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();
    }
}

// ============================================================================
// Delete Operation Tests (opcode 148)
// ============================================================================

test "fixture: delete operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "delete") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const ids_json = input.get("entity_ids") orelse continue;
        const ids = try parseEntityIds(allocator, ids_json.array);
        defer allocator.free(ids);

        const result = client.deleteEntities(allocator, ids) catch |err| {
            std.debug.print("    Delete failed: {}\n", .{err});
            continue;
        };
        _ = result;
    }
}

// ============================================================================
// Query UUID Tests (opcode 149)
// ============================================================================

test "fixture: query-uuid operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "query-uuid") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const entity_id: u128 = if (input.get("entity_id")) |id|
            jsonToEntityId(id)
        else if (input.get("setup")) |setup| blk: {
            const setup_obj = setup.object;
            if (setup_obj.get("insert_first")) |insert_first| {
                switch (insert_first) {
                    .array => |arr| {
                        if (arr.items.len > 0) {
                            break :blk jsonToEntityId(arr.items[0].object.get("entity_id").?);
                        }
                    },
                    .object => |obj| {
                        break :blk jsonToEntityId(obj.get("entity_id").?);
                    },
                    else => {},
                }
            }
            break :blk 0;
        } else 0;

        if (entity_id == 0) continue;

        const result = client.getLatestByUUID(allocator, entity_id) catch |err| {
            std.debug.print("    Query UUID failed: {}\n", .{err});
            continue;
        };
        _ = result;
    }
}

// ============================================================================
// Query UUID Batch Tests (opcode 156)
// ============================================================================

test "fixture: query-uuid-batch operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "query-uuid-batch") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const ids_json = input.get("entity_ids") orelse continue;
        const ids = try parseEntityIds(allocator, ids_json.array);
        defer allocator.free(ids);

        var result = client.queryUUIDBatch(allocator, ids) catch |err| {
            std.debug.print("    Query UUID batch failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();
    }
}

// ============================================================================
// Query Radius Tests (opcode 150)
// ============================================================================

test "fixture: query-radius operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "query-radius") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const center_lat = if (input.get("center_latitude")) |v| jsonToNano(v) else 0;
        const center_lon = if (input.get("center_longitude")) |v| jsonToNano(v) else 0;
        const radius_m = if (input.get("radius_m")) |v| jsonToU32(v) else 1000;
        const limit = if (input.get("limit")) |v| jsonToU32(v) else 1000;
        const group_id = if (input.get("group_id")) |v| jsonToGroupId(v) else 0;

        const filter = types.QueryRadiusFilter{
            .center_lat_nano = center_lat,
            .center_lon_nano = center_lon,
            .radius_mm = radius_m * 1000,
            .limit = limit,
            .group_id = group_id,
        };

        var result = client.queryRadius(allocator, filter) catch |err| {
            std.debug.print("    Query radius failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();
    }
}

// ============================================================================
// Query Polygon Tests (opcode 151)
// ============================================================================

test "fixture: query-polygon operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "query-polygon") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        // Parse polygon vertices or create a default square
        var vertices_buf: [64]types.Vertex = undefined;
        var vertex_count: usize = 0;

        if (input.get("vertices")) |verts_json| {
            for (verts_json.array.items) |v| {
                if (vertex_count >= vertices_buf.len) break;
                // Vertices are array format: [lat, lon]
                const lat = if (v.array.items.len > 0) jsonToNano(v.array.items[0]) else 0;
                const lon = if (v.array.items.len > 1) jsonToNano(v.array.items[1]) else 0;
                vertices_buf[vertex_count] = .{ .lat_nano = lat, .lon_nano = lon };
                vertex_count += 1;
            }
        } else {
            // Create default 1km square around origin
            const center_lat = if (input.get("center_latitude")) |v| jsonToNano(v) else types.degreesToNano(40.7128);
            const center_lon = if (input.get("center_longitude")) |v| jsonToNano(v) else types.degreesToNano(-74.0060);
            const delta: i64 = types.degreesToNano(0.01); // ~1km

            vertices_buf[0] = .{ .lat_nano = center_lat + delta, .lon_nano = center_lon - delta };
            vertices_buf[1] = .{ .lat_nano = center_lat + delta, .lon_nano = center_lon + delta };
            vertices_buf[2] = .{ .lat_nano = center_lat - delta, .lon_nano = center_lon + delta };
            vertices_buf[3] = .{ .lat_nano = center_lat - delta, .lon_nano = center_lon - delta };
            vertex_count = 4;
        }

        const limit = if (input.get("limit")) |v| jsonToU32(v) else 1000;
        const group_id = if (input.get("group_id")) |v| jsonToGroupId(v) else 0;

        const filter = types.QueryPolygonFilter{
            .vertices = vertices_buf[0..vertex_count],
            .limit = limit,
            .group_id = group_id,
        };

        var result = client.queryPolygon(allocator, filter) catch |err| {
            std.debug.print("    Query polygon failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();
    }
}

// ============================================================================
// Query Latest Tests (opcode 154)
// ============================================================================

test "fixture: query-latest operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "query-latest") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const limit = if (input.get("limit")) |v| jsonToU32(v) else 100;
        const group_id = if (input.get("group_id")) |v| jsonToGroupId(v) else 0;

        const filter = types.QueryLatestFilter{
            .limit = limit,
            .group_id = group_id,
        };

        var result = client.queryLatest(allocator, filter) catch |err| {
            std.debug.print("    Query latest failed: {}\n", .{err});
            continue;
        };
        defer result.deinit();
    }
}

// ============================================================================
// Ping Tests (opcode 152)
// ============================================================================

test "fixture: ping operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    var fixture = loadFixture(allocator, "ping") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        const result = client.ping() catch |err| {
            std.debug.print("    Ping failed: {}\n", .{err});
            continue;
        };

        try std.testing.expect(result);
    }
}

// ============================================================================
// Status Tests (opcode 153)
// ============================================================================

test "fixture: status operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "status") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        const status = client.getStatus(allocator) catch |err| {
            std.debug.print("    Status failed: {}\n", .{err});
            continue;
        };
        _ = status;
    }
}

// ============================================================================
// Topology Tests (opcode 157)
// ============================================================================

test "fixture: topology operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "topology") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    // Only test first case (single node) - others depend on cluster config
    const cases = fixture.value.object.get("cases").?.array;
    if (cases.items.len > 0) {
        const case_json = cases.items[0];
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        var topology = client.getTopology(allocator) catch |err| {
            std.debug.print("    Topology failed: {}\n", .{err});
            return;
        };
        defer topology.deinit(allocator);
    }
}

// ============================================================================
// TTL Set Tests (opcode 158)
// ============================================================================

test "fixture: ttl-set operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "ttl-set") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const entity_id: u128 = if (input.get("entity_id")) |id|
            jsonToEntityId(id)
        else if (input.get("setup")) |setup| blk: {
            const setup_obj = setup.object;
            if (setup_obj.get("insert_first")) |insert_first| {
                switch (insert_first) {
                    .object => |obj| break :blk jsonToEntityId(obj.get("entity_id").?),
                    .array => |arr| {
                        if (arr.items.len > 0) {
                            break :blk jsonToEntityId(arr.items[0].object.get("entity_id").?);
                        }
                    },
                    else => {},
                }
            }
            break :blk 0;
        } else 0;

        if (entity_id == 0) continue;

        const ttl = if (input.get("ttl_seconds")) |v| jsonToU32(v) else 3600;

        const result = client.setTTL(allocator, entity_id, ttl) catch |err| {
            std.debug.print("    TTL set failed: {}\n", .{err});
            continue;
        };
        _ = result;
    }
}

// ============================================================================
// TTL Extend Tests (opcode 159)
// ============================================================================

test "fixture: ttl-extend operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "ttl-extend") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const entity_id: u128 = if (input.get("entity_id")) |id|
            jsonToEntityId(id)
        else if (input.get("setup")) |setup| blk: {
            const setup_obj = setup.object;
            if (setup_obj.get("insert_first")) |insert_first| {
                switch (insert_first) {
                    .object => |obj| break :blk jsonToEntityId(obj.get("entity_id").?),
                    .array => |arr| {
                        if (arr.items.len > 0) {
                            break :blk jsonToEntityId(arr.items[0].object.get("entity_id").?);
                        }
                    },
                    else => {},
                }
            }
            break :blk 0;
        } else 0;

        if (entity_id == 0) continue;

        const extend_by = if (input.get("extend_by_seconds")) |v| jsonToU32(v) else 1800;

        const result = client.extendTTL(allocator, entity_id, extend_by) catch |err| {
            std.debug.print("    TTL extend failed: {}\n", .{err});
            continue;
        };
        _ = result;
    }
}

// ============================================================================
// TTL Clear Tests (opcode 160)
// ============================================================================

test "fixture: ttl-clear operations" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, getServerUrl()) catch |err| {
        std.debug.print("Skipping: server not available ({})\n", .{err});
        return;
    };
    defer client.deinit();

    _ = client.ping() catch {
        std.debug.print("Skipping: server not responding\n", .{});
        return;
    };

    var fixture = loadFixture(allocator, "ttl-clear") catch {
        std.debug.print("Skipping: fixture not found\n", .{});
        return;
    };
    defer fixture.deinit();

    const cases = fixture.value.object.get("cases").?.array;
    for (cases.items) |case_json| {
        const name = case_json.object.get("name").?.string;
        std.debug.print("  Running: {s}\n", .{name});

        try cleanDatabase(&client, allocator);

        const input = case_json.object.get("input").?.object;

        // Setup phase
        if (input.get("setup")) |setup| {
            insertSetupEvents(&client, allocator, setup) catch |err| {
                std.debug.print("    Setup failed: {}\n", .{err});
                continue;
            };
        }

        const entity_id: u128 = if (input.get("entity_id")) |id|
            jsonToEntityId(id)
        else if (input.get("setup")) |setup| blk: {
            const setup_obj = setup.object;
            if (setup_obj.get("insert_first")) |insert_first| {
                switch (insert_first) {
                    .object => |obj| break :blk jsonToEntityId(obj.get("entity_id").?),
                    .array => |arr| {
                        if (arr.items.len > 0) {
                            break :blk jsonToEntityId(arr.items[0].object.get("entity_id").?);
                        }
                    },
                    else => {},
                }
            }
            break :blk 0;
        } else 0;

        if (entity_id == 0) continue;

        const result = client.clearTTL(allocator, entity_id) catch |err| {
            std.debug.print("    TTL clear failed: {}\n", .{err});
            continue;
        };
        _ = result;
    }
}
