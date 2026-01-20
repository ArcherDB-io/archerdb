// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const assert = std.debug.assert;

const testing = std.testing;

const arch_client = @import("arch_client.zig");
const stdx = arch_client.vsr.stdx;
const constants = @import("../../constants.zig");
const tb = arch_client.vsr.archerdb;

const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: arch_client.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply: ?struct {
            arch_context: usize,
            arch_packet: *arch_client.Packet,
            timestamp: u64,
            result: ?[request_size_max]u8,
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

            self.reply = .{
                .arch_context = arch_context,
                .arch_packet = arch_packet,
                .timestamp = timestamp,
                .result = if (result_ptr != null and result_len > 0) blk: {
                    // Copy the message's body to the context buffer:
                    assert(result_len <= request_size_max);
                    var writable: [request_size_max]u8 = undefined;
                    const readable: [*]const u8 = @ptrCast(result_ptr.?);
                    stdx.copy_disjoint(.inexact, u8, &writable, readable[0..result_len]);
                    break :blk writable;
                } else null,
                .result_len = result_len,
            };
        }
    };
}

// Notifies the main thread when all pending requests are completed.
const Completion = struct {
    pending: usize,
    mutex: Mutex = .{},
    cond: Condition = .{},

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

        while (self.pending > 0)
            self.cond.wait(&self.mutex);
    }
};

// Consistency of U128 across Zig and the language clients.
// It must be kept in sync with all platforms.
test "u128 consistency test" {
    const decimal: u128 = 214850178493633095719753766415838275046;
    const binary = [16]u8{
        0xe6, 0xe5, 0xe4, 0xe3, 0xe2, 0xe1,
        0xd2, 0xd1, 0xc2, 0xc1, 0xb2, 0xb1,
        0xa4, 0xa3, 0xa2, 0xa1,
    };
    const pair: extern struct { lower: u64, upper: u64 } = .{
        .lower = 15119395263638463974,
        .upper = 11647051514084770242,
    };

    try testing.expectEqual(decimal, @as(u128, @bitCast(binary)));
    try testing.expectEqual(binary, @as([16]u8, @bitCast(decimal)));

    try testing.expectEqual(decimal, @as(u128, @bitCast(pair)));
    try testing.expectEqual(pair, @as(@TypeOf(pair), @bitCast(decimal)));
}

