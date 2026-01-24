// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Write amplification and space amplification metrics for LSM-tree compaction.
//!
//! This module provides atomic counters and calculations for tracking:
//! - Write amplification: ratio of physical bytes written to logical (application) bytes
//! - Space amplification: ratio of physical storage used to logical data size
//! - Per-level write statistics for debugging and optimization
//!
//! All counters use atomic operations for thread-safe, lock-free access.

const std = @import("std");
const constants = @import("../constants.zig");

/// Write amplification metrics with atomic counters.
/// Tracks the ratio of physical I/O to logical writes across the LSM tree.
pub const WriteAmpMetrics = struct {
    /// Total logical bytes written by the application (user data).
    /// This represents the actual data size before LSM tree amplification.
    logical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total physical bytes written to storage.
    /// Includes flushes, compaction rewrites, and all disk I/O.
    physical_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Per-level write tracking for debugging.
    /// Index corresponds to LSM level (0 = L0, 1 = L1, etc.).
    level_writes: [constants.lsm_levels]std.atomic.Value(u64) = init_level_writes(),

    /// Bytes written during memtable flushes (memtable -> L0).
    /// This is the first stage of data reaching persistent storage.
    flush_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Initialize all level write counters to 0.
    fn init_level_writes() [constants.lsm_levels]std.atomic.Value(u64) {
        var writes: [constants.lsm_levels]std.atomic.Value(u64) = undefined;
        for (&writes) |*w| {
            w.* = std.atomic.Value(u64).init(0);
        }
        return writes;
    }

    /// Initialize a new WriteAmpMetrics instance with all counters at 0.
    pub fn init() WriteAmpMetrics {
        return .{};
    }

    /// Reset all counters to zero.
    pub fn reset(self: *WriteAmpMetrics) void {
        self.logical_bytes_written.store(0, .monotonic);
        self.physical_bytes_written.store(0, .monotonic);
        self.flush_bytes.store(0, .monotonic);
        for (&self.level_writes) |*w| {
            w.store(0, .monotonic);
        }
    }

    /// Record a physical write at the specified LSM level.
    /// Updates both the per-level counter and the total physical bytes counter.
    ///
    /// Arguments:
    ///   level: The LSM level (0-based) where the write occurred
    ///   bytes: Number of bytes written
    pub fn record_write(self: *WriteAmpMetrics, level: u8, bytes: u64) void {
        if (level < constants.lsm_levels) {
            _ = self.level_writes[level].fetchAdd(bytes, .monotonic);
        }
        _ = self.physical_bytes_written.fetchAdd(bytes, .monotonic);
    }

    /// Record a logical (application-level) write.
    /// This represents the actual user data before any amplification.
    ///
    /// Arguments:
    ///   bytes: Number of logical bytes written by the application
    pub fn record_logical_write(self: *WriteAmpMetrics, bytes: u64) void {
        _ = self.logical_bytes_written.fetchAdd(bytes, .monotonic);
    }

    /// Record bytes written during a memtable flush.
    /// Flushes move data from memory to L0 on disk.
    ///
    /// Arguments:
    ///   bytes: Number of bytes flushed to L0
    pub fn record_flush(self: *WriteAmpMetrics, bytes: u64) void {
        _ = self.flush_bytes.fetchAdd(bytes, .monotonic);
        // Flushes also count as physical writes at level 0
        _ = self.level_writes[0].fetchAdd(bytes, .monotonic);
        _ = self.physical_bytes_written.fetchAdd(bytes, .monotonic);
    }

    /// Calculate the overall write amplification ratio.
    /// Write amplification = physical_bytes / logical_bytes
    ///
    /// Returns:
    ///   The write amplification ratio (>= 1.0 normally).
    ///   Returns 1.0 if no logical bytes have been written (avoids division by zero).
    pub fn write_amplification(self: *const WriteAmpMetrics) f64 {
        const logical = self.logical_bytes_written.load(.monotonic);
        const physical = self.physical_bytes_written.load(.monotonic);

        if (logical == 0) return 1.0;

        return @as(f64, @floatFromInt(physical)) / @as(f64, @floatFromInt(logical));
    }

    /// Calculate the write amplification for a specific level.
    /// Level write amp = bytes_written_at_level / bytes_received_from_previous_level
    ///
    /// For L0: level_writes[0] / flush_bytes
    /// For L1+: level_writes[level] / level_writes[level-1]
    ///
    /// Arguments:
    ///   level: The LSM level to calculate amplification for
    ///
    /// Returns:
    ///   The level-specific write amplification ratio.
    ///   Returns 1.0 if the input source has zero bytes (avoids division by zero).
    pub fn level_write_amplification(self: *const WriteAmpMetrics, level: u8) f64 {
        if (level >= constants.lsm_levels) return 1.0;

        const level_bytes = self.level_writes[level].load(.monotonic);

        // For level 0, compare against flush bytes (input from memtable)
        // For higher levels, compare against previous level's output
        const input_bytes = if (level == 0)
            self.flush_bytes.load(.monotonic)
        else
            self.level_writes[level - 1].load(.monotonic);

        if (input_bytes == 0) return 1.0;

        return @as(f64, @floatFromInt(level_bytes)) / @as(f64, @floatFromInt(input_bytes));
    }

    /// Get the total bytes written at a specific level.
    pub fn get_level_bytes(self: *const WriteAmpMetrics, level: u8) u64 {
        if (level >= constants.lsm_levels) return 0;
        return self.level_writes[level].load(.monotonic);
    }

    /// Get the total physical bytes written across all levels.
    pub fn get_physical_bytes(self: *const WriteAmpMetrics) u64 {
        return self.physical_bytes_written.load(.monotonic);
    }

    /// Get the total logical bytes written by the application.
    pub fn get_logical_bytes(self: *const WriteAmpMetrics) u64 {
        return self.logical_bytes_written.load(.monotonic);
    }

    /// Get the total bytes flushed from memtable to L0.
    pub fn get_flush_bytes(self: *const WriteAmpMetrics) u64 {
        return self.flush_bytes.load(.monotonic);
    }
};

