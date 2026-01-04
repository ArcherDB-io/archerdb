// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup Configuration for Object Storage (F5.5.1)
//!
//! This module provides configuration types for the backup system that uploads
//! closed LSM blocks to object storage (S3, GCS, Azure Blob) for disaster recovery.
//!
//! See: openspec/changes/add-geospatial-core/specs/backup-restore/spec.md
//!
//! Usage:
//! ```zig
//! var config = try BackupConfig.init(allocator, .{
//!     .enabled = true,
//!     .provider = .s3,
//!     .bucket = "archerdb-backups",
//!     .region = "us-east-1",
//! });
//! defer config.deinit();
//! ```
//!
//! Implementation Status:
//! - Configuration types: Implemented
//! - CLI options: Implemented
//! - Storage provider interface: Defined (stub)
//! - Actual S3/GCS/Azure clients: Pending external integration

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const log = std.log.scoped(.backup_config);

// During tests, we don't want log.err to fail tests when testing error paths.
// Wrap logging functions to suppress errors in test mode.
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        log.err(fmt, args);
    }
}

/// Supported object storage providers for backup.
pub const StorageProvider = enum {
    /// Amazon S3 (or S3-compatible storage like MinIO, Wasabi).
    s3,
    /// Google Cloud Storage.
    gcs,
    /// Azure Blob Storage.
    azure,
    /// Local filesystem (for testing/development only).
    local,

    pub fn toString(self: StorageProvider) []const u8 {
        return switch (self) {
            .s3 => "s3",
            .gcs => "gcs",
            .azure => "azure",
            .local => "local",
        };
    }

    pub fn fromString(s: []const u8) ?StorageProvider {
        if (mem.eql(u8, s, "s3")) return .s3;
        if (mem.eql(u8, s, "gcs")) return .gcs;
        if (mem.eql(u8, s, "azure")) return .azure;
        if (mem.eql(u8, s, "local")) return .local;
        return null;
    }
};

/// Backup operating mode per spec.
pub const BackupMode = enum {
    /// Best-effort mode (default): Async backups, prioritize availability.
    /// Blocks may be released without backup if queue is full.
    best_effort,

    /// Mandatory mode: Require backup before block release.
    /// Halts writes if backup queue is exhausted.
    mandatory,

    pub fn toString(self: BackupMode) []const u8 {
        return switch (self) {
            .best_effort => "best-effort",
            .mandatory => "mandatory",
        };
    }

    pub fn fromString(s: []const u8) ?BackupMode {
        if (mem.eql(u8, s, "best-effort")) return .best_effort;
        if (mem.eql(u8, s, "mandatory")) return .mandatory;
        return null;
    }
};

/// Encryption mode for backup data.
pub const EncryptionMode = enum {
    /// No encryption (not recommended for production).
    none,
    /// Server-Side Encryption with provider-managed keys (SSE-S3, etc.).
    sse,
    /// Server-Side Encryption with KMS-managed keys.
    sse_kms,

    pub fn toString(self: EncryptionMode) []const u8 {
        return switch (self) {
            .none => "none",
            .sse => "sse",
            .sse_kms => "sse-kms",
        };
    }

    pub fn fromString(s: []const u8) ?EncryptionMode {
        if (mem.eql(u8, s, "none")) return .none;
        if (mem.eql(u8, s, "sse")) return .sse;
        if (mem.eql(u8, s, "sse-kms")) return .sse_kms;
        return null;
    }
};

/// Compression algorithm for backup blocks.
pub const CompressionMode = enum {
    /// No compression (default).
    none,
    /// Zstandard compression (level 3).
    zstd,

    pub fn toString(self: CompressionMode) []const u8 {
        return switch (self) {
            .none => "none",
            .zstd => "zstd",
        };
    }

    pub fn fromString(s: []const u8) ?CompressionMode {
        if (mem.eql(u8, s, "none")) return .none;
        if (mem.eql(u8, s, "zstd")) return .zstd;
        return null;
    }
};

/// Backup configuration options (from CLI).
pub const BackupOptions = struct {
    /// Whether backup is enabled.
    enabled: bool = false,

    /// Storage provider (s3, gcs, azure, local).
    provider: StorageProvider = .s3,

    /// Bucket or container name.
    /// Format: "bucket-name" or "s3://bucket-name" (scheme stripped).
    bucket: ?[]const u8 = null,

    /// Region for the bucket (provider-specific).
    region: ?[]const u8 = null,

    /// Path to credentials file (provider-specific).
    credentials_path: ?[]const u8 = null,

    /// Operating mode: best-effort (default) or mandatory.
    mode: BackupMode = .best_effort,

    /// Encryption mode for uploaded blocks.
    encryption: EncryptionMode = .sse,

    /// KMS key ID (for sse-kms encryption).
    kms_key_id: ?[]const u8 = null,

    /// Compression algorithm.
    compression: CompressionMode = .none,

    // Queue limits (per spec)

    /// Soft limit: Log warning when queue exceeds this.
    queue_soft_limit: u32 = 50,

    /// Hard limit: Apply backpressure or halt writes.
    queue_hard_limit: u32 = 100,

    // Mandatory mode specific

    /// Timeout before emergency bypass (in seconds). Default: 1 hour.
    mandatory_halt_timeout_secs: u32 = 3600,

    // Retention policy

    /// Retention period in days (0 = keep forever).
    retention_days: u32 = 0,

    /// Retention by block count (0 = unlimited).
    retention_blocks: u32 = 0,

    // Coordination

    /// Only backup from primary replica (reduces S3 costs).
    primary_only: bool = false,
};

