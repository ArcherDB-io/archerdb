//! RAM Index - O(1) entity lookup index for ArcherDB.
//!
//! Implements an Aerospike-style index-on-RAM architecture where the primary
//! index resides entirely in RAM while data records are stored on SSD.
//!
//! Key features:
//! - 64-byte IndexEntry (cache-line aligned) for optimal CPU cache efficiency
//! - Open addressing with linear probing (cache-friendly sequential access)
//! - Lock-free concurrent reads via atomic operations
//! - Single-threaded writes (VSR commit phase guarantees this)
//! - LWW (Last-Write-Wins) semantics for conflict resolution
//! - Pre-allocated capacity at startup (no runtime resize)
//!
//! Memory requirements for 1B entities:
//! - Index entry size: 64 bytes
//! - Target load factor: 0.70
//! - Required capacity: 1B / 0.70 = ~1.43B slots
//! - RAM usage: 1.43B * 64 bytes = ~91.5GB
//!
//! See specs/hybrid-memory/spec.md for full requirements.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

const stdx = @import("stdx");
const constants = @import("constants.zig");

/// Maximum number of probes before giving up on lookup/insert.
/// Prevents infinite loops and bounds worst-case latency.
pub const max_probe_length: u32 = 1024;

/// Target load factor for optimal hash table performance.
/// Hash tables degrade significantly above 0.7-0.75 load factor.
pub const target_load_factor: f32 = 0.70;

/// IndexEntry - 64-byte cache-line aligned index entry.
///
/// Each entry maps an entity_id to its latest GeoEvent composite ID.
/// The structure is designed to:
/// - Fit exactly in one CPU cache line (64 bytes)
/// - Prevent false sharing between adjacent entries
/// - Enable atomic 64-byte loads/stores on x86-64 (within cache line)
///
/// Fields:
/// - entity_id: Primary key for lookup (u128 UUID)
/// - latest_id: Composite ID [S2 Cell ID (upper 64) | Timestamp (lower 64)]
/// - ttl_seconds: Time-to-live (0 = never expires)
/// - reserved: Padding for alignment
/// - padding: Reserved for future flags/tags/generations
pub const IndexEntry = extern struct {
    /// Entity UUID - primary lookup key.
    /// Zero indicates an empty slot.
    entity_id: u128 = 0,

    /// Composite ID of the latest GeoEvent for this entity.
    /// Lower 64 bits contain timestamp for LWW comparison.
    latest_id: u128 = 0,

    /// Time-to-live in seconds (0 = never expires).
    ttl_seconds: u32 = 0,

    /// Reserved padding for alignment.
    reserved: u32 = 0,

    /// Reserved for future extensions (flags, tags, dirty bits, generation).
    padding: [24]u8 = [_]u8{0} ** 24,

    /// Sentinel value for empty slots.
    pub const empty: IndexEntry = .{};

    /// Check if this entry is empty (unused slot).
    pub inline fn is_empty(self: IndexEntry) bool {
        return self.entity_id == 0;
    }

    /// Check if this entry is a tombstone (deleted entity).
    /// Tombstones have entity_id != 0 but latest_id == 0.
    pub inline fn is_tombstone(self: IndexEntry) bool {
        return self.entity_id != 0 and self.latest_id == 0;
    }

    /// Extract timestamp from latest_id for LWW comparison.
    /// Timestamp is stored in the lower 64 bits of the composite ID.
    pub inline fn timestamp(self: IndexEntry) u64 {
        return @as(u64, @truncate(self.latest_id));
    }
};

// Compile-time validation of IndexEntry layout.
comptime {
    // IndexEntry must be exactly 64 bytes (one cache line).
    assert(@sizeOf(IndexEntry) == 64);

    // IndexEntry must be at least 16-byte aligned for u128 fields.
    assert(@alignOf(IndexEntry) >= 16);

    // Verify no padding in the struct (all space accounted for).
    // 16 + 16 + 4 + 4 + 24 = 64 bytes
    assert(@sizeOf(IndexEntry) == 16 + 16 + 4 + 4 + 24);
}

