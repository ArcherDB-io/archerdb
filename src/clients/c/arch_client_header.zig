// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("vsr");
const exports = vsr.arch_client.exports;

/// Doxygen documentation strings for types
const type_docs = struct {
    // geo_event_flags documentation
    pub const geo_event_flags =
        \\/**
        \\ * @brief Flags for geo_event_t indicating event state and attributes.
        \\ * @details Multiple flags can be combined using bitwise OR.
        \\ *          These flags affect how events are processed and stored.
        \\ */
    ;

    // geo_event_t documentation
    pub const geo_event_t =
        \\/**
        \\ * @brief A geospatial event representing an entity's location at a point in time.
        \\ * @details This is the primary data structure for storing location data.
        \\ *
        \\ * @par Memory Ownership
        \\ * Caller owns geo_event_t arrays passed to insert operations.
        \\ * Events returned in query callbacks are library-owned and must not be freed.
        \\ *
        \\ * @par Field Units
        \\ * - id: Unique 128-bit event identifier (must be non-zero)
        \\ * - entity_id: 128-bit identifier for the tracked entity (must be non-zero, not INT_MAX)
        \\ * - correlation_id: Optional 128-bit ID for linking related events
        \\ * - user_data: 128-bit user-defined data (application-specific)
        \\ * - lat_nano: Latitude in nanodegrees (1e-9 degrees), range: [-90e9, 90e9]
        \\ * - lon_nano: Longitude in nanodegrees (1e-9 degrees), range: [-180e9, 180e9]
        \\ * - group_id: Logical grouping for tenant isolation
        \\ * - timestamp: Server-assigned timestamp in nanoseconds (set to 0 on insert)
        \\ * - altitude_mm: Altitude in millimeters above sea level
        \\ * - velocity_mms: Speed in millimeters per second
        \\ * - ttl_seconds: Time-to-live in seconds (0 = no expiration)
        \\ * - accuracy_mm: Location accuracy in millimeters
        \\ * - heading_cdeg: Heading in centidegrees (0-35999, where 0=North, 9000=East)
        \\ * - flags: Combination of GEO_EVENT_FLAGS values
        \\ * - reserved: Must be zero (reserved for future use)
        \\ */
    ;

    // insert_geo_event_result documentation
    pub const insert_geo_event_result =
        \\/**
        \\ * @brief Result codes for individual geo event insertions.
        \\ * @details Error codes 100-199 are validation errors (client should fix request).
        \\ *          See error-codes.md for complete error code documentation.
        \\ */
    ;

    // insert_geo_events_result_t documentation
    pub const insert_geo_events_result_t =
        \\/**
        \\ * @brief Result for a single event in a batch insert operation.
        \\ * @details On successful batch insert with no errors, no results are returned.
        \\ *          Results are only returned for events that failed validation.
        \\ */
    ;

    // delete_entities_result_t documentation
    pub const delete_entities_result_t =
        \\/**
        \\ * @brief Result for a single entity deletion in a batch delete operation.
        \\ * @details Contains the index of the entity in the request and the result code.
        \\ */
    ;

    // query_uuid_filter_t documentation
    pub const query_uuid_filter_t =
        \\/**
        \\ * @brief Filter for querying the latest event of a specific entity.
        \\ * @details Returns the most recent geo_event_t for the specified entity_id.
        \\ */
    ;

    // query_uuid_response_t documentation
    pub const query_uuid_response_t =
        \\/**
        \\ * @brief Response header for UUID query operations.
        \\ * @details Status 0 = found, non-zero = not found or error.
        \\ */
    ;

    // query_uuid_batch_filter_t documentation
    pub const query_uuid_batch_filter_t =
        \\/**
        \\ * @brief Filter for querying latest events of multiple entities.
        \\ * @details Entity IDs follow immediately after this header in the request data.
        \\ */
    ;

    // query_uuid_batch_result_t documentation
    pub const query_uuid_batch_result_t =
        \\/**
        \\ * @brief Response header for batch UUID query operations.
        \\ * @details Events are returned in the same order as requested entity_ids.
        \\ *          Missing entities are indicated by found_count vs not_found_count.
        \\ */
    ;

    // query_radius_filter_t documentation
    pub const query_radius_filter_t =
        \\/**
        \\ * @brief Filter for querying events within a circular radius.
        \\ * @details Uses Haversine formula for accurate great-circle distance.
        \\ *
        \\ * @par Required Fields
        \\ * - center_lat_nano: Center latitude in nanodegrees
        \\ * - center_lon_nano: Center longitude in nanodegrees
        \\ * - radius_mm: Search radius in millimeters
        \\ *
        \\ * @par Optional Fields (set to 0 for default)
        \\ * - limit: Maximum events to return (0 = server default)
        \\ * - timestamp_min: Minimum timestamp filter (0 = no minimum)
        \\ * - timestamp_max: Maximum timestamp filter (0 = no maximum)
        \\ * - group_id: Filter by group (0 = all groups)
        \\ */
    ;

    // query_polygon_filter_t documentation
    pub const query_polygon_filter_t =
        \\/**
        \\ * @brief Filter for querying events within a polygon boundary.
        \\ * @details Polygon vertices follow this header, then hole descriptors (if any),
        \\ *          then vertices for each hole. Uses ray-casting point-in-polygon test.
        \\ *
        \\ * @par Polygon Format
        \\ * - Exterior ring: counter-clockwise winding order
        \\ * - Holes: clockwise winding order (GeoJSON convention)
        \\ * - vertex_count: Number of exterior polygon vertices
        \\ * - hole_count: Number of interior holes (0 for simple polygons)
        \\ *
        \\ * @par Optional Fields (set to 0 for default)
        \\ * - limit: Maximum events to return (0 = server default)
        \\ * - timestamp_min: Minimum timestamp filter
        \\ * - timestamp_max: Maximum timestamp filter
        \\ * - group_id: Filter by group
        \\ */
    ;

    // query_latest_filter_t documentation
    pub const query_latest_filter_t =
        \\/**
        \\ * @brief Filter for querying the most recent events across all entities.
        \\ * @details Returns events ordered by timestamp descending.
        \\ *          Use cursor_timestamp for pagination.
        \\ */
    ;

    // query_response_t documentation
    pub const query_response_t =
        \\/**
        \\ * @brief Response header for query operations.
        \\ * @details Followed by count geo_event_t structures in the response data.
        \\ *
        \\ * @par Fields
        \\ * - count: Number of events in this response
        \\ * - has_more: Non-zero if more results available (pagination needed)
        \\ * - partial_result: Non-zero if query timed out before completion
        \\ */
    ;

    // polygon_vertex_t documentation
    pub const polygon_vertex_t =
        \\/**
        \\ * @brief A vertex point in a polygon for geospatial queries.
        \\ * @details Coordinates are in nanodegrees (1e-9 degrees).
        \\ */
    ;

    // hole_descriptor_t documentation
    pub const hole_descriptor_t =
        \\/**
        \\ * @brief Descriptor for a hole within a polygon.
        \\ * @details Holes use clockwise winding order (opposite of exterior ring).
        \\ */
    ;

    // ping_request_t documentation
    pub const ping_request_t =
        \\/**
        \\ * @brief Request structure for ping/health check operation.
        \\ */
    ;

    // status_request_t documentation
    pub const status_request_t =
        \\/**
        \\ * @brief Request structure for server status operation.
        \\ */
    ;

    // ping_response_t documentation
    pub const ping_response_t =
        \\/**
        \\ * @brief Response structure for ping/health check operation.
        \\ */
    ;

    // status_response_t documentation
    pub const status_response_t =
        \\/**
        \\ * @brief Server status response with index statistics.
        \\ * @details Provides insight into server capacity and resource usage.
        \\ */
    ;

    // topology_request_t documentation
    pub const topology_request_t =
        \\/**
        \\ * @brief Request structure for cluster topology information.
        \\ */
    ;

    // shard_info_t documentation
    pub const shard_info_t =
        \\/**
        \\ * @brief Information about a single shard in the cluster.
        \\ */
    ;

    // shard_status documentation
    pub const shard_status =
        \\/**
        \\ * @brief Status values for shards in the cluster topology.
        \\ */
    ;

    // topology_response_t documentation
    pub const topology_response_t =
        \\/**
        \\ * @brief Cluster topology response with shard information.
        \\ * @details Contains current cluster state and shard assignments.
        \\ */
    ;

    // ttl_operation_result documentation
    pub const ttl_operation_result =
        \\/**
        \\ * @brief Result codes for TTL (time-to-live) operations.
        \\ */
    ;

    // ttl_set_request_t documentation
    pub const ttl_set_request_t =
        \\/**
        \\ * @brief Request to set TTL on an entity.
        \\ * @details TTL is specified in seconds from the current time.
        \\ */
    ;

    // ttl_set_response_t documentation
    pub const ttl_set_response_t =
        \\/**
        \\ * @brief Response for TTL set operation.
        \\ * @details Contains both previous and new TTL values.
        \\ */
    ;

    // ttl_extend_request_t documentation
    pub const ttl_extend_request_t =
        \\/**
        \\ * @brief Request to extend TTL on an entity.
        \\ * @details Extends existing TTL by the specified number of seconds.
        \\ */
    ;

    // ttl_extend_response_t documentation
    pub const ttl_extend_response_t =
        \\/**
        \\ * @brief Response for TTL extend operation.
        \\ * @details Contains both previous and new TTL values.
        \\ */
    ;

    // ttl_clear_request_t documentation
    pub const ttl_clear_request_t =
        \\/**
        \\ * @brief Request to clear (remove) TTL from an entity.
        \\ * @details Entity will no longer expire automatically.
        \\ */
    ;

    // ttl_clear_response_t documentation
    pub const ttl_clear_response_t =
        \\/**
        \\ * @brief Response for TTL clear operation.
        \\ * @details Contains the previous TTL value before clearing.
        \\ */
    ;

    // arch_client_t documentation
    pub const arch_client_t =
        \\/**
        \\ * @brief Opaque client handle for ArcherDB connections.
        \\ * @details This struct must be "pinned" (not copyable or movable), as its
        \\ *          address must remain stable throughout the lifetime of the client.
        \\ *
        \\ * @par Memory Ownership
        \\ * The client owns all connection resources. Call arch_client_deinit() to release.
        \\ *
        \\ * @par Thread Safety
        \\ * NOT thread-safe. Create one client per thread, or use external synchronization.
        \\ * The completion callback may be invoked from a different thread than arch_client_submit().
        \\ */
    ;

    // arch_packet_t documentation
    pub const arch_packet_t =
        \\/**
        \\ * @brief Packet structure for submitting requests to the server.
        \\ * @details This struct must be "pinned" (not copyable or movable), as its
        \\ *          address must remain stable throughout the lifetime of the request.
        \\ *
        \\ * @par Fields
        \\ * - user_data: Application-defined context pointer
        \\ * - data: Pointer to request data (operation-specific)
        \\ * - data_size: Size of request data in bytes
        \\ * - user_tag: Application-defined request identifier
        \\ * - operation: ARCH_OPERATION value for this request
        \\ * - status: ARCH_PACKET_STATUS set on completion
        \\ */
    ;

    // arch_operation documentation
    pub const arch_operation =
        \\/**
        \\ * @brief Operation codes for ArcherDB requests.
        \\ * @details Set packet.operation to one of these values before calling arch_client_submit().
        \\ */
    ;

    // arch_packet_status documentation
    pub const arch_packet_status =
        \\/**
        \\ * @brief Status codes for completed packets.
        \\ * @details Check packet.status after completion callback to determine result.
        \\ */
    ;

    // arch_init_status documentation
    pub const arch_init_status =
        \\/**
        \\ * @brief Status codes for client initialization.
        \\ * @details Returned by arch_client_init() and arch_client_init_echo().
        \\ */
    ;

    // arch_client_status documentation
    pub const arch_client_status =
        \\/**
        \\ * @brief Status codes for client operations.
        \\ * @details Returned by arch_client_submit(), arch_client_deinit(), etc.
        \\ */
    ;

    // arch_register_log_callback_status documentation
    pub const arch_register_log_callback_status =
        \\/**
        \\ * @brief Status codes for log callback registration.
        \\ */
    ;

    // arch_log_level documentation
    pub const arch_log_level =
        \\/**
        \\ * @brief Log levels for the log callback.
        \\ */
    ;

    // arch_init_parameters documentation
    pub const arch_init_parameters =
        \\/**
        \\ * @brief Parameters used during client initialization.
        \\ * @details Retrieved via arch_client_init_parameters().
        \\ */
    ;
};

