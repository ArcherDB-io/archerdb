// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Integration tests for ArcherDB. Although the term is not particularly well-defined, here
//! it means a specific thing:
//!
//!   * the test binary itself doesn't contain any code from ArcherDB,
//!   * but it has access to a pre-build `./archerdb` binary.
//!
//! All the testing is done through interacting with a separate ArcherDB process.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;
const vsr = @import("vsr.zig");

const Shell = @import("./shell.zig");
const TmpArcherDB = @import("./testing/tmp_archerdb.zig");

const stdx = @import("stdx");
const ratio = stdx.PRNG.ratio;
const arch_client = @import("clients/c/arch_client.zig");
const constants = @import("constants.zig");
const StateError = @import("error_codes.zig").StateError;
const tb = vsr.archerdb;

const vortex_exe: []const u8 = @import("test_options").vortex_exe;
const archerdb: []const u8 = @import("test_options").archerdb_exe;
const archerdb_past: []const u8 = @import("test_options").archerdb_exe_past;
const skip_upgrade: bool = @import("test_options").skip_upgrade;

comptime {
    _ = @import("clients/c/arch_client_header_test.zig");
    _ = @import("testing/backup_restore_test.zig");
    _ = @import("testing/encryption_test.zig");
    _ = @import("testing/failover_test.zig");
}

fn pickFreePort() !u16 {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    try std.posix.bind(fd, &address.any, address.getOsSockLen());

    var bound_addr: std.posix.sockaddr = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(fd, &bound_addr, &bound_addr_len);

    const addr_in: *align(1) const std.posix.sockaddr.in = @ptrCast(&bound_addr);
    return std.mem.bigToNative(u16, addr_in.port);
}

fn fetchMetrics(allocator: std.mem.Allocator, port: u16) ![]u8 {
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        var stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch |err| {
            if (attempts + 1 >= 10) return err;
            std.time.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer stream.close();

        try stream.writer().writeAll(
            "GET /metrics HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
        );

        return try stream.reader().readAllAlloc(allocator, 1024 * 1024);
    }

    return error.MetricsUnavailable;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;

    const preview_len = @min(haystack.len, 2048);
    std.debug.print(
        "missing metrics substring '{s}' (response_len={d}) preview:\n{s}\n",
        .{ needle, haystack.len, haystack[0..preview_len] },
    );
    return error.TestUnexpectedResult;
}

fn childExitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: arch_client.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply_buffer: [request_size_max]u8 = undefined,
        reply: ?struct {
            arch_context: usize,
            arch_packet: *arch_client.Packet,
            timestamp: u64,
            result: ?[]const u8,
            result_len: u32,
        } = null,

        pub fn on_complete(
            arch_context: usize,
            arch_packet: *arch_client.Packet,
            timestamp: u64,
            result_ptr: ?[*]const u8,
            result_len: u32,
        ) callconv(.c) void {
            var self: *RequestContext = @ptrCast(@alignCast(arch_packet.*.user_data.?));
            defer self.completion.complete();

            const result_slice: ?[]const u8 = if (result_ptr != null and result_len > 0) blk: {
                assert(result_len <= request_size_max);
                const readable: [*]const u8 = @ptrCast(result_ptr.?);
                const buffer = self.reply_buffer[0..result_len];
                stdx.copy_disjoint(.exact, u8, buffer, readable[0..result_len]);
                break :blk buffer;
            } else null;

            self.reply = .{
                .arch_context = arch_context,
                .arch_packet = arch_packet,
                .timestamp = timestamp,
                .result = result_slice,
                .result_len = result_len,
            };
        }
    };
}

const Completion = struct {
    pending: usize,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn complete(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        assert(self.pending > 0);
        self.pending -= 1;
        self.cond.signal();
    }

    pub fn wait_pending(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending > 0) {
            self.cond.wait(&self.mutex);
        }
    }

    pub fn wait_pending_timeout(self: *Completion, timeout_ns: u64) !void {
        const start_time = std.time.nanoTimestamp();
        while (true) {
            self.mutex.lock();
            const pending = self.pending;
            self.mutex.unlock();

            if (pending == 0) return;

            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            if (elapsed_ns > @as(i128, @intCast(timeout_ns))) {
                return error.Timeout;
            }

            std.time.sleep(5 * std.time.ns_per_ms);
        }
    }
};

fn degrees_to_nano(degrees: f64) i64 {
    return @intFromFloat(@round(degrees * 1_000_000_000.0));
}

fn make_event(entity_id: u128, latitude: f64, longitude: f64) tb.GeoEvent {
    var event = std.mem.zeroes(tb.GeoEvent);
    event.entity_id = entity_id;
    event.lat_nano = degrees_to_nano(latitude);
    event.lon_nano = degrees_to_nano(longitude);
    event.group_id = 1;
    return event;
}

fn send_request(
    client: *arch_client.ClientInterface,
    completion: *Completion,
    request: anytype,
    operation: arch_client.Operation,
    payload: []const u8,
) ![]const u8 {
    const testing = std.testing;

    completion.pending = 1;
    request.reply = null;

    assert(payload.len <= request.sent_data.len);
    stdx.copy_disjoint(.exact, u8, request.sent_data[0..payload.len], payload);
    request.sent_data_size = @intCast(payload.len);

    const packet = &request.packet;
    packet.operation = @intFromEnum(operation);
    packet.user_data = request;
    packet.data = &request.sent_data;
    packet.data_size = request.sent_data_size;
    packet.user_tag = 0;
    packet.status = .ok;

    try client.submit(packet);
    try completion.wait_pending_timeout(5 * std.time.ns_per_s);

    try testing.expectEqual(arch_client.PacketStatus.ok, packet.status);
    try testing.expect(request.reply != null);

    const reply = request.reply.?;
    if (reply.result_len == 0) return &[_]u8{};
    try testing.expect(reply.result != null);
    return reply.result.?;
}

