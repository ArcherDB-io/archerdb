// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup Coordinator for Multi-Replica Environments (F5.5.5)
//!
//! This module coordinates backup operations across multiple replicas to avoid
//! redundant uploads and reduce storage costs.
//!
//!
//! ## Coordination Strategies
//!
//! ### Default: All Replicas Backup (primary_only = false)
//! - Each replica backs up to its own path: `<bucket>/<cluster>/replica-N/blocks/`
//! - Provides maximum redundancy
//! - Higher storage costs (N copies)
//!
//! ### Primary-Only Backup (primary_only = true)
//! - Only the current VSR primary uploads blocks
//! - On view change, new primary automatically resumes
//! - Reduces storage costs to 1 copy
//! - Slightly lower redundancy (depends on single upload path)
//!
//! ## Usage
//!
//! ```zig
//! var coordinator = BackupCoordinator.init(.{
//!     .primary_only = true,
//!     .replica_count = 3,
//!     .replica_id = 1,
//! });
//!
//! // Check before each backup operation
//! if (coordinator.shouldBackup()) {
//!     // Proceed with backup
//! }
//!
//! // On VSR view change
//! coordinator.onViewChange(new_view);
//! ```

const std = @import("std");
const log = std.log.scoped(.backup_coordinator);
const builtin = @import("builtin");

/// Configuration for backup coordinator.
pub const CoordinatorConfig = struct {
    /// If true, only the primary replica performs backups.
    /// Default: false (all replicas backup independently).
    primary_only: bool = false,

    /// If true, only follower replicas perform backups (zero-impact online backups).
    /// When enabled, backups skip on primary to avoid impacting client traffic.
    /// Default: true (recommended for production workloads).
    /// Note: Takes precedence over primary_only if both are set.
    follower_only: bool = true,

    /// Total number of replicas in the cluster.
    replica_count: u8 = 1,

    /// This replica's ID (0-indexed).
    replica_id: u8 = 0,

    /// Initial view number (default 0).
    initial_view: u32 = 0,
};

/// Statistics for backup coordination.
pub const CoordinatorStats = struct {
    /// Number of blocks skipped due to not being primary.
    blocks_skipped_not_primary: u64 = 0,

    /// Number of blocks skipped due to being primary (follower_only mode).
    blocks_skipped_is_primary: u64 = 0,

    /// Number of view changes observed.
    view_changes: u64 = 0,

    /// Number of times this replica became primary.
    became_primary_count: u64 = 0,

    /// Number of times this replica became backup.
    became_backup_count: u64 = 0,

    /// Number of blocks uploaded successfully.
    blocks_uploaded: u64 = 0,

    /// Number of blocks queued for upload.
    blocks_queued: u64 = 0,
};

/// Replica role for backup coordination.
pub const ReplicaRole = enum {
    primary,
    follower,
    unknown,
};

/// Progress callback type for backup operations.
/// Called during backup with progress information.
pub const ProgressCallback = *const fn (blocks_done: u64, blocks_total: u64, context: ?*anyopaque) void;

/// Incremental backup state tracking.
pub const IncrementalState = struct {
    /// Last block sequence that was successfully backed up.
    last_backed_up_sequence: u64 = 0,

    /// Timestamp of last successful backup (seconds since epoch).
    last_backup_timestamp: i64 = 0,

    /// Number of blocks in current backup batch.
    current_batch_size: u64 = 0,

    /// Number of blocks completed in current batch.
    current_batch_done: u64 = 0,
};