/// Block reference for backup tracking.
pub const BlockRef = struct {
    /// Block sequence number (from LSM).
    sequence: u64,
    /// Block address in grid.
    address: u64,
    /// Block checksum for verification.
    checksum: u128,
    /// Timestamp when block was closed.
    closed_timestamp: i64,
};

/// Backup state tracking (persisted to disk).
pub const BackupState = struct {
    /// Highest block sequence successfully uploaded.
    last_uploaded_sequence: u64 = 0,

    /// Timestamp of last successful upload.
    last_upload_timestamp: i64 = 0,

    /// Number of blocks pending upload.
    pending_count: u32 = 0,

    /// Number of failed upload attempts.
    failed_count: u32 = 0,

    /// Number of blocks abandoned without backup (best-effort mode).
    abandoned_count: u64 = 0,
};

/// Backup configuration manager.
pub const BackupConfig = struct {
    allocator: mem.Allocator,
    options: BackupOptions,

    /// Initialize backup configuration.
    pub fn init(allocator: mem.Allocator, options: BackupOptions) !BackupConfig {
        var self = BackupConfig{
            .allocator = allocator,
            .options = options,
        };

        if (options.enabled) {
            try self.validate();
        }

        return self;
    }

    pub fn deinit(self: *BackupConfig) void {
        _ = self;
        // No allocations to free currently
    }

    /// Check if backup is enabled.
    pub fn isEnabled(self: *const BackupConfig) bool {
        return self.options.enabled;
    }

    /// Check if mandatory mode is active.
    pub fn isMandatory(self: *const BackupConfig) bool {
        return self.options.mode == .mandatory;
    }

    /// Validate configuration.
    fn validate(self: *const BackupConfig) !void {
        if (self.options.bucket == null) {
            logErr("backup enabled but --backup-bucket not provided", .{});
            return error.MissingBucket;
        }

        // KMS key required for sse-kms encryption
        if (self.options.encryption == .sse_kms and self.options.kms_key_id == null) {
            logErr("sse-kms encryption requires --backup-kms-key-id", .{});
            return error.MissingKmsKey;
        }

        // Validate queue limits
        if (self.options.queue_soft_limit >= self.options.queue_hard_limit) {
            logErr("queue_soft_limit must be < queue_hard_limit", .{});
            return error.InvalidQueueLimits;
        }
    }

    /// Get the object key prefix for this cluster/replica.
    /// Format: <cluster-id>/<replica-id>/blocks/
    pub fn getObjectKeyPrefix(
        self: *const BackupConfig,
        cluster_id: u128,
        replica_id: u8,
    ) [128]u8 {
        _ = self;
        var buf: [128]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{x:0>32}/replica-{d}/blocks/", .{
            cluster_id,
            replica_id,
        }) catch unreachable;
        @memset(buf[len.len..], 0);
        return buf;
    }

    /// Get the object key for a specific block.
    /// Format: <prefix><sequence>.block[.zst]
    pub fn getBlockObjectKey(
        self: *const BackupConfig,
        cluster_id: u128,
        replica_id: u8,
        sequence: u64,
    ) [160]u8 {
        var buf: [160]u8 = undefined;
        const ext = if (self.options.compression == .zstd) ".block.zst" else ".block";
        const len = std.fmt.bufPrint(&buf, "{x:0>32}/replica-{d}/blocks/{d:0>12}{s}", .{
            cluster_id,
            replica_id,
            sequence,
            ext,
        }) catch unreachable;
        @memset(buf[len.len..], 0);
        return buf;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BackupConfig: disabled by default" {
    const config = try BackupConfig.init(std.testing.allocator, .{});
    try std.testing.expect(!config.isEnabled());
}

test "BackupConfig: enabled requires bucket" {
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
    });
    try std.testing.expectError(error.MissingBucket, result);
}

test "BackupConfig: valid configuration" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .provider = .s3,
        .bucket = "test-bucket",
        .region = "us-east-1",
    });
    defer config.deinit();

    try std.testing.expect(config.isEnabled());
    try std.testing.expect(!config.isMandatory());
}

test "BackupConfig: mandatory mode" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .mode = .mandatory,
    });
    defer config.deinit();

    try std.testing.expect(config.isMandatory());
}

test "BackupConfig: sse-kms requires key" {
    const result = BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
        .encryption = .sse_kms,
    });
    try std.testing.expectError(error.MissingKmsKey, result);
}

test "BackupConfig: object key format" {
    var config = try BackupConfig.init(std.testing.allocator, .{
        .enabled = true,
        .bucket = "test-bucket",
    });
    defer config.deinit();

    const key = config.getBlockObjectKey(0x12345678, 0, 1000);
    const key_str = mem.sliceTo(&key, 0);
    try std.testing.expect(mem.indexOf(u8, key_str, "replica-0") != null);
    try std.testing.expect(mem.indexOf(u8, key_str, "blocks/") != null);
    try std.testing.expect(mem.endsWith(u8, key_str, ".block"));
}

test "StorageProvider: fromString" {
    try std.testing.expectEqual(StorageProvider.s3, StorageProvider.fromString("s3").?);
    try std.testing.expectEqual(StorageProvider.gcs, StorageProvider.fromString("gcs").?);
    try std.testing.expectEqual(StorageProvider.azure, StorageProvider.fromString("azure").?);
    try std.testing.expectEqual(StorageProvider.local, StorageProvider.fromString("local").?);
    try std.testing.expect(StorageProvider.fromString("invalid") == null);
}

test "BackupMode: fromString" {
    try std.testing.expectEqual(BackupMode.best_effort, BackupMode.fromString("best-effort").?);
    try std.testing.expectEqual(BackupMode.mandatory, BackupMode.fromString("mandatory").?);
    try std.testing.expect(BackupMode.fromString("invalid") == null);
}
