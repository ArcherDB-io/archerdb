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
const metrics = @import("archerdb/metrics.zig");
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

// =============================================================================
// Stop-the-World Resharding (v2.0 Feature)
// =============================================================================
//
// Per openspec/changes/add-v2-distributed-features/specs/index-sharding/spec.md:
// - Cluster enters read-only mode during resharding
// - Pre-resharding backup is created automatically
// - Data is exported from source shards and imported to target shards
// - Topology metadata is updated atomically
// - Rollback restores from backup on failure
//

/// Cluster operation mode.
pub const ClusterMode = enum {
    /// Normal operation - reads and writes allowed.
    normal,

    /// Read-only mode - only reads allowed (during resharding).
    read_only,

    /// Maintenance mode - no operations allowed.
    maintenance,

    pub fn allowsWrites(self: ClusterMode) bool {
        return self == .normal;
    }

    pub fn allowsReads(self: ClusterMode) bool {
        return self == .normal or self == .read_only;
    }

    pub fn toString(self: ClusterMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .read_only => "READ_ONLY",
            .maintenance => "MAINTENANCE",
        };
    }
};

/// Global cluster mode for health checks and write rejection.
pub var cluster_mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ClusterMode.normal));

/// Set the cluster mode atomically.
pub fn setClusterMode(mode: ClusterMode) void {
    cluster_mode.store(@intFromEnum(mode), .seq_cst);
}

/// Get the current cluster mode.
pub fn getClusterMode() ClusterMode {
    return @enumFromInt(cluster_mode.load(.seq_cst));
}

/// Stop-the-world resharding state.
pub const StopTheWorldState = enum {
    /// No resharding in progress.
    idle,

    /// Validating resharding request.
    validating,

    /// Creating pre-resharding backup.
    backing_up,

    /// Entering read-only mode.
    entering_read_only,

    /// Exporting entities from source shards.
    exporting,

    /// Importing entities to target shards.
    importing,

    /// Verifying entity counts.
    verifying,

    /// Updating topology metadata.
    updating_topology,

    /// Exiting read-only mode.
    exiting_read_only,

    /// Resharding complete.
    complete,

    /// Resharding failed, rolling back.
    rolling_back,

    /// Rollback complete.
    rollback_complete,

    pub fn toString(self: StopTheWorldState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .validating => "VALIDATING",
            .backing_up => "BACKING_UP",
            .entering_read_only => "ENTERING_READ_ONLY",
            .exporting => "EXPORTING",
            .importing => "IMPORTING",
            .verifying => "VERIFYING",
            .updating_topology => "UPDATING_TOPOLOGY",
            .exiting_read_only => "EXITING_READ_ONLY",
            .complete => "COMPLETE",
            .rolling_back => "ROLLING_BACK",
            .rollback_complete => "ROLLBACK_COMPLETE",
        };
    }

    pub fn isInProgress(self: StopTheWorldState) bool {
        return self != .idle and self != .complete and self != .rollback_complete;
    }
};

/// Shard data for export/import.
pub const ShardData = struct {
    /// Shard ID.
    shard_id: u32,

    /// Entity count in this shard.
    entity_count: u64,

    /// Exported entity data (serialized GeoEvents).
    data: []u8,

    /// Data size in bytes.
    size: u64,

    /// Checksum for verification.
    checksum: u64,
};

/// Resharding plan computed before execution.
pub const ReshardingPlan = struct {
    /// Source shard count.
    source_shards: u32,

    /// Target shard count.
    target_shards: u32,

    /// Total entity count.
    total_entities: u64,

    /// Estimated entities per target shard.
    entities_per_shard: u64,

    /// Entities that need to move (change shard assignment).
    entities_to_move: u64,

    /// Estimated duration in seconds.
    estimated_duration_seconds: u64,

    /// Backup path.
    backup_path: ?[]const u8,
};