/// Get documentation for a type name
fn getTypeDocs(comptime c_name: []const u8) ?[]const u8 {
    // Map C names to doc field names using direct comparison
    if (std.mem.eql(u8, c_name, "GEO_EVENT_FLAGS")) return type_docs.geo_event_flags;
    if (std.mem.eql(u8, c_name, "geo_event_t")) return type_docs.geo_event_t;
    if (std.mem.eql(u8, c_name, "INSERT_GEO_EVENT_RESULT")) return type_docs.insert_geo_event_result;
    if (std.mem.eql(u8, c_name, "insert_geo_events_result_t")) return type_docs.insert_geo_events_result_t;
    if (std.mem.eql(u8, c_name, "delete_entities_result_t")) return type_docs.delete_entities_result_t;
    if (std.mem.eql(u8, c_name, "query_uuid_filter_t")) return type_docs.query_uuid_filter_t;
    if (std.mem.eql(u8, c_name, "query_uuid_response_t")) return type_docs.query_uuid_response_t;
    if (std.mem.eql(u8, c_name, "query_uuid_batch_filter_t")) return type_docs.query_uuid_batch_filter_t;
    if (std.mem.eql(u8, c_name, "query_uuid_batch_result_t")) return type_docs.query_uuid_batch_result_t;
    if (std.mem.eql(u8, c_name, "query_radius_filter_t")) return type_docs.query_radius_filter_t;
    if (std.mem.eql(u8, c_name, "query_polygon_filter_t")) return type_docs.query_polygon_filter_t;
    if (std.mem.eql(u8, c_name, "query_latest_filter_t")) return type_docs.query_latest_filter_t;
    if (std.mem.eql(u8, c_name, "query_response_t")) return type_docs.query_response_t;
    if (std.mem.eql(u8, c_name, "polygon_vertex_t")) return type_docs.polygon_vertex_t;
    if (std.mem.eql(u8, c_name, "hole_descriptor_t")) return type_docs.hole_descriptor_t;
    if (std.mem.eql(u8, c_name, "ping_request_t")) return type_docs.ping_request_t;
    if (std.mem.eql(u8, c_name, "status_request_t")) return type_docs.status_request_t;
    if (std.mem.eql(u8, c_name, "ping_response_t")) return type_docs.ping_response_t;
    if (std.mem.eql(u8, c_name, "status_response_t")) return type_docs.status_response_t;
    if (std.mem.eql(u8, c_name, "topology_request_t")) return type_docs.topology_request_t;
    if (std.mem.eql(u8, c_name, "shard_info_t")) return type_docs.shard_info_t;
    if (std.mem.eql(u8, c_name, "SHARD_STATUS")) return type_docs.shard_status;
    if (std.mem.eql(u8, c_name, "topology_response_t")) return type_docs.topology_response_t;
    if (std.mem.eql(u8, c_name, "TTL_OPERATION_RESULT")) return type_docs.ttl_operation_result;
    if (std.mem.eql(u8, c_name, "ttl_set_request_t")) return type_docs.ttl_set_request_t;
    if (std.mem.eql(u8, c_name, "ttl_set_response_t")) return type_docs.ttl_set_response_t;
    if (std.mem.eql(u8, c_name, "ttl_extend_request_t")) return type_docs.ttl_extend_request_t;
    if (std.mem.eql(u8, c_name, "ttl_extend_response_t")) return type_docs.ttl_extend_response_t;
    if (std.mem.eql(u8, c_name, "ttl_clear_request_t")) return type_docs.ttl_clear_request_t;
    if (std.mem.eql(u8, c_name, "ttl_clear_response_t")) return type_docs.ttl_clear_response_t;
    if (std.mem.eql(u8, c_name, "arch_client_t")) return type_docs.arch_client_t;
    if (std.mem.eql(u8, c_name, "arch_packet_t")) return type_docs.arch_packet_t;
    if (std.mem.eql(u8, c_name, "ARCH_OPERATION")) return type_docs.arch_operation;
    if (std.mem.eql(u8, c_name, "ARCH_PACKET_STATUS")) return type_docs.arch_packet_status;
    if (std.mem.eql(u8, c_name, "ARCH_INIT_STATUS")) return type_docs.arch_init_status;
    if (std.mem.eql(u8, c_name, "ARCH_CLIENT_STATUS")) return type_docs.arch_client_status;
    if (std.mem.eql(u8, c_name, "ARCH_REGISTER_LOG_CALLBACK_STATUS")) return type_docs.arch_register_log_callback_status;
    if (std.mem.eql(u8, c_name, "ARCH_LOG_LEVEL")) return type_docs.arch_log_level;
    if (std.mem.eql(u8, c_name, "arch_init_parameters_t")) return type_docs.arch_init_parameters;
    return null;
}

