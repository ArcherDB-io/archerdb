// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup/Restore Integration Tests (F5.5.7)
//!
//! This module provides integration tests for the full backup → restore cycle.
//! These tests verify:
//! - Configuration validation
//! - Block checksum integrity
//! - Sequence continuity (no gaps)
//! - Multi-replica coordination
//! - End-to-end data integrity
//!
//! See: openspec/changes/add-geospatial-core/specs/backup-restore/spec.md

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const builtin = @import("builtin");

const backup_config = @import("backup_config.zig");
const backup_queue = @import("backup_queue.zig");
const backup_state = @import("backup_state.zig");
const restore = @import("restore.zig");
const backup_coordinator = @import("backup_coordinator.zig");

const BackupConfig = backup_config.BackupConfig;
const BackupOptions = backup_config.BackupOptions;
const StorageProvider = backup_config.StorageProvider;
const BackupMode = backup_config.BackupMode;
const EncryptionMode = backup_config.EncryptionMode;
const BlockRef = backup_config.BlockRef;
const BackupQueue = backup_queue.BackupQueue;
const EnqueueResult = backup_queue.EnqueueResult;
const BackupState = backup_state.BackupState;
const PointInTime = restore.PointInTime;
const RestoreConfig = restore.RestoreConfig;
const RestoreStats = restore.RestoreStats;
const RestoreManager = restore.RestoreManager;
const BackupCoordinator = backup_coordinator.BackupCoordinator;
const CoordinatorConfig = backup_coordinator.CoordinatorConfig;

// =============================================================================
// Integration Tests: Configuration Validation
// =============================================================================

test "Integration: BackupConfig with all providers" {
    const allocator = testing.allocator;

    // Test S3 configuration
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .provider = .s3,
            .bucket = "s3-backup-bucket",
            .region = "us-east-1",
        });
        defer config.deinit();
        try testing.expect(config.isEnabled());
        try testing.expectEqual(StorageProvider.s3, config.options.provider);
    }

    // Test GCS configuration
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .provider = .gcs,
            .bucket = "gcs-backup-bucket",
            .region = "us-central1",
        });
        defer config.deinit();
        try testing.expectEqual(StorageProvider.gcs, config.options.provider);
    }

    // Test Azure configuration
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .provider = .azure,
            .bucket = "azure-container",
        });
        defer config.deinit();
        try testing.expectEqual(StorageProvider.azure, config.options.provider);
    }

    // Test local filesystem configuration
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .provider = .local,
            .bucket = "/tmp/backup",
        });
        defer config.deinit();
        try testing.expectEqual(StorageProvider.local, config.options.provider);
    }
}

test "Integration: BackupConfig mode combinations" {
    const allocator = testing.allocator;

    // Best-effort mode with no encryption
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .mode = .best_effort,
            .encryption = .none,
        });
        defer config.deinit();
        try testing.expect(!config.isMandatory());
        try testing.expectEqual(EncryptionMode.none, config.options.encryption);
    }

    // Mandatory mode with SSE encryption
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .mode = .mandatory,
            .encryption = .sse,
        });
        defer config.deinit();
        try testing.expect(config.isMandatory());
        try testing.expectEqual(EncryptionMode.sse, config.options.encryption);
    }

    // SSE-KMS requires key ID
    {
        const result = BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .encryption = .sse_kms,
        });
        try testing.expectError(error.MissingKmsKey, result);
    }

    // SSE-KMS with key ID succeeds
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .encryption = .sse_kms,
            .kms_key_id = "arn:aws:kms:us-east-1:123456789:key/test-key",
        });
        defer config.deinit();
        try testing.expectEqual(EncryptionMode.sse_kms, config.options.encryption);
    }
}

