// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Query Result Cache - Dashboard workload optimization.
//!
//! Implements a query result cache with write-invalidation semantics for
//! optimizing dashboard workloads where the same queries repeat frequently.
//!
//! ## Design
//!
//! - **Generation-based invalidation**: Instead of per-entry tracking, we use a
//!   global generation counter that increments on every write. Cache entries
//!   store the generation at which they were created. On lookup, if the entry's
//!   generation doesn't match the current generation, it's considered stale.
//!
//! - **CLOCK eviction**: Uses set-associative cache with CLOCK eviction from
//!   SetAssociativeCacheType for bounded memory usage.
//!
//! - **Write-through invalidation**: Any write operation (insert, delete)
//!   calls invalidateAll() which increments the generation, effectively
//!   invalidating all cached results without per-entry scanning.
//!
//! ## Usage
//!
//! ```zig
//! // On query:
//! const query_hash = cache.hashQuery(operation, filter_bytes);
//! if (cache.get(query_hash)) |cached| {
//!     // Return cached result
//!     @memcpy(output[0..cached.result_len], cached.result_data[0..cached.result_len]);
//!     return cached.result_len;
//! }
//! // ... execute query ...
//! cache.put(query_hash, result_bytes);
//!
//! // On write:
//! cache.invalidateAll();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const stdx = @import("stdx");
const SetAssociativeCacheType = @import("lsm/set_associative_cache.zig").SetAssociativeCacheType;

/// Maximum size of a cached result in bytes.
/// Set to make CachedResult exactly 4096 bytes (power of 2 for SetAssociativeCacheType).
/// Fits most dashboard query responses (up to ~31 GeoEvents at 128 bytes each).
pub const max_cached_result_size: usize = 4072;

/// Cached query result with generation tracking.
/// Size is exactly 4096 bytes (power of 2) for efficient cache layout.
pub const CachedResult = extern struct {
    /// Query hash (used as key)
    query_hash: u64,
    /// Generation when this entry was cached
    generation: u64,
    /// Length of the cached result data
    result_len: u32,
    /// Padding for alignment
    _padding: u32 = 0,
    /// Serialized response bytes (truncated if > max_cached_result_size)
    result_data: [max_cached_result_size]u8,

    comptime {
        // Ensure size is power of 2 for SetAssociativeCacheType
        assert(@sizeOf(CachedResult) == 4096);
        assert(std.math.isPowerOfTwo(@sizeOf(CachedResult)));
        assert(stdx.no_padding(CachedResult));
    }

    /// Check if this result is valid for the given generation.
    pub fn isValid(self: *const CachedResult, current_generation: u64) bool {
        return self.generation == current_generation and self.result_len > 0;
    }

    /// Get the result data slice.
    pub fn getData(self: *const CachedResult) []const u8 {
        return self.result_data[0..self.result_len];
    }
};

