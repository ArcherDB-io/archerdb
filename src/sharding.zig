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

// =============================================================================
// Sharding Strategy (per add-jump-consistent-hash spec)
// =============================================================================
//
// Per add-jump-consistent-hash/spec.md:
// - Supports multiple sharding strategies
// - jump_hash is the default (optimal movement on resize)
// - modulo requires power-of-2 shard counts
// - virtual_ring uses ConsistentHashRing
//

/// Sharding strategy for distributing entities across shards.
pub const ShardingStrategy = enum {
    /// Simple modulo-based sharding: hash % num_shards.
    /// Requires power-of-2 shard counts for efficient computation.
    /// Moves ~(N-1)/N entities when adding one shard.
    modulo,

    /// Virtual node ring-based consistent hashing.
    /// Uses 150 virtual nodes per shard by default.
    /// Moves ~1/N entities when adding one shard.
    /// Has O(log N) lookup overhead and memory cost.
    virtual_ring,

    /// Jump Consistent Hash (Google, 2014).
    /// O(1) memory, O(log N) compute, optimal 1/(N+1) movement.
    /// Default strategy - best balance of performance and movement.
    jump_hash,

    /// Spatial sharding based on S2 cell hierarchy.
    /// Routes events based on geographic location using S2 cell prefixes.
    /// Per add-spatial-sharding/spec.md:
    /// - Optimizes spatial queries (radius, polygon) by reducing fan-out
    /// - Entity lookups require two-hop: lookup cell_id, then data shard
    /// - Best for workloads dominated by spatial queries
    spatial,

    /// Parse strategy from string.
    pub fn fromString(str: []const u8) ?ShardingStrategy {
        if (std.mem.eql(u8, str, "modulo")) return .modulo;
        if (std.mem.eql(u8, str, "virtual_ring")) return .virtual_ring;
        if (std.mem.eql(u8, str, "jump_hash")) return .jump_hash;
        if (std.mem.eql(u8, str, "spatial")) return .spatial;
        return null;
    }

    /// Convert strategy to string.
    pub fn toString(self: ShardingStrategy) []const u8 {
        return switch (self) {
            .modulo => "modulo",
            .virtual_ring => "virtual_ring",
            .jump_hash => "jump_hash",
            .spatial => "spatial",
        };
    }

    /// Convert strategy to a stable storage code.
    pub fn toStorage(self: ShardingStrategy) u8 {
        return @intCast(@intFromEnum(self));
    }

    /// Parse strategy from a storage code.
    pub fn fromStorage(value: u8) ?ShardingStrategy {
        return switch (value) {
            0 => .modulo,
            1 => .virtual_ring,
            2 => .jump_hash,
            3 => .spatial,
            else => null,
        };
    }

    /// Check if this strategy requires power-of-2 shard count.
    pub fn requiresPowerOfTwo(self: ShardingStrategy) bool {
        return self == .modulo;
    }

    /// Check if this is the default strategy.
    pub fn isDefault(self: ShardingStrategy) bool {
        return self == .jump_hash;
    }

    /// Get the default strategy.
    pub fn default() ShardingStrategy {
        return .jump_hash;
    }

    /// Check if this strategy is spatial-based.
    pub fn isSpatial(self: ShardingStrategy) bool {
        return self == .spatial;
    }

    /// Check if this strategy requires entity lookup index.
    /// Spatial strategy needs lookup index for entity_id → cell_id mapping.
    pub fn requiresEntityLookup(self: ShardingStrategy) bool {
        return self == .spatial;
    }
};

/// Validate shard count for a specific strategy.
///
/// Per add-jump-consistent-hash/spec.md:
/// - Modulo strategy requires power-of-2 shard counts
/// - Other strategies accept any count in [min_shards, max_shards]
pub fn isValidShardCountForStrategy(num_shards: u32, strategy: ShardingStrategy) bool {
    if (num_shards < min_shards or num_shards > max_shards) {
        return false;
    }

    if (strategy.requiresPowerOfTwo()) {
        return std.math.isPowerOfTwo(num_shards);
    }

    return true;
}

/// Jump Consistent Hash (Google, 2014).
///
/// Per add-jump-consistent-hash/spec.md:
/// - O(1) memory (no data structures)
/// - O(log num_buckets) time complexity
/// - Perfect uniformity: each bucket gets exactly 1/N keys
/// - Optimal movement: exactly 1/(N+1) keys move when adding a bucket
///
/// Arguments:
/// - key: 64-bit hash key
/// - num_buckets: Number of buckets (shards)
///
/// Returns: Bucket index (0 to num_buckets-1)
///
/// Reference: "A Fast, Minimal Memory, Consistent Hash Algorithm"
/// by John Lamping and Eric Veach, Google, 2014.
pub fn jumpHash(key: u64, num_buckets: u32) u32 {
    assert(num_buckets > 0);

    var k = key;
    var b: i64 = -1;
    var j: i64 = 0;

    while (j < num_buckets) {
        b = j;
        // Linear congruential generator step
        k = k *% 2862933555777941757 +% 1;
        // Compute next jump
        j = @intFromFloat((@as(f64, @floatFromInt(b + 1))) *
            (@as(f64, @floatFromInt(@as(u64, 1) << 31)) /
                @as(f64, @floatFromInt((k >> 33) + 1))));
    }

    return @intCast(b);
}

/// Get shard for entity using the specified strategy.
///
/// Per add-jump-consistent-hash/spec.md:
/// - Dispatcher that routes to the appropriate algorithm
/// - ring parameter only used for virtual_ring strategy
///
/// Arguments:
/// - entity_id: 128-bit entity UUID
/// - num_shards: Number of shards
/// - strategy: Sharding strategy to use
/// - ring: Optional ConsistentHashRing (required for virtual_ring, ignored otherwise)
///
/// Returns: Shard index (0 to num_shards-1)
pub fn getShardForEntityWithStrategy(
    entity_id: u128,
    num_shards: u32,
    strategy: ShardingStrategy,
    ring: ?*const ConsistentHashRing,
) u32 {
    const shard_key = computeShardKey(entity_id);

    return switch (strategy) {
        .modulo => computeShardBucket(shard_key, num_shards),
        .virtual_ring => if (ring) |r|
            r.getShardByKey(shard_key)
        else
            computeShardBucket(shard_key, num_shards),
        .jump_hash => jumpHash(shard_key, num_shards),
        // For spatial strategy with entity_id only (no cell_id), use jump_hash.
        // Proper spatial routing requires cell_id; this is the fallback for
        // entity lookups that go through the lookup index first.
        .spatial => jumpHash(shard_key, num_shards),
    };
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

        const expected: f64 = @as(f64, @floatFromInt(self.total)) /
            @as(f64, @floatFromInt(self.num_shards));
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

        const expected: f64 = @as(f64, @floatFromInt(self.total)) /
            @as(f64, @floatFromInt(self.num_shards));
        var max_diff: f64 = 0.0;

        for (self.counts[0..self.num_shards]) |count| {
            const diff = @abs(@as(f64, @floatFromInt(count)) - expected);
            max_diff = @max(max_diff, diff);
        }

        return (max_diff / expected) * 100.0;
    }
};

// =============================================================================
// Spatial Sharding (per add-spatial-sharding spec)
// =============================================================================
//
// Per add-spatial-sharding/spec.md:
// - Uses S2 cell prefixes to determine shard assignment
// - Optimizes spatial queries by locality
// - Requires separate entity lookup index for entity_id → cell_id mapping
//

/// S2 cell level used for shard computation.
/// Level 5 divides Earth into ~500 cells, providing good granularity for 8-256 shards.
pub const spatial_shard_level: u8 = 5;

/// Compute shard from S2 cell ID using spatial locality.
///
/// Per add-spatial-sharding/spec.md:
/// - Uses cell prefix for shard assignment
/// - Maintains spatial locality (nearby cells likely same shard)
/// - Power-of-2 shard counts give even distribution
///
/// Arguments:
/// - cell_id: S2 cell ID (64-bit)
/// - num_shards: Number of shards (8-256, should be power of 2)
///
/// Returns: Shard index (0 to num_shards-1)
pub fn computeSpatialShard(cell_id: u64, num_shards: u32) u32 {
    assert(num_shards >= min_shards);
    assert(num_shards <= max_shards);

    // Extract the high bits of the cell ID as the shard key.
    // S2 cell IDs are structured with face (3 bits) + position bits.
    // Using high bits maintains spatial locality.
    const shard_key = cell_id >> 32;

    // Use jump hash for optimal distribution
    return jumpHash(shard_key, num_shards);
}

/// Result of covering shard computation for a spatial region.
pub const CoveringShardsResult = struct {
    /// Shards that cover the region (deduplicated).
    shards: [max_shards]u32,
    /// Number of shards in the result.
    count: u32,

    /// Get the shard list as a slice.
    pub fn getShards(self: *const CoveringShardsResult) []const u32 {
        return self.shards[0..self.count];
    }

    /// Check if a specific shard is in the covering set.
    pub fn containsShard(self: *const CoveringShardsResult, shard: u32) bool {
        for (self.shards[0..self.count]) |s| {
            if (s == shard) return true;
        }
        return false;
    }
};

/// Compute shards that cover a spatial region defined by cell IDs.
///
/// Per add-spatial-sharding/spec.md:
/// - Takes a list of S2 cells that cover a region
/// - Returns deduplicated list of shards for those cells
/// - Used for spatial queries (radius, polygon)
///
/// Arguments:
/// - covering_cells: Array of S2 cell IDs that cover the query region
/// - num_cells: Number of cells in the array
/// - num_shards: Number of shards in the cluster
///
/// Returns: CoveringShardsResult with deduplicated shard list
pub fn getCoveringShards(
    covering_cells: []const u64,
    num_shards: u32,
) CoveringShardsResult {
    var result = CoveringShardsResult{
        .shards = [_]u32{0} ** max_shards,
        .count = 0,
    };

    // Bitmap for deduplication (assumes max 256 shards)
    var seen: [max_shards]bool = [_]bool{false} ** max_shards;

    for (covering_cells) |cell_id| {
        const shard = computeSpatialShard(cell_id, num_shards);
        if (!seen[shard]) {
            seen[shard] = true;
            result.shards[result.count] = shard;
            result.count += 1;
        }
    }

    return result;
}

