// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const vsr = @import("vsr");

const assert = std.debug.assert;
const tb = vsr.tigerbeetle;
const tb_client = vsr.tb_client;

const TypeMapping = struct {
    name: []const u8,
    hidden_fields: []const []const u8 = &.{},
    docs_link: ?[]const u8 = null,

    pub fn hidden(comptime self: @This(), name: []const u8) bool {
        inline for (self.hidden_fields) |field| {
            if (std.mem.eql(u8, field, name)) {
                return true;
            }
        } else return false;
    }
};

// ArcherDB geospatial type mappings
// NOTE: Legacy TigerBeetle financial types (Account, Transfer, etc.) have been removed.
// ArcherDB is a geospatial database only.
const type_mappings = .{
    // GeoEvent and related types
    .{ tb.GeoEvent, TypeMapping{
        .name = "GeoEvent",
        .hidden_fields = &.{"reserved"},
    } },
    .{ @import("../../geo_event.zig").GeoEventFlags, TypeMapping{
        .name = "GeoEventFlags",
        .hidden_fields = &.{"padding"},
    } },
    .{ tb.InsertGeoEventResult, TypeMapping{
        .name = "InsertGeoEventError",
    } },
    .{ tb.InsertGeoEventsResult, TypeMapping{
        .name = "InsertGeoEventsError",
    } },
    .{ tb.DeleteEntityResult, TypeMapping{
        .name = "DeleteEntityError",
    } },
    .{ tb.DeleteEntitiesResult, TypeMapping{
        .name = "DeleteEntitiesError",
    } },
    // Query filter types
    .{ tb.QueryUuidFilter, TypeMapping{
        .name = "QueryUuidFilter",
        .hidden_fields = &.{"reserved"},
    } },
    .{ tb.QueryRadiusFilter, TypeMapping{
        .name = "QueryRadiusFilter",
        .hidden_fields = &.{"reserved"},
    } },
    .{ tb.QueryPolygonFilter, TypeMapping{
        .name = "QueryPolygonFilter",
        .hidden_fields = &.{"reserved"},
    } },
    .{ tb.QueryLatestFilter, TypeMapping{
        .name = "QueryLatestFilter",
        .hidden_fields = &.{ "reserved", "_reserved_align" },
    } },
    .{ tb.QueryResponse, TypeMapping{
        .name = "QueryResponse",
        .hidden_fields = &.{"reserved"},
    } },
    .{ tb.PolygonVertex, TypeMapping{
        .name = "PolygonVertex",
    } },
    // VSR operations
    .{ tb_client.Operation, TypeMapping{
        .name = "Operation",
        .hidden_fields = &.{ "reserved", "root", "register" },
    } },
};

fn typescript_type(comptime Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .@"enum" => return comptime get_mapped_type_name(Type) orelse @compileError(
            "Type " ++ @typeName(Type) ++ " not mapped.",
        ),
        .@"struct" => |info| switch (info.layout) {
            .@"packed" => return comptime typescript_type(
                std.meta.Int(.unsigned, @bitSizeOf(Type)),
            ),
            else => return comptime get_mapped_type_name(Type) orelse @compileError(
                "Type " ++ @typeName(Type) ++ " not mapped.",
            ),
        },
        .int => |info| {
            // Support both signed and unsigned integers for ArcherDB's GeoEvent
            // (lat_nano, lon_nano, altitude_mm are signed i64/i32)
            _ = info; // signedness doesn't matter for TypeScript type
            return switch (@typeInfo(Type).int.bits) {
                8 => "number", // QueryResponse has_more, partial_result
                16 => "number",
                32 => "number",
                64 => "bigint",
                128 => "bigint",
                else => @compileError("invalid int type: " ++ @typeName(Type)),
            };
        },
        else => @compileError("Unhandled type: " ++ @typeName(Type)),
    }
}

fn get_mapped_type_name(comptime Type: type) ?[]const u8 {
    inline for (type_mappings) |type_mapping| {
        if (Type == type_mapping[0]) {
            return type_mapping[1].name;
        }
    } else return null;
}