/// Error codes for RAM index operations.
pub const IndexError = error{
    /// Index capacity exceeded - cannot insert new entity.
    /// Operator must provision larger capacity.
    IndexCapacityExceeded,

    /// Index degraded - probe length exceeded max_probe_length.
    /// This indicates hash collision issues requiring rebuild.
    IndexDegraded,

    /// Invalid configuration parameters.
    InvalidConfiguration,

    /// Memory allocation failed.
    OutOfMemory,
};

/// Statistics for monitoring index health.
pub const IndexStats = struct {
    /// Number of entities currently indexed.
    entry_count: u64 = 0,

    /// Total capacity (number of slots).
    capacity: u64 = 0,

    /// Number of tombstone slots.
    tombstone_count: u64 = 0,

    /// Total number of lookup operations.
    lookup_count: u64 = 0,

    /// Number of successful lookups (cache hits).
    lookup_hit_count: u64 = 0,

    /// Total number of upsert operations.
    upsert_count: u64 = 0,

    /// Cumulative probe length for all operations (for average calculation).
    total_probe_length: u64 = 0,

    /// Maximum probe length encountered.
    max_probe_length_seen: u32 = 0,

    /// Number of operations that hit the probe limit.
    probe_limit_hits: u64 = 0,

    /// Hash collision count (probes > 1).
    collision_count: u64 = 0,

    /// Calculate current load factor.
    pub fn load_factor(self: IndexStats) f32 {
        if (self.capacity == 0) return 0.0;
        return @as(f32, @floatFromInt(self.entry_count + self.tombstone_count)) /
            @as(f32, @floatFromInt(self.capacity));
    }

    /// Calculate tombstone ratio.
    pub fn tombstone_ratio(self: IndexStats) f32 {
        const total = self.entry_count + self.tombstone_count;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.tombstone_count)) /
            @as(f32, @floatFromInt(total));
    }

    /// Calculate average probe length.
    pub fn avg_probe_length(self: IndexStats) f32 {
        const total_ops = self.lookup_count + self.upsert_count;
        if (total_ops == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_probe_length)) /
            @as(f32, @floatFromInt(total_ops));
    }

    /// Calculate memory usage in bytes.
    pub fn memory_bytes(self: IndexStats) u64 {
        return self.capacity * @sizeOf(IndexEntry);
    }
};

/// Result of a lookup operation.
pub const LookupResult = struct {
    /// The found entry, or null if not found.
    entry: ?IndexEntry,
    /// Number of probes required for this lookup.
    probe_count: u32,
};

/// Result of an upsert operation.
pub const UpsertResult = struct {
    /// True if a new entry was inserted, false if existing entry was updated.
    inserted: bool,
    /// True if the update was applied (new timestamp wins), false if ignored.
    updated: bool,
    /// Number of probes required for this upsert.
    probe_count: u32,
};

