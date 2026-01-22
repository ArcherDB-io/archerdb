// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("../../vsr.zig");
const tb = vsr.arch_client;
const stdx = vsr.stdx;

pub const arch_packet_t = tb.Packet;
pub const arch_packet_status = tb.PacketStatus;

pub const arch_client_t = extern struct {
    @"opaque": [4]u64,

    pub inline fn cast(self: *arch_client_t) *tb.ClientInterface {
        return @ptrCast(self);
    }

    comptime {
        assert(@sizeOf(arch_client_t) == @sizeOf(tb.ClientInterface));
        assert(@bitSizeOf(arch_client_t) == @bitSizeOf(tb.ClientInterface));
        assert(@alignOf(arch_client_t) == @alignOf(tb.ClientInterface));
    }
};

pub const arch_init_status = enum(c_int) {
    success = 0,
    unexpected,
    out_of_memory,
    address_invalid,
    address_limit_exceeded,
    system_resources,
    network_subsystem,
};

pub const arch_client_status = enum(c_int) {
    ok = 0,
    invalid,
};

pub const arch_register_log_callback_status = enum(c_int) {
    success = 0,
    already_registered,
    not_registered,
};

pub const arch_log_level = enum(c_int) {
    err = @intFromEnum(std.log.Level.err),
    warn = @intFromEnum(std.log.Level.warn),
    info = @intFromEnum(std.log.Level.info),
    debug = @intFromEnum(std.log.Level.debug),

    comptime {
        assert(std.enums.values(std.log.Level).len == std.enums.values(arch_log_level).len);
        for (std.enums.values(std.log.Level)) |std_level| {
            const level: arch_log_level = @enumFromInt(@intFromEnum(std_level));
            assert(std.mem.eql(u8, @tagName(std_level), @tagName(level)));
        }
    }
};

pub const arch_operation = tb.Operation;
pub const arch_completion_t = tb.CompletionCallback;
pub const arch_init_parameters = tb.InitParameters;

// ArcherDB GeoEvent types (geospatial database core)
pub const geo_event_t = vsr.archerdb.GeoEvent;
pub const geo_event_flags = @import("../../geo_event.zig").GeoEventFlags;
pub const insert_geo_event_result = vsr.archerdb.InsertGeoEventResult;
pub const insert_geo_events_result_t = vsr.archerdb.InsertGeoEventsResult;
pub const delete_entities_result_t = vsr.archerdb.DeleteEntitiesResult;
pub const query_uuid_filter_t = vsr.archerdb.QueryUuidFilter;
pub const query_uuid_response_t = vsr.archerdb.QueryUuidResponse;
pub const query_uuid_batch_filter_t = vsr.archerdb.QueryUuidBatchFilter;
pub const query_uuid_batch_result_t = vsr.archerdb.QueryUuidBatchResult;
pub const query_radius_filter_t = vsr.archerdb.QueryRadiusFilter;
pub const query_polygon_filter_t = vsr.archerdb.QueryPolygonFilter;
pub const query_latest_filter_t = vsr.archerdb.QueryLatestFilter;
pub const query_response_t = vsr.archerdb.QueryResponse;
pub const polygon_vertex_t = vsr.archerdb.PolygonVertex;
pub const hole_descriptor_t = vsr.archerdb.HoleDescriptor;
pub const ping_request_t = vsr.archerdb.PingRequest;
pub const status_request_t = vsr.archerdb.StatusRequest;
pub const ping_response_t = vsr.archerdb.PingResponse;
pub const status_response_t = vsr.archerdb.StatusResponse;
pub const topology_request_t = vsr.archerdb.TopologyRequest;
pub const topology_response_t = vsr.archerdb.TopologyResponse;
pub const shard_info_t = vsr.archerdb.ShardInfo;
pub const shard_status = vsr.archerdb.ShardStatus;

// TTL Operations
pub const ttl_operation_result = vsr.archerdb.TtlOperationResult;
pub const ttl_set_request_t = vsr.archerdb.TtlSetRequest;
pub const ttl_set_response_t = vsr.archerdb.TtlSetResponse;
pub const ttl_extend_request_t = vsr.archerdb.TtlExtendRequest;
pub const ttl_extend_response_t = vsr.archerdb.TtlExtendResponse;
pub const ttl_clear_request_t = vsr.archerdb.TtlClearRequest;
pub const ttl_clear_response_t = vsr.archerdb.TtlClearResponse;

pub fn init_error_to_status(err: tb.InitError) arch_init_status {
    return switch (err) {
        error.Unexpected => .unexpected,
        error.OutOfMemory => .out_of_memory,
        error.AddressInvalid => .address_invalid,
        error.AddressLimitExceeded => .address_limit_exceeded,
        error.SystemResources => .system_resources,
        error.NetworkSubsystemFailed => .network_subsystem,
    };
}

pub fn init(
    arch_client_out: *arch_client_t,
    cluster_id_ptr: *const [16]u8,
    addresses_ptr: [*:0]const u8,
    addresses_len: u32,
    completion_ctx: usize,
    completion_callback: arch_completion_t,
) callconv(.c) arch_init_status {
    const addresses = @as([*]const u8, @ptrCast(addresses_ptr))[0..addresses_len];

    // Passing u128 by value is prone to ABI issues. Pass as a [16]u8, and explicitly copy into
    // memory we know will be aligned correctly. Don't just use bytesToValue here, as that keeps
    // pointer alignment, and will result in a potentially unaligned access of a
    // `*align(1) const u128`.
    const cluster_id: u128 = blk: {
        var cluster_id: u128 = undefined;
        stdx.copy_disjoint(.exact, u8, std.mem.asBytes(&cluster_id), cluster_id_ptr);

        break :blk cluster_id;
    };

    tb.init(
        std.heap.c_allocator,
        arch_client_out.cast(),
        cluster_id,
        addresses,
        completion_ctx,
        completion_callback,
    ) catch |err| return init_error_to_status(err);
    return .success;
}