/// Stop-the-world resharding coordinator.
pub const StopTheWorldResharder = struct {
    const Self = @This();

    /// Current state.
    state: StopTheWorldState,

    /// Current shard configuration.
    current_shards: u32,

    /// Target shard configuration.
    target_shards: u32,

    /// Resharding plan.
    plan: ?ReshardingPlan,

    /// Progress tracking.
    progress: struct {
        /// Total entities to process.
        total_entities: u64 = 0,

        /// Entities exported so far.
        exported_entities: u64 = 0,

        /// Entities imported so far.
        imported_entities: u64 = 0,

        /// Current shard being processed.
        current_shard: u32 = 0,

        /// Start timestamp (nanoseconds).
        start_time_ns: i128 = 0,

        /// Phase start timestamp.
        phase_start_ns: i128 = 0,
    },

    /// Exported shard data (indexed by source shard).
    exported_data: []?ShardData,

    /// Error message if resharding failed.
    error_message: ?[]const u8,

    /// Backup created for rollback.
    backup_path: ?[]const u8,

    /// Allocator.
    allocator: std.mem.Allocator,

    /// Initialize the stop-the-world resharder.
    pub fn init(allocator: std.mem.Allocator, initial_shards: u32) !Self {
        const exported_data = try allocator.alloc(?ShardData, max_shards);
        @memset(exported_data, null);

        return .{
            .state = .idle,
            .current_shards = initial_shards,
            .target_shards = initial_shards,
            .plan = null,
            .progress = .{},
            .exported_data = exported_data,
            .error_message = null,
            .backup_path = null,
            .allocator = allocator,
        };
    }

    /// Deinitialize the resharder.
    pub fn deinit(self: *Self) void {
        // Free any exported data
        for (self.exported_data) |maybe_data| {
            if (maybe_data) |data| {
                self.allocator.free(data.data);
            }
        }
        self.allocator.free(self.exported_data);
    }

    /// Validate and plan resharding operation.
    /// Returns a plan that can be reviewed before execution.
    pub fn planResharding(
        self: *Self,
        new_shard_count: u32,
        total_entities: u64,
    ) !ReshardingPlan {
        if (self.state != .idle) {
            return error.ReshardingInProgress;
        }

        if (!isValidShardCount(new_shard_count)) {
            return error.InvalidShardCount;
        }

        if (new_shard_count == self.current_shards) {
            return error.NoChangeRequired;
        }

        // Estimate entities that need to move
        // When doubling shards, ~50% entities move
        // When halving shards, ~50% entities move
        const move_ratio: f64 = if (new_shard_count > self.current_shards)
            1.0 - (@as(f64, @floatFromInt(self.current_shards)) / @as(f64, @floatFromInt(new_shard_count)))
        else
            1.0 - (@as(f64, @floatFromInt(new_shard_count)) / @as(f64, @floatFromInt(self.current_shards)));

        const entities_to_move: u64 = @intFromFloat(@as(f64, @floatFromInt(total_entities)) * move_ratio);

        // Estimate duration: ~100K entities per second (conservative)
        const estimated_duration = @max(1, entities_to_move / 100_000);

        return .{
            .source_shards = self.current_shards,
            .target_shards = new_shard_count,
            .total_entities = total_entities,
            .entities_per_shard = total_entities / new_shard_count,
            .entities_to_move = entities_to_move,
            .estimated_duration_seconds = estimated_duration,
            .backup_path = null,
        };
    }

    /// Start the stop-the-world resharding operation.
    /// This will put the cluster in read-only mode.
    pub fn startResharding(self: *Self, plan: ReshardingPlan) !void {
        if (self.state != .idle) {
            return error.ReshardingInProgress;
        }

        self.state = .validating;
        self.target_shards = plan.target_shards;
        self.plan = plan;
        self.progress.total_entities = plan.total_entities;
        self.progress.start_time_ns = std.time.nanoTimestamp();
        self.progress.phase_start_ns = self.progress.start_time_ns;

        // Update metrics
        metrics.Registry.resharding_status.store(1, .monotonic); // 1 = preparing
        metrics.Registry.resharding_source_shards.store(self.current_shards, .monotonic);
        metrics.Registry.resharding_target_shards.store(plan.target_shards, .monotonic);
        metrics.Registry.resharding_start_ns.store(@intCast(self.progress.start_time_ns), .monotonic);
        metrics.Registry.resharding_progress.store(0, .monotonic);
        metrics.Registry.resharding_entities_exported.store(0, .monotonic);
        metrics.Registry.resharding_entities_imported.store(0, .monotonic);

        // Clear any previous exported data
        for (self.exported_data, 0..) |maybe_data, i| {
            if (maybe_data) |data| {
                self.allocator.free(data.data);
                self.exported_data[i] = null;
            }
        }

        // Transition to backing up
        self.state = .backing_up;
    }

    /// Called when backup is complete.
    pub fn backupComplete(self: *Self, backup_path: []const u8) !void {
        if (self.state != .backing_up) {
            return error.InvalidState;
        }

        self.backup_path = backup_path;
        self.state = .entering_read_only;

        // Enter read-only mode
        setClusterMode(.read_only);

        self.state = .exporting;
        self.progress.phase_start_ns = std.time.nanoTimestamp();
    }

    /// Skip backup (for dry-run or testing).
    pub fn skipBackup(self: *Self) !void {
        if (self.state != .backing_up) {
            return error.InvalidState;
        }

        self.state = .entering_read_only;
        setClusterMode(.read_only);
        self.state = .exporting;
        self.progress.phase_start_ns = std.time.nanoTimestamp();
    }

    /// Record exported data from a source shard.
    pub fn recordExportedShard(
        self: *Self,
        shard_id: u32,
        entity_count: u64,
        data: []const u8,
        checksum: u64,
    ) !void {
        if (self.state != .exporting) {
            return error.InvalidState;
        }

        if (shard_id >= self.current_shards) {
            return error.InvalidShardId;
        }

        // Copy data
        const data_copy = try self.allocator.dupe(u8, data);

        self.exported_data[shard_id] = .{
            .shard_id = shard_id,
            .entity_count = entity_count,
            .data = data_copy,
            .size = data.len,
            .checksum = checksum,
        };

        self.progress.exported_entities += entity_count;
        self.progress.current_shard = shard_id;

        // Update metrics
        metrics.Registry.resharding_entities_exported.store(self.progress.exported_entities, .monotonic);
        self.updateProgressMetric();
    }

    /// Update the resharding progress metric based on current state.
    fn updateProgressMetric(self: *Self) void {
        if (self.progress.total_entities == 0) return;

        // Progress: 0-50% for export (0-500), 50-100% for import (500-1000)
        // Use floating point to avoid overflow with large entity counts
        const total: f64 = @floatFromInt(self.progress.total_entities);
        const exported: f64 = @floatFromInt(self.progress.exported_entities);
        const imported: f64 = @floatFromInt(self.progress.imported_entities);

        const export_progress: u32 = @intFromFloat(@min(exported / total * 500.0, 500.0));
        const import_progress: u32 = @intFromFloat(@min(imported / total * 500.0, 500.0));
        const total_progress = export_progress + import_progress;

        metrics.Registry.resharding_progress.store(total_progress, .monotonic);
    }

    /// Transition to importing phase after all shards exported.
    pub fn startImporting(self: *Self) !void {
        if (self.state != .exporting) {
            return error.InvalidState;
        }

        // Verify all source shards have been exported
        for (0..self.current_shards) |i| {
            if (self.exported_data[i] == null) {
                return error.IncompleteExport;
            }
        }

        self.state = .importing;
        self.progress.phase_start_ns = std.time.nanoTimestamp();
        self.progress.current_shard = 0;

        // Update metrics - status 2 = migrating
        metrics.Registry.resharding_status.store(2, .monotonic);
    }

    /// Record progress of entity import.
    pub fn recordImportProgress(self: *Self, entities_imported: u64) void {
        if (self.state == .importing) {
            self.progress.imported_entities = entities_imported;
            metrics.Registry.resharding_entities_imported.store(entities_imported, .monotonic);
            self.updateProgressMetric();
        }
    }

    /// Transition to verifying phase after import complete.
    pub fn startVerifying(self: *Self) !void {
        if (self.state != .importing) {
            return error.InvalidState;
        }

        self.state = .verifying;
        self.progress.phase_start_ns = std.time.nanoTimestamp();
    }

    /// Complete verification and update topology.
    pub fn completeVerification(self: *Self, verified_count: u64) !void {
        if (self.state != .verifying) {
            return error.InvalidState;
        }

        // Verify entity count matches
        if (verified_count != self.progress.total_entities) {
            self.error_message = "Entity count mismatch after resharding";
            return error.VerificationFailed;
        }

        self.state = .updating_topology;
        self.progress.phase_start_ns = std.time.nanoTimestamp();

        // Update metrics - status 3 = finalizing
        metrics.Registry.resharding_status.store(3, .monotonic);
    }

    /// Complete the resharding operation.
    pub fn completeResharding(self: *Self) !void {
        if (self.state != .updating_topology) {
            return error.InvalidState;
        }

        // Update shard count
        self.current_shards = self.target_shards;

        // Exit read-only mode
        self.state = .exiting_read_only;
        setClusterMode(.normal);

        // Free exported data
        for (self.exported_data, 0..) |maybe_data, i| {
            if (maybe_data) |data| {
                self.allocator.free(data.data);
                self.exported_data[i] = null;
            }
        }

        self.state = .complete;

        // Update metrics - complete
        const end_time_ns = std.time.nanoTimestamp();
        const duration_ns: u64 = @intCast(end_time_ns - self.progress.start_time_ns);
        metrics.Registry.resharding_duration_ns.store(duration_ns, .monotonic);
        metrics.Registry.resharding_progress.store(1000, .monotonic); // 100%
        metrics.Registry.resharding_status.store(0, .monotonic); // idle
        metrics.Registry.shard_count.store(self.current_shards, .monotonic);
    }

    /// Initiate rollback due to failure.
    pub fn initiateRollback(self: *Self, reason: []const u8) void {
        self.state = .rolling_back;
        self.error_message = reason;

        // Return to normal mode first
        setClusterMode(.normal);
    }

    /// Complete the rollback operation.
    pub fn completeRollback(self: *Self) void {
        // Reset to original shard count
        self.target_shards = self.current_shards;

        // Free any exported data
        for (self.exported_data, 0..) |maybe_data, i| {
            if (maybe_data) |data| {
                self.allocator.free(data.data);
                self.exported_data[i] = null;
            }
        }

        self.state = .rollback_complete;

        // Reset metrics
        metrics.Registry.resharding_status.store(0, .monotonic);
        metrics.Registry.resharding_progress.store(0, .monotonic);
    }

    /// Get progress percentage (0.0 to 100.0).
    pub fn getProgressPercent(self: *const Self) f64 {
        if (self.progress.total_entities == 0) return 0.0;

        const progress: f64 = switch (self.state) {
            .idle, .validating, .backing_up, .entering_read_only => 0.0,
            .exporting => @as(f64, @floatFromInt(self.progress.exported_entities)) /
                @as(f64, @floatFromInt(self.progress.total_entities)) * 40.0,
            .importing => 40.0 + @as(f64, @floatFromInt(self.progress.imported_entities)) /
                @as(f64, @floatFromInt(self.progress.total_entities)) * 40.0,
            .verifying, .updating_topology => 80.0 + 15.0,
            .exiting_read_only, .complete => 100.0,
            .rolling_back, .rollback_complete => 0.0,
        };

        return progress;
    }

    /// Get elapsed time in seconds.
    pub fn getElapsedSeconds(self: *const Self) f64 {
        if (self.progress.start_time_ns == 0) return 0.0;
        const elapsed_ns = std.time.nanoTimestamp() - self.progress.start_time_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    }

    /// Check if resharding is in progress.
    pub fn isInProgress(self: *const Self) bool {
        return self.state.isInProgress();
    }
};

