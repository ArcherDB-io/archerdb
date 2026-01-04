// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GeoEvent benchmark load generator for F5.1.1-F5.1.4.
//!
//! Measures:
//! - F5.1.1: GeoEvent upsert throughput (target: 1M events/sec per node)
//! - F5.1.2: UUID lookup latency (target: <500us p99)
//! - F5.1.3: Radius query latency (target: <50ms p99)
//! - F5.1.4: Polygon query latency (target: <100ms p99)
//!
//! Workload steps:
//! 1. Upsert GeoEvents (bulk insert to measure write throughput)
//! 2. Query by UUID (point lookups to measure index performance)
//! 3. Query by radius (spatial queries around random points)
//! 4. Query by polygon (spatial queries with polygon bounds)

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.geo_benchmark);

const vsr = @import("vsr");
const tb = vsr.tigerbeetle;
const constants = vsr.constants;
const stdx = vsr.stdx;
const flags = vsr.flags;
const IO = vsr.io.IO;
const Time = vsr.time.Time;
const Duration = stdx.Duration;
const MessagePool = vsr.message_pool.MessagePool;
const MessageBus = vsr.message_bus.MessageBusType(IO);
const Client = vsr.ClientType(tb.Operation, MessageBus);

const cli = @import("./cli.zig");

const GeoEvent = tb.GeoEvent;
const QueryUuidFilter = tb.QueryUuidFilter;
const QueryRadiusFilter = tb.QueryRadiusFilter;
const QueryPolygonFilter = tb.QueryPolygonFilter;
const InsertGeoEventsResult = tb.InsertGeoEventsResult;

/// Polygon vertex (lat/lon pair) - matches geo_state_machine.PolygonVertex
const PolygonVertex = extern struct {
    lat_nano: i64,
    lon_nano: i64,

    comptime {
        assert(@sizeOf(PolygonVertex) == 16);
    }
};

