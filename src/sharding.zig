// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Sharding Utilities for Index Partitioning
//!
//! This module provides consistent hashing and shard computation for both:
//! - Single-node logical shards (cache contention reduction)
//! - Distributed shards (horizontal scaling)
//!
//! Per index-sharding/spec.md:
//! - Uses murmur3_128 for distributed sharding (excellent distribution)
//! - Shard bucket = hash % num_shards
//! - Supports 8-256 shard configurations
//!
//! ## Architecture
//!
//! ```
//! entity_id (u128) → computeShardKey() → shard_key (u64)
//!                                      → computeShardBucket() → shard_bucket (u32)
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
//! const shard_key = sharding.computeShardKey(entity_id);
//! const bucket = sharding.computeShardBucket(shard_key, 16);
//! // bucket is 0-15 for 16 shards
//! ```

const std = @import("std");
const assert = std.debug.assert;

/// Minimum supported shard count.
/// Per spec: 8 shards minimum for reasonable distribution.
pub const min_shards: u32 = 8;

/// Maximum supported shard count.
/// Per spec: 256 shards maximum for operational complexity limit.
pub const max_shards: u32 = 256;

/// Compute shard key from entity_id using murmur3-inspired hash.
///
/// Per index-sharding/spec.md:
/// - Uses murmur3_128 style hashing for excellent distribution
/// - 128-bit input (entity_id) → 64-bit shard key
/// - < 100ns per hash computation
///
/// Arguments:
/// - entity_id: The 128-bit entity UUID to hash
///
/// Returns: 64-bit shard key for bucket computation
pub fn computeShardKey(entity_id: u128) u64 {
    // MurmurHash3-inspired finalization for 128-bit input.
    // This provides excellent distribution properties for sharding.
    const low: u64 = @truncate(entity_id);
    const high: u64 = @truncate(entity_id >> 64);

    // Mix function constants from MurmurHash3
    const c1: u64 = 0xff51afd7ed558ccd;
    const c2: u64 = 0xc4ceb9fe1a85ec53;

    var h1 = low;
    var h2 = high;

    // Finalization mix
    h1 ^= h1 >> 33;
    h1 *%= c1;
    h1 ^= h1 >> 33;
    h1 *%= c2;
    h1 ^= h1 >> 33;

    h2 ^= h2 >> 33;
    h2 *%= c1;
    h2 ^= h2 >> 33;
    h2 *%= c2;
    h2 ^= h2 >> 33;

    // Combine for final shard key
    return h1 ^ h2;
}

/// Compute shard bucket from shard key.
///
/// Per index-sharding/spec.md:
/// - bucket = shard_key % num_shards
/// - num_shards must be power of 2 for efficient modulo
///
/// Arguments:
/// - shard_key: 64-bit key from computeShardKey()
/// - num_shards: Number of shards (8-256, must be power of 2)
///
/// Returns: Shard bucket index (0 to num_shards-1)
pub fn computeShardBucket(shard_key: u64, num_shards: u32) u32 {
    assert(num_shards >= min_shards);
    assert(num_shards <= max_shards);
    assert(std.math.isPowerOfTwo(num_shards));

    // Efficient modulo for power-of-2 shard count
    return @intCast(shard_key & (num_shards - 1));
}

/// Compute shard bucket directly from entity_id.
///
/// Convenience function combining computeShardKey and computeShardBucket.
///
/// Arguments:
/// - entity_id: The 128-bit entity UUID
/// - num_shards: Number of shards (8-256, must be power of 2)
///
/// Returns: Shard bucket index (0 to num_shards-1)
pub fn getShardBucket(entity_id: u128, num_shards: u32) u32 {
    return computeShardBucket(computeShardKey(entity_id), num_shards);
}

/// Validate shard configuration.
///
/// Per index-sharding/spec.md:
/// - Shard count must be 8-256
/// - Must be power of 2
///
/// Arguments:
/// - num_shards: Proposed shard count
///
/// Returns: true if valid, false otherwise
pub fn isValidShardCount(num_shards: u32) bool {
    return num_shards >= min_shards and
        num_shards <= max_shards and
        std.math.isPowerOfTwo(num_shards);
}