/// Query result cache with write-invalidation.
/// Caches query results keyed by query hash, with generation-based invalidation
/// on any write operation.
pub const QueryResultCache = struct {
    const Self = @This();

    /// Layout configuration for CLOCK eviction cache
    const layout = @import("lsm/set_associative_cache.zig").Layout{
        .ways = 16,
        .tag_bits = 8,
        .clock_bits = 2,
        .cache_line_size = 64,
    };

    /// Internal set-associative cache type
    const InternalCache = SetAssociativeCacheType(
        u64, // Key type: query hash
        CachedResult, // Value type
        keyFromValue,
        hashKey,
        layout,
    );

    /// The underlying set-associative cache
    cache: InternalCache,

    /// Current generation (incremented on every write)
    generation: u64,

    /// Seed for query hashing, initialized from OS entropy to prevent HashDoS.
    hash_seed: u64,

    /// Metrics
    hits: u64,
    misses: u64,

    /// Extract key from cached result
    inline fn keyFromValue(value: *const CachedResult) u64 {
        return value.query_hash;
    }

    /// Hash function for query hash (identity - already hashed)
    inline fn hashKey(key: u64) u64 {
        return key;
    }

    /// Initialize the query result cache.
    ///
    /// Arguments:
    /// - allocator: Memory allocator
    /// - value_count_max: Maximum number of cached entries (must be multiple of value_count_max_multiple)
    ///
    /// Default: 1024 entries (configurable)
    pub fn init(allocator: mem.Allocator, value_count_max: u64) !Self {
        // Ensure value_count_max is valid
        const adjusted = if (value_count_max < InternalCache.value_count_max_multiple)
            InternalCache.value_count_max_multiple
        else
            (value_count_max / InternalCache.value_count_max_multiple) *
                InternalCache.value_count_max_multiple;

        return Self{
            .cache = try InternalCache.init(allocator, adjusted, .{ .name = "query_cache" }),
            .generation = 1, // Start at 1 so 0 is always invalid
            .hash_seed = std.crypto.random.int(u64),
            .hits = 0,
            .misses = 0,
        };
    }

    /// Deinitialize the cache and free memory.
    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    /// Reset the cache (clear all entries).
    pub fn reset(self: *Self) void {
        self.cache.reset();
        self.generation = 1;
        self.hits = 0;
        self.misses = 0;
    }

    /// Look up a cached result by query hash.
    ///
    /// Returns the cached result if found AND valid for current generation,
    /// otherwise returns null (cache miss).
    pub fn get(self: *Self, query_hash: u64) ?*const CachedResult {
        if (self.cache.get(query_hash)) |cached| {
            if (cached.isValid(self.generation)) {
                self.hits += 1;
                return cached;
            }
        }
        self.misses += 1;
        return null;
    }

    /// Store a query result in the cache.
    ///
    /// Arguments:
    /// - query_hash: Hash of the query (from hashQuery)
    /// - result: Result bytes to cache
    ///
    /// Note: Results larger than max_cached_result_size are not cached.
    pub fn put(self: *Self, query_hash: u64, result: []const u8) void {
        // Don't cache oversized results
        if (result.len > max_cached_result_size) {
            return;
        }

        var entry = CachedResult{
            .query_hash = query_hash,
            .generation = self.generation,
            .result_len = @intCast(result.len),
            .result_data = undefined,
        };
        @memset(&entry.result_data, 0);
        @memcpy(entry.result_data[0..result.len], result);

        _ = self.cache.upsert(&entry);
    }

    /// Invalidate all cached entries.
    ///
    /// Called on every write operation (insert, delete) to ensure freshness.
    /// Uses generation increment for O(1) invalidation.
    pub fn invalidateAll(self: *Self) void {
        // Wrapping increment - even at 1 op/ns, takes 584 years to wrap
        self.generation +%= 1;
        // Handle wrap-around: skip 0 since it's the "invalid" generation
        if (self.generation == 0) {
            self.generation = 1;
        }
    }

    /// Hash a query for cache lookup.
    ///
    /// Combines operation type and filter bytes into a deterministic hash.
    /// The hash seed is initialized from OS entropy at cache creation to
    /// prevent HashDoS attacks against the query cache.
    pub fn hashQuery(self: *const Self, operation: u8, filter_bytes: []const u8) u64 {
        // Combine operation and filter into a single hash
        // Start with operation byte, then hash the filter data
        var hasher = std.hash.Wyhash.init(self.hash_seed);
        hasher.update(&[_]u8{operation});
        hasher.update(filter_bytes);
        return hasher.final();
    }

    /// Get cache hit rate as a percentage (0.0 - 100.0).
    pub fn hitRate(self: *const Self) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "QueryResultCache: basic put and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    const query_hash = cache.hashQuery(1, "test filter");
    const result = "test result data";

    // Cache miss before put
    try testing.expect(cache.get(query_hash) == null);
    try testing.expectEqual(@as(u64, 0), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);

    // Put result
    cache.put(query_hash, result);

    // Cache hit after put
    const cached = cache.get(query_hash);
    try testing.expect(cached != null);
    try testing.expectEqualSlices(u8, result, cached.?.getData());
    try testing.expectEqual(@as(u64, 1), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);
}