fn read_struct(comptime T: type, bytes: []const u8) T {
    assert(bytes.len >= @sizeOf(T));
    var value: T = undefined;
    stdx.copy_disjoint(.exact, u8, std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

test "geo operations integration" {
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    var events = [_]tb.GeoEvent{
        make_event(1001, 37.7749, -122.4194),
        make_event(1002, 37.7750, -122.4195),
    };

    const insert_reply = try send_request(
        &client,
        &completion,
        request,
        .insert_events,
        std.mem.sliceAsBytes(&events),
    );
    {
        const result_size = @sizeOf(tb.InsertGeoEventsResult);
        try testing.expectEqual(@as(usize, 0), insert_reply.len % result_size);
        var offset: usize = 0;
        while (offset < insert_reply.len) : (offset += result_size) {
            const result = read_struct(
                tb.InsertGeoEventsResult,
                insert_reply[offset .. offset + result_size],
            );
            try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
        }
    }

    var uuid_filter = tb.QueryUuidFilter{
        .entity_id = events[0].entity_id,
    };
    const uuid_reply = try send_request(
        &client,
        &completion,
        request,
        .query_uuid,
        std.mem.asBytes(&uuid_filter),
    );
    {
        try testing.expect(uuid_reply.len >= @sizeOf(tb.QueryUuidResponse));
        const header = read_struct(
            tb.QueryUuidResponse,
            uuid_reply[0..@sizeOf(tb.QueryUuidResponse)],
        );
        try testing.expectEqual(@as(u8, 0), header.status);
        const event = read_struct(
            tb.GeoEvent,
            uuid_reply[@sizeOf(tb.QueryUuidResponse)..][0..@sizeOf(tb.GeoEvent)],
        );
        try testing.expectEqual(events[0].entity_id, event.entity_id);
    }

    var latest_filter = tb.QueryLatestFilter{
        .limit = 10,
        .group_id = 0,
        .cursor_timestamp = 0,
    };
    const latest_reply = try send_request(
        &client,
        &completion,
        request,
        .query_latest,
        std.mem.asBytes(&latest_filter),
    );
    {
        try testing.expect(latest_reply.len >= @sizeOf(tb.QueryResponse));
        const header = read_struct(
            tb.QueryResponse,
            latest_reply[0..@sizeOf(tb.QueryResponse)],
        );
        try testing.expect(header.error_status() == null);
        try testing.expect(header.count > 0);
        const events_bytes = latest_reply[@sizeOf(tb.QueryResponse)..];
        const event_count: usize = @intCast(header.count);
        try testing.expect(events_bytes.len >= event_count * @sizeOf(tb.GeoEvent));
    }

    var radius_filter = tb.QueryRadiusFilter{
        .center_lat_nano = events[0].lat_nano,
        .center_lon_nano = events[0].lon_nano,
        .radius_mm = 2_000_000,
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };
    const radius_reply = try send_request(
        &client,
        &completion,
        request,
        .query_radius,
        std.mem.asBytes(&radius_filter),
    );
    {
        try testing.expect(radius_reply.len >= @sizeOf(tb.QueryResponse));
        const header = read_struct(
            tb.QueryResponse,
            radius_reply[0..@sizeOf(tb.QueryResponse)],
        );
        try testing.expect(header.error_status() == null);
        try testing.expect(header.count > 0);
    }

    var delete_ids = [_]u128{events[0].entity_id};
    const delete_reply = try send_request(
        &client,
        &completion,
        request,
        .delete_entities,
        std.mem.sliceAsBytes(&delete_ids),
    );
    {
        const result_size = @sizeOf(tb.DeleteEntitiesResult);
        try testing.expectEqual(@as(usize, result_size), delete_reply.len);
        const result = read_struct(tb.DeleteEntitiesResult, delete_reply);
        try testing.expectEqual(tb.DeleteEntityResult.ok, result.result);
    }

    const uuid_after_delete = try send_request(
        &client,
        &completion,
        request,
        .query_uuid,
        std.mem.asBytes(&uuid_filter),
    );
    {
        try testing.expect(uuid_after_delete.len >= @sizeOf(tb.QueryUuidResponse));
        const header = read_struct(
            tb.QueryUuidResponse,
            uuid_after_delete[0..@sizeOf(tb.QueryUuidResponse)],
        );
        try testing.expectEqual(
            @as(u8, @intCast(@intFromEnum(StateError.entity_not_found))),
            header.status,
        );
    }
}

test "integration: solo ttl insert immediate queries stay stable" {
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    for (0..16) |i| {
        var event = make_event(10_000 + @as(u128, @intCast(i)), 37.7749, -122.4194);
        event.ttl_seconds = 60;

        const insert_reply = try send_request(
            &client,
            &completion,
            request,
            .insert_events,
            std.mem.asBytes(&event),
        );
        {
            try testing.expectEqual(@as(usize, @sizeOf(tb.InsertGeoEventsResult)), insert_reply.len);
            const result = read_struct(tb.InsertGeoEventsResult, insert_reply);
            try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
        }

        var uuid_filter = tb.QueryUuidFilter{ .entity_id = event.entity_id };
        const uuid_reply = try send_request(
            &client,
            &completion,
            request,
            .query_uuid,
            std.mem.asBytes(&uuid_filter),
        );
        {
            try testing.expect(uuid_reply.len >= @sizeOf(tb.QueryUuidResponse) + @sizeOf(tb.GeoEvent));
            const header = read_struct(
                tb.QueryUuidResponse,
                uuid_reply[0..@sizeOf(tb.QueryUuidResponse)],
            );
            try testing.expectEqual(@as(u8, 0), header.status);
            const found = read_struct(
                tb.GeoEvent,
                uuid_reply[@sizeOf(tb.QueryUuidResponse)..][0..@sizeOf(tb.GeoEvent)],
            );
            try testing.expectEqual(event.entity_id, found.entity_id);
        }

        var radius_filter = tb.QueryRadiusFilter{
            .center_lat_nano = event.lat_nano,
            .center_lon_nano = event.lon_nano,
            .radius_mm = 2_000_000,
            .limit = 64,
            .timestamp_min = 0,
            .timestamp_max = 0,
            .group_id = event.group_id,
        };
        const radius_reply = try send_request(
            &client,
            &completion,
            request,
            .query_radius,
            std.mem.asBytes(&radius_filter),
        );
        {
            try testing.expect(radius_reply.len >= @sizeOf(tb.QueryResponse));
            const header = read_struct(
                tb.QueryResponse,
                radius_reply[0..@sizeOf(tb.QueryResponse)],
            );
            try testing.expect(header.error_status() == null);
            try testing.expect(header.count > 0);

            const events_bytes = radius_reply[@sizeOf(tb.QueryResponse)..];
            const event_count: usize = @intCast(header.count);
            try testing.expect(events_bytes.len >= event_count * @sizeOf(tb.GeoEvent));

            var found_entity = false;
            var offset: usize = 0;
            while (offset < event_count * @sizeOf(tb.GeoEvent)) : (offset += @sizeOf(tb.GeoEvent)) {
                const found = read_struct(
                    tb.GeoEvent,
                    events_bytes[offset .. offset + @sizeOf(tb.GeoEvent)],
                );
                if (found.entity_id == event.entity_id) {
                    found_entity = true;
                    break;
                }
            }
            try testing.expect(found_entity);
        }
    }
}

test "integration: geospatial batch insert and query" {
    // INT-01: Test batch inserts and verify all events are queryable
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    // Create events spread across different locations
    // Use 20 events to fit within lite config's smaller message_body_size
    const batch_size = 20;
    var events: [batch_size]tb.GeoEvent = undefined;
    for (0..batch_size) |i| {
        // Distribute events across a grid around San Francisco
        const lat_offset: f64 = @as(f64, @floatFromInt(i / 10)) * 0.01;
        const lon_offset: f64 = @as(f64, @floatFromInt(i % 10)) * 0.01;
        events[i] = make_event(
            @as(u128, 2000) + @as(u128, @intCast(i)),
            37.7749 + lat_offset,
            -122.4194 + lon_offset,
        );
    }

    // Batch insert all events
    const insert_reply = try send_request(
        &client,
        &completion,
        request,
        .insert_events,
        std.mem.sliceAsBytes(&events),
    );
    {
        const result_size = @sizeOf(tb.InsertGeoEventsResult);
        try testing.expectEqual(@as(usize, batch_size * result_size), insert_reply.len);
        var offset: usize = 0;
        var success_count: usize = 0;
        while (offset < insert_reply.len) : (offset += result_size) {
            const result = read_struct(
                tb.InsertGeoEventsResult,
                insert_reply[offset .. offset + result_size],
            );
            if (result.result == tb.InsertGeoEventResult.ok) {
                success_count += 1;
            }
        }
        try testing.expectEqual(batch_size, success_count);
    }

    // Verify events are queryable via UUID
    for (0..5) |i| {
        var uuid_filter = tb.QueryUuidFilter{
            .entity_id = events[i].entity_id,
        };
        const uuid_reply = try send_request(
            &client,
            &completion,
            request,
            .query_uuid,
            std.mem.asBytes(&uuid_filter),
        );
        try testing.expect(uuid_reply.len >= @sizeOf(tb.QueryUuidResponse));
        const header = read_struct(
            tb.QueryUuidResponse,
            uuid_reply[0..@sizeOf(tb.QueryUuidResponse)],
        );
        try testing.expectEqual(@as(u8, 0), header.status);
    }

    // Query all events via radius (large radius to capture all)
    // Event coords: lat 37.7749 to 37.7849, lon -122.4194 to -122.3194
    // Query center: lat 37.82, lon -122.37, radius 20km
    var radius_filter = tb.QueryRadiusFilter{
        .center_lat_nano = degrees_to_nano(37.82), // Center of grid
        .center_lon_nano = degrees_to_nano(-122.37),
        .radius_mm = 20_000_000, // 20km
        .limit = 200,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 1, // Match the group_id used in make_event
    };
    const radius_reply = try send_request(
        &client,
        &completion,
        request,
        .query_radius,
        std.mem.asBytes(&radius_filter),
    );
    {
        try testing.expect(radius_reply.len >= @sizeOf(tb.QueryResponse));
        const header = read_struct(
            tb.QueryResponse,
            radius_reply[0..@sizeOf(tb.QueryResponse)],
        );
        try testing.expect(header.error_status() == null);
        // Should find most/all of our batch events (adjusted for lite config batch size)
        try testing.expect(header.count >= batch_size / 2);
    }
}

test "integration: geospatial polygon query" {
    // INT-01: Test polygon queries with bounding box
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    // Insert events at known locations
    var events = [_]tb.GeoEvent{
        make_event(3001, 37.7749, -122.4194), // San Francisco
        make_event(3002, 37.7850, -122.4094), // Slightly north/east
        make_event(3003, 40.7128, -74.0060), // New York (outside polygon)
    };

    const insert_reply = try send_request(
        &client,
        &completion,
        request,
        .insert_events,
        std.mem.sliceAsBytes(&events),
    );
    {
        const result_size = @sizeOf(tb.InsertGeoEventsResult);
        try testing.expectEqual(@as(usize, 3 * result_size), insert_reply.len);
    }

    // Create polygon bounding box around San Francisco
    // Counter-clockwise winding (GeoJSON convention)
    var polygon_filter = tb.QueryPolygonFilter{
        .vertex_count = 4,
        .hole_count = 0,
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };
    const vertices = [_]tb.PolygonVertex{
        .{ .lat_nano = degrees_to_nano(37.70), .lon_nano = degrees_to_nano(-122.50) },
        .{ .lat_nano = degrees_to_nano(37.70), .lon_nano = degrees_to_nano(-122.35) },
        .{ .lat_nano = degrees_to_nano(37.85), .lon_nano = degrees_to_nano(-122.35) },
        .{ .lat_nano = degrees_to_nano(37.85), .lon_nano = degrees_to_nano(-122.50) },
    };

    // Build request body: filter header + vertices
    var polygon_request_data: [@sizeOf(tb.QueryPolygonFilter) + @sizeOf(@TypeOf(vertices))]u8 = undefined;
    stdx.copy_disjoint(.exact, u8, polygon_request_data[0..@sizeOf(tb.QueryPolygonFilter)], std.mem.asBytes(&polygon_filter));
    stdx.copy_disjoint(.exact, u8, polygon_request_data[@sizeOf(tb.QueryPolygonFilter)..], std.mem.sliceAsBytes(&vertices));

    const polygon_reply = try send_request(
        &client,
        &completion,
        request,
        .query_polygon,
        &polygon_request_data,
    );
    {
        try testing.expect(polygon_reply.len >= @sizeOf(tb.QueryResponse));
        const header = read_struct(
            tb.QueryResponse,
            polygon_reply[0..@sizeOf(tb.QueryResponse)],
        );
        try testing.expect(header.error_status() == null);
        // Should find 2 SF events, not the NY event
        try testing.expect(header.count >= 1);
        try testing.expect(header.count <= 3);
    }
}

test "integration: geospatial edge cases" {
    // INT-01: Test edge cases - antimeridian, poles, empty results
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    // Test 1: Insert near antimeridian (Fiji/Tonga region)
    var antimeridian_events = [_]tb.GeoEvent{
        make_event(4001, -17.7134, 178.065), // Fiji (west of antimeridian)
        make_event(4002, -21.2089, -175.198), // Tonga (east of antimeridian)
    };
    _ = try send_request(
        &client,
        &completion,
        request,
        .insert_events,
        std.mem.sliceAsBytes(&antimeridian_events),
    );

    // Verify antimeridian events are queryable
    var uuid_filter = tb.QueryUuidFilter{ .entity_id = 4001 };
    const uuid_reply = try send_request(
        &client,
        &completion,
        request,
        .query_uuid,
        std.mem.asBytes(&uuid_filter),
    );
    {
        const header = read_struct(tb.QueryUuidResponse, uuid_reply[0..@sizeOf(tb.QueryUuidResponse)]);
        try testing.expectEqual(@as(u8, 0), header.status);
    }

    // Test 2: Empty query result (search in Antarctica)
    var empty_radius_filter = tb.QueryRadiusFilter{
        .center_lat_nano = degrees_to_nano(-85.0), // Antarctica
        .center_lon_nano = degrees_to_nano(0.0),
        .radius_mm = 1_000_000, // 1km
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 0,
    };
    const empty_reply = try send_request(
        &client,
        &completion,
        request,
        .query_radius,
        std.mem.asBytes(&empty_radius_filter),
    );
    {
        try testing.expect(empty_reply.len >= @sizeOf(tb.QueryResponse));
        const header = read_struct(tb.QueryResponse, empty_reply[0..@sizeOf(tb.QueryResponse)]);
        try testing.expect(header.error_status() == null);
        // Should be empty - no events in Antarctica
        try testing.expectEqual(@as(u32, 0), header.count);
    }

    // Test 3: Query non-existent UUID
    var nonexistent_filter = tb.QueryUuidFilter{ .entity_id = 0xDEADBEEF };
    const nonexistent_reply = try send_request(
        &client,
        &completion,
        request,
        .query_uuid,
        std.mem.asBytes(&nonexistent_filter),
    );
    {
        const header = read_struct(tb.QueryUuidResponse, nonexistent_reply[0..@sizeOf(tb.QueryUuidResponse)]);
        try testing.expectEqual(
            @as(u8, @intCast(@intFromEnum(StateError.entity_not_found))),
            header.status,
        );
    }
}

test "integration: geospatial multi-region distribution" {
    // INT-01: Test events distributed across multiple continents
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
    });
    defer tmp_archerdb.deinit(testing.allocator);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    // Insert events across multiple continents
    var global_events = [_]tb.GeoEvent{
        make_event(5001, 37.7749, -122.4194), // San Francisco, USA
        make_event(5002, 40.7128, -74.0060), // New York, USA
        make_event(5003, 51.5074, -0.1278), // London, UK
        make_event(5004, 48.8566, 2.3522), // Paris, France
        make_event(5005, 35.6762, 139.6503), // Tokyo, Japan
        make_event(5006, -33.8688, 151.2093), // Sydney, Australia
        make_event(5007, -23.5505, -46.6333), // Sao Paulo, Brazil
        make_event(5008, 55.7558, 37.6173), // Moscow, Russia
    };

    _ = try send_request(
        &client,
        &completion,
        request,
        .insert_events,
        std.mem.sliceAsBytes(&global_events),
    );

    // Verify each event is queryable
    for (global_events) |event| {
        var uuid_filter = tb.QueryUuidFilter{ .entity_id = event.entity_id };
        const uuid_reply = try send_request(
            &client,
            &completion,
            request,
            .query_uuid,
            std.mem.asBytes(&uuid_filter),
        );
        const header = read_struct(tb.QueryUuidResponse, uuid_reply[0..@sizeOf(tb.QueryUuidResponse)]);
        try testing.expectEqual(@as(u8, 0), header.status);
    }

    // Query around Tokyo - should find only Tokyo event
    var tokyo_filter = tb.QueryRadiusFilter{
        .center_lat_nano = degrees_to_nano(35.6762),
        .center_lon_nano = degrees_to_nano(139.6503),
        .radius_mm = 50_000_000, // 50km
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 1, // Match group_id used in make_event
    };
    const tokyo_reply = try send_request(
        &client,
        &completion,
        request,
        .query_radius,
        std.mem.asBytes(&tokyo_filter),
    );
    {
        const header = read_struct(tb.QueryResponse, tokyo_reply[0..@sizeOf(tb.QueryResponse)]);
        try testing.expect(header.error_status() == null);
        try testing.expectEqual(@as(u32, 1), header.count);
    }

    // Query around Europe - should find London and Paris
    var europe_filter = tb.QueryRadiusFilter{
        .center_lat_nano = degrees_to_nano(50.0),
        .center_lon_nano = degrees_to_nano(1.0),
        .radius_mm = 500_000_000, // 500km
        .limit = 10,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .group_id = 1, // Match group_id used in make_event
    };
    const europe_reply = try send_request(
        &client,
        &completion,
        request,
        .query_radius,
        std.mem.asBytes(&europe_filter),
    );
    {
        const header = read_struct(tb.QueryResponse, europe_reply[0..@sizeOf(tb.QueryResponse)]);
        try testing.expect(header.error_status() == null);
        try testing.expect(header.count >= 2); // London and Paris
    }
}