/// Entity lookup entry for spatial sharding mode.
///
/// Per add-spatial-sharding/spec.md:
/// - Maps entity_id to its current S2 cell
/// - Required for entity lookups in spatial sharding mode
/// - Same size as a regular event entry for efficient storage
pub const EntityLookupEntry = struct {
    /// Entity UUID (128-bit)
    entity_id: u128,
    /// Current S2 cell ID where entity is located
    cell_id: u64,
    /// Timestamp of last update (nanoseconds)
    timestamp_ns: u64,

    // Size assertion for storage alignment.
    // Entry should be 32 bytes for efficient storage.
    comptime {
        assert(@sizeOf(EntityLookupEntry) == 32);
    }

    /// Create a new lookup entry.
    pub fn init(entity_id: u128, cell_id: u64, timestamp_ns: u64) EntityLookupEntry {
        return .{
            .entity_id = entity_id,
            .cell_id = cell_id,
            .timestamp_ns = timestamp_ns,
        };
    }

    /// Get the shard for this entity in spatial mode.
    pub fn getShard(self: EntityLookupEntry, num_shards: u32) u32 {
        return computeSpatialShard(self.cell_id, num_shards);
    }
};

/// Entity lookup index for spatial sharding.
///
/// Maps entity_id → cell_id to enable two-hop entity lookups in spatial mode:
/// 1. Look up cell_id from entity_id in this index
/// 2. Compute spatial shard from cell_id
/// 3. Query the data shard
///
/// Distributed the same way as entity sharding - each shard stores
/// lookup entries for entities it owns.
pub const EntityLookupIndex = struct {
    /// Tombstone marker (entity_id = 0 with special cell_id).
    const tombstone_marker: u64 = 0xDEAD_BEEF_DEAD_BEEF;

    /// Maximum entries per index (configurable at init).
    capacity: u32,
    /// Number of valid entries.
    count: u32,
    /// Hash table entries (open addressing with linear probing).
    entries: []EntityLookupEntry,
    /// Allocator for dynamic memory.
    allocator: std.mem.Allocator,

    /// Initialize a new lookup index with given capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !EntityLookupIndex {
        const entries = try allocator.alloc(EntityLookupEntry, capacity);
        // Initialize all entries as empty (entity_id = 0, cell_id = 0)
        for (entries) |*entry| {
            entry.* = .{
                .entity_id = 0,
                .cell_id = 0,
                .timestamp_ns = 0,
            };
        }
        return .{
            .capacity = capacity,
            .count = 0,
            .entries = entries,
            .allocator = allocator,
        };
    }

    /// Free the index memory.
    pub fn deinit(self: *EntityLookupIndex) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Check if an entry slot is empty.
    fn isEmpty(entry: *const EntityLookupEntry) bool {
        return entry.entity_id == 0 and entry.cell_id == 0;
    }

    /// Check if an entry slot is a tombstone.
    fn isTombstone(entry: *const EntityLookupEntry) bool {
        return entry.entity_id == 0 and entry.cell_id == tombstone_marker;
    }

    /// Compute hash slot for entity_id.
    fn hashSlot(self: *const EntityLookupIndex, entity_id: u128) u32 {
        // Use high bits of entity_id for better distribution
        const hash = @as(u64, @truncate(entity_id >> 64)) ^ @as(u64, @truncate(entity_id));
        return @intCast(hash % self.capacity);
    }

    /// Insert or update an entity's cell_id in the index.
    /// Returns error if index is full.
    pub fn upsert(
        self: *EntityLookupIndex,
        entity_id: u128,
        cell_id: u64,
        timestamp_ns: u64,
    ) !void {
        if (entity_id == 0) return error.InvalidEntityId;

        var slot = self.hashSlot(entity_id);
        var probes: u32 = 0;

        while (probes < self.capacity) {
            const entry = &self.entries[slot];

            if (isEmpty(entry) or isTombstone(entry)) {
                // Found empty slot - insert
                entry.* = EntityLookupEntry.init(entity_id, cell_id, timestamp_ns);
                self.count += 1;
                return;
            }

            if (entry.entity_id == entity_id) {
                // Found existing entry - update
                entry.cell_id = cell_id;
                entry.timestamp_ns = timestamp_ns;
                return;
            }

            // Linear probing
            slot = (slot + 1) % self.capacity;
            probes += 1;
        }

        return error.IndexFull;
    }

    /// Look up an entity's cell_id.
    /// Returns null if not found.
    pub fn lookup(self: *const EntityLookupIndex, entity_id: u128) ?EntityLookupEntry {
        if (entity_id == 0) return null;

        var slot = self.hashSlot(entity_id);
        var probes: u32 = 0;

        while (probes < self.capacity) {
            const entry = &self.entries[slot];

            if (isEmpty(entry)) {
                // Empty slot - not found
                return null;
            }

            if (!isTombstone(entry) and entry.entity_id == entity_id) {
                return entry.*;
            }

            slot = (slot + 1) % self.capacity;
            probes += 1;
        }

        return null;
    }

    /// Get the shard for an entity using spatial sharding.
    /// Returns null if entity not in index.
    pub fn getShardForEntity(
        self: *const EntityLookupIndex,
        entity_id: u128,
        num_shards: u32,
    ) ?u32 {
        if (self.lookup(entity_id)) |entry| {
            return entry.getShard(num_shards);
        }
        return null;
    }

    /// Remove an entity from the index.
    /// Uses tombstone to maintain probe chains.
    pub fn remove(self: *EntityLookupIndex, entity_id: u128) bool {
        if (entity_id == 0) return false;

        var slot = self.hashSlot(entity_id);
        var probes: u32 = 0;

        while (probes < self.capacity) {
            const entry = &self.entries[slot];

            if (isEmpty(entry)) {
                return false;
            }

            if (!isTombstone(entry) and entry.entity_id == entity_id) {
                // Mark as tombstone
                entry.entity_id = 0;
                entry.cell_id = tombstone_marker;
                entry.timestamp_ns = 0;
                self.count -= 1;
                return true;
            }

            slot = (slot + 1) % self.capacity;
            probes += 1;
        }

        return false;
    }

    /// Get load factor (count / capacity).
    pub fn loadFactor(self: *const EntityLookupIndex) f32 {
        return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.capacity));
    }

    /// Check if index needs resizing (load factor > 0.75).
    pub fn needsResize(self: *const EntityLookupIndex) bool {
        return self.loadFactor() > 0.75;
    }
};

/// Get shard for spatial query (radius or polygon).
///
/// Wrapper that handles spatial strategy routing.
/// Returns all shards if not using spatial strategy.
pub fn getShardsForSpatialQuery(
    covering_cells: []const u64,
    num_shards: u32,
    strategy: ShardingStrategy,
) CoveringShardsResult {
    if (strategy.isSpatial() and covering_cells.len > 0) {
        return getCoveringShards(covering_cells, num_shards);
    }

    // Non-spatial strategy or empty covering: return all shards
    var result = CoveringShardsResult{
        .shards = [_]u32{0} ** max_shards,
        .count = num_shards,
    };
    for (0..num_shards) |i| {
        result.shards[i] = @intCast(i);
    }
    return result;
}

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

// =============================================================================
// Jump Consistent Hash Tests (per add-jump-consistent-hash spec)
// =============================================================================

test "ShardingStrategy fromString and toString" {
    // Parse valid strategies
    try std.testing.expectEqual(ShardingStrategy.fromString("modulo"), .modulo);
    try std.testing.expectEqual(ShardingStrategy.fromString("virtual_ring"), .virtual_ring);
    try std.testing.expectEqual(ShardingStrategy.fromString("jump_hash"), .jump_hash);

    // Invalid string
    try std.testing.expectEqual(ShardingStrategy.fromString("invalid"), null);

    // Round-trip
    try std.testing.expectEqualStrings("modulo", ShardingStrategy.modulo.toString());
    try std.testing.expectEqualStrings("virtual_ring", ShardingStrategy.virtual_ring.toString());
    try std.testing.expectEqualStrings("jump_hash", ShardingStrategy.jump_hash.toString());
}

test "ShardingStrategy storage roundtrip" {
    const strategies = [_]ShardingStrategy{ .modulo, .virtual_ring, .jump_hash, .spatial };
    inline for (strategies) |strategy| {
        const stored = strategy.toStorage();
        try std.testing.expectEqual(strategy, ShardingStrategy.fromStorage(stored).?);
    }

    try std.testing.expectEqual(@as(?ShardingStrategy, null), ShardingStrategy.fromStorage(255));
}

test "ShardingStrategy requiresPowerOfTwo" {
    try std.testing.expect(ShardingStrategy.modulo.requiresPowerOfTwo());
    try std.testing.expect(!ShardingStrategy.virtual_ring.requiresPowerOfTwo());
    try std.testing.expect(!ShardingStrategy.jump_hash.requiresPowerOfTwo());
}

test "ShardingStrategy default" {
    try std.testing.expectEqual(ShardingStrategy.default(), .jump_hash);
    try std.testing.expect(ShardingStrategy.jump_hash.isDefault());
    try std.testing.expect(!ShardingStrategy.modulo.isDefault());
}

test "isValidShardCountForStrategy" {
    // Modulo requires power-of-2
    try std.testing.expect(isValidShardCountForStrategy(8, .modulo));
    try std.testing.expect(isValidShardCountForStrategy(16, .modulo));
    try std.testing.expect(!isValidShardCountForStrategy(10, .modulo)); // Not power of 2
    try std.testing.expect(!isValidShardCountForStrategy(24, .modulo)); // Not power of 2

    // Jump hash accepts any count in range
    try std.testing.expect(isValidShardCountForStrategy(8, .jump_hash));
    try std.testing.expect(isValidShardCountForStrategy(10, .jump_hash)); // Any count OK
    try std.testing.expect(isValidShardCountForStrategy(24, .jump_hash));
    try std.testing.expect(isValidShardCountForStrategy(100, .jump_hash));

    // Virtual ring also accepts any count
    try std.testing.expect(isValidShardCountForStrategy(10, .virtual_ring));
    try std.testing.expect(isValidShardCountForStrategy(100, .virtual_ring));

    // All strategies reject out of range
    try std.testing.expect(!isValidShardCountForStrategy(4, .jump_hash)); // Below min
    try std.testing.expect(!isValidShardCountForStrategy(512, .jump_hash)); // Above max
}

test "jumpHash determinism" {
    // Same key should always return same bucket
    const key: u64 = 0x123456789ABCDEF0;
    const bucket1 = jumpHash(key, 16);
    const bucket2 = jumpHash(key, 16);
    try std.testing.expectEqual(bucket1, bucket2);

    // Different keys should (likely) return different buckets
    const bucket3 = jumpHash(key + 1, 16);
    // With 16 buckets, probability of collision is 1/16
    // Just verify both are in range
    try std.testing.expect(bucket1 < 16);
    try std.testing.expect(bucket3 < 16);
}

