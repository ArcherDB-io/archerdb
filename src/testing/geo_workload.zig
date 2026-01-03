//! GeoEvent Workload Generator for VOPR (F4.1.1)
//!
//! This module generates random GeoEvent workloads for the VOPR simulator,
//! enabling deterministic testing of the GeoStateMachine under various
//! fault injection scenarios.
//!
//! ## Workload Patterns
//!
//! The generator supports multiple patterns per the spec:
//! - Random point insertions
//! - Clustered insertions (hotspots)
//! - Moving entity updates (trajectory patterns)
//! - Spatial query bursts
//! - Mixed read/write ratios
//!
//! ## Determinism
//!
//! All randomness comes from the PRNG seed, ensuring reproducible workloads
//! for regression testing and bug reproduction.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const geo_event = @import("../geo_event.zig");
const archerdb = @import("../archerdb.zig");

const GeoEvent = geo_event.GeoEvent;
const Operation = archerdb.Operation;
const geo_state_machine_types = @import("../geo_state_machine.zig");

/// Workload configuration options
pub const Options = struct {
    /// Maximum batch size in bytes
    batch_size_limit: u32 = constants.message_body_size_max / 2,

    /// Target number of total requests
    requests_target: u32 = 10_000,

    /// Probability of write operations (vs queries)
    write_probability: stdx.PRNG.Ratio = .{ .numerator = 70, .denominator = 100 },

    /// Probability of using clustered coordinates (hotspot)
    cluster_probability: stdx.PRNG.Ratio = .{ .numerator = 30, .denominator = 100 },

    /// Number of hotspot centers for clustered insertions
    hotspot_count: u8 = 5,

    /// Hotspot radius in nanodegrees
    hotspot_radius: i64 = 100_000_000, // ~0.1 degrees

    /// Number of tracked entities for updates/queries
    tracked_entities_max: u32 = 1000,
};