pub fn main(
    allocator: std.mem.Allocator,
    io: *IO,
    time: Time,
    addresses: []const std.net.Address,
    cli_args: *const cli.Command.Benchmark,
) !void {
    if (builtin.mode != .ReleaseSafe and builtin.mode != .ReleaseFast) {
        log.warn("Benchmark must be built with '-Drelease' for reasonable results.", .{});
    }
    if (!vsr.constants.config.process.direct_io) {
        log.warn("Direct IO is disabled.", .{});
    }
    if (vsr.constants.config.process.verify) {
        log.warn("Extra assertions are enabled.", .{});
    }

    if (cli_args.clients == 0 or cli_args.clients > constants.clients_max) vsr.fatal(
        .cli,
        "--clients: must be between 1 and {}, got {}",
        .{ constants.clients_max, cli_args.clients },
    );

    const cluster_id: u128 = 0;

    var message_pools = stdx.BoundedArrayType(MessagePool, constants.clients_max){};
    defer for (message_pools.slice()) |*message_pool| message_pool.deinit(allocator);
    for (0..cli_args.clients) |_| {
        message_pools.push(try MessagePool.init(allocator, .client));
    }

    std.log.info("GeoEvent Benchmark running against {any}", .{addresses});
    std.log.info("Configuration: {} events, {} entities, {} UUID queries, {} radius queries, {} polygon queries", .{
        cli_args.geo_event_count,
        cli_args.geo_entity_count,
        cli_args.geo_query_uuid_count,
        cli_args.geo_query_radius_count,
        cli_args.geo_query_polygon_count,
    });

    var clients = stdx.BoundedArrayType(Client, constants.clients_max){};
    defer for (clients.slice()) |*client| client.deinit(allocator);

    for (0..cli_args.clients) |i| {
        clients.push(try Client.init(
            allocator,
            time,
            &message_pools.slice()[i],
            .{
                .id = stdx.unique_u128(),
                .cluster = cluster_id,
                .replica_count = @intCast(addresses.len),
                .message_bus_options = .{ .configuration = addresses, .io = io },
            },
        ));
    }

    // Latency histogram (1ms buckets, 0-10000ms)
    const request_latency_histogram = try allocator.alloc(u64, 10_001);
    @memset(request_latency_histogram, 0);
    defer allocator.free(request_latency_histogram);

    const client_requests = try allocator.alignedAlloc(
        [constants.message_body_size_max]u8,
        constants.sector_size,
        clients.count(),
    );
    defer allocator.free(client_requests);

    const client_replies = try allocator.alignedAlloc(
        [constants.message_body_size_max]u8,
        constants.sector_size,
        clients.count(),
    );
    defer allocator.free(client_replies);

    // Track entity UUIDs for queries
    const entity_ids = try allocator.alloc(u128, cli_args.geo_entity_count);
    defer allocator.free(entity_ids);

    // Generate deterministic entity UUIDs
    var prng = stdx.PRNG.from_seed(42);
    for (entity_ids) |*id| {
        id.* = prng.int(u128);
        // Ensure non-zero
        if (id.* == 0) id.* = 1;
    }

    var benchmark = GeoBenchmark{
        .io = io,
        .prng = &prng,
        .timer = try std.time.Timer.start(),
        .output = std.io.getStdOut().writer().any(),
        .clients = clients.slice(),
        .client_requests = client_requests,
        .client_replies = client_replies,
        .request_latency_histogram = request_latency_histogram,
        .entity_ids = entity_ids,
        .geo_event_count = cli_args.geo_event_count,
        .geo_entity_count = cli_args.geo_entity_count,
        .geo_query_uuid_count = cli_args.geo_query_uuid_count,
        .geo_query_radius_count = cli_args.geo_query_radius_count,
        .geo_query_polygon_count = cli_args.geo_query_polygon_count,
        .geo_query_radius_meters = cli_args.geo_query_radius_meters,
        .print_batch_timings = cli_args.print_batch_timings,
    };

    // Register clients
    try benchmark.run(.register);

    // F5.1.1: Upsert throughput benchmark
    try benchmark.run(.upsert_events);

    // F5.1.2: UUID query latency benchmark
    if (benchmark.geo_query_uuid_count > 0) {
        try benchmark.run(.query_uuid);
    }

    // F5.1.3: Radius query latency benchmark
    if (benchmark.geo_query_radius_count > 0) {
        try benchmark.run(.query_radius);
    }

    // F5.1.4: Polygon query latency benchmark
    // NOTE: Polygon queries require variable-length messages (filter + vertices)
    // which the client currently doesn't support. See issue for enhancement.
    if (benchmark.geo_query_polygon_count > 0) {
        log.warn("Polygon queries skipped: client doesn't support variable-length messages yet", .{});
        log.warn("Polygon query benchmark requires client enhancement (see F5.1.4)", .{});
        // TODO: Enable when client supports variable-length requests
        // try benchmark.run(.query_polygon);
    }
}