/// Backup coordinator for multi-replica environments.
///
/// Determines whether this replica should perform backup operations based on
/// the configured strategy (all replicas, primary-only, or follower-only) and current VSR view.
///
/// Coordination modes:
/// - All replicas (default): Every replica backs up independently
/// - Primary-only: Only the VSR primary backs up (reduces storage costs)
/// - Follower-only: Only followers backup (zero-impact online backups)
pub const BackupCoordinator = struct {
    /// Configuration
    primary_only: bool,
    follower_only: bool,
    replica_count: u8,
    replica_id: u8,

    /// Current VSR view number
    view: u32,

    /// Coordination statistics
    stats: CoordinatorStats,

    /// Whether backup is currently active on this replica.
    /// Updated on view changes based on coordination mode.
    backup_active: bool,

    /// Incremental backup state for tracking progress.
    incremental: IncrementalState,

    /// Initialize backup coordinator.
    pub fn init(config: CoordinatorConfig) BackupCoordinator {
        const primary_idx = primaryIndex(config.initial_view, config.replica_count);
        const is_primary = primary_idx == config.replica_id;

        // Determine if backup should be active based on coordination mode
        // follower_only takes precedence over primary_only
        const backup_active = blk: {
            if (config.follower_only) {
                // Follower-only mode: backup only on non-primary replicas
                break :blk !is_primary;
            } else if (config.primary_only) {
                // Primary-only mode: backup only on primary
                break :blk is_primary;
            } else {
                // All replicas mode: always backup
                break :blk true;
            }
        };

        if (config.follower_only) {
            if (backup_active) {
                logInfo("Backup coordinator initialized as follower (view={}, replica={}) - zero-impact mode", .{
                    config.initial_view,
                    config.replica_id,
                });
            } else {
                logInfo("Backup coordinator initialized as primary (view={}, replica={}) - backup skipped (follower_only=true)", .{
                    config.initial_view,
                    config.replica_id,
                });
            }
        } else if (config.primary_only) {
            if (backup_active) {
                logInfo("Backup coordinator initialized as primary (view={}, replica={})", .{
                    config.initial_view,
                    config.replica_id,
                });
            } else {
                const primary = primaryIndex(config.initial_view, config.replica_count);
                logInfo(
                    "Backup coordinator initialized as backup (view={}, replica={}, primary={})",
                    .{ config.initial_view, config.replica_id, primary },
                );
            }
        } else {
            logInfo("Backup coordinator initialized (all replicas mode, replica={})", .{
                config.replica_id,
            });
        }

        return BackupCoordinator{
            .primary_only = config.primary_only,
            .follower_only = config.follower_only,
            .replica_count = config.replica_count,
            .replica_id = config.replica_id,
            .view = config.initial_view,
            .stats = .{},
            .backup_active = backup_active,
            .incremental = .{},
        };
    }

    /// Check if this replica should perform backup.
    ///
    /// Returns true if:
    /// - primary_only is false (all replicas backup), OR
    /// - primary_only is true AND this replica is the current primary
    pub fn shouldBackup(self: *const BackupCoordinator) bool {
        return self.backup_active;
    }

    /// Called when a VSR view change occurs.
    ///
    /// Updates whether this replica should perform backups based on:
    /// - follower_only mode: backups run on followers, pause on primary
    /// - primary_only mode: backups run on primary, pause on followers
    pub fn onViewChange(self: *BackupCoordinator, new_view: u32) void {
        if (new_view == self.view) return;

        const old_view = self.view;
        self.view = new_view;
        self.stats.view_changes += 1;

        // All replicas mode - no change needed
        if (!self.primary_only and !self.follower_only) {
            return;
        }

        const was_primary = primaryIndex(old_view, self.replica_count) == self.replica_id;
        const is_primary = primaryIndex(new_view, self.replica_count) == self.replica_id;

        if (self.follower_only) {
            // Follower-only mode: backup when NOT primary
            if (!was_primary and is_primary) {
                // Became primary - pause backup
                self.backup_active = false;
                self.stats.became_primary_count += 1;
                logInfo("View change {}->{}: This replica is now primary, pausing backup (follower_only=true)", .{
                    old_view,
                    new_view,
                });
            } else if (was_primary and !is_primary) {
                // Became follower - resume backup
                self.backup_active = true;
                self.stats.became_backup_count += 1;
                logInfo("View change {}->{}: This replica is now follower, resuming backup (follower_only=true)", .{
                    old_view,
                    new_view,
                });
            }
        } else if (self.primary_only) {
            // Primary-only mode: backup when primary
            if (was_primary and !is_primary) {
                // Became backup
                self.backup_active = false;
                self.stats.became_backup_count += 1;
                logInfo("View change {}->{}: This replica is no longer primary, pausing backup", .{
                    old_view,
                    new_view,
                });
            } else if (!was_primary and is_primary) {
                // Became primary
                self.backup_active = true;
                self.stats.became_primary_count += 1;
                logInfo("View change {}->{}: This replica is now primary, resuming backup", .{
                    old_view,
                    new_view,
                });
            }
        }
    }

    /// Record that a block was skipped because of coordination mode.
    /// Call this when shouldBackup() returns false but a block was ready.
    pub fn recordSkipped(self: *BackupCoordinator) void {
        if (self.follower_only and self.isPrimary()) {
            self.stats.blocks_skipped_is_primary += 1;
        } else {
            self.stats.blocks_skipped_not_primary += 1;
        }
    }

    /// Get the current replica role.
    pub fn getReplicaRole(self: *const BackupCoordinator) ReplicaRole {
        if (self.replica_count == 0) return .unknown;
        if (self.isPrimary()) return .primary;
        return .follower;
    }

    /// Check if a block needs to be backed up based on sequence number.
    /// Returns true if the block's sequence is newer than the last backed up sequence.
    pub fn needsBackup(self: *const BackupCoordinator, block_sequence: u64) bool {
        return block_sequence > self.incremental.last_backed_up_sequence;
    }

    /// Record successful backup of a block.
    pub fn recordBackedUp(self: *BackupCoordinator, block_sequence: u64, timestamp: i64) void {
        if (block_sequence > self.incremental.last_backed_up_sequence) {
            self.incremental.last_backed_up_sequence = block_sequence;
        }
        self.incremental.last_backup_timestamp = timestamp;
        self.stats.blocks_uploaded += 1;
        if (self.incremental.current_batch_done < self.incremental.current_batch_size) {
            self.incremental.current_batch_done += 1;
        }
    }

    /// Record that a block was queued for backup.
    pub fn recordQueued(self: *BackupCoordinator) void {
        self.stats.blocks_queued += 1;
    }

    /// Start a new backup batch with the given number of blocks.
    pub fn startBatch(self: *BackupCoordinator, batch_size: u64) void {
        self.incremental.current_batch_size = batch_size;
        self.incremental.current_batch_done = 0;
    }

    /// Get progress as (done, total) tuple.
    pub fn getProgress(self: *const BackupCoordinator) struct { done: u64, total: u64 } {
        return .{
            .done = self.incremental.current_batch_done,
            .total = self.incremental.current_batch_size,
        };
    }

    /// Execute backup bookkeeping with progress callbacks.
    ///
    /// This helper advances the coordinator's incremental state for a
    /// successful sequential batch and reports progress after each block.
    /// Production upload implementations can use it as the default synchronous
    /// path while more advanced async uploaders can drive `recordQueued()` and
    /// `recordBackedUp()` directly.
    pub fn backupWithProgress(
        self: *BackupCoordinator,
        blocks_to_backup: u64,
        callback: ?ProgressCallback,
        context: ?*anyopaque,
    ) void {
        self.startBatch(blocks_to_backup);

        if (callback) |cb| {
            cb(0, blocks_to_backup, context);
        }

        if (!self.shouldBackup()) {
            for (0..blocks_to_backup) |_| {
                self.recordSkipped();
            }
            return;
        }

        const base_timestamp = std.time.timestamp();
        var sequence = self.incremental.last_backed_up_sequence;
        var i: u64 = 0;
        while (i < blocks_to_backup) : (i += 1) {
            self.recordQueued();
            sequence += 1;
            self.recordBackedUp(sequence, base_timestamp + @as(i64, @intCast(i)));

            if (callback) |cb| {
                cb(self.incremental.current_batch_done, blocks_to_backup, context);
            }
        }
    }

    /// Get the last backed up sequence number.
    pub fn getLastBackedUpSequence(self: *const BackupCoordinator) u64 {
        return self.incremental.last_backed_up_sequence;
    }

    /// Get the timestamp of the last successful backup.
    pub fn getLastBackupTimestamp(self: *const BackupCoordinator) i64 {
        return self.incremental.last_backup_timestamp;
    }

    /// Set the initial state for incremental backup (e.g., loaded from persistent storage).
    pub fn setIncrementalState(self: *BackupCoordinator, last_sequence: u64, last_timestamp: i64) void {
        self.incremental.last_backed_up_sequence = last_sequence;
        self.incremental.last_backup_timestamp = last_timestamp;
    }

    /// Get the current primary replica ID.
    pub fn currentPrimary(self: *const BackupCoordinator) u8 {
        return primaryIndex(self.view, self.replica_count);
    }

    /// Check if this replica is currently the primary.
    pub fn isPrimary(self: *const BackupCoordinator) bool {
        return primaryIndex(self.view, self.replica_count) == self.replica_id;
    }

    /// Get coordination statistics.
    pub fn getStats(self: *const BackupCoordinator) CoordinatorStats {
        return self.stats;
    }

    /// Reset statistics.
    pub fn resetStats(self: *BackupCoordinator) void {
        self.stats = .{};
    }

    /// Calculate primary index for a given view.
    /// This matches VSR's primary selection: view % replica_count
    fn primaryIndex(view: u32, replica_count: u8) u8 {
        if (replica_count == 0) return 0;
        return @intCast(@mod(view, replica_count));
    }
};

