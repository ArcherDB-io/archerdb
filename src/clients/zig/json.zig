// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK - JSON serialization helpers
//!
//! This module provides JSON serialization and deserialization for ArcherDB types.
//! Uses std.json for all operations.

const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

// ============================================================================
// Serialization
// ============================================================================

/// Serialize a single GeoEvent to JSON.
pub fn serializeGeoEvent(allocator: std.mem.Allocator, event: types.GeoEvent) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    // Build JSON object manually for wire format
    const writer = json_string.writer();
    try writer.writeAll("{");

    // entity_id as string (u128 needs special handling)
    try writer.print("\"entity_id\":\"{d}\"", .{event.entity_id});

    try writer.print(",\"lat_nano\":{d}", .{event.lat_nano});
    try writer.print(",\"lon_nano\":{d}", .{event.lon_nano});

    if (event.group_id != 0) {
        try writer.print(",\"group_id\":{d}", .{event.group_id});
    }
    if (event.correlation_id != 0) {
        try writer.print(",\"correlation_id\":\"{d}\"", .{event.correlation_id});
    }
    if (event.user_data != 0) {
        try writer.print(",\"user_data\":\"{d}\"", .{event.user_data});
    }
    if (event.altitude_mm != 0) {
        try writer.print(",\"altitude_mm\":{d}", .{event.altitude_mm});
    }
    if (event.velocity_mms != 0) {
        try writer.print(",\"velocity_mms\":{d}", .{event.velocity_mms});
    }
    if (event.ttl_seconds != 0) {
        try writer.print(",\"ttl_seconds\":{d}", .{event.ttl_seconds});
    }
    if (event.accuracy_mm != 0) {
        try writer.print(",\"accuracy_mm\":{d}", .{event.accuracy_mm});
    }
    if (event.heading_cdeg != 0) {
        try writer.print(",\"heading_cdeg\":{d}", .{event.heading_cdeg});
    }
    if (event.flags != 0) {
        try writer.print(",\"flags\":{d}", .{event.flags});
    }

    try writer.writeAll("}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize multiple GeoEvents to JSON array.
pub fn serializeEvents(allocator: std.mem.Allocator, events_slice: []const types.GeoEvent) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.writeAll("[");

    for (events_slice, 0..) |event, i| {
        if (i > 0) try writer.writeAll(",");

        const event_json = try serializeGeoEvent(allocator, event);
        defer allocator.free(event_json);
        try writer.writeAll(event_json);
    }

    try writer.writeAll("]");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize an insert/upsert request body.
pub fn serializeInsertRequest(allocator: std.mem.Allocator, events_slice: []const types.GeoEvent, mode: []const u8) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.print("{{\"mode\":\"{s}\",\"events\":", .{mode});

    const events_json = try serializeEvents(allocator, events_slice);
    defer allocator.free(events_json);
    try writer.writeAll(events_json);

    try writer.writeAll("}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize a radius query filter to JSON.
pub fn serializeRadiusFilter(allocator: std.mem.Allocator, filter: types.QueryRadiusFilter) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.writeAll("{");
    try writer.print("\"center_lat_nano\":{d}", .{filter.center_lat_nano});
    try writer.print(",\"center_lon_nano\":{d}", .{filter.center_lon_nano});
    try writer.print(",\"radius_mm\":{d}", .{filter.radius_mm});
    try writer.print(",\"limit\":{d}", .{filter.limit});

    if (filter.group_id != 0) {
        try writer.print(",\"group_id\":{d}", .{filter.group_id});
    }
    if (filter.timestamp_min != 0) {
        try writer.print(",\"timestamp_min\":{d}", .{filter.timestamp_min});
    }
    if (filter.timestamp_max != 0) {
        try writer.print(",\"timestamp_max\":{d}", .{filter.timestamp_max});
    }
    if (filter.cursor != 0) {
        try writer.print(",\"cursor\":{d}", .{filter.cursor});
    }

    try writer.writeAll("}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize a polygon query filter to JSON.
pub fn serializePolygonFilter(allocator: std.mem.Allocator, filter: types.QueryPolygonFilter) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.writeAll("{\"vertices\":[");

    // Serialize vertices
    for (filter.vertices, 0..) |vertex, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"lat_nano\":{d},\"lon_nano\":{d}}}", .{ vertex.lat_nano, vertex.lon_nano });
    }
    try writer.writeAll("]");

    // Serialize holes if any
    if (filter.holes.len > 0) {
        try writer.writeAll(",\"holes\":[");
        for (filter.holes, 0..) |hole, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("[");
            for (hole.vertices, 0..) |vertex, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.print("{{\"lat_nano\":{d},\"lon_nano\":{d}}}", .{ vertex.lat_nano, vertex.lon_nano });
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("]");
    }

    try writer.print(",\"limit\":{d}", .{filter.limit});

    if (filter.group_id != 0) {
        try writer.print(",\"group_id\":{d}", .{filter.group_id});
    }
    if (filter.cursor != 0) {
        try writer.print(",\"cursor\":{d}", .{filter.cursor});
    }

    try writer.writeAll("}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize a latest query filter to JSON.
pub fn serializeLatestFilter(allocator: std.mem.Allocator, filter: types.QueryLatestFilter) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.writeAll("{");
    try writer.print("\"limit\":{d}", .{filter.limit});

    if (filter.group_id != 0) {
        try writer.print(",\"group_id\":{d}", .{filter.group_id});
    }
    if (filter.cursor != 0) {
        try writer.print(",\"cursor\":{d}", .{filter.cursor});
    }

    try writer.writeAll("}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize entity IDs for batch query or delete.
pub fn serializeEntityIds(allocator: std.mem.Allocator, entity_ids: []const u128) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.writeAll("{\"entity_ids\":[");

    for (entity_ids, 0..) |id, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("\"{d}\"", .{id});
    }

    try writer.writeAll("]}");

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize TTL set request.
pub fn serializeTtlSetRequest(allocator: std.mem.Allocator, entity_id: u128, ttl_seconds: u32) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.print("{{\"entity_id\":\"{d}\",\"ttl_seconds\":{d}}}", .{ entity_id, ttl_seconds });

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize TTL extend request.
pub fn serializeTtlExtendRequest(allocator: std.mem.Allocator, entity_id: u128, extend_by_seconds: u32) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.print("{{\"entity_id\":\"{d}\",\"extend_by_seconds\":{d}}}", .{ entity_id, extend_by_seconds });

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

/// Serialize TTL clear request.
pub fn serializeTtlClearRequest(allocator: std.mem.Allocator, entity_id: u128) errors.ClientError![]u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    errdefer json_string.deinit();

    const writer = json_string.writer();
    try writer.print("{{\"entity_id\":\"{d}\"}}", .{entity_id});

    return json_string.toOwnedSlice() catch return error.OutOfMemory;
}

// ============================================================================
// Deserialization
// ============================================================================

/// JSON value wrapper for parsing.
const JsonValue = std.json.Value;

/// Parse a u128 from a JSON string or number.
fn parseU128(value: JsonValue) ?u128 {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u128, s, 10) catch null,
        else => null,
    };
}