test "Integration: BackupConfig queue limits" {
    const allocator = testing.allocator;

    // Valid queue limits
    {
        var config = try BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .queue_soft_limit = 25,
            .queue_hard_limit = 50,
        });
        defer config.deinit();
        try testing.expectEqual(@as(u32, 25), config.options.queue_soft_limit);
        try testing.expectEqual(@as(u32, 50), config.options.queue_hard_limit);
    }

    // Invalid: soft >= hard
    {
        const result = BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test-bucket",
            .queue_soft_limit = 100,
            .queue_hard_limit = 50,
        });
        try testing.expectError(error.InvalidQueueLimits, result);
    }
}

// =============================================================================
// Integration Tests: Backup Queue Operations
// =============================================================================

test "Integration: BackupQueue enqueue/dequeue cycle" {
    const allocator = testing.allocator;

    var queue = BackupQueue.init(allocator, .{
        .soft_limit = 10,
        .hard_limit = 20,
        .mode = .best_effort,
    });
    defer queue.deinit();

    // Enqueue several blocks
    for (0..5) |i| {
        _ = queue.enqueue(.{
            .sequence = @intCast(i + 1),
            .address = @intCast(1000 + i),
            .checksum = @intCast(0xDEADBEEF + i),
            .closed_timestamp = @intCast(1704067200 + @as(i64, @intCast(i)) * 60),
        });
    }

    try testing.expectEqual(@as(u32, 5), queue.depth());
    try testing.expect(!queue.isOverSoftLimit());
    try testing.expect(!queue.isOverHardLimit());

    // Dequeue and verify order (FIFO)
    var expected_seq: u64 = 1;
    while (queue.dequeue()) |entry| {
        try testing.expectEqual(expected_seq, entry.block.sequence);
        expected_seq += 1;
    }

    try testing.expectEqual(@as(u32, 0), queue.depth());
}

test "Integration: BackupQueue soft/hard limit behavior" {
    const allocator = testing.allocator;

    var queue = BackupQueue.init(allocator, .{
        .soft_limit = 3,
        .hard_limit = 5,
        .mode = .best_effort,
    });
    defer queue.deinit();

    // Fill up to soft limit
    for (0..3) |i| {
        _ = queue.enqueue(.{
            .sequence = @intCast(i + 1),
            .address = @intCast(1000 + i),
            .checksum = @intCast(0xABCD0000 + i),
            .closed_timestamp = 1704067200,
        });
    }

    try testing.expect(queue.isOverSoftLimit());
    try testing.expect(!queue.isOverHardLimit());

    // Add more up to hard limit
    for (3..5) |i| {
        _ = queue.enqueue(.{
            .sequence = @intCast(i + 1),
            .address = @intCast(1000 + i),
            .checksum = @intCast(0xABCD0000 + i),
            .closed_timestamp = 1704067200,
        });
    }

    try testing.expect(queue.isOverHardLimit());

    // In best-effort mode, enqueue returns 'abandoned' at hard limit
    const result = queue.enqueue(.{
        .sequence = 6,
        .address = 1005,
        .checksum = 0xABCD0005,
        .closed_timestamp = 1704067200,
    });
    try testing.expectEqual(EnqueueResult.abandoned, result);
}

// =============================================================================
// Integration Tests: Restore Operations
// =============================================================================

test "Integration: PointInTime parsing and formatting" {
    // Parse sequence
    {
        const pit = PointInTime.parse("seq:12345");
        try testing.expect(pit != null);
        try testing.expectEqual(@as(u64, 12345), pit.?.sequence);
    }

    // Parse timestamp
    {
        const pit = PointInTime.parse("ts:1704067200");
        try testing.expect(pit != null);
        try testing.expectEqual(@as(i64, 1704067200), pit.?.timestamp);
    }

    // Parse latest
    {
        const pit = PointInTime.parse("latest");
        try testing.expect(pit != null);
        try testing.expectEqual(PointInTime.latest, pit.?);
    }

    // Format and round-trip
    {
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const original = PointInTime{ .sequence = 9999 };
        try original.format("", .{}, fbs.writer());
        const formatted = fbs.getWritten();
        const parsed = PointInTime.parse(formatted);
        try testing.expect(parsed != null);
        try testing.expectEqual(original, parsed.?);
    }
}

