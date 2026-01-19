// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! ArcherDB Vortex Workload - Geospatial Operations
//!
//! This workload runs in a loop, generating and executing geospatial operations on a cluster
//! through a _driver_.
//!
//! Any successful operations are reconciled with a model, tracking what entities exist. Future
//! operations are generated based on this model.
//!
//! After every operation, entities are queried, and basic invariants are checked.
//!
//! The workload and drivers communicate with a binary protocol over stdio. The protocol is based
//! on the extern structs in `src/archerdb.zig` and `src/geo_state_machine.zig`, and it works like
//! this:
//!
//! 1. Workload sends a request, which is:
//!    * the _operation_ (1 byte),
//!    * the _event count_ (4 bytes), and
//!    * the events (event count * size of event).
//! 2. The driver uses its client to submit those events. When receiving results, it sends them
//!    back on its stdout as:
//!    * the _operation_ (1 byte)
//!    * the _result count_ (4 bytes), and
//!    * the results (result count * size of result pair), where each pair holds an index and a
//!      result enum value (see `src/archerdb.zig`)
//! 3. The workload receives the results, and expects them to be of the same operation type as
//!    originally requested. There might be fewer results than events, because clients can omit
//!    .ok results.
//!
//! Additionally, the workload itself sends `Progress` events on its stdout back to the supervisor.
//! This is used for tracing and liveness checks.

const std = @import("std");
const stdx = @import("stdx");
const tb = @import("../../archerdb.zig");
const Operation = tb.Operation;
const GeoEvent = tb.GeoEvent;
const GeoEventFlags = tb.GeoEventFlags;
const InsertGeoEventsResult = tb.InsertGeoEventsResult;
const InsertGeoEventResult = tb.InsertGeoEventResult;
const QueryUuidResponse = tb.QueryUuidResponse;
const QueryUuidFilter = tb.QueryUuidFilter;
const QueryLatestFilter = tb.QueryLatestFilter;
const RingBufferType = stdx.RingBufferType;
const ratio = stdx.PRNG.ratio;

const log = std.log.scoped(.workload);
const assert = std.debug.assert;

const events_count_max = 8189;
const entities_count_max = 128;
const query_uuid_raw_len = 1 + @divExact(@sizeOf(GeoEvent), @sizeOf(QueryUuidResponse));

const DriverStdio = struct { input: std.fs.File, output: std.fs.File };

pub fn main(
    allocator: std.mem.Allocator,
    driver: *const DriverStdio,
) !void {
    var entities_buffer = std.mem.zeroes([entities_count_max]u128);

    var model = Model{
        .entities = std.ArrayListUnmanaged(u128).initBuffer(&entities_buffer),
    };

    const seed = std.crypto.random.int(u64);
    var prng = stdx.PRNG.from_seed(seed);

    const stdout = std.io.getStdOut().writer().any();

    _ = allocator;

    for (0..std.math.maxInt(u64)) |i| {
        const command_timestamp_start: u64 = @intCast(std.time.microTimestamp());
        const command = random_command(&prng, &model);
        const result = try execute(command, driver) orelse break;
        try reconcile(result, &command, &model);
        const command_timestamp_end: u64 = @intCast(std.time.microTimestamp());
        try progress_write(stdout, .{
            .event_count = command.event_count(),
            .timestamp_start_micros = command_timestamp_start,
            .timestamp_end_micros = command_timestamp_end,
        });

        const query_timestamp_start: u64 = @intCast(std.time.microTimestamp());
        const query = query_latest_events(&model);
        const query_result = try execute(query, driver) orelse break;
        try reconcile(query_result, &query, &model);
        const query_timestamp_end: u64 = @intCast(std.time.microTimestamp());
        try progress_write(stdout, .{
            .event_count = query.event_count(),
            .timestamp_start_micros = query_timestamp_start,
            .timestamp_end_micros = query_timestamp_end,
        });

        log.info(
            "entities created = {d}, events inserted = {d}, commands run = {d}",
            .{
                model.entities.items.len,
                model.events_inserted,
                i + 1,
            },
        );
    }
}

const Command = union(enum) {
    insert_events: []GeoEvent,
    query_uuid: []QueryUuidFilter,
    query_latest: []QueryLatestFilter,

    fn event_count(command: Command) usize {
        return switch (command) {
            .insert_events => |entries| entries.len,
            .query_uuid => |entries| entries.len,
            .query_latest => |entries| entries.len,
        };
    }
};

const CommandBuffers = FixedSizeBuffersType(Command);
var command_buffers: CommandBuffers = std.mem.zeroes(CommandBuffers);
var query_uuid_raw_buffer: [query_uuid_raw_len]QueryUuidResponse = undefined;

const Result = union(enum) {
    insert_events: []InsertGeoEventsResult,
    query_uuid: []GeoEvent,
    query_latest: []GeoEvent,
};
const ResultBuffers = FixedSizeBuffersType(Result);
var result_buffers: ResultBuffers = std.mem.zeroes(ResultBuffers);