// Logging helper that suppresses output during tests
fn logInfo(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.info(fmt, args);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "BackupCoordinator: all replicas mode" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = false,
        .follower_only = false, // Disable follower_only for all-replicas mode
        .replica_count = 3,
        .replica_id = 1,
    });

    // All replicas should backup in all-replicas mode
    try std.testing.expect(coordinator.shouldBackup());

    // View changes don't affect backup status
    coordinator.onViewChange(1);
    try std.testing.expect(coordinator.shouldBackup());

    coordinator.onViewChange(2);
    try std.testing.expect(coordinator.shouldBackup());
}

test "BackupCoordinator: primary-only mode - initial primary" {
    // Replica 0 is primary in view 0
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    try std.testing.expect(coordinator.shouldBackup());
    try std.testing.expect(coordinator.isPrimary());
    try std.testing.expectEqual(@as(u8, 0), coordinator.currentPrimary());
}

test "BackupCoordinator: primary-only mode - initial backup" {
    // Replica 1 is backup in view 0 (primary is 0)
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());
    try std.testing.expect(!coordinator.isPrimary());
}

test "BackupCoordinator: view change - becomes primary" {
    // Replica 1 starts as backup in view 0
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());

    // View 1: primary is 1 % 3 = 1
    coordinator.onViewChange(1);
    try std.testing.expect(coordinator.shouldBackup());
    try std.testing.expect(coordinator.isPrimary());
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_primary_count);
}

