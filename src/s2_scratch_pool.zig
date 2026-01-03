// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! S2 Scratch Buffer Pool (F3.3.6)
//!
//! Pre-allocated pool of scratch buffers for S2 polygon covering operations.
//! Each buffer is 1MB (sufficient for 10k-vertex polygons) and the pool contains
//! 100 buffers by default, matching max_concurrent_queries.
//!
//! ## Design Rationale
//!
//! The S2 RegionCoverer needs working memory for complex polygon operations.
//! Rather than allocating per-query (forbidden in VSR hot path), we pre-allocate
//! a pool at startup. This provides:
//!
//! - **Bounded memory**: Pool size × buffer size = 100MB max for S2 operations
//! - **No runtime allocation**: acquire() never allocates, just returns a pre-existing buffer
//! - **Backpressure**: When exhausted, queries wait (rather than OOM or error)
//!
//! ## Usage
//!
//! ```zig
//! var pool = try S2ScratchPool.init(allocator);
//! defer pool.deinit(allocator);
//!
//! // Acquire a buffer for polygon covering
//! if (pool.acquire()) |buffer| {
//!     defer pool.release(buffer);
//!
//!     // Use buffer for S2 operations...
//!     const covering = coverer.coverPolygon(polygon, buffer.slice());
//! } else {
//!     // Pool exhausted, apply backpressure
//!     return error.PoolExhausted;
//! }
//! ```
//!
//! ## Memory Layout
//!
//! The pool allocates one contiguous region:
//! - `pool_size × buffer_size` bytes = 100 × 1MB = 100MB
//! - Each buffer is page-aligned for efficient I/O
//!
//! ## Thread Safety
//!
//! This implementation is NOT thread-safe. In the VSR architecture, each replica
//! runs single-threaded, so thread safety is not required.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Default scratch buffer size: 1MB (per constants/spec.md)
/// Sufficient for 10k-vertex polygons.
pub const default_buffer_size: usize = 1 * 1024 * 1024;

/// Default pool size: 100 buffers (per constants/spec.md)
/// Matches max_concurrent_queries.
pub const default_pool_size: usize = 100;

/// A handle to a scratch buffer from the pool.
/// The buffer slice is available via .slice()
pub const ScratchBuffer = struct {
    /// Index in the pool's buffer array
    index: usize,

    /// Pointer to the actual buffer data
    data: [*]align(std.heap.page_size_min) u8,

    /// Size of the buffer
    size: usize,

    /// Get the buffer as a slice
    pub fn slice(self: ScratchBuffer) []align(std.heap.page_size_min) u8 {
        return self.data[0..self.size];
    }

    /// Get a typed slice of the buffer (for convenience)
    pub fn typed(self: ScratchBuffer, comptime T: type, count: usize) []T {
        comptime assert(@alignOf(T) <= std.heap.page_size_min);
        assert(count * @sizeOf(T) <= self.size);

        const ptr: [*]T = @ptrCast(@alignCast(self.data));
        return ptr[0..count];
    }
};

/// Pool statistics for monitoring
pub const PoolStats = struct {
    /// Total number of acquire() calls
    acquires: u64 = 0,

    /// Number of successful acquire() calls
    acquired: u64 = 0,

    /// Number of release() calls
    released: u64 = 0,

    /// Number of times acquire() returned null (pool exhausted)
    exhausted: u64 = 0,

    /// Peak concurrent usage (high water mark)
    peak_usage: usize = 0,

    /// Current number of buffers in use
    current_usage: usize = 0,

    /// Export statistics in Prometheus format.
    pub fn toPrometheus(self: PoolStats, writer: anytype) !void {
        try writer.print("archerdb_s2_scratch_pool_acquires {d}\n", .{self.acquires});
        try writer.print("archerdb_s2_scratch_pool_acquired {d}\n", .{self.acquired});
        try writer.print("archerdb_s2_scratch_pool_released {d}\n", .{self.released});
        try writer.print("archerdb_s2_scratch_pool_exhausted {d}\n", .{self.exhausted});
        try writer.print("archerdb_s2_scratch_pool_peak_usage {d}\n", .{self.peak_usage});
        try writer.print("archerdb_s2_scratch_pool_current_usage {d}\n", .{self.current_usage});
    }
};

