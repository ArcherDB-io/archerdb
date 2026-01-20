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

    /// Number of view changes observed.
    view_changes: u64 = 0,

    /// Number of times this replica became primary.
    became_primary_count: u64 = 0,

    /// Number of times this replica became backup.
    became_backup_count: u64 = 0,
};

/// Backup coordinator for multi-replica environments.
///
/// Determines whether this replica should perform backup operations based on
/// the configured strategy (all replicas or primary-only) and current VSR view.
pub const BackupCoordinator = struct {
    /// Configuration
    primary_only: bool,
    replica_count: u8,
    replica_id: u8,

    /// Current VSR view number
    view: u32,

    /// Coordination statistics
    stats: CoordinatorStats,

    /// Whether backup is currently active on this replica.
    /// Updated on view changes when primary_only is true.
    backup_active: bool,

    /// Initialize backup coordinator.
    pub fn init(config: CoordinatorConfig) BackupCoordinator {
        const primary_idx = primaryIndex(config.initial_view, config.replica_count);
        const is_primary = primary_idx == config.replica_id;
        const backup_active = !config.primary_only or is_primary;

        if (config.primary_only) {
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
            .replica_count = config.replica_count,
            .replica_id = config.replica_id,
            .view = config.initial_view,
            .stats = .{},
            .backup_active = backup_active,
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
    /// If primary_only is configured, this updates whether this replica
    /// should perform backups (only primary does).
    pub fn onViewChange(self: *BackupCoordinator, new_view: u32) void {
        if (new_view == self.view) return;

        const old_view = self.view;
        self.view = new_view;
        self.stats.view_changes += 1;

        if (!self.primary_only) {
            // All replicas mode - no change needed
            return;
        }

        const was_primary = primaryIndex(old_view, self.replica_count) == self.replica_id;
        const is_primary = primaryIndex(new_view, self.replica_count) == self.replica_id;

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

    /// Record that a block was skipped because this replica is not the primary.
    /// Call this when shouldBackup() returns false but a block was ready.
    pub fn recordSkipped(self: *BackupCoordinator) void {
        self.stats.blocks_skipped_not_primary += 1;
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

test "BackupCoordinator: all replicas mode (default)" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = false,
        .replica_count = 3,
        .replica_id = 1,
    });

    // All replicas should backup in default mode
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

test "BackupCoordinator: single replica always backups" {
    var coordinator = BackupCoordinator.init(.{
        .primary_only = true,
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
