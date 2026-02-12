// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
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

    /// Probability of using adversarial/edge-case patterns (F4.1.3)
    adversarial_probability: stdx.PRNG.Ratio = .{ .numerator = 20, .denominator = 100 },

    /// Generate randomized options for VOPR testing.
    /// Similar to the base workload's Options.generate.
    pub fn generate(prng: *stdx.PRNG, options: struct {
        batch_size_limit: u32,
        multi_batch_per_request_limit: u32,
        client_count: usize,
        in_flight_max: usize,
    }) Options {
        _ = options.multi_batch_per_request_limit;
        _ = options.client_count;
        _ = options.in_flight_max;

        return .{
            .batch_size_limit = options.batch_size_limit,
            .requests_target = prng.range_inclusive(u32, 1000, 50000),
            .write_probability = .{
                .numerator = prng.range_inclusive(u8, 50, 90),
                .denominator = 100,
            },
            .cluster_probability = .{
                .numerator = prng.range_inclusive(u8, 10, 50),
                .denominator = 100,
            },
            .hotspot_count = prng.range_inclusive(u8, 2, 10),
            .hotspot_radius = @as(i64, @intCast(
                prng.range_inclusive(u64, 10_000_000, 500_000_000),
            )),
            .tracked_entities_max = prng.range_inclusive(u32, 100, 5000),
            .adversarial_probability = .{
                .numerator = prng.range_inclusive(u8, 10, 40),
                .denominator = 100,
            },
        };
    }
};

/// Edge-case coordinates for adversarial testing (F4.1.3)
/// Per testing-simulation spec: S2 cell calculation edge cases
pub const EdgeCaseCoordinates = struct {
    /// North pole (90°N)
    pub const NORTH_POLE_LAT: i64 = 90_000_000_000;
    /// South pole (90°S)
    pub const SOUTH_POLE_LAT: i64 = -90_000_000_000;
    /// Anti-meridian East (180°E)
    pub const ANTI_MERIDIAN_EAST: i64 = 180_000_000_000;
    /// Anti-meridian West (180°W)
    pub const ANTI_MERIDIAN_WEST: i64 = -180_000_000_000;
    /// Equator
    pub const EQUATOR_LAT: i64 = 0;
    /// Prime meridian
    pub const PRIME_MERIDIAN_LON: i64 = 0;
    /// Max valid latitude
    pub const MAX_LAT: i64 = 90_000_000_000;
    /// Min valid latitude
    pub const MIN_LAT: i64 = -90_000_000_000;
    /// Max valid longitude
    pub const MAX_LON: i64 = 180_000_000_000;
    /// Min valid longitude
    pub const MIN_LON: i64 = -180_000_000_000;
    /// One nanodegree (minimum precision difference)
    pub const ONE_NANODEGREE: i64 = 1;
};