/// Calculate space amplification ratio.
/// Space amplification = physical_size / logical_size
///
/// This measures storage overhead from:
/// - Tombstones not yet garbage collected
/// - Duplicate keys across levels
/// - Block/page internal fragmentation
///
/// Arguments:
///   logical_size: The actual size of unique, live data
///   physical_size: The total size consumed on disk
///
/// Returns:
///   The space amplification ratio (>= 1.0 normally).
///   Returns 1.0 if logical_size is 0 (avoids division by zero).
pub fn space_amplification(logical_size: u64, physical_size: u64) f64 {
    if (logical_size == 0) return 1.0;
    return @as(f64, @floatFromInt(physical_size)) / @as(f64, @floatFromInt(logical_size));
}

/// Rolling window metrics for time-based analysis.
/// Tracks bytes written over 1-minute, 5-minute, and 1-hour windows.
pub const RollingWindowMetrics = struct {
    /// Window durations in nanoseconds.
    const WINDOW_1MIN_NS: u64 = 60 * std.time.ns_per_s;
    const WINDOW_5MIN_NS: u64 = 5 * 60 * std.time.ns_per_s;
    const WINDOW_1HR_NS: u64 = 60 * 60 * std.time.ns_per_s;

    /// Per-window tracking.
    pub const Window = struct {
        /// Bytes written during this window.
        bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Timestamp when this window started (nanoseconds since epoch).
        window_start_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    /// 1-minute rolling window.
    window_1min: Window = .{},
    /// 5-minute rolling window.
    window_5min: Window = .{},
    /// 1-hour rolling window.
    window_1hr: Window = .{},

    /// Initialize with current timestamp.
    pub fn init(current_time_ns: u64) RollingWindowMetrics {
        return .{
            .window_1min = .{ .window_start_ns = std.atomic.Value(u64).init(current_time_ns) },
            .window_5min = .{ .window_start_ns = std.atomic.Value(u64).init(current_time_ns) },
            .window_1hr = .{ .window_start_ns = std.atomic.Value(u64).init(current_time_ns) },
        };
    }

    /// Record bytes written (added to all active windows).
    pub fn record(self: *RollingWindowMetrics, bytes: u64) void {
        _ = self.window_1min.bytes_written.fetchAdd(bytes, .monotonic);
        _ = self.window_5min.bytes_written.fetchAdd(bytes, .monotonic);
        _ = self.window_1hr.bytes_written.fetchAdd(bytes, .monotonic);
    }

    /// Sample and rotate windows based on current time.
    /// Call this periodically (e.g., every second) to maintain accurate windows.
    ///
    /// Returns the bytes/second rates for each window that was rotated.
    pub fn sample(self: *RollingWindowMetrics, current_time_ns: u64) WindowRates {
        var rates: WindowRates = .{};

        // Check and rotate 1-minute window
        const start_1min = self.window_1min.window_start_ns.load(.monotonic);
        if (current_time_ns >= start_1min + WINDOW_1MIN_NS) {
            const bytes = self.window_1min.bytes_written.swap(0, .monotonic);
            const elapsed_ns = current_time_ns - start_1min;
            if (elapsed_ns > 0) {
                const bytes_f: f64 = @floatFromInt(bytes);
                const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
                rates.rate_1min = bytes_f / elapsed_s;
            }
            self.window_1min.window_start_ns.store(current_time_ns, .monotonic);
        }

        // Check and rotate 5-minute window
        const start_5min = self.window_5min.window_start_ns.load(.monotonic);
        if (current_time_ns >= start_5min + WINDOW_5MIN_NS) {
            const bytes = self.window_5min.bytes_written.swap(0, .monotonic);
            const elapsed_ns = current_time_ns - start_5min;
            if (elapsed_ns > 0) {
                const bytes_f: f64 = @floatFromInt(bytes);
                const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
                rates.rate_5min = bytes_f / elapsed_s;
            }
            self.window_5min.window_start_ns.store(current_time_ns, .monotonic);
        }

        // Check and rotate 1-hour window
        const start_1hr = self.window_1hr.window_start_ns.load(.monotonic);
        if (current_time_ns >= start_1hr + WINDOW_1HR_NS) {
            const bytes = self.window_1hr.bytes_written.swap(0, .monotonic);
            const elapsed_ns = current_time_ns - start_1hr;
            if (elapsed_ns > 0) {
                const bytes_f: f64 = @floatFromInt(bytes);
                const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
                rates.rate_1hr = bytes_f / elapsed_s;
            }
            self.window_1hr.window_start_ns.store(current_time_ns, .monotonic);
        }

        return rates;
    }

    /// Get current accumulated bytes for each window (useful for intermediate checks).
    pub fn get_current_bytes(self: *const RollingWindowMetrics) struct { min1: u64, min5: u64, hr1: u64 } {
        return .{
            .min1 = self.window_1min.bytes_written.load(.monotonic),
            .min5 = self.window_5min.bytes_written.load(.monotonic),
            .hr1 = self.window_1hr.bytes_written.load(.monotonic),
        };
    }
};

/// Rates calculated from rolling windows (bytes per second).
pub const WindowRates = struct {
    rate_1min: f64 = 0.0,
    rate_5min: f64 = 0.0,
    rate_1hr: f64 = 0.0,
};

// ============================================================================
// Unit Tests
// ============================================================================

test "WriteAmpMetrics: basic write amplification calculation" {
    var metrics = WriteAmpMetrics.init();

    // Record 1000 logical bytes
    metrics.record_logical_write(1000);

    // Record 3000 physical bytes (3x amplification)
    metrics.record_write(0, 1000);
    metrics.record_write(1, 2000);

    const wa = metrics.write_amplification();
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), wa, 0.001);
}

