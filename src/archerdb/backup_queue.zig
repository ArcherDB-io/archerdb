// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup Queue Implementation (F5.5.2)
//!
//! This module provides the backup queue that manages pending block uploads
//! to object storage. It implements two operating modes with different
//! durability/availability trade-offs:
//!
//! - best-effort (default): Prioritizes availability over backup completeness
//! - mandatory: Prioritizes durability, halts writes if backup queue fills up
//!
//! See: openspec/changes/add-geospatial-core/specs/backup-restore/spec.md
//!
//! Usage:
//! ```zig
//! var queue = BackupQueue.init(allocator, .{
//!     .mode = .best_effort,
//!     .soft_limit = 50,
//!     .hard_limit = 100,
//! });
//! defer queue.deinit();
//!
//! // Enqueue a block for backup
//! try queue.enqueue(.{ .sequence = 1000, .address = 0x1234, ... });
//!
//! // Check if writes should be blocked (mandatory mode)
//! if (queue.shouldBlockWrites()) {
//!     return error.backup_required;
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const log = std.log.scoped(.backup_queue);

const backup_config = @import("backup_config.zig");
const BackupMode = backup_config.BackupMode;
const BlockRef = backup_config.BlockRef;

// Test-safe logging wrapper
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.warn(fmt, args);
    }
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.info(fmt, args);
    }
}

/// Error code for backup-required state (writes halted).
/// Returns to client when mandatory mode blocks writes.
pub const BackupQueueError = error{
    /// Error code 212: Writes halted pending backup completion.
    /// In mandatory mode, this is returned when the backup queue exceeds hard_limit.
    backup_required,
    /// Queue is at capacity, cannot accept more blocks.
    queue_full,
    /// Block was not found in the queue.
    block_not_found,
};

/// Result of enqueue operation.
pub const EnqueueResult = enum {
    /// Block successfully queued for backup.
    queued,
    /// Block queued, but soft limit exceeded (warning logged).
    queued_over_soft_limit,
    /// Block dropped without backup (best-effort mode, queue full).
    abandoned,
    /// Writes should be blocked (mandatory mode, queue full).
    blocked,
};

/// Queue configuration options.
pub const QueueOptions = struct {
    /// Operating mode: best-effort or mandatory.
    mode: BackupMode = .best_effort,
    /// Soft limit: log warning when exceeded.
    soft_limit: u32 = 50,
    /// Hard limit: apply backpressure or halt writes.
    hard_limit: u32 = 100,
    /// Timeout before emergency bypass (in seconds). Default: 1 hour.
    /// Only applicable in mandatory mode.
    mandatory_halt_timeout_secs: u32 = 3600,
};

/// Statistics for monitoring backup queue health.
pub const QueueStats = struct {
    /// Current number of pending blocks.
    pending_count: u32 = 0,
    /// Total blocks successfully uploaded.
    uploaded_total: u64 = 0,
    /// Total failed upload attempts.
    failed_total: u64 = 0,
    /// Blocks abandoned without backup (best-effort mode).
    abandoned_total: u64 = 0,
    /// Times emergency bypass was triggered (mandatory mode).
    emergency_bypass_total: u64 = 0,
    /// Timestamp when writes were first halted (for timeout tracking).
    halt_started_ns: ?i128 = null,
    /// Whether writes are currently halted.
    writes_halted: bool = false,
};

/// Pending upload entry with retry tracking.
pub const PendingUpload = struct {
    /// Block reference to upload.
    block: BlockRef,
    /// Number of upload attempts.
    attempt_count: u8 = 0,
    /// Timestamp of last attempt (nanoseconds).
    last_attempt_ns: i128 = 0,
    /// Next retry timestamp (nanoseconds).
    next_retry_ns: i128 = 0,
};