/// GeoEvent workload generator for VOPR simulation.
pub fn GeoWorkloadType(comptime StateMachine: type) type {
    return struct {
        const Self = @This();

        /// Return type for build_request and related functions.
        /// Named struct to ensure type compatibility across all request builders.
        pub const RequestResult = struct {
            operation: StateMachine.Operation,
            size: usize,
        };

        prng: *stdx.PRNG,
        options: Options,

        /// Request tracking
        requests_sent: usize = 0,
        requests_delivered: usize = 0,

        /// Tracked entity IDs for queries and updates
        tracked_entities: std.ArrayList(u128),

        /// Hotspot centers (for clustered insertions)
        hotspots: []HotspotCenter,

        /// Statistics for monitoring
        stats: WorkloadStats = .{},

        const HotspotCenter = struct {
            lat_nano: i64,
            lon_nano: i64,
        };

        const WorkloadStats = struct {
            inserts_sent: u64 = 0,
            queries_sent: u64 = 0,
            uuid_queries: u64 = 0,
            radius_queries: u64 = 0,
            polygon_queries: u64 = 0,
            updates_sent: u64 = 0,
            deletes_sent: u64 = 0,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            prng: *stdx.PRNG,
            options: Options,
        ) !Self {
            var tracked = std.ArrayList(u128).init(allocator);
            errdefer tracked.deinit();

            // Generate random hotspot centers
            const hotspots = try allocator.alloc(HotspotCenter, options.hotspot_count);
            errdefer allocator.free(hotspots);

            for (hotspots) |*hs| {
                hs.* = .{
                    // Random lat in valid range [-90, +90] degrees
                    // Generate unsigned [0, 180B] then shift to signed range
                    .lat_nano = @as(i64, @intCast(prng.range_inclusive(u64, 0, 180_000_000_000))) - 90_000_000_000,
                    // Random lon in valid range [-180, +180] degrees
                    .lon_nano = @as(i64, @intCast(prng.range_inclusive(u64, 0, 360_000_000_000))) - 180_000_000_000,
                };
            }

            return Self{
                .prng = prng,
                .options = options,
                .tracked_entities = tracked,
                .hotspots = hotspots,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.tracked_entities.deinit();
            allocator.free(self.hotspots);
        }

        /// Returns true when workload is complete.
        pub fn done(self: *const Self) bool {
            return self.requests_sent >= self.options.requests_target and
                self.requests_sent == self.requests_delivered;
        }

        /// Build a request body for the next operation.
        pub fn build_request(
            self: *Self,
            client_index: usize,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            _ = client_index;

            self.requests_sent += 1;

            // Decide between write and query operations
            if (self.prng.chance(self.options.write_probability)) {
                return self.build_write_request(body);
            } else {
                return self.build_query_request(body);
            }
        }

        /// Build a write operation (insert, update, or delete).
        fn build_write_request(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            // Weight distribution: 80% inserts, 15% updates, 5% deletes
            const roll = self.prng.int(u8);
            if (roll < 204) { // ~80%
                return self.build_insert_request(body);
            } else if (roll < 242) { // ~15%
                return self.build_update_request(body);
            } else { // ~5%
                return self.build_delete_request(body);
            }
        }

        /// Build an insert_events request.
        fn build_insert_request(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const events: []GeoEvent = stdx.bytes_as_slice(.inexact, GeoEvent, body);
            const max_events = @min(events.len, self.options.batch_size_limit / @sizeOf(GeoEvent));

            // Generate 1 to max_events
            const event_count = self.prng.int_inclusive(usize, @max(1, max_events));

            for (events[0..event_count]) |*event| {
                event.* = self.generate_geo_event();

                // Track some entities for future queries/updates
                if (self.tracked_entities.items.len < self.options.tracked_entities_max) {
                    if (self.prng.chance(.{ .numerator = 10, .denominator = 100 })) {
                        self.tracked_entities.append(event.entity_id) catch {};
                    }
                }
            }

            self.stats.inserts_sent += event_count;

            return .{
                .operation = .insert_events,
                .size = event_count * @sizeOf(GeoEvent),
            };
        }

        /// Build an update request (insert with existing entity_id).
        fn build_update_request(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            if (self.tracked_entities.items.len == 0) {
                // No entities to update, insert instead
                return self.build_insert_request(body);
            }

            const events: []GeoEvent = stdx.bytes_as_slice(.inexact, GeoEvent, body);
            const event = &events[0];

            // Pick a random tracked entity
            const idx = self.prng.int(usize) % self.tracked_entities.items.len;
            const entity_id = self.tracked_entities.items[idx];

            // Generate new location for existing entity
            event.* = self.generate_geo_event();
            event.entity_id = entity_id;

            self.stats.updates_sent += 1;

            return .{
                .operation = .insert_events,
                .size = @sizeOf(GeoEvent),
            };
        }

        /// Build a delete request.
        fn build_delete_request(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            if (self.tracked_entities.items.len == 0) {
                // No entities to delete, insert instead
                return self.build_insert_request(body);
            }

            // Use the body for entity IDs (u128 array)
            const entity_ids: []u128 = stdx.bytes_as_slice(.inexact, u128, body);

            // Pick random entities to delete
            const count = self.prng.int_inclusive(usize, @min(entity_ids.len, 10));
            for (entity_ids[0..count], 0..) |*id, i| {
                _ = i;
                const idx = self.prng.int(usize) % self.tracked_entities.items.len;
                id.* = self.tracked_entities.items[idx];
            }

            self.stats.deletes_sent += count;

            return .{
                .operation = .delete_entities,
                .size = count * @sizeOf(u128),
            };
        }

        /// Build a query operation.
        fn build_query_request(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            // Weight distribution: 40% UUID, 40% radius, 20% polygon
            const roll = self.prng.int(u8);
            if (roll < 102) { // ~40%
                return self.build_uuid_query(body);
            } else if (roll < 204) { // ~40%
                return self.build_radius_query(body);
            } else { // ~20%
                return self.build_polygon_query(body);
            }
        }

        /// Build a query_uuid request.
        fn build_uuid_query(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryUuidFilter, @ptrCast(@alignCast(body.ptr)));

            if (self.tracked_entities.items.len > 0 and
                self.prng.chance(.{ .numerator = 80, .denominator = 100 }))
            {
                // Query a known entity
                const idx = self.prng.int(usize) % self.tracked_entities.items.len;
                filter.entity_id = self.tracked_entities.items[idx];
            } else {
                // Query a random (likely non-existent) entity
                filter.entity_id = self.prng.int(u128);
            }

            filter.limit = self.prng.int_inclusive(u32, 100);
            filter.reserved = [_]u8{0} ** 108;

            self.stats.uuid_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_uuid,
                .size = @sizeOf(archerdb.QueryUuidFilter),
            };
        }

        /// Build a query_radius request.
        fn build_radius_query(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryRadiusFilter, @ptrCast(@alignCast(body.ptr)));

            // Use hotspot center or random location
            if (self.prng.chance(.{ .numerator = 70, .denominator = 100 }) and
                self.hotspots.len > 0)
            {
                const hs = self.hotspots[self.prng.int(usize) % self.hotspots.len];
                filter.center_lat_nano = hs.lat_nano;
                filter.center_lon_nano = hs.lon_nano;
            } else {
                filter.center_lat_nano = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 180_000_000_000))) - 90_000_000_000;
                filter.center_lon_nano = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 360_000_000_000))) - 180_000_000_000;
            }

            // Radius between 100m and 100km
            filter.radius_mm = self.prng.range_inclusive(u32, 100_000, 100_000_000);
            filter.limit = self.prng.int_inclusive(u32, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 80;

            self.stats.radius_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_radius,
                .size = @sizeOf(archerdb.QueryRadiusFilter),
            };
        }

        /// Build a query_polygon request.
        fn build_polygon_query(
            self: *Self,
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryPolygonFilter, @ptrCast(@alignCast(body.ptr)));

            // Generate polygon with 3-10 vertices
            const vertex_count = self.prng.int_inclusive(u32, 10);
            filter.vertex_count = @max(3, vertex_count);
            filter.limit = self.prng.int_inclusive(u32, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 96;

            // Generate vertices after filter header
            const vertices_start = @sizeOf(archerdb.QueryPolygonFilter);
            const vertices_bytes = body[vertices_start..];
            const vertices = stdx.bytes_as_slice(.inexact, geo_state_machine_types.PolygonVertex, vertices_bytes);

            // Generate polygon around a center point
            var center_lat: i64 = undefined;
            var center_lon: i64 = undefined;

            if (self.prng.chance(.{ .numerator = 70, .denominator = 100 }) and
                self.hotspots.len > 0)
            {
                const hs = self.hotspots[self.prng.int(usize) % self.hotspots.len];
                center_lat = hs.lat_nano;
                center_lon = hs.lon_nano;
            } else {
                // Use slightly smaller range to avoid edge cases with polygon vertices
                center_lat = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 170_000_000_000))) - 85_000_000_000;
                center_lon = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 350_000_000_000))) - 175_000_000_000;
            }

            // Generate vertices in a rough circle around center
            // Radius between 0.1° and 5° in nanodegrees
            const radius: i64 = @as(i64, @intCast(self.prng.range_inclusive(u64, 100_000_000, 5_000_000_000)));
            for (vertices[0..filter.vertex_count], 0..) |*v, i| {
                // Angle for this vertex
                const angle_factor = @divTrunc(@as(i64, @intCast(i)) * 360, @as(i64, filter.vertex_count));
                const lat_offset = @divTrunc(radius * angle_factor, 360);
                const lon_offset = radius - @as(i64, @intCast(@abs(lat_offset)));

                v.lat_nano = std.math.clamp(
                    center_lat + lat_offset,
                    -90_000_000_000,
                    90_000_000_000,
                );
                v.lon_nano = std.math.clamp(
                    center_lon + @mod(lon_offset * @as(i64, @intCast(i)), radius * 2) - radius,
                    -180_000_000_000,
                    180_000_000_000,
                );
            }

            self.stats.polygon_queries += 1;
            self.stats.queries_sent += 1;

            const total_size = vertices_start + filter.vertex_count * @sizeOf(geo_state_machine_types.PolygonVertex);
            return .{
                .operation = .query_polygon,
                .size = total_size,
            };
        }

        /// Generate a random GeoEvent.
        fn generate_geo_event(self: *Self) GeoEvent {
            var lat_nano: i64 = undefined;
            var lon_nano: i64 = undefined;

            // Decide whether to use clustered or random coordinates
            if (self.prng.chance(self.options.cluster_probability) and self.hotspots.len > 0) {
                // Clustered: pick a hotspot and add random offset
                const hs = self.hotspots[self.prng.int(usize) % self.hotspots.len];
                // Generate unsigned offset [0, 2*radius] then shift to [-radius, +radius]
                const radius: u64 = @intCast(@as(i64, @intCast(@abs(self.options.hotspot_radius))));
                const lat_offset_unsigned = self.prng.range_inclusive(u64, 0, radius * 2);
                const lon_offset_unsigned = self.prng.range_inclusive(u64, 0, radius * 2);
                const lat_offset: i64 = @as(i64, @intCast(lat_offset_unsigned)) - @as(i64, @intCast(radius));
                const lon_offset: i64 = @as(i64, @intCast(lon_offset_unsigned)) - @as(i64, @intCast(radius));

                lat_nano = std.math.clamp(
                    hs.lat_nano + lat_offset,
                    -90_000_000_000,
                    90_000_000_000,
                );
                lon_nano = std.math.clamp(
                    hs.lon_nano + lon_offset,
                    -180_000_000_000,
                    180_000_000_000,
                );
            } else {
                // Random coordinates: generate unsigned [0, range] then shift to signed
                lat_nano = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 180_000_000_000))) - 90_000_000_000;
                lon_nano = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 360_000_000_000))) - 180_000_000_000;
            }

            // Altitude: [0, 20_000_000] - 11_000_000 = [-11_000_000, +9_000_000] mm (ocean floor to Everest)
            const altitude_mm: i32 = @as(i32, @intCast(self.prng.range_inclusive(u32, 0, 20_000_000))) - 11_000_000;

            return GeoEvent{
                .id = 0, // Set by state machine
                .entity_id = self.prng.int(u128),
                .correlation_id = self.prng.int(u128),
                .user_data = self.prng.int(u128),
                .lat_nano = lat_nano,
                .lon_nano = lon_nano,
                .group_id = self.prng.int(u64) % 100, // Small group_id space
                .timestamp = 0, // Set by state machine
                .altitude_mm = altitude_mm,
                .velocity_mms = self.prng.int(u32) % 100_000, // Up to 100 m/s
                .ttl_seconds = if (self.prng.chance(.{ .numerator = 20, .denominator = 100 }))
                    self.prng.int_inclusive(u32, 86400) // 0-24h TTL
                else
                    0, // No TTL
                .accuracy_mm = self.prng.int(u16) % 10000, // Up to 10m accuracy
                .heading_cdeg = self.prng.int(u16) % 36000, // 0-360 degrees
                .flags = .none,
                .reserved = [_]u8{0} ** 12,
            };
        }

        /// Handle reply from state machine.
        pub fn on_reply(
            self: *Self,
            client_index: usize,
            operation: StateMachine.Operation,
            timestamp: u64,
            request_body: []align(@alignOf(vsr.Header)) const u8,
            reply_body: []align(@alignOf(vsr.Header)) const u8,
        ) void {
            _ = client_index;
            _ = timestamp;
            _ = request_body;
            _ = reply_body;
            _ = operation;

            self.requests_delivered += 1;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "GeoWorkload: initialization" {
    const allocator = std.testing.allocator;
    var prng = stdx.PRNG.from_seed(12345);

    // Mock state machine type
    const MockStateMachine = struct {
        pub const Operation = archerdb.Operation;
    };

    var workload = try GeoWorkloadType(MockStateMachine).init(
        allocator,
        &prng,
        .{},
    );
    defer workload.deinit(allocator);

    try std.testing.expect(!workload.done());
    try std.testing.expectEqual(@as(usize, 0), workload.requests_sent);
}

test "GeoWorkload: generate events" {
    const allocator = std.testing.allocator;
    var prng = stdx.PRNG.from_seed(54321);

    const MockStateMachine = struct {
        pub const Operation = archerdb.Operation;
    };

    var workload = try GeoWorkloadType(MockStateMachine).init(
        allocator,
        &prng,
        .{ .requests_target = 100 },
    );
    defer workload.deinit(allocator);

    var body: [4096]u8 align(@alignOf(vsr.Header)) = undefined;

    // Generate some requests
    for (0..10) |_| {
        const result = workload.build_request(0, &body);
        try std.testing.expect(result.size > 0);
        try std.testing.expect(result.size <= body.len);
    }

    try std.testing.expectEqual(@as(usize, 10), workload.requests_sent);
}

test "GeoWorkload: determinism" {
    const allocator = std.testing.allocator;

    const MockStateMachine = struct {
        pub const Operation = archerdb.Operation;
    };

    // Run twice with same seed
    var results1: [10]struct { op: archerdb.Operation, size: usize } = undefined;
    var results2: [10]struct { op: archerdb.Operation, size: usize } = undefined;

    {
        var prng = stdx.PRNG.from_seed(99999);
        var workload = try GeoWorkloadType(MockStateMachine).init(
            allocator,
            &prng,
            .{ .requests_target = 10 },
        );
        defer workload.deinit(allocator);

        var body: [4096]u8 align(@alignOf(vsr.Header)) = undefined;
        for (&results1) |*r| {
            const result = workload.build_request(0, &body);
            r.* = .{ .op = result.operation, .size = result.size };
        }
    }

    {
        var prng = stdx.PRNG.from_seed(99999);
        var workload = try GeoWorkloadType(MockStateMachine).init(
            allocator,
            &prng,
            .{ .requests_target = 10 },
        );
        defer workload.deinit(allocator);

        var body: [4096]u8 align(@alignOf(vsr.Header)) = undefined;
        for (&results2) |*r| {
            const result = workload.build_request(0, &body);
            r.* = .{ .op = result.operation, .size = result.size };
        }
    }

    // Results should be identical
    for (results1, results2) |r1, r2| {
        try std.testing.expectEqual(r1.op, r2.op);
        try std.testing.expectEqual(r1.size, r2.size);
    }
}
