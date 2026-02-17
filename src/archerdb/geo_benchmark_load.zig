// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! GeoEvent benchmark load generator for F5.1.1-F5.1.4.
//!
//! Measures:
//! - F5.1.1: GeoEvent insert throughput (target: 1M events/sec per node)
//! - F5.1.2: UUID lookup latency (single-request, target: <500us p99)
//! - F5.1.2b: UUID lookup latency (per-entity cost in batched requests, diagnostic)
//! - F5.1.3: Radius query latency (target: <50ms p99)
//! - F5.1.4: Polygon query latency (target: <100ms p99)
//!
//! Workload steps:
//! 1. Insert GeoEvents (bulk insert to measure write throughput)
//! 2. Query by UUID (single-request, grade gate)
//! 3. Query by UUID batch (per-entity diagnostic)
//! 4. Query by radius (single-client spatial latency)
//! 5. Query by polygon (single-client spatial latency)

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.geo_benchmark);

const vsr = @import("vsr");
const tb = vsr.archerdb;
const constants = vsr.constants;
const stdx = vsr.stdx;
const flags = vsr.flags;
const IO = vsr.io.IO;
const Time = vsr.time.Time;
const MessagePool = vsr.message_pool.MessagePool;
const MessageBus = vsr.message_bus.MessageBusType(IO);
const Client = vsr.ClientType(tb.Operation, MessageBus);

const cli = @import("./cli.zig");

const GeoEvent = tb.GeoEvent;
const QueryUuidFilter = tb.QueryUuidFilter;
const QueryUuidBatchFilter = tb.QueryUuidBatchFilter;
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
    std.log.info(
        "Configuration: {} events, {} entities, {} UUID queries, " ++
            "{} radius queries, {} polygon queries",
        .{
            cli_args.event_count,
            cli_args.entity_count,
            cli_args.query_uuid_count,
            cli_args.query_radius_count,
            cli_args.query_polygon_count,
        },
    );
    std.log.info(
        "Concurrency: write clients={}, query clients=1",
        .{ cli_args.clients },
    );

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
    const entity_ids = try allocator.alloc(u128, cli_args.entity_count);
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
        .event_count = cli_args.event_count,
        .entity_count = cli_args.entity_count,
        .query_uuid_count = cli_args.query_uuid_count,
        .query_radius_count = cli_args.query_radius_count,
        .query_polygon_count = cli_args.query_polygon_count,
        .query_radius_meters = cli_args.query_radius_meters,
        .print_batch_timings = cli_args.print_batch_timings,
    };

    // Register clients
    try benchmark.run(.register);

    // F5.1.1: Insert throughput benchmark
    try benchmark.run(.insert_events);

    // F5.1.2: UUID single-request latency benchmark (grade gate)
    if (benchmark.query_uuid_count > 0) {
        try benchmark.run(.query_uuid_single);
        try benchmark.run(.query_uuid_batch);
    }

    // F5.1.3: Radius query latency benchmark
    if (benchmark.query_radius_count > 0) {
        try benchmark.run(.query_radius);
    }

    // F5.1.4: Polygon query latency benchmark
    if (benchmark.query_polygon_count > 0) {
        try benchmark.run(.query_polygon);
    }

    // Print memory statistics at end of benchmark
    print_memory_stats(benchmark.output);
}