const type_mappings = .{
    // ArcherDB GeoEvent types (geospatial database core)
    .{ exports.geo_event_flags, "GEO_EVENT_FLAGS" },
    .{ exports.geo_event_t, "geo_event_t" },
    .{ exports.insert_geo_event_result, "INSERT_GEO_EVENT_RESULT" },
    .{ exports.insert_geo_events_result_t, "insert_geo_events_result_t" },
    .{ exports.delete_entities_result_t, "delete_entities_result_t" },
    .{ exports.query_uuid_filter_t, "query_uuid_filter_t" },
    .{ exports.query_uuid_response_t, "query_uuid_response_t" },
    .{ exports.query_uuid_batch_filter_t, "query_uuid_batch_filter_t" },
    .{ exports.query_uuid_batch_result_t, "query_uuid_batch_result_t" },
    .{ exports.query_radius_filter_t, "query_radius_filter_t" },
    .{ exports.query_polygon_filter_t, "query_polygon_filter_t" },
    .{ exports.query_latest_filter_t, "query_latest_filter_t" },
    .{ exports.query_response_t, "query_response_t" },
    .{ exports.polygon_vertex_t, "polygon_vertex_t" },
    .{ exports.hole_descriptor_t, "hole_descriptor_t" },
    .{ exports.ping_request_t, "ping_request_t" },
    .{ exports.status_request_t, "status_request_t" },
    .{ exports.ping_response_t, "ping_response_t" },
    .{ exports.status_response_t, "status_response_t" },
    .{ exports.topology_request_t, "topology_request_t" },
    .{ exports.shard_info_t, "shard_info_t" },
    .{ exports.shard_status, "SHARD_STATUS" },
    .{ exports.topology_response_t, "topology_response_t" },
    // TTL Operations
    .{ exports.ttl_operation_result, "TTL_OPERATION_RESULT" },
    .{ exports.ttl_set_request_t, "ttl_set_request_t" },
    .{ exports.ttl_set_response_t, "ttl_set_response_t" },
    .{ exports.ttl_extend_request_t, "ttl_extend_request_t" },
    .{ exports.ttl_extend_response_t, "ttl_extend_response_t" },
    .{ exports.ttl_clear_request_t, "ttl_clear_request_t" },
    .{ exports.ttl_clear_response_t, "ttl_clear_response_t" },
    // Client types
    .{ exports.arch_client_t, "arch_client_t" },
    .{ exports.arch_packet_t, "arch_packet_t" },
    .{ exports.arch_operation, "ARCH_OPERATION" },
    .{ exports.arch_packet_status, "ARCH_PACKET_STATUS" },
    .{ exports.arch_init_status, "ARCH_INIT_STATUS" },
    .{ exports.arch_client_status, "ARCH_CLIENT_STATUS" },
    .{ exports.arch_register_log_callback_status, "ARCH_REGISTER_LOG_CALLBACK_STATUS" },
    .{ exports.arch_log_level, "ARCH_LOG_LEVEL" },
    .{ exports.arch_init_parameters, "arch_init_parameters_t" },
};