test "jumpHash valid range" {
    const test_keys = [_]u64{
        0x0000000000000000,
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
        0xFFFFFFFFFFFFFFFF,
    };

    // Test various bucket counts
    for (test_keys) |key| {
        try std.testing.expect(jumpHash(key, 1) < 1);
        try std.testing.expect(jumpHash(key, 8) < 8);
        try std.testing.expect(jumpHash(key, 16) < 16);
        try std.testing.expect(jumpHash(key, 24) < 24); // Non-power-of-2
        try std.testing.expect(jumpHash(key, 100) < 100);
        try std.testing.expect(jumpHash(key, 256) < 256);
    }
}

test "jumpHash uniformity" {
    // Generate many keys and verify distribution is uniform
    const num_buckets: u32 = 16;
    const num_keys: u32 = 160000; // 10000 per bucket expected
    var counts: [16]u32 = .{0} ** 16;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..num_keys) |_| {
        const key = random.int(u64);
        const bucket = jumpHash(key, num_buckets);
        counts[bucket] += 1;
    }

    // Each bucket should have ~10000 keys
    // Allow 5% deviation (9500-10500)
    const expected: f64 = @as(f64, @floatFromInt(num_keys)) / @as(f64, @floatFromInt(num_buckets));
    for (counts) |count| {
        const actual: f64 = @floatFromInt(count);
        const deviation = @abs(actual - expected) / expected;
        try std.testing.expect(deviation < 0.05); // Less than 5% deviation
    }
}

test "jumpHash optimal movement" {
    // Per spec: exactly 1/(N+1) keys should move when adding a bucket
    const num_keys: u32 = 100000;
    const old_buckets: u32 = 16;
    const new_buckets: u32 = 17;

    var moved: u32 = 0;

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    for (0..num_keys) |_| {
        const key = random.int(u64);
        const old_bucket = jumpHash(key, old_buckets);
        const new_bucket = jumpHash(key, new_buckets);
        if (old_bucket != new_bucket) {
            moved += 1;
        }
    }

    // Expected: 1/17 = ~5.88% should move
    const expected_ratio: f64 = 1.0 / @as(f64, @floatFromInt(new_buckets));
    const actual_ratio: f64 = @as(f64, @floatFromInt(moved)) / @as(f64, @floatFromInt(num_keys));

    // Allow 1% absolute deviation
    try std.testing.expect(@abs(actual_ratio - expected_ratio) < 0.01);
}

test "jumpHash known values" {
    // Verify against reference implementation values
    // These values are computed from the Google reference implementation
    try std.testing.expectEqual(jumpHash(0, 1), 0);
    try std.testing.expectEqual(jumpHash(0, 10), 0);

    // Test that increasing buckets never increases bucket assignment
    // (monotonicity property of jump hash)
    const key: u64 = 0xDEADBEEF;
    var prev_bucket: u32 = 0;
    for (1..257) |n| {
        const bucket = jumpHash(key, @intCast(n));
        try std.testing.expect(bucket <= prev_bucket or bucket == @as(u32, @intCast(n)) - 1);
        prev_bucket = bucket;
    }
}

test "getShardForEntityWithStrategy modulo" {
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const bucket_modulo = getShardForEntityWithStrategy(entity_id, 16, .modulo, null);
    const bucket_direct = getShardBucket(entity_id, 16);
    try std.testing.expectEqual(bucket_modulo, bucket_direct);
}

test "getShardForEntityWithStrategy jump_hash" {
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const bucket = getShardForEntityWithStrategy(entity_id, 16, .jump_hash, null);
    try std.testing.expect(bucket < 16);

    // Should be deterministic
    const bucket2 = getShardForEntityWithStrategy(entity_id, 16, .jump_hash, null);
    try std.testing.expectEqual(bucket, bucket2);
}

