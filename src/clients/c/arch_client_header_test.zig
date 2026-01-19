// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const assert = std.debug.assert;

const exports = @import("arch_client.zig").exports;
const c = @cImport(@cInclude("arch_client.h"));

fn to_uppercase(comptime input: []const u8) []const u8 {
    comptime var uppercase: [input.len]u8 = undefined;
    inline for (input, 0..) |char, i| {
        const is_lowercase = (char >= 'a') and (char <= 'z');
        uppercase[i] = char - (@as(u8, @intFromBool(is_lowercase)) * 32);
    }
    return &uppercase;
}

fn to_snakecase(comptime input: []const u8) []const u8 {
    comptime var output: []const u8 = &.{};
    inline for (input, 0..) |char, i| {
        const is_uppercase = (char >= 'A') and (char <= 'Z');
        if (is_uppercase and i > 0) output = "_" ++ output;
        output = output ++ &[_]u8{char};
    }
    return output;
}

test "valid arch_client.h" {
    @setEvalBranchQuota(20_000);

    comptime for (.{
        .{ exports.geo_event_flags, "GEO_EVENT_FLAGS" },
        .{ exports.geo_event_t, "geo_event_t" },
        .{ exports.insert_geo_event_result, "INSERT_GEO_EVENT_RESULT" },
        .{ exports.insert_geo_events_result_t, "insert_geo_events_result_t" },
        .{ exports.delete_entities_result_t, "delete_entities_result_t" },
        .{ exports.query_uuid_filter_t, "query_uuid_filter_t" },
        .{ exports.query_uuid_response_t, "query_uuid_response_t" },
        .{ exports.query_radius_filter_t, "query_radius_filter_t" },
        .{ exports.query_polygon_filter_t, "query_polygon_filter_t" },
        .{ exports.query_latest_filter_t, "query_latest_filter_t" },
        .{ exports.query_response_t, "query_response_t" },
        .{ exports.polygon_vertex_t, "polygon_vertex_t" },
        .{ exports.hole_descriptor_t, "hole_descriptor_t" },
        .{ exports.ttl_operation_result, "TTL_OPERATION_RESULT" },
        .{ exports.ttl_set_request_t, "ttl_set_request_t" },
        .{ exports.ttl_set_response_t, "ttl_set_response_t" },
        .{ exports.ttl_extend_request_t, "ttl_extend_request_t" },
        .{ exports.ttl_extend_response_t, "ttl_extend_response_t" },
        .{ exports.ttl_clear_request_t, "ttl_clear_request_t" },
        .{ exports.ttl_clear_response_t, "ttl_clear_response_t" },

        .{ u128, "arch_uint128_t" },
        .{ i128, "arch_int128_t" },
        .{ exports.arch_client_t, "arch_client_t" },
        .{ exports.arch_packet_t, "arch_packet_t" },
        .{ exports.arch_init_status, "ARCH_INIT_STATUS" },
        .{ exports.arch_client_status, "ARCH_CLIENT_STATUS" },
        .{ exports.arch_packet_status, "ARCH_PACKET_STATUS" },
        .{ exports.arch_operation, "ARCH_OPERATION" },
        .{ exports.arch_register_log_callback_status, "ARCH_REGISTER_LOG_CALLBACK_STATUS" },
        .{ exports.arch_log_level, "ARCH_LOG_LEVEL" },
        .{ exports.arch_init_parameters, "arch_init_parameters_t" },
    }) |c_export| {
        const ty: type = c_export[0];
        const c_type_name = @as([]const u8, c_export[1]);
        const c_type: type = @field(c, c_type_name);

        switch (@typeInfo(ty)) {
            .int => assert(ty == c_type),
            .pointer => assert(@sizeOf(ty) == @sizeOf(c_type)),
            .@"enum" => {
                const prefix_offset = std.mem.lastIndexOfScalar(u8, c_type_name, '_').?;
                var c_enum_prefix: []const u8 = c_type_name[0 .. prefix_offset + 1];
                assert(c_type == c_uint);

                // ARCH_STATUS and ARCH_OPERATION are special cases in naming
                if (std.mem.eql(u8, c_type_name, "ARCH_STATUS") or
                    std.mem.eql(u8, c_type_name, "ARCH_OPERATION"))
                {
                    c_enum_prefix = c_type_name ++ "_";
                }

                // Compare the enum int values in C to the enum int values in Zig.
                for (std.meta.fields(ty)) |field| {
                    if (std.mem.startsWith(u8, field.name, "deprecated_")) continue;
                    const c_enum_field = to_uppercase(to_snakecase(field.name));
                    const c_value = @field(c, c_enum_prefix ++ c_enum_field);

                    const zig_value = @intFromEnum(@field(ty, field.name));
                    assert(zig_value == c_value);
                }
            },
            .@"struct" => |type_info| switch (type_info.layout) {
                .auto => @compileError("struct must be extern or packed to be used in C"),
                .@"packed" => {
                    const prefix_offset = std.mem.lastIndexOfScalar(u8, c_type_name, '_').?;
                    const c_enum_prefix = c_type_name[0 .. prefix_offset + 1];
                    assert(c_type == c_uint);

                    for (std.meta.fields(ty)) |field| {
                        if (!std.mem.eql(u8, field.name, "padding")) {
                            // Get the bit value in the C enum.
                            const c_enum_field = to_uppercase(to_snakecase(field.name));
                            const c_value = @field(c, c_enum_prefix ++ c_enum_field);

                            // Compare the bit value to the packed struct's field.
                            var instance = std.mem.zeroes(ty);
                            @field(instance, field.name) = true;
                            assert(@as(type_info.backing_integer.?, @bitCast(instance)) == c_value);
                        }
                    }
                },
                .@"extern" => {
                    // Ensure structs are effectively the same.
                    assert(@sizeOf(ty) == @sizeOf(c_type));
                    if (@alignOf(ty) != @alignOf(c_type)) {
                        @compileLog(ty, c_type);
                    }
                    assert(@alignOf(ty) == @alignOf(c_type));

                    for (std.meta.fields(ty)) |field| {
                        // In C, packed structs and enums are replaced with integers.
                        var field_type = field.type;
                        switch (@typeInfo(field_type)) {
                            .@"struct" => |info| {
                                assert(info.layout == .@"packed");
                                assert(@sizeOf(field_type) <= @sizeOf(u128));
                                field_type = std.meta.Int(.unsigned, @bitSizeOf(field_type));
                            },
                            .@"enum" => |info| field_type = info.tag_type,
                            .bool => field_type = u8,
                            else => {},
                        }

                        // In C, pointers are opaque so we compare only the field sizes,
                        const c_field_type = @TypeOf(@field(@as(c_type, undefined), field.name));
                        switch (@typeInfo(c_field_type)) {
                            .pointer => |info| {
                                assert(info.size == .c);
                                assert(@sizeOf(c_field_type) == @sizeOf(field_type));
                            },
                            else => assert(c_field_type == field_type),
                        }
                    }
                },
            },
            else => |i| @compileLog("TODO", i),
        }
    };
}