// When initialized with `init_echo`, the arch_client uses a test context that echoes
// the data back without creating an actual client or connecting to a cluster.
//
// This same test should be implemented by all the target programming languages, asserting that:
// 1. the arch_client api was initialized correctly.
// 2. the application can submit messages and receive replies through the completion callback.
// 3. the data marshaling is correct, and exactly the same data sent was received back.
test "arch_client echo" {
    // Using the insert_events operation for this test.
    const RequestContext = RequestContextType(constants.message_body_size_max);

    // Test multiple ArcherDB geospatial operations (F1.3.7)
    const operations = [_]arch_client.Operation{
        arch_client.Operation.insert_events,
        arch_client.Operation.upsert_events,
        arch_client.Operation.delete_entities,
        arch_client.Operation.query_uuid,
        arch_client.Operation.query_latest,
        arch_client.Operation.query_radius,
        arch_client.Operation.query_polygon,
    };

    // Initializing an echo client for testing purposes.
    // We ensure that the retry mechanism is being tested
    // by allowing more simultaneous packets than "client_request_queue_max".
    var client: arch_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const address = "3000";
    const concurrency_max: u32 = constants.client_request_queue_max;
    const arch_context: usize = 42;
    try arch_client.init_echo(
        testing.allocator,
        &client,
        cluster_id,
        address,
        arch_context,
        RequestContext.on_complete,
    );

    defer client.deinit() catch unreachable;
    var prng = stdx.PRNG.from_seed(arch_context);

    const requests: []RequestContext = try testing.allocator.alloc(
        RequestContext,
        concurrency_max,
    );
    defer testing.allocator.free(requests);

    // Repeating the same test multiple times to stress the
    // cycle of message exhaustion followed by completions.
    const repetitions_max = 20;
    var repetition: u32 = 0;
    var operation_current: ?arch_client.Operation = null;
    while (repetition < repetitions_max) : (repetition += 1) {
        var completion = Completion{ .pending = concurrency_max };

        const operation: arch_client.Operation = operation: {
            if (operation_current == null or
                // Sometimes repeat the same operation for testing multi-batch.
                prng.boolean())
            {
                operation_current = operations[prng.index(operations)];
            }
            break :operation operation_current.?;
        };

        // ArcherDB geospatial operations event sizes (F1.3.7)
        const event_size: u32, const event_request_max: u32 = switch (operation) {
            .insert_events, .upsert_events => .{
                @sizeOf(tb.GeoEvent),
                @divExact(constants.message_body_size_max, @sizeOf(tb.GeoEvent)),
            },
            .delete_entities => .{
                @sizeOf(u128), // entity_id
                @divExact(constants.message_body_size_max, @sizeOf(u128)),
            },
            .query_uuid => .{
                @sizeOf(tb.QueryUuidFilter),
                1,
            },
            .query_latest => .{
                @sizeOf(tb.QueryLatestFilter),
                1,
            },
            .query_radius => .{
                @sizeOf(tb.QueryRadiusFilter),
                1,
            },
            .query_polygon => .{
                @sizeOf(tb.QueryPolygonFilter),
                1,
            },
            else => unreachable,
        };
        const event_request_max_capped: u32 = @min(event_request_max, 1);

        // Submitting some random data to be echoed back:
        for (requests) |*request| {
            request.* = .{
                .packet = undefined,
                .completion = &completion,
                .sent_data_size = prng.range_inclusive(
                    u32,
                    1,
                    event_request_max_capped,
                ) * event_size,
            };
            prng.fill(request.sent_data[0..request.sent_data_size]);
            const data_slice = request.sent_data[0..request.sent_data_size];
            switch (operation) {
                .query_latest => {
                    @memset(data_slice, 0);
                    clamp_limit(data_slice, @offsetOf(tb.QueryLatestFilter, "limit"));
                },
                .query_radius => {
                    @memset(data_slice, 0);
                    clamp_limit(data_slice, @offsetOf(tb.QueryRadiusFilter, "limit"));
                },
                .query_polygon => {
                    @memset(data_slice, 0);
                    clamp_limit(data_slice, @offsetOf(tb.QueryPolygonFilter, "limit"));
                },
                else => {},
            }

            const packet = &request.packet;
            packet.operation = @intFromEnum(operation);
            packet.user_data = request;
            packet.data = &request.sent_data;
            packet.data_size = request.sent_data_size;
            packet.user_tag = 0;
            packet.status = .ok;

            try client.submit(packet);
        }

        // Waiting until the c_client thread has processed all submitted requests:
        completion.wait_pending();

        // Checking if the received echo matches the data we sent:
        for (requests) |*request| {
            try testing.expect(request.reply != null);
            try testing.expectEqual(arch_context, request.reply.?.arch_context);
            try testing.expectEqual(arch_client.PacketStatus.ok, request.packet.status);
            try testing.expectEqual(
                @intFromPtr(&request.packet),
                @intFromPtr(request.reply.?.arch_packet),
            );
            try testing.expect(request.reply.?.result != null);
            try testing.expectEqual(request.sent_data_size, request.reply.?.result_len);

            const sent_data = request.sent_data[0..request.sent_data_size];
            const reply = request.reply.?.result.?[0..request.reply.?.result_len];
            try testing.expectEqualSlices(u8, sent_data, reply);
        }
    }
}

fn clamp_limit(buffer: []u8, offset: usize) void {
    if (offset + @sizeOf(u32) > buffer.len) return;
    const limit_bytes = std.mem.toBytes(@as(u32, 1000));
    stdx.copy_left(.exact, u8, buffer[offset..][0..limit_bytes.len], &limit_bytes);
}