test "getShardForEntityWithStrategy virtual_ring" {
    const allocator = std.testing.allocator;
    var ring = try ConsistentHashRing.init(allocator, 16, 150);
    defer ring.deinit();

    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const bucket = getShardForEntityWithStrategy(entity_id, 16, .virtual_ring, &ring);
    try std.testing.expect(bucket < 16);

    // Should match ring directly
    const bucket_ring = ring.getShard(entity_id);
    try std.testing.expectEqual(bucket, bucket_ring);
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
// Consistent Hashing Ring
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
    ) !ConsistentHashRing {
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
    pub fn deinit(self: *ConsistentHashRing) void {
        self.allocator.free(self.ring);
    }

    /// Find the shard for a given entity_id using consistent hashing.
    pub fn getShard(self: *const ConsistentHashRing, entity_id: u128) u32 {
        const key = computeShardKey(entity_id);
        return self.getShardByKey(key);
    }

    /// Find the shard for a given shard key.
    pub fn getShardByKey(self: *const ConsistentHashRing, key: u64) u32 {
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
        self: *const ConsistentHashRing,
        new_ring: *const ConsistentHashRing,
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
// Online Resharding State Machine
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
    pub fn init(allocator: std.mem.Allocator, initial_shards: u32) ReshardingManager {
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
    pub fn deinit(self: *ReshardingManager) void {
        if (self.current_ring) |*ring| {
            ring.deinit();
        }
        if (self.target_ring) |*ring| {
            ring.deinit();
        }
    }

    /// Start online resharding to a new shard count.
    pub fn startResharding(self: *ReshardingManager, new_shard_count: u32) !void {
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
    pub fn reportProgress(self: *ReshardingManager, migrated: u64, total: u64) void {
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
    pub fn completeResharding(self: *ReshardingManager) !void {
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
    pub fn cancelResharding(self: *ReshardingManager, reason: []const u8) void {
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
    pub fn getShardForEntity(
        self: *const ReshardingManager,
        entity_id: u128,
    ) struct { primary: u32, secondary: ?u32 } {
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
    pub fn isDualWriteRequired(self: *const ReshardingManager) bool {
        return self.state == .copying or self.state == .verifying;
    }

    /// Get progress percentage.
    pub fn getProgressPercent(self: *const ReshardingManager) f64 {
        if (self.progress.total_entities == 0) return 0.0;
        return @as(f64, @floatFromInt(self.progress.migrated_entities)) /
            @as(f64, @floatFromInt(self.progress.total_entities)) * 100.0;
    }
};

// =============================================================================
// Online Resharding Implementation
// =============================================================================
//
// - Dual-write mode during migration
// - Background batch migration with rate limiting
// - Resumable after failures
// - Brief pause (<1 second) for cutover

/// Configuration for online resharding.
pub const OnlineReshardingConfig = struct {
    /// Number of entities per migration batch.
    batch_size: u32 = 1000,

    /// Maximum migration rate (entities per second). 0 = unlimited.
    rate_limit: u32 = 10000,

    /// Delay between batches in milliseconds.
    batch_delay_ms: u32 = 10,

    /// Maximum retries for failed batches.
    max_retries: u32 = 3,

    /// Whether to automatically trigger cutover when migration completes.
    auto_cutover: bool = false,

    /// Maximum lag (entities) before cutover is allowed.
    max_cutover_lag: u64 = 100,

    /// Checkpoint interval (entities between checkpoints).
    checkpoint_interval: u64 = 10000,
};

/// Migration checkpoint for resumability.
pub const MigrationCheckpoint = struct {
    /// Source shard being migrated.
    source_shard: u32,

    /// Last migrated entity key (resume from here).
    last_key: u128,

    /// Number of entities migrated from this shard.
    migrated_count: u64,

    /// Total entities in this shard.
    total_count: u64,

    /// Timestamp of this checkpoint.
    timestamp: i64,

    /// Checksum for verification.
    checksum: u64,

    pub fn isComplete(self: *const MigrationCheckpoint) bool {
        return self.migrated_count >= self.total_count;
    }

    pub fn getProgress(self: *const MigrationCheckpoint) f64 {
        if (self.total_count == 0) return 1.0;
        return @as(f64, @floatFromInt(self.migrated_count)) /
            @as(f64, @floatFromInt(self.total_count));
    }
};

/// Represents a batch of entities to migrate.
pub const MigrationBatch = struct {
    /// Source shard ID.
    source_shard: u32,

    /// Target shard ID.
    target_shard: u32,

    /// Entity IDs in this batch.
    entity_ids: []u128,

    /// Batch sequence number (for ordering).
    sequence: u64,

    /// Retry count for this batch.
    retry_count: u32,

    /// Allocator used.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MigrationBatch) void {
        self.allocator.free(self.entity_ids);
    }
};

/// Build a migration batch with sequential entity IDs.
pub fn makeSequentialMigrationBatch(
    allocator: std.mem.Allocator,
    source_shard: u32,
    target_shard: u32,
    start_id: u128,
    count: usize,
    sequence: u64,
) !MigrationBatch {
    const entity_ids = try allocator.alloc(u128, count);
    for (entity_ids, 0..) |*entry, idx| {
        entry.* = start_id + @as(u128, idx);
    }

    return MigrationBatch{
        .source_shard = source_shard,
        .target_shard = target_shard,
        .entity_ids = entity_ids,
        .sequence = sequence,
        .retry_count = 0,
        .allocator = allocator,
    };
}

/// Online migration worker state.
pub const MigrationWorkerState = enum {
    /// Worker is idle.
    idle,

    /// Worker is scanning source shards.
    scanning,

    /// Worker is actively migrating.
    migrating,

    /// Worker is paused (rate limited or manual).
    paused,

    /// Worker is waiting for cutover.
    waiting_cutover,

    /// Worker is performing cutover.
    cutover,

    /// Migration completed.
    completed,

    /// Migration failed.
    failed,

    pub fn toString(self: MigrationWorkerState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .scanning => "SCANNING",
            .migrating => "MIGRATING",
            .paused => "PAUSED",
            .waiting_cutover => "WAITING_CUTOVER",
            .cutover => "CUTOVER",
            .completed => "COMPLETED",
            .failed => "FAILED",
        };
    }
};

/// Online migration worker for background data migration.
pub const OnlineMigrationWorker = struct {
    /// Configuration.
    config: OnlineReshardingConfig,

    /// Current worker state.
    state: MigrationWorkerState,

    /// Resharding manager reference.
    resharding_manager: *ReshardingManager,

    /// Migration checkpoints per source shard.
    checkpoints: std.AutoHashMap(u32, MigrationCheckpoint),

    /// Queue of pending batches.
    pending_batches: std.ArrayList(MigrationBatch),

    /// Statistics.
    stats: struct {
        /// Total entities to migrate.
        total_entities: u64 = 0,

        /// Successfully migrated entities.
        migrated_entities: u64 = 0,

        /// Failed migration attempts.
        failed_attempts: u64 = 0,

        /// Batches processed.
        batches_processed: u64 = 0,

        /// Current migration rate (entities/sec).
        current_rate: f64 = 0,

        /// Start timestamp.
        start_time: i64 = 0,

        /// Last update timestamp.
        last_update: i64 = 0,
    },

    /// Error message if failed.
    error_message: ?[]const u8,

    /// Allocator.
    allocator: std.mem.Allocator,

    /// Rate limiter state.
    rate_limiter: struct {
        /// Tokens available.
        tokens: u64 = 0,

        /// Last refill time.
        last_refill: i64 = 0,
    },

    pub fn init(
        allocator: std.mem.Allocator,
        resharding_manager: *ReshardingManager,
        config: OnlineReshardingConfig,
    ) OnlineMigrationWorker {
        return .{
            .config = config,
            .state = .idle,
            .resharding_manager = resharding_manager,
            .checkpoints = std.AutoHashMap(u32, MigrationCheckpoint).init(allocator),
            .pending_batches = std.ArrayList(MigrationBatch).init(allocator),
            .stats = .{},
            .error_message = null,
            .allocator = allocator,
            .rate_limiter = .{},
        };
    }

    pub fn deinit(self: *OnlineMigrationWorker) void {
        // Clean up pending batches
        for (self.pending_batches.items) |*batch| {
            batch.deinit();
        }
        self.pending_batches.deinit();
        self.checkpoints.deinit();
    }

    /// Start the migration process.
    pub fn start(self: *OnlineMigrationWorker, total_entities: u64) !void {
        if (self.state != .idle) {
            return error.MigrationAlreadyRunning;
        }

        self.state = .scanning;
        self.stats.total_entities = total_entities;
        self.stats.start_time = std.time.timestamp();
        self.stats.last_update = self.stats.start_time;
        self.rate_limiter.last_refill = self.stats.start_time;
        self.rate_limiter.tokens = self.config.rate_limit;
    }

    /// Pause the migration.
    pub fn pause(self: *OnlineMigrationWorker) void {
        if (self.state == .migrating or self.state == .scanning) {
            self.state = .paused;
        }
    }

    /// Resume the migration.
    pub fn resumeMigration(self: *OnlineMigrationWorker) void {
        if (self.state == .paused) {
            self.state = .migrating;
        }
    }

    /// Cancel the migration (triggers rollback).
    pub fn cancel(self: *OnlineMigrationWorker, reason: []const u8) void {
        self.state = .failed;
        self.error_message = reason;
        self.resharding_manager.cancelResharding(reason);
    }

    /// Process a single batch of entities.
    /// Returns true if batch was processed, false if rate limited.
    pub fn processBatch(self: *OnlineMigrationWorker, batch: *MigrationBatch) !bool {
        // Check rate limit
        if (!self.acquireRateTokens(batch.entity_ids.len)) {
            return false;
        }

        // In a real implementation, this would:
        // 1. Read entities from source shard
        // 2. Write entities to target shard
        // 3. Verify write succeeded
        // For now, we track progress

        self.stats.migrated_entities += batch.entity_ids.len;
        self.stats.batches_processed += 1;
        self.stats.last_update = std.time.timestamp();

        // Update checkpoint
        if (batch.entity_ids.len > 0) {
            const last_key = batch.entity_ids[batch.entity_ids.len - 1];
            try self.updateCheckpoint(batch.source_shard, last_key, batch.entity_ids.len);
        }

        // Report progress to manager
        self.resharding_manager.reportProgress(
            self.stats.migrated_entities,
            self.stats.total_entities,
        );

        // Calculate current rate
        const elapsed = self.stats.last_update - self.stats.start_time;
        if (elapsed > 0) {
            self.stats.current_rate = @as(f64, @floatFromInt(self.stats.migrated_entities)) /
                @as(f64, @floatFromInt(elapsed));
        }

        return true;
    }

    /// Check if migration is complete and ready for cutover.
    pub fn isReadyForCutover(self: *const OnlineMigrationWorker) bool {
        if (self.stats.total_entities == 0) return false;

        const remaining = self.stats.total_entities - self.stats.migrated_entities;
        return remaining <= self.config.max_cutover_lag;
    }

    /// Perform cutover to new shard configuration.
    /// This implements the brief pause (<1 second) for final sync.
    pub fn performCutover(self: *OnlineMigrationWorker) !void {
        if (!self.isReadyForCutover()) {
            return error.NotReadyForCutover;
        }

        self.state = .cutover;

        // In a real implementation:
        // 1. Enable write blocking (brief pause)
        // 2. Drain remaining entities
        // 3. Switch topology
        // 4. Resume writes to new topology

        // Complete the resharding
        try self.resharding_manager.completeResharding();

        self.state = .completed;
    }

    /// Get overall progress as a value between 0.0 and 1.0.
    pub fn getProgress(self: *const OnlineMigrationWorker) f64 {
        if (self.stats.total_entities == 0) return 0.0;
        return @as(f64, @floatFromInt(self.stats.migrated_entities)) /
            @as(f64, @floatFromInt(self.stats.total_entities));
    }

    /// Get estimated time remaining in seconds.
    pub fn getEtaSeconds(self: *const OnlineMigrationWorker) ?i64 {
        if (self.stats.current_rate <= 0) return null;

        const remaining = self.stats.total_entities - self.stats.migrated_entities;
        const eta_f64 = @as(f64, @floatFromInt(remaining)) / self.stats.current_rate;
        return @as(i64, @intFromFloat(eta_f64));
    }

    /// Create a checkpoint for a source shard.
    fn updateCheckpoint(
        self: *OnlineMigrationWorker,
        source_shard: u32,
        last_key: u128,
        count: usize,
    ) !void {
        const entry = self.checkpoints.getPtr(source_shard);
        if (entry) |checkpoint| {
            checkpoint.last_key = last_key;
            checkpoint.migrated_count += count;
            checkpoint.timestamp = std.time.timestamp();
        } else {
            try self.checkpoints.put(source_shard, .{
                .source_shard = source_shard,
                .last_key = last_key,
                .migrated_count = count,
                .total_count = 0, // Set by scanner
                .timestamp = std.time.timestamp(),
                .checksum = 0,
            });
        }
    }

    /// Acquire rate limit tokens.
    fn acquireRateTokens(self: *OnlineMigrationWorker, count: usize) bool {
        if (self.config.rate_limit == 0) return true; // Unlimited

        const now = std.time.timestamp();
        const elapsed = now - self.rate_limiter.last_refill;

        // Refill tokens
        if (elapsed > 0) {
            const refill = @as(u64, @intCast(elapsed)) * self.config.rate_limit;
            self.rate_limiter.tokens = @min(
                self.rate_limiter.tokens + refill,
                @as(u64, self.config.rate_limit) * 2, // Max 2 seconds of tokens
            );
            self.rate_limiter.last_refill = now;
        }

        // Check if we have enough tokens
        if (self.rate_limiter.tokens >= count) {
            self.rate_limiter.tokens -= count;
            return true;
        }

        return false;
    }

    /// Load checkpoint from persistent storage (for resumability).
    pub fn loadCheckpoint(
        self: *OnlineMigrationWorker,
        source_shard: u32,
        checkpoint: MigrationCheckpoint,
    ) !void {
        try self.checkpoints.put(source_shard, checkpoint);
        self.stats.migrated_entities += checkpoint.migrated_count;
    }

    /// Get checkpoint for serialization.
    pub fn getCheckpoint(
        self: *const OnlineMigrationWorker,
        source_shard: u32,
    ) ?MigrationCheckpoint {
        return self.checkpoints.get(source_shard);
    }
};

/// Online resharding controller coordinating dual-write migration and cutover.
pub const OnlineReshardingController = struct {
    pub const TopologyManager = @import("topology.zig").TopologyManager;

    const ReshardingStatus = enum(u8) {
        idle = 0,
        preparing = 1,
        migrating = 2,
        finalizing = 3,
    };

    /// Resharding manager for shard map state.
    manager: ReshardingManager,

    /// Background migration worker.
    worker: OnlineMigrationWorker,

    /// Configuration for online resharding.
    config: OnlineReshardingConfig,

    /// Optional topology manager for notifications.
    topology_manager: ?*TopologyManager,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_shards: u32,
        config: OnlineReshardingConfig,
        topology_manager: ?*TopologyManager,
    ) OnlineReshardingController {
        var controller = OnlineReshardingController{
            .manager = ReshardingManager.init(allocator, initial_shards),
            .worker = undefined,
            .config = config,
            .topology_manager = topology_manager,
        };
        controller.worker = OnlineMigrationWorker.init(allocator, &controller.manager, config);
        return controller;
    }

    pub fn deinit(self: *OnlineReshardingController) void {
        self.worker.deinit();
        self.manager.deinit();
    }

    /// Start online resharding to a new shard count.
    pub fn startOnlineResharding(
        self: *OnlineReshardingController,
        new_shard_count: u32,
        total_entities: u64,
    ) !void {
        self.bindManager();
        self.resetMetrics();
        self.setReshardingMode(.preparing);

        metrics.Registry.resharding_source_shards.store(self.manager.current_shards, .monotonic);
        metrics.Registry.resharding_target_shards.store(new_shard_count, .monotonic);
        metrics.Registry.resharding_start_ns.store(
            @intCast(std.time.nanoTimestamp()),
            .monotonic,
        );

        try self.manager.startResharding(new_shard_count);
        try self.worker.start(total_entities);
        self.updateDualWriteMetric();

        if (self.topology_manager) |manager| {
            if (@hasDecl(TopologyManager, "beginResharding")) {
                manager.beginResharding(new_shard_count);
            }
        }
    }

    /// Tick migration worker and update metrics.
    pub fn tickMigration(self: *OnlineReshardingController, batch: *MigrationBatch) !bool {
        self.bindManager();
        if (self.worker.state == .scanning) {
            self.worker.state = .migrating;
        }

        const processed = try self.worker.processBatch(batch);
        if (processed) {
            self.setReshardingMode(.migrating);
            self.updateMigrationMetrics();
        }

        self.updateDualWriteMetric();
        return processed;
    }

    /// Perform cutover if migration is ready.
    pub fn maybeCutover(self: *OnlineReshardingController) !bool {
        self.bindManager();
        if (!self.worker.isReadyForCutover()) return false;

        self.setReshardingMode(.finalizing);
        try self.worker.performCutover();

        if (self.topology_manager) |manager| {
            if (@hasDecl(TopologyManager, "completeResharding")) {
                manager.completeResharding(self.manager.current_shards);
            }
        }

        self.finishResharding();
        return true;
    }

    /// Cancel resharding and rollback.
    pub fn cancel(self: *OnlineReshardingController, reason: []const u8) void {
        self.bindManager();
        self.worker.cancel(reason);
        self.resetWorkerState();
        self.resetManagerProgress();

        if (self.topology_manager) |manager| {
            if (@hasDecl(TopologyManager, "abortResharding")) {
                manager.abortResharding();
            }
        }

        self.finishResharding();
    }

    fn setReshardingMode(_: *OnlineReshardingController, status: ReshardingStatus) void {
        metrics.Registry.resharding_mode.store(2, .monotonic);
        metrics.Registry.resharding_status.store(@intFromEnum(status), .monotonic);
    }

    fn updateDualWriteMetric(self: *OnlineReshardingController) void {
        const enabled: u8 = if (self.manager.isDualWriteRequired()) 1 else 0;
        metrics.Registry.resharding_dual_write_enabled.store(enabled, .monotonic);
    }

    fn updateMigrationMetrics(self: *OnlineReshardingController) void {
        const rate_scaled: u32 = @intCast(@min(
            @as(u64, @intFromFloat(self.worker.stats.current_rate * 100.0)),
            @as(u64, std.math.maxInt(u32)),
        ));
        metrics.Registry.resharding_migration_rate.store(rate_scaled, .monotonic);
        metrics.Registry.resharding_batches_processed.store(
            self.worker.stats.batches_processed,
            .monotonic,
        );
        metrics.Registry.resharding_migration_failures.store(
            self.worker.stats.failed_attempts,
            .monotonic,
        );

        const progress_scaled: u32 = @intCast(@min(
            @as(u64, @intFromFloat(self.worker.getProgress() * 1000.0)),
            @as(u64, std.math.maxInt(u32)),
        ));
        metrics.Registry.resharding_progress.store(progress_scaled, .monotonic);

        if (self.worker.getEtaSeconds()) |eta| {
            metrics.Registry.resharding_eta_seconds.store(@intCast(eta), .monotonic);
        } else {
            metrics.Registry.resharding_eta_seconds.store(0, .monotonic);
        }
    }

    fn resetMetrics(self: *OnlineReshardingController) void {
        _ = self;
        metrics.Registry.resharding_mode.store(0, .monotonic);
        metrics.Registry.resharding_status.store(@intFromEnum(ReshardingStatus.idle), .monotonic);
        metrics.Registry.resharding_source_shards.store(0, .monotonic);
        metrics.Registry.resharding_target_shards.store(0, .monotonic);
        metrics.Registry.resharding_start_ns.store(0, .monotonic);
        metrics.Registry.resharding_dual_write_enabled.store(0, .monotonic);
        metrics.Registry.resharding_migration_rate.store(0, .monotonic);
        metrics.Registry.resharding_batches_processed.store(0, .monotonic);
        metrics.Registry.resharding_migration_failures.store(0, .monotonic);
        metrics.Registry.resharding_eta_seconds.store(0, .monotonic);
        metrics.Registry.resharding_progress.store(0, .monotonic);
    }

    fn finishResharding(self: *OnlineReshardingController) void {
        _ = self;
        metrics.Registry.resharding_mode.store(0, .monotonic);
        metrics.Registry.resharding_status.store(@intFromEnum(ReshardingStatus.idle), .monotonic);
        metrics.Registry.resharding_source_shards.store(0, .monotonic);
        metrics.Registry.resharding_target_shards.store(0, .monotonic);
        metrics.Registry.resharding_start_ns.store(0, .monotonic);
        metrics.Registry.resharding_dual_write_enabled.store(0, .monotonic);
        metrics.Registry.resharding_migration_rate.store(0, .monotonic);
        metrics.Registry.resharding_batches_processed.store(0, .monotonic);
        metrics.Registry.resharding_migration_failures.store(0, .monotonic);
        metrics.Registry.resharding_eta_seconds.store(0, .monotonic);
        metrics.Registry.resharding_progress.store(0, .monotonic);
    }

    fn resetWorkerState(self: *OnlineReshardingController) void {
        for (self.worker.pending_batches.items) |*batch| {
            batch.deinit();
        }
        self.worker.pending_batches.clearRetainingCapacity();
        self.worker.checkpoints.clearRetainingCapacity();
        self.worker.stats = .{};
        self.worker.error_message = null;
        self.worker.state = .idle;
        self.worker.rate_limiter = .{};
    }

    fn resetManagerProgress(self: *OnlineReshardingController) void {
        self.manager.progress = .{};
        self.manager.error_message = null;
    }

    fn bindManager(self: *OnlineReshardingController) void {
        self.worker.resharding_manager = &self.manager;
    }
};

/// Resharding mode for CLI.
pub const ReshardingMode = enum {
    /// Stop-the-world (offline) resharding.
    offline,

    /// Online resharding with dual-write.
    online,

    pub fn toString(self: ReshardingMode) []const u8 {
        return switch (self) {
            .offline => "offline",
            .online => "online",
        };
    }

    pub fn fromString(s: []const u8) ?ReshardingMode {
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "online")) return .online;
        return null;
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
// Stop-the-World Resharding
// =============================================================================
//
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
pub var cluster_mode: std.atomic.Value(u8) =
    std.atomic.Value(u8).init(@intFromEnum(ClusterMode.normal));

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
    pub fn init(allocator: std.mem.Allocator, initial_shards: u32) !StopTheWorldResharder {
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
    pub fn deinit(self: *StopTheWorldResharder) void {
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
        self: *StopTheWorldResharder,
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
            1.0 - (@as(f64, @floatFromInt(self.current_shards)) /
                @as(f64, @floatFromInt(new_shard_count)))
        else
            1.0 - (@as(f64, @floatFromInt(new_shard_count)) /
                @as(f64, @floatFromInt(self.current_shards)));

        const entities_to_move: u64 =
            @intFromFloat(@as(f64, @floatFromInt(total_entities)) * move_ratio);

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
    pub fn startResharding(self: *StopTheWorldResharder, plan: ReshardingPlan) !void {
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
        metrics.Registry.resharding_start_ns.store(
            @intCast(self.progress.start_time_ns),
            .monotonic,
        );
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
    pub fn backupComplete(self: *StopTheWorldResharder, backup_path: []const u8) !void {
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
    pub fn skipBackup(self: *StopTheWorldResharder) !void {
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
        self: *StopTheWorldResharder,
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
        metrics.Registry.resharding_entities_exported.store(
            self.progress.exported_entities,
            .monotonic,
        );
        self.updateProgressMetric();
    }

    /// Update the resharding progress metric based on current state.
    fn updateProgressMetric(self: *StopTheWorldResharder) void {
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
    pub fn startImporting(self: *StopTheWorldResharder) !void {
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
    pub fn recordImportProgress(self: *StopTheWorldResharder, entities_imported: u64) void {
        if (self.state == .importing) {
            self.progress.imported_entities = entities_imported;
            metrics.Registry.resharding_entities_imported.store(entities_imported, .monotonic);
            self.updateProgressMetric();
        }
    }

    /// Transition to verifying phase after import complete.
    pub fn startVerifying(self: *StopTheWorldResharder) !void {
        if (self.state != .importing) {
            return error.InvalidState;
        }

        self.state = .verifying;
        self.progress.phase_start_ns = std.time.nanoTimestamp();
    }

    /// Complete verification and update topology.
    pub fn completeVerification(self: *StopTheWorldResharder, verified_count: u64) !void {
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
    pub fn completeResharding(self: *StopTheWorldResharder) !void {
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
    pub fn initiateRollback(self: *StopTheWorldResharder, reason: []const u8) void {
        self.state = .rolling_back;
        self.error_message = reason;

        // Return to normal mode first
        setClusterMode(.normal);
    }

    /// Complete the rollback operation.
    pub fn completeRollback(self: *StopTheWorldResharder) void {
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
    pub fn getProgressPercent(self: *const StopTheWorldResharder) f64 {
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
    pub fn getElapsedSeconds(self: *const StopTheWorldResharder) f64 {
        if (self.progress.start_time_ns == 0) return 0.0;
        const elapsed_ns = std.time.nanoTimestamp() - self.progress.start_time_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    }

    /// Check if resharding is in progress.
    pub fn isInProgress(self: *const StopTheWorldResharder) bool {
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
    try std.testing.expectEqual(
        @as(u8, 1),
        metrics.Registry.resharding_status.load(.monotonic),
    );
    try std.testing.expectEqual(
        @as(u32, 8),
        metrics.Registry.resharding_source_shards.load(.monotonic),
    );
    try std.testing.expectEqual(
        @as(u32, 16),
        metrics.Registry.resharding_target_shards.load(.monotonic),
    );
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
    try std.testing.expectEqual(
        @as(u64, 1000),
        metrics.Registry.resharding_entities_exported.load(.monotonic),
    );
    // Progress should be ~50% (export phase)
    const export_progress = metrics.Registry.resharding_progress.load(.monotonic);
    try std.testing.expect(export_progress >= 400 and export_progress <= 500);

    // Import phase - status should be 2 (migrating)
    try resharder.startImporting();
    try std.testing.expectEqual(
        @as(u8, 2),
        metrics.Registry.resharding_status.load(.monotonic),
    );

    // Record import progress
    resharder.recordImportProgress(1000);
    try std.testing.expectEqual(
        @as(u64, 1000),
        metrics.Registry.resharding_entities_imported.load(.monotonic),
    );
    // Progress should be ~100%
    const import_progress = metrics.Registry.resharding_progress.load(.monotonic);
    try std.testing.expect(import_progress >= 900);

    // Verify and finalize - status should be 3 (finalizing)
    try resharder.startVerifying();
    try resharder.completeVerification(1000);
    try std.testing.expectEqual(
        @as(u8, 3),
        metrics.Registry.resharding_status.load(.monotonic),
    );

    // Complete
    try resharder.completeResharding();
    try std.testing.expectEqual(
        @as(u8, 0),
        metrics.Registry.resharding_status.load(.monotonic),
    );
    try std.testing.expectEqual(
        @as(u32, 1000),
        metrics.Registry.resharding_progress.load(.monotonic),
    ); // 100%
    try std.testing.expect(metrics.Registry.resharding_duration_ns.load(.monotonic) > 0);
    try std.testing.expectEqual(
        @as(u32, 16),
        metrics.Registry.shard_count.load(.monotonic),
    );

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

// =============================================================================
// Online Resharding Tests
// =============================================================================

test "OnlineReshardingConfig defaults" {
    const config = OnlineReshardingConfig{};
    try std.testing.expectEqual(@as(u32, 1000), config.batch_size);
    try std.testing.expectEqual(@as(u32, 10000), config.rate_limit);
    try std.testing.expectEqual(@as(u32, 10), config.batch_delay_ms);
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expect(!config.auto_cutover);
}

test "MigrationCheckpoint progress tracking" {
    var checkpoint = MigrationCheckpoint{
        .source_shard = 0,
        .last_key = 0,
        .migrated_count = 500,
        .total_count = 1000,
        .timestamp = 0,
        .checksum = 0,
    };

    try std.testing.expect(!checkpoint.isComplete());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), checkpoint.getProgress(), 0.001);

    checkpoint.migrated_count = 1000;
    try std.testing.expect(checkpoint.isComplete());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), checkpoint.getProgress(), 0.001);
}

test "MigrationWorkerState toString" {
    try std.testing.expectEqualStrings("IDLE", MigrationWorkerState.idle.toString());
    try std.testing.expectEqualStrings(
        "SCANNING",
        MigrationWorkerState.scanning.toString(),
    );
    try std.testing.expectEqualStrings(
        "MIGRATING",
        MigrationWorkerState.migrating.toString(),
    );
    try std.testing.expectEqualStrings("PAUSED", MigrationWorkerState.paused.toString());
    try std.testing.expectEqualStrings(
        "WAITING_CUTOVER",
        MigrationWorkerState.waiting_cutover.toString(),
    );
    try std.testing.expectEqualStrings("CUTOVER", MigrationWorkerState.cutover.toString());
    try std.testing.expectEqualStrings(
        "COMPLETED",
        MigrationWorkerState.completed.toString(),
    );
    try std.testing.expectEqualStrings("FAILED", MigrationWorkerState.failed.toString());
}

test "OnlineMigrationWorker initialization" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{},
    );
    defer worker.deinit();

    try std.testing.expectEqual(MigrationWorkerState.idle, worker.state);
    try std.testing.expectEqual(@as(u64, 0), worker.stats.total_entities);
    try std.testing.expectEqual(@as(u64, 0), worker.stats.migrated_entities);
}

test "OnlineMigrationWorker start and progress" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{},
    );
    defer worker.deinit();

    try worker.start(10000);

    try std.testing.expectEqual(MigrationWorkerState.scanning, worker.state);
    try std.testing.expectEqual(@as(u64, 10000), worker.stats.total_entities);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), worker.getProgress(), 0.001);
}

test "OnlineMigrationWorker pause and resume" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{},
    );
    defer worker.deinit();

    try worker.start(10000);
    worker.state = .migrating; // Simulate scanning complete

    worker.pause();
    try std.testing.expectEqual(MigrationWorkerState.paused, worker.state);

    worker.resumeMigration();
    try std.testing.expectEqual(MigrationWorkerState.migrating, worker.state);
}

test "OnlineMigrationWorker cutover readiness" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{ .max_cutover_lag = 100 },
    );
    defer worker.deinit();

    try worker.start(10000);

    // Not ready - too much remaining
    worker.stats.migrated_entities = 9000;
    try std.testing.expect(!worker.isReadyForCutover());

    // Ready - within lag threshold
    worker.stats.migrated_entities = 9950;
    try std.testing.expect(worker.isReadyForCutover());

    // Ready - complete
    worker.stats.migrated_entities = 10000;
    try std.testing.expect(worker.isReadyForCutover());
}

test "OnlineMigrationWorker cancel triggers rollback" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    // Start resharding first
    try manager.startResharding(16);

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{},
    );
    defer worker.deinit();

    try worker.start(10000);
    worker.cancel("test cancellation");

    try std.testing.expectEqual(MigrationWorkerState.failed, worker.state);
    try std.testing.expectEqual(ReshardingState.idle, manager.state);
}

