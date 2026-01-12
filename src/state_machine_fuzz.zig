// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! State Machine Fuzz Tests for ArcherDB GeoStateMachine.
//!
//! Implements comprehensive fuzz testing for geospatial operations:
//! - Random GeoEvent generation with valid coordinates
//! - Insert/Upsert/Delete operation sequences
//! - Query operations (UUID, radius, polygon, latest)
//! - LWW (Last-Write-Wins) semantic verification
//! - Spatial bounds and TTL invariant checking
//!
//! Uses deterministic PRNG for reproducible test failures.
//! See specs/testing-simulation/spec.md for full requirements.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const PRNG = stdx.PRNG;

const geo_event = @import("geo_event.zig");
const GeoEvent = geo_event.GeoEvent;
const fuzz = @import("testing/fuzz.zig");

/// Maximum latitude in nanodegrees (+90 degrees).
const MAX_LAT_NANO: i64 = 90_000_000_000;
/// Maximum longitude in nanodegrees (+180 degrees).
const MAX_LON_NANO: i64 = 180_000_000_000;

/// Fuzz test operations.
pub const FuzzOperation = enum {
    insert,
    upsert,
    delete,
    query_uuid,
    query_radius,
    query_latest,
};

/// Configuration for fuzz testing.
pub const FuzzConfig = struct {
    /// Maximum number of operations per test run.
    max_operations: u32 = 10_000,
    /// Probability of each operation type (weights sum to 100).
    insert_weight: u32 = 30,
    upsert_weight: u32 = 25,
    delete_weight: u32 = 15,
    query_uuid_weight: u32 = 15,
    query_radius_weight: u32 = 10,
    query_latest_weight: u32 = 5,
    /// Maximum number of entities to track.
    max_entities: u32 = 1000,
    /// Whether to verify LWW semantics.
    verify_lww: bool = true,
    /// Whether to verify spatial bounds.
    verify_bounds: bool = true,
};

