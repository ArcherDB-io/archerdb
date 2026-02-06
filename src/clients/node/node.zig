// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const assert = std.debug.assert;

const c = @import("src/c.zig").c;
const translate = @import("src/translate.zig");
const tb = vsr.archerdb;
const arch_client = vsr.arch_client;

const Operation = tb.Operation;

// GeoEvent types for ArcherDB geospatial operations
const GeoEvent = tb.GeoEvent;
const QueryUuidFilter = tb.QueryUuidFilter;
const QueryUuidBatchFilter = tb.QueryUuidBatchFilter;
const QueryUuidResponse = tb.QueryUuidResponse;
const QueryRadiusFilter = tb.QueryRadiusFilter;
const QueryPolygonFilter = tb.QueryPolygonFilter;
const QueryLatestFilter = tb.QueryLatestFilter;
const QueryResponse = tb.QueryResponse;
const QueryUuidBatchResult = tb.QueryUuidBatchResult;
const PolygonVertex = tb.PolygonVertex;
const HoleDescriptor = tb.HoleDescriptor;
const PingRequest = tb.PingRequest;
const StatusRequest = tb.StatusRequest;
const CleanupRequest = tb.CleanupRequest;
const TopologyRequest = tb.TopologyRequest;
const TopologyResponseCompact = tb.TopologyResponseCompact;
const ShardInfo = tb.ShardInfo;
const TtlSetRequest = tb.TtlSetRequest;
const TtlExtendRequest = tb.TtlExtendRequest;
const TtlClearRequest = tb.TtlClearRequest;
const BatchQueryRequest = tb.BatchQueryRequest;
const PrepareQueryRequest = tb.PrepareQueryRequest;
const ExecutePreparedRequest = tb.ExecutePreparedRequest;
const DeallocatePreparedRequest = tb.DeallocatePreparedRequest;

const vsr = @import("vsr");
const constants = vsr.constants;
const stdx = vsr.stdx;

const global_allocator = std.heap.c_allocator;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = arch_client.exports.Logging.application_logger,
};

// Cached value for JS (null).
var napi_null: c.napi_value = undefined;

const InternalError = enum(u16) {
    none = 0,
    result_ptr_null = 1,
    allocation_failed = 2,
    tsfn_queue_full = 3,
    tsfn_closing = 4,
    tsfn_failed = 5,
};

fn internal_error_from_tag(tag: u16) InternalError {
    return std.meta.intToEnum(InternalError, tag) catch .none;
}

fn set_internal_error(packet_extern: *arch_client.Packet, err: InternalError) void {
    packet_extern.user_tag = @intFromEnum(err);
}

fn internal_error_throw(env: c.napi_env, err: InternalError) !c.napi_value {
    return switch (err) {
        .none => translate.throw(env, "No internal error."),
        .result_ptr_null => translate.throw(env, "Native completion returned a null result pointer."),
        .allocation_failed => translate.throw(env, "Failed to allocate native response buffer."),
        .tsfn_queue_full => translate.throw(env, "Native completion queue is full."),
        .tsfn_closing => translate.throw(env, "Native completion queue is closing."),
        .tsfn_failed => translate.throw(env, "Failed to queue native completion callback."),
    };
}

fn cleanup_packet_on_failed_queue(packet_extern: *arch_client.Packet) void {
    const packet = packet_extern.cast();
    if (packet.data_size > 0 and packet.data != null) {
        const data: [*]u8 = @ptrCast(packet.data.?);
        global_allocator.free(data[0..@intCast(packet.data_size)]);
    }
    global_allocator.destroy(packet);
}

/// N-API will call this constructor automatically to register the module.
export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    napi_null = translate.capture_null(env) catch return null;

    translate.register_function(env, exports, "init", init) catch return null;
    translate.register_function(env, exports, "init_echo", init_echo) catch return null;
    translate.register_function(env, exports, "deinit", deinit) catch return null;
    translate.register_function(env, exports, "submit", submit) catch return null;
    return exports;
}

// Add-on code

fn init(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    const args = translate.extract_args(env, info, .{
        .count = 1,
        .function = "init",
    }) catch return null;

    const cluster = translate.u128_from_object(env, args[0], "cluster_id") catch return null;
    const addresses = translate.slice_from_object(
        env,
        args[0],
        "replica_addresses",
    ) catch return null;

    return create(env, cluster, addresses, false) catch null;
}

fn init_echo(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    const args = translate.extract_args(env, info, .{
        .count = 1,
        .function = "init_echo",
    }) catch return null;

    const cluster = translate.u128_from_object(env, args[0], "cluster_id") catch return null;
    const addresses = translate.slice_from_object(
        env,
        args[0],
        "replica_addresses",
    ) catch return null;

    return create(env, cluster, addresses, true) catch null;
}

fn deinit(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    const args = translate.extract_args(env, info, .{
        .count = 1,
        .function = "deinit",
    }) catch return null;

    destroy(env, args[0]) catch {};
    return null;
}

fn submit(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    const args = translate.extract_args(env, info, .{
        .count = 4,
        .function = "submit",
    }) catch return null;

    const operation_int = translate.u32_from_value(env, args[1], "operation") catch return null;
    if (!@as(vsr.Operation, @enumFromInt(operation_int)).valid(Operation)) {
        translate.throw(env, "Unknown operation.") catch return null;
    }

    var is_array: bool = undefined;
    if (c.napi_is_array(env, args[2], &is_array) != c.napi_ok) {
        translate.throw(env, "Failed to check array argument type.") catch return null;
    }
    if (!is_array) {
        translate.throw(env, "Array argument must be an [object Array].") catch return null;
    }

    var callback_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, args[3], &callback_type) != c.napi_ok) {
        translate.throw(env, "Failed to check callback argument type.") catch return null;
    }
    if (callback_type != c.napi_function) {
        translate.throw(env, "Callback argument must be a Function.") catch return null;
    }

    request(
        env,
        args[0], // arch_client
        @enumFromInt(@as(u8, @intCast(operation_int))),
        args[2], // request array
        args[3], // callback
    ) catch {};
    return null;
}