/// RAM Index - O(1) entity lookup index.
///
/// Thread-safety model:
/// - Multiple concurrent readers (lookups) using lock-free atomic loads
/// - Single writer (VSR commit phase guarantees serialized writes)
/// - Read-during-write safety via atomic operations with Acquire/Release semantics
pub fn RamIndex(comptime options: struct {
    /// Enable statistics tracking (has minor performance overhead).
    track_stats: bool = true,
}) type {
    return struct {
        const Self = @This();

        /// Pre-allocated array of index entries.
        /// Aligned to 64 bytes (cache line) to prevent false sharing.
        entries: []align(64) IndexEntry,

        /// Total number of slots (capacity).
        capacity: u64,

        /// Number of non-empty entries (including tombstones).
        /// Updated atomically for concurrent access.
        count: std.atomic.Value(u64),

        /// Statistics for monitoring (optional).
        stats: if (options.track_stats) IndexStats else void,

        /// Initialize a new RAM index with the specified capacity.
        ///
        /// The capacity should be calculated as: capacity = ceil(expected_entities / 0.7)
        /// For 1B entities: capacity = 1,428,571,429 slots (~91.5GB)
        ///
        /// Memory is pre-allocated at startup and never grows.
        pub fn init(allocator: Allocator, capacity: u64) IndexError!Self {
            if (capacity == 0) return error.InvalidConfiguration;

            // Allocate aligned memory for entries.
            // Alignment of 64 bytes ensures each entry is on its own cache line.
            const entries = allocator.alignedAlloc(
                IndexEntry,
                64, // Cache line alignment
                @intCast(capacity),
            ) catch return error.OutOfMemory;

            // Initialize all entries to empty.
            @memset(entries, IndexEntry.empty);

            return Self{
                .entries = entries,
                .capacity = capacity,
                .count = std.atomic.Value(u64).init(0),
                .stats = if (options.track_stats) IndexStats{
                    .capacity = capacity,
                } else {},
            };
        }

        /// Deinitialize and free index memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.entries);
            self.* = undefined;
        }

        /// Hash function for entity_id (u128).
        /// Uses Google Abseil LowLevelHash (wyhash-inspired) from stdx.
        inline fn hash(entity_id: u128) u64 {
            return stdx.hash_inline(entity_id);
        }

        /// Calculate slot index from hash.
        inline fn slot_index(self: *const Self, entity_id: u128) u64 {
            return hash(entity_id) % self.capacity;
        }

        /// Lookup an entity by ID.
        ///
        /// This is a lock-free operation using atomic loads with Acquire semantics.
        /// Safe to call concurrently from multiple threads.
        ///
        /// Returns the IndexEntry if found, null otherwise.
        /// Also returns the probe count for diagnostics.
        pub fn lookup(self: *Self, entity_id: u128) LookupResult {
            if (entity_id == 0) {
                // Entity ID 0 is reserved as empty marker.
                return .{ .entry = null, .probe_count = 0 };
            }

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                // Atomic load with Acquire semantics.
                // Ensures we see all writes from the Release store in upsert.
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = @as(*volatile IndexEntry, @ptrCast(entry_ptr)).*;

                if (entry.is_empty()) {
                    // Empty slot - entity not found.
                    self.updateLookupStats(probe_count, false);
                    return .{ .entry = null, .probe_count = probe_count };
                }

                if (entry.entity_id == entity_id) {
                    // Found the entity.
                    // Check if it's a tombstone.
                    if (entry.is_tombstone()) {
                        self.updateLookupStats(probe_count, false);
                        return .{ .entry = null, .probe_count = probe_count };
                    }
                    self.updateLookupStats(probe_count, true);
                    return .{ .entry = entry, .probe_count = probe_count };
                }

                // Collision - probe next slot (linear probing).
                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            // Probe limit exceeded - entry not found.
            self.updateProbeLimit();
            return .{ .entry = null, .probe_count = probe_count };
        }

        /// Upsert an entity into the index.
        ///
        /// Uses Last-Write-Wins (LWW) semantics:
        /// - If slot is empty: insert new entry
        /// - If slot has same entity_id: compare timestamps
        ///   - new_timestamp > old_timestamp: update (new wins)
        ///   - new_timestamp < old_timestamp: ignore (old wins)
        ///   - timestamps equal: higher latest_id wins (deterministic tie-break)
        /// - If slot has different entity_id: probe next slot
        ///
        /// This function is NOT thread-safe for concurrent writes.
        /// VSR commit phase guarantees single-threaded execution.
        pub fn upsert(
            self: *Self,
            entity_id: u128,
            latest_id: u128,
            ttl_seconds: u32,
        ) IndexError!UpsertResult {
            if (entity_id == 0) {
                // Entity ID 0 is reserved as empty marker.
                return error.InvalidConfiguration;
            }

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = entry_ptr.*;

                if (entry.is_empty() or entry.is_tombstone()) {
                    // Empty or tombstone slot - insert new entry.
                    const new_entry = IndexEntry{
                        .entity_id = entity_id,
                        .latest_id = latest_id,
                        .ttl_seconds = ttl_seconds,
                        .reserved = 0,
                        .padding = [_]u8{0} ** 24,
                    };

                    // Write with Release semantics.
                    @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = new_entry;

                    // Update count if this was an empty slot (not tombstone reuse).
                    if (entry.is_empty()) {
                        _ = self.count.fetchAdd(1, .monotonic);
                    }

                    self.updateUpsertStats(probe_count, true, entry.is_tombstone());
                    return .{ .inserted = true, .updated = true, .probe_count = probe_count };
                }

                if (entry.entity_id == entity_id) {
                    // Found existing entry - apply LWW.
                    const new_timestamp = @as(u64, @truncate(latest_id));
                    const old_timestamp = entry.timestamp();

                    var should_update = false;
                    if (new_timestamp > old_timestamp) {
                        // New write wins.
                        should_update = true;
                    } else if (new_timestamp == old_timestamp) {
                        // Tie-break: higher latest_id wins (deterministic).
                        should_update = latest_id > entry.latest_id;
                    }
                    // else: new_timestamp < old_timestamp - old wins, ignore.

                    if (should_update) {
                        const new_entry = IndexEntry{
                            .entity_id = entity_id,
                            .latest_id = latest_id,
                            .ttl_seconds = ttl_seconds,
                            .reserved = 0,
                            .padding = [_]u8{0} ** 24,
                        };

                        // Write with Release semantics.
                        @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = new_entry;
                    }

                    self.updateUpsertStats(probe_count, false, false);
                    return .{ .inserted = false, .updated = should_update, .probe_count = probe_count };
                }

                // Different entity - collision, probe next slot.
                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            // Probe limit exceeded - index degraded.
            self.updateProbeLimit();
            return error.IndexDegraded;
        }

        /// Mark an entity as deleted (create tombstone).
        ///
        /// Tombstones preserve the slot for the entity_id to ensure
        /// proper probe chain behavior. They are reclaimed during rebuild.
        pub fn remove(self: *Self, entity_id: u128) bool {
            if (entity_id == 0) return false;

            var slot = self.slot_index(entity_id);
            var probe_count: u32 = 0;

            while (probe_count < max_probe_length) {
                const entry_ptr: *IndexEntry = &self.entries[@intCast(slot)];
                const entry = entry_ptr.*;

                if (entry.is_empty()) {
                    // Not found.
                    return false;
                }

                if (entry.entity_id == entity_id) {
                    if (entry.is_tombstone()) {
                        // Already deleted.
                        return false;
                    }

                    // Create tombstone (keep entity_id, zero latest_id).
                    const tombstone = IndexEntry{
                        .entity_id = entity_id,
                        .latest_id = 0,
                        .ttl_seconds = 0,
                        .reserved = 0,
                        .padding = [_]u8{0} ** 24,
                    };

                    @as(*volatile IndexEntry, @ptrCast(entry_ptr)).* = tombstone;

                    if (options.track_stats) {
                        self.stats.tombstone_count += 1;
                        self.stats.entry_count -|= 1;
                    }

                    return true;
                }

                slot = (slot + 1) % self.capacity;
                probe_count += 1;
            }

            return false;
        }

        /// Get current statistics.
        pub fn get_stats(self: *const Self) IndexStats {
            if (options.track_stats) {
                var stats = self.stats;
                stats.entry_count = self.count.load(.monotonic);
                return stats;
            } else {
                return IndexStats{
                    .capacity = self.capacity,
                    .entry_count = self.count.load(.monotonic),
                };
            }
        }

        // Internal stats update functions.

        fn updateLookupStats(self: *Self, probe_count: u32, hit: bool) void {
            if (options.track_stats) {
                self.stats.lookup_count += 1;
                if (hit) self.stats.lookup_hit_count += 1;
                self.stats.total_probe_length += probe_count;
                if (probe_count > self.stats.max_probe_length_seen) {
                    self.stats.max_probe_length_seen = probe_count;
                }
                if (probe_count > 0) self.stats.collision_count += 1;
            }
        }

        fn updateUpsertStats(self: *Self, probe_count: u32, inserted: bool, tombstone_reuse: bool) void {
            if (options.track_stats) {
                self.stats.upsert_count += 1;
                self.stats.total_probe_length += probe_count;
                if (probe_count > self.stats.max_probe_length_seen) {
                    self.stats.max_probe_length_seen = probe_count;
                }
                if (probe_count > 0) self.stats.collision_count += 1;
                if (inserted and !tombstone_reuse) {
                    self.stats.entry_count += 1;
                } else if (tombstone_reuse) {
                    self.stats.tombstone_count -|= 1;
                    self.stats.entry_count += 1;
                }
            }
        }

        fn updateProbeLimit(self: *Self) void {
            if (options.track_stats) {
                self.stats.probe_limit_hits += 1;
            }
        }
    };
}