test "QueryResultCache: write-invalidation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    const query_hash = cache.hashQuery(1, "test filter");
    const result = "test result data";

    // Put result
    cache.put(query_hash, result);

    // Cache hit
    try testing.expect(cache.get(query_hash) != null);

    // Invalidate all
    cache.invalidateAll();

    // Cache miss after invalidation
    try testing.expect(cache.get(query_hash) == null);
}

test "QueryResultCache: generation wrapping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    // Force generation to near max
    cache.generation = std.math.maxInt(u64);

    const query_hash = cache.hashQuery(1, "test filter");
    const result = "test result data";

    // Put at max generation
    cache.put(query_hash, result);
    try testing.expect(cache.get(query_hash) != null);

    // Invalidate - should wrap to 1 (skipping 0)
    cache.invalidateAll();
    try testing.expectEqual(@as(u64, 1), cache.generation);

    // Old entry is now stale
    try testing.expect(cache.get(query_hash) == null);
}

test "QueryResultCache: hash function determinism" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    // Same operation+filter produces same hash
    const hash1 = cache.hashQuery(1, "filter bytes");
    const hash2 = cache.hashQuery(1, "filter bytes");
    try testing.expectEqual(hash1, hash2);

    // Different operations produce different hashes
    const hash3 = cache.hashQuery(2, "filter bytes");
    try testing.expect(hash1 != hash3);

    // Different filters produce different hashes
    const hash4 = cache.hashQuery(1, "different filter");
    try testing.expect(hash1 != hash4);
}

test "QueryResultCache: oversized results not cached" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    const query_hash = cache.hashQuery(1, "test filter");

    // Create oversized result
    var oversized: [max_cached_result_size + 1]u8 = undefined;
    @memset(&oversized, 'x');

    // Put oversized - should be ignored
    cache.put(query_hash, &oversized);

    // Cache miss - oversized was not cached
    try testing.expect(cache.get(query_hash) == null);
}

test "QueryResultCache: CLOCK eviction under pressure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Small cache to trigger eviction
    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    // Fill cache with many entries
    var i: u64 = 0;
    while (i < 512) : (i += 1) {
        var filter_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &filter_buf, i, .little);
        const query_hash = cache.hashQuery(1, &filter_buf);
        cache.put(query_hash, "result data");
    }

    // Access first entry to increase its count
    var first_filter: [8]u8 = undefined;
    std.mem.writeInt(u64, &first_filter, 0, .little);
    const first_hash = cache.hashQuery(1, &first_filter);

    // First entry may or may not be present depending on eviction
    // The important thing is the cache doesn't crash under pressure
    _ = cache.get(first_hash);

    // Cache should still be functional
    const new_hash = cache.hashQuery(1, "new entry");
    cache.put(new_hash, "new result");
    try testing.expect(cache.get(new_hash) != null);
}

test "QueryResultCache: reset clears all" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    // Add some entries
    cache.put(cache.hashQuery(1, "filter1"), "result1");
    cache.put(cache.hashQuery(2, "filter2"), "result2");

    // Verify they exist
    try testing.expect(cache.get(cache.hashQuery(1, "filter1")) != null);
    try testing.expect(cache.get(cache.hashQuery(2, "filter2")) != null);

    // Reset
    cache.reset();

    // All gone
    try testing.expect(cache.get(cache.hashQuery(1, "filter1")) == null);
    try testing.expect(cache.get(cache.hashQuery(2, "filter2")) == null);
    try testing.expectEqual(@as(u64, 0), cache.hits);
    // Misses are recorded for the gets above
    try testing.expectEqual(@as(u64, 2), cache.misses);
}