// arch_client Logic

fn create(
    env: c.napi_env,
    cluster_id: u128,
    addresses: []const u8,
    comptime echo_mode: bool,
) !c.napi_value {
    var tsfn_name: c.napi_value = undefined;
    const name_result = c.napi_create_string_utf8(
        env,
        "arch_client",
        c.NAPI_AUTO_LENGTH,
        &tsfn_name,
    );
    if (name_result != c.napi_ok) {
        return translate.throw(
            env,
            "Failed to create resource name for thread-safe function.",
        );
    }

    var completion_tsfn: c.napi_threadsafe_function = undefined;
    if (c.napi_create_threadsafe_function(
        env,
        null, // No javascript function to call directly from here.
        null, // No async resource.
        tsfn_name,
        0, // Max queue size of 0 means no limit.
        1, // Number of acquires/threads that will be calling this TSFN.
        null, // No finalization data.
        null, // No finalization callback.
        null, // No custom context.
        on_completion_js, // Function to call on JS thread when TSFN is called.
        &completion_tsfn, // TSFN out handle.
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to create thread-safe function.");
    }
    errdefer if (c.napi_release_threadsafe_function(
        completion_tsfn,
        c.napi_tsfn_abort,
    ) != c.napi_ok) {
        std.log.warn("Failed to release allocated thread-safe function on error.", .{});
    };

    const client = global_allocator.create(arch_client.ClientInterface) catch {
        return translate.throw(env, "Failed to allocated the client interface.");
    };
    errdefer global_allocator.destroy(client);

    const init_fn = if (echo_mode) arch_client.init_echo else arch_client.init;
    init_fn(
        global_allocator,
        client,
        cluster_id,
        addresses,
        @intFromPtr(completion_tsfn),
        on_completion,
    ) catch |err| switch (err) {
        error.OutOfMemory => return translate.throw(env, "Failed to allocate memory for Client."),
        error.Unexpected => return translate.throw(env, "Unexpected error occurred on Client."),
        error.AddressInvalid => return translate.throw(env, "Invalid replica address."),
        error.AddressLimitExceeded => return translate.throw(env, "Too many replica addresses."),
        error.SystemResources => return translate.throw(env, "Failed to reserve system resources."),
        error.NetworkSubsystemFailed => return translate.throw(env, "Network stack failure."),
    };
    errdefer client.deinit() catch unreachable;

    return try translate.create_external(env, client);
}

// Javascript is single threaded so no synchronization is necessary for closing/accessing a client.
fn destroy(env: c.napi_env, context: c.napi_value) !void {
    const client_ptr = try translate.value_external(
        env,
        context,
        "Failed to get client context pointer.",
    );
    const client: *arch_client.ClientInterface = @ptrCast(@alignCast(client_ptr.?));
    defer {
        client.deinit() catch unreachable;
        global_allocator.destroy(client);
    }

    const completion_ctx = client.completion_context() catch |err| switch (err) {
        error.ClientInvalid => return translate.throw(env, "Client was closed."),
    };

    const completion_tsfn: c.napi_threadsafe_function = @ptrFromInt(completion_ctx);
    if (c.napi_release_threadsafe_function(completion_tsfn, c.napi_tsfn_release) != c.napi_ok) {
        return translate.throw(env, "Failed to release allocated thread-safe function on error.");
    }
}

fn request(
    env: c.napi_env,
    context: c.napi_value,
    operation: Operation,
    array: c.napi_value,
    callback: c.napi_value,
) !void {
    const client_ptr = try translate.value_external(
        env,
        context,
        "Failed to get client context pointer.",
    );
    const client: *arch_client.ClientInterface = @ptrCast(@alignCast(client_ptr.?));

    // Create a reference to the callback so it stay alive until the packet completes.
    var callback_ref: c.napi_ref = undefined;
    if (c.napi_create_reference(env, callback, 1, &callback_ref) != c.napi_ok) {
        return translate.throw(env, "Failed to create reference to callback.");
    }
    errdefer translate.delete_reference(env, callback_ref) catch {
        std.log.warn("Failed to delete reference to callback on error.", .{});
    };

    const array_length: u32 = try translate.array_length(env, array);
    const packet, const packet_data = switch (operation) {
        .query_uuid_batch => blk: {
            if (array_length != 1) {
                return translate.throw(env, "query_uuid_batch requires a single filter.");
            }

            const filter = try translate.array_element(env, array, 0);
            const buffer = try encode_query_uuid_batch_request(env, filter);

            const packet = global_allocator.create(arch_client.Packet) catch {
                global_allocator.free(buffer);
                return translate.throw(env, "Failed to allocated a new packet.");
            };

            break :blk .{ packet, buffer };
        },
        .query_polygon => blk: {
            if (array_length != 1) {
                return translate.throw(env, "query_polygon requires a single filter.");
            }

            const filter = try translate.array_element(env, array, 0);
            const buffer = try encode_query_polygon_request(env, filter);

            const packet = global_allocator.create(arch_client.Packet) catch {
                global_allocator.free(buffer);
                return translate.throw(env, "Failed to allocated a new packet.");
            };

            break :blk .{ packet, buffer };
        },
        inline else => |operation_comptime| blk: {
            const Event = operation_comptime.EventType();

            // Avoid allocating memory for requests that are known to be too large.
            // However, the final validation happens in `arch_client` against the runtime-known
            // maximum size.
            if (array_length * @sizeOf(Event) > constants.message_body_size_max) {
                return translate.throw(env, "Too much data provided on this batch.");
            }

            const packet = global_allocator.create(arch_client.Packet) catch {
                return translate.throw(env, "Failed to allocated a new packet.");
            };
            errdefer global_allocator.destroy(packet);

            const buffer: []Event = global_allocator.alloc(Event, array_length) catch {
                return translate.throw(env, "Failed to allocated the request buffer.");
            };
            errdefer global_allocator.free(buffer);

            try decode_array(Event, env, array, buffer);
            break :blk .{ packet, std.mem.sliceAsBytes(buffer) };
        },
        .pulse => unreachable,
    };

    packet.* = .{
        .user_data = callback_ref,
        .operation = @intFromEnum(operation),
        .data = packet_data.ptr,
        .data_size = @intCast(packet_data.len),
        .user_tag = 0,
        .status = undefined,
    };

    client.submit(packet) catch |err| switch (err) {
        error.ClientInvalid => return translate.throw(env, "Client was closed."),
    };
}

fn encode_query_polygon_request(env: c.napi_env, filter: c.napi_value) ![]u8 {
    const header_size = @sizeOf(QueryPolygonFilter);
    const vertex_size = @sizeOf(PolygonVertex);
    const desc_size = @sizeOf(HoleDescriptor);

    var vertices_value: c.napi_value = undefined;
    if (c.napi_get_named_property(
        env,
        filter,
        @ptrCast(add_trailing_null("vertices")),
        &vertices_value,
    ) != c.napi_ok) {
        return translate.throw(env, "vertices must be defined");
    }

    var is_vertices_array: bool = undefined;
    if (c.napi_is_array(env, vertices_value, &is_vertices_array) != c.napi_ok or
        !is_vertices_array)
    {
        return translate.throw(env, "vertices must be an Array.");
    }

    const vertex_count = try translate.array_length(env, vertices_value);
    if (vertex_count < 3) {
        return translate.throw(env, "Polygon must have at least 3 vertices.");
    }
    if (vertex_count > constants.polygon_vertices_max) {
        return translate.throw(env, "Polygon exceeds maximum vertex count.");
    }

    var hole_count: u32 = 0;
    var total_hole_vertices: u32 = 0;
    var has_holes: bool = false;
    var holes_value: c.napi_value = undefined;

    if (c.napi_has_named_property(
        env,
        filter,
        @ptrCast(add_trailing_null("holes")),
        &has_holes,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to inspect holes property.");
    }

    if (has_holes) {
        if (c.napi_get_named_property(
            env,
            filter,
            @ptrCast(add_trailing_null("holes")),
            &holes_value,
        ) != c.napi_ok) {
            return translate.throw(env, "holes must be defined");
        }

        var holes_type: c.napi_valuetype = undefined;
        if (c.napi_typeof(env, holes_value, &holes_type) != c.napi_ok) {
            return translate.throw(env, "Failed to inspect holes type.");
        }

        if (holes_type != c.napi_undefined and holes_type != c.napi_null) {
            var is_holes_array: bool = undefined;
            if (c.napi_is_array(env, holes_value, &is_holes_array) != c.napi_ok or
                !is_holes_array)
            {
                return translate.throw(env, "holes must be an Array.");
            }

            hole_count = try translate.array_length(env, holes_value);
            if (hole_count > constants.polygon_holes_max) {
                return translate.throw(env, "Polygon exceeds maximum hole count.");
            }

            var hole_index: u32 = 0;
            while (hole_index < hole_count) : (hole_index += 1) {
                const hole = try translate.array_element(env, holes_value, hole_index);

                var hole_vertices_value: c.napi_value = undefined;
                if (c.napi_get_named_property(
                    env,
                    hole,
                    @ptrCast(add_trailing_null("vertices")),
                    &hole_vertices_value,
                ) != c.napi_ok) {
                    return translate.throw(env, "holes[].vertices must be defined");
                }

                var is_hole_vertices_array: bool = undefined;
                if (c.napi_is_array(
                    env,
                    hole_vertices_value,
                    &is_hole_vertices_array,
                ) != c.napi_ok or !is_hole_vertices_array) {
                    return translate.throw(env, "holes[].vertices must be an Array.");
                }

                const hole_vertices_count = try translate.array_length(env, hole_vertices_value);
                if (hole_vertices_count < constants.polygon_hole_vertices_min) {
                    return translate.throw(env, "Hole must have at least 3 vertices.");
                }

                total_hole_vertices += hole_vertices_count;
            }
        }
    }

    const total_vertices = vertex_count + total_hole_vertices;
    if (total_vertices > constants.polygon_vertices_max) {
        return translate.throw(env, "Polygon exceeds maximum total vertex count.");
    }

    const outer_vertices_size: usize = vertex_count * vertex_size;
    const hole_descriptors_size: usize = hole_count * desc_size;
    const hole_vertices_size: usize = total_hole_vertices * vertex_size;
    const total_size: usize = header_size + outer_vertices_size +
        hole_descriptors_size + hole_vertices_size;

    if (total_size > constants.message_body_size_max) {
        return translate.throw(env, "Too much data provided on this batch.");
    }

    const buffer = try global_allocator.alignedAlloc(
        u8,
        @alignOf(QueryPolygonFilter),
        total_size,
    );
    errdefer global_allocator.free(buffer);
    @memset(buffer, 0);

    const header = std.mem.bytesAsValue(QueryPolygonFilter, buffer[0..header_size]);
    header.* = .{
        .vertex_count = vertex_count,
        .hole_count = hole_count,
        .limit = try translate.u32_from_object(env, filter, add_trailing_null("limit")),
        .timestamp_min = try translate.u64_from_object(
            env,
            filter,
            add_trailing_null("timestamp_min"),
        ),
        .timestamp_max = try translate.u64_from_object(
            env,
            filter,
            add_trailing_null("timestamp_max"),
        ),
        .group_id = try translate.u64_from_object(env, filter, add_trailing_null("group_id")),
    };

    var offset: usize = header_size;
    const outer_vertices = std.mem.bytesAsSlice(
        PolygonVertex,
        buffer[offset..][0..outer_vertices_size],
    );
    var vertex_index: u32 = 0;
    while (vertex_index < vertex_count) : (vertex_index += 1) {
        const vertex = try translate.array_element(env, vertices_value, vertex_index);
        outer_vertices[vertex_index] = .{
            .lat_nano = try translate.i64_from_object(env, vertex, add_trailing_null("lat_nano")),
            .lon_nano = try translate.i64_from_object(env, vertex, add_trailing_null("lon_nano")),
        };
    }

    offset += outer_vertices_size;
    if (hole_count > 0) {
        const descriptors = std.mem.bytesAsSlice(
            HoleDescriptor,
            buffer[offset..][0..hole_descriptors_size],
        );
        offset += hole_descriptors_size;

        var hole_index: u32 = 0;
        while (hole_index < hole_count) : (hole_index += 1) {
            const hole = try translate.array_element(env, holes_value, hole_index);
            var hole_vertices_value: c.napi_value = undefined;
            if (c.napi_get_named_property(
                env,
                hole,
                @ptrCast(add_trailing_null("vertices")),
                &hole_vertices_value,
            ) != c.napi_ok) {
                return translate.throw(env, "holes[].vertices must be defined");
            }

            const hole_vertices_count = try translate.array_length(env, hole_vertices_value);
            descriptors[hole_index] = .{
                .vertex_count = hole_vertices_count,
            };

            const hole_vertices_bytes: usize = hole_vertices_count * vertex_size;
            const hole_vertices = std.mem.bytesAsSlice(
                PolygonVertex,
                buffer[offset..][0..hole_vertices_bytes],
            );

            var hole_vertex_index: u32 = 0;
            while (hole_vertex_index < hole_vertices_count) : (hole_vertex_index += 1) {
                const hole_vertex = try translate.array_element(
                    env,
                    hole_vertices_value,
                    hole_vertex_index,
                );
                hole_vertices[hole_vertex_index] = .{
                    .lat_nano = try translate.i64_from_object(
                        env,
                        hole_vertex,
                        add_trailing_null("lat_nano"),
                    ),
                    .lon_nano = try translate.i64_from_object(
                        env,
                        hole_vertex,
                        add_trailing_null("lon_nano"),
                    ),
                };
            }

            offset += hole_vertices_bytes;
        }
    }

    return buffer;
}

fn on_completion(
    completion_ctx: usize,
    packet_extern: *arch_client.Packet,
    timestamp: u64,
    result_ptr: ?[*]const u8,
    result_len: u32,
) callconv(.c) void {
    _ = timestamp;

    var internal_error: InternalError = .none;
    switch (packet_extern.status) {
        .ok => {
            if (result_len > 0 and result_ptr == null) {
                internal_error = .result_ptr_null;
            } else {
                const operation: Operation = @enumFromInt(packet_extern.operation);
                op_switch: switch (operation) {
                    .query_uuid,
                    .query_uuid_batch,
                    .query_radius,
                    .query_polygon,
                    .query_latest,
                    => {
                        // Query operations return a header + payload buffer, not a flat Result[].
                        const packet = packet_extern.cast();
                        const req_buf = @constCast(packet.slice());
                        const reply_buffer = global_allocator.realloc(req_buf, result_len) catch {
                            // We can't throw Js exceptions from the native callback.
                            internal_error = .allocation_failed;
                            break :op_switch;
                        };
                        if (result_len > 0) {
                            stdx.copy_disjoint(
                                .exact,
                                u8,
                                reply_buffer,
                                result_ptr.?[0..result_len],
                            );
                        }
                        packet.data = if (reply_buffer.len == 0) null else reply_buffer.ptr;
                        packet.data_size = @intCast(reply_buffer.len);
                    },
                    inline else => |operation_comptime| {
                        const Event = operation_comptime.EventType();
                        const Result = operation_comptime.ResultType();

                        const packet = packet_extern.cast();
                        const request_buffer: []align(@alignOf(Event)) u8 =
                            @alignCast(@constCast(packet.slice()));
                        // Trying to reallocate the request buffer instead of allocating a new one.
                        // This is optimal for create_* operations.
                        const req_buf = @as([]u8, @alignCast(request_buffer));
                        const reply_buffer: []align(@alignOf(Result)) u8 = @alignCast(
                            global_allocator.realloc(req_buf, result_len) catch {
                                // We can't throw Js exceptions from the native callback.
                                internal_error = .allocation_failed;
                                break :op_switch;
                            },
                        );

                        const source_bytes: []const u8 = if (result_len == 0)
                            &[_]u8{}
                        else
                            result_ptr.?[0..result_len];
                        const source = stdx.bytes_as_slice(
                            .exact,
                            Result,
                            source_bytes,
                        );
                        const target = stdx.bytes_as_slice(
                            .exact,
                            Result,
                            reply_buffer,
                        );

                        stdx.copy_disjoint(
                            .exact,
                            Result,
                            target,
                            source,
                        );

                        // Store the size of the results in the `tag` field.
                        // This is read during `on_completion_js`.
                        packet.data = if (reply_buffer.len == 0) null else reply_buffer.ptr;
                        packet.data_size = @intCast(reply_buffer.len);
                    },
                    .pulse => unreachable,
                }
            }
        },
        .client_evicted,
        .client_release_too_low,
        .client_release_too_high,
        .client_shutdown,
        .too_much_data,
        => {}, // Handled on the JS side to throw exception.
        .invalid_operation => unreachable, // We check the operation during request().
        .invalid_data_size => unreachable, // We set correct data size during request().
    }

    if (internal_error != .none) {
        set_internal_error(packet_extern, internal_error);
    }

    // Queue the packet to be processed on the JS thread to invoke its JS callback.
    const completion_tsfn: c.napi_threadsafe_function = @ptrFromInt(completion_ctx);
    const call_result = c.napi_call_threadsafe_function(
        completion_tsfn,
        packet_extern,
        c.napi_tsfn_nonblocking,
    );
    if (call_result == c.napi_ok) {
        return;
    }

    if (call_result == c.napi_queue_full) {
        set_internal_error(packet_extern, .tsfn_queue_full);
        const retry = c.napi_call_threadsafe_function(
            completion_tsfn,
            packet_extern,
            c.napi_tsfn_blocking,
        );
        if (retry == c.napi_ok) return;
    } else {
        set_internal_error(packet_extern, .tsfn_failed);
    }

    std.log.err(
        "Failed to queue completion callback (napi status={d}); dropping packet.",
        .{call_result},
    );
    cleanup_packet_on_failed_queue(packet_extern);
}

fn on_completion_js(
    env: c.napi_env,
    unused_js_cb: c.napi_value,
    unused_context: ?*anyopaque,
    packet_argument: ?*anyopaque,
) callconv(.c) void {
    _ = unused_js_cb;
    _ = unused_context;

    // Extract the remaining packet information from the packet before it's freed.
    const packet_extern: *arch_client.Packet = @ptrCast(@alignCast(packet_argument.?));
    const callback_ref: c.napi_ref = @ptrCast(@alignCast(packet_extern.user_data.?));

    // Decode the packet's Buffer results into an array then free the packet/Buffer.
    const array_or_error = result: {
        const internal_error = internal_error_from_tag(packet_extern.user_tag);
        if (internal_error != .none) {
            const packet = packet_extern.cast();
            defer global_allocator.destroy(packet);

            const buffer: []const u8 = packet.slice();
            defer global_allocator.free(buffer);

            break :result internal_error_throw(env, internal_error);
        }

        const operation: Operation = @enumFromInt(packet_extern.operation);
        break :result switch (operation) {
            .query_uuid => blk: {
                const packet = packet_extern.cast();
                defer global_allocator.destroy(packet);

                const buffer: []const u8 = packet.slice();
                defer global_allocator.free(buffer);

                switch (packet.status) {
                    .ok => break :blk encode_query_uuid_response(env, buffer),
                    .client_shutdown => {
                        break :blk translate.throw(env, "Client was shutdown.");
                    },
                    .client_evicted => {
                        break :blk translate.throw(env, "Client was evicted.");
                    },
                    .client_release_too_low => {
                        break :blk translate.throw(env, "Client was evicted: release too old.");
                    },
                    .client_release_too_high => {
                        break :blk translate.throw(env, "Client was evicted: release too new.");
                    },
                    .too_much_data => {
                        break :blk translate.throw(env, "Too much data provided on this batch.");
                    },
                    else => unreachable, // all other packet status' handled in previous callback.
                }
            },
            .query_uuid_batch => blk: {
                const packet = packet_extern.cast();
                defer global_allocator.destroy(packet);

                const buffer: []const u8 = packet.slice();
                defer global_allocator.free(buffer);

                switch (packet.status) {
                    .ok => break :blk encode_query_uuid_batch_response(env, buffer),
                    .client_shutdown => {
                        break :blk translate.throw(env, "Client was shutdown.");
                    },
                    .client_evicted => {
                        break :blk translate.throw(env, "Client was evicted.");
                    },
                    .client_release_too_low => {
                        break :blk translate.throw(env, "Client was evicted: release too old.");
                    },
                    .client_release_too_high => {
                        break :blk translate.throw(env, "Client was evicted: release too new.");
                    },
                    .too_much_data => {
                        break :blk translate.throw(env, "Too much data provided on this batch.");
                    },
                    else => unreachable, // all other packet status' handled in previous callback.
                }
            },
            .query_radius, .query_polygon, .query_latest => blk: {
                const packet = packet_extern.cast();
                defer global_allocator.destroy(packet);

                const buffer: []const u8 = packet.slice();
                defer global_allocator.free(buffer);

                switch (packet.status) {
                    .ok => break :blk encode_query_response(env, buffer),
                    .client_shutdown => {
                        break :blk translate.throw(env, "Client was shutdown.");
                    },
                    .client_evicted => {
                        break :blk translate.throw(env, "Client was evicted.");
                    },
                    .client_release_too_low => {
                        break :blk translate.throw(env, "Client was evicted: release too old.");
                    },
                    .client_release_too_high => {
                        break :blk translate.throw(env, "Client was evicted: release too new.");
                    },
                    .too_much_data => {
                        break :blk translate.throw(env, "Too much data provided on this batch.");
                    },
                    else => unreachable, // all other packet status' handled in previous callback.
                }
            },
            .get_topology => blk: {
                const packet = packet_extern.cast();
                defer global_allocator.destroy(packet);

                const buffer: []const u8 = packet.slice();
                defer global_allocator.free(buffer);

                switch (packet.status) {
                    .ok => break :blk encode_topology_response(env, buffer),
                    .client_shutdown => {
                        break :blk translate.throw(env, "Client was shutdown.");
                    },
                    .client_evicted => {
                        break :blk translate.throw(env, "Client was evicted.");
                    },
                    .client_release_too_low => {
                        break :blk translate.throw(env, "Client was evicted: release too old.");
                    },
                    .client_release_too_high => {
                        break :blk translate.throw(env, "Client was evicted: release too new.");
                    },
                    .too_much_data => {
                        break :blk translate.throw(env, "Too much data provided on this batch.");
                    },
                    else => unreachable, // all other packet status' handled in previous callback.
                }
            },
            inline else => |operation_comptime| blk: {
                const Result = operation_comptime.ResultType();

                const packet = packet_extern.cast();
                defer global_allocator.destroy(packet);

                const buffer: []const u8 = packet.slice();
                defer global_allocator.free(buffer);

                switch (packet.status) {
                    .ok => {
                        const results = stdx.bytes_as_slice(
                            .exact,
                            Result,
                            buffer,
                        );
                        break :blk encode_array(Result, env, results);
                    },
                    .client_shutdown => {
                        break :blk translate.throw(env, "Client was shutdown.");
                    },
                    .client_evicted => {
                        break :blk translate.throw(env, "Client was evicted.");
                    },
                    .client_release_too_low => {
                        break :blk translate.throw(env, "Client was evicted: release too old.");
                    },
                    .client_release_too_high => {
                        break :blk translate.throw(env, "Client was evicted: release too new.");
                    },
                    .too_much_data => {
                        break :blk translate.throw(env, "Too much data provided on this batch.");
                    },
                    else => unreachable, // all other packet status' handled in previous callback.
                }
            },
            .pulse => unreachable,
        };
    };

    // Parse Result array out of packet data, freeing it in the process.
    // NOTE: Ensure this is called before anything that could early-return to avoid a alloc leak.
    var callback_error = napi_null;
    const callback_result = array_or_error catch |err| switch (err) {
        error.ExceptionThrown => blk: {
            if (c.napi_get_and_clear_last_exception(env, &callback_error) != c.napi_ok) {
                std.log.warn("Failed to capture callback error from thrown Exception.", .{});
            }
            break :blk napi_null;
        },
    };

    // Make sure to delete the callback reference once we're done calling it.
    defer if (c.napi_delete_reference(env, callback_ref) != c.napi_ok) {
        std.log.warn("Failed to delete reference to user's JS callback.", .{});
    };

    const callback = translate.reference_value(
        env,
        callback_ref,
        "Failed to get callback from reference.",
    ) catch return;

    var args = [_]c.napi_value{ callback_error, callback_result };
    _ = translate.call_function(env, napi_null, callback, &args) catch return;
}

// (De)Serialization

fn encode_query_uuid_response(env: c.napi_env, buffer: []const u8) !c.napi_value {
    const header_size = @sizeOf(QueryUuidResponse);
    if (buffer.len < header_size) {
        const empty: [0]GeoEvent = .{};
        return encode_array(GeoEvent, env, &empty);
    }

    const header = std.mem.bytesAsValue(
        QueryUuidResponse,
        buffer[0..header_size],
    );

    switch (header.status) {
        0 => {
            if (buffer.len < header_size + @sizeOf(GeoEvent)) {
                const empty: [0]GeoEvent = .{};
                return encode_array(GeoEvent, env, &empty);
            }
            const events = stdx.bytes_as_slice(
                .exact,
                GeoEvent,
                buffer[header_size..][0..@sizeOf(GeoEvent)],
            );
            return encode_array(GeoEvent, env, events);
        },
        200 => {
            const empty: [0]GeoEvent = .{};
            return encode_array(GeoEvent, env, &empty);
        },
        210 => return translate.throw(env, "Entity expired due to TTL."),
        else => return translate.throw(env, "Query UUID failed."),
    }
}

fn encode_query_uuid_batch_request(env: c.napi_env, filter: c.napi_value) ![]u8 {
    const header_size = @sizeOf(QueryUuidBatchFilter);
    const id_size = @sizeOf(u128);

    var ids_value: c.napi_value = undefined;
    if (c.napi_get_named_property(
        env,
        filter,
        @ptrCast(add_trailing_null("entity_ids")),
        &ids_value,
    ) != c.napi_ok) {
        return translate.throw(env, "entity_ids must be defined");
    }

    var is_ids_array: bool = undefined;
    if (c.napi_is_array(env, ids_value, &is_ids_array) != c.napi_ok or !is_ids_array) {
        return translate.throw(env, "entity_ids must be an Array.");
    }

    const count = try translate.array_length(env, ids_value);
    if (count > QueryUuidBatchFilter.max_count) {
        return translate.throw(env, "entity_ids exceeds maximum count.");
    }

    const ids_size: usize = count * id_size;
    const total_size: usize = header_size + ids_size;
    if (total_size > constants.message_body_size_max) {
        return translate.throw(env, "Too much data provided on this batch.");
    }

    const buffer = try global_allocator.alignedAlloc(
        u8,
        @alignOf(QueryUuidBatchFilter),
        total_size,
    );
    errdefer global_allocator.free(buffer);
    @memset(buffer, 0);

    const header = std.mem.bytesAsValue(QueryUuidBatchFilter, buffer[0..header_size]);
    header.* = .{
        .count = count,
    };

    const ids = std.mem.bytesAsSlice(u128, buffer[header_size..][0..ids_size]);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const value = try translate.array_element(env, ids_value, index);
        ids[index] = try translate.u128_from_value(env, value, add_trailing_null("entity_ids"));
    }

    return buffer;
}

fn encode_query_uuid_batch_response(env: c.napi_env, buffer: []const u8) !c.napi_value {
    const header_size = @sizeOf(QueryUuidBatchResult);
    const empty: [0]GeoEvent = .{};

    if (buffer.len < header_size) {
        return translate.throw(env, "query_uuid_batch response too small.");
    }

    const header = std.mem.bytesAsValue(
        QueryUuidBatchResult,
        buffer[0..header_size],
    ).*;

    const not_found_count = header.not_found_count;
    const found_count = header.found_count;
    const indices_size: usize = @as(usize, not_found_count) * @sizeOf(u16);
    const indices_end = header_size + indices_size;
    const events_offset = std.mem.alignForward(usize, indices_end, 16);
    const events_size: usize = @as(usize, found_count) * @sizeOf(GeoEvent);

    if (buffer.len < events_offset + events_size) {
        return translate.throw(env, "query_uuid_batch response truncated.");
    }

    const indices = try translate.create_array(
        env,
        not_found_count,
        "Failed to allocate not_found_indices array.",
    );
    var idx: u32 = 0;
    while (idx < not_found_count) : (idx += 1) {
        const start = header_size + @as(usize, idx) * @sizeOf(u16);
        const value = std.mem.readInt(u16, buffer[start..][0..@sizeOf(u16)], .little);

        var js_value: c.napi_value = undefined;
        if (c.napi_create_uint32(env, value, &js_value) != c.napi_ok) {
            return translate.throw(env, "Failed to create not_found index value.");
        }
        try translate.set_array_element(
            env,
            indices,
            idx,
            js_value,
            "Failed to set not_found index element.",
        );
    }

    const events = if (found_count == 0)
        &empty
    else
        stdx.bytes_as_slice(
            .exact,
            GeoEvent,
            buffer[events_offset..][0..events_size],
        );
    const events_array = try encode_array(GeoEvent, env, events);

    const result = try translate.create_object(
        env,
        "Failed to create query_uuid_batch result.",
    );
    try translate.u32_into_object(
        env,
        result,
        add_trailing_null("found_count"),
        header.found_count,
        "Failed to set query_uuid_batch found_count.",
    );
    try translate.u32_into_object(
        env,
        result,
        add_trailing_null("not_found_count"),
        header.not_found_count,
        "Failed to set query_uuid_batch not_found_count.",
    );

    if (c.napi_set_named_property(
        env,
        result,
        @ptrCast(add_trailing_null("not_found_indices")),
        indices,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to set not_found_indices.");
    }

    if (c.napi_set_named_property(
        env,
        result,
        @ptrCast(add_trailing_null("events")),
        events_array,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to set events.");
    }

    return result;
}

fn encode_query_response(env: c.napi_env, buffer: []const u8) !c.napi_value {
    const header_size = @sizeOf(QueryResponse);
    const event_size = @sizeOf(GeoEvent);
    const empty: [0]GeoEvent = .{};

    if (buffer.len == 0) {
        return encode_array(GeoEvent, env, &empty);
    }

    const has_header = buffer.len >= header_size and
        (buffer.len - header_size) % event_size == 0;

    if (!has_header) {
        if (buffer.len < event_size) {
            // Short replies may be server error codes; treat as empty result for parity with other SDKs.
            return encode_array(GeoEvent, env, &empty);
        }
        if (buffer.len % event_size != 0) {
            if (buffer.len % event_size == @sizeOf(u32)) {
                // Polygon errors can return a 4-byte error code with padding; treat as empty result.
                return encode_array(GeoEvent, env, &empty);
            }
            return translate.throw(env, "Query response size not aligned to GeoEvent.");
        }
        const events = stdx.bytes_as_slice(
            .exact,
            GeoEvent,
            buffer,
        );
        return encode_array(GeoEvent, env, events);
    }

    const header = std.mem.bytesAsValue(
        QueryResponse,
        buffer[0..header_size],
    ).*;
    const payload = buffer[header_size..];
    const expected: usize = @intCast(header.count);
    const available = payload.len / event_size;

    if (expected != available) {
        return translate.throw(env, "Query response count does not match payload size.");
    }

    const events = if (expected == 0)
        &empty
    else
        stdx.bytes_as_slice(
            .exact,
            GeoEvent,
            payload[0 .. expected * event_size],
        );

    const array = try encode_array(GeoEvent, env, events);
    try set_query_response_metadata(
        env,
        array,
        header.has_more != 0,
        header.partial_result != 0,
    );
    return array;
}

fn encode_topology_response(env: c.napi_env, buffer: []const u8) !c.napi_value {
    // Use compact response (max 16 shards) which the server returns for lite config
    if (buffer.len < @sizeOf(TopologyResponseCompact)) {
        return translate.throw(env, "Topology response too short.");
    }

    const response = std.mem.bytesAsValue(
        TopologyResponseCompact,
        buffer[0..@sizeOf(TopologyResponseCompact)],
    ).*;

    const obj = try translate.create_object(
        env,
        "Failed to create TopologyResponse object.",
    );

    try translate.u64_into_object(
        env,
        obj,
        add_trailing_null("version"),
        response.version,
        "Failed to set topology.version",
    );
    try translate.u32_into_object(
        env,
        obj,
        add_trailing_null("num_shards"),
        response.num_shards,
        "Failed to set topology.num_shards",
    );
    try translate.u128_into_object(
        env,
        obj,
        add_trailing_null("cluster_id"),
        response.cluster_id,
        "Failed to set topology.cluster_id",
    );
    try translate.i128_into_object(
        env,
        obj,
        add_trailing_null("last_change_ns"),
        response.last_change_ns,
        "Failed to set topology.last_change_ns",
    );
    try translate.u8_into_object(
        env,
        obj,
        add_trailing_null("resharding_status"),
        response.resharding_status,
        "Failed to set topology.resharding_status",
    );
    try translate.u8_into_object(
        env,
        obj,
        add_trailing_null("flags"),
        response.flags,
        "Failed to set topology.flags",
    );

    const shard_count: usize = @intCast(response.num_shards);
    const shards_array = try translate.create_array(
        env,
        @intCast(shard_count),
        "Failed to allocate topology shards array.",
    );
    const max_replicas: usize =
        @typeInfo(std.meta.fieldInfo(
            ShardInfo,
            @field(std.meta.FieldEnum(ShardInfo), "replicas"),
        ).type).array.len;

    var shard_index: usize = 0;
    while (shard_index < shard_count) : (shard_index += 1) {
        const shard = response.shards[shard_index];
        const shard_obj = try translate.create_object(
            env,
            "Failed to create ShardInfo object.",
        );

        try translate.u32_into_object(
            env,
            shard_obj,
            add_trailing_null("id"),
            shard.id,
            "Failed to set shard.id",
        );

        const primary = std.mem.sliceTo(&shard.primary, 0);
        var primary_value: c.napi_value = undefined;
        if (c.napi_create_string_utf8(
            env,
            primary.ptr,
            primary.len,
            &primary_value,
        ) != c.napi_ok) {
            return translate.throw(env, "Failed to create shard.primary string.");
        }
        if (c.napi_set_named_property(
            env,
            shard_obj,
            @ptrCast(add_trailing_null("primary")),
            primary_value,
        ) != c.napi_ok) {
            return translate.throw(env, "Failed to set shard.primary.");
        }

        const replica_count: usize = @min(
            @as(usize, @intCast(shard.replica_count)),
            max_replicas,
        );
        const replicas_array = try translate.create_array(
            env,
            @intCast(replica_count),
            "Failed to allocate shard.replicas array.",
        );
        var replica_index: usize = 0;
        while (replica_index < replica_count) : (replica_index += 1) {
            const replica = std.mem.sliceTo(&shard.replicas[replica_index], 0);
            var replica_value: c.napi_value = undefined;
            if (c.napi_create_string_utf8(
                env,
                replica.ptr,
                replica.len,
                &replica_value,
            ) != c.napi_ok) {
                return translate.throw(env, "Failed to create shard.replicas string.");
            }
            try translate.set_array_element(
                env,
                replicas_array,
                @intCast(replica_index),
                replica_value,
                "Failed to set shard.replicas element.",
            );
        }
        if (c.napi_set_named_property(
            env,
            shard_obj,
            @ptrCast(add_trailing_null("replicas")),
            replicas_array,
        ) != c.napi_ok) {
            return translate.throw(env, "Failed to set shard.replicas.");
        }

        try translate.u8_into_object(
            env,
            shard_obj,
            add_trailing_null("status"),
            @intCast(@intFromEnum(shard.status)),
            "Failed to set shard.status",
        );
        try translate.u64_into_object(
            env,
            shard_obj,
            add_trailing_null("entity_count"),
            shard.entity_count,
            "Failed to set shard.entity_count",
        );
        try translate.u64_into_object(
            env,
            shard_obj,
            add_trailing_null("size_bytes"),
            shard.size_bytes,
            "Failed to set shard.size_bytes",
        );

        try translate.set_array_element(
            env,
            shards_array,
            @intCast(shard_index),
            shard_obj,
            "Failed to set topology shard element.",
        );
    }

    if (c.napi_set_named_property(
        env,
        obj,
        @ptrCast(add_trailing_null("shards")),
        shards_array,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to set topology.shards.");
    }

    const array = try translate.create_array(
        env,
        1,
        "Failed to allocate topology response array.",
    );
    try translate.set_array_element(
        env,
        array,
        0,
        obj,
        "Failed to set topology response element.",
    );
    return array;
}

fn set_query_response_metadata(
    env: c.napi_env,
    array: c.napi_value,
    has_more: bool,
    partial_result: bool,
) !void {
    var value: c.napi_value = undefined;
    if (c.napi_get_boolean(env, has_more, &value) != c.napi_ok) {
        return translate.throw(env, "Failed to create has_more value.");
    }
    if (c.napi_set_named_property(
        env,
        array,
        @ptrCast(add_trailing_null("has_more")),
        value,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to set has_more on query response.");
    }

    if (c.napi_get_boolean(env, partial_result, &value) != c.napi_ok) {
        return translate.throw(env, "Failed to create partial_result value.");
    }
    if (c.napi_set_named_property(
        env,
        array,
        @ptrCast(add_trailing_null("partial_result")),
        value,
    ) != c.napi_ok) {
        return translate.throw(env, "Failed to set partial_result on query response.");
    }
}

fn decode_array(comptime Event: type, env: c.napi_env, array: c.napi_value, events: []Event) !void {
    for (events, 0..) |*event, i| {
        const object = try translate.array_element(env, array, @intCast(i));
        switch (Event) {
            // GeoEvent types
            GeoEvent,
            QueryUuidFilter,
            QueryUuidBatchFilter,
            QueryRadiusFilter,
            QueryPolygonFilter,
            QueryLatestFilter,
            // Other types
            PingRequest,
            StatusRequest,
            CleanupRequest,
            TopologyRequest,
            TtlSetRequest,
            TtlExtendRequest,
            TtlClearRequest,
            BatchQueryRequest,
            PrepareQueryRequest,
            ExecutePreparedRequest,
            DeallocatePreparedRequest,
            => {
                inline for (std.meta.fields(Event)) |field| {
                    const value: field.type = switch (@typeInfo(field.type)) {
                        .@"struct" => |info| @bitCast(try @field(
                            translate,
                            @typeName(info.backing_integer.?) ++ "_from_object",
                        )(
                            env,
                            object,
                            add_trailing_null(field.name),
                        )),
                        .int => try @field(translate, @typeName(field.type) ++ "_from_object")(
                            env,
                            object,
                            add_trailing_null(field.name),
                        ),
                        // Arrays are only used for padding/reserved fields,
                        // instead of requiring the user to explicitly set an empty buffer,
                        // we just hide those fields and use default value or zero.
                        .array => if (field.default_value_ptr) |ptr|
                            @as(*const field.type, @ptrCast(@alignCast(ptr))).*
                        else
                            std.mem.zeroes(field.type),
                        else => unreachable,
                    };

                    @field(event, field.name) = value;
                }
            },
            u128 => event.* = try translate.u128_from_value(env, object, "lookup"),
            void => {}, // Operations with no request body (ping, get_status)
            else => @compileError("invalid Event type"),
        }
    }
}

fn encode_array(comptime Result: type, env: c.napi_env, results: []const Result) !c.napi_value {
    const array = try translate.create_array(
        env,
        @intCast(results.len),
        "Failed to allocate array for results.",
    );

    for (results, 0..) |*result, i| {
        const object = try translate.create_object(
            env,
            "Failed to create " ++ @typeName(Result) ++ " object.",
        );

        inline for (std.meta.fields(Result)) |field| {
            const FieldInt = switch (@typeInfo(field.type)) {
                .@"struct" => |info| info.backing_integer.?,
                .@"enum" => |info| info.tag_type,
                // Arrays are only used for padding/reserved fields.
                .array => continue,
                else => field.type,
            };

            const value: FieldInt = switch (@typeInfo(field.type)) {
                .@"struct" => @bitCast(@field(result, field.name)),
                .@"enum" => @intFromEnum(@field(result, field.name)),
                else => @field(result, field.name),
            };

            try @field(translate, @typeName(FieldInt) ++ "_into_object")(
                env,
                object,
                add_trailing_null(field.name),
                value,
                "Failed to set property \"" ++ field.name ++
                    "\" of " ++ @typeName(Result) ++ " object",
            );

            try translate.set_array_element(
                env,
                array,
                @intCast(i),
                object,
                "Failed to set element in results array.",
            );
        }
    }

    return array;
}

fn add_trailing_null(comptime input: []const u8) [:0]const u8 {
    // Concatenating `[]const u8` with an empty string `[0:0]const u8`,
    // gives us a null-terminated string `[:0]const u8`.
    const output = input ++ "";
    comptime assert(output.len == input.len);
    comptime assert(output[output.len] == 0);
    return output;
}