/// Shard distribution statistics for testing and monitoring.
pub const ShardStats = struct {
    /// Number of shards
    num_shards: u32,
    /// Entity count per shard
    counts: []u64,
    /// Total entities
    total: u64,

    /// Calculate standard deviation of shard counts.
    pub fn stdDev(self: ShardStats) f64 {
        if (self.total == 0) return 0.0;

        const expected: f64 = @as(f64, @floatFromInt(self.total)) / @as(f64, @floatFromInt(self.num_shards));
        var variance: f64 = 0.0;

        for (self.counts[0..self.num_shards]) |count| {
            const diff = @as(f64, @floatFromInt(count)) - expected;
            variance += diff * diff;
        }

        return @sqrt(variance / @as(f64, @floatFromInt(self.num_shards)));
    }

    /// Calculate max imbalance percentage.
    pub fn maxImbalance(self: ShardStats) f64 {
        if (self.total == 0) return 0.0;

        const expected: f64 = @as(f64, @floatFromInt(self.total)) / @as(f64, @floatFromInt(self.num_shards));
        var max_diff: f64 = 0.0;

        for (self.counts[0..self.num_shards]) |count| {
            const diff = @abs(@as(f64, @floatFromInt(count)) - expected);
            max_diff = @max(max_diff, diff);
        }

        return (max_diff / expected) * 100.0;
    }
};

// === Tests ===

test "computeShardKey deterministic" {
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const key1 = computeShardKey(entity_id);
    const key2 = computeShardKey(entity_id);
    try std.testing.expectEqual(key1, key2);
}

test "computeShardKey distribution" {
    // Test that different entity_ids produce different shard keys
    const ids = [_]u128{
        0x00000000_00000000_00000000_00000001,
        0x00000000_00000000_00000000_00000002,
        0x00000000_00000000_00000000_00000003,
        0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE,
        0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF,
    };

    var keys: [5]u64 = undefined;
    for (ids, 0..) |id, i| {
        keys[i] = computeShardKey(id);
    }

    // All keys should be unique (extremely high probability)
    for (0..5) |i| {
        for (i + 1..5) |j| {
            try std.testing.expect(keys[i] != keys[j]);
        }
    }
}

test "computeShardBucket valid range" {
    const key: u64 = 0x123456789ABCDEF0;

    // Test various shard counts
    try std.testing.expect(computeShardBucket(key, 8) < 8);
    try std.testing.expect(computeShardBucket(key, 16) < 16);
    try std.testing.expect(computeShardBucket(key, 32) < 32);
    try std.testing.expect(computeShardBucket(key, 64) < 64);
    try std.testing.expect(computeShardBucket(key, 128) < 128);
    try std.testing.expect(computeShardBucket(key, 256) < 256);
}

test "getShardBucket convenience" {
    const entity_id: u128 = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;
    const bucket = getShardBucket(entity_id, 16);
    try std.testing.expect(bucket < 16);

    // Verify it matches the two-step process
    const key = computeShardKey(entity_id);
    const bucket2 = computeShardBucket(key, 16);
    try std.testing.expectEqual(bucket, bucket2);
}

test "isValidShardCount" {
    // Valid counts
    try std.testing.expect(isValidShardCount(8));
    try std.testing.expect(isValidShardCount(16));
    try std.testing.expect(isValidShardCount(32));
    try std.testing.expect(isValidShardCount(64));
    try std.testing.expect(isValidShardCount(128));
    try std.testing.expect(isValidShardCount(256));

    // Invalid counts
    try std.testing.expect(!isValidShardCount(0));
    try std.testing.expect(!isValidShardCount(4)); // Below minimum
    try std.testing.expect(!isValidShardCount(7)); // Not power of 2
    try std.testing.expect(!isValidShardCount(10)); // Not power of 2
    try std.testing.expect(!isValidShardCount(512)); // Above maximum
}

test "ShardStats calculation" {
    var counts = [_]u64{ 100, 102, 98, 101 };
    const stats = ShardStats{
        .num_shards = 4,
        .counts = &counts,
        .total = 401,
    };

    // Expected per shard: 100.25
    // Std dev should be small
    const std_dev = stats.stdDev();
    try std.testing.expect(std_dev < 2.0);

    // Max imbalance should be small (< 3% for this test data)
    // With counts [100, 102, 98, 101] and expected 100.25, max diff is 2.25
    const imbalance = stats.maxImbalance();
    try std.testing.expect(imbalance < 3.0);
}