// Asserts the validation rules associated with the `init*` functions.
test "arch_client init" {
    const assert_status = struct {
        pub fn action(
            addresses: []const u8,
            expected: arch_client.InitError!void,
        ) !void {
            var client_out: arch_client.ClientInterface = undefined;
            const cluster_id: u128 = 0;
            const arch_context: usize = 0;
            const result = arch_client.init_echo(
                testing.allocator,
                &client_out,
                cluster_id,
                addresses,
                arch_context,
                RequestContextType(0).on_complete,
            );
            defer if (!std.meta.isError(result)) client_out.deinit() catch unreachable;
            try testing.expectEqual(expected, result);
        }
    }.action;

    // Valid addresses should return ARCH_STATUS_SUCCESS:
    try assert_status("3000", {});
    try assert_status("127.0.0.1", {});
    try assert_status("127.0.0.1:3000", {});
    try assert_status("3000,3001,3002", {});
    try assert_status("127.0.0.1,127.0.0.2,172.0.0.3", {});
    try assert_status("127.0.0.1:3000,127.0.0.1:3002,127.0.0.1:3003", {});

    // Invalid or empty address should return "ARCH_STATUS_ADDRESS_INVALID":
    try assert_status("invalid", error.AddressInvalid);
    try assert_status("", error.AddressInvalid);

    // More addresses than "replicas_max" should return "ARCH_STATUS_ADDRESS_LIMIT_EXCEEDED":
    try assert_status(
        ("3000," ** constants.replicas_max) ++ "3001",
        error.AddressLimitExceeded,
    );

    // All other status are not testable.
}

// Asserts the validation rules associated with the client status.
test "arch_client client status" {
    const RequestContext = RequestContextType(0);
    var client: arch_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const addresses = "3000";
    const arch_context: usize = 0;
    try arch_client.init_echo(
        testing.allocator,
        &client,
        cluster_id,
        addresses,
        arch_context,
        RequestContext.on_complete,
    );
    errdefer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 1 };
    var request = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const packet = &request.packet;
    packet.operation = @intFromEnum(arch_client.Operation.insert_events);
    packet.user_data = &request;
    packet.data = null;
    packet.data_size = 0;
    packet.user_tag = 0;
    packet.status = .ok;

    // Sanity test to verify that the client is working.
    try client.submit(packet);
    completion.wait_pending();

    // Deinit the client.
    try client.deinit();

    // Cannot submit after deinit.
    try testing.expectError(error.ClientInvalid, client.submit(packet));

    // Multiple deinit calls are safe.
    try testing.expectError(error.ClientInvalid, client.deinit());
}

// Asserts the validation rules associated with the "PacketStatus" enum.
test "arch_client PacketStatus" {
    const RequestContext = RequestContextType(constants.message_body_size_max);

    var client_out: arch_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const addresses = "3000";
    const arch_context: usize = 42;
    try arch_client.init_echo(
        testing.allocator,
        &client_out,
        cluster_id,
        addresses,
        arch_context,
        RequestContext.on_complete,
    );
    defer client_out.deinit() catch unreachable;

    const assert_result = struct {
        // Asserts if the packet's status matches the expected status
        // for a given operation and request_size.
        pub fn action(
            client: *arch_client.ClientInterface,
            operation: u8,
            request_size: u32,
            packet_status_expected: arch_client.PacketStatus,
        ) !void {
            var completion = Completion{ .pending = 1 };
            var request = RequestContext{
                .packet = undefined,
                .completion = &completion,
                .sent_data_size = request_size,
            };

            const packet = &request.packet;
            packet.operation = operation;
            packet.user_data = &request;
            packet.data = &request.sent_data;
            packet.data_size = request_size;
            packet.user_tag = 0;
            packet.status = .ok;

            try client.submit(packet);

            completion.wait_pending();

            try testing.expect(request.reply != null);
            try testing.expectEqual(arch_context, request.reply.?.arch_context);
            try testing.expectEqual(
                @intFromPtr(&request.packet),
                @intFromPtr(request.reply.?.arch_packet),
            );
            try testing.expectEqual(packet_status_expected, request.packet.status);
        }
    }.action;

    // Messages larger than constants.message_body_size_max should return "too_much_data":
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.insert_events),
        constants.message_body_size_max + @sizeOf(arch_client.exports.geo_event_t),
        .too_much_data,
    );

    // All reserved and unknown operations should return "invalid_operation":
    try assert_result(
        &client_out,
        0,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        1,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        99,
        @sizeOf(u128),
        .invalid_operation,
    );
    try assert_result(
        &client_out,
        254,
        @sizeOf(u128),
        .invalid_operation,
    );

    // Messages not a multiple of the event size
    // should return "invalid_data_size":
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.insert_events),
        @sizeOf(arch_client.exports.geo_event_t) - 1,
        .invalid_data_size,
    );
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.delete_entities),
        @sizeOf(u128) + 1,
        .invalid_data_size,
    );
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.delete_entities),
        @sizeOf(u128) * 2.5,
        .invalid_data_size,
    );

    // Messages with zero length or multiple of the event size are valid.
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.insert_events),
        0,
        .ok,
    );
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.insert_events),
        @sizeOf(arch_client.exports.geo_event_t),
        .ok,
    );
    try assert_result(
        &client_out,
        @intFromEnum(arch_client.Operation.insert_events),
        @sizeOf(arch_client.exports.geo_event_t) * 2,
        .ok,
    );
}