test "BackupCoordinator: view change - becomes backup" {
    // Replica 0 starts as primary in view 0
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    try std.testing.expect(coordinator.shouldBackup());

    // View 1: primary is 1, replica 0 becomes backup
    coordinator.onViewChange(1);
    try std.testing.expect(!coordinator.shouldBackup());
    try std.testing.expect(!coordinator.isPrimary());
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_backup_count);
}

test "BackupCoordinator: view change cycle" {
    // 3 replicas, test full view cycle
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    // View 0: replica 0 is primary
    try std.testing.expect(coordinator.shouldBackup());

    // View 1: replica 1 is primary
    coordinator.onViewChange(1);
    try std.testing.expect(!coordinator.shouldBackup());

    // View 2: replica 2 is primary
    coordinator.onViewChange(2);
    try std.testing.expect(!coordinator.shouldBackup());

    // View 3: replica 0 is primary again (3 % 3 = 0)
    coordinator.onViewChange(3);
    try std.testing.expect(coordinator.shouldBackup());

    try std.testing.expectEqual(@as(u64, 3), coordinator.stats.view_changes);
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_primary_count);
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_backup_count);
}

test "BackupCoordinator: recordSkipped updates stats" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 1, // Not primary in view 0
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());

    coordinator.recordSkipped();
    coordinator.recordSkipped();
    coordinator.recordSkipped();

    try std.testing.expectEqual(@as(u64, 3), coordinator.stats.blocks_skipped_not_primary);
}

test "BackupCoordinator: single replica always backups (primary_only)" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 1,
        .replica_id = 0,
    });

    // Single replica is always primary
    try std.testing.expect(coordinator.shouldBackup());

    // View changes still work (0 % 1 = 0)
    coordinator.onViewChange(1);
    try std.testing.expect(coordinator.shouldBackup());

    coordinator.onViewChange(100);
    try std.testing.expect(coordinator.shouldBackup());
}

test "BackupCoordinator: same view change is no-op" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false, // Explicitly disable follower_only
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    // Same view - should be no-op
    coordinator.onViewChange(0);
    try std.testing.expectEqual(@as(u64, 0), coordinator.stats.view_changes);
}