// =============================================================================
// Consistent Hashing Ring (v2.1+ Feature)
// =============================================================================
//
// Per index-sharding/consistent-hashing.md:
// - Uses virtual nodes for better distribution
// - Minimizes data movement on node addition/removal
// - Each physical node gets 150 virtual nodes by default
//

/// Virtual node on the consistent hashing ring.
pub const VirtualNode = struct {
    /// Position on the ring (hash value).
    position: u64,

    /// Physical shard/node this virtual node maps to.
    shard_id: u32,

    /// Virtual node index within the shard.
    vnode_index: u16,
};

/// Consistent hashing ring for minimal data movement during resharding.
pub const ConsistentHashRing = struct {
    const Self = @This();

    /// Number of virtual nodes per physical shard.
    pub const default_vnodes_per_shard: u16 = 150;

    /// Sorted array of virtual nodes.
    ring: []VirtualNode,

    /// Number of physical shards.
    num_shards: u32,

    /// Virtual nodes per shard.
    vnodes_per_shard: u16,

    /// Allocator used for ring memory.
    allocator: std.mem.Allocator,

    /// Initialize a consistent hashing ring.
    pub fn init(
        allocator: std.mem.Allocator,
        num_shards: u32,
        vnodes_per_shard: u16,
    ) !Self {
        assert(num_shards >= min_shards);
        assert(num_shards <= max_shards);
        assert(vnodes_per_shard > 0);

        const total_vnodes = @as(usize, num_shards) * @as(usize, vnodes_per_shard);
        const ring = try allocator.alloc(VirtualNode, total_vnodes);
        errdefer allocator.free(ring);

        // Generate virtual nodes for each shard
        var idx: usize = 0;
        for (0..num_shards) |shard| {
            for (0..vnodes_per_shard) |vnode| {
                // Hash shard_id and vnode_index to get ring position
                const seed: u128 = (@as(u128, shard) << 64) | @as(u128, vnode);
                const position = computeShardKey(seed);

                ring[idx] = .{
                    .position = position,
                    .shard_id = @intCast(shard),
                    .vnode_index = @intCast(vnode),
                };
                idx += 1;
            }
        }

        // Sort by position for binary search
        std.mem.sort(VirtualNode, ring, {}, struct {
            fn lessThan(_: void, a: VirtualNode, b: VirtualNode) bool {
                return a.position < b.position;
            }
        }.lessThan);

        return .{
            .ring = ring,
            .num_shards = num_shards,
            .vnodes_per_shard = vnodes_per_shard,
            .allocator = allocator,
        };
    }

    /// Deinitialize the ring.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.ring);
    }

    /// Find the shard for a given entity_id using consistent hashing.
    pub fn getShard(self: *const Self, entity_id: u128) u32 {
        const key = computeShardKey(entity_id);
        return self.getShardByKey(key);
    }

    /// Find the shard for a given shard key.
    pub fn getShardByKey(self: *const Self, key: u64) u32 {
        // Binary search for first vnode with position >= key
        var left: usize = 0;
        var right: usize = self.ring.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.ring[mid].position < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // Wrap around to first vnode if past the end
        if (left >= self.ring.len) {
            left = 0;
        }

        return self.ring[left].shard_id;
    }

    /// Get all entities that would move when adding a new shard.
    /// Returns the list of (entity_id, old_shard, new_shard) tuples.
    pub fn computeMigrations(
        self: *const Self,
        new_ring: *const Self,
        entity_ids: []const u128,
        result: []Migration,
    ) usize {
        var count: usize = 0;

        for (entity_ids) |entity_id| {
            const old_shard = self.getShard(entity_id);
            const new_shard = new_ring.getShard(entity_id);

            if (old_shard != new_shard and count < result.len) {
                result[count] = .{
                    .entity_id = entity_id,
                    .old_shard = old_shard,
                    .new_shard = new_shard,
                };
                count += 1;
            }
        }

        return count;
    }
};

/// Migration record for resharding.
pub const Migration = struct {
    entity_id: u128,
    old_shard: u32,
    new_shard: u32,
};