const GeoBenchmark = struct {
    io: *IO,
    prng: *stdx.PRNG,
    timer: std.time.Timer,
    output: std.io.AnyWriter,
    clients: []Client,

    // Configuration
    entity_ids: []const u128,
    geo_event_count: u64,
    geo_entity_count: u32,
    geo_query_uuid_count: u32,
    geo_query_radius_count: u32,
    geo_query_polygon_count: u32,
    geo_query_radius_meters: u32,
    print_batch_timings: bool,

    // State
    clients_busy: stdx.BitSetType(constants.clients_max) = .{},
    clients_request_ns: [constants.clients_max]u64 = @splat(undefined),
    client_requests: []align(constants.sector_size) [constants.message_body_size_max]u8,
    client_replies: []align(constants.sector_size) [constants.message_body_size_max]u8,
    request_latency_histogram: []u64,
    request_index: usize = 0,
    event_index: usize = 0,
    query_index: usize = 0,
    events_created: usize = 0,
    stage: Stage = .idle,

    const Stage = enum {
        idle,
        register,
        upsert_events,
        query_uuid,
        query_radius,
        query_polygon,
    };

    pub fn run(b: *GeoBenchmark, stage: Stage) !void {
        assert(b.stage == .idle);
        assert(b.clients.len > 0);
        assert(b.clients_busy.empty());
        assert(stdx.zeroed(std.mem.sliceAsBytes(b.request_latency_histogram)));
        assert(b.request_index == 0);
        assert(b.event_index == 0);
        assert(b.query_index == 0);
        assert(stage != .idle);

        b.stage = stage;
        b.timer.reset();

        for (0..b.clients.len) |client_usize| {
            const client = @as(u32, @intCast(client_usize));
            switch (b.stage) {
                .register => b.register(client),
                .upsert_events => b.upsert_events(client),
                .query_uuid => b.do_query_uuid(client),
                .query_radius => b.do_query_radius(client),
                .query_polygon => b.do_query_polygon(client),
                .idle => break,
            }
        }

        while (b.stage != .idle) {
            for (b.clients) |*client| client.tick();
            try b.io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
        }
    }

    fn run_finish(b: *GeoBenchmark) void {
        assert(b.stage != .idle);
        assert(b.clients_busy.empty());

        b.stage = .idle;
        b.request_index = 0;
        b.event_index = 0;
        b.query_index = 0;
        @memset(b.request_latency_histogram, 0);
    }

    // =========================================================================
    // Registration
    // =========================================================================

    fn register(b: *GeoBenchmark, client_index: usize) void {
        assert(b.stage == .register);
        assert(!b.clients_busy.is_set(client_index));

        b.clients_busy.set(client_index);
        b.clients[client_index].register(register_callback, @bitCast(RequestContext{
            .benchmark = b,
            .client_index = @intCast(client_index),
            .request_index = undefined,
        }));
        b.request_index += 1;
    }

    fn register_callback(user_data: u128, _: *const vsr.RegisterResult) void {
        const context: RequestContext = @bitCast(user_data);
        const b: *GeoBenchmark = context.benchmark;
        assert(b.stage == .register);
        assert(b.clients_busy.is_set(context.client_index));

        b.clients_busy.unset(context.client_index);
        if (b.clients_busy.empty()) b.run_finish();
    }

    // =========================================================================
    // F5.1.1: Upsert Events (Write Throughput)
    // =========================================================================

    fn upsert_events(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .upsert_events);
        assert(!b.clients_busy.is_set(client_index));

        if (b.event_index >= b.geo_event_count) {
            if (b.clients_busy.empty()) b.upsert_events_finish();
            return;
        }

        // Calculate batch size (max events per message)
        const max_events_per_batch = constants.message_body_size_max / @sizeOf(GeoEvent);
        const remaining = b.geo_event_count - b.event_index;
        const batch_count: u32 = @intCast(@min(remaining, max_events_per_batch));

        const events = stdx.bytes_as_slice(
            .exact,
            GeoEvent,
            &b.client_requests[client_index],
        )[0..batch_count];
        b.build_events(events);

        b.request(client_index, .upsert_events, .{
            .batch_count = batch_count,
            .event_size = @sizeOf(GeoEvent),
        });
    }

    fn upsert_events_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .upsert_events);

        const results = stdx.bytes_as_slice(.exact, InsertGeoEventsResult, result);
        // Check for errors
        for (results) |r| {
            if (r.result != .ok) {
                log.warn("upsert error at index {}: {}", .{ r.index, r.result });
            }
        }

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_ms = @divTrunc(request_duration_ns, std.time.ns_per_ms);
        b.request_latency_histogram[@min(request_duration_ms, b.request_latency_histogram.len - 1)] += 1;

        if (b.print_batch_timings) {
            log.info("upsert batch {}: {} ms", .{ b.request_index, request_duration_ms });
        }

        b.upsert_events(client_index);
    }

    fn upsert_events_finish(b: *GeoBenchmark) void {
        assert(b.stage == .upsert_events);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;
        const events_per_sec = @as(u64, @intFromFloat(@as(f64, @floatFromInt(b.events_created)) / duration_s));

        b.output.print(
            \\
            \\=== F5.1.1: GeoEvent Write Throughput ===
            \\events upserted = {[events]}
            \\duration = {[duration]d:.2} s
            \\throughput = {[rate]} events/s
            \\target = 1,000,000 events/s per node
            \\
        , .{
            .events = b.events_created,
            .duration = duration_s,
            .rate = events_per_sec,
        }) catch unreachable;

        print_percentiles_histogram(b.output, "upsert batch", b.request_latency_histogram);

        b.run_finish();
    }

    fn build_events(b: *GeoBenchmark, events: []GeoEvent) void {
        for (events) |*event| {
            // Select entity cyclically
            const entity_idx = b.event_index % b.geo_entity_count;
            const entity_id = b.entity_ids[entity_idx];

            // Generate random coordinates (global distribution)
            // Latitude: -90 to +90 degrees in nanodegrees
            const lat_raw = b.prng.range_inclusive(u64, 0, 180_000_000_000);
            const lat_nano: i64 = @as(i64, @intCast(lat_raw)) - 90_000_000_000;
            // Longitude: -180 to +180 degrees in nanodegrees
            const lon_raw = b.prng.range_inclusive(u64, 0, 360_000_000_000);
            const lon_nano: i64 = @as(i64, @intCast(lon_raw)) - 180_000_000_000;

            // Generate composite ID (S2 cell << 64 | would be timestamp, but set to 0 for server)
            const s2_cell = compute_simple_s2_cell(lat_nano, lon_nano);

            event.* = .{
                .id = GeoEvent.pack_id(s2_cell, 0), // Timestamp assigned by server
                .entity_id = entity_id,
                .correlation_id = b.prng.int(u128),
                .user_data = b.prng.int(u128),
                .lat_nano = lat_nano,
                .lon_nano = lon_nano,
                .group_id = b.prng.int(u64) % 100, // 100 groups
                .timestamp = 0, // Server assigns
                .altitude_mm = @as(i32, @intCast(b.prng.int(u32) % 10000)),
                .velocity_mms = b.prng.int(u32) % 50000, // 0-50 m/s
                .ttl_seconds = 0, // No expiry
                .accuracy_mm = b.prng.int(u32) % 100000, // 0-100m accuracy
                .heading_cdeg = @as(u16, @intCast(b.prng.int(u32) % 36001)),
                .flags = .{},
                .reserved = @splat(0),
            };

            b.event_index += 1;
            b.events_created += 1;
        }
    }

    // =========================================================================
    // F5.1.2: UUID Query (Lookup Latency)
    // =========================================================================

    fn do_query_uuid(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_uuid);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.geo_query_uuid_count) {
            if (b.clients_busy.empty()) b.query_uuid_finish();
            return;
        }

        // Pick a random entity to query
        const entity_idx = b.prng.int(u32) % b.geo_entity_count;
        const entity_id = b.entity_ids[entity_idx];

        const filter: *QueryUuidFilter = @alignCast(@ptrCast(&b.client_requests[client_index]));
        filter.* = .{
            .entity_id = entity_id,
            .limit = 1, // We expect at most 1 result for UUID lookup
        };

        b.query_index += 1;
        b.request(client_index, .query_uuid, .{
            .batch_count = 1,
            .event_size = @sizeOf(QueryUuidFilter),
        });
    }

    fn query_uuid_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .query_uuid);
        _ = result; // Results contain GeoEvent(s)

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_ms = @divTrunc(request_duration_ns, std.time.ns_per_ms);
        b.request_latency_histogram[@min(request_duration_ms, b.request_latency_histogram.len - 1)] += 1;

        b.do_query_uuid(client_index);
    }

    fn query_uuid_finish(b: *GeoBenchmark) void {
        assert(b.stage == .query_uuid);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;

        b.output.print(
            \\
            \\=== F5.1.2: UUID Query Latency ===
            \\queries = {[queries]}
            \\duration = {[duration]d:.2} s
            \\target = <500us p99
            \\
        , .{
            .queries = b.request_index,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(b.output, "UUID query", b.request_latency_histogram);

        b.run_finish();
    }

    // =========================================================================
    // F5.1.3: Radius Query (Spatial Query Latency)
    // =========================================================================

    fn do_query_radius(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_radius);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.geo_query_radius_count) {
            if (b.clients_busy.empty()) b.query_radius_finish();
            return;
        }

        // Random center point
        const lat_raw = b.prng.range_inclusive(u64, 0, 180_000_000_000);
        const lat_nano: i64 = @as(i64, @intCast(lat_raw)) - 90_000_000_000;
        const lon_raw = b.prng.range_inclusive(u64, 0, 360_000_000_000);
        const lon_nano: i64 = @as(i64, @intCast(lon_raw)) - 180_000_000_000;

        const filter: *QueryRadiusFilter = @alignCast(@ptrCast(&b.client_requests[client_index]));
        filter.* = .{
            .center_lat_nano = lat_nano,
            .center_lon_nano = lon_nano,
            .radius_mm = b.geo_query_radius_meters * 1000, // Convert meters to mm
            .limit = 100,
            .timestamp_min = 0,
            .timestamp_max = 0,
            .group_id = 0,
        };

        b.query_index += 1;
        b.request(client_index, .query_radius, .{
            .batch_count = 1,
            .event_size = @sizeOf(QueryRadiusFilter),
        });
    }

    fn query_radius_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .query_radius);
        _ = result;

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_ms = @divTrunc(request_duration_ns, std.time.ns_per_ms);
        b.request_latency_histogram[@min(request_duration_ms, b.request_latency_histogram.len - 1)] += 1;

        b.do_query_radius(client_index);
    }

    fn query_radius_finish(b: *GeoBenchmark) void {
        assert(b.stage == .query_radius);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;

        b.output.print(
            \\
            \\=== F5.1.3: Radius Query Latency ===
            \\queries = {[queries]}
            \\radius = {[radius]} meters
            \\duration = {[duration]d:.2} s
            \\target = <50ms p99
            \\
        , .{
            .queries = b.request_index,
            .radius = b.geo_query_radius_meters,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(b.output, "radius query", b.request_latency_histogram);

        b.run_finish();
    }

    // =========================================================================
    // F5.1.4: Polygon Query (Complex Spatial Query Latency)
    // =========================================================================

    fn do_query_polygon(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_polygon);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.geo_query_polygon_count) {
            if (b.clients_busy.empty()) b.query_polygon_finish();
            return;
        }

        // Create a simple rectangular polygon around a random center
        const center_lat_raw = b.prng.range_inclusive(u64, 10_000_000_000, 170_000_000_000);
        const center_lat: i64 = @as(i64, @intCast(center_lat_raw)) - 90_000_000_000;
        const center_lon_raw = b.prng.range_inclusive(u64, 10_000_000_000, 350_000_000_000);
        const center_lon: i64 = @as(i64, @intCast(center_lon_raw)) - 180_000_000_000;

        // Rectangle size: roughly 0.1 degrees (about 10km at equator)
        const half_size: i64 = 50_000_000; // 0.05 degrees in nanodegrees

        const filter: *QueryPolygonFilter = @alignCast(@ptrCast(&b.client_requests[client_index]));
        filter.* = .{
            .vertex_count = 4,
            .limit = 100,
            .timestamp_min = 0,
            .timestamp_max = 0,
            .group_id = 0,
        };

        // Add vertices after filter (4 corners of rectangle)
        const vertices_ptr: [*]PolygonVertex = @alignCast(@ptrCast(&b.client_requests[client_index][@sizeOf(QueryPolygonFilter)]));
        vertices_ptr[0] = .{ .lat_nano = center_lat - half_size, .lon_nano = center_lon - half_size };
        vertices_ptr[1] = .{ .lat_nano = center_lat - half_size, .lon_nano = center_lon + half_size };
        vertices_ptr[2] = .{ .lat_nano = center_lat + half_size, .lon_nano = center_lon + half_size };
        vertices_ptr[3] = .{ .lat_nano = center_lat + half_size, .lon_nano = center_lon - half_size };

        b.query_index += 1;

        const total_size = @sizeOf(QueryPolygonFilter) + 4 * @sizeOf(PolygonVertex);
        b.request_polygon(client_index, total_size);
    }

    fn request_polygon(b: *GeoBenchmark, client_index: usize, request_size: usize) void {
        assert(b.stage == .query_polygon);
        assert(!b.clients_busy.is_set(client_index));

        b.clients_busy.set(client_index);
        b.clients_request_ns[client_index] = b.timer.read();
        b.request_index += 1;

        // For polygon queries, we send the raw bytes (filter + vertices)
        b.clients[client_index].request(
            request_complete,
            @bitCast(RequestContext{
                .benchmark = b,
                .client_index = @intCast(client_index),
                .request_index = @intCast(b.request_index - 1),
            }),
            .query_polygon,
            b.client_requests[client_index][0..request_size],
        );
    }

    fn query_polygon_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .query_polygon);
        _ = result;

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_ms = @divTrunc(request_duration_ns, std.time.ns_per_ms);
        b.request_latency_histogram[@min(request_duration_ms, b.request_latency_histogram.len - 1)] += 1;

        b.do_query_polygon(client_index);
    }

    fn query_polygon_finish(b: *GeoBenchmark) void {
        assert(b.stage == .query_polygon);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;

        b.output.print(
            \\
            \\=== F5.1.4: Polygon Query Latency ===
            \\queries = {[queries]}
            \\duration = {[duration]d:.2} s
            \\target = <100ms p99
            \\
        , .{
            .queries = b.request_index,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(b.output, "polygon query", b.request_latency_histogram);

        b.run_finish();
    }

    // =========================================================================
    // Common Request Infrastructure
    // =========================================================================

    const RequestContext = extern struct {
        benchmark: *GeoBenchmark,
        client_index: u32,
        request_index: u32,

        comptime {
            assert(@sizeOf(RequestContext) == @sizeOf(u128));
        }
    };

    fn request(
        b: *GeoBenchmark,
        client_index: usize,
        operation: tb.Operation,
        options: struct {
            batch_count: u32,
            event_size: u32,
        },
    ) void {
        assert(b.stage != .idle);
        assert(!b.clients_busy.is_set(client_index));

        b.clients_busy.set(client_index);
        b.clients_request_ns[client_index] = b.timer.read();
        b.request_index += 1;

        // Check if operation uses multi-batch encoding
        if (operation.is_multi_batch()) {
            var encoder = vsr.multi_batch.MultiBatchEncoder.init(
                &b.client_requests[client_index],
                .{ .element_size = options.event_size },
            );
            encoder.add(options.batch_count * options.event_size);
            const bytes_written = encoder.finish();

            b.clients[client_index].request(
                request_complete,
                @bitCast(RequestContext{
                    .benchmark = b,
                    .client_index = @intCast(client_index),
                    .request_index = @intCast(b.request_index - 1),
                }),
                operation,
                b.client_requests[client_index][0..bytes_written],
            );
        } else {
            // Non-batched operations send raw bytes
            b.clients[client_index].request(
                request_complete,
                @bitCast(RequestContext{
                    .benchmark = b,
                    .client_index = @intCast(client_index),
                    .request_index = @intCast(b.request_index - 1),
                }),
                operation,
                b.client_requests[client_index][0 .. options.batch_count * options.event_size],
            );
        }
    }

    fn request_complete(
        user_data: u128,
        operation_vsr: vsr.Operation,
        timestamp: u64,
        result: []u8,
    ) void {
        const operation = operation_vsr.cast(tb.Operation);
        const context: RequestContext = @bitCast(user_data);
        const client = context.client_index;
        const b: *GeoBenchmark = context.benchmark;

        assert(b.clients_busy.is_set(client));
        assert(b.stage != .idle);
        assert(timestamp > 0);

        b.clients_busy.unset(client);

        // Decode response
        const input: []const u8 = if (operation.is_multi_batch()) input: {
            var reply_decoder = vsr.multi_batch.MultiBatchDecoder.init(
                result,
                .{ .element_size = operation.result_size() },
            ) catch {
                log.warn("failed to decode multi-batch response", .{});
                break :input &[_]u8{};
            };
            break :input reply_decoder.peek();
        } else result;

        switch (operation) {
            .upsert_events => b.upsert_events_callback(client, input),
            .query_uuid => b.query_uuid_callback(client, input),
            .query_radius => b.query_radius_callback(client, input),
            .query_polygon => b.query_polygon_callback(client, input),
            else => unreachable,
        }
    }
};

/// Simple S2 cell approximation (level 12) for benchmark purposes.
/// Real S2 uses spherical geometry; this is a fast approximation.
fn compute_simple_s2_cell(lat_nano: i64, lon_nano: i64) u64 {
    // Convert to face + position
    // S2 level 12 = 4096 cells per face side
    const level: u6 = 12;
    const cells_per_side: u64 = @as(u64, 1) << level;

    // Normalize to [0, 1) range
    const lat_norm = @as(f64, @floatFromInt(lat_nano + 90_000_000_000)) / 180_000_000_000.0;
    const lon_norm = @as(f64, @floatFromInt(lon_nano + 180_000_000_000)) / 360_000_000_000.0;

    // Simple face selection based on predominant axis
    const face: u64 = @as(u64, @intFromFloat(lon_norm * 6.0)) % 6;

    // Position within face
    const i: u64 = @intFromFloat(lat_norm * @as(f64, @floatFromInt(cells_per_side)));
    const j: u64 = @intFromFloat((lon_norm * 6.0 - @as(f64, @floatFromInt(face))) * @as(f64, @floatFromInt(cells_per_side)));

    // Pack into S2 cell ID format (simplified)
    return (face << 61) | ((i & 0xFFF) << 49) | ((j & 0xFFF) << 37);
}

fn print_percentiles_histogram(
    stdout: std.io.AnyWriter,
    label: []const u8,
    histogram_buckets: []const u64,
) void {
    var histogram_total: u64 = 0;
    for (histogram_buckets) |bucket| histogram_total += bucket;

    if (histogram_total == 0) {
        stdout.print("{s}: no data\n", .{label}) catch unreachable;
        return;
    }

    const percentiles = [_]u64{ 1, 50, 99, 100 };
    for (percentiles) |percentile| {
        const histogram_percentile: usize = @divTrunc(histogram_total * percentile, 100);

        var sum: usize = 0;
        const latency = for (histogram_buckets, 0..) |bucket, bucket_index| {
            sum += bucket;
            if (sum >= histogram_percentile) break bucket_index;
        } else histogram_buckets.len;

        stdout.print("{s} latency p{: <3} = {} ms{s}\n", .{
            label,
            percentile,
            latency,
            if (latency == histogram_buckets.len) "+ (exceeds histogram resolution)" else "",
        }) catch unreachable;
    }
}