/// Parse an i64 from a JSON value.
fn parseI64(value: JsonValue) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Parse a u64 from a JSON value.
fn parseU64(value: JsonValue) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// Parse a u32 from a JSON value.
fn parseU32(value: JsonValue) ?u32 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

/// Parse a u16 from a JSON value.
fn parseU16(value: JsonValue) ?u16 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u16)) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u16, s, 10) catch null,
        else => null,
    };
}

/// Parse an i32 from a JSON value.
fn parseI32(value: JsonValue) ?i32 {
    return switch (value) {
        .integer => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(i32, s, 10) catch null,
        else => null,
    };
}

/// Parse a bool from a JSON value.
fn parseBool(value: JsonValue) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// Parse a single GeoEvent from JSON object.
pub fn parseGeoEventFromObject(obj: std.json.ObjectMap) ?types.GeoEvent {
    // Required fields
    const entity_id = parseU128(obj.get("entity_id") orelse return null) orelse return null;
    const lat_nano = parseI64(obj.get("lat_nano") orelse return null) orelse return null;
    const lon_nano = parseI64(obj.get("lon_nano") orelse return null) orelse return null;

    var event = types.GeoEvent{
        .entity_id = entity_id,
        .lat_nano = lat_nano,
        .lon_nano = lon_nano,
    };

    // Optional fields
    if (obj.get("id")) |v| event.id = parseU128(v) orelse 0;
    if (obj.get("correlation_id")) |v| event.correlation_id = parseU128(v) orelse 0;
    if (obj.get("user_data")) |v| event.user_data = parseU128(v) orelse 0;
    if (obj.get("group_id")) |v| event.group_id = parseU64(v) orelse 0;
    if (obj.get("timestamp")) |v| event.timestamp = parseU64(v) orelse 0;
    if (obj.get("altitude_mm")) |v| event.altitude_mm = parseI32(v) orelse 0;
    if (obj.get("velocity_mms")) |v| event.velocity_mms = parseU32(v) orelse 0;
    if (obj.get("ttl_seconds")) |v| event.ttl_seconds = parseU32(v) orelse 0;
    if (obj.get("accuracy_mm")) |v| event.accuracy_mm = parseU32(v) orelse 0;
    if (obj.get("heading_cdeg")) |v| event.heading_cdeg = parseU16(v) orelse 0;
    if (obj.get("flags")) |v| event.flags = parseU16(v) orelse 0;

    return event;
}