test "benchmark/inspect smoke" {
    const data_file = data_file: {
        var random_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const random_suffix: [8]u8 = std.fmt.bytesToHex(random_bytes, .lower);
        break :data_file "0_0-" ++ random_suffix ++ ".archerdb.benchmark";
    };
    defer std.fs.cwd().deleteFile(data_file) catch {};

    const trace_file = data_file ++ ".json";
    defer std.fs.cwd().deleteFile(trace_file) catch {};

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{archerdb} benchmark" ++
            " --event-count=10_000" ++
            " --event-batch-size=10" ++
            " --validate" ++
            " --trace={trace_file}" ++
            " --statsd=127.0.0.1:65535" ++
            " --file={data_file}",
        .{
            .archerdb = archerdb,
            .trace_file = trace_file,
            .data_file = data_file,
        },
    );

    inline for (.{
        "{archerdb} inspect constants",
        "{archerdb} inspect metrics",
    }) |command| {
        log.debug("{s}", .{command});
        try shell.exec(command, .{ .archerdb = archerdb });
    }

    inline for (.{
        "{archerdb} inspect superblock              {path}",
        "{archerdb} inspect wal --slot=0            {path}",
        "{archerdb} inspect replies                 {path}",
        "{archerdb} inspect replies --slot=0        {path}",
        "{archerdb} inspect grid                    {path}",
        "{archerdb} inspect manifest                {path}",
        "{archerdb} inspect tables --tree=geo_events {path}",
        "{archerdb} inspect integrity               {path}",
    }) |command| {
        log.debug("{s}", .{command});

        try shell.exec(
            command,
            .{ .archerdb = archerdb, .path = data_file },
        );
    }

    // Corrupt the data file, and ensure the integrity check fails. Use the WAL headers zone so the
    // check stays fast even when the grid is large.
    const offset = vsr.Zone.wal_headers.start();

    {
        const file = try std.fs.cwd().openFile(data_file, .{ .mode = .read_write });
        defer file.close();

        var prng = stdx.PRNG.from_seed_testing();
        var random_bytes: [256]u8 = undefined;
        prng.fill(&random_bytes);

        try file.pwriteAll(&random_bytes, offset);
    }

    // `shell.exec` assumes that success is a zero exit code; but in this case the test expects
    // corruption to be found and wants to assert a non-zero exit code.
    var child = std.process.Child.init(
        &.{ archerdb, "inspect", "integrity", "--skip-client-replies", "--skip-grid", data_file },
        std.testing.allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited, .Signal => |value| try std.testing.expect(value != 0),
        else => unreachable,
    }
}