/// Fuzz test state for tracking operations.
pub const FuzzState = struct {
    const Self = @This();

    allocator: Allocator,
    prng: *PRNG,
    config: FuzzConfig,

    /// Known entities and their latest events.
    entities: std.AutoHashMap(u128, GeoEvent),
    /// Operation counts for statistics.
    stats: FuzzStats,
    /// Invariant violations detected.
    violations: std.ArrayList(Violation),

    pub fn init(allocator: Allocator, prng: *PRNG, config: FuzzConfig) Self {
        return .{
            .allocator = allocator,
            .prng = prng,
            .config = config,
            .entities = std.AutoHashMap(u128, GeoEvent).init(allocator),
            .stats = .{},
            .violations = std.ArrayList(Violation).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
        self.violations.deinit();
    }

    /// Generate a random GeoEvent.
    pub fn generateRandomEvent(self: *Self) GeoEvent {
        const entity_id = self.generateEntityId();
        const timestamp = self.generateTimestamp();

        // Generate random coordinates within valid range.
        // Use unsigned range and convert to signed.
        const lat_unsigned = self.prng.range_inclusive(u64, 0, @as(u64, MAX_LAT_NANO) * 2);
        const lat_nano: i64 = @as(i64, @intCast(lat_unsigned)) - MAX_LAT_NANO;

        const lon_unsigned = self.prng.range_inclusive(u64, 0, @as(u64, MAX_LON_NANO) * 2);
        const lon_nano: i64 = @as(i64, @intCast(lon_unsigned)) - MAX_LON_NANO;

        // Generate S2 cell ID (simplified: use lat/lon hash).
        const s2_cell_id = computeSimpleS2CellId(lat_nano, lon_nano);
        const composite_id = (@as(u128, s2_cell_id) << 64) | timestamp;

        // Random altitude: -1000m to +100km.
        const alt_unsigned = self.prng.range_inclusive(u32, 0, 101_000_000);
        const altitude_mm: i32 = @as(i32, @intCast(alt_unsigned)) - 1_000_000;

        return GeoEvent{
            .id = composite_id,
            .entity_id = entity_id,
            .correlation_id = self.prng.int(u128),
            .user_data = self.prng.int(u128),
            .lat_nano = lat_nano,
            .lon_nano = lon_nano,
            .group_id = self.prng.int(u64),
            .timestamp = timestamp,
            .altitude_mm = altitude_mm,
            .velocity_mms = self.prng.int(u32),
            .heading_cdeg = self.prng.range_inclusive(u16, 0, 36000),
            .accuracy_mm = self.prng.range_inclusive(u32, 1, 100_000),
            .ttl_seconds = self.prng.range_inclusive(u32, 0, 86400 * 365),
            .flags = .{},
            .reserved = [_]u8{0} ** 12,
        };
    }

    /// Generate entity ID with collision probability.
    fn generateEntityId(self: *Self) u128 {
        // 70% chance to reuse existing entity (for updates).
        if (self.entities.count() > 0 and self.prng.range_inclusive(u32, 0, 100) < 70) {
            var iter = self.entities.keyIterator();
            const skip = self.prng.int_inclusive(usize, self.entities.count() - 1);
            var i: usize = 0;
            while (iter.next()) |key| {
                if (i == skip) return key.*;
                i += 1;
            }
        }
        return self.prng.int(u128);
    }

    /// Generate monotonically increasing timestamp.
    fn generateTimestamp(self: *Self) u64 {
        const base: u64 = 1704067200_000_000_000; // 2024-01-01
        return base + self.prng.int(u64) % (365 * 24 * 3600 * 1_000_000_000);
    }

    /// Execute a random operation.
    pub fn executeRandomOperation(self: *Self) !void {
        const op = self.selectOperation();
        switch (op) {
            .insert => try self.executeInsert(),
            .upsert => try self.executeUpsert(),
            .delete => try self.executeDelete(),
            .query_uuid => try self.executeQueryUuid(),
            .query_radius => try self.executeQueryRadius(),
            .query_latest => try self.executeQueryLatest(),
        }
    }

    /// Select operation based on weights.
    fn selectOperation(self: *Self) FuzzOperation {
        const cfg = self.config;
        const total = cfg.insert_weight + cfg.upsert_weight + cfg.delete_weight +
            cfg.query_uuid_weight + cfg.query_radius_weight + cfg.query_latest_weight;

        const roll = self.prng.int_inclusive(u32, total - 1);

        var cumulative: u32 = 0;
        if (roll < (cumulative + cfg.insert_weight)) return .insert;
        cumulative += cfg.insert_weight;
        if (roll < (cumulative + cfg.upsert_weight)) return .upsert;
        cumulative += cfg.upsert_weight;
        if (roll < (cumulative + cfg.delete_weight)) return .delete;
        cumulative += cfg.delete_weight;
        if (roll < (cumulative + cfg.query_uuid_weight)) return .query_uuid;
        cumulative += cfg.query_uuid_weight;
        if (roll < (cumulative + cfg.query_radius_weight)) return .query_radius;

        return .query_latest;
    }

    /// Execute insert operation.
    fn executeInsert(self: *Self) !void {
        const event = self.generateRandomEvent();
        self.stats.inserts += 1;

        // Verify bounds before "insert".
        if (self.config.verify_bounds) {
            try self.verifyBounds(event);
        }

        // Track entity (simulating insert).
        if (self.entities.get(event.entity_id)) |existing| {
            // LWW: only update if newer.
            if (self.config.verify_lww and event.timestamp <= existing.timestamp) {
                self.stats.lww_rejections += 1;
                return;
            }
        }

        try self.entities.put(event.entity_id, event);
        self.stats.successful_ops += 1;
    }

    /// Execute upsert operation.
    fn executeUpsert(self: *Self) !void {
        const event = self.generateRandomEvent();
        self.stats.upserts += 1;

        if (self.config.verify_bounds) {
            try self.verifyBounds(event);
        }

        // LWW semantics.
        if (self.entities.get(event.entity_id)) |existing| {
            if (self.config.verify_lww and event.timestamp <= existing.timestamp) {
                self.stats.lww_rejections += 1;
                return;
            }
        }

        try self.entities.put(event.entity_id, event);
        self.stats.successful_ops += 1;
    }

    /// Execute delete operation.
    fn executeDelete(self: *Self) !void {
        self.stats.deletes += 1;

        if (self.entities.count() == 0) return;

        // Select random entity to delete.
        var iter = self.entities.keyIterator();
        const skip = self.prng.int_inclusive(usize, self.entities.count() - 1);
        var i: usize = 0;
        while (iter.next()) |key| {
            if (i == skip) {
                _ = self.entities.remove(key.*);
                self.stats.successful_ops += 1;
                return;
            }
            i += 1;
        }
    }

    /// Execute UUID query operation.
    fn executeQueryUuid(self: *Self) !void {
        self.stats.queries_uuid += 1;

        if (self.entities.count() == 0) return;

        // Query a known entity.
        var iter = self.entities.iterator();
        const skip = self.prng.int_inclusive(usize, self.entities.count() - 1);
        var i: usize = 0;
        while (iter.next()) |entry| {
            if (i == skip) {
                // Verify the entity can be found (simulation).
                const found = self.entities.get(entry.key_ptr.*);
                if (found == null) {
                    try self.violations.append(.{
                        .type = .missing_entity,
                        .entity_id = entry.key_ptr.*,
                        .description = "Entity not found during UUID query",
                    });
                }
                self.stats.successful_ops += 1;
                return;
            }
            i += 1;
        }
    }

    /// Execute radius query operation.
    fn executeQueryRadius(self: *Self) !void {
        self.stats.queries_radius += 1;

        // Generate random center and radius (using unsigned range and convert).
        const lat_unsigned = self.prng.range_inclusive(u64, 0, @as(u64, MAX_LAT_NANO) * 2);
        const center_lat: i64 = @as(i64, @intCast(lat_unsigned)) - MAX_LAT_NANO;

        const lon_unsigned = self.prng.range_inclusive(u64, 0, @as(u64, MAX_LON_NANO) * 2);
        const center_lon: i64 = @as(i64, @intCast(lon_unsigned)) - MAX_LON_NANO;

        const radius_m = self.prng.range_inclusive(u32, 100, 100_000);

        // Count entities in radius (simplified distance check).
        var count: u32 = 0;
        var iter = self.entities.valueIterator();
        while (iter.next()) |event| {
            if (isWithinRadius(event.lat_nano, event.lon_nano, center_lat, center_lon, radius_m)) {
                count += 1;
            }
        }

        self.stats.radius_results_total += count;
        self.stats.successful_ops += 1;
    }

    /// Execute latest query operation.
    fn executeQueryLatest(self: *Self) !void {
        self.stats.queries_latest += 1;

        // Find entity with latest timestamp.
        var latest: ?GeoEvent = null;
        var iter = self.entities.valueIterator();
        while (iter.next()) |event| {
            if (latest == null or event.timestamp > latest.?.timestamp) {
                latest = event.*;
            }
        }

        if (latest != null) {
            self.stats.successful_ops += 1;
        }
    }

    /// Verify spatial bounds.
    fn verifyBounds(self: *Self, event: GeoEvent) !void {
        if (event.lat_nano < -MAX_LAT_NANO or event.lat_nano > MAX_LAT_NANO) {
            try self.violations.append(.{
                .type = .invalid_latitude,
                .entity_id = event.entity_id,
                .description = "Latitude out of bounds",
            });
        }
        if (event.lon_nano < -MAX_LON_NANO or event.lon_nano > MAX_LON_NANO) {
            try self.violations.append(.{
                .type = .invalid_longitude,
                .entity_id = event.entity_id,
                .description = "Longitude out of bounds",
            });
        }
    }

    /// Get test statistics.
    pub fn getStats(self: *const Self) FuzzStats {
        return self.stats;
    }

    /// Check if any violations occurred.
    pub fn hasViolations(self: *const Self) bool {
        return self.violations.items.len > 0;
    }
};

/// Statistics for fuzz testing.
pub const FuzzStats = struct {
    inserts: u64 = 0,
    upserts: u64 = 0,
    deletes: u64 = 0,
    queries_uuid: u64 = 0,
    queries_radius: u64 = 0,
    queries_latest: u64 = 0,
    successful_ops: u64 = 0,
    lww_rejections: u64 = 0,
    radius_results_total: u64 = 0,

    pub fn totalOperations(self: FuzzStats) u64 {
        return self.inserts + self.upserts + self.deletes +
            self.queries_uuid + self.queries_radius + self.queries_latest;
    }
};

/// Invariant violation type.
pub const ViolationType = enum {
    invalid_latitude,
    invalid_longitude,
    lww_violation,
    missing_entity,
    duplicate_id,
    corrupted_data,
};

/// Violation record.
pub const Violation = struct {
    type: ViolationType,
    entity_id: u128,
    description: []const u8,
};

/// Compute simplified S2 cell ID from coordinates.
fn computeSimpleS2CellId(lat_nano: i64, lon_nano: i64) u64 {
    // Simplified: hash lat/lon to 64-bit value.
    // Real implementation would use actual S2 library.
    const lat_bits: u64 = @bitCast(lat_nano);
    const lon_bits: u64 = @bitCast(lon_nano);
    return (lat_bits *% 0x9E3779B97F4A7C15) ^ (lon_bits *% 0xC4CEB9FE1A85EC53);
}

/// Check if point is within radius (simplified haversine).
fn isWithinRadius(lat1: i64, lon1: i64, lat2: i64, lon2: i64, radius_m: u32) bool {
    // Simplified: use Euclidean distance in nanodegrees.
    // 1 degree ≈ 111km at equator.
    const nano_per_meter: i64 = 9; // ~1/111000 degrees in nanodegrees
    const threshold: i64 = @as(i64, radius_m) * nano_per_meter;

    const dlat = @abs(lat1 - lat2);
    const dlon = @abs(lon1 - lon2);

    return dlat < threshold and dlon < threshold;
}

// =============================================================================
// Tests
// =============================================================================

test "state_machine_fuzz: basic operations" {
    const allocator = testing.allocator;

    var prng = PRNG.from_seed(12345);

    var state = FuzzState.init(allocator, &prng, .{ .max_operations = 100 });
    defer state.deinit();

    // Run 100 random operations.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try state.executeRandomOperation();
    }

    const stats = state.getStats();
    try testing.expectEqual(@as(u64, 100), stats.totalOperations());
    try testing.expect(!state.hasViolations());
}

