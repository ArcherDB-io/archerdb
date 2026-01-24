// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Memory allocation tracking for test builds.
//!
//! Provides a wrapper around any allocator that tracks:
//! - Total allocations and frees
//! - Current and peak allocated bytes
//! - Memory leak detection
//!
//! For detailed stack traces on leaks, use std.heap.DebugAllocator directly.
//!
//! Usage:
//!     var tracker = TrackingAllocator.init(std.testing.allocator);
//!     defer _ = tracker.deinit();
//!
//!     const alloc = tracker.allocator();
//!     // Use alloc for allocations...
//!
//!     const stats = tracker.getStats();
//!     // Inspect stats...

const std = @import("std");

/// Statistics for tracked allocations.
pub const AllocationStats = struct {
    total_allocations: usize,
    total_frees: usize,
    current_allocated_bytes: usize,
    peak_allocated_bytes: usize,

    /// Returns true if there are outstanding allocations.
    pub fn hasLeaks(self: AllocationStats) bool {
        return self.total_allocations != self.total_frees;
    }

    /// Returns the number of leaked allocations.
    pub fn leakedCount(self: AllocationStats) usize {
        if (self.total_allocations > self.total_frees) {
            return self.total_allocations - self.total_frees;
        }
        return 0;
    }
};

/// Result of leak check during deinit.
pub const LeakCheckResult = enum {
    ok,
    leak,
};