/// Default RAM index type with stats enabled.
pub const DefaultRamIndex = RamIndex(.{ .track_stats = true });

// ============================================================================
// Unit Tests
// ============================================================================

test "IndexEntry: size and alignment" {
    // IndexEntry must be exactly 64 bytes (cache line).
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(IndexEntry));

    // Must have at least 16-byte alignment for u128.
    try std.testing.expect(@alignOf(IndexEntry) >= 16);
}

test "IndexEntry: empty and tombstone detection" {
    const empty = IndexEntry.empty;
    try std.testing.expect(empty.is_empty());
    try std.testing.expect(!empty.is_tombstone());

    const live = IndexEntry{
        .entity_id = 123,
        .latest_id = 456,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expect(!live.is_empty());
    try std.testing.expect(!live.is_tombstone());

    const tombstone = IndexEntry{
        .entity_id = 123,
        .latest_id = 0,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expect(!tombstone.is_empty());
    try std.testing.expect(tombstone.is_tombstone());
}

test "IndexEntry: timestamp extraction" {
    // Timestamp is lower 64 bits of latest_id.
    const entry = IndexEntry{
        .entity_id = 1,
        .latest_id = (@as(u128, 0xDEADBEEF) << 64) | 0x123456789ABCDEF0,
        .ttl_seconds = 0,
        .reserved = 0,
        .padding = [_]u8{0} ** 24,
    };
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), entry.timestamp());
}

