// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Block-level deduplication for LSM storage optimization.
//!
//! Geospatial trajectory data often contains repeated locations (e.g., parked vehicles,
//! delivery routes with common stops). Block-level deduplication detects these patterns
//! via content hashing and references existing blocks instead of storing duplicates.
//! This can reduce storage by 10-30% for trajectory-heavy workloads.
//!
//! Design decisions:
//! - Uses XxHash64 from Zig stdlib (extremely fast, no external dependency)
//! - Per-level index to bound memory usage
//! - LRU eviction to stay within memory limits
//! - Reference counting for correct block lifecycle management
//!
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

/// Configuration for block deduplication.
pub const DedupConfig = struct {
    /// Whether deduplication is enabled
    enabled: bool = true,
    /// Maximum memory for dedup index (in bytes)
    /// Per-level to prevent memory explosion
    index_memory_limit: usize = 64 * 1024 * 1024, // 64 MiB
    /// Minimum block size to consider for deduplication
    /// Small blocks have overhead that may not justify dedup
    min_block_size: usize = 4096,

    /// Create config from cluster configuration values
    pub fn fromClusterConfig(
        enabled: bool,
        index_memory_mb: u32,
        min_block_size: u32,
    ) DedupConfig {
        return .{
            .enabled = enabled,
            .index_memory_limit = @as(usize, index_memory_mb) * 1024 * 1024,
            .min_block_size = min_block_size,
        };
    }
};

/// Entry in the deduplication index tracking a unique block.
pub const DedupEntry = struct {
    /// Address of the block in storage
    block_address: u64,
    /// Number of references to this block
    reference_count: u32,
    /// Tick when this entry was last accessed (for LRU eviction)
    last_access_tick: u32,
};

/// Result from lookup_or_insert operation.
pub const LookupResult = union(enum) {
    /// Duplicate found - use this existing address instead
    duplicate: u64,
    /// No duplicate - this is a new unique block
    unique: void,
};

/// Block-level deduplication index.
///
/// Maintains a hash table mapping content hashes to block addresses.
/// Uses LRU eviction to stay within configured memory limits.
pub const DedupIndex = struct {
    /// Hash -> entry mapping (u64 hash from std.hash.XxHash64)
    entries: std.AutoHashMap(u64, DedupEntry),
    /// Current estimated memory usage
    current_memory: usize,
    /// Configuration
    config: DedupConfig,
    /// Current tick for LRU tracking (increments on each access)
    current_tick: u32,
    /// Allocator for the hash map
    allocator: mem.Allocator,

    // Metrics
    /// Total blocks checked for deduplication
    blocks_checked: u64,
    /// Duplicates found and deduplicated
    duplicates_found: u64,
    /// Bytes saved by deduplication
    bytes_saved: u64,
    /// Number of LRU evictions performed
    evictions: u64,

    /// Size of each entry in memory (approximate)
    const entry_size: usize = @sizeOf(u64) + @sizeOf(DedupEntry) + 32; // hash + entry + hashmap overhead

    /// Initialize a new dedup index.
    pub fn init(allocator: mem.Allocator, config: DedupConfig) DedupIndex {
        return .{
            .entries = std.AutoHashMap(u64, DedupEntry).init(allocator),
            .current_memory = 0,
            .config = config,
            .current_tick = 0,
            .allocator = allocator,
            .blocks_checked = 0,
            .duplicates_found = 0,
            .bytes_saved = 0,
            .evictions = 0,
        };
    }

    /// Deinitialize the dedup index, freeing all memory.
    pub fn deinit(self: *DedupIndex) void {
        self.entries.deinit();
        self.* = undefined;
    }

    /// Look up a block by content hash, or insert if not found.
    ///
    /// Parameters:
    /// - block_content: The block data to hash and look up
    /// - new_address: The address to use if this is a new unique block
    ///
    /// Returns:
    /// - .duplicate with existing address if a duplicate was found
    /// - .unique if this is a new block (inserted into index)
    pub fn lookup_or_insert(
        self: *DedupIndex,
        block_content: []const u8,
        new_address: u64,
    ) LookupResult {
        if (!self.config.enabled) {
            return .unique;
        }

        // Skip small blocks
        if (block_content.len < self.config.min_block_size) {
            return .unique;
        }

        self.blocks_checked += 1;
        self.current_tick +|= 1; // Saturating add to prevent overflow

        const hash = compute_hash(block_content);

        // Check if we already have this block
        if (self.entries.getPtr(hash)) |entry| {
            // Duplicate found!
            entry.reference_count += 1;
            entry.last_access_tick = self.current_tick;
            self.duplicates_found += 1;
            self.bytes_saved += block_content.len;
            return .{ .duplicate = entry.block_address };
        }

        // New unique block - check memory limit before inserting
        if (self.current_memory + entry_size > self.config.index_memory_limit) {
            self.evict_lru();
        }

        // Insert new entry
        self.entries.put(hash, .{
            .block_address = new_address,
            .reference_count = 1,
            .last_access_tick = self.current_tick,
        }) catch {
            // On allocation failure, skip dedup for this block
            return .unique;
        };

        self.current_memory += entry_size;
        return .unique;
    }

    /// Decrement reference count for a block.
    /// Call this when a block is deleted or compacted away.
    ///
    /// Parameters:
    /// - block_content: The block data (used to compute hash)
    ///
    /// Returns: true if entry was removed (refcount reached 0), false otherwise
    pub fn decrement_reference(self: *DedupIndex, block_content: []const u8) bool {
        if (!self.config.enabled) {
            return false;
        }

        if (block_content.len < self.config.min_block_size) {
            return false;
        }

        const hash = compute_hash(block_content);

        if (self.entries.getPtr(hash)) |entry| {
            if (entry.reference_count > 1) {
                entry.reference_count -= 1;
                return false;
            } else {
                // Remove entry when refcount reaches 0
                _ = self.entries.remove(hash);
                self.current_memory -|= entry_size;
                return true;
            }
        }

        return false;
    }

    /// Evict least recently used entries to free memory.
    /// Called automatically when memory limit is exceeded.
    fn evict_lru(self: *DedupIndex) void {
        // Find entries with oldest access tick
        // Evict entries until we're under 90% of memory limit
        const target_memory = (self.config.index_memory_limit * 90) / 100;

        while (self.current_memory > target_memory and self.entries.count() > 0) {
            // Find the LRU entry (oldest last_access_tick with refcount == 1)
            var oldest_hash: ?u64 = null;
            var oldest_tick: u32 = std.math.maxInt(u32);

            var iter = self.entries.iterator();
            while (iter.next()) |kv| {
                // Only evict entries with refcount 1 (not actively referenced)
                if (kv.value_ptr.reference_count == 1 and
                    kv.value_ptr.last_access_tick < oldest_tick)
                {
                    oldest_tick = kv.value_ptr.last_access_tick;
                    oldest_hash = kv.key_ptr.*;
                }
            }

            if (oldest_hash) |hash| {
                _ = self.entries.remove(hash);
                self.current_memory -|= entry_size;
                self.evictions += 1;
            } else {
                // No evictable entries (all have refcount > 1)
                break;
            }
        }
    }

    /// Get current metrics snapshot.
    pub fn getMetrics(self: *const DedupIndex) Metrics {
        return .{
            .blocks_checked = self.blocks_checked,
            .duplicates_found = self.duplicates_found,
            .bytes_saved = self.bytes_saved,
            .evictions = self.evictions,
            .index_entries = self.entries.count(),
            .index_memory = self.current_memory,
        };
    }

    /// Reset all metrics to zero.
    pub fn resetMetrics(self: *DedupIndex) void {
        self.blocks_checked = 0;
        self.duplicates_found = 0;
        self.bytes_saved = 0;
        self.evictions = 0;
    }
};