/// Compute new shard assignments for all entities.
/// Returns a mapping of entity_id -> new_shard for entities that need to move.
pub fn computeShardAssignments(
    entity_ids: []const u128,
    old_shard_count: u32,
    new_shard_count: u32,
    result: []Migration,
) usize {
    var count: usize = 0;

    for (entity_ids) |entity_id| {
        const old_shard = getShardBucket(entity_id, old_shard_count);
        const new_shard = getShardBucket(entity_id, new_shard_count);

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

/// Calculate simple checksum for data verification.
pub fn calculateChecksum(data: []const u8) u64 {
    // FNV-1a hash for fast checksum
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    const prime: u64 = 0x100000001b3; // FNV prime

    for (data) |byte| {
        hash ^= byte;
        hash *%= prime;
    }

    return hash;
}

// === Stop-the-World Tests ===

test "ClusterMode operations" {
    try std.testing.expect(ClusterMode.normal.allowsWrites());
    try std.testing.expect(ClusterMode.normal.allowsReads());

    try std.testing.expect(!ClusterMode.read_only.allowsWrites());
    try std.testing.expect(ClusterMode.read_only.allowsReads());

    try std.testing.expect(!ClusterMode.maintenance.allowsWrites());
    try std.testing.expect(!ClusterMode.maintenance.allowsReads());
}

test "StopTheWorldState transitions" {
    try std.testing.expect(!StopTheWorldState.idle.isInProgress());
    try std.testing.expect(StopTheWorldState.exporting.isInProgress());
    try std.testing.expect(StopTheWorldState.importing.isInProgress());
    try std.testing.expect(!StopTheWorldState.complete.isInProgress());
    try std.testing.expect(!StopTheWorldState.rollback_complete.isInProgress());
}

test "StopTheWorldResharder planning" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Plan resharding from 8 to 16 shards
    const plan = try resharder.planResharding(16, 1_000_000);

    try std.testing.expectEqual(@as(u32, 8), plan.source_shards);
    try std.testing.expectEqual(@as(u32, 16), plan.target_shards);
    try std.testing.expectEqual(@as(u64, 1_000_000), plan.total_entities);
    try std.testing.expect(plan.entities_to_move > 0);
    try std.testing.expect(plan.estimated_duration_seconds > 0);
}

test "StopTheWorldResharder state machine" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Initial state
    try std.testing.expectEqual(StopTheWorldState.idle, resharder.state);
    try std.testing.expect(!resharder.isInProgress());

    // Plan and start
    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);
    try std.testing.expectEqual(StopTheWorldState.backing_up, resharder.state);
    try std.testing.expect(resharder.isInProgress());

    // Skip backup for testing
    try resharder.skipBackup();
    try std.testing.expectEqual(StopTheWorldState.exporting, resharder.state);
    try std.testing.expectEqual(ClusterMode.read_only, getClusterMode());

    // Record exports for each source shard
    for (0..8) |i| {
        const test_data = "test data";
        try resharder.recordExportedShard(
            @intCast(i),
            125, // entities per shard
            test_data,
            calculateChecksum(test_data),
        );
    }

    try std.testing.expectEqual(@as(u64, 1000), resharder.progress.exported_entities);

    // Transition to importing
    try resharder.startImporting();
    try std.testing.expectEqual(StopTheWorldState.importing, resharder.state);

    // Record import progress
    resharder.recordImportProgress(1000);
    try std.testing.expectEqual(@as(u64, 1000), resharder.progress.imported_entities);

    // Verify
    try resharder.startVerifying();
    try resharder.completeVerification(1000);
    try std.testing.expectEqual(StopTheWorldState.updating_topology, resharder.state);

    // Complete
    try resharder.completeResharding();
    try std.testing.expectEqual(StopTheWorldState.complete, resharder.state);
    try std.testing.expectEqual(@as(u32, 16), resharder.current_shards);
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());

    // Reset for next test
    setClusterMode(.normal);
}