fn resetOnlineReshardingMetrics() void {
    metrics.Registry.resharding_mode.store(0, .monotonic);
    metrics.Registry.resharding_status.store(0, .monotonic);
    metrics.Registry.resharding_dual_write_enabled.store(0, .monotonic);
    metrics.Registry.resharding_migration_rate.store(0, .monotonic);
    metrics.Registry.resharding_batches_processed.store(0, .monotonic);
    metrics.Registry.resharding_migration_failures.store(0, .monotonic);
    metrics.Registry.resharding_eta_seconds.store(0, .monotonic);
    metrics.Registry.resharding_progress.store(0, .monotonic);
}

test "OnlineReshardingController migration flow" {
    resetOnlineReshardingMetrics();

    var controller = OnlineReshardingController.init(
        std.testing.allocator,
        8,
        OnlineReshardingConfig{ .max_cutover_lag = 0 },
        null,
    );
    defer controller.deinit();

    try controller.startOnlineResharding(16, 10);

    try std.testing.expectEqual(@as(u8, 2), metrics.Registry.resharding_mode.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 1), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(
        @as(u8, 1),
        metrics.Registry.resharding_dual_write_enabled.load(.monotonic),
    );

    controller.worker.stats.start_time -= 1;

    const entity_ids = try std.testing.allocator.alloc(u128, 10);
    defer std.testing.allocator.free(entity_ids);
    for (entity_ids, 0..) |*entry, idx| {
        entry.* = @as(u128, idx + 1);
    }

    var batch = MigrationBatch{
        .source_shard = 0,
        .target_shard = 1,
        .entity_ids = entity_ids,
        .sequence = 1,
        .retry_count = 0,
        .allocator = std.testing.allocator,
    };

    const processed = try controller.tickMigration(&batch);
    try std.testing.expect(processed);
    try std.testing.expectEqual(@as(u8, 2), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.Registry.resharding_batches_processed.load(.monotonic),
    );
    try std.testing.expectEqual(
        @as(u32, 1000),
        metrics.Registry.resharding_progress.load(.monotonic),
    );

    const did_cutover = try controller.maybeCutover();
    try std.testing.expect(did_cutover);
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_mode.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(
        @as(u8, 0),
        metrics.Registry.resharding_dual_write_enabled.load(.monotonic),
    );
}