fn execute(command: Command, driver: *const DriverStdio) !?Result {
    switch (command) {
        .query_uuid => |filters| {
            const operation = Operation.query_uuid;
            try send(driver, operation, filters);

            const raw_results = receive(driver, operation, query_uuid_raw_buffer[0..]) catch |err| {
                switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                }
            };
            return .{ .query_uuid = query_uuid_events(raw_results) };
        },
        inline else => |events, tag| {
            const operation = comptime operation_from_command(tag);
            try send(driver, operation, events);

            const buffer = @field(result_buffers, @tagName(tag))[0..events.len];
            const results = receive(driver, operation, buffer) catch |err| {
                switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                }
            };
            return @unionInit(Result, @tagName(tag), results);
        },
    }
}

/// State machine operations and Vortex workload commands are not 1:1. This function maps the
/// enum values from command to operation.
fn operation_from_command(tag: std.meta.Tag(Command)) Operation {
    return switch (tag) {
        .insert_events => .insert_events,
        .query_uuid => .query_uuid,
        .query_latest => .query_latest,
    };
}

fn reconcile(result: Result, command: *const Command, model: *Model) !void {
    switch (result) {
        .insert_events => |entries| {
            const events_new = command.insert_events;

            // Track results for all new events, assuming `.ok` if response from driver is
            // omitted.
            var events_results: [events_count_max]InsertGeoEventResult = undefined;
            @memset(events_results[0..events_new.len], .ok);

            // Fill in non-ok results.
            for (entries) |entry| {
                events_results[entry.index] = entry.result;
            }

            for (
                events_results[0..events_new.len],
                events_new,
                0..,
            ) |event_result, event, index| {
                if (event_result == .ok) {
                    // Track unique entity IDs
                    if (!model.entity_exists(event.entity_id)) {
                        if (model.entities.items.len < entities_count_max) {
                            model.entities.appendAssumeCapacity(event.entity_id);
                        }
                    }
                    model.events_inserted += 1;
                } else {
                    log.err("got result {s} for event {d}: entity_id={d}", .{
                        @tagName(event_result),
                        index,
                        event.entity_id,
                    });
                    return error.TestFailed;
                }
            }
        },
        .query_uuid => |events_found| {
            // Check that timestamps are monotonically increasing.
            var timestamp_max: u64 = 0;
            for (events_found) |event| {
                if (event.timestamp <= timestamp_max) {
                    log.err(
                        "event entity_id={d} timestamp {d} is not greater than " ++
                            "previous timestamp {d}",
                        .{ event.entity_id, event.timestamp, timestamp_max },
                    );
                    return error.TestFailed;
                }
                timestamp_max = event.timestamp;
            }
        },
        .query_latest => |events_found| {
            // Check that timestamps are monotonically increasing within results.
            var timestamp_max: u64 = 0;
            for (events_found) |event| {
                if (event.timestamp <= timestamp_max) {
                    log.err(
                        "event entity_id={d} timestamp {d} is not greater than " ++
                            "previous timestamp {d}",
                        .{ event.entity_id, event.timestamp, timestamp_max },
                    );
                    return error.TestFailed;
                }
                timestamp_max = event.timestamp;
            }
        },
    }
}

const LatestEvents = RingBufferType(u128, .{ .array = events_count_max });

/// Tracks information about the entities and events created by the workload.
const Model = struct {
    entities: std.ArrayListUnmanaged(u128),
    events_inserted: u64 = 0,
    latest_events: LatestEvents = LatestEvents.init(),

    // O(n) lookup, but it's limited by `entities_count_max`, so it's OK for this test.
    fn entity_exists(model: @This(), id: u128) bool {
        for (model.entities.items) |entity_id| {
            if (entity_id == id) return true;
        }
        return false;
    }
};

fn random_command(prng: *stdx.PRNG, model: *const Model) Command {
    const command_tag = prng.enum_weighted(std.meta.Tag(Command), .{
        .insert_events = 10,
        .query_uuid = if (model.entities.items.len > 0) 3 else 0,
        .query_latest = 2,
    });
    switch (command_tag) {
        .insert_events => return random_insert_events(prng, model),
        .query_uuid => return query_by_uuid(prng, model),
        .query_latest => return query_latest_events(model),
    }
}