pub fn init_echo(
    arch_client_out: *arch_client_t,
    cluster_id_ptr: *const [16]u8,
    addresses_ptr: [*:0]const u8,
    addresses_len: u32,
    completion_ctx: usize,
    completion_callback: arch_completion_t,
) callconv(.c) arch_init_status {
    const addresses = @as([*]const u8, @ptrCast(addresses_ptr))[0..addresses_len];

    // See explanation in init().
    const cluster_id: u128 = blk: {
        var cluster_id: u128 = undefined;
        stdx.copy_disjoint(.exact, u8, std.mem.asBytes(&cluster_id), cluster_id_ptr);

        break :blk cluster_id;
    };

    tb.init_echo(
        std.heap.c_allocator,
        arch_client_out.cast(),
        cluster_id,
        addresses,
        completion_ctx,
        completion_callback,
    ) catch |err| return init_error_to_status(err);
    return .success;
}

pub fn submit(
    arch_client: ?*arch_client_t,
    packet: *arch_packet_t,
) callconv(.c) arch_client_status {
    const client: *tb.ClientInterface = if (arch_client) |ptr|
        ptr.cast()
    else
        return .invalid;
    client.submit(packet) catch |err| switch (err) {
        error.ClientInvalid => return .invalid,
    };
    return .ok;
}

pub fn deinit(arch_client: ?*arch_client_t) callconv(.c) arch_client_status {
    const client: *tb.ClientInterface = if (arch_client) |ptr| ptr.cast() else return .invalid;
    client.deinit() catch |err| switch (err) {
        error.ClientInvalid => return .invalid,
    };
    return .ok;
}

pub fn init_parameters(
    arch_client: ?*arch_client_t,
    out_parameters: *arch_init_parameters,
) callconv(.c) arch_client_status {
    const client: *tb.ClientInterface = if (arch_client) |ptr| ptr.cast() else return .invalid;
    client.init_parameters(out_parameters) catch |err| switch (err) {
        error.ClientInvalid => return .invalid,
    };
    return .ok;
}

pub fn completion_context(
    arch_client: ?*arch_client_t,
    completion_ctx_out: *usize,
) callconv(.c) arch_client_status {
    const client: *tb.ClientInterface = if (arch_client) |ptr| ptr.cast() else return .invalid;
    completion_ctx_out.* = client.completion_context() catch |err| switch (err) {
        error.ClientInvalid => return .invalid,
    };
    return .ok;
}

pub fn register_log_callback(
    callback_maybe: ?Logging.Callback,
    debug: bool,
) callconv(.c) arch_register_log_callback_status {
    Logging.global.mutex.lock();
    defer Logging.global.mutex.unlock();
    if (Logging.global.callback == null) {
        if (callback_maybe) |callback| {
            Logging.global.callback = callback;
            Logging.global.debug = debug;
            return .success;
        } else {
            return .not_registered;
        }
    } else {
        if (callback_maybe == null) {
            Logging.global.callback = null;
            Logging.global.debug = debug;
            return .success;
        } else {
            return .already_registered;
        }
    }
}

pub const Logging = struct {
    const Callback = *const fn (
        message_level: arch_log_level,
        message_ptr: [*]const u8,
        message_len: u32,
    ) callconv(.c) void;

    const log_line_max = 8192;

    /// Logging is global per process; it would be nice to be able to define a different logger
    /// for each client instance, though.
    var global: Logging = .{};

    callback: ?Callback = null,
    mutex: std.Thread.Mutex = .{},
    buffer: [log_line_max]u8 = undefined,
    debug: bool = false,

    /// A logger which defers to an application provided handler.
    pub fn application_logger(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Debug logs are dropped here unless debug is set, because of the potential penalty in
        // crossing FFI to drop them.
        if (message_level == .debug and !Logging.global.debug) {
            return;
        }

        // Other messages are silently dropped if no logging callback is specified - unless they're
        // warn or err. The value in having those for debugging is too high to silence them, even
        // until client libraries catch up and implement a callback handler.
        if (Logging.global.callback == null and (message_level == .warn or message_level == .err)) {
            std.log.defaultLog(message_level, scope, format, args);
            return;
        }

        // Protect everything with a mutex - logging can be called from different threads
        // simultaneously, and there's only one buffer for now.
        Logging.global.mutex.lock();
        defer Logging.global.mutex.unlock();

        const callback = Logging.global.callback orelse return;

        const arch_message_level: arch_log_level = @enumFromInt(@intFromEnum(message_level));
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const output = std.fmt.bufPrint(
            &Logging.global.buffer,
            prefix ++ format,
            args,
        ) catch |err| switch (err) {
            error.NoSpaceLeft => blk: {
                // Print an error indicating the log message has been truncated, before the
                // truncated log itself.
                const message = "the following log message has been truncated:";
                callback(arch_message_level, message.ptr, message.len);

                break :blk &Logging.global.buffer;
            },
            else => unreachable,
        };

        callback(arch_message_level, output.ptr, @intCast(output.len));
    }
};