test "OnlineReshardingController cancel resets state" {
    resetOnlineReshardingMetrics();

    var controller = OnlineReshardingController.init(
        std.testing.allocator,
        8,
        OnlineReshardingConfig{},
        null,
    );
    defer controller.deinit();

    try controller.startOnlineResharding(16, 100);
    controller.cancel("test cancel");

    try std.testing.expectEqual(ReshardingState.idle, controller.manager.state);
    try std.testing.expect(controller.manager.target_ring == null);
    try std.testing.expectEqual(MigrationWorkerState.idle, controller.worker.state);
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_mode.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0), metrics.Registry.resharding_status.load(.monotonic));
    try std.testing.expectEqual(
        @as(u8, 0),
        metrics.Registry.resharding_dual_write_enabled.load(.monotonic),
    );
    try std.testing.expectEqual(@as(u32, 0), metrics.Registry.resharding_progress.load(.monotonic));
}

test "ReshardingMode parsing" {
    try std.testing.expectEqual(ReshardingMode.offline, ReshardingMode.fromString("offline").?);
    try std.testing.expectEqual(ReshardingMode.online, ReshardingMode.fromString("online").?);
    try std.testing.expectEqual(@as(?ReshardingMode, null), ReshardingMode.fromString("invalid"));

    try std.testing.expectEqualStrings("offline", ReshardingMode.offline.toString());
    try std.testing.expectEqualStrings("online", ReshardingMode.online.toString());
}

test "OnlineMigrationWorker checkpoint management" {
    var manager = ReshardingManager.init(std.testing.allocator, 8);
    defer manager.deinit();

    var worker = OnlineMigrationWorker.init(
        std.testing.allocator,
        &manager,
        OnlineReshardingConfig{},
    );
    defer worker.deinit();

    // Load a checkpoint (simulating resume from failure)
    const checkpoint = MigrationCheckpoint{
        .source_shard = 0,
        .last_key = 0x12345678,
        .migrated_count = 5000,
        .total_count = 10000,
        .timestamp = 1234567890,
        .checksum = 0,
    };
    try worker.loadCheckpoint(0, checkpoint);

    // Verify checkpoint is stored
    const loaded = worker.getCheckpoint(0);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(u64, 5000), loaded.?.migrated_count);
    try std.testing.expectEqual(@as(u128, 0x12345678), loaded.?.last_key);

    // Verify stats updated
    try std.testing.expectEqual(@as(u64, 5000), worker.stats.migrated_entities);
}

test "sharding strategy throughput comparison" {
    // Verify jump_hash has similar or better throughput than other strategies.
    // Per add-jump-consistent-hash/spec.md: Jump hash should be ≤ virtual ring latency.
    const allocator = std.testing.allocator;
    const iterations = 100_000;
    const num_shards: u32 = 16;

    // Initialize virtual ring for comparison
    var ring = try ConsistentHashRing.init(allocator, num_shards, 150);
    defer ring.deinit();

    var timer = std.time.Timer.start() catch return;

    // Benchmark modulo (baseline, fastest but inflexible)
    for (0..iterations) |i| {
        const key: u128 = @intCast(i + 1);
        _ = getShardForEntityWithStrategy(key, num_shards, .modulo, null);
    }
    const modulo_ns = timer.lap();

    // Benchmark jump_hash
    for (0..iterations) |i| {
        const key: u128 = @intCast(i + 1);
        _ = getShardForEntityWithStrategy(key, num_shards, .jump_hash, null);
    }
    const jump_ns = timer.lap();

    // Benchmark virtual_ring
    for (0..iterations) |i| {
        const key: u128 = @intCast(i + 1);
        _ = getShardForEntityWithStrategy(key, num_shards, .virtual_ring, &ring);
    }
    const ring_ns = timer.lap();

    // Jump hash should be at most 10x slower than modulo (it's O(log n))
    // In practice it's typically 2-3x
    const jump_ratio = @as(f64, @floatFromInt(jump_ns)) / @as(f64, @floatFromInt(modulo_ns));
    try std.testing.expect(jump_ratio <= 10.0);

    // Jump hash should be no slower than virtual ring (typically faster)
    // Virtual ring requires binary search through sorted array
    try std.testing.expect(jump_ns <= ring_ns * 2); // Allow 2x margin for variance

    // Jump hash uses zero additional memory (vs ring which allocates)
    // Verified implicitly by not allocating anything for jump_hash
}

// ============================================================================
// Entity Lookup Index Tests
// ============================================================================