test "BackupCoordinator: primaryIndex calculation" {
    // Test primary index matches VSR formula: view % replica_count
    try std.testing.expectEqual(@as(u8, 0), BackupCoordinator.primaryIndex(0, 3));
    try std.testing.expectEqual(@as(u8, 1), BackupCoordinator.primaryIndex(1, 3));
    try std.testing.expectEqual(@as(u8, 2), BackupCoordinator.primaryIndex(2, 3));
    try std.testing.expectEqual(@as(u8, 0), BackupCoordinator.primaryIndex(3, 3));
    try std.testing.expectEqual(@as(u8, 1), BackupCoordinator.primaryIndex(4, 3));

    // Edge cases
    try std.testing.expectEqual(@as(u8, 0), BackupCoordinator.primaryIndex(0, 1));
    try std.testing.expectEqual(@as(u8, 0), BackupCoordinator.primaryIndex(100, 1));
    // Degenerate case
    try std.testing.expectEqual(@as(u8, 0), BackupCoordinator.primaryIndex(0, 0));
}

test "BackupCoordinator: stats reset" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 0,
    });

    coordinator.onViewChange(1);
    coordinator.recordSkipped();

    try std.testing.expect(coordinator.stats.view_changes > 0);

    coordinator.resetStats();

    try std.testing.expectEqual(@as(u64, 0), coordinator.stats.view_changes);
    try std.testing.expectEqual(@as(u64, 0), coordinator.stats.blocks_skipped_not_primary);
}

// =============================================================================
// Follower-Only Mode Tests (Zero-Impact Online Backups)
// =============================================================================

test "BackupCoordinator: follower-only mode - follower backups" {
    // Replica 1 is follower in view 0 (primary is 0)
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    // Follower should backup in follower_only mode
    try std.testing.expect(coordinator.shouldBackup());
    try std.testing.expect(!coordinator.isPrimary());
    try std.testing.expectEqual(ReplicaRole.follower, coordinator.getReplicaRole());
}

test "BackupCoordinator: follower-only mode - primary skipped" {
    // Replica 0 is primary in view 0
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    // Primary should NOT backup in follower_only mode (zero-impact)
    try std.testing.expect(!coordinator.shouldBackup());
    try std.testing.expect(coordinator.isPrimary());
    try std.testing.expectEqual(ReplicaRole.primary, coordinator.getReplicaRole());
}

test "BackupCoordinator: follower-only mode - view change to primary pauses backup" {
    // Replica 1 starts as follower in view 0
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    try std.testing.expect(coordinator.shouldBackup());

    // View 1: replica 1 becomes primary (1 % 3 = 1)
    coordinator.onViewChange(1);
    try std.testing.expect(!coordinator.shouldBackup());
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_primary_count);
}

test "BackupCoordinator: follower-only mode - view change to follower resumes backup" {
    // Replica 0 starts as primary in view 0
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());

    // View 1: replica 0 becomes follower (primary is 1)
    coordinator.onViewChange(1);
    try std.testing.expect(coordinator.shouldBackup());
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.became_backup_count);
}

test "BackupCoordinator: follower-only takes precedence over primary-only" {
    // If both are set, follower_only wins
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 0, // Primary in view 0
        .initial_view = 0,
    });

    // follower_only=true means primary should NOT backup
    try std.testing.expect(!coordinator.shouldBackup());
}

test "BackupCoordinator: follower-only mode - single replica always primary" {
    // Single replica is always primary, so backup is always skipped
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 1,
        .replica_id = 0,
    });

    // Single replica = always primary = never backups in follower_only mode
    try std.testing.expect(!coordinator.shouldBackup());
}