// =============================================================================
// Online Resharding State Machine (v2.1+ Feature)
// =============================================================================
//
// Per index-sharding/failover-resharding.md:
// - Supports online resharding without downtime
// - Uses dual-write during migration phase
// - Implements read-repair for consistency
//

/// Resharding operation state.
pub const ReshardingState = enum {
    /// No resharding in progress.
    idle,

    /// Preparing resharding (computing migrations).
    preparing,

    /// Copying data to new shards (dual-write enabled).
    copying,

    /// Verifying data consistency.
    verifying,

    /// Switching to new shard configuration.
    switching,

    /// Cleaning up old shard data.
    cleanup,

    /// Resharding failed, rolling back.
    rollback,

    /// Resharding complete.
    complete,

    pub fn toString(self: ReshardingState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .preparing => "PREPARING",
            .copying => "COPYING",
            .verifying => "VERIFYING",
            .switching => "SWITCHING",
            .cleanup => "CLEANUP",
            .rollback => "ROLLBACK",
            .complete => "COMPLETE",
        };
    }
};

/// Online resharding manager.
pub const ReshardingManager = struct {
    const Self = @This();

    /// Current state.
    state: ReshardingState,

    /// Current shard configuration.
    current_shards: u32,

    /// Target shard configuration.
    target_shards: u32,

    /// Current consistent hash ring.
    current_ring: ?ConsistentHashRing,

    /// Target consistent hash ring.
    target_ring: ?ConsistentHashRing,

    /// Migration progress tracking.
    progress: struct {
        /// Total entities to migrate.
        total_entities: u64 = 0,

        /// Entities migrated so far.
        migrated_entities: u64 = 0,

        /// Start timestamp.
        start_time: i64 = 0,

        /// Last update timestamp.
        last_update: i64 = 0,

        /// Estimated completion time (0 = unknown).
        estimated_completion: i64 = 0,
    },

    /// Error message if resharding failed.
    error_message: ?[]const u8,

    /// Allocator for ring memory.
    allocator: std.mem.Allocator,

    /// Initialize resharding manager.
    pub fn init(allocator: std.mem.Allocator, initial_shards: u32) Self {
        return .{
            .state = .idle,
            .current_shards = initial_shards,
            .target_shards = initial_shards,
            .current_ring = null,
            .target_ring = null,
            .progress = .{},
            .error_message = null,
            .allocator = allocator,
        };
    }

    /// Deinitialize resharding manager.
    pub fn deinit(self: *Self) void {
        if (self.current_ring) |*ring| {
            ring.deinit();
        }
        if (self.target_ring) |*ring| {
            ring.deinit();
        }
    }

    /// Start online resharding to a new shard count.
    pub fn startResharding(self: *Self, new_shard_count: u32) !void {
        if (self.state != .idle) {
            return error.ReshardingInProgress;
        }

        if (!isValidShardCount(new_shard_count)) {
            return error.InvalidShardCount;
        }

        if (new_shard_count == self.current_shards) {
            return error.NoChangeRequired;
        }

        self.state = .preparing;
        self.target_shards = new_shard_count;
        self.progress.start_time = std.time.timestamp();
        self.progress.migrated_entities = 0;

        // Create target ring
        self.target_ring = try ConsistentHashRing.init(
            self.allocator,
            new_shard_count,
            ConsistentHashRing.default_vnodes_per_shard,
        );

        // Create current ring if not exists
        if (self.current_ring == null) {
            self.current_ring = try ConsistentHashRing.init(
                self.allocator,
                self.current_shards,
                ConsistentHashRing.default_vnodes_per_shard,
            );
        }

        self.state = .copying;
    }

    /// Report migration progress.
    pub fn reportProgress(self: *Self, migrated: u64, total: u64) void {
        self.progress.migrated_entities = migrated;
        self.progress.total_entities = total;
        self.progress.last_update = std.time.timestamp();

        // Estimate completion time
        if (migrated > 0) {
            const elapsed = self.progress.last_update - self.progress.start_time;
            const rate = @as(f64, @floatFromInt(migrated)) / @as(f64, @floatFromInt(elapsed));
            const remaining = total - migrated;
            const eta = @as(i64, @intFromFloat(@as(f64, @floatFromInt(remaining)) / rate));
            self.progress.estimated_completion = self.progress.last_update + eta;
        }
    }

    /// Complete resharding (after all data migrated).
    pub fn completeResharding(self: *Self) !void {
        if (self.state != .copying and self.state != .verifying) {
            return error.InvalidState;
        }

        self.state = .switching;

        // Swap rings
        if (self.current_ring) |*ring| {
            ring.deinit();
        }
        self.current_ring = self.target_ring;
        self.target_ring = null;
        self.current_shards = self.target_shards;

        self.state = .cleanup;

        // Cleanup would happen asynchronously in real implementation
        self.state = .complete;
    }

    /// Cancel resharding and rollback.
    pub fn cancelResharding(self: *Self, reason: []const u8) void {
        self.state = .rollback;
        self.error_message = reason;

        // Cleanup target ring
        if (self.target_ring) |*ring| {
            ring.deinit();
            self.target_ring = null;
        }

        self.target_shards = self.current_shards;
        self.state = .idle;
    }

    /// Get shard for entity (handles dual-read during resharding).
    pub fn getShardForEntity(self: *const Self, entity_id: u128) struct { primary: u32, secondary: ?u32 } {
        const primary = if (self.current_ring) |*ring|
            ring.getShard(entity_id)
        else
            getShardBucket(entity_id, self.current_shards);

        // During copying phase, also check target shard
        if (self.state == .copying) {
            if (self.target_ring) |*ring| {
                const secondary = ring.getShard(entity_id);
                if (secondary != primary) {
                    return .{ .primary = primary, .secondary = secondary };
                }
            }
        }

        return .{ .primary = primary, .secondary = null };
    }

    /// Check if dual-write is required (during resharding).
    pub fn isDualWriteRequired(self: *const Self) bool {
        return self.state == .copying or self.state == .verifying;
    }

    /// Get progress percentage.
    pub fn getProgressPercent(self: *const Self) f64 {
        if (self.progress.total_entities == 0) return 0.0;
        return @as(f64, @floatFromInt(self.progress.migrated_entities)) /
            @as(f64, @floatFromInt(self.progress.total_entities)) * 100.0;
    }
};