test "metrics endpoint includes index health metrics" {
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(std.testing.allocator);

    const response = try fetchMetrics(std.testing.allocator, metrics_port);
    defer std.testing.allocator.free(response);

    try expectContains(response, "archerdb_index_entries_total");
    try expectContains(response, "archerdb_index_memory_bytes");
    try expectContains(response, "archerdb_index_lookup_latency_seconds");
}

test "info command includes sharding strategy" {
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    const tmp_dir = try shell.create_tmp_dir();
    defer shell.cwd.deleteTree(tmp_dir) catch {};

    const data_file = try shell.fmt("{s}/info-test.archerdb", .{tmp_dir});

    try shell.exec(
        "{archerdb} format --cluster=1 --replica=0 --replica-count=1 " ++
            "--sharding-strategy=jump_hash {data_file}",
        .{ .archerdb = archerdb, .data_file = data_file },
    );

    const output = try shell.exec_stdout("{archerdb} info {data_file}", .{
        .archerdb = archerdb,
        .data_file = data_file,
    });

    try std.testing.expect(std.mem.indexOf(u8, output, "Sharding Strategy: jump_hash") != null);
}

test "metrics endpoint includes sharding strategy and query shard histograms" {
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(std.testing.allocator);

    const response = try fetchMetrics(std.testing.allocator, metrics_port);
    defer std.testing.allocator.free(response);

    try expectContains(response, "archerdb_sharding_strategy");
    try expectContains(response, "archerdb_shard_strategy");
    try expectContains(response, "archerdb_shard_lookup_duration_seconds");
    try expectContains(response, "archerdb_query_shards_queried");
}