test "BackupCoordinator: follower-only mode - recordSkipped tracks correctly" {
    var coordinator = BackupCoordinator.init(.{
        .follower_only = true,
        .replica_count = 3,
        .replica_id = 0, // Primary in view 0
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());

    coordinator.recordSkipped();
    coordinator.recordSkipped();

    // Should track as skipped due to being primary
    try std.testing.expectEqual(@as(u64, 2), coordinator.stats.blocks_skipped_is_primary);
    try std.testing.expectEqual(@as(u64, 0), coordinator.stats.blocks_skipped_not_primary);
}

// =============================================================================
// Incremental Backup Tests
// =============================================================================

test "BackupCoordinator: incremental backup - needsBackup" {
    var coordinator = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    // Initially, all sequences need backup
    try std.testing.expect(coordinator.needsBackup(1));
    try std.testing.expect(coordinator.needsBackup(100));

    // After backing up sequence 50, only > 50 needs backup
    coordinator.recordBackedUp(50, 1000);
    try std.testing.expect(!coordinator.needsBackup(1));
    try std.testing.expect(!coordinator.needsBackup(50));
    try std.testing.expect(coordinator.needsBackup(51));
    try std.testing.expect(coordinator.needsBackup(100));
}

test "BackupCoordinator: incremental backup - state tracking" {
    var coordinator = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    try std.testing.expectEqual(@as(u64, 0), coordinator.getLastBackedUpSequence());
    try std.testing.expectEqual(@as(i64, 0), coordinator.getLastBackupTimestamp());

    coordinator.recordBackedUp(100, 1234567890);

    try std.testing.expectEqual(@as(u64, 100), coordinator.getLastBackedUpSequence());
    try std.testing.expectEqual(@as(i64, 1234567890), coordinator.getLastBackupTimestamp());
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.blocks_uploaded);
}

test "BackupCoordinator: incremental backup - set initial state" {
    var coordinator = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    // Simulate loading state from persistent storage
    coordinator.setIncrementalState(500, 1234567890);

    try std.testing.expectEqual(@as(u64, 500), coordinator.getLastBackedUpSequence());
    try std.testing.expectEqual(@as(i64, 1234567890), coordinator.getLastBackupTimestamp());

    // Only sequences > 500 need backup
    try std.testing.expect(!coordinator.needsBackup(500));
    try std.testing.expect(coordinator.needsBackup(501));
}

test "BackupCoordinator: incremental backup - batch progress" {
    var coordinator = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    coordinator.startBatch(10);
    const progress1 = coordinator.getProgress();
    try std.testing.expectEqual(@as(u64, 0), progress1.done);
    try std.testing.expectEqual(@as(u64, 10), progress1.total);

    coordinator.recordBackedUp(1, 1000);
    coordinator.recordBackedUp(2, 1001);
    coordinator.recordBackedUp(3, 1002);

    const progress2 = coordinator.getProgress();
    try std.testing.expectEqual(@as(u64, 3), progress2.done);
    try std.testing.expectEqual(@as(u64, 10), progress2.total);
}

test "BackupCoordinator: getReplicaRole returns correct role" {
    // Primary
    var coordinator1 = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });
    try std.testing.expectEqual(ReplicaRole.primary, coordinator1.getReplicaRole());

    // Follower
    var coordinator2 = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });
    try std.testing.expectEqual(ReplicaRole.follower, coordinator2.getReplicaRole());
}

test "BackupCoordinator: backupWithProgress updates stats and callbacks" {
    const CallbackState = struct {
        calls: u32 = 0,
        last_done: u64 = 0,
        last_total: u64 = 0,

        fn onProgress(done: u64, total: u64, context: ?*anyopaque) void {
            const Self = @This();
            const state: *Self = @ptrCast(@alignCast(context.?));
            state.calls += 1;
            state.last_done = done;
            state.last_total = total;
        }
    };

    var coordinator = BackupCoordinator.init(.{
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    var state = CallbackState{};
    coordinator.backupWithProgress(3, CallbackState.onProgress, &state);

    try std.testing.expectEqual(@as(u64, 3), coordinator.getLastBackedUpSequence());
    try std.testing.expectEqual(@as(u64, 3), coordinator.stats.blocks_uploaded);
    try std.testing.expectEqual(@as(u64, 3), coordinator.stats.blocks_queued);
    try std.testing.expectEqual(@as(u64, 3), coordinator.getProgress().done);
    try std.testing.expectEqual(@as(u32, 4), state.calls); // initial + one per block
    try std.testing.expectEqual(@as(u64, 3), state.last_done);
    try std.testing.expectEqual(@as(u64, 3), state.last_total);
}

test "BackupCoordinator: backupWithProgress records skips when inactive" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
        .follower_only = false,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    try std.testing.expect(!coordinator.shouldBackup());
    coordinator.backupWithProgress(2, null, null);

    try std.testing.expectEqual(@as(u64, 0), coordinator.stats.blocks_uploaded);
    try std.testing.expectEqual(@as(u64, 2), coordinator.stats.blocks_skipped_not_primary);
    try std.testing.expectEqual(@as(u64, 0), coordinator.getProgress().done);
    try std.testing.expectEqual(@as(u64, 2), coordinator.getProgress().total);
}