fn resolve_c_type(comptime Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .array => |info| return resolve_c_type(info.child),
        .@"enum" => |info| return resolve_c_type(info.tag_type),
        .@"struct" => {
            inline for (type_mappings) |mapping| {
                if (Type == mapping[0]) return mapping[1];
            }
            return resolve_c_type(std.meta.Int(.unsigned, @bitSizeOf(Type)));
        },
        .bool => return "uint8_t",
        .int => |info| {
            if (info.signedness == .unsigned) {
                return switch (info.bits) {
                    8 => "uint8_t",
                    16 => "uint16_t",
                    32 => "uint32_t",
                    64 => "uint64_t",
                    128 => "arch_uint128_t",
                    else => @compileError("invalid int type"),
                };
            } else {
                return switch (info.bits) {
                    8 => "int8_t",
                    16 => "int16_t",
                    32 => "int32_t",
                    64 => "int64_t",
                    128 => "arch_int128_t",
                    else => @compileError("invalid int type"),
                };
            }
        },
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => return resolve_c_type(info.child),
            else => @compileError("Unsupported optional type: " ++ @typeName(Type)),
        },
        .pointer => |info| {
            assert(info.size != .slice);
            assert(!info.is_allowzero);

            inline for (type_mappings) |type_mapping| {
                const ZigType = type_mapping[0];
                const c_name = type_mapping[1];

                if (info.child == ZigType) {
                    const prefix = if (@typeInfo(ZigType) == .@"struct") "struct " else "";
                    return prefix ++ c_name ++ "*";
                }
            }

            return comptime resolve_c_type(info.child) ++ "*";
        },
        .void, .@"opaque" => return "void",
        else => @compileError("Unhandled type: " ++ @typeName(Type)),
    }
}