// ============================================================================
// Phase 14 Verification Tests
// ============================================================================

test "QueryResultCache: VERIFY dashboard workload 80%+ cache hit ratio" {
    // Phase 14 Success Criteria: Dashboard workload achieves 80%+ cache hit ratio
    //
    // Dashboard workloads are characterized by:
    // - Small set of repeated queries (typically 10-20 unique dashboard panels)
    // - Same queries repeat frequently (refresh every 10-30 seconds)
    // - Occasional new queries when users navigate
    //
    // Simulation: 10 unique dashboard queries, repeated 100 times each = 1000 total queries
    // Expected: After warmup (10 misses), 990 hits = 99% hit rate

    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 256);
    defer cache.deinit(allocator);

    // Define 10 dashboard-style queries (simulating different panels)
    const dashboard_queries = [_]struct { op: u8, filter: []const u8 }{
        .{ .op = 1, .filter = "dashboard:panel:map:bounds" },
        .{ .op = 1, .filter = "dashboard:panel:stats:today" },
        .{ .op = 2, .filter = "dashboard:panel:timeline:24h" },
        .{ .op = 1, .filter = "dashboard:panel:alerts:active" },
        .{ .op = 3, .filter = "dashboard:panel:devices:list" },
        .{ .op = 1, .filter = "dashboard:panel:geofence:status" },
        .{ .op = 2, .filter = "dashboard:panel:activity:recent" },
        .{ .op = 1, .filter = "dashboard:panel:summary:fleet" },
        .{ .op = 3, .filter = "dashboard:panel:metrics:latency" },
        .{ .op = 1, .filter = "dashboard:panel:overview:all" },
    };

    // Pre-compute hashes
    var query_hashes: [10]u64 = undefined;
    for (dashboard_queries, 0..) |q, i| {
        query_hashes[i] = cache.hashQuery(q.op, q.filter);
    }

    // Simulate dashboard refresh pattern: 100 refresh cycles
    const refresh_cycles = 100;
    var total_queries: u64 = 0;

    for (0..refresh_cycles) |cycle| {
        for (query_hashes, 0..) |hash, panel_idx| {
            total_queries += 1;

            if (cache.get(hash)) |_| {
                // Cache hit - dashboard panel served from cache
                continue;
            }

            // Cache miss - simulate query execution and cache result
            // Real dashboard responses are typically 100-2000 bytes JSON
            var result_buf: [512]u8 = undefined;
            const result_len = @min(100 + panel_idx * 50, result_buf.len);
            @memset(result_buf[0..result_len], @intCast((cycle + panel_idx) % 256));
            cache.put(hash, result_buf[0..result_len]);
        }
    }

    // Calculate hit rate
    const hit_rate = cache.hitRate();
    const target_rate: f64 = 80.0;

    // Report results (using debug.print to always show output)
    std.debug.print("\n=== Dashboard Workload Cache Verification ===\n", .{});
    std.debug.print("  Total queries: {d}\n", .{total_queries});
    std.debug.print("  Cache hits: {d}\n", .{cache.hits});
    std.debug.print("  Cache misses: {d}\n", .{cache.misses});
    std.debug.print("  Hit rate: {d:.2}%\n", .{hit_rate});
    std.debug.print("  Target: >= {d:.0}%\n", .{target_rate});

    // VERIFY: Hit rate must be >= 80%
    try testing.expect(hit_rate >= target_rate);

    // Additional verification: with 10 unique queries and 100 cycles,
    // we expect exactly 10 misses (first access of each) and 990 hits = 99%
    // Allow some margin for CLOCK eviction edge cases
    try testing.expect(hit_rate >= 95.0); // Should be ~99%
}