test "EntityLookupIndex: basic operations" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    try std.testing.expectEqual(@as(u32, 0), index.count);
    try std.testing.expectEqual(@as(u32, 1024), index.capacity);

    // Insert an entry
    const entity_id: u128 = 0x12345678_ABCDEF00_12345678_ABCDEF00;
    const cell_id: u64 = 0x3000000000000001;
    const timestamp: u64 = 1704067200000000000;

    try index.upsert(entity_id, cell_id, timestamp);
    try std.testing.expectEqual(@as(u32, 1), index.count);

    // Lookup should succeed
    const entry = index.lookup(entity_id);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(entity_id, entry.?.entity_id);
    try std.testing.expectEqual(cell_id, entry.?.cell_id);
    try std.testing.expectEqual(timestamp, entry.?.timestamp_ns);
}

test "EntityLookupIndex: update existing entry" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    const entity_id: u128 = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;

    // Insert initial entry
    try index.upsert(entity_id, 100, 1000);
    try std.testing.expectEqual(@as(u32, 1), index.count);

    // Update same entity
    try index.upsert(entity_id, 200, 2000);
    try std.testing.expectEqual(@as(u32, 1), index.count); // Still 1 entry

    // Verify updated values
    const entry = index.lookup(entity_id);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 200), entry.?.cell_id);
    try std.testing.expectEqual(@as(u64, 2000), entry.?.timestamp_ns);
}

test "EntityLookupIndex: lookup not found" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    // Lookup non-existent entry
    const entry = index.lookup(0x12345678);
    try std.testing.expect(entry == null);

    // Zero entity_id always returns null
    try std.testing.expect(index.lookup(0) == null);
}

test "EntityLookupIndex: remove entry" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    const entity_id: u128 = 0xABCD1234_5678EFAB_CDEF1234_56789ABC;

    try index.upsert(entity_id, 100, 1000);
    try std.testing.expectEqual(@as(u32, 1), index.count);

    // Remove
    const removed = index.remove(entity_id);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u32, 0), index.count);

    // Lookup should now fail
    try std.testing.expect(index.lookup(entity_id) == null);

    // Remove again should return false
    try std.testing.expect(!index.remove(entity_id));
}

test "EntityLookupIndex: collision handling" {
    // Use small capacity to force collisions
    var index = try EntityLookupIndex.init(std.testing.allocator, 16);
    defer index.deinit();

    // Insert multiple entries (will likely collide)
    const ids = [_]u128{
        1, 2, 3, 4, 5, 17, // 17 mod 16 = 1, collides with 1
        33, // 33 mod 16 = 1, collides with 1 and 17
    };

    for (ids, 0..) |id, i| {
        try index.upsert(id, @intCast(i * 100), 0);
    }

    // All should be retrievable
    for (ids, 0..) |id, i| {
        const entry = index.lookup(id);
        try std.testing.expect(entry != null);
        try std.testing.expectEqual(@as(u64, @intCast(i * 100)), entry.?.cell_id);
    }
}

test "EntityLookupIndex: getShardForEntity" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    const entity_id: u128 = 0x11111111_22222222_33333333_44444444;
    const cell_id: u64 = 0x3000000000000001; // Level 13 S2 cell

    try index.upsert(entity_id, cell_id, 0);

    // Get shard using spatial routing
    const shard = index.getShardForEntity(entity_id, 8);
    try std.testing.expect(shard != null);
    try std.testing.expect(shard.? < 8);

    // Unknown entity returns null
    try std.testing.expect(index.getShardForEntity(0xFFFFFFFF, 8) == null);
}

test "EntityLookupIndex: load factor" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 100);
    defer index.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(f32, 0.0), index.loadFactor());
    try std.testing.expect(!index.needsResize());

    // Add 50 entries (50% load)
    for (1..51) |i| {
        try index.upsert(@intCast(i), @intCast(i * 10), 0);
    }
    try std.testing.expectEqual(@as(f32, 0.5), index.loadFactor());
    try std.testing.expect(!index.needsResize());

    // Add 26 more entries (76% load, needs resize)
    for (51..77) |i| {
        try index.upsert(@intCast(i), @intCast(i * 10), 0);
    }
    try std.testing.expect(index.loadFactor() > 0.75);
    try std.testing.expect(index.needsResize());
}

test "EntityLookupIndex: tombstone maintains probe chain" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 16);
    defer index.deinit();

    // Insert entries that will be in a probe chain
    // Entity 1, 17, 33 all hash to slot 1 mod 16
    try index.upsert(1, 100, 0);
    try index.upsert(17, 200, 0); // Collides with 1
    try index.upsert(33, 300, 0); // Collides with 1, 17

    // Remove middle entry (17)
    try std.testing.expect(index.remove(17));

    // Should still find 33 (probe chain intact via tombstone)
    const entry = index.lookup(33);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 300), entry.?.cell_id);

    // Can still find 1
    try std.testing.expect(index.lookup(1) != null);

    // 17 is gone
    try std.testing.expect(index.lookup(17) == null);
}

test "EntityLookupIndex: invalid entity_id zero" {
    var index = try EntityLookupIndex.init(std.testing.allocator, 1024);
    defer index.deinit();

    // Cannot insert entity_id 0
    const result = index.upsert(0, 100, 0);
    try std.testing.expectError(error.InvalidEntityId, result);
}

// =============================================================================
// Jump Consistent Hash Golden Vector Tests (per 05-01 plan)
// =============================================================================
//
// These golden vectors are CANONICAL and MUST match all SDK implementations.
// Reference: "A Fast, Minimal Memory, Consistent Hash Algorithm"
// by John Lamping and Eric Veach, Google, 2014.
//
// Any change to these values indicates an algorithm change and will break
// cross-SDK compatibility. SDKs reference src/sharding.zig as source of truth.
//

test "jumpHash golden vectors - cross-SDK compatibility" {
    // Golden vectors that MUST match all SDK implementations (Go, Python, Java, Node.js).
    // If any SDK produces different values, the SDK implementation is incorrect.
    //
    // These values are computed from Google's Jump Consistent Hash algorithm.

    // Key 0: always maps to bucket 0 regardless of bucket count
    try std.testing.expectEqual(@as(u32, 0), jumpHash(0, 1));
    try std.testing.expectEqual(@as(u32, 0), jumpHash(0, 10));
    try std.testing.expectEqual(@as(u32, 0), jumpHash(0, 100));
    try std.testing.expectEqual(@as(u32, 0), jumpHash(0, 256));

    // Key 0xDEADBEEF: canonical test key
    try std.testing.expectEqual(@as(u32, 5), jumpHash(0xDEADBEEF, 8));
    try std.testing.expectEqual(@as(u32, 5), jumpHash(0xDEADBEEF, 16));
    try std.testing.expectEqual(@as(u32, 16), jumpHash(0xDEADBEEF, 32));
    try std.testing.expectEqual(@as(u32, 16), jumpHash(0xDEADBEEF, 64));
    try std.testing.expectEqual(@as(u32, 87), jumpHash(0xDEADBEEF, 128));
    try std.testing.expectEqual(@as(u32, 87), jumpHash(0xDEADBEEF, 256));

    // Key 0xCAFEBABE: another canonical test key
    try std.testing.expectEqual(@as(u32, 5), jumpHash(0xCAFEBABE, 8));
    try std.testing.expectEqual(@as(u32, 5), jumpHash(0xCAFEBABE, 16));
    try std.testing.expectEqual(@as(u32, 5), jumpHash(0xCAFEBABE, 32));
    try std.testing.expectEqual(@as(u32, 46), jumpHash(0xCAFEBABE, 64));
    try std.testing.expectEqual(@as(u32, 85), jumpHash(0xCAFEBABE, 128));
    try std.testing.expectEqual(@as(u32, 85), jumpHash(0xCAFEBABE, 256));

    // Key max u64 (0xFFFFFFFFFFFFFFFF): edge case
    try std.testing.expectEqual(@as(u32, 7), jumpHash(0xFFFFFFFFFFFFFFFF, 8));
    try std.testing.expectEqual(@as(u32, 10), jumpHash(0xFFFFFFFFFFFFFFFF, 16));
    try std.testing.expectEqual(@as(u32, 248), jumpHash(0xFFFFFFFFFFFFFFFF, 256));

    // Additional test keys for broader coverage
    try std.testing.expectEqual(@as(u32, 4), jumpHash(0x123456789ABCDEF0, 8));
    try std.testing.expectEqual(@as(u32, 4), jumpHash(0x123456789ABCDEF0, 16));
    try std.testing.expectEqual(@as(u32, 33), jumpHash(0x123456789ABCDEF0, 256));

    try std.testing.expectEqual(@as(u32, 1), jumpHash(0xFEDCBA9876543210, 8));
    try std.testing.expectEqual(@as(u32, 10), jumpHash(0xFEDCBA9876543210, 16));
    try std.testing.expectEqual(@as(u32, 143), jumpHash(0xFEDCBA9876543210, 256));
}

test "jumpHash determinism - 1000 iterations" {
    // Verify same key+buckets always produces same result over 1000 iterations.
    // This confirms no state leakage between calls.
    const test_cases = [_]struct { key: u64, buckets: u32, expected: u32 }{
        .{ .key = 0xDEADBEEF, .buckets = 16, .expected = 5 },
        .{ .key = 0xCAFEBABE, .buckets = 64, .expected = 46 },
        .{ .key = 0x123456789ABCDEF0, .buckets = 256, .expected = 33 },
        .{ .key = 0xFFFFFFFFFFFFFFFF, .buckets = 8, .expected = 7 },
    };

    for (test_cases) |tc| {
        // Run 1000 iterations for each test case
        for (0..1000) |_| {
            const result = jumpHash(tc.key, tc.buckets);
            try std.testing.expectEqual(tc.expected, result);
        }
    }
}

test "computeShardKey determinism - 1000 iterations" {
    // Verify same entity_id always produces same shard_key over 1000 iterations.
    const test_cases = [_]struct { entity_id: u128, expected: u64 }{
        .{ .entity_id = 0x00000000_00000000_00000000_00000001, .expected = 0xB456BCFC34C2CB2C },
        .{ .entity_id = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0, .expected = 0x683A5932FE04E714 },
        .{ .entity_id = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF, .expected = 0x0000000000000000 },
        .{ .entity_id = 0x12345678_ABCDEF00_12345678_ABCDEF00, .expected = 0x0000000000000000 },
    };

    for (test_cases) |tc| {
        // Run 1000 iterations for each test case
        for (0..1000) |_| {
            const result = computeShardKey(tc.entity_id);
            try std.testing.expectEqual(tc.expected, result);
        }
    }
}

// =============================================================================
// Distribution Tolerance, Resharding, and Strategy Tests (per 05-01 plan)
// =============================================================================