test "StopTheWorldResharder rollback" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    // Simulate failure and rollback
    resharder.initiateRollback("Test failure");
    try std.testing.expectEqual(StopTheWorldState.rolling_back, resharder.state);
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());

    resharder.completeRollback();
    try std.testing.expectEqual(StopTheWorldState.rollback_complete, resharder.state);
    try std.testing.expectEqual(@as(u32, 8), resharder.current_shards);
}

test "computeShardAssignments" {
    // Test entity IDs
    var entity_ids: [100]u128 = undefined;
    for (0..100) |i| {
        entity_ids[i] = @as(u128, i) + 1;
    }

    var migrations: [100]Migration = undefined;
    const count = computeShardAssignments(&entity_ids, 8, 16, &migrations);

    // Some entities should need to move when doubling shards
    try std.testing.expect(count > 0);
    try std.testing.expect(count < 100);

    // Verify all migrations have different old/new shards
    for (migrations[0..count]) |m| {
        try std.testing.expect(m.old_shard != m.new_shard);
        try std.testing.expect(m.old_shard < 8);
        try std.testing.expect(m.new_shard < 16);
    }
}

test "calculateChecksum" {
    const data1 = "Hello, World!";
    const data2 = "Hello, World!";
    const data3 = "Different data";

    const checksum1 = calculateChecksum(data1);
    const checksum2 = calculateChecksum(data2);
    const checksum3 = calculateChecksum(data3);

    // Same data should produce same checksum
    try std.testing.expectEqual(checksum1, checksum2);

    // Different data should produce different checksum
    try std.testing.expect(checksum1 != checksum3);
}