/// Parse a GeoEvent from JSON string.
pub fn parseGeoEvent(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.GeoEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    return parseGeoEventFromObject(parsed.value.object) orelse error.JsonParseError;
}

/// Parse multiple GeoEvents from JSON array.
pub fn parseEvents(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!std.ArrayList(types.GeoEvent) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .array) return error.JsonParseError;

    var events = std.ArrayList(types.GeoEvent).init(allocator);
    errdefer events.deinit();

    for (parsed.value.array.items) |item| {
        if (item != .object) return error.JsonParseError;
        const event = parseGeoEventFromObject(item.object) orelse return error.JsonParseError;
        events.append(event) catch return error.OutOfMemory;
    }

    return events;
}

/// Parse insert/upsert response.
pub fn parseInsertResults(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!std.ArrayList(types.InsertResult) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    var results = std.ArrayList(types.InsertResult).init(allocator);
    errdefer results.deinit();

    // Check for results array
    if (parsed.value != .object) return error.JsonParseError;

    const results_value = parsed.value.object.get("results") orelse return results;

    if (results_value != .array) return error.JsonParseError;

    for (results_value.array.items) |item| {
        if (item != .object) return error.JsonParseError;

        const index = parseU32(item.object.get("index") orelse continue) orelse continue;
        const code_int = parseU16(item.object.get("code") orelse continue) orelse continue;

        const code: types.InsertResultCode = @enumFromInt(code_int);

        results.append(.{
            .index = index,
            .code = code,
        }) catch return error.OutOfMemory;
    }

    return results;
}

/// Parse query response (events + pagination).
pub fn parseQueryResult(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.QueryResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    var result = types.QueryResult{
        .events = std.ArrayList(types.GeoEvent).init(allocator),
    };
    errdefer result.events.deinit();

    // Parse events array
    if (parsed.value.object.get("events")) |events_value| {
        if (events_value == .array) {
            for (events_value.array.items) |item| {
                if (item == .object) {
                    if (parseGeoEventFromObject(item.object)) |event| {
                        result.events.append(event) catch return error.OutOfMemory;
                    }
                }
            }
        }
    }

    // Parse pagination fields
    if (parsed.value.object.get("has_more")) |v| result.has_more = parseBool(v) orelse false;
    if (parsed.value.object.get("cursor")) |v| result.cursor = parseU64(v) orelse 0;

    return result;
}

/// Parse delete response.
pub fn parseDeleteResult(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.DeleteResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    var result = types.DeleteResult{};

    if (parsed.value.object.get("deleted_count")) |v| result.deleted_count = parseU32(v) orelse 0;
    if (parsed.value.object.get("not_found_count")) |v| result.not_found_count = parseU32(v) orelse 0;

    return result;
}

/// Parse TTL set response.
pub fn parseTtlSetResponse(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.TtlSetResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    return types.TtlSetResponse{
        .success = parseBool(parsed.value.object.get("success") orelse return error.JsonParseError) orelse false,
        .expiry_ns = parseU64(parsed.value.object.get("expiry_ns") orelse return error.JsonParseError) orelse 0,
        .previous_ttl = parseU32(parsed.value.object.get("previous_ttl") orelse .{ .integer = 0 }) orelse 0,
    };
}

/// Parse TTL extend response.
pub fn parseTtlExtendResponse(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.TtlExtendResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    return types.TtlExtendResponse{
        .success = parseBool(parsed.value.object.get("success") orelse return error.JsonParseError) orelse false,
        .new_expiry_ns = parseU64(parsed.value.object.get("new_expiry_ns") orelse return error.JsonParseError) orelse 0,
        .previous_expiry_ns = parseU64(parsed.value.object.get("previous_expiry_ns") orelse .{ .integer = 0 }) orelse 0,
    };
}