fn to_uppercase(comptime input: []const u8) [input.len]u8 {
    comptime var output: [input.len]u8 = undefined;
    inline for (&output, 0..) |*char, i| {
        char.* = input[i];
        char.* -= 32 * @as(u8, @intFromBool(char.* >= 'a' and char.* <= 'z'));
    }
    return output;
}

fn emit_enum(
    buffer: *std.ArrayList(u8),
    comptime Type: type,
    comptime type_info: anytype,
    comptime c_name: []const u8,
    comptime skip_fields: []const []const u8,
) !void {
    var suffix_pos = std.mem.lastIndexOfScalar(u8, c_name, '_').?;
    if (std.mem.count(u8, c_name, "_") == 1) suffix_pos = c_name.len;

    try buffer.writer().print("typedef enum {s} {{\n", .{c_name});

    inline for (type_info.fields, 0..) |field, i| {
        if (comptime std.mem.startsWith(u8, field.name, "deprecated_")) continue;
        comptime var skip = false;
        inline for (skip_fields) |sf| {
            skip = skip or comptime std.mem.eql(u8, sf, field.name);
        }

        if (!skip) {
            const field_name = to_uppercase(field.name);
            if (@typeInfo(Type) == .@"enum") {
                try buffer.writer().print("    {s}_{s} = {},\n", .{
                    c_name[0..suffix_pos],
                    @as([]const u8, &field_name),
                    @intFromEnum(@field(Type, field.name)),
                });
            } else {
                // Packed structs.
                try buffer.writer().print("    {s}_{s} = 1 << {},\n", .{
                    c_name[0..suffix_pos],
                    @as([]const u8, &field_name),
                    i,
                });
            }
        }
    }

    try buffer.writer().print("}} {s};\n\n", .{c_name});
}