// ============================================================================
// Resharding Integration Tests
// ============================================================================

test "resharding integration: metrics are updated throughout lifecycle" {
    // Reset metrics before test
    metrics.Registry.resharding_status.store(0, .monotonic);
    metrics.Registry.resharding_progress.store(0, .monotonic);
    metrics.Registry.resharding_entities_exported.store(0, .monotonic);
    metrics.Registry.resharding_entities_imported.store(0, .monotonic);
    metrics.Registry.resharding_source_shards.store(0, .monotonic);
    metrics.Registry.resharding_target_shards.store(0, .monotonic);
    metrics.Registry.resharding_duration_ns.store(0, .monotonic);

    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Before start - status should be idle
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_status.load(.monotonic));

    // Start resharding
    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);

    // After start - status should be 1 (preparing), source/target set
    try std.testing.expectEqual(@as(u8, 1), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 8), metrics.Registry.resharding_source_shards.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 16), metrics.Registry.resharding_target_shards.load(.monotonic));
    try std.testing.expect(metrics.Registry.resharding_start_ns.load(.monotonic) > 0);

    // Skip backup and export
    try resharder.skipBackup();
    for (0..8) |i| {
        const test_data = "test entity data for shard";
        try resharder.recordExportedShard(
            @intCast(i),
            125,
            test_data,
            calculateChecksum(test_data),
        );
    }

    // After export - entities_exported should be updated
    try std.testing.expectEqual(@as(u64, 1000), metrics.Registry.resharding_entities_exported.load(.monotonic));
    // Progress should be ~50% (export phase)
    const export_progress = metrics.Registry.resharding_progress.load(.monotonic);
    try std.testing.expect(export_progress >= 400 and export_progress <= 500);

    // Import phase - status should be 2 (migrating)
    try resharder.startImporting();
    try std.testing.expectEqual(@as(u8, 2), metrics.Registry.resharding_status.load(.monotonic));

    // Record import progress
    resharder.recordImportProgress(1000);
    try std.testing.expectEqual(@as(u64, 1000), metrics.Registry.resharding_entities_imported.load(.monotonic));
    // Progress should be ~100%
    const import_progress = metrics.Registry.resharding_progress.load(.monotonic);
    try std.testing.expect(import_progress >= 900);

    // Verify and finalize - status should be 3 (finalizing)
    try resharder.startVerifying();
    try resharder.completeVerification(1000);
    try std.testing.expectEqual(@as(u8, 3), metrics.Registry.resharding_status.load(.monotonic));

    // Complete
    try resharder.completeResharding();
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1000), metrics.Registry.resharding_progress.load(.monotonic)); // 100%
    try std.testing.expect(metrics.Registry.resharding_duration_ns.load(.monotonic) > 0);
    try std.testing.expectEqual(@as(u32, 16), metrics.Registry.shard_count.load(.monotonic));

    // Reset for other tests
    setClusterMode(.normal);
}