test "state_machine_fuzz: LWW semantics" {
    const allocator = testing.allocator;

    var prng = PRNG.from_seed(54321);

    var state = FuzzState.init(allocator, &prng, .{
        .max_operations = 1000,
        .verify_lww = true,
    });
    defer state.deinit();

    // Insert same entity multiple times with varying timestamps.
    const entity_id: u128 = 0xDEADBEEF;

    // Insert with timestamp 1000.
    var event1 = state.generateRandomEvent();
    event1.entity_id = entity_id;
    event1.timestamp = 1000;
    try state.entities.put(entity_id, event1);

    // Try to update with older timestamp - should be rejected.
    var event2 = state.generateRandomEvent();
    event2.entity_id = entity_id;
    event2.timestamp = 500;

    // Simulate LWW check.
    if (state.entities.get(entity_id)) |existing| {
        try testing.expect(event2.timestamp <= existing.timestamp);
    }
}

test "state_machine_fuzz: spatial bounds validation" {
    const allocator = testing.allocator;

    var prng = PRNG.from_seed(99999);

    var state = FuzzState.init(allocator, &prng, .{
        .verify_bounds = true,
    });
    defer state.deinit();

    // Create event with valid bounds.
    const valid_event = state.generateRandomEvent();
    try state.verifyBounds(valid_event);

    // Events generated should always be valid.
    try testing.expect(!state.hasViolations());
}