fn emit_enum(
    buffer: *std.ArrayList(u8),
    comptime Type: type,
    comptime mapping: TypeMapping,
) !void {
    try emit_docs(buffer, mapping, 0, null);

    try buffer.writer().print("export enum {s} {{\n", .{mapping.name});

    inline for (@typeInfo(Type).@"enum".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "deprecated_")) continue;
        if (comptime mapping.hidden(field.name)) continue;

        try emit_docs(buffer, mapping, 1, field.name);

        try buffer.writer().print("  {s} = {d},\n", .{
            field.name,
            @intFromEnum(@field(Type, field.name)),
        });
    }

    try buffer.writer().print("}}\n\n", .{});
}

fn emit_packed_struct(
    buffer: *std.ArrayList(u8),
    comptime type_info: anytype,
    comptime mapping: TypeMapping,
) !void {
    assert(type_info.layout == .@"packed");
    try emit_docs(buffer, mapping, 0, null);

    try buffer.writer().print(
        \\export enum {s} {{
        \\  none = 0,
        \\
    , .{mapping.name});

    inline for (type_info.fields, 0..) |field, i| {
        if (comptime mapping.hidden(field.name)) continue;

        try emit_docs(buffer, mapping, 1, field.name);

        try buffer.writer().print("  {s} = (1 << {d}),\n", .{
            field.name,
            i,
        });
    }

    try buffer.writer().print("}}\n\n", .{});
}

fn emit_struct(
    buffer: *std.ArrayList(u8),
    comptime type_info: anytype,
    comptime mapping: TypeMapping,
) !void {
    try emit_docs(buffer, mapping, 0, null);

    try buffer.writer().print("export type {s} = {{\n", .{
        mapping.name,
    });

    inline for (type_info.fields) |field| {
        if (comptime mapping.hidden(field.name)) continue;

        try emit_docs(buffer, mapping, 1, field.name);

        switch (@typeInfo(field.type)) {
            .array => try buffer.writer().print("  {s}: Buffer\n", .{
                field.name,
            }),
            else => try buffer.writer().print(
                "  {s}: {s}\n",
                .{
                    field.name,
                    typescript_type(field.type),
                },
            ),
        }
    }

    try buffer.writer().print("}}\n\n", .{});
}

fn emit_docs(
    buffer: anytype,
    comptime mapping: TypeMapping,
    comptime indent: comptime_int,
    comptime field: ?[]const u8,
) !void {
    if (mapping.docs_link) |docs_link| {
        try buffer.writer().print(
            \\
            \\{[indent]s}/**
            \\{[indent]s}* See [{[name]s}](https://docs.tigerbeetle.com/{[docs_link]s}{[field]s})
            \\{[indent]s}*/
            \\
        , .{
            .indent = "  " ** indent,
            .name = field orelse mapping.name,
            .docs_link = docs_link,
            .field = field orelse "",
        });
    }
}

pub fn generate_bindings(buffer: *std.ArrayList(u8)) !void {
    @setEvalBranchQuota(100_000);

    try buffer.writer().print(
        \\///////////////////////////////////////////////////////
        \\// This file was auto-generated by node_bindings.zig //
        \\//              Do not manually modify.              //
        \\///////////////////////////////////////////////////////
        \\
        \\
    , .{});

    // Emit JS declarations.
    inline for (type_mappings) |type_mapping| {
        const ZigType = type_mapping[0];
        const mapping = type_mapping[1];

        switch (@typeInfo(ZigType)) {
            .@"struct" => |info| switch (info.layout) {
                .auto => @compileError(
                    "Only packed or extern structs are supported: " ++ @typeName(ZigType),
                ),
                .@"packed" => try emit_packed_struct(buffer, info, mapping),
                .@"extern" => try emit_struct(buffer, info, mapping),
            },
            .@"enum" => try emit_enum(buffer, ZigType, mapping),
            else => @compileError("Type cannot be represented: " ++ @typeName(ZigType)),
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer = std.ArrayList(u8).init(allocator);
    try generate_bindings(&buffer);
    try std.io.getStdOut().writeAll(buffer.items);
}