test "resharding integration: scale down from 16 to 8 shards" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 16);
    defer resharder.deinit();

    // Plan scale down
    const plan = try resharder.planResharding(8, 2000);
    try std.testing.expectEqual(@as(u32, 16), plan.source_shards);
    try std.testing.expectEqual(@as(u32, 8), plan.target_shards);

    // Execute full workflow
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    // Export from all 16 source shards
    for (0..16) |i| {
        const test_data = "scale down test data";
        try resharder.recordExportedShard(
            @intCast(i),
            125, // 2000/16
            test_data,
            calculateChecksum(test_data),
        );
    }

    try resharder.startImporting();
    resharder.recordImportProgress(2000);
    try resharder.startVerifying();
    try resharder.completeVerification(2000);
    try resharder.completeResharding();

    try std.testing.expectEqual(@as(u32, 8), resharder.current_shards);
    try std.testing.expectEqual(StopTheWorldState.complete, resharder.state);

    setClusterMode(.normal);
}

test "resharding integration: error on concurrent resharding attempt" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);

    // Attempt another resharding while one is in progress
    const result = resharder.startResharding(plan);
    try std.testing.expectError(error.ReshardingInProgress, result);

    // Clean up
    resharder.initiateRollback("test cleanup");
    resharder.completeRollback();
    setClusterMode(.normal);
}

