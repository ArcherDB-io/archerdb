// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const stdx = @import("stdx");
const vsr = @import("../../vsr.zig");
const constants = vsr.constants;
const Operation = vsr.archerdb.Operation;

// We could have used the idiomatic Zig API exposed by `vsr.arch_client`,
// but we want to test the actual FFI exposed by `libarch_client`.
const c = @cImport({
    @cInclude("arch_client.h");
});

const assert = std.debug.assert;

const log = std.log.scoped(.zig_driver);
const events_count_max = 8189;
const events_buffer_size_max = size: {
    var event_size_max = 0;
    for (std.enums.values(Operation)) |operation| {
        event_size_max = @max(event_size_max, operation.event_size());
    }
    break :size event_size_max * events_count_max;
};

pub const CLIArgs = struct {
    @"--": void,
    @"cluster-id": u128,
    addresses: []const u8,
};

pub fn main(_: std.mem.Allocator, args: CLIArgs) !void {
    log.info("addresses: {s}", .{args.addresses});

    const cluster_id = args.@"cluster-id";

    var arch_client: c.arch_client_t = undefined;
    const init_status = c.arch_client_init(
        &arch_client,
        std.mem.asBytes(&cluster_id),
        args.addresses.ptr,
        @intCast(args.addresses.len),
        0,
        on_complete,
    );
    if (init_status != c.ARCH_INIT_SUCCESS) {
        return error.ClientInitError;
    }
    defer {
        const client_status = c.arch_client_deinit(&arch_client);
        assert(client_status == c.ARCH_CLIENT_OK);
    }

    const stdin = std.io.getStdIn().reader().any();
    const stdout = std.io.getStdOut().writer().any();

    while (true) {
        var events_buffer: [events_buffer_size_max]u8 = undefined;
        const operation, const events = receive(stdin, events_buffer[0..]) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        };

        var context = RequestContext{};

        {
            context.lock.lock();
            defer context.lock.unlock();

            var packet: c.arch_packet_t = undefined;
            packet.operation = @intFromEnum(operation);
            packet.user_data = @ptrCast(@constCast(&context));
            packet.data = @constCast(events.ptr);
            packet.data_size = @intCast(events.len);
            packet.user_tag = 0;
            packet.status = c.ARCH_PACKET_OK;

            const client_status = c.arch_client_submit(&arch_client, &packet);
            assert(client_status == c.ARCH_CLIENT_OK);

            while (!context.completed) {
                context.condition.wait(&context.lock);
            }
        }

        write_results(stdout, operation, context.result[0..context.result_size]) catch |err| {
            switch (err) {
                error.BrokenPipe => {
                    log.info("stdout is closed, exiting", .{});
                    break;
                },
                else => return err,
            }
        };
    }
}

const RequestContext = struct {
    lock: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    completed: bool = false,
    result: [constants.message_body_size_max]u8 = undefined,
    result_size: u32 = 0,
};

pub fn on_complete(
    arch_context: usize,
    arch_packet: [*c]c.arch_packet_t,
    timestamp: u64,
    result_ptr: [*c]const u8,
    result_len: u32,
) callconv(.c) void {
    _ = arch_context;
    _ = timestamp;
    const context: *RequestContext = @ptrCast(@alignCast(arch_packet.*.user_data.?));

    context.lock.lock();
    defer context.lock.unlock();

    assert(arch_packet.*.status == c.ARCH_PACKET_OK);
    assert(result_ptr != null);

    stdx.copy_disjoint(.exact, u8, context.result[0..result_len], result_ptr[0..result_len]);
    context.result_size = result_len;
    context.completed = true;
    context.condition.signal();
}

fn write_results(
    writer: std.io.AnyWriter,
    operation: Operation,
    result: []const u8,
) !void {
    switch (operation) {
        inline else => |operation_comptime| {
            const result_size = operation_comptime.result_size();
            if (result_size > 0) {
                const count = @divExact(result.len, result_size);
                try writer.writeInt(u32, @intCast(count), .little);
                try writer.writeAll(result);
            } else {
                log.err(
                    "unexpected size {d} for op: {s}",
                    .{ result_size, @tagName(operation_comptime) },
                );
                unreachable;
            }
        },
    }
}

fn receive(reader: std.io.AnyReader, buffer: []u8) !struct { Operation, []const u8 } {
    const operation = try reader.readEnum(Operation, .little);
    const count = try reader.readInt(u32, .little);

    return switch (operation) {
        inline else => |operation_comptime| {
            assert(count <= events_count_max);

            const response_size = operation_comptime.event_size() * count;
            assert(buffer.len >= response_size);

            const read_total_size = try reader.readAtLeast(buffer, response_size);
            assert(read_total_size == response_size);

            return .{ operation_comptime, buffer[0..response_size] };
        },
    };
}