test "WriteAmpMetrics: zero logical bytes returns 1.0" {
    var metrics = WriteAmpMetrics.init();

    // Record physical bytes only
    metrics.record_write(0, 1000);

    const wa = metrics.write_amplification();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), wa, 0.001);
}

test "WriteAmpMetrics: per-level tracking" {
    var metrics = WriteAmpMetrics.init();

    // Record writes at different levels
    metrics.record_write(0, 100);
    metrics.record_write(1, 200);
    metrics.record_write(2, 300);

    try std.testing.expectEqual(@as(u64, 100), metrics.get_level_bytes(0));
    try std.testing.expectEqual(@as(u64, 200), metrics.get_level_bytes(1));
    try std.testing.expectEqual(@as(u64, 300), metrics.get_level_bytes(2));
    try std.testing.expectEqual(@as(u64, 600), metrics.get_physical_bytes());
}

test "WriteAmpMetrics: flush tracking" {
    var metrics = WriteAmpMetrics.init();

    // Flush 500 bytes from memtable to L0
    metrics.record_flush(500);

    try std.testing.expectEqual(@as(u64, 500), metrics.get_flush_bytes());
    // Flush should also count as L0 write and physical write
    try std.testing.expectEqual(@as(u64, 500), metrics.get_level_bytes(0));
    try std.testing.expectEqual(@as(u64, 500), metrics.get_physical_bytes());
}