test "integration: index resize control reports live status" {
    const testing = std.testing;
    const RequestContext = RequestContextType(constants.message_body_size_max);
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .index_resize_batch_size = 1,
    });
    defer tmp_archerdb.deinit(testing.allocator);
    errdefer tmp_archerdb.log_stderr();

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        testing.allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        42,
        RequestContext.on_complete,
    );
    var client_active = true;
    defer if (client_active) client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try testing.allocator.create(RequestContext);
    defer testing.allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const event_count: usize = 2_000;
    const batch_size: usize = 20;
    var events = try testing.allocator.alloc(tb.GeoEvent, batch_size);
    defer testing.allocator.free(events);

    var next_entity_id: u128 = 10_000;
    var remaining: usize = event_count;
    while (remaining > 0) {
        const count: usize = @min(remaining, batch_size);
        for (events[0..count], 0..) |*event, i| {
            const ordinal: f64 = @floatFromInt(i + @as(usize, @intCast(next_entity_id - 10_000)));
            event.* = make_event(
                next_entity_id + i,
                37.0 + (ordinal * 0.00001),
                -122.0 - (ordinal * 0.00001),
            );
        }

        const insert_reply = try send_request(
            &client,
            &completion,
            request,
            .insert_events,
            std.mem.sliceAsBytes(events[0..count]),
        );

        const result_size = @sizeOf(tb.InsertGeoEventsResult);
        try testing.expectEqual(@as(usize, 0), insert_reply.len % result_size);
        var offset: usize = 0;
        while (offset < insert_reply.len) : (offset += result_size) {
            const result = read_struct(
                tb.InsertGeoEventsResult,
                insert_reply[offset .. offset + result_size],
            );
            try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
        }

        next_entity_id += count;
        remaining -= count;
    }

    try client.deinit();
    client_active = false;

    const shell = try Shell.create(testing.allocator);
    defer shell.destroy();

    const address = try std.fmt.allocPrint(testing.allocator, "127.0.0.1:{d}", .{
        tmp_archerdb.port,
    });
    defer testing.allocator.free(address);

    const target_capacity: u64 = 2_000_000;
    const start_output = try shell.exec_stdout(
        "{archerdb} index resize --addresses={address} --cluster=0 " ++
            "--metrics-port={metrics_port} --new-capacity={target_capacity} --format=json",
        .{
            .archerdb = archerdb,
            .address = address,
            .metrics_port = metrics_port,
            .target_capacity = target_capacity,
        },
    );
    try expectContains(start_output, "\"accepted_nodes\":1");
    try expectContains(start_output, "\"target_capacity\":2000000");

    const status_deadline = std.time.nanoTimestamp() + (10 * std.time.ns_per_s);
    var saw_active_resize = false;
    var last_status_stdout: []const u8 = "";
    var last_status_stderr: []const u8 = "";
    while (std.time.nanoTimestamp() < status_deadline) {
        const result = try shell.exec_raw(
            "{archerdb} index resize --addresses={address} --cluster=0 --format=json status",
            .{
                .archerdb = archerdb,
                .address = address,
            },
        );
        last_status_stdout = result.stdout;
        last_status_stderr = result.stderr;

        if (childExitedOk(result.term) and
            std.mem.indexOf(u8, result.stdout, "\"active_nodes\":1") != null and
            (std.mem.indexOf(u8, result.stdout, "\"index_resize_status\":\"in_progress\"") != null or
                std.mem.indexOf(u8, result.stdout, "\"index_resize_status\":\"completing\"") != null))
        {
            saw_active_resize = true;
            break;
        }

        std.time.sleep(50 * std.time.ns_per_ms);
    }
    if (!saw_active_resize) {
        const metrics_snapshot = try fetchMetrics(testing.allocator, metrics_port);
        defer testing.allocator.free(metrics_snapshot);
        std.debug.print(
            "index resize status never became active\nstdout:\n{s}\nstderr:\n{s}\nmetrics preview:\n{s}\n",
            .{
                last_status_stdout,
                last_status_stderr,
                metrics_snapshot[0..@min(metrics_snapshot.len, 2048)],
            },
        );
    }
    try testing.expect(saw_active_resize);

    const abort_output = try shell.exec_stdout(
        "{archerdb} index resize --addresses={address} --cluster=0 " ++
            "--metrics-port={metrics_port} --format=json abort",
        .{
            .archerdb = archerdb,
            .address = address,
            .metrics_port = metrics_port,
        },
    );
    try expectContains(abort_output, "\"accepted_nodes\":1");

    const final_deadline = std.time.nanoTimestamp() + (10 * std.time.ns_per_s);
    var saw_post_abort_status = false;
    while (std.time.nanoTimestamp() < final_deadline) {
        const result = try shell.exec_raw(
            "{archerdb} index resize --addresses={address} --cluster=0 --format=json status",
            .{
                .archerdb = archerdb,
                .address = address,
            },
        );

        if (childExitedOk(result.term) and
            std.mem.indexOf(u8, result.stdout, "\"active_nodes\":1") != null and
            (std.mem.indexOf(u8, result.stdout, "\"index_resize_status\":\"idle\"") != null or
                std.mem.indexOf(u8, result.stdout, "\"index_resize_status\":\"aborted\"") != null or
                std.mem.indexOf(u8, result.stdout, "\"index_resize_status\":\"completing\"") != null))
        {
            saw_post_abort_status = true;
            break;
        }

        std.time.sleep(50 * std.time.ns_per_ms);
    }
    try testing.expect(saw_post_abort_status);
}