/// Memory allocation tracker wrapping any allocator.
///
/// Tracks allocation statistics and can detect memory leaks.
/// For stack traces on leaks, use std.heap.DebugAllocator as the backing allocator.
pub const TrackingAllocator = struct {
    backing_allocator: std.mem.Allocator,

    // Statistics
    total_allocations: usize,
    total_frees: usize,
    current_allocated_bytes: usize,
    peak_allocated_bytes: usize,

    const Self = @This();

    /// Initialize with a backing allocator.
    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return .{
            .backing_allocator = backing_allocator,
            .total_allocations = 0,
            .total_frees = 0,
            .current_allocated_bytes = 0,
            .peak_allocated_bytes = 0,
        };
    }

    /// Deinitialize and check for leaks.
    /// Returns .leak if any allocations were not freed.
    pub fn deinit(self: *Self) LeakCheckResult {
        const result: LeakCheckResult = if (self.hasLeaks()) .leak else .ok;
        self.* = undefined;
        return result;
    }

    /// Get an allocator interface that tracks statistics.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Get current allocation statistics.
    pub fn getStats(self: *const Self) AllocationStats {
        return .{
            .total_allocations = self.total_allocations,
            .total_frees = self.total_frees,
            .current_allocated_bytes = self.current_allocated_bytes,
            .peak_allocated_bytes = self.peak_allocated_bytes,
        };
    }

    /// Check if there are any leaked allocations.
    pub fn hasLeaks(self: *const Self) bool {
        return self.total_allocations > self.total_frees;
    }

    /// Dump leak information to a writer.
    pub fn dumpLeaks(self: *const Self, writer: anytype) !void {
        const stats = self.getStats();
        if (stats.hasLeaks()) {
            try writer.print("Memory leak detected!\n", .{});
            try writer.print("  Outstanding allocations: {d}\n", .{stats.leakedCount()});
            try writer.print("  Current allocated bytes: {d}\n", .{stats.current_allocated_bytes});
            try writer.print("  Total allocations: {d}\n", .{stats.total_allocations});
            try writer.print("  Total frees: {d}\n", .{stats.total_frees});
            try writer.print("  Peak allocated bytes: {d}\n", .{stats.peak_allocated_bytes});
        } else {
            try writer.print("No memory leaks detected.\n", .{});
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.total_allocations += 1;
            self.current_allocated_bytes += len;
            if (self.current_allocated_bytes > self.peak_allocated_bytes) {
                self.peak_allocated_bytes = self.current_allocated_bytes;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            // Update current allocated bytes based on size change
            if (new_len > old_len) {
                self.current_allocated_bytes += (new_len - old_len);
            } else {
                self.current_allocated_bytes -= (old_len - new_len);
            }
            if (self.current_allocated_bytes > self.peak_allocated_bytes) {
                self.peak_allocated_bytes = self.current_allocated_bytes;
            }
        }
        return result;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.backing_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null) {
            // Update current allocated bytes based on size change
            if (new_len > old_len) {
                self.current_allocated_bytes += (new_len - old_len);
            } else {
                self.current_allocated_bytes -= (old_len - new_len);
            }
            if (self.current_allocated_bytes > self.peak_allocated_bytes) {
                self.peak_allocated_bytes = self.current_allocated_bytes;
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
        self.total_frees += 1;
        if (self.current_allocated_bytes >= buf.len) {
            self.current_allocated_bytes -= buf.len;
        } else {
            self.current_allocated_bytes = 0;
        }
    }
};

/// Create a tracking allocator wrapping the page allocator.
/// Useful for standalone test scenarios.
pub fn createTestAllocator() TrackingAllocator {
    return TrackingAllocator.init(std.heap.page_allocator);
}

/// Create a tracking allocator with debug capabilities.
/// Uses std.heap.DebugAllocator for stack traces on leaks.
/// Returns struct with both the debug allocator (for deinit) and tracking allocator.
pub const DebugTrackingAllocator = struct {
    debug_allocator: std.heap.DebugAllocator(.{
        .stack_trace_frames = 10,
        .retain_metadata = true,
        .never_unmap = true,
    }),
    tracker: TrackingAllocator,

    const Self = @This();

    pub fn init() Self {
        var self: Self = .{
            .debug_allocator = .{
                .backing_allocator = std.heap.page_allocator,
            },
            .tracker = undefined,
        };
        self.tracker = TrackingAllocator.init(self.debug_allocator.allocator());
        return self;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.tracker.allocator();
    }

    pub fn getStats(self: *const Self) AllocationStats {
        return self.tracker.getStats();
    }

    pub fn hasLeaks(self: *const Self) bool {
        return self.tracker.hasLeaks();
    }

    pub fn deinit(self: *Self) LeakCheckResult {
        const tracker_result = self.tracker.deinit();
        const debug_result = self.debug_allocator.deinit();
        // Return leak if either detected a leak
        if (tracker_result == .leak or debug_result == .leak) {
            return .leak;
        }
        return .ok;
    }
};

/// Format allocation statistics as human-readable output.
pub fn formatStats(stats: AllocationStats, writer: anytype) !void {
    try writer.print("Allocation Statistics:\n", .{});
    try writer.print("  Total allocations: {d}\n", .{stats.total_allocations});
    try writer.print("  Total frees:       {d}\n", .{stats.total_frees});
    try writer.print("  Current bytes:     {d}\n", .{stats.current_allocated_bytes});
    try writer.print("  Peak bytes:        {d}\n", .{stats.peak_allocated_bytes});
    if (stats.hasLeaks()) {
        try writer.print("  STATUS: LEAK DETECTED ({d} outstanding)\n", .{stats.leakedCount()});
    } else {
        try writer.print("  STATUS: OK (no leaks)\n", .{});
    }
}

// Tests for allocator tracking
test "TrackingAllocator: basic allocation" {
    var tracker = TrackingAllocator.init(std.testing.allocator);

    const alloc = tracker.allocator();
    const data = try alloc.alloc(u8, 1024);

    var stats = tracker.getStats();
    try std.testing.expect(stats.total_allocations == 1);
    try std.testing.expect(stats.current_allocated_bytes == 1024);
    try std.testing.expect(stats.peak_allocated_bytes == 1024);
    try std.testing.expect(stats.hasLeaks());

    alloc.free(data);

    stats = tracker.getStats();
    try std.testing.expect(stats.total_frees == 1);
    try std.testing.expect(stats.current_allocated_bytes == 0);
    try std.testing.expect(!stats.hasLeaks());

    const result = tracker.deinit();
    try std.testing.expect(result == .ok);
}

test "TrackingAllocator: peak tracking" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    defer _ = tracker.deinit();

    const alloc = tracker.allocator();

    // Allocate 1KB
    const data1 = try alloc.alloc(u8, 1024);
    try std.testing.expect(tracker.getStats().peak_allocated_bytes == 1024);

    // Allocate another 2KB - peak should be 3KB
    const data2 = try alloc.alloc(u8, 2048);
    try std.testing.expect(tracker.getStats().peak_allocated_bytes == 3072);

    // Free first - peak should still be 3KB
    alloc.free(data1);
    try std.testing.expect(tracker.getStats().peak_allocated_bytes == 3072);
    try std.testing.expect(tracker.getStats().current_allocated_bytes == 2048);

    alloc.free(data2);
}

test "TrackingAllocator: multiple allocations" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    defer _ = tracker.deinit();

    const alloc = tracker.allocator();

    var buffers: [10][]u8 = undefined;
    for (&buffers) |*buf| {
        buf.* = try alloc.alloc(u8, 100);
    }

    const stats = tracker.getStats();
    try std.testing.expect(stats.total_allocations == 10);
    try std.testing.expect(stats.current_allocated_bytes == 1000);

    for (buffers) |buf| {
        alloc.free(buf);
    }

    try std.testing.expect(!tracker.hasLeaks());
}

test "formatStats: output format" {
    const stats = AllocationStats{
        .total_allocations = 5,
        .total_frees = 5,
        .current_allocated_bytes = 0,
        .peak_allocated_bytes = 1024,
    };

    var buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try formatStats(stats, fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Total allocations: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STATUS: OK") != null);
}