fn emit_struct(
    buffer: *std.ArrayList(u8),
    comptime type_info: anytype,
    comptime c_name: []const u8,
) !void {
    try buffer.writer().print("typedef struct {s} {{\n", .{c_name});

    inline for (type_info.fields) |field| {
        try buffer.writer().print("    {s} {s}", .{
            resolve_c_type(field.type),
            field.name,
        });

        switch (@typeInfo(field.type)) {
            .array => |array| try buffer.writer().print("[{d}]", .{array.len}),
            else => {},
        }

        try buffer.writer().print(";\n", .{});
    }

    try buffer.writer().print("}} {s};\n\n", .{c_name});
}

pub fn main() !void {
    @setEvalBranchQuota(100_000);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer = std.ArrayList(u8).init(allocator);

    // File-level Doxygen documentation
    try buffer.writer().print(
        \\/**
        \\ * @file arch_client.h
        \\ * @brief ArcherDB C Client - High-performance geospatial database client
        \\ * @version 0.1.0
        \\ *
        \\ * @details This header provides the C API for interacting with ArcherDB,
        \\ *          a high-performance geospatial database optimized for real-time
        \\ *          location tracking and spatial queries.
        \\ *
        \\ * @section memory_ownership Memory Ownership
        \\ * - **Client resources**: The arch_client_t owns all connection and network resources.
        \\ *   Call arch_client_deinit() to release these resources.
        \\ * - **Request data**: Caller owns geo_event_t arrays and filter structs passed to operations.
        \\ *   Data must remain valid until the completion callback is invoked.
        \\ * - **Response data**: Data passed to completion callbacks is library-owned.
        \\ *   Copy any data you need to retain before the callback returns.
        \\ *
        \\ * @section thread_safety Thread Safety
        \\ * - The arch_client_t is NOT thread-safe. Do not call arch_client_submit() from
        \\ *   multiple threads without external synchronization.
        \\ * - **Recommended**: Create one arch_client_t per thread, or use a mutex.
        \\ * - The completion callback may be invoked from a different thread than the
        \\ *   thread that called arch_client_submit().
        \\ *
        \\ * @section error_codes Error Code Ranges
        \\ * - 0: Success
        \\ * - 1-99: Protocol errors (message format, checksums, version)
        \\ * - 100-199: Validation errors (invalid inputs, constraint violations)
        \\ * - 200-299: State errors (multi-region 213-218, sharding 220-224)
        \\ * - 300-399: Resource errors (limits exceeded, capacity)
        \\ * - 400-499: Security errors (auth, encryption 410-414)
        \\ * - 500-599: Internal errors (bugs, should not occur)
        \\ *
        \\ * See error-codes.md for complete documentation.
        \\ *
        \\ * @warning This file is auto-generated by arch_client_header.zig. Do not modify directly.
        \\ */
        \\
        \\ //////////////////////////////////////////////////////////
        \\ // This file was auto-generated by arch_client_header.zig //
        \\ //              Do not manually modify.                 //
        \\ //////////////////////////////////////////////////////////
        \\
        \\#ifndef ARCH_CLIENT_H
        \\#define ARCH_CLIENT_H
        \\
        \\#ifdef __cplusplus
        \\extern "C" {{
        \\#endif
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\
        \\/** @brief 128-bit unsigned integer type */
        \\typedef __uint128_t arch_uint128_t;
        \\/** @brief 128-bit signed integer type */
        \\typedef __int128_t arch_int128_t;
        \\
        \\
    , .{});

    // Emit C type declarations.
    inline for (type_mappings) |type_mapping| {
        const ZigType = type_mapping[0];
        const c_name = type_mapping[1];

        // Emit Doxygen documentation for this type
        if (comptime getTypeDocs(c_name)) |docs| {
            try buffer.writer().print("{s}\n", .{docs});
        }

        switch (@typeInfo(ZigType)) {
            .@"struct" => |info| switch (info.layout) {
                .auto => @compileError("Invalid C struct type: " ++ @typeName(ZigType)),
                .@"packed" => try emit_enum(&buffer, ZigType, info, c_name, &.{"padding"}),
                .@"extern" => try emit_struct(&buffer, info, c_name),
            },
            .@"enum" => |info| {
                comptime var skip: []const []const u8 = &.{};
                if (ZigType == exports.arch_operation) {
                    skip = &.{ "reserved", "root", "register" };
                }

                try emit_enum(&buffer, ZigType, info, c_name, skip);
            },
            else => try buffer.writer().print("typedef {s} {s}; \n\n", .{
                resolve_c_type(ZigType),
                c_name,
            }),
        }
    }

    // Emit C function declarations with Doxygen documentation.
    try buffer.writer().print(
        \\/**
        \\ * @brief Initialize a new ArcherDB client.
        \\ * @details Connects to the cluster at the specified addresses and completes
        \\ *          submitted packets by invoking the callback with the given context.
        \\ *
        \\ * @param[out] client_out  Pointer to client handle to initialize (must be pinned)
        \\ * @param[in]  cluster_id  128-bit cluster ID as 16-byte little-endian array
        \\ * @param[in]  address_ptr Null-terminated string of comma-separated addresses (e.g., "host:port,host:port")
        \\ * @param[in]  address_len Length of address string in bytes
        \\ * @param[in]  completion_ctx  Application context passed to completion callback
        \\ * @param[in]  completion_callback  Function called when requests complete
        \\ *
        \\ * @return ARCH_INIT_SUCCESS on success, or an error code on failure
        \\ *
        \\ * @note The client handle must remain at a stable address (pinned memory).
        \\ * @note Call arch_client_deinit() to release resources when done.
        \\ *
        \\ * @par Thread Safety
        \\ * This function is NOT thread-safe. Initialize clients from a single thread.
        \\ */
        \\ARCH_INIT_STATUS arch_client_init(
        \\    arch_client_t *client_out,
        \\    const uint8_t cluster_id[16],
        \\    const char *address_ptr,
        \\    uint32_t address_len,
        \\    uintptr_t completion_ctx,
        \\    void (*completion_callback)(uintptr_t, arch_packet_t*, uint64_t, const uint8_t*, uint32_t)
        \\);
        \\
        \\/**
        \\ * @brief Initialize a new ArcherDB echo client for testing.
        \\ * @details Creates a client that echoes back any submitted data without
        \\ *          connecting to a real cluster. Useful for unit testing.
        \\ *
        \\ * @param[out] client_out  Pointer to client handle to initialize
        \\ * @param[in]  cluster_id  128-bit cluster ID as 16-byte little-endian array
        \\ * @param[in]  address_ptr Address string (not used for echo client)
        \\ * @param[in]  address_len Length of address string
        \\ * @param[in]  completion_ctx  Application context passed to completion callback
        \\ * @param[in]  completion_callback  Function called when requests complete
        \\ *
        \\ * @return ARCH_INIT_SUCCESS on success, or an error code on failure
        \\ */
        \\ARCH_INIT_STATUS arch_client_init_echo(
        \\    arch_client_t *client_out,
        \\    const uint8_t cluster_id[16],
        \\    const char *address_ptr,
        \\    uint32_t address_len,
        \\    uintptr_t completion_ctx,
        \\    void (*completion_callback)(uintptr_t, arch_packet_t*, uint64_t, const uint8_t*, uint32_t)
        \\);
        \\
        \\/**
        \\ * @brief Retrieve the initialization parameters for a client.
        \\ *
        \\ * @param[in]  client  Initialized client handle
        \\ * @param[out] init_parameters_out  Pointer to receive initialization parameters
        \\ *
        \\ * @return ARCH_CLIENT_OK on success, ARCH_CLIENT_INVALID if client is invalid
        \\ */
        \\ARCH_CLIENT_STATUS arch_client_init_parameters(
        \\    arch_client_t* client,
        \\    arch_init_parameters_t* init_parameters_out
        \\);
        \\
        \\/**
        \\ * @brief Retrieve the completion context for a client.
        \\ *
        \\ * @param[in]  client  Initialized client handle
        \\ * @param[out] completion_ctx_out  Pointer to receive the completion context
        \\ *
        \\ * @return ARCH_CLIENT_OK on success, ARCH_CLIENT_INVALID if client is invalid
        \\ */
        \\ARCH_CLIENT_STATUS arch_client_completion_context(
        \\    arch_client_t* client,
        \\    uintptr_t* completion_ctx_out
        \\);
        \\
        \\/**
        \\ * @brief Submit a request packet to the server.
        \\ * @details The packet must have its operation, data, and data_size fields set.
        \\ *          Once completed, the completion_callback will be invoked with the
        \\ *          completion_ctx and the packet from a separate thread.
        \\ *
        \\ * @param[in] client  Initialized client handle
        \\ * @param[in] packet  Request packet (must be pinned until callback is invoked)
        \\ *
        \\ * @return ARCH_CLIENT_OK on success, ARCH_CLIENT_INVALID if client is invalid
        \\ *
        \\ * @note The packet must remain valid and at a stable address until the
        \\ *       completion callback is invoked.
        \\ * @note The completion callback may be invoked from a different thread.
        \\ *
        \\ * @par Memory Ownership
        \\ * Caller owns the packet and its data until the completion callback.
        \\ * Data in the callback is library-owned and must be copied if needed.
        \\ */
        \\ARCH_CLIENT_STATUS arch_client_submit(
        \\    arch_client_t *client,
        \\    arch_packet_t *packet
        \\);
        \\
        \\/**
        \\ * @brief Close the client and release all resources.
        \\ * @details Any previously submitted packets will be completed with
        \\ *          ARCH_PACKET_CLIENT_SHUTDOWN status before resources are freed.
        \\ *
        \\ * @param[in] client  Client handle to close
        \\ *
        \\ * @return ARCH_CLIENT_OK on success, ARCH_CLIENT_INVALID if client is invalid
        \\ *
        \\ * @note After this call, the client handle is invalid and must not be used.
        \\ * @note Wait for all pending callbacks to complete before calling this.
        \\ */
        \\ARCH_CLIENT_STATUS arch_client_deinit(
        \\    arch_client_t *client
        \\);
        \\
        \\/**
        \\ * @brief Register or unregister a log callback for client diagnostics.
        \\ *
        \\ * @param[in] callback  Log callback function, or NULL to unregister
        \\ * @param[in] debug     If true, include debug-level messages
        \\ *
        \\ * @return ARCH_REGISTER_LOG_CALLBACK_SUCCESS on success
        \\ * @return ARCH_REGISTER_LOG_CALLBACK_ALREADY_REGISTERED if already registered
        \\ * @return ARCH_REGISTER_LOG_CALLBACK_NOT_REGISTERED if unregistering when not registered
        \\ */
        \\ARCH_REGISTER_LOG_CALLBACK_STATUS arch_client_register_log_callback(
        \\    void (*callback)(ARCH_LOG_LEVEL, const uint8_t*, uint32_t),
        \\    bool debug
        \\);
        \\
        \\
    , .{});

    try buffer.writer().print(
        \\#ifdef __cplusplus
        \\}} // extern "C"
        \\#endif
        \\
        \\#endif // ARCH_CLIENT_H
        \\
    , .{});

    try std.io.getStdOut().writeAll(buffer.items);
}