test "QueryResultCache: VERIFY sub-millisecond cached query latency P99" {
    // Phase 14 Success Criteria: Cached queries return in <1ms (P99)
    //
    // Test methodology:
    // 1. Populate cache with typical dashboard data
    // 2. Perform 1000 cache lookups with timing
    // 3. Calculate P99 latency
    // 4. Verify P99 < 1ms (1,000,000 nanoseconds)

    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = try QueryResultCache.init(allocator, 1024);
    defer cache.deinit(allocator);

    // Pre-populate cache with 50 queries (typical dashboard load)
    const num_queries: usize = 50;
    var query_hashes: [num_queries]u64 = undefined;
    var result_data: [num_queries][256]u8 = undefined;

    for (0..num_queries) |i| {
        var filter_buf: [32]u8 = undefined;
        const filter_len = std.fmt.bufPrint(&filter_buf, "query:panel:{d}", .{i}) catch unreachable;
        query_hashes[i] = cache.hashQuery(1, filter_buf[0..filter_len.len]);

        // Generate realistic result data (100-250 bytes)
        const result_len = 100 + (i * 3);
        @memset(result_data[i][0..result_len], @intCast(i % 256));
        cache.put(query_hashes[i], result_data[i][0..result_len]);
    }

    // Collect timing samples for cache lookups
    const num_samples: usize = 1000;
    var latencies_ns: [num_samples]i128 = undefined;

    // Use std.time.Timer for precise timing
    for (0..num_samples) |sample_idx| {
        const query_idx = sample_idx % num_queries;
        const hash = query_hashes[query_idx];

        const start = std.time.nanoTimestamp();
        const result = cache.get(hash);
        const end = std.time.nanoTimestamp();

        // Verify we got a hit
        try testing.expect(result != null);

        latencies_ns[sample_idx] = end - start;
    }

    // Sort latencies to calculate percentiles
    std.sort.block(i128, &latencies_ns, {}, std.sort.asc(i128));

    // Calculate statistics
    const p50_idx = num_samples / 2;
    const p95_idx = (num_samples * 95) / 100;
    const p99_idx = (num_samples * 99) / 100;

    const p50_ns = latencies_ns[p50_idx];
    const p95_ns = latencies_ns[p95_idx];
    const p99_ns = latencies_ns[p99_idx];
    const max_ns = latencies_ns[num_samples - 1];
    const min_ns = latencies_ns[0];

    // Calculate mean
    var sum: i128 = 0;
    for (latencies_ns) |lat| sum += lat;
    const mean_ns = @divTrunc(sum, num_samples);

    // Target: P99 < 1ms (1,000,000 ns)
    // In practice, cache lookups should be ~100-1000ns
    const p99_target_ns: i128 = 1_000_000; // 1ms

    std.debug.print("\n=== Cached Query Latency Verification ===\n", .{});
    std.debug.print("  Samples: {d}\n", .{num_samples});
    std.debug.print("  Min: {d}ns\n", .{min_ns});
    std.debug.print("  Mean: {d}ns\n", .{mean_ns});
    std.debug.print("  P50: {d}ns\n", .{p50_ns});
    std.debug.print("  P95: {d}ns\n", .{p95_ns});
    std.debug.print("  P99: {d}ns ({d:.3}ms)\n", .{ p99_ns, @as(f64, @floatFromInt(p99_ns)) / 1_000_000.0 });
    std.debug.print("  Max: {d}ns\n", .{max_ns});
    std.debug.print("  Target P99: <{d}ns (1ms)\n", .{p99_target_ns});

    // VERIFY: P99 latency < 1ms
    try testing.expect(p99_ns < p99_target_ns);

    // Additional verification: P99 should actually be much faster (< 100us)
    // for in-memory cache with no I/O
    const p99_expected_ns: i128 = 100_000; // 100us
    if (p99_ns < p99_expected_ns) {
        std.debug.print("  EXCELLENT: P99 < 100us (expected for in-memory cache)\n", .{});
    }
    std.debug.print("  RESULT: PASS (P99 {d}ns < 1ms target)\n", .{p99_ns});
}