test "integration: upgrade status emits json and live start fails closed" {
    const testing = std.testing;
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(testing.allocator);
    errdefer tmp_archerdb.log_stderr();

    const shell = try Shell.create(testing.allocator);
    defer shell.destroy();

    const address = try std.fmt.allocPrint(testing.allocator, "127.0.0.1:{d}", .{
        tmp_archerdb.port,
    });
    defer testing.allocator.free(address);

    const status_result = try shell.exec_raw(
        "{archerdb} upgrade status --addresses={address} --metrics-port={metrics_port} --format=json",
        .{
            .archerdb = archerdb,
            .address = address,
            .metrics_port = metrics_port,
        },
    );
    try testing.expect(childExitedOk(status_result.term));
    try testing.expect(std.mem.indexOf(u8, status_result.stdout, "\"state\":\"not_started\"") != null);
    try testing.expect(std.mem.indexOf(u8, status_result.stdout, "\"has_quorum\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status_result.stdout, "\"replicas\":[") != null);

    const start_result = try shell.exec_raw(
        "{archerdb} upgrade start --addresses={address} --metrics-port={metrics_port} " ++
            "--target-version=9.9.9 --format=json",
        .{
            .archerdb = archerdb,
            .address = address,
            .metrics_port = metrics_port,
        },
    );
    try testing.expect(!childExitedOk(start_result.term));
    try testing.expect(
        std.mem.indexOf(u8, start_result.stdout, "\"error\":\"not_implemented\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, start_result.stdout, "\"feature\":\"upgrade start\"") != null,
    );
}

test "integration: cluster status reuses sync clients without crashing" {
    const testing = std.testing;
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(testing.allocator);
    errdefer tmp_archerdb.log_stderr();

    const shell = try Shell.create(testing.allocator);
    defer shell.destroy();

    const address = try std.fmt.allocPrint(testing.allocator, "127.0.0.1:{d}", .{
        tmp_archerdb.port,
    });
    defer testing.allocator.free(address);

    const status_result = try shell.exec_raw(
        "{archerdb} cluster status --addresses={address},{address} --cluster=0 --format=json",
        .{
            .archerdb = archerdb,
            .address = address,
        },
    );
    try testing.expect(childExitedOk(status_result.term));
    try testing.expect(std.mem.indexOf(u8, status_result.stdout, "\"cluster\":0") != null);
    try testing.expect(std.mem.indexOf(u8, status_result.stdout, "\"nodes\":[") != null);
}

test "help/version smoke" {
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    // The substring is chosen to be mostly stable, but from (near) the end of the output, to catch
    // a missed buffer flush.
    inline for (.{
        .{ .command = "{archerdb} --help", .substring = "archerdb repl" },
        .{ .command = "{archerdb} inspect --help", .substring = "tables --tree" },
        .{ .command = "{archerdb} version", .substring = "ArcherDB version" },
        .{ .command = "{archerdb} version --verbose", .substring = "process.aof_recovery=" },
    }) |check| {
        const output = try shell.exec_stdout(check.command, .{ .archerdb = archerdb });
        try std.testing.expect(output.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, output, check.substring) != null);
    }
}

test "repl smoke" {
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    const stdout, const stderr = try shell.exec_stdout_stderr(
        "{archerdb} repl --cluster=0 --addresses=127.0.0.1:3001 --command=STATUS",
        .{ .archerdb = archerdb },
    );
    _ = stderr;
    // Verify REPL outputs cluster status information
    try expectContains(stdout, "Cluster Status");
}

test "in-place upgrade" {
    // Smoke test that in-place upgrades work.
    //
    // Starts a cluster of three replicas using the previous release of ArcherDB and then
    // replaces the binaries on disk with a new version.
    //
    // Against this upgrading cluster, we are running a benchmark load and checking that it finishes
    // with a zero status.
    //
    // To spice things up, replicas are periodically killed and restarted.

    if (skip_upgrade) {
        return error.SkipZigTest;
    }

    if (builtin.target.os.tag == .windows) {
        return error.SkipZigTest; // Coming soon!
    }

    const replica_count = TmpCluster.replica_count;

    var cluster = try TmpCluster.init();
    defer cluster.deinit();

    for (0..replica_count) |replica_index| {
        try cluster.replica_install(replica_index, .past);
        try cluster.replica_format(replica_index);
    }
    try cluster.workload_start(.{
        .event_count = 2_000_000,
        .query_uuid_count = 200,
        .query_radius_count = 100,
        .query_polygon_count = 40,
    });

    for (0..replica_count) |replica_index| {
        try cluster.replica_spawn(replica_index);
    }

    const ticks_max = 50;
    var upgrade_tick: [replica_count]u8 = @splat(0);
    for (0..replica_count) |replica_index| {
        upgrade_tick[replica_index] = cluster.prng.int_inclusive(u8, ticks_max - 1);
    }

    for (0..ticks_max) |tick| {
        std.time.sleep(2 * std.time.ns_per_s);

        for (0..replica_count) |replica_index| {
            if (tick == upgrade_tick[replica_index]) {
                assert(!cluster.replica_upgraded[replica_index]);
                try cluster.replica_upgrade(replica_index);
                assert(cluster.replica_upgraded[replica_index]);
            }
        }

        const replica_index = cluster.prng.index(cluster.replicas);
        const crash = cluster.prng.chance(ratio(1, 4));
        const restart = cluster.prng.chance(ratio(1, 2));

        if (cluster.replicas[replica_index] == null and restart) {
            try cluster.replica_spawn(replica_index);
        } else if (cluster.replicas[replica_index] != null and crash) {
            try cluster.replica_kill(replica_index);
        }
    }

    for (0..replica_count) |replica_index| {
        assert(cluster.replica_upgraded[replica_index]);
        if (cluster.replicas[replica_index] == null) {
            try cluster.replica_spawn(replica_index);
        }
    }

    cluster.workload_finish();
}