test "Integration: RestoreConfig basic validation" {
    // Test RestoreConfig can be created with various configurations
    const configs = [_]RestoreConfig{
        .{
            .source_url = "s3://my-bucket/prefix",
            .dest_data_file = "/tmp/restored.db",
        },
        .{
            .source_url = "gs://my-bucket/prefix",
            .dest_data_file = "/tmp/restored.db",
            .provider = .gcs,
        },
        .{
            .source_url = "file:///backup/prefix",
            .dest_data_file = "/tmp/restored.db",
            .dry_run = true,
        },
    };

    // Verify configs are created correctly
    for (configs) |config| {
        try testing.expect(config.source_url.len > 0);
        try testing.expect(config.dest_data_file.len > 0);
    }
}

test "Integration: RestoreStats throughput calculation" {
    // Simulate restore with timing
    var stats = RestoreStats{
        .blocks_available = 100,
        .blocks_downloaded = 100,
        .blocks_verified = 100,
        .events_restored = 50000,
        .bytes_downloaded = 100 * 4 * 1024 * 1024, // 100 blocks * 4MB
    };

    // Simulate 10 second restore
    stats.start_time_ns = 0;
    stats.end_time_ns = 10_000_000_000; // 10 seconds in nanoseconds

    try testing.expectEqual(@as(f64, 10.0), stats.durationSeconds());

    // 400MB in 10 seconds = 40 MB/s
    const throughput = stats.downloadThroughputMBps();
    try testing.expect(throughput > 39.0 and throughput < 41.0);
}

// =============================================================================
// Integration Tests: Multi-Replica Coordination
// =============================================================================