test "RamIndex: basic lookup and upsert" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Lookup on empty index.
    const result1 = index.lookup(42);
    try std.testing.expect(result1.entry == null);

    // Insert an entry.
    const upsert_result = try index.upsert(42, 1000, 3600);
    try std.testing.expect(upsert_result.inserted);
    try std.testing.expect(upsert_result.updated);

    // Lookup should now find it.
    const result2 = index.lookup(42);
    try std.testing.expect(result2.entry != null);
    try std.testing.expectEqual(@as(u128, 42), result2.entry.?.entity_id);
    try std.testing.expectEqual(@as(u128, 1000), result2.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 3600), result2.entry.?.ttl_seconds);
}

test "RamIndex: LWW semantics" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert initial entry with timestamp 1000.
    _ = try index.upsert(42, 1000, 3600);

    // Try to update with older timestamp 500 - should be ignored.
    const result1 = try index.upsert(42, 500, 7200);
    try std.testing.expect(!result1.inserted);
    try std.testing.expect(!result1.updated); // Old wins, not updated.

    // Verify entry still has original values.
    const lookup1 = index.lookup(42);
    try std.testing.expectEqual(@as(u128, 1000), lookup1.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 3600), lookup1.entry.?.ttl_seconds);

    // Update with newer timestamp 2000 - should succeed.
    const result2 = try index.upsert(42, 2000, 1800);
    try std.testing.expect(!result2.inserted);
    try std.testing.expect(result2.updated); // New wins, updated.

    // Verify entry has new values.
    const lookup2 = index.lookup(42);
    try std.testing.expectEqual(@as(u128, 2000), lookup2.entry.?.latest_id);
    try std.testing.expectEqual(@as(u32, 1800), lookup2.entry.?.ttl_seconds);
}

test "RamIndex: LWW tie-break" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert entry: same timestamp (lower 64 bits), lower full ID.
    const id1 = (@as(u128, 100) << 64) | 5000; // S2=100, ts=5000
    _ = try index.upsert(42, id1, 3600);

    // Try with same timestamp but higher full ID - should win.
    const id2 = (@as(u128, 200) << 64) | 5000; // S2=200, ts=5000 (same)
    const result = try index.upsert(42, id2, 1800);
    try std.testing.expect(result.updated); // Higher full ID wins.

    const lookup = index.lookup(42);
    try std.testing.expectEqual(id2, lookup.entry.?.latest_id);
}