test "WriteAmpMetrics: level write amplification" {
    var metrics = WriteAmpMetrics.init();

    // Flush 1000 bytes to L0
    metrics.record_flush(1000);

    // Compaction writes 2000 bytes to L1 (2x amplification at L1)
    metrics.record_write(1, 2000);

    // L0 amplification = L0 bytes / flush bytes = 1000/1000 = 1.0
    const l0_amp = metrics.level_write_amplification(0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), l0_amp, 0.001);

    // L1 amplification = L1 bytes / L0 bytes = 2000/1000 = 2.0
    const l1_amp = metrics.level_write_amplification(1);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), l1_amp, 0.001);
}

test "WriteAmpMetrics: reset clears all counters" {
    var metrics = WriteAmpMetrics.init();

    metrics.record_logical_write(1000);
    metrics.record_write(0, 500);
    metrics.record_flush(200);

    metrics.reset();

    try std.testing.expectEqual(@as(u64, 0), metrics.get_logical_bytes());
    try std.testing.expectEqual(@as(u64, 0), metrics.get_physical_bytes());
    try std.testing.expectEqual(@as(u64, 0), metrics.get_flush_bytes());
    try std.testing.expectEqual(@as(u64, 0), metrics.get_level_bytes(0));
}

test "space_amplification: basic calculation" {
    // 1000 bytes logical, 2500 bytes physical = 2.5x amplification
    const sa = space_amplification(1000, 2500);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), sa, 0.001);
}

test "space_amplification: zero logical size returns 1.0" {
    const sa = space_amplification(0, 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sa, 0.001);
}

test "space_amplification: equal sizes returns 1.0" {
    const sa = space_amplification(1000, 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sa, 0.001);
}

test "RollingWindowMetrics: record accumulates bytes" {
    var rolling = RollingWindowMetrics.init(0);

    rolling.record(100);
    rolling.record(200);
    rolling.record(300);

    const bytes = rolling.get_current_bytes();
    try std.testing.expectEqual(@as(u64, 600), bytes.min1);
    try std.testing.expectEqual(@as(u64, 600), bytes.min5);
    try std.testing.expectEqual(@as(u64, 600), bytes.hr1);
}

test "RollingWindowMetrics: sample rotates expired windows" {
    const start_ns: u64 = 0;
    var rolling = RollingWindowMetrics.init(start_ns);

    // Record some bytes
    rolling.record(6000);

    // Advance time by 61 seconds (past 1-minute window)
    const after_1min = start_ns + 61 * std.time.ns_per_s;
    const rates = rolling.sample(after_1min);

    // 1-minute rate should be ~100 bytes/sec (6000 bytes / ~60 seconds)
    // (Actual calculation accounts for 61 seconds elapsed)
    try std.testing.expect(rates.rate_1min > 90.0 and rates.rate_1min < 110.0);

    // 5-minute and 1-hour windows should not have rotated yet
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rates.rate_5min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rates.rate_1hr, 0.001);

    // The 1-minute window bytes should be reset
    const bytes = rolling.get_current_bytes();
    try std.testing.expectEqual(@as(u64, 0), bytes.min1);
    // 5-minute and 1-hour still have accumulated bytes
    try std.testing.expectEqual(@as(u64, 6000), bytes.min5);
    try std.testing.expectEqual(@as(u64, 6000), bytes.hr1);
}