test "recover smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const replica_count = TmpCluster.replica_count;

    var cluster = try TmpCluster.init();
    defer cluster.deinit();

    for (0..replica_count) |replica_index| {
        try cluster.replica_install(replica_index, .current);
    }
    try cluster.replica_format(0);
    try cluster.replica_format(1);
    try cluster.replica_format(2);
    try cluster.replica_spawn(0);
    try cluster.replica_spawn(1);
    try cluster.replica_spawn(2);
    try cluster.wait_for_live_replicas(&.{ 0, 1, 2 }, .seconds(10));

    // This smoke focuses on recover/rejoin sequencing; heavier workload coverage lives elsewhere.
    try cluster.replica_kill(2);
    try cluster.wait_for_live_replicas(&.{ 0, 1 }, .seconds(10));
    try cluster.replica_reformat(2);
    try cluster.replica_spawn(2);
    try cluster.wait_for_live_replicas(&.{ 0, 1, 2 }, .seconds(10));
    try cluster.replica_kill(1);
    try cluster.wait_for_live_replicas(&.{ 0, 2 }, .seconds(10));
    try cluster.replica_spawn(1);
    try cluster.wait_for_live_replicas(&.{ 0, 1, 2 }, .seconds(10));
}

test "vortex smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    // Vortex requires Linux namespaces for proper process isolation and cleanup.
    // Skip this test if namespaces aren't available (e.g., unprivileged container).
    if (!canCreateUserNamespace()) {
        log.warn("Skipping vortex smoke test: user namespaces not available", .{});
        return error.SkipZigTest;
    }

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{vortex_exe} supervisor --test-duration=1s --replica-count=1",
        .{ .vortex_exe = vortex_exe },
    );
}

/// Check if we can create Linux namespaces (required for vortex process isolation).
/// Vortex requires both user and PID namespaces for proper cleanup.
fn canCreateUserNamespace() bool {
    if (builtin.os.tag != .linux) return false;

    // Fork a child process to test namespace creation without affecting this process.
    // The child will attempt to create user + PID namespaces and exit with status indicating success.
    const fork_result = std.posix.fork() catch return false;

    if (fork_result == 0) {
        // Child process: try to create namespaces
        const user_result = std.os.linux.unshare(std.os.linux.CLONE.NEWUSER);
        if (std.os.linux.E.init(user_result) != .SUCCESS) {
            std.posix.exit(1);
        }
        const pid_result = std.os.linux.unshare(std.os.linux.CLONE.NEWPID);
        if (std.os.linux.E.init(pid_result) != .SUCCESS) {
            std.posix.exit(1);
        }
        std.posix.exit(0);
    } else {
        // Parent process: wait for child and check exit status
        const wait_result = std.posix.waitpid(fork_result, 0);
        if (std.posix.W.IFEXITED(wait_result.status)) {
            return std.posix.W.EXITSTATUS(wait_result.status) == 0;
        }
        return false;
    }
}

// ============================================================================
// Multi-Region Replication Integration Tests
// ============================================================================

// NOTE: Multi-region replication tests require:
// - --region-role=primary|follower CLI flags
// - WAL shipping infrastructure
// - Follower read-only enforcement (error 213)
//
// These tests verify multi-region features:
// - Primary region accepts writes
// - Follower region rejects writes with FOLLOWER_READ_ONLY (213)
// - Follower region can serve reads
// - Replication lag metrics are exposed
//
// To run: zig build test:integration -- --test-filter "primary-follower"

// =============================================================================
// Metrics Pipeline Integration Tests (Phase 18)
// =============================================================================
//
// These tests verify E2E metrics flow:
// 1. Storage metrics (STOR-03) - compaction write amplification, compression ratio
// 2. RAM index metrics (MEM-03) - memory bytes, load factor, entry count
// 3. Query metrics (QUERY-04) - latency breakdown (parse/plan/execute/serialize)
//
// Manual Dashboard Verification:
// 1. Start ArcherDB: ./zig/zig build -j4 && ./zig-out/bin/archerdb start
// 2. Access metrics: curl http://localhost:8081/metrics
// 3. Verify in Grafana:
//    - archerdb-storage.json: Write Amplification, Compression Ratio panels
//    - archerdb-memory.json: RAM Index Load Factor, RAM Index Memory panels
//    - archerdb-query-performance.json: Latency by Phase, Query Latency P99 panels
//
// Alert Verification:
// Run workload and verify alerts fire in prometheus/rules/*.yaml when thresholds exceeded.
// =============================================================================

test "metrics: storage metrics exported" {
    // Verify storage metrics (STOR-03) appear in /metrics output
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(std.testing.allocator);

    const response = try fetchMetrics(std.testing.allocator, metrics_port);
    defer std.testing.allocator.free(response);

    // Storage metrics (STOR-03: Write amplification monitoring)
    try expectContains(response, "archerdb_compaction_write_amplification");
    try expectContains(response, "archerdb_storage_space_amplification");
    try expectContains(response, "archerdb_compaction_level_bytes_total");
    try expectContains(response, "archerdb_compression_ratio");
}

test "metrics: RAM index and query metrics exported" {
    // Verify RAM index (MEM-03) and query (QUERY-04) metrics appear in /metrics output
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(std.testing.allocator);

    const response = try fetchMetrics(std.testing.allocator, metrics_port);
    defer std.testing.allocator.free(response);

    // RAM index metrics (MEM-03)
    try expectContains(response, "archerdb_index_memory_bytes");
    try expectContains(response, "archerdb_index_entries_total");
    try expectContains(response, "archerdb_index_load_factor");

    // Query latency breakdown metrics (QUERY-04)
    try expectContains(response, "archerdb_query_parse_seconds");
    try expectContains(response, "archerdb_query_plan_seconds");
    try expectContains(response, "archerdb_query_execute_seconds");
    try expectContains(response, "archerdb_query_serialize_seconds");
}