/// S2 scratch buffer pool.
pub fn S2ScratchPoolType(comptime pool_size: usize, comptime buffer_size: usize) type {
    return struct {
        

        /// The underlying memory block
        memory: []align(std.heap.page_size_min) u8,

        /// Bitmap tracking which buffers are in use (true = in use)
        in_use: [pool_size]bool,

        /// Number of free buffers
        free_count: usize,

        /// Statistics
        stats: PoolStats,

        /// Initialize the pool by allocating all buffers.
        pub fn init(allocator: Allocator) !@This() {
            const total_size = pool_size * buffer_size;

            const memory = try allocator.alignedAlloc(
                u8,
                std.heap.page_size_min,
                total_size,
            );
            errdefer allocator.free(memory);

            return @This(){
                .memory = memory,
                .in_use = [_]bool{false} ** pool_size,
                .free_count = pool_size,
                .stats = .{},
            };
        }

        /// Deinitialize the pool, freeing all memory.
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            // All buffers should be released before deinit
            assert(self.free_count == pool_size);
            allocator.free(self.memory);
            self.* = undefined;
        }

        /// Acquire a scratch buffer from the pool.
        ///
        /// Returns null if the pool is exhausted (all buffers in use).
        /// The caller is responsible for releasing the buffer when done.
        pub fn acquire(self: *@This()) ?ScratchBuffer {
            self.stats.acquires += 1;

            if (self.free_count == 0) {
                self.stats.exhausted += 1;
                return null;
            }

            // Find first free buffer
            for (&self.in_use, 0..) |*in_use, i| {
                if (!in_use.*) {
                    in_use.* = true;
                    self.free_count -= 1;

                    // Update stats
                    self.stats.acquired += 1;
                    self.stats.current_usage = pool_size - self.free_count;
                    if (self.stats.current_usage > self.stats.peak_usage) {
                        self.stats.peak_usage = self.stats.current_usage;
                    }

                    const offset = i * buffer_size;
                    return ScratchBuffer{
                        .index = i,
                        .data = @ptrCast(@alignCast(self.memory.ptr + offset)),
                        .size = buffer_size,
                    };
                }
            }

            unreachable; // free_count > 0 but no free buffer found
        }

        /// Release a scratch buffer back to the pool.
        pub fn release(self: *@This(), buffer: ScratchBuffer) void {
            assert(buffer.index < pool_size);
            assert(self.in_use[buffer.index]); // Must be in use

            self.in_use[buffer.index] = false;
            self.free_count += 1;

            self.stats.released += 1;
            self.stats.current_usage = pool_size - self.free_count;
        }

        /// Get the number of free buffers.
        pub fn freeCount(self: *const @This()) usize {
            return self.free_count;
        }

        /// Get the number of buffers in use.
        pub fn usedCount(self: *const @This()) usize {
            return pool_size - self.free_count;
        }

        /// Check if the pool is exhausted.
        pub fn isExhausted(self: *const @This()) bool {
            return self.free_count == 0;
        }

        /// Get pool statistics.
        pub fn getStats(self: *const @This()) PoolStats {
            return self.stats;
        }

        /// Reset statistics (for testing).
        pub fn resetStats(self: *@This()) void {
            self.stats = .{};
            self.stats.current_usage = pool_size - self.free_count;
        }
    };
}

/// Default S2 scratch pool type (100 × 1MB).
pub const S2ScratchPool = S2ScratchPoolType(default_pool_size, default_buffer_size);

/// Smaller pool for testing (10 × 4KB).
pub const TestScratchPool = S2ScratchPoolType(10, 4 * 1024);

// =============================================================================
// Tests
// =============================================================================

test "S2ScratchPool: initialization" {
    const allocator = std.testing.allocator;

    var pool = try TestScratchPool.init(allocator);
    defer pool.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 10), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.usedCount());
    try std.testing.expect(!pool.isExhausted());
}

test "S2ScratchPool: acquire and release" {
    const allocator = std.testing.allocator;

    var pool = try TestScratchPool.init(allocator);
    defer pool.deinit(allocator);

    // Acquire a buffer
    const buffer = pool.acquire().?;
    try std.testing.expectEqual(@as(usize, 9), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.usedCount());

    // Write to buffer to verify it's usable
    const slice = buffer.slice();
    try std.testing.expectEqual(@as(usize, 4 * 1024), slice.len);
    slice[0] = 42;
    slice[slice.len - 1] = 99;

    // Release the buffer
    pool.release(buffer);
    try std.testing.expectEqual(@as(usize, 10), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.usedCount());
}

test "S2ScratchPool: exhaustion" {
    const allocator = std.testing.allocator;
    // Buffer size must be at least page_size_min for alignment requirements
    const SmallPool = S2ScratchPoolType(3, std.heap.page_size_min);

    var pool = try SmallPool.init(allocator);
    defer pool.deinit(allocator);

    // Acquire all buffers
    const b1 = pool.acquire().?;
    const b2 = pool.acquire().?;
    const b3 = pool.acquire().?;

    try std.testing.expect(pool.isExhausted());
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());

    // Next acquire should return null
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.exhausted);

    // Release one and acquire should succeed again
    pool.release(b2);
    try std.testing.expect(!pool.isExhausted());

    const b4 = pool.acquire().?;
    try std.testing.expect(pool.isExhausted());

    // Cleanup
    pool.release(b1);
    pool.release(b3);
    pool.release(b4);
}