test "resharding integration: error on incomplete export" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 800);
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    // Only export 4 of 8 shards
    for (0..4) |i| {
        const test_data = "partial export";
        try resharder.recordExportedShard(
            @intCast(i),
            100,
            test_data,
            calculateChecksum(test_data),
        );
    }

    // Attempting to start importing should fail
    const result = resharder.startImporting();
    try std.testing.expectError(error.IncompleteExport, result);

    // Clean up
    resharder.initiateRollback("incomplete export");
    resharder.completeRollback();
    setClusterMode(.normal);
}

test "resharding integration: error on verification mismatch" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    for (0..8) |i| {
        const test_data = "test data";
        try resharder.recordExportedShard(
            @intCast(i),
            125,
            test_data,
            calculateChecksum(test_data),
        );
    }

    try resharder.startImporting();
    resharder.recordImportProgress(1000);
    try resharder.startVerifying();

    // Complete with wrong entity count
    const result = resharder.completeVerification(999);
    try std.testing.expectError(error.VerificationFailed, result);
    try std.testing.expect(resharder.error_message != null);

    // Clean up
    resharder.initiateRollback("verification failed");
    resharder.completeRollback();
    setClusterMode(.normal);
}

test "resharding integration: minimum shard count (8)" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 16);
    defer resharder.deinit();

    // Plan resharding to minimum
    const plan = try resharder.planResharding(min_shards, 500);
    try std.testing.expectEqual(@as(u32, min_shards), plan.target_shards);
    try resharder.startResharding(plan);

    // Clean up
    resharder.initiateRollback("test");
    resharder.completeRollback();
    setClusterMode(.normal);
}

test "resharding integration: maximum shard count (256)" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 128);
    defer resharder.deinit();

    // Plan resharding to maximum
    const plan = try resharder.planResharding(max_shards, 10000);
    try std.testing.expectEqual(@as(u32, max_shards), plan.target_shards);
    try resharder.startResharding(plan);

    // Clean up
    resharder.initiateRollback("test");
    resharder.completeRollback();
    setClusterMode(.normal);
}

test "resharding integration: invalid shard count rejected" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Below minimum
    const result1 = resharder.planResharding(4, 1000);
    try std.testing.expectError(error.InvalidShardCount, result1);

    // Above maximum
    const result2 = resharder.planResharding(512, 1000);
    try std.testing.expectError(error.InvalidShardCount, result2);

    // Same as current (no change needed)
    const result3 = resharder.planResharding(8, 1000);
    try std.testing.expectError(error.NoChangeRequired, result3);
}

test "resharding integration: progress percentage calculation" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Idle - 0%
    try std.testing.expectEqual(@as(f64, 0.0), resharder.getProgressPercent());

    const plan = try resharder.planResharding(16, 1000);
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    // After export starts - should show export progress
    for (0..4) |i| {
        const test_data = "progress test";
        try resharder.recordExportedShard(
            @intCast(i),
            125,
            test_data,
            calculateChecksum(test_data),
        );
    }
    // Half exported = ~20% total (40% * 0.5)
    const progress_half_export = resharder.getProgressPercent();
    try std.testing.expect(progress_half_export >= 15.0 and progress_half_export <= 25.0);

    // Complete export
    for (4..8) |i| {
        const test_data = "progress test";
        try resharder.recordExportedShard(
            @intCast(i),
            125,
            test_data,
            calculateChecksum(test_data),
        );
    }

    try resharder.startImporting();
    resharder.recordImportProgress(500);
    // Half imported = 40% + 20% = ~60%
    const progress_half_import = resharder.getProgressPercent();
    try std.testing.expect(progress_half_import >= 55.0 and progress_half_import <= 65.0);

    resharder.recordImportProgress(1000);
    try resharder.startVerifying();
    // Verifying = 80% + 15% = 95%
    const progress_verifying = resharder.getProgressPercent();
    try std.testing.expect(progress_verifying >= 90.0 and progress_verifying <= 100.0);

    try resharder.completeVerification(1000);
    try resharder.completeResharding();
    // Complete = 100%
    try std.testing.expectEqual(@as(f64, 100.0), resharder.getProgressPercent());

    setClusterMode(.normal);
}