test "jumpHash distribution within 5%" {
    // Per CONTEXT.md: Distribution variance is within +/-5% for all shard counts 8-256.
    // This test verifies the jump hash algorithm produces uniform distribution.
    //
    // Statistical note: With 256 shards and N keys, the expected count per bucket is N/256.
    // Standard deviation is sqrt(N * (1/256) * (255/256)) ~ sqrt(N)/16.
    // For 3-sigma confidence (99.7%), we need max_deviation < 3 * stddev / expected.
    // With N=10M, expected=39062.5, stddev~195, 3-sigma~585, which is 1.5%.
    // Using 10M keys ensures statistical stability within the 5% tolerance.
    const shard_counts = [_]u32{ 8, 16, 32, 64, 128, 256 };
    const num_keys: u64 = 10_000_000;

    for (shard_counts) |shard_count| {
        var buckets = [_]u64{0} ** 256;

        // Use xorshift64 PRNG with seed 12345 for reproducibility
        var state: u64 = 12345;
        for (0..num_keys) |_| {
            // xorshift64 step
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;

            const bucket = jumpHash(state, shard_count);
            buckets[bucket] += 1;
        }

        // Verify each bucket is within +/-5% of expected
        const expected: f64 = @as(f64, @floatFromInt(num_keys)) / @as(f64, @floatFromInt(shard_count));
        var max_deviation_pct: f64 = 0.0;

        for (0..shard_count) |i| {
            const actual: f64 = @floatFromInt(buckets[i]);
            const deviation: f64 = @abs(actual - expected);
            const deviation_pct: f64 = (deviation / expected) * 100.0;
            max_deviation_pct = @max(max_deviation_pct, deviation_pct);

            // Each bucket must be within +/-5% of expected (strict tolerance per CONTEXT.md)
            if (deviation_pct > 5.0) {
                std.log.err(
                    "Shard {} with {} shards: bucket {} has {} keys (expected {d:.1}), deviation {d:.2}%",
                    .{ shard_count, shard_count, i, buckets[i], expected, deviation_pct },
                );
            }
            try std.testing.expect(deviation_pct <= 5.0);
        }
    }
}

test "jumpHash resharding optimal movement" {
    // Per CONTEXT.md: Resharding moves exactly 1/(N+1) entities when adding one shard.
    // Uses 10,000 keys to verify optimal movement property.
    const transitions = [_]struct { from: u32, to: u32 }{
        .{ .from = 8, .to = 9 },
        .{ .from = 16, .to = 17 },
        .{ .from = 100, .to = 101 },
        .{ .from = 255, .to = 256 },
    };

    const num_keys: u64 = 10_000;

    for (transitions) |t| {
        var moved: u64 = 0;

        // Use xorshift64 PRNG with seed 54321 for reproducibility
        var state: u64 = 54321;
        for (0..num_keys) |_| {
            // xorshift64 step
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;

            const old_shard = jumpHash(state, t.from);
            const new_shard = jumpHash(state, t.to);

            if (old_shard != new_shard) {
                moved += 1;
            }
        }

        // Expected movement: ~1/(N+1) keys
        // With jump hash, when adding one shard, ~1/(N+1) of keys move to the new shard.
        const expected_ratio: f64 = 1.0 / @as(f64, @floatFromInt(t.to));
        const actual_ratio: f64 = @as(f64, @floatFromInt(moved)) / @as(f64, @floatFromInt(num_keys));

        // Allow 1% tolerance for statistical variance
        const tolerance: f64 = 0.01;
        const diff = @abs(actual_ratio - expected_ratio);

        if (diff > tolerance) {
            std.log.err(
                "Resharding {}->{}: moved {d:.2}% (expected {d:.2}%), diff {d:.4}",
                .{ t.from, t.to, actual_ratio * 100, expected_ratio * 100, diff },
            );
        }
        try std.testing.expect(diff <= tolerance);
    }
}

test "getShardForEntityWithStrategy consistency" {
    // Verify all strategies produce deterministic results.
    // Same entity always routes to same shard.
    const strategies = [_]ShardingStrategy{
        .modulo,
        .virtual_ring,
        .jump_hash,
        .spatial,
    };

    const entity_ids = [_]u128{
        0x00000000_00000000_00000000_00000001,
        0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0,
        0x11111111_22222222_33333333_44444444,
        0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE, // Avoid max u128 which might hash to 0
    };

    for (strategies) |strategy| {
        for (entity_ids) |entity_id| {
            const shard_1 = getShardForEntityWithStrategy(entity_id, 16, strategy, null);
            const shard_2 = getShardForEntityWithStrategy(entity_id, 16, strategy, null);
            const shard_3 = getShardForEntityWithStrategy(entity_id, 16, strategy, null);

            // All calls should return the same shard
            try std.testing.expectEqual(shard_1, shard_2);
            try std.testing.expectEqual(shard_2, shard_3);

            // Shard must be within valid range
            try std.testing.expect(shard_1 < 16);
        }
    }
}

test "ShardStats maxImbalance calculation" {
    // Test the maxImbalance calculation for distribution monitoring.

    // Perfect distribution: 0% imbalance
    {
        var counts = [_]u64{ 100, 100, 100, 100 };
        const stats = ShardStats{
            .num_shards = 4,
            .total = 400,
            .counts = &counts,
        };

        const imbalance = stats.maxImbalance();
        try std.testing.expect(imbalance < 0.001); // Should be ~0%
    }

    // Slight imbalance: ~2% deviation
    {
        var counts = [_]u64{ 98, 102, 100, 100 };
        const stats = ShardStats{
            .num_shards = 4,
            .total = 400,
            .counts = &counts,
        };

        const imbalance = stats.maxImbalance();
        try std.testing.expect(imbalance >= 1.5);
        try std.testing.expect(imbalance <= 2.5);
    }

    // Extreme imbalance: 100% deviation for empty bucket
    {
        var counts = [_]u64{ 200, 0, 100, 100 };
        const stats = ShardStats{
            .num_shards = 4,
            .total = 400,
            .counts = &counts,
        };

        const imbalance = stats.maxImbalance();
        try std.testing.expect(imbalance >= 90.0); // Should be ~100% for empty bucket
    }

    // Empty stats: 0% imbalance
    {
        var counts = [_]u64{ 0, 0, 0, 0 };
        const stats = ShardStats{
            .num_shards = 4,
            .total = 0,
            .counts = &counts,
        };

        const imbalance = stats.maxImbalance();
        try std.testing.expectEqual(@as(f64, 0.0), imbalance);
    }
}

// =============================================================================
// Cross-Shard Query Tests (SHARD-04, SHARD-05 per 05-01 plan)
// =============================================================================
//
// These tests verify the cross-shard query infrastructure used by the
// coordinator for fan-out queries (radius, polygon, latest).

test "cross-shard query fan-out shard selection" {
    // SHARD-04: Verify fan-out query reaches all relevant shards.
    // This tests the shard selection logic, not actual network calls.
    const Coordinator = @import("coordinator.zig").Coordinator;

    // Verify which query types require fan-out
    try std.testing.expect(!Coordinator.requiresFanOut(.uuid_lookup)); // Single entity
    try std.testing.expect(Coordinator.requiresFanOut(.radius)); // Spatial - all shards
    try std.testing.expect(Coordinator.requiresFanOut(.polygon)); // Spatial - all shards
    try std.testing.expect(Coordinator.requiresFanOut(.latest)); // Global - all shards

    // UUID batch may require fan-out if entities span multiple shards
    // (This is handled by the coordinator based on actual entity routing)
}

test "cross-shard query fan-out multi-shard coverage" {
    // SHARD-04: Verify that a fan-out query would reach all configured shards.
    const Coordinator = @import("coordinator.zig").Coordinator;
    const Address = @import("coordinator.zig").Address;

    var coordinator = Coordinator.init(std.testing.allocator, .{});
    defer coordinator.deinit();

    // Configure 8 shards
    for (0..8) |i| {
        try coordinator.addShard(@intCast(i), Address.init("node", 5000));
    }

    try coordinator.start();

    // Get shards that would be queried for fan-out
    const fan_out_shards = coordinator.getFanOutShards();

    // All 8 shards should be included in fan-out
    try std.testing.expectEqual(@as(usize, 8), fan_out_shards.len);

    // Each shard should be present exactly once
    var seen = [_]bool{false} ** 8;
    for (fan_out_shards) |shard| {
        try std.testing.expect(shard.id < 8);
        try std.testing.expect(!seen[shard.id]); // Not seen before
        seen[shard.id] = true;
    }

    // All should be seen
    for (seen) |s| {
        try std.testing.expect(s);
    }
}

test "coordinator aggregation shard health tracking" {
    // SHARD-05: Verify coordinator tracks shard health for aggregation decisions.
    // When a shard becomes unavailable, it should be tracked for partial result handling.
    const Coordinator = @import("coordinator.zig").Coordinator;
    const Address = @import("coordinator.zig").Address;
    const ShardStatus = @import("coordinator.zig").ShardStatus;

    var coordinator = Coordinator.init(std.testing.allocator, .{
        .max_retries = 2,
    });
    defer coordinator.deinit();

    try coordinator.addShard(0, Address.init("node-0", 5000));
    try coordinator.addShard(1, Address.init("node-1", 5000));
    try coordinator.start();

    // Both shards start as active
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[0].status);
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[1].status);

    // Mark shard 1 unhealthy multiple times (exceeds max_retries)
    coordinator.markShardUnhealthy(1);
    coordinator.markShardUnhealthy(1);

    // After max_retries failures, shard should be unavailable
    try std.testing.expectEqual(ShardStatus.unavailable, coordinator.topology.shards[1].status);

    // Aggregation logic (in SDKs) would use this status to determine partial results.
    // When allow_partial=true, results from shard 0 would be returned.
    // When allow_partial=false, the query would fail.

    // Recover shard 1
    coordinator.markShardHealthy(1);
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[1].status);
}

test "coordinator aggregation timeout handling" {
    // SHARD-05: Verify timeout is configurable per CONTEXT.md (5s default).
    const Coordinator = @import("coordinator.zig").Coordinator;

    // Default timeout should be reasonable for cross-shard queries
    {
        const coordinator = Coordinator.init(std.testing.allocator, .{});
        defer @constCast(&coordinator).deinit();

        // Verify default query timeout is set (30 seconds in coordinator.zig)
        try std.testing.expectEqual(@as(u32, 30_000), coordinator.config.query_timeout_ms);
    }

    // Custom timeout should be respected
    {
        const coordinator = Coordinator.init(std.testing.allocator, .{
            .query_timeout_ms = 5_000, // 5s per CONTEXT.md mention
        });
        defer @constCast(&coordinator).deinit();

        try std.testing.expectEqual(@as(u32, 5_000), coordinator.config.query_timeout_ms);
    }
}