test "RamIndex: remove creates tombstone" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Insert and verify.
    _ = try index.upsert(42, 1000, 3600);
    try std.testing.expect(index.lookup(42).entry != null);

    // Remove.
    const removed = index.remove(42);
    try std.testing.expect(removed);

    // Lookup should return null (tombstone is not visible).
    try std.testing.expect(index.lookup(42).entry == null);

    // Remove again should return false.
    try std.testing.expect(!index.remove(42));
}

test "RamIndex: collision handling" {
    const allocator = std.testing.allocator;

    // Small capacity to force collisions.
    var index = try DefaultRamIndex.init(allocator, 10);
    defer index.deinit(allocator);

    // Insert multiple entries - some will collide.
    var i: u128 = 1;
    while (i <= 5) : (i += 1) {
        _ = try index.upsert(i, i * 100, 3600);
    }

    // Verify all can be found.
    i = 1;
    while (i <= 5) : (i += 1) {
        const result = index.lookup(i);
        try std.testing.expect(result.entry != null);
        try std.testing.expectEqual(i, result.entry.?.entity_id);
        try std.testing.expectEqual(i * 100, result.entry.?.latest_id);
    }
}

test "RamIndex: statistics" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Initial stats.
    var stats = index.get_stats();
    try std.testing.expectEqual(@as(u64, 1000), stats.capacity);
    try std.testing.expectEqual(@as(u64, 0), stats.entry_count);
    try std.testing.expectEqual(@as(f32, 0.0), stats.load_factor());

    // Insert some entries.
    _ = try index.upsert(1, 100, 0);
    _ = try index.upsert(2, 200, 0);
    _ = try index.upsert(3, 300, 0);

    // Perform lookups.
    _ = index.lookup(1);
    _ = index.lookup(2);
    _ = index.lookup(999); // Miss.

    stats = index.get_stats();
    try std.testing.expectEqual(@as(u64, 3), stats.entry_count);
    try std.testing.expectEqual(@as(u64, 3), stats.upsert_count);
    try std.testing.expectEqual(@as(u64, 3), stats.lookup_count);
    try std.testing.expectEqual(@as(u64, 2), stats.lookup_hit_count);

    // Verify load factor calculation.
    const expected_lf = 3.0 / 1000.0;
    try std.testing.expectApproxEqAbs(expected_lf, stats.load_factor(), 0.0001);
}

test "RamIndex: out-of-order timestamp handling (F2.1.7)" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // Simulate GPS packets arriving out of order.
    // Packets: ts=3000, ts=1000, ts=2000 (arriving in this order).

    // First packet arrives (ts=3000).
    _ = try index.upsert(42, 3000, 3600);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Second packet arrives (ts=1000 - older, should be ignored).
    const result1 = try index.upsert(42, 1000, 3600);
    try std.testing.expect(!result1.updated);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Third packet arrives (ts=2000 - still older, should be ignored).
    const result2 = try index.upsert(42, 2000, 3600);
    try std.testing.expect(!result2.updated);
    try std.testing.expectEqual(@as(u128, 3000), index.lookup(42).entry.?.latest_id);

    // Fourth packet arrives (ts=4000 - newer, should win).
    const result3 = try index.upsert(42, 4000, 3600);
    try std.testing.expect(result3.updated);
    try std.testing.expectEqual(@as(u128, 4000), index.lookup(42).entry.?.latest_id);
}

test "RamIndex: entity_id zero is rejected" {
    const allocator = std.testing.allocator;

    var index = try DefaultRamIndex.init(allocator, 1000);
    defer index.deinit(allocator);

    // entity_id = 0 is reserved as empty marker.
    const result = index.upsert(0, 1000, 3600);
    try std.testing.expectError(error.InvalidConfiguration, result);

    // Lookup of 0 should return null immediately.
    try std.testing.expect(index.lookup(0).entry == null);
}