/// Deduplication metrics snapshot.
pub const Metrics = struct {
    /// Total blocks checked for deduplication
    blocks_checked: u64,
    /// Duplicates found and deduplicated
    duplicates_found: u64,
    /// Bytes saved by deduplication
    bytes_saved: u64,
    /// Number of LRU evictions performed
    evictions: u64,
    /// Current number of entries in the index
    index_entries: usize,
    /// Current memory usage of the index
    index_memory: usize,

    /// Calculate deduplication ratio (0.0 to 1.0)
    pub fn dedup_ratio(self: Metrics) f64 {
        if (self.blocks_checked == 0) return 0.0;
        return @as(f64, @floatFromInt(self.duplicates_found)) /
            @as(f64, @floatFromInt(self.blocks_checked));
    }
};

/// Compute content hash for block deduplication.
/// Uses std.hash.XxHash64 from Zig stdlib (built-in, extremely fast).
/// Collision probability with 64-bit hash is negligible for our use case (1 in 2^64).
pub fn compute_hash(block_content: []const u8) u64 {
    return std.hash.XxHash64.hash(0, block_content);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "dedup: basic duplicate detection" {
    const allocator = std.testing.allocator;

    var index = DedupIndex.init(allocator, .{});
    defer index.deinit();

    // Create a block with repeated content
    const block1 = try allocator.alloc(u8, 8192);
    defer allocator.free(block1);
    @memset(block1, 0xAB);

    // First insert - should be unique
    const result1 = index.lookup_or_insert(block1, 100);
    try std.testing.expectEqual(LookupResult.unique, result1);

    // Second insert of same content - should find duplicate
    const result2 = index.lookup_or_insert(block1, 200);
    try std.testing.expect(result2 == .duplicate);
    try std.testing.expectEqual(@as(u64, 100), result2.duplicate);

    // Verify metrics
    const metrics = index.getMetrics();
    try std.testing.expectEqual(@as(u64, 2), metrics.blocks_checked);
    try std.testing.expectEqual(@as(u64, 1), metrics.duplicates_found);
    try std.testing.expectEqual(@as(u64, 8192), metrics.bytes_saved);
}

test "dedup: different content is unique" {
    const allocator = std.testing.allocator;

    var index = DedupIndex.init(allocator, .{});
    defer index.deinit();

    const block1 = try allocator.alloc(u8, 8192);
    defer allocator.free(block1);
    @memset(block1, 0xAB);

    const block2 = try allocator.alloc(u8, 8192);
    defer allocator.free(block2);
    @memset(block2, 0xCD);

    const result1 = index.lookup_or_insert(block1, 100);
    try std.testing.expect(result1 == .unique);

    const result2 = index.lookup_or_insert(block2, 200);
    try std.testing.expect(result2 == .unique);

    try std.testing.expectEqual(@as(u64, 2), index.getMetrics().blocks_checked);
    try std.testing.expectEqual(@as(u64, 0), index.getMetrics().duplicates_found);
}

test "dedup: small blocks skipped" {
    const allocator = std.testing.allocator;

    var index = DedupIndex.init(allocator, .{ .min_block_size = 4096 });
    defer index.deinit();

    // Small block (below min_block_size)
    const small_block = try allocator.alloc(u8, 1024);
    defer allocator.free(small_block);
    @memset(small_block, 0xAB);

    const result1 = index.lookup_or_insert(small_block, 100);
    try std.testing.expect(result1 == .unique);

    // Same content again - still unique because too small
    const result2 = index.lookup_or_insert(small_block, 200);
    try std.testing.expect(result2 == .unique);

    // No dedup should have happened
    try std.testing.expectEqual(@as(u64, 0), index.getMetrics().blocks_checked);
}

test "dedup: disabled config" {
    const allocator = std.testing.allocator;

    var index = DedupIndex.init(allocator, .{ .enabled = false });
    defer index.deinit();

    const block = try allocator.alloc(u8, 8192);
    defer allocator.free(block);
    @memset(block, 0xAB);

    const result1 = index.lookup_or_insert(block, 100);
    try std.testing.expect(result1 == .unique);

    // Should not find duplicate when disabled
    const result2 = index.lookup_or_insert(block, 200);
    try std.testing.expect(result2 == .unique);

    try std.testing.expectEqual(@as(u64, 0), index.getMetrics().blocks_checked);
}

test "dedup: reference counting" {
    const allocator = std.testing.allocator;

    var index = DedupIndex.init(allocator, .{});
    defer index.deinit();

    const block = try allocator.alloc(u8, 8192);
    defer allocator.free(block);
    @memset(block, 0xAB);

    // Insert once
    _ = index.lookup_or_insert(block, 100);
    try std.testing.expectEqual(@as(usize, 1), index.entries.count());

    // Insert again (increments refcount)
    _ = index.lookup_or_insert(block, 200);

    // Decrement once - should not remove
    const removed1 = index.decrement_reference(block);
    try std.testing.expect(!removed1);
    try std.testing.expectEqual(@as(usize, 1), index.entries.count());

    // Decrement again - should remove
    const removed2 = index.decrement_reference(block);
    try std.testing.expect(removed2);
    try std.testing.expectEqual(@as(usize, 0), index.entries.count());
}

test "dedup: LRU eviction" {
    const allocator = std.testing.allocator;

    // Create index with very small memory limit to force eviction
    const entry_size = DedupIndex.entry_size;
    var index = DedupIndex.init(allocator, .{
        .index_memory_limit = entry_size * 3, // Only room for ~2-3 entries
        .min_block_size = 100,
    });
    defer index.deinit();

    // Create multiple unique blocks
    var blocks: [5][]u8 = undefined;
    for (&blocks, 0..) |*block, i| {
        block.* = try allocator.alloc(u8, 128);
        @memset(block.*, @intCast(i + 1));
    }
    defer for (&blocks) |block| allocator.free(block);

    // Insert all blocks
    for (&blocks, 0..) |block, i| {
        _ = index.lookup_or_insert(block, @intCast(100 + i));
    }

    // Should have evicted some entries
    try std.testing.expect(index.getMetrics().evictions > 0);
    try std.testing.expect(index.current_memory <= index.config.index_memory_limit);
}

test "dedup: compute_hash consistency" {
    const data1 = "Hello, World!";
    const data2 = "Hello, World!";
    const data3 = "Different data";

    const hash1 = compute_hash(data1);
    const hash2 = compute_hash(data2);
    const hash3 = compute_hash(data3);

    // Same content should produce same hash
    try std.testing.expectEqual(hash1, hash2);

    // Different content should produce different hash
    try std.testing.expect(hash1 != hash3);
}

test "dedup: metrics dedup_ratio" {
    var metrics = Metrics{
        .blocks_checked = 100,
        .duplicates_found = 30,
        .bytes_saved = 30 * 8192,
        .evictions = 0,
        .index_entries = 70,
        .index_memory = 70 * 64,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 0.3), metrics.dedup_ratio(), 0.001);

    // Test zero division protection
    metrics.blocks_checked = 0;
    metrics.duplicates_found = 0;
    try std.testing.expectEqual(@as(f64, 0.0), metrics.dedup_ratio());
}

test "dedup: config from cluster config" {
    const config = DedupConfig.fromClusterConfig(true, 128, 8192);

    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), config.index_memory_limit);
    try std.testing.expectEqual(@as(usize, 8192), config.min_block_size);
}