test "S2ScratchPool: typed access" {
    const allocator = std.testing.allocator;

    var pool = try TestScratchPool.init(allocator);
    defer pool.deinit(allocator);

    const buffer = pool.acquire().?;
    defer pool.release(buffer);

    // Get typed slice for u64 values
    const u64_slice = buffer.typed(u64, 100);
    try std.testing.expectEqual(@as(usize, 100), u64_slice.len);

    // Write and verify
    for (u64_slice, 0..) |*ptr, i| {
        ptr.* = i * 7;
    }
    try std.testing.expectEqual(@as(u64, 0), u64_slice[0]);
    try std.testing.expectEqual(@as(u64, 693), u64_slice[99]);
}

test "S2ScratchPool: statistics" {
    const allocator = std.testing.allocator;
    // Buffer size must be at least page_size_min for alignment requirements
    const SmallPool = S2ScratchPoolType(3, std.heap.page_size_min);

    var pool = try SmallPool.init(allocator);
    defer pool.deinit(allocator);

    // Initial stats
    try std.testing.expectEqual(@as(u64, 0), pool.stats.acquires);
    try std.testing.expectEqual(@as(u64, 0), pool.stats.acquired);

    // Acquire two buffers
    const b1 = pool.acquire().?;
    const b2 = pool.acquire().?;

    try std.testing.expectEqual(@as(u64, 2), pool.stats.acquires);
    try std.testing.expectEqual(@as(u64, 2), pool.stats.acquired);
    try std.testing.expectEqual(@as(usize, 2), pool.stats.current_usage);
    try std.testing.expectEqual(@as(usize, 2), pool.stats.peak_usage);

    // Release one
    pool.release(b1);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.released);
    try std.testing.expectEqual(@as(usize, 1), pool.stats.current_usage);
    try std.testing.expectEqual(@as(usize, 2), pool.stats.peak_usage); // Peak unchanged

    pool.release(b2);
}

test "S2ScratchPool: multiple buffers different indices" {
    const allocator = std.testing.allocator;
    const buf_size = std.heap.page_size_min;
    const SmallPool = S2ScratchPoolType(4, buf_size);

    var pool = try SmallPool.init(allocator);
    defer pool.deinit(allocator);

    // Acquire all buffers and verify they have different indices
    const b1 = pool.acquire().?;
    const b2 = pool.acquire().?;
    const b3 = pool.acquire().?;
    const b4 = pool.acquire().?;

    try std.testing.expect(b1.index != b2.index);
    try std.testing.expect(b2.index != b3.index);
    try std.testing.expect(b3.index != b4.index);

    // Verify buffers don't overlap
    const p1 = @intFromPtr(b1.data);
    const p2 = @intFromPtr(b2.data);
    const p3 = @intFromPtr(b3.data);
    const p4 = @intFromPtr(b4.data);

    try std.testing.expect(@abs(@as(i64, @intCast(p2)) - @as(i64, @intCast(p1))) >= buf_size);
    try std.testing.expect(@abs(@as(i64, @intCast(p3)) - @as(i64, @intCast(p2))) >= buf_size);
    try std.testing.expect(@abs(@as(i64, @intCast(p4)) - @as(i64, @intCast(p3))) >= buf_size);

    pool.release(b1);
    pool.release(b2);
    pool.release(b3);
    pool.release(b4);
}

test "S2ScratchPool: reuse after release" {
    const allocator = std.testing.allocator;
    const SmallPool = S2ScratchPoolType(2, std.heap.page_size_min);

    var pool = try SmallPool.init(allocator);
    defer pool.deinit(allocator);

    // Acquire, release, acquire again
    const b1 = pool.acquire().?;
    const idx1 = b1.index;
    pool.release(b1);

    const b2 = pool.acquire().?;
    // Should get the same index back (first free slot)
    try std.testing.expectEqual(idx1, b2.index);

    pool.release(b2);
}

test "PoolStats: prometheus export" {
    const stats = PoolStats{
        .acquires = 100,
        .acquired = 95,
        .released = 90,
        .exhausted = 5,
        .peak_usage = 10,
        .current_usage = 5,
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try stats.toPrometheus(stream.writer());

    const output = stream.getWritten();
    const acq = "archerdb_s2_scratch_pool_acquires 100";
    const peak = "archerdb_s2_scratch_pool_peak_usage 10";
    try std.testing.expect(std.mem.indexOf(u8, output, acq) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, peak) != null);
}