/// GeoEvent workload generator for VOPR simulation.
pub fn GeoWorkloadType(comptime StateMachine: type) type {
    return struct {
        /// Return type for build_request and related functions.
        /// Named struct to ensure type compatibility across all request builders.
        pub const RequestResult = struct {
            operation: StateMachine.Operation,
            size: usize,
        };

        /// File-level Options reference for internal use
        const FileOptions = @import("geo_workload.zig").Options;

        /// Re-export Options for VOPR access as StateMachine.Workload.Options
        pub const Options = FileOptions;

        prng: *stdx.PRNG,
        options: FileOptions,

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
            /// Adversarial pattern statistics (F4.1.3)
            adversarial_queries: u64 = 0,
            pole_queries: u64 = 0,
            antimeridian_queries: u64 = 0,
            boundary_queries: u64 = 0,
            /// LWW conflict resolution scenarios (CLEAN-05)
            /// Concurrent updates to same entity test LWW determinism
            concurrent_updates: u64 = 0,
            /// TTL-enabled inserts for expiration testing
            ttl_inserts: u64 = 0,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            prng: *stdx.PRNG,
            options: FileOptions,
        ) !@This() {
            var tracked = std.ArrayList(u128).init(allocator);
            errdefer tracked.deinit();

            // Generate random hotspot centers
            const hotspots = try allocator.alloc(HotspotCenter, options.hotspot_count);
            errdefer allocator.free(hotspots);

            for (hotspots) |*hs| {
                // Random lat in valid range [-90, +90] degrees
                // Generate unsigned [0, 180B] then shift to signed range
                const lat_raw = prng.range_inclusive(u64, 0, 180_000_000_000);
                // Random lon in valid range [-180, +180] degrees
                const lon_raw = prng.range_inclusive(u64, 0, 360_000_000_000);
                hs.* = .{
                    .lat_nano = @as(i64, @intCast(lat_raw)) - 90_000_000_000,
                    .lon_nano = @as(i64, @intCast(lon_raw)) - 180_000_000_000,
                };
            }

            return @This(){
                .prng = prng,
                .options = options,
                .tracked_entities = tracked,
                .hotspots = hotspots,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.tracked_entities.deinit();
            allocator.free(self.hotspots);
        }

        /// Returns true when workload is complete.
        pub fn done(self: *const @This()) bool {
            return self.requests_sent >= self.options.requests_target and
                self.requests_sent == self.requests_delivered;
        }

        /// Build a request body for the next operation.
        pub fn build_request(
            self: *@This(),
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
            self: *@This(),
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
        /// Covers CLEAN-05 scenarios: TTL inserts, coordinate edge cases.
        fn build_insert_request(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const events: []GeoEvent = stdx.bytes_as_slice(.inexact, GeoEvent, body);
            const max_events = @min(events.len, self.options.batch_size_limit / @sizeOf(GeoEvent));

            // Generate 1 to max_events
            const event_count = self.prng.int_inclusive(usize, @max(1, max_events));

            for (events[0..event_count]) |*event| {
                event.* = self.generate_geo_event();

                // Track TTL inserts for statistics
                if (event.ttl_seconds > 0) {
                    self.stats.ttl_inserts += 1;
                }

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
        /// Tests LWW conflict resolution when multiple updates target same entity (CLEAN-05).
        /// VSR consensus ensures deterministic ordering; LWW uses highest timestamp wins.
        fn build_update_request(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            if (self.tracked_entities.items.len == 0) {
                // No entities to update, insert instead
                return self.build_insert_request(body);
            }

            const events: []GeoEvent = stdx.bytes_as_slice(.inexact, GeoEvent, body);
            const max_events = @min(events.len, self.options.batch_size_limit / @sizeOf(GeoEvent));

            // Sometimes send multiple updates in same batch (tests concurrent LWW)
            const batch_concurrent = self.prng.chance(.{ .numerator = 20, .denominator = 100 }) and
                max_events >= 2;
            const event_count: usize = if (batch_concurrent) @min(3, max_events) else 1;

            // Pick a random tracked entity
            const idx = self.prng.int(usize) % self.tracked_entities.items.len;
            const entity_id = self.tracked_entities.items[idx];

            // Generate updates for the same entity (LWW conflict scenario)
            for (events[0..event_count]) |*event| {
                event.* = self.generate_geo_event();
                event.entity_id = entity_id;
            }

            self.stats.updates_sent += event_count;
            if (event_count > 1) {
                self.stats.concurrent_updates += 1;
            }

            return .{
                .operation = .insert_events,
                .size = event_count * @sizeOf(GeoEvent),
            };
        }

        /// Build a delete request.
        fn build_delete_request(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            if (self.tracked_entities.items.len == 0) {
                // No entities to delete, insert instead
                return self.build_insert_request(body);
            }

            // Use the body for entity IDs (u128 array)
            const entity_ids: []u128 = stdx.bytes_as_slice(.inexact, u128, body);

            // Pick random entities to delete, respecting batch_size_limit
            const max_by_limit = self.options.batch_size_limit / @sizeOf(u128);
            const max_count = @min(entity_ids.len, @min(max_by_limit, 10));
            const count = self.prng.int_inclusive(usize, @max(1, max_count));
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
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            // Check for adversarial pattern (F4.1.3)
            if (self.prng.chance(self.options.adversarial_probability)) {
                return self.build_adversarial_query(body);
            }

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

        /// Build an adversarial/edge-case spatial query (F4.1.3).
        /// Tests boundary conditions per testing-simulation spec.
        fn build_adversarial_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            self.stats.adversarial_queries += 1;

            // Randomly select adversarial query type
            const adversarial_type = self.prng.int(u8) % 6;
            return switch (adversarial_type) {
                0 => self.build_pole_radius_query(body),
                1 => self.build_antimeridian_radius_query(body),
                2 => self.build_zero_radius_query(body),
                3 => self.build_max_radius_query(body),
                4 => self.build_boundary_polygon_query(body),
                else => self.build_concave_polygon_query(body),
            };
        }

        /// Radius query centered at a pole (tests S2 cell edge cases)
        fn build_pole_radius_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryRadiusFilter, @ptrCast(@alignCast(body.ptr)));

            // Choose North or South pole
            filter.center_lat_nano = if (self.prng.chance(.{ .numerator = 50, .denominator = 100 }))
                EdgeCaseCoordinates.NORTH_POLE_LAT
            else
                EdgeCaseCoordinates.SOUTH_POLE_LAT;
            filter.center_lon_nano = 0; // Longitude irrelevant at poles

            // Radius between 1km and 100km
            filter.radius_mm = self.prng.range_inclusive(u32, 1_000_000, 100_000_000);
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 80;

            self.stats.pole_queries += 1;
            self.stats.radius_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_radius,
                .size = @sizeOf(archerdb.QueryRadiusFilter),
            };
        }

        /// Radius query crossing the anti-meridian (±180°)
        fn build_antimeridian_radius_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryRadiusFilter, @ptrCast(@alignCast(body.ptr)));

            // Random latitude, longitude near anti-meridian
            const lat_raw = self.prng.range_inclusive(u64, 0, 180_000_000_000);
            filter.center_lat_nano = @as(i64, @intCast(lat_raw)) - 90_000_000_000;
            // Longitude very close to ±180°
            const offset = @as(i64, @intCast(self.prng.range_inclusive(u64, 0, 10_000_000)));
            filter.center_lon_nano = if (self.prng.chance(.{ .numerator = 50, .denominator = 100 }))
                EdgeCaseCoordinates.ANTI_MERIDIAN_EAST - offset
            else
                EdgeCaseCoordinates.ANTI_MERIDIAN_WEST + offset;

            // Large enough radius to cross anti-meridian
            filter.radius_mm = self.prng.range_inclusive(u32, 50_000_000, 500_000_000); // 50-500km
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 80;

            self.stats.antimeridian_queries += 1;
            self.stats.radius_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_radius,
                .size = @sizeOf(archerdb.QueryRadiusFilter),
            };
        }

        /// Zero-radius query (point query edge case)
        fn build_zero_radius_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryRadiusFilter, @ptrCast(@alignCast(body.ptr)));

            const lat_rand = self.prng.range_inclusive(u64, 0, 180_000_000_000);
            const lon_rand = self.prng.range_inclusive(u64, 0, 360_000_000_000);
            filter.center_lat_nano = @as(i64, @intCast(lat_rand)) - 90_000_000_000;
            filter.center_lon_nano = @as(i64, @intCast(lon_rand)) - 180_000_000_000;
            filter.radius_mm = 1; // Near-zero radius (1mm point query)
            filter.limit = self.prng.range_inclusive(u32, 1, 100);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 80;

            self.stats.boundary_queries += 1;
            self.stats.radius_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_radius,
                .size = @sizeOf(archerdb.QueryRadiusFilter),
            };
        }

        /// Maximum radius query (1000km per spec)
        fn build_max_radius_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryRadiusFilter, @ptrCast(@alignCast(body.ptr)));

            const lat_rand = self.prng.range_inclusive(u64, 0, 180_000_000_000);
            const lon_rand = self.prng.range_inclusive(u64, 0, 360_000_000_000);
            filter.center_lat_nano = @as(i64, @intCast(lat_rand)) - 90_000_000_000;
            filter.center_lon_nano = @as(i64, @intCast(lon_rand)) - 180_000_000_000;
            filter.radius_mm = 1_000_000_000; // 1000km max radius
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.reserved = [_]u8{0} ** 80;

            self.stats.boundary_queries += 1;
            self.stats.radius_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_radius,
                .size = @sizeOf(archerdb.QueryRadiusFilter),
            };
        }

        /// Polygon query at coordinate boundaries (min/max vertices, pole-containing)
        fn build_boundary_polygon_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryPolygonFilter, @ptrCast(@alignCast(body.ptr)));

            // Use minimum vertices (3) or maximum (capped by batch_size_limit)
            const use_min = self.prng.chance(.{ .numerator = 50, .denominator = 100 });
            const vertices_start = @sizeOf(archerdb.QueryPolygonFilter);
            const vertices_bytes = body[vertices_start..];
            const max_by_body = vertices_bytes.len / @sizeOf(geo_state_machine_types.PolygonVertex);
            // Limit vertices to what fits in batch_size_limit
            const vert_size = @sizeOf(geo_state_machine_types.PolygonVertex);
            const max_by_limit = if (self.options.batch_size_limit > vertices_start)
                (self.options.batch_size_limit - vertices_start) / vert_size
            else
                3; // Minimum polygon
            const max_vertices = @min(max_by_body, @min(max_by_limit, 100));

            filter.vertex_count = if (use_min) 3 else @as(u32, @intCast(@max(3, max_vertices)));
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.hole_count = 0; // Simple polygon (no holes)
            filter.reserved = [_]u8{0} ** 88;

            const PV = geo_state_machine_types.PolygonVertex;
            const vertices = stdx.bytes_as_slice(.inexact, PV, vertices_bytes);

            // Generate polygon containing a pole or crossing anti-meridian
            const pole_containing = self.prng.chance(.{ .numerator = 50, .denominator = 100 });
            if (pole_containing) {
                // Triangle around north pole
                vertices[0] = .{ .lat_nano = 85_000_000_000, .lon_nano = 0 };
                vertices[1] = .{ .lat_nano = 85_000_000_000, .lon_nano = 120_000_000_000 };
                vertices[2] = .{ .lat_nano = 85_000_000_000, .lon_nano = -120_000_000_000 };
                // Fill remaining vertices with valid interpolated points if needed
                for (vertices[3..filter.vertex_count]) |*v| {
                    v.* = .{ .lat_nano = 85_000_000_000, .lon_nano = 0 };
                }
            } else {
                // Polygon crossing anti-meridian
                vertices[0] = .{ .lat_nano = 0, .lon_nano = 170_000_000_000 };
                vertices[1] = .{ .lat_nano = 10_000_000_000, .lon_nano = -170_000_000_000 };
                vertices[2] = .{ .lat_nano = -10_000_000_000, .lon_nano = -170_000_000_000 };
                for (vertices[3..filter.vertex_count]) |*v| {
                    v.* = .{ .lat_nano = 0, .lon_nano = 170_000_000_000 };
                }
            }

            self.stats.boundary_queries += 1;
            self.stats.polygon_queries += 1;
            self.stats.queries_sent += 1;

            const pv_size = @sizeOf(geo_state_machine_types.PolygonVertex);
            const total_size = vertices_start + filter.vertex_count * pv_size;
            return .{
                .operation = .query_polygon,
                .size = total_size,
            };
        }

        /// Concave polygon query (tests point-in-polygon edge cases)
        fn build_concave_polygon_query(
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryPolygonFilter, @ptrCast(@alignCast(body.ptr)));

            const vertices_start = @sizeOf(archerdb.QueryPolygonFilter);
            const pv_size = @sizeOf(geo_state_machine_types.PolygonVertex);

            // Check if L-shape (6 vertices) fits in batch_size_limit
            const l_shape_size = vertices_start + 6 * pv_size;
            if (self.options.batch_size_limit < l_shape_size) {
                // Batch too small for L-shape, fall back to radius query
                return self.build_radius_query(body);
            }

            // Concave polygon (L-shape or star)
            filter.vertex_count = 6; // L-shape
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.hole_count = 0; // Simple polygon (no holes)
            filter.reserved = [_]u8{0} ** 88;

            const vertices_bytes = body[vertices_start..];
            const PV = geo_state_machine_types.PolygonVertex;
            const vertices = stdx.bytes_as_slice(.inexact, PV, vertices_bytes);

            // Generate L-shaped concave polygon around a random center
            const lat_rand = self.prng.range_inclusive(u64, 0, 160_000_000_000);
            const lon_rand = self.prng.range_inclusive(u64, 0, 340_000_000_000);
            const center_lat = @as(i64, @intCast(lat_rand)) - 80_000_000_000;
            const center_lon = @as(i64, @intCast(lon_rand)) - 170_000_000_000;
            const size: i64 = 1_000_000_000; // ~1 degree
            const half = @divTrunc(size, 2);

            // L-shape vertices (concave at vertex 2)
            vertices[0] = .{ .lat_nano = center_lat, .lon_nano = center_lon };
            vertices[1] = .{ .lat_nano = center_lat + size, .lon_nano = center_lon };
            vertices[2] = .{ .lat_nano = center_lat + size, .lon_nano = center_lon + half };
            vertices[3] = .{ .lat_nano = center_lat + half, .lon_nano = center_lon + half };
            vertices[4] = .{ .lat_nano = center_lat + half, .lon_nano = center_lon + size };
            vertices[5] = .{ .lat_nano = center_lat, .lon_nano = center_lon + size };

            self.stats.boundary_queries += 1;
            self.stats.polygon_queries += 1;
            self.stats.queries_sent += 1;

            const total_size = vertices_start + filter.vertex_count * pv_size;
            return .{
                .operation = .query_polygon,
                .size = total_size,
            };
        }

        /// Build a query_uuid request.
        fn build_uuid_query(
            self: *@This(),
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

            filter.reserved = [_]u8{0} ** 16;

            self.stats.uuid_queries += 1;
            self.stats.queries_sent += 1;

            return .{
                .operation = .query_uuid,
                .size = @sizeOf(archerdb.QueryUuidFilter),
            };
        }

        /// Build a query_radius request.
        fn build_radius_query(
            self: *@This(),
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
                const lat_rand = self.prng.range_inclusive(u64, 0, 180_000_000_000);
                const lon_rand = self.prng.range_inclusive(u64, 0, 360_000_000_000);
                filter.center_lat_nano = @as(i64, @intCast(lat_rand)) - 90_000_000_000;
                filter.center_lon_nano = @as(i64, @intCast(lon_rand)) - 180_000_000_000;
            }

            // Radius between 100m and 100km
            filter.radius_mm = self.prng.range_inclusive(u32, 100_000, 100_000_000);
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
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
            self: *@This(),
            body: []align(@alignOf(vsr.Header)) u8,
        ) RequestResult {
            const filter = @as(*archerdb.QueryPolygonFilter, @ptrCast(@alignCast(body.ptr)));

            const vertices_start = @sizeOf(archerdb.QueryPolygonFilter);
            const pv_size = @sizeOf(geo_state_machine_types.PolygonVertex);

            // Calculate max vertices that fit in batch_size_limit
            const max_by_limit: u32 = if (self.options.batch_size_limit > vertices_start)
                @intCast((self.options.batch_size_limit - vertices_start) / pv_size)
            else
                3; // Minimum polygon

            // Check if even minimum polygon fits
            if (max_by_limit < 3) {
                // Batch too small for polygon, fall back to radius query
                return self.build_radius_query(body);
            }

            // Generate polygon with 3 to min(10, max_by_limit) vertices
            const vertex_count = self.prng.int_inclusive(u32, @min(10, max_by_limit));
            filter.vertex_count = @max(3, vertex_count);
            filter.limit = self.prng.range_inclusive(u32, 1, 1000);
            filter.timestamp_min = 0;
            filter.timestamp_max = 0;
            filter.group_id = 0;
            filter.hole_count = 0; // Simple polygon (no holes)
            filter.reserved = [_]u8{0} ** 88;
            const vertices_bytes = body[vertices_start..];
            const PV = geo_state_machine_types.PolygonVertex;
            const vertices = stdx.bytes_as_slice(.inexact, PV, vertices_bytes);

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
                const lat_rand = self.prng.range_inclusive(u64, 0, 170_000_000_000);
                const lon_rand = self.prng.range_inclusive(u64, 0, 350_000_000_000);
                center_lat = @as(i64, @intCast(lat_rand)) - 85_000_000_000;
                center_lon = @as(i64, @intCast(lon_rand)) - 175_000_000_000;
            }

            // Generate vertices in a rough circle around center
            // Radius between 0.1° and 5° in nanodegrees
            const rad_rand = self.prng.range_inclusive(u64, 100_000_000, 5_000_000_000);
            const radius: i64 = @as(i64, @intCast(rad_rand));
            const vc: i64 = @intCast(filter.vertex_count);
            for (vertices[0..filter.vertex_count], 0..) |*v, i| {
                // Angle for this vertex
                const idx: i64 = @intCast(i);
                const angle_factor = @divTrunc(idx * 360, vc);
                const lat_offset = @divTrunc(radius * angle_factor, 360);
                const lon_offset = radius - @as(i64, @intCast(@abs(lat_offset)));
                const lon_mod = @mod(lon_offset * idx, radius * 2) - radius;

                v.lat_nano = std.math.clamp(
                    center_lat + lat_offset,
                    -90_000_000_000,
                    90_000_000_000,
                );
                v.lon_nano = std.math.clamp(
                    center_lon + lon_mod,
                    -180_000_000_000,
                    180_000_000_000,
                );
            }

            self.stats.polygon_queries += 1;
            self.stats.queries_sent += 1;

            const total_size = vertices_start + filter.vertex_count * pv_size;
            return .{
                .operation = .query_polygon,
                .size = total_size,
            };
        }

        /// Generate a random GeoEvent.
        fn generate_geo_event(self: *@This()) GeoEvent {
            var lat_nano: i64 = undefined;
            var lon_nano: i64 = undefined;

            // Decide whether to use clustered or random coordinates
            if (self.prng.chance(self.options.cluster_probability) and self.hotspots.len > 0) {
                // Clustered: pick a hotspot and add random offset
                const hs = self.hotspots[self.prng.int(usize) % self.hotspots.len];
                // Generate unsigned offset [0, 2*radius] then shift to [-radius, +radius]
                const radius: u64 = @intCast(@as(i64, @intCast(@abs(self.options.hotspot_radius))));
                const lat_off_u = self.prng.range_inclusive(u64, 0, radius * 2);
                const lon_off_u = self.prng.range_inclusive(u64, 0, radius * 2);
                const rad_i64: i64 = @intCast(radius);
                const lat_offset: i64 = @as(i64, @intCast(lat_off_u)) - rad_i64;
                const lon_offset: i64 = @as(i64, @intCast(lon_off_u)) - rad_i64;

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
                const lat_rand = self.prng.range_inclusive(u64, 0, 180_000_000_000);
                const lon_rand = self.prng.range_inclusive(u64, 0, 360_000_000_000);
                lat_nano = @as(i64, @intCast(lat_rand)) - 90_000_000_000;
                lon_nano = @as(i64, @intCast(lon_rand)) - 180_000_000_000;
            }

            // Altitude: [-11_000_000, +9_000_000] mm (ocean floor to Everest)
            const alt_rand = self.prng.range_inclusive(u32, 0, 20_000_000);
            const altitude_mm: i32 = @as(i32, @intCast(alt_rand)) - 11_000_000;

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
            self: *@This(),
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

        /// Handle pulse operation for TTL expiration (F2.4.8).
        /// Called for pulse operations in commit order.
        pub fn on_pulse(
            self: *@This(),
            operation: StateMachine.Operation,
            timestamp: u64,
        ) void {
            _ = self;
            _ = operation;
            _ = timestamp;

            // GeoEvent TTL expiration is handled by the state machine's
            // pulse operation. The workload doesn't need to track this
            // since entity lookups will naturally fail for expired events.
            //
            // In the future, this could be used to:
            // - Remove expired entity_ids from tracked_entities
            // - Update statistics for expired events
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

test "GeoWorkload: adversarial queries (F4.1.3)" {
    const allocator = std.testing.allocator;
    var prng = stdx.PRNG.from_seed(77777);

    const MockStateMachine = struct {
        pub const Operation = archerdb.Operation;
    };

    // Configure for 100% adversarial queries
    var workload = try GeoWorkloadType(MockStateMachine).init(
        allocator,
        &prng,
        .{
            .requests_target = 100,
            .write_probability = .{ .numerator = 0, .denominator = 100 }, // All queries
            .adversarial_probability = .{ .numerator = 100, .denominator = 100 }, // All adversarial
        },
    );
    defer workload.deinit(allocator);

    var body: [8192]u8 align(@alignOf(vsr.Header)) = undefined;

    // Generate adversarial queries
    for (0..30) |_| {
        const result = workload.build_request(0, &body);
        try std.testing.expect(result.size > 0);
        try std.testing.expect(result.size <= body.len);
        // Should be either radius or polygon query
        const is_radius = result.operation == .query_radius;
        const is_polygon = result.operation == .query_polygon;
        try std.testing.expect(is_radius or is_polygon);
    }

    // Verify adversarial stats were tracked
    try std.testing.expect(workload.stats.adversarial_queries > 0);
    // Should have various boundary types
    const total_boundary = workload.stats.pole_queries +
        workload.stats.antimeridian_queries +
        workload.stats.boundary_queries;
    try std.testing.expect(total_boundary > 0);
}