const GeoBenchmark = struct {
    io: *IO,
    prng: *stdx.PRNG,
    timer: std.time.Timer,
    output: std.io.AnyWriter,
    clients: []Client,

    // Configuration
    entity_ids: []const u128,
    event_count: u64,
    entity_count: u32,
    query_uuid_count: u32,
    query_radius_count: u32,
    query_polygon_count: u32,
    query_radius_meters: u32,
    print_batch_timings: bool,

    // State
    clients_busy: stdx.BitSetType(constants.clients_max) = .{},
    clients_request_ns: [constants.clients_max]u64 = @splat(undefined),
    clients_query_batch_count: [constants.clients_max]u16 = @splat(0),
    client_requests: []align(constants.sector_size) [constants.message_body_size_max]u8,
    client_replies: []align(constants.sector_size) [constants.message_body_size_max]u8,
    request_latency_histogram: []u64,
    latency_bucket_ns: u64 = std.time.ns_per_ms,
    latency_unit_label: []const u8 = "ms",
    request_index: usize = 0,
    event_index: usize = 0,
    query_index: usize = 0,
    events_created: usize = 0,
    events_failed: usize = 0,
    stage: Stage = .idle,

    const Stage = enum {
        idle,
        register,
        insert_events,
        query_uuid_single,
        query_uuid_batch,
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
        switch (stage) {
            .query_uuid_single, .query_uuid_batch => {
                b.latency_bucket_ns = std.time.ns_per_us;
                b.latency_unit_label = "us";
            },
            else => {
                b.latency_bucket_ns = std.time.ns_per_ms;
                b.latency_unit_label = "ms";
            },
        }
        b.timer.reset();

        const active_clients = b.stageClientCount(stage);
        for (0..active_clients) |client_usize| {
            const client = @as(u32, @intCast(client_usize));
            switch (b.stage) {
                .register => b.register(client),
                .insert_events => b.insert_events(client),
                .query_uuid_single => b.do_query_uuid_single(client),
                .query_uuid_batch => b.do_query_uuid_batch(client),
                .query_radius => b.do_query_radius(client),
                .query_polygon => b.do_query_polygon(client),
                .idle => break,
            }
        }

        while (b.stage != .idle) {
            for (b.clients[0..active_clients]) |*client| client.tick();
            const io_step_ns: u63 = switch (b.stage) {
                .insert_events => constants.tick_ms * std.time.ns_per_ms,
                .register => constants.tick_ms * std.time.ns_per_ms,
                .query_uuid_single, .query_uuid_batch, .query_radius, .query_polygon => @as(u63, 100 * std.time.ns_per_us),
                .idle => unreachable,
            };
            try b.io.run_for_ns(io_step_ns);
        }
    }

    fn stageClientCount(b: *const GeoBenchmark, stage: Stage) usize {
        return switch (stage) {
            .insert_events, .register => b.clients.len,
            .query_uuid_single, .query_uuid_batch, .query_radius, .query_polygon => 1,
            .idle => 0,
        };
    }

    fn run_finish(b: *GeoBenchmark) void {
        assert(b.stage != .idle);
        assert(b.clients_busy.empty());

        b.stage = .idle;
        b.request_index = 0;
        b.event_index = 0;
        b.query_index = 0;
        b.events_created = 0;
        b.events_failed = 0;
        b.clients_query_batch_count = @splat(0);
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
    // F5.1.1: Insert Events (Write Throughput)
    // =========================================================================

    fn insert_events(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .insert_events);
        assert(!b.clients_busy.is_set(client_index));

        if (b.event_index >= b.event_count) {
            if (b.clients_busy.empty()) b.insert_events_finish();
            return;
        }

        // Calculate batch size (max events per message)
        const max_events_per_batch = constants.message_body_size_max / @sizeOf(GeoEvent);
        const remaining = b.event_count - b.event_index;
        const batch_count: u32 = @intCast(@min(remaining, max_events_per_batch));

        const events = stdx.bytes_as_slice(
            .exact,
            GeoEvent,
            &b.client_requests[client_index],
        )[0..batch_count];
        b.build_events(events);

        b.request(client_index, .insert_events, .{
            .batch_count = batch_count,
            .event_size = @sizeOf(GeoEvent),
        });
    }

    fn insert_events_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .insert_events);

        const results = stdx.bytes_as_slice(.exact, InsertGeoEventsResult, result);
        // Check for errors
        for (results) |r| {
            if (r.result != .ok) {
                b.events_failed += 1;
                log.warn("insert error at index {}: {}", .{ r.index, r.result });
            }
        }

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_units = @divTrunc(request_duration_ns, b.latency_bucket_ns);
        const hist_idx = @min(request_duration_units, b.request_latency_histogram.len - 1);
        b.request_latency_histogram[hist_idx] += 1;

        if (b.print_batch_timings) {
            log.info("insert batch {}: {} {s}", .{
                b.request_index,
                request_duration_units,
                b.latency_unit_label,
            });
        }

        b.insert_events(client_index);
    }

    fn insert_events_finish(b: *GeoBenchmark) void {
        assert(b.stage == .insert_events);

        const timer_ns: f64 = @floatFromInt(b.timer.read());
        const duration_s = timer_ns / std.time.ns_per_s;
        const events_inserted = b.events_created -| b.events_failed;
        const events_f: f64 = @floatFromInt(events_inserted);
        const events_per_sec: u64 = @intFromFloat(events_f / duration_s);

        b.output.print(
            \\
            \\=== F5.1.1: GeoEvent Write Throughput ===
            \\events attempted = {[events_attempted]}
            \\events inserted = {[events_inserted]}
            \\events failed = {[events_failed]}
            \\duration = {[duration]d:.2} s
            \\throughput = {[rate]} events/s
            \\target = 1,000,000 events/s per node
            \\
        , .{
            .events_attempted = b.events_created,
            .events_inserted = events_inserted,
            .events_failed = b.events_failed,
            .duration = duration_s,
            .rate = events_per_sec,
        }) catch unreachable;

        print_percentiles_histogram(
            b.output,
            "insert batch",
            b.request_latency_histogram,
            b.latency_unit_label,
        );

        b.run_finish();
    }

    fn build_events(b: *GeoBenchmark, events: []GeoEvent) void {
        for (events) |*event| {
            // Select entity cyclically
            const entity_idx = b.event_index % b.entity_count;
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
    // F5.1.2a: UUID Query (Single-Request Latency, Grade Gate)
    // =========================================================================

    fn do_query_uuid_single(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_uuid_single);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.query_uuid_count) {
            if (b.clients_busy.empty()) b.query_uuid_single_finish();
            return;
        }

        // Pick a random entity to query.
        const entity_idx = b.prng.int(u32) % b.entity_count;
        const entity_id = b.entity_ids[entity_idx];

        const filter: *QueryUuidFilter = @ptrCast(@alignCast(&b.client_requests[client_index]));
        filter.* = .{
            .entity_id = entity_id,
        };

        b.query_index += 1;
        b.request(client_index, .query_uuid, .{
            .batch_count = 1,
            .event_size = @sizeOf(QueryUuidFilter),
        });
    }

    fn query_uuid_single_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .query_uuid_single);
        _ = result;

        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const request_duration_units = @divTrunc(request_duration_ns, b.latency_bucket_ns);
        const hist_idx = @min(request_duration_units, b.request_latency_histogram.len - 1);
        b.request_latency_histogram[hist_idx] += 1;

        b.do_query_uuid_single(client_index);
    }

    fn query_uuid_single_finish(b: *GeoBenchmark) void {
        assert(b.stage == .query_uuid_single);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;

        b.output.print(
            \\
            \\=== F5.1.2: UUID Query Latency (Single) ===
            \\queries = {[queries]}
            \\duration = {[duration]d:.2} s
            \\target = <500us p99 (grade gate)
            \\
        , .{
            .queries = b.query_index,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(
            b.output,
            "UUID single query",
            b.request_latency_histogram,
            b.latency_unit_label,
        );

        b.run_finish();
    }

    // =========================================================================
    // F5.1.2b: UUID Query (Per-Entity Latency in Batch, Diagnostic)
    // =========================================================================

    fn do_query_uuid_batch(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_uuid_batch);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.query_uuid_count) {
            if (b.clients_busy.empty()) b.query_uuid_batch_finish();
            return;
        }

        const remaining = b.query_uuid_count - b.query_index;
        const batch_count: u32 = @min(remaining, 128);

        const filter: *QueryUuidBatchFilter = @ptrCast(@alignCast(&b.client_requests[client_index]));
        filter.* = .{
            .count = batch_count,
            .reserved = @splat(0),
        };
        const ids_start = @sizeOf(QueryUuidBatchFilter);
        const ids_ptr: [*]u128 = @ptrCast(@alignCast(&b.client_requests[client_index][ids_start]));
        for (0..batch_count) |i| {
            const entity_idx = b.prng.int(u32) % b.entity_count;
            ids_ptr[i] = b.entity_ids[entity_idx];
        }

        b.query_index += batch_count;
        b.clients_query_batch_count[client_index] = @intCast(batch_count);
        b.request(client_index, .query_uuid_batch, .{
            .batch_count = 1,
            .event_size = @intCast(@sizeOf(QueryUuidBatchFilter) + batch_count * @sizeOf(u128)),
        });
    }

    fn query_uuid_batch_callback(b: *GeoBenchmark, client_index: u32, result: []const u8) void {
        assert(b.stage == .query_uuid_batch);
        _ = result;

        const batch_count = @max(@as(u16, 1), b.clients_query_batch_count[client_index]);
        b.clients_query_batch_count[client_index] = 0;
        const request_duration_ns = b.timer.read() - b.clients_request_ns[client_index];
        const per_query_duration_ns = request_duration_ns / batch_count;
        const request_duration_units = @divTrunc(per_query_duration_ns, b.latency_bucket_ns);
        const hist_idx = @min(request_duration_units, b.request_latency_histogram.len - 1);
        b.request_latency_histogram[hist_idx] += batch_count;

        b.do_query_uuid_batch(client_index);
    }

    fn query_uuid_batch_finish(b: *GeoBenchmark) void {
        assert(b.stage == .query_uuid_batch);

        const duration_s = @as(f64, @floatFromInt(b.timer.read())) / std.time.ns_per_s;

        b.output.print(
            \\
            \\=== F5.1.2b: UUID Query Latency (Batch Per Entity) ===
            \\queries = {[queries]}
            \\duration = {[duration]d:.2} s
            \\note = diagnostic only (not grade gate)
            \\
        , .{
            .queries = b.query_index,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(
            b.output,
            "UUID batch-per-entity",
            b.request_latency_histogram,
            b.latency_unit_label,
        );

        b.run_finish();
    }

    // =========================================================================
    // F5.1.3: Radius Query (Spatial Query Latency)
    // =========================================================================

    fn do_query_radius(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_radius);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.query_radius_count) {
            if (b.clients_busy.empty()) b.query_radius_finish();
            return;
        }

        // Random center point
        const lat_raw = b.prng.range_inclusive(u64, 0, 180_000_000_000);
        const lat_nano: i64 = @as(i64, @intCast(lat_raw)) - 90_000_000_000;
        const lon_raw = b.prng.range_inclusive(u64, 0, 360_000_000_000);
        const lon_nano: i64 = @as(i64, @intCast(lon_raw)) - 180_000_000_000;

        const filter: *QueryRadiusFilter = @ptrCast(@alignCast(&b.client_requests[client_index]));
        filter.* = .{
            .center_lat_nano = lat_nano,
            .center_lon_nano = lon_nano,
            .radius_mm = b.query_radius_meters * 1000, // Convert meters to mm
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
        const request_duration_units = @divTrunc(request_duration_ns, b.latency_bucket_ns);
        const hist_idx = @min(request_duration_units, b.request_latency_histogram.len - 1);
        b.request_latency_histogram[hist_idx] += 1;

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
            .radius = b.query_radius_meters,
            .duration = duration_s,
        }) catch unreachable;

        print_percentiles_histogram(
            b.output,
            "radius query",
            b.request_latency_histogram,
            b.latency_unit_label,
        );

        b.run_finish();
    }

    // =========================================================================
    // F5.1.4: Polygon Query (Complex Spatial Query Latency)
    // =========================================================================

    fn do_query_polygon(b: *GeoBenchmark, client_index: u32) void {
        assert(b.stage == .query_polygon);
        assert(!b.clients_busy.is_set(client_index));

        if (b.query_index >= b.query_polygon_count) {
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

        const filter: *QueryPolygonFilter = @ptrCast(@alignCast(&b.client_requests[client_index]));
        filter.* = .{
            .vertex_count = 4,
            .hole_count = 0, // Simple polygon (no holes)
            .limit = 100,
            .timestamp_min = 0,
            .timestamp_max = 0,
            .group_id = 0,
        };

        // Add vertices after filter (4 corners of rectangle)
        const request_buf = &b.client_requests[client_index];
        const offset = @sizeOf(QueryPolygonFilter);
        const vertices_ptr: [*]PolygonVertex = @ptrCast(@alignCast(&request_buf[offset]));
        const min_lat = center_lat - half_size;
        const max_lat = center_lat + half_size;
        const min_lon = center_lon - half_size;
        const max_lon = center_lon + half_size;
        vertices_ptr[0] = .{ .lat_nano = min_lat, .lon_nano = min_lon };
        vertices_ptr[1] = .{ .lat_nano = min_lat, .lon_nano = max_lon };
        vertices_ptr[2] = .{ .lat_nano = max_lat, .lon_nano = max_lon };
        vertices_ptr[3] = .{ .lat_nano = max_lat, .lon_nano = min_lon };

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
        const request_duration_units = @divTrunc(request_duration_ns, b.latency_bucket_ns);
        const hist_idx = @min(request_duration_units, b.request_latency_histogram.len - 1);
        b.request_latency_histogram[hist_idx] += 1;

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

        print_percentiles_histogram(
            b.output,
            "polygon query",
            b.request_latency_histogram,
            b.latency_unit_label,
        );

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
            .insert_events => b.insert_events_callback(client, input),
            .query_uuid => b.query_uuid_single_callback(client, input),
            .query_uuid_batch => b.query_uuid_batch_callback(client, input),
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
    const cells_f: f64 = @floatFromInt(cells_per_side);
    const face_f: f64 = @floatFromInt(face);
    const i: u64 = @intFromFloat(lat_norm * cells_f);
    const j: u64 = @intFromFloat((lon_norm * 6.0 - face_f) * cells_f);

    // Pack into S2 cell ID format (simplified)
    return (face << 61) | ((i & 0xFFF) << 49) | ((j & 0xFFF) << 37);
}

/// Percentile specification with integer and decimal parts for sub-percentiles
const PercentileSpec = struct {
    /// Integer part (0-100)
    p: u64,
    /// Decimal part in tenths (e.g., 9 for .9)
    d: u64,

    fn label(self: PercentileSpec) []const u8 {
        return switch (self.p) {
            1 => if (self.d == 0) "p1  " else "p1.?",
            50 => if (self.d == 0) "p50 " else "p50?",
            95 => if (self.d == 0) "p95 " else "p95?",
            99 => if (self.d == 0) "p99 " else if (self.d == 9) "p99.9" else "p99?",
            100 => if (self.d == 0) "p100" else "p100",
            else => "p???",
        };
    }

    /// Calculate the histogram index corresponding to this percentile
    fn histogram_index(self: PercentileSpec, histogram_total: u64) u64 {
        // percentile = p + d/10, so for p99.9: 99 + 9/10 = 99.9
        // histogram_percentile = total * percentile / 100
        // = total * (p + d/10) / 100
        // = (total * p * 10 + total * d) / 1000
        return (histogram_total * self.p * 10 + histogram_total * self.d) / 1000;
    }
};

fn print_percentiles_histogram(
    stdout: std.io.AnyWriter,
    label: []const u8,
    histogram_buckets: []const u64,
    unit_label: []const u8,
) void {
    var histogram_total: u64 = 0;
    for (histogram_buckets) |bucket| histogram_total += bucket;

    if (histogram_total == 0) {
        stdout.print("{s}: no data\n", .{label}) catch unreachable;
        return;
    }

    // Percentiles: p1 (min), p50 (median), p95, p99, p99.9, p100 (max)
    const percentiles = [_]PercentileSpec{
        .{ .p = 1, .d = 0 }, // p1 (min)
        .{ .p = 50, .d = 0 }, // p50 (median)
        .{ .p = 95, .d = 0 }, // p95
        .{ .p = 99, .d = 0 }, // p99
        .{ .p = 99, .d = 9 }, // p99.9
        .{ .p = 100, .d = 0 }, // p100 (max)
    };

    for (percentiles) |pspec| {
        const histogram_percentile_raw: usize = @intCast(pspec.histogram_index(histogram_total));
        const histogram_percentile: usize = @max(histogram_percentile_raw, 1);

        var sum: usize = 0;
        const latency = for (histogram_buckets, 0..) |bucket, bucket_index| {
            sum += bucket;
            if (sum >= histogram_percentile) break bucket_index;
        } else histogram_buckets.len;
        const capped = latency == histogram_buckets.len - 1;
        if (capped) {
            stdout.print("{s} latency {s} >= {} {s} (capped at histogram max)\n", .{
                label,
                pspec.label(),
                latency,
                unit_label,
            }) catch unreachable;
        } else {
            stdout.print("{s} latency {s} = {} {s}\n", .{
                label,
                pspec.label(),
                latency,
                unit_label,
            }) catch unreachable;
        }
    }
}

/// Get current memory usage statistics
fn get_memory_stats() struct { rss_bytes: u64, peak_rss_bytes: u64 } {
    if (builtin.os.tag == .linux) {
        // Read from /proc/self/statm for RSS, /proc/self/status for peak
        const page_size: u64 = 4096;
        var rss_bytes: u64 = 0;
        var peak_rss_bytes: u64 = 0;

        // Try to read current RSS from /proc/self/statm
        if (std.fs.cwd().openFile("/proc/self/statm", .{})) |file| {
            defer file.close();
            var buf: [256]u8 = undefined;
            if (file.reader().readUntilDelimiterOrEof(&buf, '\n')) |line_opt| {
                if (line_opt) |line| {
                    // Format: size resident shared text lib data dt
                    var it = std.mem.splitScalar(u8, line, ' ');
                    _ = it.next(); // size
                    if (it.next()) |resident_str| {
                        if (std.fmt.parseInt(u64, resident_str, 10)) |resident_pages| {
                            rss_bytes = resident_pages * page_size;
                        } else |_| {}
                    }
                }
            } else |_| {}
        } else |_| {}

        // Try to read peak RSS from /proc/self/status
        if (std.fs.cwd().openFile("/proc/self/status", .{})) |file| {
            defer file.close();
            var buf: [4096]u8 = undefined;
            const bytes_read = file.reader().readAll(&buf) catch 0;
            const content = buf[0..bytes_read];
            // Look for VmHWM (high water mark)
            if (std.mem.indexOf(u8, content, "VmHWM:")) |idx| {
                const rest = content[idx + 6 ..];
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                if (it.next()) |value_str| {
                    if (std.fmt.parseInt(u64, std.mem.trimRight(u8, value_str, " \t\n"), 10)) |value_kb| {
                        peak_rss_bytes = value_kb * 1024;
                    } else |_| {}
                }
            }
        } else |_| {}

        return .{ .rss_bytes = rss_bytes, .peak_rss_bytes = peak_rss_bytes };
    } else if (builtin.os.tag == .macos) {
        // Use getrusage on macOS
        // RUSAGE_SELF = 0 (get resource usage for calling process)
        const usage = std.posix.getrusage(0);
        // maxrss is in bytes on macOS
        return .{
            .rss_bytes = @intCast(usage.maxrss),
            .peak_rss_bytes = @intCast(usage.maxrss),
        };
    } else {
        return .{ .rss_bytes = 0, .peak_rss_bytes = 0 };
    }
}

fn print_memory_stats(stdout: std.io.AnyWriter) void {
    const stats = get_memory_stats();
    if (stats.rss_bytes > 0 or stats.peak_rss_bytes > 0) {
        stdout.print(
            \\
            \\=== Memory Statistics ===
            \\current RSS = {} MB
            \\peak RSS    = {} MB
            \\
        , .{
            stats.rss_bytes / (1024 * 1024),
            stats.peak_rss_bytes / (1024 * 1024),
        }) catch unreachable;
    }
}