/// Parse TTL clear response.
pub fn parseTtlClearResponse(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.TtlClearResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    return types.TtlClearResponse{
        .success = parseBool(parsed.value.object.get("success") orelse return error.JsonParseError) orelse false,
        .had_ttl = parseBool(parsed.value.object.get("had_ttl") orelse .{ .bool = false }) orelse false,
    };
}

/// Parse status response.
pub fn parseStatusResponse(allocator: std.mem.Allocator, json_data: []const u8) errors.ClientError!types.StatusResponse {
    _ = allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_data, .{}) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JsonParseError;

    return types.StatusResponse{
        .version = "",
        .entity_count = parseU64(parsed.value.object.get("entity_count") orelse .{ .integer = 0 }) orelse 0,
        .ram_bytes = parseU64(parsed.value.object.get("ram_bytes") orelse .{ .integer = 0 }) orelse 0,
        .tombstone_count = parseU64(parsed.value.object.get("tombstone_count") orelse .{ .integer = 0 }) orelse 0,
        .cluster_state = "",
    };
}

/// Parse ping response.
pub fn parsePingResponse(json_data: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_data, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;

    // Check for "pong" response
    if (parsed.value.object.get("pong")) |v| {
        return switch (v) {
            .bool => |b| b,
            .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "pong"),
            else => false,
        };
    }

    // Also accept {"status": "ok"} or similar
    if (parsed.value.object.get("status")) |v| {
        return switch (v) {
            .string => |s| std.mem.eql(u8, s, "ok") or std.mem.eql(u8, s, "pong"),
            else => false,
        };
    }

    return true; // If we got valid JSON back, consider it a successful ping
}

// ============================================================================
// Tests
// ============================================================================

test "serializeGeoEvent basic" {
    const event = types.GeoEvent{
        .entity_id = 12345,
        .lat_nano = 37774900000,
        .lon_nano = -122419400000,
    };

    const json = try serializeGeoEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"entity_id\":\"12345\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lat_nano\":37774900000") != null);
}

test "serializeInsertRequest" {
    const events = [_]types.GeoEvent{
        .{
            .entity_id = 1001,
            .lat_nano = 40712800000,
            .lon_nano = -74006000000,
        },
    };

    const json = try serializeInsertRequest(std.testing.allocator, &events, "insert");
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"mode\":\"insert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"events\":[") != null);
}

test "parseGeoEvent" {
    const json =
        \\{"entity_id":"12345","lat_nano":37774900000,"lon_nano":-122419400000,"group_id":1}
    ;

    const event = try parseGeoEvent(std.testing.allocator, json);
    try std.testing.expectEqual(@as(u128, 12345), event.entity_id);
    try std.testing.expectEqual(@as(i64, 37774900000), event.lat_nano);
    try std.testing.expectEqual(@as(i64, -122419400000), event.lon_nano);
    try std.testing.expectEqual(@as(u64, 1), event.group_id);
}

test "parseQueryResult" {
    const json =
        \\{"events":[{"entity_id":"1001","lat_nano":40712800000,"lon_nano":-74006000000}],"has_more":true,"cursor":12345}
    ;

    var result = try parseQueryResult(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.events.items.len);
    try std.testing.expect(result.has_more);
    try std.testing.expectEqual(@as(u64, 12345), result.cursor);
}

test "parseInsertResults" {
    const json =
        \\{"results":[{"index":0,"code":0},{"index":1,"code":9}]}
    ;

    var results = try parseInsertResults(std.testing.allocator, json);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(types.InsertResultCode.ok, results.items[0].code);
    try std.testing.expectEqual(types.InsertResultCode.lat_out_of_range, results.items[1].code);
}

test "parseDeleteResult" {
    const json =
        \\{"deleted_count":5,"not_found_count":2}
    ;

    const result = try parseDeleteResult(std.testing.allocator, json);
    try std.testing.expectEqual(@as(u32, 5), result.deleted_count);
    try std.testing.expectEqual(@as(u32, 2), result.not_found_count);
}

test "serializeRadiusFilter" {
    const filter = types.QueryRadiusFilter{
        .center_lat_nano = 37774900000,
        .center_lon_nano = -122419400000,
        .radius_mm = 1000000,
        .limit = 100,
    };

    const json = try serializeRadiusFilter(std.testing.allocator, filter);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"radius_mm\":1000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limit\":100") != null);
}