fn random_insert_events(prng: *stdx.PRNG, model: *const Model) Command {
    const events_count = prng.range_inclusive(
        usize,
        1,
        @min(100, events_count_max),
    );
    assert(events_count <= events_count_max);

    var events = command_buffers.insert_events[0..events_count];
    for (events) |*event| {
        // Either use existing entity or create new one
        const entity_id = if (model.entities.items.len > 0 and prng.chance(ratio(3, 10)))
            model.entities.items[prng.index(model.entities.items)]
        else
            prng.range_inclusive(u128, 1, std.math.maxInt(u128));

        // Random coordinates: latitude -90 to +90, longitude -180 to +180
        // Stored as nanodegrees (10^-9 degrees)
        // Generate as unsigned then shift to signed range
        const lat_range: u64 = @intCast(GeoEvent.lat_nano_max - GeoEvent.lat_nano_min);
        const lon_range: u64 = @intCast(GeoEvent.lon_nano_max - GeoEvent.lon_nano_min);
        const lat_nano: i64 = @as(i64, @intCast(prng.int_inclusive(u64, lat_range))) +
            GeoEvent.lat_nano_min;
        const lon_nano: i64 = @as(i64, @intCast(prng.int_inclusive(u64, lon_range))) +
            GeoEvent.lon_nano_min;

        // Generate a random S2 cell ID (simplified - actual S2 calculation is complex)
        // In a real implementation, this would use proper S2 geometry
        const s2_cell_id: u64 = prng.int(u64);
        const timestamp_ns: u64 = @as(u64, @intCast(std.time.nanoTimestamp()));

        event.* = std.mem.zeroInit(GeoEvent, .{
            .id = GeoEvent.pack_id(s2_cell_id, timestamp_ns),
            .entity_id = entity_id,
            .lat_nano = lat_nano,
            .lon_nano = lon_nano,
            .timestamp = timestamp_ns,
            .flags = GeoEventFlags{},
        });
    }

    return .{ .insert_events = events[0..events_count] };
}

fn query_by_uuid(prng: *stdx.PRNG, model: *const Model) Command {
    // Query a random subset of known entities
    const query_count = @min(@as(usize, 1), model.entities.items.len);

    var filters = command_buffers.query_uuid[0..query_count];
    for (filters, 0..) |*filter, i| {
        const entity_idx = (prng.int(usize) + i) % model.entities.items.len;
        filter.* = std.mem.zeroInit(QueryUuidFilter, .{
            .entity_id = model.entities.items[entity_idx],
        });
    }

    return .{ .query_uuid = filters[0..query_count] };
}

fn query_latest_events(model: *const Model) Command {
    _ = model;
    // Query latest events globally
    var filters = command_buffers.query_latest[0..1];
    filters[0] = std.mem.zeroInit(QueryLatestFilter, .{
        .limit = 100,
    });

    return .{ .query_latest = filters[0..1] };
}

/// Converts a union type, where each field is of a slice type, into a struct of arrays of the
/// corresponding type, with the maximum count of driver events as its len. These buffers are used
/// to hold commands and results in the workload loop.
fn FixedSizeBuffersType(Union: type) type {
    const union_fields = @typeInfo(Union).@"union".fields;
    var struct_fields: [union_fields.len]std.builtin.Type.StructField = undefined;

    var i = 0;
    for (union_fields) |union_field| {
        const info = @typeInfo(union_field.type);
        const field_type = [events_count_max]info.pointer.child;
        struct_fields[i] = .{
            .name = union_field.name,
            .type = field_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(field_type),
        };
        i += 1;
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = false,
            .fields = &struct_fields,
            .layout = .auto,
            .decls = &.{},
        },
    });
}

pub fn send(
    driver: *const DriverStdio,
    comptime operation: Operation,
    events: []const operation.EventType(),
) !void {
    assert(events.len <= events_count_max);

    const writer = driver.input.writer().any();

    try writer.writeInt(u8, @intFromEnum(operation), .little);
    try writer.writeInt(u32, @intCast(events.len), .little);

    const bytes: []const u8 = std.mem.sliceAsBytes(events);
    try writer.writeAll(bytes);
}

pub fn receive(
    driver: *const DriverStdio,
    comptime operation: Operation,
    results: []operation.ResultType(),
) ![]operation.ResultType() {
    assert(results.len <= events_count_max);
    const reader = driver.output.reader();

    const results_count = try reader.readInt(u32, .little);
    assert(results_count <= results.len);

    const buf: []u8 = std.mem.sliceAsBytes(results[0..results_count]);
    assert(try reader.readAtLeast(buf, buf.len) == buf.len);

    return results[0..results_count];
}

fn query_uuid_events(results: []const QueryUuidResponse) []GeoEvent {
    const header_size = @sizeOf(QueryUuidResponse);
    const reply_body = std.mem.sliceAsBytes(results);
    if (reply_body.len < header_size) return result_buffers.query_uuid[0..0];

    const header = std.mem.bytesAsValue(
        QueryUuidResponse,
        reply_body[0..header_size],
    );
    if (header.status != 0) return result_buffers.query_uuid[0..0];

    if (reply_body.len < header_size + @sizeOf(GeoEvent)) return result_buffers.query_uuid[0..0];

    const events = stdx.bytes_as_slice(
        .exact,
        GeoEvent,
        reply_body[header_size..][0..@sizeOf(GeoEvent)],
    );
    result_buffers.query_uuid[0] = events[0];
    return result_buffers.query_uuid[0..1];
}

/// A message written to stdout by the workload, communicating the progress it makes.
pub const Progress = extern struct {
    event_count: u64,
    timestamp_start_micros: u64,
    timestamp_end_micros: u64,
};

fn progress_write(writer: std.io.AnyWriter, stats: Progress) !void {
    try writer.writeAll(std.mem.asBytes(&stats));
}