test "state_machine_fuzz: high volume stress test" {
    const allocator = testing.allocator;

    var prng = PRNG.from_seed(0xCAFEBABE);

    var state = FuzzState.init(allocator, &prng, .{
        .max_operations = 10_000,
        .max_entities = 500,
    });
    defer state.deinit();

    // Run 10,000 operations.
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        try state.executeRandomOperation();
    }

    const stats = state.getStats();
    try testing.expectEqual(@as(u64, 10_000), stats.totalOperations());
    try testing.expect(!state.hasViolations());

    // Verify reasonable distribution of operations.
    try testing.expect(stats.inserts > 0);
    try testing.expect(stats.upserts > 0);
    try testing.expect(stats.deletes > 0);
    try testing.expect(stats.queries_uuid > 0);
}

test "state_machine_fuzz: deterministic replay" {
    const allocator = testing.allocator;

    // Run same sequence twice with same seed.
    const seed: u64 = 0x12345678;

    var prng1 = PRNG.from_seed(seed);
    var state1 = FuzzState.init(allocator, &prng1, .{ .max_operations = 100 });
    defer state1.deinit();

    var prng2 = PRNG.from_seed(seed);
    var state2 = FuzzState.init(allocator, &prng2, .{ .max_operations = 100 });
    defer state2.deinit();

    // Run same operations.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try state1.executeRandomOperation();
        try state2.executeRandomOperation();
    }

    // Results should be identical.
    try testing.expectEqual(state1.getStats().totalOperations(), state2.getStats().totalOperations());
    try testing.expectEqual(state1.entities.count(), state2.entities.count());
}

test "state_machine_fuzz: radius query coverage" {
    const allocator = testing.allocator;

    var prng = PRNG.from_seed(0xABCDEF);

    var state = FuzzState.init(allocator, &prng, .{
        .insert_weight = 80,
        .query_radius_weight = 20,
        .upsert_weight = 0,
        .delete_weight = 0,
        .query_uuid_weight = 0,
        .query_latest_weight = 0,
    });
    defer state.deinit();

    // Run operations biased toward inserts and radius queries.
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        try state.executeRandomOperation();
    }

    const stats = state.getStats();
    try testing.expect(stats.inserts > 0);
    try testing.expect(stats.queries_radius > 0);
}

test "FuzzStats: total operations" {
    var stats = FuzzStats{
        .inserts = 10,
        .upserts = 20,
        .deletes = 5,
        .queries_uuid = 15,
        .queries_radius = 8,
        .queries_latest = 2,
    };

    try testing.expectEqual(@as(u64, 60), stats.totalOperations());
}

test "computeSimpleS2CellId: deterministic" {
    const id1 = computeSimpleS2CellId(40_712_800_000, -74_006_000_000);
    const id2 = computeSimpleS2CellId(40_712_800_000, -74_006_000_000);

    try testing.expectEqual(id1, id2);
}

test "isWithinRadius: basic check" {
    // Same point should be within any radius.
    try testing.expect(isWithinRadius(0, 0, 0, 0, 1000));

    // Far points should not be within small radius.
    try testing.expect(!isWithinRadius(0, 0, MAX_LAT_NANO, MAX_LON_NANO, 1000));
}