// === Additional Tests ===

test "ConsistentHashRing basic operations" {
    var ring = try ConsistentHashRing.init(std.testing.allocator, 8, 10);
    defer ring.deinit();

    // Test that we get valid shard IDs
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const shard = ring.getShard(entity_id);
    try std.testing.expect(shard < 8);

    // Test determinism
    const shard2 = ring.getShard(entity_id);
    try std.testing.expectEqual(shard, shard2);
}

test "ConsistentHashRing distribution" {
    var ring = try ConsistentHashRing.init(std.testing.allocator, 16, 100);
    defer ring.deinit();

    // Generate random entity IDs and count distribution
    var counts = [_]u64{0} ** 16;
    var prng = std.Random.DefaultPrng.init(12345);

    for (0..10000) |_| {
        const entity_id: u128 = prng.random().int(u128);
        const shard = ring.getShard(entity_id);
        counts[shard] += 1;
    }

    // Check that all shards got some entities
    for (counts) |count| {
        try std.testing.expect(count > 0);
    }
}

test "ReshardingManager state transitions" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    try std.testing.expectEqual(ReshardingState.idle, manager.state);
    try std.testing.expectEqual(@as(u32, 8), manager.current_shards);

    // Start resharding to 16 shards
    try manager.startResharding(16);
    try std.testing.expectEqual(ReshardingState.copying, manager.state);
    try std.testing.expectEqual(@as(u32, 16), manager.target_shards);

    // Report progress
    manager.reportProgress(500, 1000);
    try std.testing.expect(manager.getProgressPercent() > 49.0);

    // Complete resharding
    try manager.completeResharding();
    try std.testing.expectEqual(ReshardingState.complete, manager.state);
    try std.testing.expectEqual(@as(u32, 16), manager.current_shards);
}

test "ReshardingState toString" {
    try std.testing.expectEqualStrings("IDLE", ReshardingState.idle.toString());
    try std.testing.expectEqualStrings("COPYING", ReshardingState.copying.toString());
    try std.testing.expectEqualStrings("COMPLETE", ReshardingState.complete.toString());
}