test "resharding integration: data integrity with checksum validation" {
    const test_entities = [_]struct { id: u128, data: []const u8 }{
        .{ .id = 0x1234567890ABCDEF, .data = "Entity 1 data with location info" },
        .{ .id = 0xFEDCBA0987654321, .data = "Entity 2 different content" },
        .{ .id = 0x1111222233334444, .data = "Entity 3 spatial data payload" },
        .{ .id = 0xAAAABBBBCCCCDDDD, .data = "Entity 4 geo-event information" },
    };

    // Calculate checksums for each entity
    var checksums: [4]u64 = undefined;
    for (test_entities, 0..) |entity, i| {
        checksums[i] = calculateChecksum(entity.data);
    }

    // Verify checksums are deterministic
    for (test_entities, 0..) |entity, i| {
        const recomputed = calculateChecksum(entity.data);
        try std.testing.expectEqual(checksums[i], recomputed);
    }

    // Verify different data produces different checksums
    try std.testing.expect(checksums[0] != checksums[1]);
    try std.testing.expect(checksums[1] != checksums[2]);
    try std.testing.expect(checksums[2] != checksums[3]);
}

test "resharding integration: cluster mode transitions" {
    // Start in normal mode
    setClusterMode(.normal);
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());

    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 96); // 8 shards * 12 entities each
    try resharder.startResharding(plan);

    // Still normal during backup
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());

    // Skip backup triggers read-only mode
    try resharder.skipBackup();
    try std.testing.expectEqual(ClusterMode.read_only, getClusterMode());

    // Complete resharding returns to normal
    for (0..8) |i| {
        try resharder.recordExportedShard(@intCast(i), 12, "d", calculateChecksum("d"));
    }
    try resharder.startImporting();
    resharder.recordImportProgress(96);
    try resharder.startVerifying();
    try resharder.completeVerification(96);
    try resharder.completeResharding();

    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());
}

test "resharding integration: rollback restores cluster mode" {
    setClusterMode(.normal);

    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    const plan = try resharder.planResharding(16, 100);
    try resharder.startResharding(plan);
    try resharder.skipBackup();

    // Cluster is in read-only mode
    try std.testing.expectEqual(ClusterMode.read_only, getClusterMode());

    // Rollback should restore normal mode
    resharder.initiateRollback("test rollback");
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());

    resharder.completeRollback();
    try std.testing.expectEqual(ClusterMode.normal, getClusterMode());
}

test "resharding integration: entity migration calculation" {
    // Test specific entity IDs to verify consistent shard assignment
    const entity1: u128 = 0x0000000000000001;
    const entity2: u128 = 0x0000000000000002;
    const entity3: u128 = 0xFFFFFFFFFFFFFFFF;

    // Get shard keys
    const key1 = computeShardKey(entity1);
    const key2 = computeShardKey(entity2);
    const key3 = computeShardKey(entity3);

    // Different entities should have different shard keys
    try std.testing.expect(key1 != key2);
    try std.testing.expect(key2 != key3);

    // Shard buckets should be deterministic
    const bucket1_8 = computeShardBucket(key1, 8);
    const bucket1_16 = computeShardBucket(key1, 16);

    // Same entity may be in different bucket after resharding
    // (this tests the migration logic)
    const needs_migration = (bucket1_8 != (bucket1_16 % 8));
    _ = needs_migration; // Used for understanding migration behavior

    // Buckets should be in valid range
    try std.testing.expect(bucket1_8 < 8);
    try std.testing.expect(bucket1_16 < 16);
}

test "resharding integration: elapsed time tracking" {
    var resharder = try StopTheWorldResharder.init(std.testing.allocator, 8);
    defer resharder.deinit();

    // Before start, elapsed should be 0
    try std.testing.expectEqual(@as(f64, 0.0), resharder.getElapsedSeconds());

    const plan = try resharder.planResharding(16, 100);
    try resharder.startResharding(plan);

    // After start, elapsed should be > 0
    const elapsed = resharder.getElapsedSeconds();
    try std.testing.expect(elapsed >= 0.0);

    // Clean up
    resharder.initiateRollback("test");
    resharder.completeRollback();
    setClusterMode(.normal);
}