fn degrees_to_nano(degrees: f64) i64 {
    return @intFromFloat(@round(degrees * 1_000_000_000.0));
}

fn make_event(entity_id: u128, latitude: f64, longitude: f64) tb.GeoEvent {
    var event = std.mem.zeroes(tb.GeoEvent);
    event.id = entity_id;
    event.entity_id = entity_id;
    event.lat_nano = degrees_to_nano(latitude);
    event.lon_nano = degrees_to_nano(longitude);
    event.group_id = 1;
    return event;
}

fn submit_insert_batch(
    client: *arch_client.ClientInterface,
    completion: *Completion,
    request: anytype,
    events: []const tb.GeoEvent,
) !void {
    completion.pending = 1;
    request.reply = null;

    const bytes = std.mem.sliceAsBytes(events);
    assert(bytes.len <= request.sent_data.len);
    stdx.copy_disjoint(.exact, u8, request.sent_data[0..bytes.len], bytes);
    request.sent_data_size = @intCast(bytes.len);

    const packet = &request.packet;
    packet.operation = @intFromEnum(arch_client.Operation.insert_events);
    packet.user_data = request;
    packet.data = &request.sent_data;
    packet.data_size = request.sent_data_size;
    packet.user_tag = 0;
    packet.status = .ok;

    try client.submit(packet);
    completion.wait_pending();

    try testing.expectEqual(arch_client.PacketStatus.ok, packet.status);
    try testing.expect(request.reply != null);
    if (request.reply.?.result_len > 0) {
        try testing.expect(request.reply.?.result != null);
        const result_size = @sizeOf(arch_client.exports.insert_geo_events_result_t);
        try testing.expectEqual(@as(u32, 0), request.reply.?.result_len % result_size);
        const results = request.reply.?.result.?[0..request.reply.?.result_len];
        var offset: usize = 0;
        while (offset < results.len) : (offset += result_size) {
            const raw = std.mem.bytesToValue(
                arch_client.exports.insert_geo_events_result_t,
                results[offset .. offset + result_size],
            );
            try testing.expectEqual(arch_client.exports.insert_geo_event_result.ok, raw.result);
        }
    }
}

test "arch_client insert_events integration" {
    const run_integration = blk: {
        const value = std.process.getEnvVarOwned(testing.allocator, "ARCHERDB_INTEGRATION") catch {
            break :blk false;
        };
        defer testing.allocator.free(value);
        break :blk std.mem.eql(u8, value, "1");
    };
    if (!run_integration) return;

    const address_opt = std.process.getEnvVarOwned(
        testing.allocator,
        "ARCHERDB_ADDRESS",
    ) catch null;
    defer if (address_opt) |addr| testing.allocator.free(addr);
    const address = address_opt orelse "127.0.0.1:3001";

    const RequestContext = RequestContextType(constants.message_body_size_max);

    var client: arch_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const arch_context: usize = 0;
    try arch_client.init(
        testing.allocator,
        &client,
        cluster_id,
        address,
        arch_context,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    var request = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    var batch1 = [_]tb.GeoEvent{
        make_event(1001, 37.7749, -122.4194),
        make_event(1002, 37.7750, -122.4195),
    };
    try submit_insert_batch(&client, &completion, &request, &batch1);

    var batch2 = [_]tb.GeoEvent{
        make_event(1003, 37.7751, -122.4196),
        make_event(1004, 37.7752, -122.4197),
    };
    try submit_insert_batch(&client, &completion, &request, &batch2);
}