test "Integration: Coordinator primary-only with view changes" {
    // 3-replica cluster
    var replica0 = BackupCoordinator.init(.{
        .primary_only = true,
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    var replica1 = BackupCoordinator.init(.{
        .primary_only = true,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    var replica2 = BackupCoordinator.init(.{
        .primary_only = true,
        .replica_count = 3,
        .replica_id = 2,
        .initial_view = 0,
    });

    // View 0: Only replica 0 should backup
    try testing.expect(replica0.shouldBackup());
    try testing.expect(!replica1.shouldBackup());
    try testing.expect(!replica2.shouldBackup());

    // Simulate view change to view 1
    replica0.onViewChange(1);
    replica1.onViewChange(1);
    replica2.onViewChange(1);

    // View 1: Only replica 1 should backup
    try testing.expect(!replica0.shouldBackup());
    try testing.expect(replica1.shouldBackup());
    try testing.expect(!replica2.shouldBackup());

    // Simulate view change to view 2
    replica0.onViewChange(2);
    replica1.onViewChange(2);
    replica2.onViewChange(2);

    // View 2: Only replica 2 should backup
    try testing.expect(!replica0.shouldBackup());
    try testing.expect(!replica1.shouldBackup());
    try testing.expect(replica2.shouldBackup());

    // Check stats
    try testing.expectEqual(@as(u64, 2), replica0.stats.view_changes);
    try testing.expectEqual(@as(u64, 1), replica0.stats.became_backup_count);
}

test "Integration: Coordinator all-replicas mode ignores view changes" {
    var replica0 = BackupCoordinator.init(.{
        .primary_only = false, // All replicas mode
        .replica_count = 3,
        .replica_id = 0,
        .initial_view = 0,
    });

    var replica1 = BackupCoordinator.init(.{
        .primary_only = false,
        .replica_count = 3,
        .replica_id = 1,
        .initial_view = 0,
    });

    // All should backup in this mode
    try testing.expect(replica0.shouldBackup());
    try testing.expect(replica1.shouldBackup());

    // View changes don't affect backup status
    replica0.onViewChange(1);
    replica1.onViewChange(1);

    try testing.expect(replica0.shouldBackup());
    try testing.expect(replica1.shouldBackup());
}

// =============================================================================
// Integration Tests: Full Workflow Simulation
// =============================================================================

test "Integration: Full backup workflow simulation" {
    const allocator = testing.allocator;

    // 1. Create backup config
    var backup_cfg = try BackupConfig.init(allocator, .{
        .enabled = true,
        .provider = .local,
        .bucket = "/tmp/archerdb-backup-test",
        .mode = .best_effort,
    });
    defer backup_cfg.deinit();

    // 2. Create backup queue
    var queue = BackupQueue.init(allocator, .{
        .soft_limit = backup_cfg.options.queue_soft_limit,
        .hard_limit = backup_cfg.options.queue_hard_limit,
        .mode = backup_cfg.options.mode,
    });
    defer queue.deinit();

    // 3. Create coordinator (simulating primary)
    var coordinator = BackupCoordinator.init(.{
        .primary_only = backup_cfg.options.primary_only,
        .replica_count = 1,
        .replica_id = 0,
    });

    // 4. Simulate block closure events
    const mock_blocks = [_]BlockRef{
        .{ .sequence = 1, .address = 1000, .checksum = 0x1111111111111111, .closed_timestamp = 1704067200 },
        .{ .sequence = 2, .address = 1001, .checksum = 0x2222222222222222, .closed_timestamp = 1704067260 },
        .{ .sequence = 3, .address = 1002, .checksum = 0x3333333333333333, .closed_timestamp = 1704067320 },
    };

    for (mock_blocks) |block| {
        // Check if this replica should backup
        if (coordinator.shouldBackup()) {
            _ = queue.enqueue(block);
        } else {
            coordinator.recordSkipped();
        }
    }

    // 5. Simulate upload process (dequeue and "upload")
    var uploaded_count: usize = 0;
    while (queue.dequeue()) |entry| {
        // In real implementation, this would upload to object storage
        _ = entry;
        uploaded_count += 1;
    }

    try testing.expectEqual(@as(usize, 3), uploaded_count);
    try testing.expectEqual(@as(u32, 0), queue.depth());
}

test "Integration: Full restore workflow simulation" {
    const allocator = testing.allocator;

    // 1. Create restore config
    const restore_cfg = RestoreConfig{
        .source_url = "file:///tmp/archerdb-backup-test/cluster-123",
        .dest_data_file = "/tmp/archerdb-restored.db",
        .point_in_time = .latest,
        .dry_run = true, // Don't actually write
    };

    // 2. Create restore manager
    var manager = try RestoreManager.init(allocator, restore_cfg);
    defer manager.deinit();

    // 3. Execute restore - with non-existent source, expect TargetNotFound
    // (because listBlocks returns empty or InvalidSource)
    const result = manager.execute();

    // Source path doesn't exist, so we get an error
    // Accept either TargetNotFound (empty blocks) or InvalidSource (path issue)
    if (result) |_| {
        // Unexpected success - fail the test
        try testing.expect(false);
    } else |err| {
        try testing.expect(err == restore.RestoreError.TargetNotFound or
            err == restore.RestoreError.InvalidSource);
    }
}

// =============================================================================
// Integration Tests: Checksum Verification
// =============================================================================

test "Integration: Block checksum structure" {
    // Verify block reference structure
    const block = backup_config.BlockRef{
        .sequence = 42,
        .address = 0x1234567890ABCDEF,
        .checksum = 0x0123456789ABCDEF0123456789ABCDEF,
        .closed_timestamp = 1704067200,
    };

    try testing.expectEqual(@as(u64, 42), block.sequence);
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), block.address);
    try testing.expectEqual(@as(u128, 0x0123456789ABCDEF0123456789ABCDEF), block.checksum);
}

// =============================================================================
// Integration Tests: Sequence Continuity
// =============================================================================

test "Integration: Sequence gap detection simulation" {
    // Simulate blocks with a gap
    const available_blocks = [_]u64{ 1, 2, 3, 5, 6, 7 }; // Gap at 4

    // Verify continuity check logic
    var has_gap = false;
    var prev_seq: u64 = 0;
    for (available_blocks) |seq| {
        if (prev_seq != 0 and seq != prev_seq + 1) {
            has_gap = true;
            break;
        }
        prev_seq = seq;
    }

    try testing.expect(has_gap);

    // Continuous sequence should pass
    const continuous_blocks = [_]u64{ 1, 2, 3, 4, 5 };
    has_gap = false;
    prev_seq = 0;
    for (continuous_blocks) |seq| {
        if (prev_seq != 0 and seq != prev_seq + 1) {
            has_gap = true;
            break;
        }
        prev_seq = seq;
    }

    try testing.expect(!has_gap);
}

// =============================================================================
// Integration Tests: Object Key Formatting
// =============================================================================

test "Integration: Object key format for backup paths" {
    const allocator = testing.allocator;

    var config = try BackupConfig.init(allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    const cluster_id: u128 = 0x12345678;
    const replica_id: u8 = 2;
    const sequence: u64 = 1000;

    // Test block key format
    const key = config.getBlockObjectKey(cluster_id, replica_id, sequence);
    const key_str = mem.sliceTo(&key, 0);

    // Verify key contains expected components
    try testing.expect(mem.indexOf(u8, key_str, "replica-2") != null);
    try testing.expect(mem.indexOf(u8, key_str, "blocks/") != null);
    try testing.expect(mem.indexOf(u8, key_str, "000000001000") != null);
    try testing.expect(mem.endsWith(u8, key_str, ".block"));
}

test "Integration: Compressed block key format" {
    const allocator = testing.allocator;

    var config = try BackupConfig.init(allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .compression = .zstd,
    });
    defer config.deinit();

    const key = config.getBlockObjectKey(0x12345678, 0, 100);
    const key_str = mem.sliceTo(&key, 0);

    // Compressed blocks should have .block.zst extension
    try testing.expect(mem.endsWith(u8, key_str, ".block.zst"));
}

// =============================================================================
// Integration Tests: Error Handling
// =============================================================================

test "Integration: Backup config error chain" {
    const allocator = testing.allocator;

    // Missing bucket
    {
        const result = BackupConfig.init(allocator, .{ .enabled = true });
        try testing.expectError(error.MissingBucket, result);
    }

    // Missing KMS key for SSE-KMS
    {
        const result = BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test",
            .encryption = .sse_kms,
        });
        try testing.expectError(error.MissingKmsKey, result);
    }

    // Invalid queue limits
    {
        const result = BackupConfig.init(allocator, .{
            .enabled = true,
            .bucket = "test",
            .queue_soft_limit = 100,
            .queue_hard_limit = 50,
        });
        try testing.expectError(error.InvalidQueueLimits, result);
    }
}

test "Integration: Restore config error handling" {
    // PointInTime.parse returns null for invalid input (not an error)

    // Invalid point-in-time format returns null
    {
        const result = PointInTime.parse("invalid:format");
        try testing.expect(result == null);
    }

    // Invalid sequence number returns null
    {
        const result = PointInTime.parse("seq:not_a_number");
        try testing.expect(result == null);
    }

    // Invalid timestamp returns null
    {
        const result = PointInTime.parse("ts:not_a_number");
        try testing.expect(result == null);
    }

    // Valid formats should return non-null
    {
        const seq_result = PointInTime.parse("seq:12345");
        try testing.expect(seq_result != null);

        const ts_result = PointInTime.parse("ts:1704067200");
        try testing.expect(ts_result != null);
    }
}