const TmpCluster = struct {
    const replica_count = 3;
    // The test uses this hard-coded address, so only one instance can be running at a time.
    const addresses = "127.0.0.1:7121,127.0.0.1:7122,127.0.0.1:7123";
    const replica_ports = [_]u16{ 7121, 7122, 7123 };

    shell: *Shell,
    tmp: []const u8,

    prng: stdx.PRNG,
    replicas: [replica_count]?std.process.Child = @splat(null),
    replica_exe: [replica_count][]const u8,
    replica_datafile: [replica_count][]const u8,
    replica_upgraded: [replica_count]bool = @splat(false),

    workload_thread: ?std.Thread = null,
    workload_exit_ok: bool = false,

    fn init() !TmpCluster {
        const shell = try Shell.create(std.testing.allocator);
        errdefer shell.destroy();

        const tmp = try shell.fmt("./.zig-cache/tmp/{}", .{std.crypto.random.int(u64)});
        errdefer shell.cwd.deleteTree(tmp) catch {};

        try shell.cwd.makePath(tmp);

        var replica_exe: [replica_count][]const u8 = @splat("");
        var replica_datafile: [replica_count][]const u8 = @splat("");
        for (0..replica_count) |replica_index| {
            replica_exe[replica_index] = try shell.fmt("{s}/archerdb{}{s}", .{
                tmp,
                replica_index,
                builtin.target.exeFileExt(),
            });
            replica_datafile[replica_index] = try shell.fmt("{s}/0_{}.archerdb", .{
                tmp,
                replica_index,
            });
        }

        const prng = stdx.PRNG.from_seed_testing();
        return .{
            .shell = shell,
            .tmp = tmp,
            .prng = prng,
            .replica_exe = replica_exe,
            .replica_datafile = replica_datafile,
        };
    }

    fn deinit(cluster: *TmpCluster) void {
        // Sadly, killing workload process is not easy, so, in case of an error, we'll wait
        // for full timeout.
        if (cluster.workload_thread) |workload_thread| {
            workload_thread.join();
        }

        for (&cluster.replicas) |*replica| {
            if (replica.*) |*alive| {
                _ = alive.kill() catch {};
            }
        }

        cluster.shell.cwd.deleteTree(cluster.tmp) catch {};
        cluster.shell.destroy();
        cluster.* = undefined;
    }

    fn replica_install(
        cluster: *TmpCluster,
        replica_index: usize,
        version: enum { past, current },
    ) !void {
        const destination = cluster.replica_exe[replica_index];
        try cluster.shell.cwd.copyFile(
            switch (version) {
                .past => if (skip_upgrade) archerdb else archerdb_past,
                .current => archerdb,
            },
            cluster.shell.cwd,
            destination,
            .{},
        );
        try cluster.shell.file_make_executable(destination);
    }

    fn replica_format(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);

        try cluster.shell.exec(
            \\{archerdb} format --cluster=0 --replica={replica} --replica-count=3 {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .replica = replica_index,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_reformat(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);

        cluster.shell.cwd.deleteFile(cluster.replica_datafile[replica_index]) catch {};

        try cluster.shell.exec(
            \\{archerdb} recover
            \\    --cluster=0
            \\    --replica={replica}
            \\    --replica-count=3
            \\    --development=true
            \\    --addresses={addresses}
            \\    {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .replica = replica_index,
            .addresses = addresses,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_upgrade(cluster: *TmpCluster, replica_index: usize) !void {
        assert(!cluster.replica_upgraded[replica_index]);

        const upgrade_requires_restart = builtin.os.tag != .linux;
        if (upgrade_requires_restart) {
            if (cluster.replicas[replica_index] != null) {
                try cluster.replica_kill(replica_index);
            }
            assert(cluster.replicas[replica_index] == null);
        }

        cluster.shell.cwd.deleteFile(cluster.replica_exe[replica_index]) catch {};
        try cluster.replica_install(replica_index, .current);
        cluster.replica_upgraded[replica_index] = true;

        if (upgrade_requires_restart) {
            assert(cluster.replicas[replica_index] == null);
            try cluster.replica_spawn(replica_index);
            assert(cluster.replicas[replica_index] != null);
        }
    }

    fn replica_spawn(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);
        cluster.replicas[replica_index] = try cluster.shell.spawn(.{},
            \\{archerdb} start --development=true --addresses={addresses} {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .addresses = addresses,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_kill(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] != null);
        _ = cluster.replicas[replica_index].?.kill() catch {};
        cluster.replicas[replica_index] = null;
    }

    fn wait_for_live_replicas(
        cluster: *TmpCluster,
        replica_indices: []const usize,
        timeout: stdx.Duration,
    ) !void {
        _ = cluster;

        const deadline = std.time.nanoTimestamp() + timeout.ns;
        var stable_checks: usize = 0;
        while (std.time.nanoTimestamp() < deadline) {
            var all_listening = true;
            for (replica_indices) |replica_index| {
                var stream = std.net.tcpConnectToAddress(replica_address(replica_index)) catch |err| switch (err) {
                    error.ConnectionRefused,
                    error.ConnectionTimedOut,
                    error.NetworkUnreachable,
                    error.ConnectionResetByPeer,
                    => {
                        all_listening = false;
                        break;
                    },
                    else => return err,
                };
                stream.close();
            }

            if (all_listening) {
                stable_checks += 1;
                if (stable_checks >= 3) return;
            } else {
                stable_checks = 0;
            }

            std.time.sleep(200 * std.time.ns_per_ms);
        }

        return error.ExecTimeout;
    }

    fn replica_address(replica_index: usize) std.net.Address {
        return std.net.Address.parseIp4("127.0.0.1", replica_ports[replica_index]) catch unreachable;
    }

    const WorkloadStartOptions = struct {
        event_count: usize,
        query_uuid_count: usize = 0,
        query_radius_count: usize = 0,
        query_polygon_count: usize = 0,
    };

    fn workload_start(cluster: *TmpCluster, options: WorkloadStartOptions) !void {
        assert(cluster.workload_thread == null);
        assert(!cluster.workload_exit_ok);
        // Run workload in a separate thread, to collect it's stdout and stderr, and to
        // forcefully terminate it after 10 minutes.
        cluster.workload_thread = try std.Thread.spawn(.{}, struct {
            fn thread_main(
                workload_exit_ok_ptr: *bool,
                archerdb_path: []const u8,
                benchmark_options: WorkloadStartOptions,
            ) !void {
                const shell = try Shell.create(std.testing.allocator);
                defer shell.destroy();

                try shell.exec_options(.{ .timeout = .minutes(10) },
                    \\{archerdb} benchmark
                    \\    --print-batch-timings
                    \\    --event-count={event_count}
                    \\    --query-uuid-count={query_uuid_count}
                    \\    --query-radius-count={query_radius_count}
                    \\    --query-polygon-count={query_polygon_count}
                    \\    --addresses={addresses}
                , .{
                    .archerdb = archerdb_path,
                    .addresses = addresses,
                    .event_count = benchmark_options.event_count,
                    .query_uuid_count = benchmark_options.query_uuid_count,
                    .query_radius_count = benchmark_options.query_radius_count,
                    .query_polygon_count = benchmark_options.query_polygon_count,
                });
                workload_exit_ok_ptr.* = true;
            }
        }.thread_main, .{
            &cluster.workload_exit_ok,
            if (skip_upgrade) archerdb else archerdb_past,
            options,
        });
    }

    fn workload_finish(cluster: *TmpCluster) void {
        cluster.workload_thread.?.join();
        cluster.workload_thread = null;
        assert(cluster.workload_exit_ok);
    }
};