/// Backup queue managing pending uploads with mode-specific behavior.
pub const BackupQueue = struct {
    allocator: mem.Allocator,
    options: QueueOptions,
    stats: QueueStats,

    /// Queue of pending uploads (FIFO).
    pending: std.ArrayList(PendingUpload),
    /// Set of block sequences currently in queue (for deduplication).
    pending_sequences: std.AutoHashMap(u64, void),

    /// Initialize backup queue.
    pub fn init(allocator: mem.Allocator, options: QueueOptions) BackupQueue {
        return .{
            .allocator = allocator,
            .options = options,
            .stats = .{},
            .pending = std.ArrayList(PendingUpload).init(allocator),
            .pending_sequences = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *BackupQueue) void {
        self.pending.deinit();
        self.pending_sequences.deinit();
    }

    /// Get current queue depth.
    pub fn depth(self: *const BackupQueue) u32 {
        return @intCast(self.pending.items.len);
    }

    /// Check if queue is at or over soft limit.
    pub fn isOverSoftLimit(self: *const BackupQueue) bool {
        return self.depth() >= self.options.soft_limit;
    }

    /// Check if queue is at or over hard limit.
    pub fn isOverHardLimit(self: *const BackupQueue) bool {
        return self.depth() >= self.options.hard_limit;
    }

    /// Check if writes should be blocked (mandatory mode only).
    /// Returns true if writes should be halted and backup_required error returned.
    pub fn shouldBlockWrites(self: *BackupQueue) bool {
        if (self.options.mode != .mandatory) {
            return false;
        }

        // Check for emergency bypass timeout
        if (self.stats.halt_started_ns) |halt_start| {
            const now = std.time.nanoTimestamp();
            const elapsed_ns = now - halt_start;
            const timeout_ns: i128 = @as(i128, self.options.mandatory_halt_timeout_secs) * std.time.ns_per_s;

            if (elapsed_ns > timeout_ns) {
                // Trigger emergency bypass
                self.triggerEmergencyBypass();
                return false;
            }
        }

        return self.isOverHardLimit();
    }

    /// Trigger emergency bypass - switch to best-effort mode.
    /// Called when mandatory halt timeout is exceeded.
    fn triggerEmergencyBypass(self: *BackupQueue) void {
        logErr("Backup mandatory mode HALT TIMEOUT exceeded - switching to best-effort to restore availability", .{});

        self.options.mode = .best_effort;
        self.stats.emergency_bypass_total += 1;
        self.stats.writes_halted = false;
        self.stats.halt_started_ns = null;
    }

    /// Enqueue a block for backup.
    /// Returns the result of the operation based on queue state and mode.
    pub fn enqueue(self: *BackupQueue, block: BlockRef) EnqueueResult {
        // Check for duplicate
        if (self.pending_sequences.contains(block.sequence)) {
            // Already queued, skip
            return .queued;
        }

        const current_depth = self.depth();

        // Check hard limit
        if (current_depth >= self.options.hard_limit) {
            if (self.options.mode == .mandatory) {
                // Mandatory mode: block writes
                if (!self.stats.writes_halted) {
                    logErr("Writes halted - backup mandatory mode, queue full (depth={})", .{current_depth});
                    self.stats.writes_halted = true;
                    self.stats.halt_started_ns = std.time.nanoTimestamp();
                }
                return .blocked;
            } else {
                // Best-effort mode: abandon oldest block to make room
                self.abandonOldest();
            }
        }

        // Add to queue
        const now = std.time.nanoTimestamp();
        self.pending.append(.{
            .block = block,
            .attempt_count = 0,
            .last_attempt_ns = 0,
            .next_retry_ns = now,
        }) catch {
            // Memory allocation failed - this is a critical error
            logErr("Failed to allocate backup queue entry", .{});
            self.stats.abandoned_total += 1;
            return .abandoned;
        };

        self.pending_sequences.put(block.sequence, {}) catch {
            // Memory allocation failed - remove from pending list
            _ = self.pending.pop();
            logErr("Failed to allocate backup sequence tracking", .{});
            self.stats.abandoned_total += 1;
            return .abandoned;
        };

        self.stats.pending_count = @intCast(self.pending.items.len);

        // Check soft limit for warning
        if (self.isOverSoftLimit()) {
            logWarn("Backup queue over soft limit: depth={}, soft_limit={}", .{
                self.depth(),
                self.options.soft_limit,
            });
            return .queued_over_soft_limit;
        }

        return .queued;
    }

    /// Abandon the oldest pending block (best-effort mode).
    fn abandonOldest(self: *BackupQueue) void {
        if (self.pending.items.len == 0) return;

        const oldest = self.pending.orderedRemove(0);
        _ = self.pending_sequences.remove(oldest.block.sequence);

        self.stats.abandoned_total += 1;
        self.stats.pending_count = @intCast(self.pending.items.len);

        logWarn("Abandoned block {} without backup (queue full)", .{oldest.block.sequence});
    }

    /// Get next block ready for upload (respects retry timing).
    /// Returns null if no blocks are ready.
    pub fn dequeue(self: *BackupQueue) ?*PendingUpload {
        const now = std.time.nanoTimestamp();

        for (self.pending.items) |*upload| {
            if (upload.next_retry_ns <= now) {
                return upload;
            }
        }

        return null;
    }

    /// Mark a block as successfully uploaded.
    /// Removes it from the queue.
    pub fn markUploaded(self: *BackupQueue, sequence: u64) BackupQueueError!void {
        // Find and remove the block
        var index: ?usize = null;
        for (self.pending.items, 0..) |upload, i| {
            if (upload.block.sequence == sequence) {
                index = i;
                break;
            }
        }

        if (index) |i| {
            _ = self.pending.orderedRemove(i);
            _ = self.pending_sequences.remove(sequence);

            self.stats.uploaded_total += 1;
            self.stats.pending_count = @intCast(self.pending.items.len);

            // Resume writes if queue drained below soft limit
            if (self.stats.writes_halted and !self.isOverSoftLimit()) {
                logInfo("Backup queue drained below soft limit, resuming writes", .{});
                self.stats.writes_halted = false;
                self.stats.halt_started_ns = null;
            }
        } else {
            return BackupQueueError.block_not_found;
        }
    }

    /// Mark a block upload as failed, schedule retry with exponential backoff.
    /// Returns true if retry scheduled, false if max retries exceeded.
    pub fn markFailed(self: *BackupQueue, sequence: u64) BackupQueueError!bool {
        const max_attempts: u8 = 5;
        const backoff_schedule = [_]i128{
            1 * std.time.ns_per_s, // 1s
            2 * std.time.ns_per_s, // 2s
            4 * std.time.ns_per_s, // 4s
            8 * std.time.ns_per_s, // 8s
            16 * std.time.ns_per_s, // 16s max
        };

        // Find the block
        for (self.pending.items) |*upload| {
            if (upload.block.sequence == sequence) {
                const now = std.time.nanoTimestamp();
                upload.attempt_count += 1;
                upload.last_attempt_ns = now;

                self.stats.failed_total += 1;

                if (upload.attempt_count >= max_attempts) {
                    logErr("Block {} backup failed after {} attempts", .{
                        sequence,
                        max_attempts,
                    });
                    return false;
                }

                // Calculate next retry with exponential backoff
                const backoff_index = @min(upload.attempt_count, backoff_schedule.len) - 1;
                const backoff = backoff_schedule[backoff_index];
                upload.next_retry_ns = now + backoff;

                logWarn("Block {} backup failed, attempt {}/{}, retry in {}s", .{
                    sequence,
                    upload.attempt_count,
                    max_attempts,
                    @divFloor(backoff, std.time.ns_per_s),
                });

                return true;
            }
        }

        return BackupQueueError.block_not_found;
    }

    /// Get current statistics.
    pub fn getStats(self: *const BackupQueue) QueueStats {
        return self.stats;
    }

    /// Check if the queue has any pending blocks.
    pub fn hasPending(self: *const BackupQueue) bool {
        return self.pending.items.len > 0;
    }

    /// Estimate time until queue clears (for error messages).
    /// Returns nanoseconds estimate based on average upload rate.
    /// Returns null if no uploads have completed yet.
    pub fn estimateDrainTimeNs(self: *const BackupQueue, avg_upload_ns: ?i128) ?i128 {
        if (avg_upload_ns) |avg| {
            return avg * @as(i128, self.depth());
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BackupQueue: init and deinit" {
    var queue = BackupQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    try std.testing.expectEqual(@as(u32, 0), queue.depth());
    try std.testing.expect(!queue.isOverSoftLimit());
    try std.testing.expect(!queue.isOverHardLimit());
}

test "BackupQueue: enqueue and dequeue" {
    var queue = BackupQueue.init(std.testing.allocator, .{
        .soft_limit = 5,
        .hard_limit = 10,
    });
    defer queue.deinit();

    // Enqueue a block
    const result = queue.enqueue(.{
        .sequence = 1000,
        .address = 0x1234,
        .checksum = 0xABCD,
        .closed_timestamp = 1000000,
    });

    try std.testing.expectEqual(EnqueueResult.queued, result);
    try std.testing.expectEqual(@as(u32, 1), queue.depth());

    // Dequeue should return the block
    const upload = queue.dequeue();
    try std.testing.expect(upload != null);
    try std.testing.expectEqual(@as(u64, 1000), upload.?.block.sequence);
}

test "BackupQueue: soft limit warning" {
    var queue = BackupQueue.init(std.testing.allocator, .{
        .soft_limit = 2,
        .hard_limit = 5,
    });
    defer queue.deinit();

    // First two blocks - under soft limit
    _ = queue.enqueue(.{ .sequence = 1, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    const result2 = queue.enqueue(.{ .sequence = 2, .address = 2, .checksum = 2, .closed_timestamp = 2 });
    try std.testing.expectEqual(EnqueueResult.queued_over_soft_limit, result2);
}

test "BackupQueue: hard limit best-effort abandons oldest" {
    var queue = BackupQueue.init(std.testing.allocator, .{
        .mode = .best_effort,
        .soft_limit = 2,
        .hard_limit = 3,
    });
    defer queue.deinit();

    // Fill to hard limit
    _ = queue.enqueue(.{ .sequence = 1, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    _ = queue.enqueue(.{ .sequence = 2, .address = 2, .checksum = 2, .closed_timestamp = 2 });
    _ = queue.enqueue(.{ .sequence = 3, .address = 3, .checksum = 3, .closed_timestamp = 3 });

    // Enqueue one more - should abandon oldest
    const result = queue.enqueue(.{ .sequence = 4, .address = 4, .checksum = 4, .closed_timestamp = 4 });
    try std.testing.expectEqual(EnqueueResult.queued_over_soft_limit, result);

    // Queue should still be at hard limit
    try std.testing.expectEqual(@as(u32, 3), queue.depth());

    // Oldest (sequence 1) should be gone
    try std.testing.expect(!queue.pending_sequences.contains(1));
    try std.testing.expect(queue.pending_sequences.contains(4));

    // Stats should reflect abandonment
    try std.testing.expectEqual(@as(u64, 1), queue.stats.abandoned_total);
}

test "BackupQueue: hard limit mandatory blocks writes" {
    var queue = BackupQueue.init(std.testing.allocator, .{
        .mode = .mandatory,
        .soft_limit = 2,
        .hard_limit = 3,
    });
    defer queue.deinit();

    // Fill to hard limit
    _ = queue.enqueue(.{ .sequence = 1, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    _ = queue.enqueue(.{ .sequence = 2, .address = 2, .checksum = 2, .closed_timestamp = 2 });
    _ = queue.enqueue(.{ .sequence = 3, .address = 3, .checksum = 3, .closed_timestamp = 3 });

    // Try to enqueue more - should block
    const result = queue.enqueue(.{ .sequence = 4, .address = 4, .checksum = 4, .closed_timestamp = 4 });
    try std.testing.expectEqual(EnqueueResult.blocked, result);

    // Writes should be halted
    try std.testing.expect(queue.shouldBlockWrites());
    try std.testing.expect(queue.stats.writes_halted);
}

test "BackupQueue: markUploaded removes block" {
    var queue = BackupQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    _ = queue.enqueue(.{ .sequence = 100, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    try std.testing.expectEqual(@as(u32, 1), queue.depth());

    try queue.markUploaded(100);
    try std.testing.expectEqual(@as(u32, 0), queue.depth());
    try std.testing.expectEqual(@as(u64, 1), queue.stats.uploaded_total);
}

test "BackupQueue: markFailed schedules retry" {
    var queue = BackupQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    _ = queue.enqueue(.{ .sequence = 100, .address = 1, .checksum = 1, .closed_timestamp = 1 });

    // First failure should schedule retry
    const should_retry = try queue.markFailed(100);
    try std.testing.expect(should_retry);
    try std.testing.expectEqual(@as(u8, 1), queue.pending.items[0].attempt_count);
    try std.testing.expectEqual(@as(u64, 1), queue.stats.failed_total);
}

test "BackupQueue: deduplication" {
    var queue = BackupQueue.init(std.testing.allocator, .{});
    defer queue.deinit();

    _ = queue.enqueue(.{ .sequence = 100, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    _ = queue.enqueue(.{ .sequence = 100, .address = 1, .checksum = 1, .closed_timestamp = 1 });

    // Should only have one entry
    try std.testing.expectEqual(@as(u32, 1), queue.depth());
}

test "BackupQueue: resume writes after drain" {
    var queue = BackupQueue.init(std.testing.allocator, .{
        .mode = .mandatory,
        .soft_limit = 2,
        .hard_limit = 3,
    });
    defer queue.deinit();

    // Fill queue and block writes
    _ = queue.enqueue(.{ .sequence = 1, .address = 1, .checksum = 1, .closed_timestamp = 1 });
    _ = queue.enqueue(.{ .sequence = 2, .address = 2, .checksum = 2, .closed_timestamp = 2 });
    _ = queue.enqueue(.{ .sequence = 3, .address = 3, .checksum = 3, .closed_timestamp = 3 });
    _ = queue.enqueue(.{ .sequence = 4, .address = 4, .checksum = 4, .closed_timestamp = 4 });

    try std.testing.expect(queue.stats.writes_halted);

    // Drain queue below soft limit
    try queue.markUploaded(1);
    try queue.markUploaded(2);

    // Writes should resume (depth now 1, below soft limit of 2)
    try std.testing.expect(!queue.stats.writes_halted);
}
