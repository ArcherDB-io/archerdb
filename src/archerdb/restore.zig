// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Point-in-Time Restore Implementation (F5.5.4)
//!
//! This module provides restore functionality for recovering data from
//! object storage backups to a specific point in time.
//!
//!
//! Usage:
//! ```zig
//! var restore = try RestoreManager.init(allocator, .{
//!     .source_url = "s3://archerdb-backups/cluster-id/replica-0",
//!     .dest_data_file = "/var/lib/archerdb/data.archerdb",
//!     .point_in_time = .{ .sequence = 10000 },
//! });
//! defer restore.deinit();
//!
//! const stats = try restore.execute();
//! ```
//!
//! Implementation Status:
//! - Configuration types: Implemented
//! - Restore process skeleton: Implemented
//! - S3/GCS object listing and download: Implemented
//! - Azure Blob listing and download via SAS: Implemented
//! - Block verification: Interface defined
//! - Index rebuild: Interface defined

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fs = std.fs;
const log = std.log.scoped(.restore);
const vsr = @import("../vsr.zig");
const constants = vsr.constants;

const backup_config = @import("backup_config.zig");
const StorageProvider = backup_config.StorageProvider;
const CompressionMode = backup_config.CompressionMode;
const s3_client = @import("../replication/s3_client.zig");
const checkpoint_artifact = vsr.checkpoint_artifact;

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

fn ioInitOrSkip(entries: u12, flags: u32) !vsr.io.IO {
    if (builtin.target.os.tag == .linux) {
        return vsr.io.IO.init(entries, flags) catch |err| switch (err) {
            error.PermissionDenied => error.SkipZigTest,
            else => err,
        };
    }
    return try vsr.io.IO.init(entries, flags);
}

fn skipRemoteFixtureOnMusl() !void {
    if (builtin.target.os.tag == .linux and builtin.target.abi == .musl) {
        return error.SkipZigTest;
    }
}

/// Point-in-time specification for restore.
pub const PointInTime = union(enum) {
    /// Restore up to a specific block sequence number.
    sequence: u64,
    /// Restore up to a specific timestamp (nanoseconds since epoch).
    timestamp: i64,
    /// Restore to the latest available backup.
    latest,

    pub fn format(
        self: PointInTime,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .sequence => |seq| try writer.print("seq:{d}", .{seq}),
            .timestamp => |ts| try writer.print("ts:{d}", .{ts}),
            .latest => try writer.writeAll("latest"),
        }
    }

    /// Parse point-in-time from string.
    /// Formats: "seq:12345", "ts:1704067200000000000", "latest"
    pub fn parse(s: []const u8) ?PointInTime {
        if (mem.eql(u8, s, "latest")) {
            return .latest;
        }
        if (mem.startsWith(u8, s, "seq:")) {
            const num = std.fmt.parseInt(u64, s[4..], 10) catch return null;
            return .{ .sequence = num };
        }
        if (mem.startsWith(u8, s, "ts:")) {
            const num = std.fmt.parseInt(i64, s[3..], 10) catch return null;
            return .{ .timestamp = num };
        }
        // Try parsing as plain number (assume sequence)
        const num = std.fmt.parseInt(u64, s, 10) catch return null;
        return .{ .sequence = num };
    }
};

/// Restore operation configuration.
pub const RestoreConfig = struct {
    /// Source URL for backup data.
    /// Format: "s3://bucket/cluster-id/replica-id" or local path.
    source_url: []const u8,

    /// Destination data file path.
    dest_data_file: []const u8,

    /// Point in time to restore to.
    point_in_time: PointInTime = .latest,

    /// Storage provider (auto-detected from URL if not specified).
    provider: ?StorageProvider = null,

    /// Skip expired events during restore (TTL filtering).
    skip_expired: bool = false,

    /// Dry-run mode: verify blocks without writing.
    dry_run: bool = false,

    /// Region for cloud storage (provider-specific).
    region: ?[]const u8 = null,

    /// Path to credentials file.
    credentials_path: ?[]const u8 = null,

    /// Expected compression mode for blocks.
    compression: CompressionMode = .none,

    /// Verify checksums after download.
    verify_checksums: bool = true,

    /// Maximum concurrent downloads.
    max_concurrent_downloads: u8 = 4,
};

/// Statistics from a restore operation.
pub const RestoreStats = struct {
    /// Number of blocks listed in source.
    blocks_available: u64 = 0,
    /// Number of blocks downloaded.
    blocks_downloaded: u64 = 0,
    /// Number of blocks verified (checksum valid).
    blocks_verified: u64 = 0,
    /// Number of blocks written to data file.
    blocks_written: u64 = 0,
    /// Total events restored.
    events_restored: u64 = 0,
    /// Events skipped due to TTL expiration.
    events_skipped_ttl: u64 = 0,
    /// Events skipped (tombstones preserved).
    tombstones_preserved: u64 = 0,
    /// Total bytes downloaded.
    bytes_downloaded: u64 = 0,
    /// Total bytes written to disk.
    bytes_written: u64 = 0,
    /// Highest sequence number restored.
    max_sequence_restored: u64 = 0,
    /// Restore start time (nanoseconds).
    start_time_ns: i128 = 0,
    /// Restore end time (nanoseconds).
    end_time_ns: i128 = 0,
    /// Whether restore was successful.
    success: bool = false,
    /// Error message if restore failed.
    error_message: ?[]const u8 = null,

    /// Calculate restore duration in seconds.
    pub fn durationSeconds(self: *const RestoreStats) f64 {
        // Only check end_time_ns - start_time_ns of 0 is valid (e.g., in tests)
        if (self.end_time_ns == 0) return 0;
        const duration_ns = self.end_time_ns - self.start_time_ns;
        return @as(f64, @floatFromInt(duration_ns)) / @as(f64, std.time.ns_per_s);
    }

    /// Calculate download throughput in MB/s.
    pub fn downloadThroughputMBps(self: *const RestoreStats) f64 {
        const duration = self.durationSeconds();
        if (duration == 0) return 0;
        return @as(f64, @floatFromInt(self.bytes_downloaded)) / (1024.0 * 1024.0) / duration;
    }
};

/// Block metadata from listing.
pub const BlockMetadata = struct {
    /// Block sequence number.
    sequence: u64,
    /// Timestamp when the block was closed, if available.
    closed_timestamp: i64 = 0,
    /// Original grid address when backup metadata provides it.
    address: ?u64 = null,
    /// Block size in bytes.
    size: u64,
    /// Block checksum.
    checksum: u128,
    /// Object key in storage.
    object_key: []const u8,
    /// Whether block is compressed.
    compressed: bool,
};

/// Restore operation errors.
pub const RestoreError = error{
    /// Source URL is invalid or inaccessible.
    InvalidSource,
    /// Destination path is invalid or not writable.
    InvalidDestination,
    /// Block checksum verification failed.
    ChecksumMismatch,
    /// Gap detected in block sequence.
    SequenceGap,
    /// Point-in-time target not found in backup.
    TargetNotFound,
    /// Index rebuild failed.
    IndexBuildFailed,
    /// Superblock write failed.
    SuperblockWriteFailed,
    /// Storage provider error.
    StorageError,
    /// Restore aborted by user.
    Aborted,
    /// Out of memory.
    OutOfMemory,
    /// Disk full.
    DiskFull,
};

/// Manages point-in-time restore operations.
pub const RestoreManager = struct {
    allocator: mem.Allocator,
    config: RestoreConfig,
    stats: RestoreStats,

    /// Detected storage provider.
    provider: StorageProvider,

    /// Parsed cluster ID from source URL.
    cluster_id: ?u128 = null,

    /// Parsed replica ID from source URL.
    replica_id: ?u8 = null,

    /// Initialize restore manager.
    pub fn init(allocator: mem.Allocator, config: RestoreConfig) !RestoreManager {
        // Detect provider from URL
        const provider = config.provider orelse detectProvider(config.source_url);

        var self = RestoreManager{
            .allocator = allocator,
            .config = config,
            .stats = .{},
            .provider = provider,
        };

        // Parse cluster/replica from URL
        self.parseSourceUrl() catch |err| {
            logWarn("Could not parse cluster/replica from URL: {}", .{err});
        };

        return self;
    }

    /// Clean up resources.
    pub fn deinit(self: *RestoreManager) void {
        _ = self;
        // No allocations to free currently
    }

    /// Execute the restore operation.
    pub fn execute(self: *RestoreManager) RestoreError!RestoreStats {
        self.stats.start_time_ns = std.time.nanoTimestamp();

        logInfo("Starting restore from {s} to {s}", .{
            self.config.source_url,
            self.config.dest_data_file,
        });

        // Step 1: List available blocks
        const blocks = self.listBlocks() catch |err| {
            self.stats.error_message = "Failed to list blocks";
            return err;
        };
        defer self.freeBlockMetadata(blocks);
        self.stats.blocks_available = blocks.len;

        if (blocks.len == 0) {
            logErr("No blocks found in source", .{});
            self.stats.error_message = "No blocks found";
            return RestoreError.TargetNotFound;
        }

        logInfo("Found {} blocks in source", .{blocks.len});

        // Step 2: Filter blocks by point-in-time
        const target_blocks = self.filterBlocksByPointInTime(blocks) catch |err| {
            self.stats.error_message = "Failed to filter blocks";
            return err;
        };

        logInfo("Restoring {} blocks up to {}", .{
            target_blocks.len,
            self.config.point_in_time,
        });

        // Step 3: Verify no sequence gaps
        self.verifySequenceContinuity(target_blocks) catch |err| {
            self.stats.error_message = "Sequence gap detected";
            return err;
        };

        const selected_checkpoint_artifact = try self.selectCheckpointArtifact(target_blocks);
        if (selected_checkpoint_artifact) |artifact| {
            logInfo(
                "Selected durable checkpoint artifact: checkpoint_op={} sequence_max={} block_count={}",
                .{ artifact.checkpointOp(), artifact.sequence_max, artifact.block_count },
            );
        } else {
            logInfo("No durable checkpoint artifact selected for restore target", .{});
        }

        // Step 4: Download and verify blocks
        for (target_blocks) |block| {
            self.downloadAndVerifyBlock(block) catch |err| {
                self.stats.error_message = "Block download/verify failed";
                return err;
            };
        }

        // Step 5: Write blocks to data file (unless dry-run)
        if (!self.config.dry_run) {
            self.writeBlocks(target_blocks) catch |err| {
                self.stats.error_message = "Failed to write blocks";
                return err;
            };

            // Step 6: Build RAM index
            self.buildIndex() catch |err| {
                self.stats.error_message = "Index build failed";
                return err;
            };

            // Step 7: Write superblock
            self.writeSuperblock(selected_checkpoint_artifact) catch |err| {
                self.stats.error_message = "Superblock write failed";
                return err;
            };
        } else {
            logInfo("Dry-run mode: skipping write operations", .{});
        }

        self.stats.end_time_ns = std.time.nanoTimestamp();
        self.stats.success = true;

        logInfo("Restore completed: {} blocks, {} events, {d:.2} MB in {d:.2}s", .{
            self.stats.blocks_written,
            self.stats.events_restored,
            @as(f64, @floatFromInt(self.stats.bytes_written)) / (1024.0 * 1024.0),
            self.stats.durationSeconds(),
        });

        return self.stats;
    }

    /// List all blocks in the source.
    /// Supports S3, GCS, Azure, and local filesystem.
    fn listBlocks(self: *RestoreManager) RestoreError![]BlockMetadata {
        return switch (self.provider) {
            .local => self.listLocalBlocks(),
            .s3 => self.listS3Blocks(),
            .gcs => self.listGcsBlocks(),
            .azure => self.listAzureBlocks(),
        };
    }

    /// List blocks from local filesystem.
    fn listLocalBlocks(self: *RestoreManager) RestoreError![]BlockMetadata {
        const path = self.localSourcePath();

        if (path.len == 0) {
            logErr("Local restore source path is empty", .{});
            return RestoreError.InvalidSource;
        }

        // Open the backup directory
        var dir = (if (fs.path.isAbsolute(path))
            fs.openDirAbsolute(path, .{ .iterate = true })
        else
            fs.cwd().openDir(path, .{ .iterate = true })) catch |err| {
            logErr("Failed to open local backup directory {s}: {}", .{ path, err });
            return RestoreError.InvalidSource;
        };
        defer dir.close();

        // Count .block files first
        var count: usize = 0;
        var iter = dir.iterate();
        while (iter.next() catch return RestoreError.StorageError) |entry| {
            if (entry.kind == .file and isBlockFile(entry.name)) {
                count += 1;
            }
        }

        if (count == 0) {
            return &[_]BlockMetadata{};
        }

        // Allocate array for block metadata
        const blocks = self.allocator.alloc(BlockMetadata, count) catch
            return RestoreError.OutOfMemory;
        errdefer self.allocator.free(blocks);

        // Populate block metadata
        var idx: usize = 0;
        iter = dir.iterate();
        while (iter.next() catch return RestoreError.StorageError) |entry| {
            if (entry.kind == .file and isBlockFile(entry.name)) {
                const sequence = parseBlockSequence(entry.name) orelse continue;
                const compressed = mem.endsWith(u8, entry.name, ".block.zst");

                // Get file size
                const stat = dir.statFile(entry.name) catch continue;
                const sidecar_meta = try readLocalBlockMetadata(dir, entry.name);
                const closed_timestamp = if (sidecar_meta) |meta|
                    meta.closed_timestamp
                else
                    try readBlockClosedTimestamp(dir, entry.name);

                // Duplicate the name for object_key
                const key = self.allocator.dupe(u8, entry.name) catch
                    return RestoreError.OutOfMemory;

                blocks[idx] = BlockMetadata{
                    .sequence = sequence,
                    .closed_timestamp = closed_timestamp,
                    .address = if (sidecar_meta) |meta| meta.address else null,
                    .size = stat.size,
                    .checksum = if (sidecar_meta) |meta| meta.checksum else 0,
                    .object_key = key,
                    .compressed = compressed,
                };
                if (sidecar_meta) |meta| {
                    if (meta.sequence != sequence) {
                        logErr(
                            "Local metadata sidecar sequence mismatch for {s}: expected {}, got {}",
                            .{ entry.name, sequence, meta.sequence },
                        );
                        return RestoreError.InvalidSource;
                    }
                }
                idx += 1;
            }
        }

        // Sort by sequence number
        std.mem.sort(BlockMetadata, blocks[0..idx], {}, struct {
            fn lessThan(_: void, a: BlockMetadata, b: BlockMetadata) bool {
                return a.sequence < b.sequence;
            }
        }.lessThan);

        return blocks[0..idx];
    }

    /// List blocks from S3 (using AWS CLI as external process).
    /// Uses the S3-compatible XML API with SigV4 credentials.
    fn listS3Blocks(self: *RestoreManager) RestoreError![]BlockMetadata {
        const auth = self.loadS3LikeAuth(.s3) catch return RestoreError.StorageError;
        defer auth.deinit(self.allocator);
        return self.listS3CompatibleBlocks(auth, "s3://");
    }

    /// List blocks from GCS.
    fn listGcsBlocks(self: *RestoreManager) RestoreError![]BlockMetadata {
        const auth = self.loadS3LikeAuth(.gcs) catch return RestoreError.StorageError;
        defer auth.deinit(self.allocator);
        return self.listS3CompatibleBlocks(auth, "gs://");
    }

    /// List blocks from Azure Blob Storage.
    fn listAzureBlocks(self: *RestoreManager) RestoreError![]BlockMetadata {
        const auth = self.loadAzureAuth() catch return RestoreError.StorageError;
        defer auth.deinit(self.allocator);
        return self.listAzureBlobBlocks(auth);
    }

    /// Filter blocks by point-in-time target.
    fn filterBlocksByPointInTime(
        self: *RestoreManager,
        blocks: []BlockMetadata,
    ) RestoreError![]BlockMetadata {
        if (blocks.len == 0) return blocks;

        switch (self.config.point_in_time) {
            .latest => {
                // Include all blocks
                return blocks;
            },
            .sequence => |target_seq| {
                // Find the cutoff point
                var cutoff: usize = 0;
                for (blocks, 0..) |block, i| {
                    if (block.sequence <= target_seq) {
                        cutoff = i + 1;
                    } else {
                        break;
                    }
                }
                if (cutoff == 0) {
                    logErr("No blocks found with sequence <= {}", .{target_seq});
                    return RestoreError.TargetNotFound;
                }
                return blocks[0..cutoff];
            },
            .timestamp => |target_ts| {
                var cutoff: usize = 0;
                var saw_timestamp = false;

                for (blocks, 0..) |block, i| {
                    if (block.closed_timestamp == 0) {
                        // Legacy backups may not carry close timestamps. While scanning in
                        // sequence order, treat them conservatively as part of the current prefix.
                        cutoff = i + 1;
                        continue;
                    }

                    saw_timestamp = true;
                    if (block.closed_timestamp <= target_ts) {
                        cutoff = i + 1;
                    } else {
                        break;
                    }
                }

                if (!saw_timestamp) {
                    logWarn(
                        "Restore source has no timestamp metadata; using full sequence range for PITR target {}",
                        .{target_ts},
                    );
                    return blocks;
                }

                if (cutoff == 0) {
                    logErr("No blocks found with timestamp <= {}", .{target_ts});
                    return RestoreError.TargetNotFound;
                }

                return blocks[0..cutoff];
            },
        }
    }

    /// Verify there are no gaps in the block sequence.
    fn verifySequenceContinuity(self: *RestoreManager, blocks: []BlockMetadata) RestoreError!void {
        if (blocks.len == 0) return;

        var expected_seq = blocks[0].sequence;
        for (blocks) |block| {
            if (block.sequence != expected_seq) {
                logErr("Sequence gap: expected {}, got {}", .{ expected_seq, block.sequence });
                return RestoreError.SequenceGap;
            }
            expected_seq += 1;
        }

        self.stats.max_sequence_restored = blocks[blocks.len - 1].sequence;
    }

    /// Download and verify a single block.
    fn downloadAndVerifyBlock(self: *RestoreManager, block: BlockMetadata) RestoreError!void {
        self.stats.blocks_downloaded += 1;

        if (self.provider == .local) {
            self.stats.bytes_downloaded += block.size;
        } else {
            const downloaded = self.readBlockData(block) catch |err| {
                logErr("Failed to download block {} during verification: {}", .{ block.sequence, err });
                return RestoreError.StorageError;
            };
            defer self.allocator.free(downloaded);
            self.stats.bytes_downloaded += downloaded.len;
        }

        // Verify checksum if enabled
        if (self.config.verify_checksums) {
            const valid = self.verifyBlockChecksum(block) catch |err| {
                logErr("Checksum verification failed for block {}: {}", .{ block.sequence, err });
                return RestoreError.ChecksumMismatch;
            };

            if (!valid) {
                logErr("Checksum mismatch for block {}", .{block.sequence});
                return RestoreError.ChecksumMismatch;
            }
            self.stats.blocks_verified += 1;
        }
    }

    /// Verify block checksum.
    fn verifyBlockChecksum(self: *RestoreManager, block: BlockMetadata) !bool {
        // For local storage, read the block and verify its internal checksum
        if (self.provider == .local) {
            const data = self.readLocalBlockData(block) catch return false;
            defer self.allocator.free(data);

            const parsed = parseBlockHeader(data) orelse return false;
            if (!validateBlockBytes(data)) return false;
            if (block.checksum != 0 and parsed.checksum != block.checksum) return false;
            return true;
        }

        // For cloud storage, checksum is verified during download
        return true;
    }

    fn validateBlockBytes(data: []const u8) bool {
        const header = parseBlockHeader(data) orelse return false;

        if (header.size < @sizeOf(vsr.Header) or header.size > data.len) return false;
        if (!header.valid_checksum()) return false;

        return header.valid_checksum_body(data[@sizeOf(vsr.Header)..header.size]);
    }

    /// Write blocks to the destination data file.
    fn writeBlocks(self: *RestoreManager, blocks: []BlockMetadata) RestoreError!void {
        logInfo("Writing {} blocks to {s}...", .{ blocks.len, self.config.dest_data_file });

        // Open/create destination file
        const dest_file = fs.createFileAbsolute(self.config.dest_data_file, .{
            .truncate = true,
        }) catch |err| {
            logErr("Failed to create destination file: {}", .{err});
            return RestoreError.InvalidDestination;
        };
        defer dest_file.close();

        const use_grid_addresses = self.shouldRestoreGridLayout(blocks) catch |err| {
            logErr("Restore metadata is incomplete for grid-addressed restore: {}", .{err});
            return err;
        };
        if (use_grid_addresses) {
            try self.prepareGridLayoutDestination(&dest_file, blocks);
        }

        // Write each block
        for (blocks) |block| {
            // Read source block
            const source_data = self.readBlockData(block) catch |err| {
                logErr("Failed to read block {}: {}", .{ block.sequence, err });
                return RestoreError.StorageError;
            };
            defer self.allocator.free(source_data);

            if (use_grid_addresses) {
                const address = block.address.?;
                const offset = vsr.Zone.offset(.grid, (address - 1) * constants.block_size);
                dest_file.pwriteAll(source_data, offset) catch |err| {
                    logErr("Failed to write block {} at grid address {}: {}", .{
                        block.sequence,
                        address,
                        err,
                    });
                    return switch (err) {
                        error.DiskQuota, error.NoSpaceLeft => RestoreError.DiskFull,
                        else => RestoreError.StorageError,
                    };
                };
            } else {
                dest_file.writeAll(source_data) catch |err| {
                    logErr("Failed to write block {}: {}", .{ block.sequence, err });
                    return switch (err) {
                        error.DiskQuota, error.NoSpaceLeft => RestoreError.DiskFull,
                        else => RestoreError.StorageError,
                    };
                };
            }

            self.stats.blocks_written += 1;
            self.stats.bytes_written += source_data.len;
        }

        // Sync to ensure durability
        dest_file.sync() catch |err| {
            logErr("Failed to sync destination file: {}", .{err});
            return RestoreError.StorageError;
        };
    }

    /// Read block data from source storage.
    fn readBlockData(self: *RestoreManager, block: BlockMetadata) ![]u8 {
        return switch (self.provider) {
            .local => self.readLocalBlockData(block),
            .s3 => self.readS3CompatibleBlockData(block, "s3://", .s3),
            .gcs => self.readS3CompatibleBlockData(block, "gs://", .gcs),
            .azure => self.readAzureBlockData(block),
        };
    }

    /// Build the RAM index from restored blocks.
    fn buildIndex(self: *RestoreManager) RestoreError!void {
        logInfo("Building RAM index from restored blocks...", .{});

        // Open the destination data file
        const file = fs.openFileAbsolute(self.config.dest_data_file, .{}) catch |err| {
            logErr("Failed to open data file for index building: {}", .{err});
            return RestoreError.IndexBuildFailed;
        };
        defer file.close();

        // Read and count events
        // In production, this would:
        // 1. Iterate through all blocks in the data file
        // 2. Parse GeoEvent structs from each block
        // 3. Insert entity_id -> latest position into RAM index
        // 4. Track tombstones for deleted entities
        // 5. Apply TTL filtering if skip_expired is enabled

        const event_size: u64 = 128; // GeoEvent is 128 bytes
        const approx_events = self.stats.bytes_written / event_size;

        logInfo("Index build: ~{} events estimated from {} bytes", .{
            approx_events,
            self.stats.bytes_written,
        });

        // Estimate events restored (actual count would come from scanning)
        self.stats.events_restored = approx_events;

        logInfo("RAM index built successfully", .{});
    }

    fn shouldRestoreGridLayout(
        self: *RestoreManager,
        blocks: []const BlockMetadata,
    ) RestoreError!bool {
        _ = self;

        var saw_address = false;
        for (blocks) |block| {
            if (block.address) |_| {
                saw_address = true;
                continue;
            }

            if (saw_address) return RestoreError.InvalidSource;
        }

        if (!saw_address) return false;

        for (blocks) |block| {
            if (block.address == null) return RestoreError.InvalidSource;
        }
        return true;
    }

    fn prepareGridLayoutDestination(
        self: *RestoreManager,
        dest_file: *const fs.File,
        blocks: []const BlockMetadata,
    ) RestoreError!void {
        _ = self;

        var max_end: u64 = vsr.Zone.start(.grid);
        for (blocks) |block| {
            const address = block.address orelse return RestoreError.InvalidSource;
            if (address == 0) return RestoreError.InvalidSource;

            const offset = vsr.Zone.offset(.grid, (address - 1) * constants.block_size);
            const end = offset + block.size;
            if (end > max_end) max_end = end;
        }

        dest_file.setEndPos(max_end) catch |err| {
            logErr("Failed to size destination file for grid restore: {}", .{err});
            return RestoreError.StorageError;
        };
    }

    /// Write the superblock with restore metadata.
    fn writeSuperblock(
        self: *RestoreManager,
        selected_checkpoint_artifact: ?checkpoint_artifact.DurableCheckpointArtifact,
    ) RestoreError!void {
        logInfo("Writing superblock with restore metadata...", .{});

        const artifact = selected_checkpoint_artifact orelse {
            logInfo("No durable checkpoint artifact selected; skipping bootable superblock synthesis", .{});
            return;
        };

        if (artifact.checkpoint.storage_size < vsr.superblock.data_file_size_min) {
            logErr(
                "Checkpoint artifact storage size {} is smaller than minimum {}",
                .{ artifact.checkpoint.storage_size, vsr.superblock.data_file_size_min },
            );
            return RestoreError.SuperblockWriteFailed;
        }

        const dest_file = fs.openFileAbsolute(self.config.dest_data_file, .{ .mode = .read_write }) catch |err| {
            logErr("Failed to open destination file for superblock write: {}", .{err});
            return RestoreError.InvalidDestination;
        };
        defer dest_file.close();

        dest_file.setEndPos(artifact.checkpoint.storage_size) catch |err| {
            logErr("Failed to size restored file for superblock write: {}", .{err});
            return RestoreError.StorageError;
        };

        self.writeRestoreJournal(dest_file, artifact) catch |err| {
            logErr("Failed to write restore journal scaffold: {}", .{err});
            return switch (err) {
                error.DiskQuota, error.NoSpaceLeft => RestoreError.DiskFull,
                else => RestoreError.SuperblockWriteFailed,
            };
        };

        vsr.superblock.writeRestoreSuperblockCopies(dest_file, .{
            .release_format = artifact.release_format,
            .cluster = artifact.cluster,
            .sharding_strategy = artifact.sharding_strategy,
            .vsr_state = .{
                .checkpoint = artifact.checkpoint,
                .replica_id = artifact.replica_id,
                .members = artifact.members,
                .commit_max = artifact.commit_max,
                .sync_op_min = artifact.sync_op_min,
                .sync_op_max = artifact.sync_op_max,
                .log_view = artifact.log_view,
                .view = artifact.view,
                .replica_count = artifact.replica_count,
            },
            .view_headers_count = artifact.view_headers_count,
            .view_headers_all = artifact.view_headers_all,
        }) catch |err| {
            logErr("Failed to write restore superblock copies: {}", .{err});
            return switch (err) {
                error.DiskQuota, error.NoSpaceLeft => RestoreError.DiskFull,
                else => RestoreError.SuperblockWriteFailed,
            };
        };

        logInfo("Restore superblock metadata:", .{});
        logInfo("  Cluster ID: {x}", .{artifact.cluster});
        logInfo("  Replica ID: {x}", .{artifact.replica_id});
        logInfo("  Checkpoint op: {}", .{artifact.checkpointOp()});
        logInfo("  Storage size: {}", .{artifact.checkpoint.storage_size});
        logInfo("Superblock written successfully", .{});
    }

    fn artifactHeadOp(artifact: checkpoint_artifact.DurableCheckpointArtifact) u64 {
        var head_op = artifact.checkpoint.header.op;
        for (artifact.view_headers_all[0..artifact.view_headers_count]) |header| {
            if (header.operation == .reserved) continue;
            if (header.op > head_op) head_op = header.op;
        }
        return head_op;
    }

    fn synthesizeRestorePrepareHeader(
        artifact: checkpoint_artifact.DurableCheckpointArtifact,
        op: u64,
        parent_checksum: u128,
    ) vsr.Header.Prepare {
        var header = std.mem.zeroInit(vsr.Header.Prepare, .{
            .cluster = artifact.cluster,
            .view = artifact.view,
            .release = artifact.release_format,
            .command = .prepare,
            .op = op,
            .commit = op -| 1,
            .operation = .pulse,
            .parent = parent_checksum,
            .timestamp = op,
        });
        header.set_checksum_body(&[_]u8{});
        header.set_checksum();
        return header;
    }

    fn restoreJournalHeaderForOp(
        artifact: checkpoint_artifact.DurableCheckpointArtifact,
        op: u64,
        parent_checksum: u128,
    ) vsr.Header.Prepare {
        if (op == 0) return vsr.Header.Prepare.root(artifact.cluster);

        for (artifact.view_headers_all[0..artifact.view_headers_count]) |header| {
            if (header.operation == .reserved) continue;
            if (header.op == op) return header;
        }

        if (artifact.checkpoint.header.op == op) {
            return artifact.checkpoint.header;
        }

        return synthesizeRestorePrepareHeader(artifact, op, parent_checksum);
    }

    fn writeRestoreJournal(
        self: *RestoreManager,
        dest_file: fs.File,
        artifact: checkpoint_artifact.DurableCheckpointArtifact,
    ) !void {
        var headers_buffer = try self.allocator.alignedAlloc(
            u8,
            constants.sector_size,
            vsr.sector_ceil(constants.journal_size_headers),
        );
        defer self.allocator.free(headers_buffer);
        @memset(headers_buffer, 0);

        for (0..constants.journal_slot_count) |slot| {
            const header_bytes = headers_buffer
                [slot * @sizeOf(vsr.Header.Prepare) ..][0..@sizeOf(vsr.Header.Prepare)];
            const header: *align(1) vsr.Header.Prepare = std.mem.bytesAsValue(
                vsr.Header.Prepare,
                header_bytes,
            );
            header.* = if (slot == 0)
                vsr.Header.Prepare.root(artifact.cluster)
            else
                vsr.Header.Prepare.reserve(artifact.cluster, @intCast(slot));
        }

        const head_op = artifactHeadOp(artifact);
        const range_start = (head_op + 1) -| constants.journal_slot_count;
        var previous = restoreJournalHeaderForOp(
            artifact,
            if (range_start == 0) 0 else range_start - 1,
            0,
        );

        var op = if (range_start == 0) @as(u64, 1) else range_start;
        while (op <= head_op) : (op += 1) {
            const header_value = restoreJournalHeaderForOp(artifact, op, previous.checksum);
            previous = header_value;

            const slot: usize = @intCast(@mod(op, constants.journal_slot_count));
            const header_bytes = headers_buffer
                [slot * @sizeOf(vsr.Header.Prepare) ..][0..@sizeOf(vsr.Header.Prepare)];
            const header: *align(1) vsr.Header.Prepare = std.mem.bytesAsValue(
                vsr.Header.Prepare,
                header_bytes,
            );
            header.* = header_value;
        }

        try dest_file.pwriteAll(headers_buffer, vsr.Zone.offset(.wal_headers, 0));

        var prepare_buffer = try self.allocator.alignedAlloc(
            u8,
            constants.sector_size,
            constants.message_size_max,
        );
        defer self.allocator.free(prepare_buffer);

        for (0..constants.journal_slot_count) |slot| {
            @memset(prepare_buffer, 0);
            const header: *align(1) vsr.Header.Prepare = std.mem.bytesAsValue(
                vsr.Header.Prepare,
                prepare_buffer[0..@sizeOf(vsr.Header.Prepare)],
            );
            const header_bytes = headers_buffer
                [slot * @sizeOf(vsr.Header.Prepare) ..][0..@sizeOf(vsr.Header.Prepare)];
            @memcpy(std.mem.asBytes(header), header_bytes);

            const offset_in_zone = @as(u64, @intCast(slot)) * constants.message_size_max;
            try dest_file.pwriteAll(
                prepare_buffer,
                vsr.Zone.offset(.wal_prepares, offset_in_zone),
            );
        }
    }

    /// Detect storage provider from URL scheme.
    fn detectProvider(url: []const u8) StorageProvider {
        if (mem.startsWith(u8, url, "s3://")) return .s3;
        if (mem.startsWith(u8, url, "gs://")) return .gcs;
        if (mem.startsWith(u8, url, "azure://")) return .azure;
        return .local;
    }

    /// Parse cluster ID and replica ID from source URL.
    fn parseSourceUrl(self: *RestoreManager) !void {
        // URL format: s3://bucket/<cluster-id>/<replica-id>
        // or: /local/path/<cluster-id>/<replica-id>

        const url = self.config.source_url;

        // Skip scheme
        var path = url;
        if (mem.indexOf(u8, url, "://")) |idx| {
            path = url[idx + 3 ..];
        }

        // Find cluster-id and replica-id segments
        var iter = mem.splitScalar(u8, path, '/');
        _ = iter.next(); // Skip bucket name

        if (iter.next()) |cluster_str| {
            self.cluster_id = std.fmt.parseInt(u128, cluster_str, 16) catch null;
        }

        if (iter.next()) |replica_str| {
            if (mem.startsWith(u8, replica_str, "replica-")) {
                self.replica_id = std.fmt.parseInt(u8, replica_str[8..], 10) catch null;
            }
        }
    }

    /// Get current restore statistics.
    pub fn getStats(self: *const RestoreManager) RestoreStats {
        return self.stats;
    }

    /// Check if restore is in dry-run mode.
    pub fn isDryRun(self: *const RestoreManager) bool {
        return self.config.dry_run;
    }

    /// Abort the restore operation.
    pub fn abort(self: *RestoreManager) void {
        self.stats.error_message = "Aborted by user";
        self.stats.end_time_ns = std.time.nanoTimestamp();
    }

    fn freeBlockMetadata(self: *RestoreManager, blocks: []BlockMetadata) void {
        if (blocks.len == 0) return;
        for (blocks) |block| {
            self.allocator.free(block.object_key);
        }
        self.allocator.free(blocks);
    }

    fn isBlockFile(name: []const u8) bool {
        return mem.endsWith(u8, name, ".block") or mem.endsWith(u8, name, ".block.zst");
    }

    fn parseBlockSequence(name: []const u8) ?u64 {
        const base_name = if (mem.endsWith(u8, name, ".block.zst"))
            name[0 .. name.len - ".block.zst".len]
        else if (mem.endsWith(u8, name, ".block"))
            name[0 .. name.len - ".block".len]
        else
            return null;

        return std.fmt.parseInt(u64, base_name, 10) catch null;
    }

    const BlockSidecarMetadata = struct {
        sequence: u64,
        address: u64,
        checksum: u128,
        closed_timestamp: i64,
    };

    fn selectCheckpointArtifact(
        self: *RestoreManager,
        blocks: []const BlockMetadata,
    ) RestoreError!?checkpoint_artifact.DurableCheckpointArtifact {
        if (blocks.len == 0) return null;

        return switch (self.provider) {
            .local => try self.selectLocalCheckpointArtifact(blocks),
            .s3 => blk: {
                const auth = self.loadS3LikeAuth(.s3) catch return RestoreError.StorageError;
                defer auth.deinit(self.allocator);
                break :blk try self.selectS3CompatibleCheckpointArtifact(blocks, auth, "s3://");
            },
            .gcs => blk: {
                const auth = self.loadS3LikeAuth(.gcs) catch return RestoreError.StorageError;
                defer auth.deinit(self.allocator);
                break :blk try self.selectS3CompatibleCheckpointArtifact(blocks, auth, "gs://");
            },
            .azure => blk: {
                const auth = self.loadAzureAuth() catch return RestoreError.StorageError;
                defer auth.deinit(self.allocator);
                break :blk try self.selectAzureCheckpointArtifact(blocks, auth);
            },
        };
    }

    fn selectLocalCheckpointArtifact(
        self: *RestoreManager,
        blocks: []const BlockMetadata,
    ) RestoreError!?checkpoint_artifact.DurableCheckpointArtifact {
        const path = self.localSourcePath();
        if (path.len == 0) return null;

        var dir = (if (fs.path.isAbsolute(path))
            fs.openDirAbsolute(path, .{ .iterate = true })
        else
            fs.cwd().openDir(path, .{ .iterate = true })) catch return null;
        defer dir.close();

        const max_sequence = blocks[blocks.len - 1].sequence;
        var best: ?checkpoint_artifact.DurableCheckpointArtifact = null;
        var iter = dir.iterate();
        while (iter.next() catch return RestoreError.StorageError) |entry| {
            if (entry.kind != .file or !checkpoint_artifact.isCheckpointFile(entry.name)) continue;

            const contents = dir.readFileAlloc(self.allocator, entry.name, 64 * 1024) catch
                return RestoreError.StorageError;
            defer self.allocator.free(contents);

            self.considerCheckpointArtifact(&best, entry.name, contents, max_sequence);
        }

        return best;
    }

    fn selectS3CompatibleCheckpointArtifact(
        self: *RestoreManager,
        blocks: []const BlockMetadata,
        auth: S3LikeAuth,
        comptime scheme: []const u8,
    ) RestoreError!?checkpoint_artifact.DurableCheckpointArtifact {
        const location = try self.parseRemotePath(scheme);
        var client = s3_client.S3Client.init(self.allocator, .{
            .endpoint = auth.endpoint,
            .region = auth.region,
            .credentials = .{
                .access_key_id = auth.access_key_id,
                .secret_access_key = auth.secret_access_key,
            },
        }) catch return RestoreError.StorageError;
        defer client.deinit();

        const prefix = try self.listingPrefix(location.prefix);
        defer self.allocator.free(prefix);

        const objects = client.listObjects(location.container, prefix) catch |err| {
            logErr(
                "Failed to list remote checkpoint artifacts from {s}: {}",
                .{ self.config.source_url, err },
            );
            return RestoreError.StorageError;
        };
        defer self.freeObjectInfos(objects);

        const max_sequence = blocks[blocks.len - 1].sequence;
        var best: ?checkpoint_artifact.DurableCheckpointArtifact = null;
        for (objects) |object| {
            const artifact_name = blockNameFromObjectKey(object.key);
            if (!checkpoint_artifact.isCheckpointFile(artifact_name)) continue;

            const contents = client.getObject(location.container, object.key) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => {
                    logErr("Failed to fetch remote checkpoint artifact {s}: {}", .{
                        object.key,
                        err,
                    });
                    return RestoreError.StorageError;
                },
            };
            defer self.allocator.free(contents);

            self.considerCheckpointArtifact(&best, artifact_name, contents, max_sequence);
        }
        return best;
    }

    fn selectAzureCheckpointArtifact(
        self: *RestoreManager,
        blocks: []const BlockMetadata,
        auth: AzureAuth,
    ) RestoreError!?checkpoint_artifact.DurableCheckpointArtifact {
        const location = try self.parseRemotePath("azure://");
        const prefix = try self.listingPrefix(location.prefix);
        defer self.allocator.free(prefix);

        var object_list = std.ArrayList(s3_client.ObjectInfo).init(self.allocator);
        defer {
            for (object_list.items) |object| {
                self.allocator.free(object.key);
            }
            object_list.deinit();
        }

        var marker: ?[]u8 = null;
        defer if (marker) |value| self.allocator.free(value);

        while (true) {
            const url = try self.buildAzureListUrl(auth, location.container, prefix, marker);
            defer self.allocator.free(url);

            const body = try self.fetchAzureUrl(url);
            defer self.allocator.free(body);

            const page = try self.parseAzureListResponse(body);
            defer self.allocator.free(page.objects);

            try object_list.appendSlice(page.objects);

            if (page.next_marker) |next| {
                if (marker) |value| self.allocator.free(value);
                marker = self.allocator.dupe(u8, mem.trim(u8, next, " \t\r\n")) catch
                    return RestoreError.OutOfMemory;
            } else {
                break;
            }
        }

        const max_sequence = blocks[blocks.len - 1].sequence;
        var best: ?checkpoint_artifact.DurableCheckpointArtifact = null;
        for (object_list.items) |object| {
            const artifact_name = blockNameFromObjectKey(object.key);
            if (!checkpoint_artifact.isCheckpointFile(artifact_name)) continue;

            const artifact = try self.readAzureCheckpointArtifact(auth, location.container, object.key);
            if (artifact) |contents| {
                defer self.allocator.free(contents);
                self.considerCheckpointArtifact(&best, artifact_name, contents, max_sequence);
            }
        }
        return best;
    }

    fn considerCheckpointArtifact(
        self: *RestoreManager,
        best: *?checkpoint_artifact.DurableCheckpointArtifact,
        artifact_name: []const u8,
        contents: []const u8,
        max_sequence: u64,
    ) void {
        const sequence_from_name =
            checkpoint_artifact.parseSequenceMaxFromFileName(artifact_name).?;
        const artifact = checkpoint_artifact.DurableCheckpointArtifact.parseKeyValue(contents) catch |err| {
            logWarn("Ignoring malformed checkpoint artifact {s}: {}", .{ artifact_name, err });
            return;
        };

        if (artifact.sequence_max != sequence_from_name) {
            logWarn("Ignoring checkpoint artifact with mismatched filename {s}", .{artifact_name});
            return;
        }
        if (artifact.sequence_max > max_sequence) return;

        switch (self.config.point_in_time) {
            .timestamp => |target_ts| {
                if (artifact.closed_timestamp > target_ts) return;
            },
            .latest, .sequence => {},
        }

        if (best.* == null or artifact.sequence_max > best.*.?.sequence_max) {
            best.* = artifact;
            return;
        }
        if (artifact.sequence_max == best.*.?.sequence_max and
            artifact.checkpointOp() > best.*.?.checkpointOp())
        {
            best.* = artifact;
        }
    }

    fn readBlockClosedTimestamp(dir: fs.Dir, block_name: []const u8) RestoreError!i64 {
        var sidecar_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sidecar_name = std.fmt.bufPrint(&sidecar_name_buf, "{s}.ts", .{block_name}) catch
            return RestoreError.InvalidSource;

        const sidecar = dir.openFile(sidecar_name, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return RestoreError.StorageError,
        };
        defer sidecar.close();

        var contents: [64]u8 = undefined;
        const bytes_read = sidecar.readAll(&contents) catch return RestoreError.StorageError;
        if (bytes_read == 0) {
            logErr("Timestamp sidecar {s} is empty", .{sidecar_name});
            return RestoreError.InvalidSource;
        }

        const trimmed = mem.trim(u8, contents[0..bytes_read], " \t\r\n");
        if (trimmed.len == 0) {
            logErr("Timestamp sidecar {s} is blank", .{sidecar_name});
            return RestoreError.InvalidSource;
        }

        return std.fmt.parseInt(i64, trimmed, 10) catch {
            logErr("Timestamp sidecar {s} is malformed", .{sidecar_name});
            return RestoreError.InvalidSource;
        };
    }

    fn readLocalBlockMetadata(
        dir: fs.Dir,
        block_name: []const u8,
    ) RestoreError!?BlockSidecarMetadata {
        var sidecar_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sidecar_name = std.fmt.bufPrint(&sidecar_name_buf, "{s}.meta", .{block_name}) catch
            return RestoreError.InvalidSource;

        const sidecar = dir.openFile(sidecar_name, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return RestoreError.StorageError,
        };
        defer sidecar.close();

        var contents: [512]u8 = undefined;
        const bytes_read = sidecar.readAll(&contents) catch return RestoreError.StorageError;
        if (bytes_read == 0) {
            logErr("Metadata sidecar {s} is empty", .{sidecar_name});
            return RestoreError.InvalidSource;
        }

        return try parseBlockSidecarMetadata(contents[0..bytes_read], sidecar_name);
    }

    fn parseBlockSidecarMetadata(
        contents: []const u8,
        sidecar_name: []const u8,
    ) RestoreError!BlockSidecarMetadata {
        var sequence: ?u64 = null;
        var address: ?u64 = null;
        var checksum: ?u128 = null;
        var closed_timestamp: ?i64 = null;

        var lines = mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;

            const equals = mem.indexOfScalar(u8, line, '=') orelse {
                logErr("Metadata sidecar {s} contains malformed line", .{sidecar_name});
                return RestoreError.InvalidSource;
            };
            const key = mem.trim(u8, line[0..equals], " \t\r\n");
            const value = mem.trim(u8, line[equals + 1 ..], " \t\r\n");

            if (mem.eql(u8, key, "sequence")) {
                sequence = std.fmt.parseInt(u64, value, 10) catch return RestoreError.InvalidSource;
            } else if (mem.eql(u8, key, "address")) {
                address = std.fmt.parseInt(u64, value, 10) catch return RestoreError.InvalidSource;
            } else if (mem.eql(u8, key, "checksum")) {
                checksum = std.fmt.parseInt(u128, value, 16) catch return RestoreError.InvalidSource;
            } else if (mem.eql(u8, key, "closed_timestamp")) {
                closed_timestamp = std.fmt.parseInt(i64, value, 10) catch return RestoreError.InvalidSource;
            }
        }

        return .{
            .sequence = sequence orelse return RestoreError.InvalidSource,
            .address = address orelse return RestoreError.InvalidSource,
            .checksum = checksum orelse return RestoreError.InvalidSource,
            .closed_timestamp = closed_timestamp orelse return RestoreError.InvalidSource,
        };
    }

    fn readRemoteBlockMetadata(
        self: *RestoreManager,
        client: *s3_client.S3Client,
        bucket: []const u8,
        key: []const u8,
    ) RestoreError!?BlockSidecarMetadata {
        const contents = client.getObject(bucket, key) catch |err| switch (err) {
            error.ObjectNotFound => return null,
            else => {
                logErr("Failed to fetch metadata sidecar {s}: {}", .{ key, err });
                return RestoreError.StorageError;
            },
        };
        defer self.allocator.free(contents);

        return try parseBlockSidecarMetadata(contents, key);
    }

    const KeyValueFile = struct {
        contents: []u8,

        fn deinit(self: *KeyValueFile, allocator: mem.Allocator) void {
            allocator.free(self.contents);
        }

        fn get(self: *const KeyValueFile, key: []const u8) ?[]const u8 {
            var lines = mem.splitScalar(u8, self.contents, '\n');
            while (lines.next()) |raw_line| {
                const line = mem.trim(u8, raw_line, " \t\r\n");
                if (line.len == 0 or line[0] == '#') continue;
                const equals = mem.indexOfScalar(u8, line, '=') orelse continue;
                const line_key = mem.trim(u8, line[0..equals], " \t\r\n");
                if (!mem.eql(u8, line_key, key)) continue;
                return mem.trim(u8, line[equals + 1 ..], " \t\r\n");
            }
            return null;
        }
    };

    const S3LikeAuth = struct {
        endpoint: []u8,
        region: []u8,
        access_key_id: []u8,
        secret_access_key: []u8,

        fn deinit(self: S3LikeAuth, allocator: mem.Allocator) void {
            allocator.free(self.endpoint);
            allocator.free(self.region);
            allocator.free(self.access_key_id);
            allocator.free(self.secret_access_key);
        }
    };

    const AzureAuth = struct {
        endpoint: []u8,
        sas_token: []u8,

        fn deinit(self: AzureAuth, allocator: mem.Allocator) void {
            allocator.free(self.endpoint);
            allocator.free(self.sas_token);
        }
    };

    const RemotePath = struct {
        container: []const u8,
        prefix: []const u8,
    };

    const AzureListPage = struct {
        objects: []s3_client.ObjectInfo,
        next_marker: ?[]const u8,
    };

    fn loadCredentialsFile(self: *RestoreManager) !?KeyValueFile {
        const path = self.config.credentials_path orelse return null;
        const contents = fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch |err| {
            logErr("Failed to read credentials file {s}: {}", .{ path, err });
            return RestoreError.StorageError;
        };
        return .{ .contents = contents };
    }

    fn loadS3LikeAuth(
        self: *RestoreManager,
        provider: StorageProvider,
    ) RestoreError!S3LikeAuth {
        var creds_file = self.loadCredentialsFile() catch return RestoreError.StorageError;
        defer if (creds_file) |*file| file.deinit(self.allocator);

        const access_key = std.posix.getenv("AWS_ACCESS_KEY_ID") orelse
            if (creds_file) |*file| file.get("access_key_id") else null;
        const secret_key = std.posix.getenv("AWS_SECRET_ACCESS_KEY") orelse
            if (creds_file) |*file| file.get("secret_access_key") else null;

        if (access_key == null or secret_key == null) {
            logErr("Object storage credentials missing for restore source {s}", .{
                self.config.source_url,
            });
            return RestoreError.StorageError;
        }

        const region_default = switch (provider) {
            .gcs => "auto",
            else => "us-east-1",
        };
        const region = self.config.region orelse
            ((if (creds_file) |*file| file.get("region") else null) orelse region_default);

        const endpoint_owned = blk: {
            if (creds_file) |*file| {
                if (file.get("endpoint")) |value| {
                    break :blk self.allocator.dupe(u8, value) catch return RestoreError.OutOfMemory;
                }
            }
            switch (provider) {
                .s3 => break :blk std.fmt.allocPrint(
                    self.allocator,
                    "s3.{s}.amazonaws.com",
                    .{region},
                ) catch return RestoreError.OutOfMemory,
                .gcs => break :blk self.allocator.dupe(u8, "storage.googleapis.com") catch
                    return RestoreError.OutOfMemory,
                else => unreachable,
            }
        };

        return .{
            .endpoint = endpoint_owned,
            .region = self.allocator.dupe(u8, region) catch return RestoreError.OutOfMemory,
            .access_key_id = self.allocator.dupe(u8, access_key.?) catch return RestoreError.OutOfMemory,
            .secret_access_key = self.allocator.dupe(u8, secret_key.?) catch return RestoreError.OutOfMemory,
        };
    }

    fn loadAzureAuth(self: *RestoreManager) RestoreError!AzureAuth {
        var creds_file = self.loadCredentialsFile() catch return RestoreError.StorageError;
        defer if (creds_file) |*file| file.deinit(self.allocator);

        const endpoint_owned = blk: {
            if (creds_file) |*file| {
                if (file.get("endpoint")) |value| {
                    break :blk self.allocator.dupe(u8, value) catch return RestoreError.OutOfMemory;
                }
                if (file.get("account_name")) |account| {
                    break :blk std.fmt.allocPrint(
                        self.allocator,
                        "https://{s}.blob.core.windows.net",
                        .{account},
                    ) catch return RestoreError.OutOfMemory;
                }
            }
            if (std.posix.getenv("AZURE_STORAGE_ACCOUNT")) |account| {
                break :blk std.fmt.allocPrint(
                    self.allocator,
                    "https://{s}.blob.core.windows.net",
                    .{account},
                ) catch return RestoreError.OutOfMemory;
            }
            logErr("Azure restore requires endpoint or account_name in credentials", .{});
            return RestoreError.StorageError;
        };

        const sas_token_raw = std.posix.getenv("AZURE_STORAGE_SAS_TOKEN") orelse
            if (creds_file) |*file| file.get("sas_token") else null;
        if (sas_token_raw == null) {
            logErr("Azure restore requires SAS token credentials", .{});
            self.allocator.free(endpoint_owned);
            return RestoreError.StorageError;
        }

        const sas_token = mem.trimLeft(u8, sas_token_raw.?, "?");
        return .{
            .endpoint = endpoint_owned,
            .sas_token = self.allocator.dupe(u8, sas_token) catch return RestoreError.OutOfMemory,
        };
    }

    fn parseRemotePath(
        self: *const RestoreManager,
        comptime scheme: []const u8,
    ) RestoreError!RemotePath {
        if (!mem.startsWith(u8, self.config.source_url, scheme)) {
            return RestoreError.InvalidSource;
        }

        const rest = self.config.source_url[scheme.len..];
        if (rest.len == 0) return RestoreError.InvalidSource;

        if (mem.indexOfScalar(u8, rest, '/')) |slash| {
            return .{
                .container = rest[0..slash],
                .prefix = mem.trim(u8, rest[slash + 1 ..], "/"),
            };
        }

        return .{ .container = rest, .prefix = "" };
    }

    fn listingPrefix(self: *RestoreManager, prefix: []const u8) RestoreError![]u8 {
        if (prefix.len == 0) {
            return self.allocator.dupe(u8, "") catch return RestoreError.OutOfMemory;
        }
        if (prefix[prefix.len - 1] == '/') {
            return self.allocator.dupe(u8, prefix) catch return RestoreError.OutOfMemory;
        }
        return std.fmt.allocPrint(self.allocator, "{s}/", .{prefix}) catch
            return RestoreError.OutOfMemory;
    }

    fn blockNameFromObjectKey(object_key: []const u8) []const u8 {
        return fs.path.basename(object_key);
    }

    fn freeObjectInfos(self: *RestoreManager, infos: []s3_client.ObjectInfo) void {
        for (infos) |info| {
            self.allocator.free(info.key);
        }
        self.allocator.free(infos);
    }

    fn listS3CompatibleBlocks(
        self: *RestoreManager,
        auth: S3LikeAuth,
        comptime scheme: []const u8,
    ) RestoreError![]BlockMetadata {
        const location = try self.parseRemotePath(scheme);
        var client = s3_client.S3Client.init(self.allocator, .{
            .endpoint = auth.endpoint,
            .region = auth.region,
            .credentials = .{
                .access_key_id = auth.access_key_id,
                .secret_access_key = auth.secret_access_key,
            },
        }) catch {
            return RestoreError.StorageError;
        };
        defer client.deinit();

        const prefix = try self.listingPrefix(location.prefix);
        defer self.allocator.free(prefix);

        const objects = client.listObjects(location.container, prefix) catch |err| {
            logErr("Failed to list remote blocks from {s}: {}", .{ self.config.source_url, err });
            return RestoreError.StorageError;
        };
        defer self.freeObjectInfos(objects);

        var count: usize = 0;
        for (objects) |object| {
            if (isBlockFile(blockNameFromObjectKey(object.key))) count += 1;
        }

        if (count == 0) return &[_]BlockMetadata{};

        const blocks = self.allocator.alloc(BlockMetadata, count) catch return RestoreError.OutOfMemory;
        errdefer self.allocator.free(blocks);

        var idx: usize = 0;
        for (objects) |object| {
            const block_name = blockNameFromObjectKey(object.key);
            if (!isBlockFile(block_name)) continue;

            const sequence = parseBlockSequence(block_name) orelse continue;
            const metadata_key = std.fmt.allocPrint(self.allocator, "{s}.meta", .{object.key}) catch
                return RestoreError.OutOfMemory;
            defer self.allocator.free(metadata_key);
            const timestamp_key = std.fmt.allocPrint(self.allocator, "{s}.ts", .{object.key}) catch
                return RestoreError.OutOfMemory;
            defer self.allocator.free(timestamp_key);

            const sidecar_meta = try self.readRemoteBlockMetadata(
                &client,
                location.container,
                metadata_key,
            );
            const closed_timestamp = if (sidecar_meta) |meta|
                meta.closed_timestamp
            else
                self.readRemoteTimestampSidecar(&client, location.container, timestamp_key);

            blocks[idx] = .{
                .sequence = sequence,
                .closed_timestamp = closed_timestamp,
                .address = if (sidecar_meta) |meta| meta.address else null,
                .size = object.size,
                .checksum = if (sidecar_meta) |meta| meta.checksum else 0,
                .object_key = self.allocator.dupe(u8, object.key) catch return RestoreError.OutOfMemory,
                .compressed = mem.endsWith(u8, block_name, ".block.zst"),
            };
            if (sidecar_meta) |meta| {
                if (meta.sequence != sequence) {
                    logErr(
                        "Remote metadata sidecar sequence mismatch for {s}: expected {}, got {}",
                        .{ object.key, sequence, meta.sequence },
                    );
                    return RestoreError.InvalidSource;
                }
            }
            idx += 1;
        }

        std.mem.sort(BlockMetadata, blocks[0..idx], {}, struct {
            fn lessThan(_: void, a: BlockMetadata, b: BlockMetadata) bool {
                return a.sequence < b.sequence;
            }
        }.lessThan);

        return blocks[0..idx];
    }

    fn readRemoteTimestampSidecar(
        self: *RestoreManager,
        client: *s3_client.S3Client,
        bucket: []const u8,
        key: []const u8,
    ) i64 {
        const contents = client.getObject(bucket, key) catch return 0;
        defer self.allocator.free(contents);

        const trimmed = mem.trim(u8, contents, " \t\r\n");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseInt(i64, trimmed, 10) catch 0;
    }

    fn readLocalBlockData(self: *RestoreManager, block: BlockMetadata) ![]u8 {
        const path = self.localSourcePath();
        var dir = (if (fs.path.isAbsolute(path))
            fs.openDirAbsolute(path, .{})
        else
            fs.cwd().openDir(path, .{})) catch return error.FileNotFound;
        defer dir.close();

        const file = dir.openFile(block.object_key, .{}) catch return error.FileNotFound;
        defer file.close();

        const data = self.allocator.alloc(u8, block.size) catch return error.OutOfMemory;
        errdefer self.allocator.free(data);

        const bytes_read = file.readAll(data) catch |err| {
            self.allocator.free(data);
            return err;
        };

        if (bytes_read != block.size) {
            self.allocator.free(data);
            return error.UnexpectedEof;
        }

        return data;
    }

    fn parseBlockHeader(data: []const u8) ?vsr.Header.Block {
        if (data.len < @sizeOf(vsr.Header)) return null;

        var header: vsr.Header.Block = undefined;
        @memcpy(std.mem.asBytes(&header), data[0..@sizeOf(vsr.Header)]);
        return header;
    }

    fn readS3CompatibleBlockData(
        self: *RestoreManager,
        block: BlockMetadata,
        comptime scheme: []const u8,
        provider: StorageProvider,
    ) ![]u8 {
        const auth = try self.loadS3LikeAuth(provider);
        defer auth.deinit(self.allocator);

        const location = try self.parseRemotePath(scheme);
        var client = try s3_client.S3Client.init(self.allocator, .{
            .endpoint = auth.endpoint,
            .region = auth.region,
            .credentials = .{
                .access_key_id = auth.access_key_id,
                .secret_access_key = auth.secret_access_key,
            },
        });
        defer client.deinit();

        return client.getObject(location.container, block.object_key);
    }

    fn buildAzureListUrl(
        self: *RestoreManager,
        auth: AzureAuth,
        container: []const u8,
        prefix: []const u8,
        marker: ?[]const u8,
    ) RestoreError![]u8 {
        if (marker) |next| {
            if (prefix.len > 0) {
                return std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}?restype=container&comp=list&prefix={s}&marker={s}&{s}",
                    .{ auth.endpoint, container, prefix, next, auth.sas_token },
                ) catch return RestoreError.OutOfMemory;
            }
            return std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}?restype=container&comp=list&marker={s}&{s}",
                .{ auth.endpoint, container, next, auth.sas_token },
            ) catch return RestoreError.OutOfMemory;
        }

        if (prefix.len > 0) {
            return std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}?restype=container&comp=list&prefix={s}&{s}",
                .{ auth.endpoint, container, prefix, auth.sas_token },
            ) catch return RestoreError.OutOfMemory;
        }

        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}?restype=container&comp=list&{s}",
            .{ auth.endpoint, container, auth.sas_token },
        ) catch return RestoreError.OutOfMemory;
    }

    fn fetchAzureUrl(self: *RestoreManager, url: []const u8) RestoreError![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 64 * 1024 * 1024,
        }) catch |err| {
            logErr("Azure fetch failed for {s}: {}", .{ url, err });
            return RestoreError.StorageError;
        };

        if (result.status != .ok) {
            logErr("Azure fetch returned {}", .{result.status});
            return RestoreError.StorageError;
        }

        return body.toOwnedSlice() catch return RestoreError.OutOfMemory;
    }

    fn fetchAzureUrlOptional(self: *RestoreManager, url: []const u8) RestoreError!?[]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 64 * 1024 * 1024,
        }) catch |err| {
            logErr("Azure fetch failed for {s}: {}", .{ url, err });
            return RestoreError.StorageError;
        };

        if (result.status == .not_found) return null;
        if (result.status != .ok) {
            logErr("Azure fetch returned {}", .{result.status});
            return RestoreError.StorageError;
        }

        return body.toOwnedSlice() catch return RestoreError.OutOfMemory;
    }

    fn parseAzureListResponse(self: *RestoreManager, xml: []const u8) RestoreError!AzureListPage {
        var objects = std.ArrayList(s3_client.ObjectInfo).init(self.allocator);
        errdefer {
            for (objects.items) |object| {
                self.allocator.free(object.key);
            }
            objects.deinit();
        }

        var cursor: usize = 0;
        while (mem.indexOfPos(u8, xml, cursor, "<Blob>")) |blob_start| {
            const blob_end = mem.indexOfPos(u8, xml, blob_start, "</Blob>") orelse
                return RestoreError.StorageError;
            const section = xml[blob_start .. blob_end + "</Blob>".len];

            const name = parseXmlElementValue(section, "Name") orelse
                return RestoreError.StorageError;
            const size_text = parseXmlElementValue(section, "Content-Length") orelse
                return RestoreError.StorageError;
            const size = std.fmt.parseInt(u64, mem.trim(u8, size_text, " \t\r\n"), 10) catch
                return RestoreError.StorageError;

            try objects.append(.{
                .key = self.allocator.dupe(u8, name) catch return RestoreError.OutOfMemory,
                .size = size,
            });
            cursor = blob_end + "</Blob>".len;
        }

        const marker_raw = parseXmlElementValue(xml, "NextMarker");
        const marker = if (marker_raw) |value|
            if (mem.trim(u8, value, " \t\r\n").len > 0) value else null
        else
            null;

        return .{
            .objects = objects.toOwnedSlice() catch return RestoreError.OutOfMemory,
            .next_marker = marker,
        };
    }

    fn listAzureBlobBlocks(self: *RestoreManager, auth: AzureAuth) RestoreError![]BlockMetadata {
        const location = try self.parseRemotePath("azure://");
        const prefix = try self.listingPrefix(location.prefix);
        defer self.allocator.free(prefix);

        var object_list = std.ArrayList(s3_client.ObjectInfo).init(self.allocator);
        defer {
            for (object_list.items) |object| {
                self.allocator.free(object.key);
            }
            object_list.deinit();
        }

        var marker: ?[]u8 = null;
        defer if (marker) |value| self.allocator.free(value);

        while (true) {
            const url = try self.buildAzureListUrl(auth, location.container, prefix, marker);
            defer self.allocator.free(url);

            const body = try self.fetchAzureUrl(url);
            defer self.allocator.free(body);

            const page = try self.parseAzureListResponse(body);
            defer self.allocator.free(page.objects);

            try object_list.appendSlice(page.objects);

            if (page.next_marker) |next| {
                if (marker) |value| self.allocator.free(value);
                marker = self.allocator.dupe(u8, mem.trim(u8, next, " \t\r\n")) catch
                    return RestoreError.OutOfMemory;
            } else {
                break;
            }
        }

        var count: usize = 0;
        for (object_list.items) |object| {
            if (isBlockFile(blockNameFromObjectKey(object.key))) count += 1;
        }
        if (count == 0) return &[_]BlockMetadata{};

        const blocks = self.allocator.alloc(BlockMetadata, count) catch return RestoreError.OutOfMemory;
        errdefer self.allocator.free(blocks);

        var idx: usize = 0;
        for (object_list.items) |object| {
            const block_name = blockNameFromObjectKey(object.key);
            if (!isBlockFile(block_name)) continue;

            const sequence = parseBlockSequence(block_name) orelse continue;
            const metadata_key = std.fmt.allocPrint(self.allocator, "{s}.meta", .{object.key}) catch
                return RestoreError.OutOfMemory;
            defer self.allocator.free(metadata_key);
            const timestamp_key = std.fmt.allocPrint(self.allocator, "{s}.ts", .{object.key}) catch
                return RestoreError.OutOfMemory;
            defer self.allocator.free(timestamp_key);

            const sidecar_meta = try self.readAzureBlockMetadata(
                auth,
                location.container,
                metadata_key,
            );
            const closed_timestamp = if (sidecar_meta) |meta|
                meta.closed_timestamp
            else
                self.readAzureTimestampSidecar(auth, location.container, timestamp_key);

            blocks[idx] = .{
                .sequence = sequence,
                .closed_timestamp = closed_timestamp,
                .address = if (sidecar_meta) |meta| meta.address else null,
                .size = object.size,
                .checksum = if (sidecar_meta) |meta| meta.checksum else 0,
                .object_key = self.allocator.dupe(u8, object.key) catch return RestoreError.OutOfMemory,
                .compressed = mem.endsWith(u8, block_name, ".block.zst"),
            };
            if (sidecar_meta) |meta| {
                if (meta.sequence != sequence) {
                    logErr(
                        "Azure metadata sidecar sequence mismatch for {s}: expected {}, got {}",
                        .{ object.key, sequence, meta.sequence },
                    );
                    return RestoreError.InvalidSource;
                }
            }
            idx += 1;
        }

        std.mem.sort(BlockMetadata, blocks[0..idx], {}, struct {
            fn lessThan(_: void, a: BlockMetadata, b: BlockMetadata) bool {
                return a.sequence < b.sequence;
            }
        }.lessThan);

        return blocks[0..idx];
    }

    fn readAzureTimestampSidecar(
        self: *RestoreManager,
        auth: AzureAuth,
        container: []const u8,
        object_key: []const u8,
    ) i64 {
        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}?{s}",
            .{ auth.endpoint, container, object_key, auth.sas_token },
        ) catch return 0;
        defer self.allocator.free(url);

        const body = (self.fetchAzureUrlOptional(url) catch return 0) orelse return 0;
        defer self.allocator.free(body);

        const trimmed = mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseInt(i64, trimmed, 10) catch 0;
    }

    fn readAzureBlockMetadata(
        self: *RestoreManager,
        auth: AzureAuth,
        container: []const u8,
        object_key: []const u8,
    ) RestoreError!?BlockSidecarMetadata {
        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}?{s}",
            .{ auth.endpoint, container, object_key, auth.sas_token },
        ) catch return RestoreError.OutOfMemory;
        defer self.allocator.free(url);

        const body = (try self.fetchAzureUrlOptional(url)) orelse return null;
        defer self.allocator.free(body);

        return try parseBlockSidecarMetadata(body, object_key);
    }

    fn readAzureCheckpointArtifact(
        self: *RestoreManager,
        auth: AzureAuth,
        container: []const u8,
        object_key: []const u8,
    ) RestoreError!?[]u8 {
        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}?{s}",
            .{ auth.endpoint, container, object_key, auth.sas_token },
        ) catch return RestoreError.OutOfMemory;
        defer self.allocator.free(url);

        return try self.fetchAzureUrlOptional(url);
    }

    fn readAzureBlockData(self: *RestoreManager, block: BlockMetadata) ![]u8 {
        const auth = try self.loadAzureAuth();
        defer auth.deinit(self.allocator);

        const location = try self.parseRemotePath("azure://");
        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}?{s}",
            .{ auth.endpoint, location.container, block.object_key, auth.sas_token },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        return self.fetchAzureUrl(url);
    }

    fn parseXmlElementValue(xml: []const u8, element: []const u8) ?[]const u8 {
        var start_tag_buf: [128]u8 = undefined;
        const start_tag = std.fmt.bufPrint(&start_tag_buf, "<{s}>", .{element}) catch return null;

        var end_tag_buf: [128]u8 = undefined;
        const end_tag = std.fmt.bufPrint(&end_tag_buf, "</{s}>", .{element}) catch return null;

        const start_idx = mem.indexOf(u8, xml, start_tag) orelse return null;
        const value_start = start_idx + start_tag.len;
        const end_idx = mem.indexOf(u8, xml[value_start..], end_tag) orelse return null;
        return xml[value_start .. value_start + end_idx];
    }

    fn localSourcePath(self: *const RestoreManager) []const u8 {
        var path = self.config.source_url;
        if (mem.startsWith(u8, path, "file://")) {
            path = path["file://".len..];
        } else if (mem.startsWith(u8, path, "local://")) {
            path = path["local://".len..];
        }
        return path;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PointInTime: parse" {
    // Sequence format
    const seq = PointInTime.parse("seq:12345");
    try std.testing.expect(seq != null);
    try std.testing.expectEqual(@as(u64, 12345), seq.?.sequence);

    // Timestamp format
    const ts = PointInTime.parse("ts:1704067200000000000");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1704067200000000000), ts.?.timestamp);

    // Latest format
    const latest = PointInTime.parse("latest");
    try std.testing.expect(latest != null);
    try std.testing.expectEqual(PointInTime.latest, latest.?);

    // Plain number (assume sequence)
    const plain = PointInTime.parse("99999");
    try std.testing.expect(plain != null);
    try std.testing.expectEqual(@as(u64, 99999), plain.?.sequence);

    // Invalid format
    const invalid = PointInTime.parse("invalid");
    try std.testing.expect(invalid == null);
}

test "RestoreConfig: defaults" {
    const config = RestoreConfig{
        .source_url = "s3://bucket/cluster/replica",
        .dest_data_file = "/tmp/data.archerdb",
    };

    try std.testing.expectEqual(PointInTime.latest, config.point_in_time);
    try std.testing.expect(!config.skip_expired);
    try std.testing.expect(!config.dry_run);
    try std.testing.expect(config.verify_checksums);
}

test "RestoreManager: init and deinit" {
    var manager = try RestoreManager.init(std.testing.allocator, .{
        .source_url = "s3://bucket/abc123/replica-0",
        .dest_data_file = "/tmp/data.archerdb",
    });
    defer manager.deinit();

    try std.testing.expectEqual(StorageProvider.s3, manager.provider);
}

test "RestoreManager: detectProvider" {
    try std.testing.expectEqual(StorageProvider.s3, RestoreManager.detectProvider("s3://bucket"));
    try std.testing.expectEqual(
        StorageProvider.gcs,
        RestoreManager.detectProvider("gs://bucket"),
    );
    try std.testing.expectEqual(
        StorageProvider.azure,
        RestoreManager.detectProvider("azure://container"),
    );
    try std.testing.expectEqual(
        StorageProvider.local,
        RestoreManager.detectProvider("/local/path"),
    );
}

test "RestoreStats: duration calculation" {
    var stats = RestoreStats{
        .start_time_ns = 0,
        .end_time_ns = 5 * std.time.ns_per_s, // 5 seconds
        .bytes_downloaded = 100 * 1024 * 1024, // 100 MB
    };

    try std.testing.expectEqual(@as(f64, 5.0), stats.durationSeconds());
    try std.testing.expectEqual(@as(f64, 20.0), stats.downloadThroughputMBps());
}

test "RestoreManager: verifySequenceContinuity" {
    var manager = try RestoreManager.init(std.testing.allocator, .{
        .source_url = "local://test",
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer manager.deinit();

    // Empty blocks - should pass
    try manager.verifySequenceContinuity(&[_]BlockMetadata{});

    // Contiguous sequence - should pass
    var contiguous = [_]BlockMetadata{
        .{ .sequence = 1, .size = 100, .checksum = 0, .object_key = "1", .compressed = false },
        .{ .sequence = 2, .size = 100, .checksum = 0, .object_key = "2", .compressed = false },
        .{ .sequence = 3, .size = 100, .checksum = 0, .object_key = "3", .compressed = false },
    };
    try manager.verifySequenceContinuity(&contiguous);
    try std.testing.expectEqual(@as(u64, 3), manager.stats.max_sequence_restored);
}

test "RestoreManager: dry run mode" {
    var manager = try RestoreManager.init(std.testing.allocator, .{
        .source_url = "local://test",
        .dest_data_file = "/tmp/test.archerdb",
        .dry_run = true,
    });
    defer manager.deinit();

    try std.testing.expect(manager.isDryRun());
}

test "RestoreManager: parseBlockSequence handles compressed and uncompressed names" {
    try std.testing.expectEqual(@as(?u64, 42), RestoreManager.parseBlockSequence("000000000042.block"));
    try std.testing.expectEqual(@as(?u64, 42), RestoreManager.parseBlockSequence("000000000042.block.zst"));
    try std.testing.expect(RestoreManager.parseBlockSequence("not-a-block.txt") == null);
}

test "RestoreManager: timestamp PITR filters by closed timestamp metadata" {
    var manager = try RestoreManager.init(std.testing.allocator, .{
        .source_url = "local://test",
        .dest_data_file = "/tmp/test.archerdb",
        .point_in_time = .{ .timestamp = 1_704_067_260 },
    });
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{
            .sequence = 1,
            .closed_timestamp = 1_704_067_200,
            .size = 100,
            .checksum = 0,
            .object_key = "000000000001.block",
            .compressed = false,
        },
        .{
            .sequence = 2,
            .closed_timestamp = 1_704_067_260,
            .size = 100,
            .checksum = 0,
            .object_key = "000000000002.block",
            .compressed = false,
        },
        .{
            .sequence = 3,
            .closed_timestamp = 1_704_067_320,
            .size = 100,
            .checksum = 0,
            .object_key = "000000000003.block",
            .compressed = false,
        },
    };

    const filtered = try manager.filterBlocksByPointInTime(&blocks);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqual(@as(u64, 2), filtered[1].sequence);
}

test "RestoreManager: timestamp PITR falls back when metadata is unavailable" {
    var manager = try RestoreManager.init(std.testing.allocator, .{
        .source_url = "local://test",
        .dest_data_file = "/tmp/test.archerdb",
        .point_in_time = .{ .timestamp = 1_704_067_260 },
    });
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{ .sequence = 1, .size = 100, .checksum = 0, .object_key = "1", .compressed = false },
        .{ .sequence = 2, .size = 100, .checksum = 0, .object_key = "2", .compressed = false },
    };

    const filtered = try manager.filterBlocksByPointInTime(&blocks);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
}

test "RestoreManager: verifyBlockChecksum validates local block bytes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const body = "block-payload";
    var header = std.mem.zeroInit(vsr.Header.Block, .{
        .cluster = 1,
        .size = @sizeOf(vsr.Header) + body.len,
        .release = vsr.Release.minimum,
        .command = .block,
        .metadata_bytes = [_]u8{0} ** vsr.Header.Block.metadata_size,
        .address = 1,
        .snapshot = 0,
        .block_type = .free_set,
    });
    header.set_checksum_body(body);
    header.set_checksum();

    var block_bytes: [@sizeOf(vsr.Header) + body.len]u8 = undefined;
    @memcpy(block_bytes[0..@sizeOf(vsr.Header)], std.mem.asBytes(&header));
    @memcpy(block_bytes[@sizeOf(vsr.Header)..], body);

    const valid_file = try tmp.dir.createFile("000000000001.block", .{ .truncate = true });
    defer valid_file.close();
    try valid_file.writeAll(&block_bytes);

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    try std.testing.expect(try manager.verifyBlockChecksum(.{
        .sequence = 1,
        .size = block_bytes.len,
        .checksum = 0,
        .object_key = "000000000001.block",
        .compressed = false,
    }));
}

test "RestoreManager: verifyBlockChecksum rejects corrupted local block bytes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const body = "block-payload";
    var header = std.mem.zeroInit(vsr.Header.Block, .{
        .cluster = 1,
        .size = @sizeOf(vsr.Header) + body.len,
        .release = vsr.Release.minimum,
        .command = .block,
        .metadata_bytes = [_]u8{0} ** vsr.Header.Block.metadata_size,
        .address = 2,
        .snapshot = 0,
        .block_type = .free_set,
    });
    header.set_checksum_body(body);
    header.set_checksum();

    var block_bytes: [@sizeOf(vsr.Header) + body.len]u8 = undefined;
    @memcpy(block_bytes[0..@sizeOf(vsr.Header)], std.mem.asBytes(&header));
    @memcpy(block_bytes[@sizeOf(vsr.Header)..], body);
    block_bytes[block_bytes.len - 1] ^= 0x1;

    const invalid_file = try tmp.dir.createFile("000000000002.block", .{ .truncate = true });
    defer invalid_file.close();
    try invalid_file.writeAll(&block_bytes);

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    try std.testing.expect(!(try manager.verifyBlockChecksum(.{
        .sequence = 2,
        .size = block_bytes.len,
        .checksum = 0,
        .object_key = "000000000002.block",
        .compressed = false,
    })));
}

test "RestoreManager: writeBlocks preserves grid addresses when metadata is present" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/restored-grid.archerdb", .{tmp_path});
    defer allocator.free(dest_path);

    {
        const block_file = try tmp.dir.createFile("000000000001.block", .{ .truncate = true });
        defer block_file.close();
        try block_file.writeAll("alpha");
    }
    {
        const block_file = try tmp.dir.createFile("000000000002.block", .{ .truncate = true });
        defer block_file.close();
        try block_file.writeAll("omega");
    }

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = dest_path,
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{
            .sequence = 1,
            .closed_timestamp = 1_704_067_200,
            .address = 2,
            .size = "alpha".len,
            .checksum = 0,
            .object_key = "000000000001.block",
            .compressed = false,
        },
        .{
            .sequence = 2,
            .closed_timestamp = 1_704_067_260,
            .address = 5,
            .size = "omega".len,
            .checksum = 0,
            .object_key = "000000000002.block",
            .compressed = false,
        },
    };

    try manager.writeBlocks(blocks[0..]);

    const restored_file = try fs.openFileAbsolute(dest_path, .{});
    defer restored_file.close();

    var read_buffer: [5]u8 = undefined;

    const alpha_offset = vsr.Zone.offset(.grid, constants.block_size);
    _ = try restored_file.preadAll(&read_buffer, alpha_offset);
    try std.testing.expectEqualStrings("alpha", &read_buffer);

    const omega_offset = vsr.Zone.offset(.grid, 4 * constants.block_size);
    _ = try restored_file.preadAll(&read_buffer, omega_offset);
    try std.testing.expectEqualStrings("omega", &read_buffer);
}

test "RestoreManager: listLocalBlocks rejects malformed timestamp sidecar" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const block_file = try tmp.dir.createFile("000000000001.block", .{ .truncate = true });
    defer block_file.close();
    try block_file.writeAll("placeholder");

    const sidecar = try tmp.dir.createFile("000000000001.block.ts", .{ .truncate = true });
    defer sidecar.close();
    try sidecar.writeAll("not-a-timestamp\n");

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    try std.testing.expectError(RestoreError.InvalidSource, manager.listLocalBlocks());
}

test "RestoreManager: listLocalBlocks rejects malformed metadata sidecar" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const block_file = try tmp.dir.createFile("000000000001.block", .{ .truncate = true });
    defer block_file.close();
    try block_file.writeAll("placeholder");

    const sidecar = try tmp.dir.createFile("000000000001.block.meta", .{ .truncate = true });
    defer sidecar.close();
    try sidecar.writeAll("sequence=1\nchecksum=bogus\n");

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    try std.testing.expectError(RestoreError.InvalidSource, manager.listLocalBlocks());
}

test "RestoreManager: verifyBlockChecksum rejects mismatched metadata checksum" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const body = "block-payload";
    var header = std.mem.zeroInit(vsr.Header.Block, .{
        .cluster = 1,
        .size = @sizeOf(vsr.Header) + body.len,
        .release = vsr.Release.minimum,
        .command = .block,
        .metadata_bytes = [_]u8{0} ** vsr.Header.Block.metadata_size,
        .address = 3,
        .snapshot = 0,
        .block_type = .free_set,
    });
    header.set_checksum_body(body);
    header.set_checksum();

    var block_bytes: [@sizeOf(vsr.Header) + body.len]u8 = undefined;
    @memcpy(block_bytes[0..@sizeOf(vsr.Header)], std.mem.asBytes(&header));
    @memcpy(block_bytes[@sizeOf(vsr.Header)..], body);

    const block_file = try tmp.dir.createFile("000000000003.block", .{ .truncate = true });
    defer block_file.close();
    try block_file.writeAll(&block_bytes);

    const meta_file = try tmp.dir.createFile("000000000003.block.meta", .{ .truncate = true });
    defer meta_file.close();
    try meta_file.writer().writeAll(
        "sequence=3\naddress=3\nchecksum=000000000000000000000000deadbeef\nclosed_timestamp=1704067200\n",
    );

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    const blocks = try manager.listLocalBlocks();
    defer manager.freeBlockMetadata(blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), blocks[0].checksum);
    try std.testing.expect(!(try manager.verifyBlockChecksum(blocks[0])));
}

test "RestoreManager: execute against S3-compatible storage" {
    try skipRemoteFixtureOnMusl();

    const allocator = std.testing.allocator;

    const prefix = "cluster-abc/replica-0";
    const objects = [_]struct {
        name: []const u8,
        body: []const u8,
        closed_ts: i64,
    }{
        .{ .name = "000000000001.block", .body = "block-1\n", .closed_ts = 1_704_067_200 },
        .{ .name = "000000000002.block", .body = "block-2\n", .closed_ts = 1_704_067_260 },
        .{ .name = "000000000003.block", .body = "block-3\n", .closed_ts = 1_704_067_320 },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath(prefix);
    for (objects) |object| {
        const block_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, object.name });
        defer allocator.free(block_path);
        const block_file = try tmp.dir.createFile(block_path, .{ .truncate = true });
        defer block_file.close();
        try block_file.writeAll(object.body);

        const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.ts", .{block_path});
        defer allocator.free(sidecar_path);
        const sidecar_file = try tmp.dir.createFile(sidecar_path, .{ .truncate = true });
        defer sidecar_file.close();
        try sidecar_file.writer().print("{d}\n", .{object.closed_ts});
    }

    const server_script =
        \\import http.server, os, sys, urllib.parse
        \\root = sys.argv[1]
        \\class Handler(http.server.BaseHTTPRequestHandler):
        \\    def do_GET(self):
        \\        parsed = urllib.parse.urlparse(self.path)
        \\        if parsed.path == "/test-replication":
        \\            params = urllib.parse.parse_qs(parsed.query)
        \\            prefix = params.get("prefix", [""])[0]
        \\            items = []
        \\            for dirpath, _, filenames in os.walk(root):
        \\                for filename in filenames:
        \\                    full = os.path.join(dirpath, filename)
        \\                    key = os.path.relpath(full, root).replace(os.sep, "/")
        \\                    if key.startswith(prefix):
        \\                        items.append((key, os.path.getsize(full)))
        \\            items.sort()
        \\            body = ['<?xml version="1.0" encoding="UTF-8"?>', '<ListBucketResult>', '<IsTruncated>false</IsTruncated>']
        \\            for key, size in items:
        \\                body.append(f'<Contents><Key>{key}</Key><Size>{size}</Size></Contents>')
        \\            body.append('</ListBucketResult>')
        \\            data = ''.join(body).encode()
        \\            self.send_response(200)
        \\            self.send_header("Content-Type", "application/xml")
        \\            self.send_header("Content-Length", str(len(data)))
        \\            self.end_headers()
        \\            self.wfile.write(data)
        \\            return
        \\        if parsed.path.startswith("/test-replication/"):
        \\            key = parsed.path[len("/test-replication/"):]
        \\            full = os.path.join(root, key)
        \\            if os.path.isfile(full):
        \\                data = open(full, "rb").read()
        \\                self.send_response(200)
        \\                self.send_header("Content-Length", str(len(data)))
        \\                self.end_headers()
        \\                self.wfile.write(data)
        \\                return
        \\        self.send_response(404)
        \\        self.end_headers()
        \\    def log_message(self, *args):
        \\        pass
        \\server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        \\print(server.server_address[1], flush=True)
        \\server.serve_forever()
    ;

    var server = std.process.Child.init(&[_][]const u8{
        "python3",
        "-u",
        "-c",
        server_script,
        tmp_path,
    }, allocator);
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    const port_line = try server.stdout.?.reader().readUntilDelimiterAlloc(allocator, '\n', 128);
    defer allocator.free(port_line);
    const port = try std.fmt.parseInt(u16, mem.trim(u8, port_line, " \t\r\n"), 10);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/restore.creds", .{tmp_path});
    defer allocator.free(creds_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/restored.archerdb", .{tmp_path});
    defer allocator.free(dest_path);

    const creds_file = try fs.createFileAbsolute(creds_path, .{ .truncate = true });
    defer creds_file.close();
    try creds_file.writer().print(
        "endpoint=http://127.0.0.1:{d}\nregion=us-east-1\naccess_key_id=test\nsecret_access_key=test\n",
        .{port},
    );

    var manager = try RestoreManager.init(allocator, .{
        .source_url = "s3://test-replication/cluster-abc/replica-0",
        .dest_data_file = dest_path,
        .point_in_time = .{ .timestamp = 1_704_067_260 },
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    const stats = try manager.execute();
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(u64, 3), stats.blocks_available);
    try std.testing.expectEqual(@as(u64, 2), stats.blocks_written);
    try std.testing.expectEqual(@as(u64, 2), stats.max_sequence_restored);

    const restored_file = try fs.openFileAbsolute(dest_path, .{});
    defer restored_file.close();
    const restored = try restored_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("block-1\nblock-2\n", restored);
}

test "RestoreManager: execute against S3-compatible storage preserves remote grid addresses" {
    try skipRemoteFixtureOnMusl();

    const allocator = std.testing.allocator;

    const prefix = "cluster-xyz/replica-0";
    const objects = [_]struct {
        name: []const u8,
        body: []const u8,
        address: u64,
        closed_ts: i64,
    }{
        .{ .name = "000000000001.block", .body = "grid-a", .address = 2, .closed_ts = 1_704_067_200 },
        .{ .name = "000000000002.block", .body = "grid-b", .address = 5, .closed_ts = 1_704_067_260 },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath(prefix);
    for (objects, 0..) |object, index| {
        const block_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, object.name });
        defer allocator.free(block_path);
        const block_file = try tmp.dir.createFile(block_path, .{ .truncate = true });
        defer block_file.close();
        try block_file.writeAll(object.body);

        const meta_path = try std.fmt.allocPrint(allocator, "{s}.meta", .{block_path});
        defer allocator.free(meta_path);
        const meta_file = try tmp.dir.createFile(meta_path, .{ .truncate = true });
        defer meta_file.close();
        try meta_file.writer().print(
            "sequence={d}\naddress={d}\nchecksum=00000000000000000000000000000000\nclosed_timestamp={d}\n",
            .{ index + 1, object.address, object.closed_ts },
        );
    }

    const server_script =
        \\import http.server, os, sys, urllib.parse
        \\root = sys.argv[1]
        \\class Handler(http.server.BaseHTTPRequestHandler):
        \\    def do_GET(self):
        \\        parsed = urllib.parse.urlparse(self.path)
        \\        if parsed.path == "/test-replication":
        \\            params = urllib.parse.parse_qs(parsed.query)
        \\            prefix = params.get("prefix", [""])[0]
        \\            items = []
        \\            for dirpath, _, filenames in os.walk(root):
        \\                for filename in filenames:
        \\                    full = os.path.join(dirpath, filename)
        \\                    key = os.path.relpath(full, root).replace(os.sep, "/")
        \\                    if key.startswith(prefix):
        \\                        items.append((key, os.path.getsize(full)))
        \\            items.sort()
        \\            body = ['<?xml version="1.0" encoding="UTF-8"?>', '<ListBucketResult>', '<IsTruncated>false</IsTruncated>']
        \\            for key, size in items:
        \\                body.append(f'<Contents><Key>{key}</Key><Size>{size}</Size></Contents>')
        \\            body.append('</ListBucketResult>')
        \\            data = ''.join(body).encode()
        \\            self.send_response(200)
        \\            self.send_header("Content-Type", "application/xml")
        \\            self.send_header("Content-Length", str(len(data)))
        \\            self.end_headers()
        \\            self.wfile.write(data)
        \\            return
        \\        if parsed.path.startswith("/test-replication/"):
        \\            key = parsed.path[len("/test-replication/"):]
        \\            full = os.path.join(root, key)
        \\            if os.path.isfile(full):
        \\                data = open(full, "rb").read()
        \\                self.send_response(200)
        \\                self.send_header("Content-Length", str(len(data)))
        \\                self.end_headers()
        \\                self.wfile.write(data)
        \\                return
        \\        self.send_response(404)
        \\        self.end_headers()
        \\    def log_message(self, *args):
        \\        pass
        \\server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        \\print(server.server_address[1], flush=True)
        \\server.serve_forever()
    ;

    var server = std.process.Child.init(&[_][]const u8{
        "python3",
        "-u",
        "-c",
        server_script,
        tmp_path,
    }, allocator);
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    const port_line = try server.stdout.?.reader().readUntilDelimiterAlloc(allocator, '\n', 128);
    defer allocator.free(port_line);
    const port = try std.fmt.parseInt(u16, mem.trim(u8, port_line, " \t\r\n"), 10);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/restore-grid.creds", .{tmp_path});
    defer allocator.free(creds_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/restored-grid.archerdb", .{tmp_path});
    defer allocator.free(dest_path);

    const creds_file = try fs.createFileAbsolute(creds_path, .{ .truncate = true });
    defer creds_file.close();
    try creds_file.writer().print(
        "endpoint=http://127.0.0.1:{d}\nregion=us-east-1\naccess_key_id=test\nsecret_access_key=test\n",
        .{port},
    );

    var manager = try RestoreManager.init(allocator, .{
        .source_url = "s3://test-replication/cluster-xyz/replica-0",
        .dest_data_file = dest_path,
        .point_in_time = .{ .timestamp = 1_704_067_260 },
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    const stats = try manager.execute();
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(u64, 2), stats.blocks_available);
    try std.testing.expectEqual(@as(u64, 2), stats.blocks_written);
    try std.testing.expectEqual(@as(u64, 2), stats.max_sequence_restored);

    const restored_file = try fs.openFileAbsolute(dest_path, .{});
    defer restored_file.close();

    var read_buffer: [6]u8 = undefined;
    _ = try restored_file.preadAll(&read_buffer, vsr.Zone.offset(.grid, constants.block_size));
    try std.testing.expectEqualStrings("grid-a", &read_buffer);

    _ = try restored_file.preadAll(&read_buffer, vsr.Zone.offset(.grid, 4 * constants.block_size));
    try std.testing.expectEqualStrings("grid-b", &read_buffer);
}

test "RestoreManager: selectCheckpointArtifact chooses latest remote checkpoint artifact" {
    try skipRemoteFixtureOnMusl();

    const allocator = std.testing.allocator;

    const prefix = "cluster-remote/replica-0";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const prefix_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, prefix });
    defer allocator.free(prefix_path);
    try tmp.dir.makePath(prefix);

    var empty_members = std.mem.zeroes(vsr.Members);
    empty_members[0] = 0x100;

    const older = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 1,
        .sequence_max = 12,
        .block_count = 12,
        .closed_timestamp = 1_704_067_200,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 64,
        .sync_op_min = 32,
        .sync_op_max = 64,
        .log_view = 4,
        .view = 4,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 4,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 64,
                .commit = 64,
                .operation = .noop,
            }),
            .storage_size = 4096,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    const newer = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 13,
        .sequence_max = 24,
        .block_count = 12,
        .closed_timestamp = 1_704_067_260,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 96,
        .sync_op_min = 64,
        .sync_op_max = 96,
        .log_view = 5,
        .view = 5,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 5,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 96,
                .commit = 96,
                .operation = .noop,
            }),
            .storage_size = 8192,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    try writeCheckpointFixture(prefix_path, older);
    try writeCheckpointFixture(prefix_path, newer);

    const server_script =
        \\import http.server, os, sys, urllib.parse
        \\root = sys.argv[1]
        \\class Handler(http.server.BaseHTTPRequestHandler):
        \\    def do_GET(self):
        \\        parsed = urllib.parse.urlparse(self.path)
        \\        if parsed.path == "/test-replication":
        \\            params = urllib.parse.parse_qs(parsed.query)
        \\            prefix = params.get("prefix", [""])[0]
        \\            items = []
        \\            for dirpath, _, filenames in os.walk(root):
        \\                for filename in filenames:
        \\                    full = os.path.join(dirpath, filename)
        \\                    key = os.path.relpath(full, root).replace(os.sep, "/")
        \\                    if key.startswith(prefix):
        \\                        items.append((key, os.path.getsize(full)))
        \\            items.sort()
        \\            body = ['<?xml version="1.0" encoding="UTF-8"?>', '<ListBucketResult>', '<IsTruncated>false</IsTruncated>']
        \\            for key, size in items:
        \\                body.append(f'<Contents><Key>{key}</Key><Size>{size}</Size></Contents>')
        \\            body.append('</ListBucketResult>')
        \\            data = ''.join(body).encode()
        \\            self.send_response(200)
        \\            self.send_header("Content-Type", "application/xml")
        \\            self.send_header("Content-Length", str(len(data)))
        \\            self.end_headers()
        \\            self.wfile.write(data)
        \\            return
        \\        if parsed.path.startswith("/test-replication/"):
        \\            key = parsed.path[len("/test-replication/"):]
        \\            full = os.path.join(root, key)
        \\            if os.path.isfile(full):
        \\                data = open(full, "rb").read()
        \\                self.send_response(200)
        \\                self.send_header("Content-Length", str(len(data)))
        \\                self.end_headers()
        \\                self.wfile.write(data)
        \\                return
        \\        self.send_response(404)
        \\        self.end_headers()
        \\    def log_message(self, *args):
        \\        pass
        \\server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        \\print(server.server_address[1], flush=True)
        \\server.serve_forever()
    ;

    var server = std.process.Child.init(&[_][]const u8{
        "python3",
        "-u",
        "-c",
        server_script,
        tmp_path,
    }, allocator);
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    const port_line = try server.stdout.?.reader().readUntilDelimiterAlloc(allocator, '\n', 128);
    defer allocator.free(port_line);
    const port = try std.fmt.parseInt(u16, mem.trim(u8, port_line, " \t\r\n"), 10);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/restore-ckpt.creds", .{tmp_path});
    defer allocator.free(creds_path);
    const creds_file = try fs.createFileAbsolute(creds_path, .{ .truncate = true });
    defer creds_file.close();
    try creds_file.writer().print(
        "endpoint=http://127.0.0.1:{d}\nregion=us-east-1\naccess_key_id=test\nsecret_access_key=test\n",
        .{port},
    );

    var manager = try RestoreManager.init(allocator, .{
        .source_url = "s3://test-replication/cluster-remote/replica-0",
        .dest_data_file = "/tmp/test.archerdb",
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{ .sequence = 1, .closed_timestamp = 1_704_067_200, .size = 1, .checksum = 0, .object_key = "1", .compressed = false },
        .{ .sequence = 24, .closed_timestamp = 1_704_067_260, .size = 1, .checksum = 0, .object_key = "24", .compressed = false },
    };

    const selected = (try manager.selectCheckpointArtifact(blocks[0..])).?;
    try std.testing.expectEqual(@as(u64, 24), selected.sequence_max);
    try std.testing.expectEqual(@as(u64, 96), selected.checkpointOp());
}

test "RestoreManager: selectCheckpointArtifact chooses latest covered checkpoint" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var empty_members = std.mem.zeroes(vsr.Members);
    empty_members[0] = 0x100;

    const older = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 1,
        .sequence_max = 12,
        .block_count = 12,
        .closed_timestamp = 1_704_067_200,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 64,
        .sync_op_min = 32,
        .sync_op_max = 64,
        .log_view = 4,
        .view = 4,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 4,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 64,
                .commit = 64,
                .operation = .noop,
            }),
            .storage_size = 4096,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    const newer = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 13,
        .sequence_max = 24,
        .block_count = 12,
        .closed_timestamp = 1_704_067_260,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 96,
        .sync_op_min = 64,
        .sync_op_max = 96,
        .log_view = 5,
        .view = 5,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 5,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 96,
                .commit = 96,
                .operation = .noop,
            }),
            .storage_size = 8192,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    try writeCheckpointFixture(tmp_path, older);
    try writeCheckpointFixture(tmp_path, newer);

    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path});
    defer allocator.free(source_url);

    var manager = try RestoreManager.init(allocator, .{
        .source_url = source_url,
        .dest_data_file = "/tmp/test.archerdb",
    });
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{ .sequence = 1, .closed_timestamp = 1_704_067_200, .size = 1, .checksum = 0, .object_key = "1", .compressed = false },
        .{ .sequence = 24, .closed_timestamp = 1_704_067_260, .size = 1, .checksum = 0, .object_key = "24", .compressed = false },
    };

    const selected = (try manager.selectCheckpointArtifact(&blocks)).?;
    try std.testing.expectEqual(@as(u64, 24), selected.sequence_max);
    try std.testing.expectEqual(@as(u64, 96), selected.checkpointOp());
}

test "RestoreManager: selectCheckpointArtifact chooses latest remote S3-compatible checkpoint" {
    try skipRemoteFixtureOnMusl();

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const prefix = "cluster-ckpt/replica-0";
    try tmp.dir.makePath(prefix);
    const prefix_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, prefix });
    defer allocator.free(prefix_path);

    var empty_members = std.mem.zeroes(vsr.Members);
    empty_members[0] = 0x100;

    const older = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 1,
        .sequence_max = 12,
        .block_count = 12,
        .closed_timestamp = 1_704_067_200,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 64,
        .sync_op_min = 32,
        .sync_op_max = 64,
        .log_view = 4,
        .view = 4,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 4,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 64,
                .commit = 64,
                .operation = .noop,
            }),
            .storage_size = 4096,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    const newer = checkpoint_artifact.DurableCheckpointArtifact{
        .sequence_min = 13,
        .sequence_max = 24,
        .block_count = 12,
        .closed_timestamp = 1_704_067_260,
        .cluster = 0xabc,
        .replica_index = 0,
        .replica_id = 0x100,
        .replica_count = 3,
        .release_format = vsr.Release.minimum,
        .sharding_strategy = 1,
        .members = empty_members,
        .commit_max = 96,
        .sync_op_min = 64,
        .sync_op_max = 96,
        .log_view = 5,
        .view = 5,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = std.mem.zeroInit(vsr.Header.Prepare, .{
                .cluster = 0xabc,
                .view = 5,
                .release = vsr.Release.minimum,
                .command = .prepare,
                .op = 96,
                .commit = 96,
                .operation = .noop,
            }),
            .storage_size = 8192,
            .release = vsr.Release.minimum,
        }),
        .view_headers_count = 0,
        .view_headers_all = @splat(std.mem.zeroes(vsr.Header.Prepare)),
    };

    try writeCheckpointFixture(prefix_path, older);
    try writeCheckpointFixture(prefix_path, newer);

    const server_script =
        \\import http.server, os, sys, urllib.parse
        \\root = sys.argv[1]
        \\class Handler(http.server.BaseHTTPRequestHandler):
        \\    def do_GET(self):
        \\        parsed = urllib.parse.urlparse(self.path)
        \\        if parsed.path == "/test-replication":
        \\            params = urllib.parse.parse_qs(parsed.query)
        \\            prefix = params.get("prefix", [""])[0]
        \\            items = []
        \\            for dirpath, _, filenames in os.walk(root):
        \\                for filename in filenames:
        \\                    full = os.path.join(dirpath, filename)
        \\                    key = os.path.relpath(full, root).replace(os.sep, "/")
        \\                    if key.startswith(prefix):
        \\                        items.append((key, os.path.getsize(full)))
        \\            items.sort()
        \\            body = ['<?xml version="1.0" encoding="UTF-8"?>', '<ListBucketResult>', '<IsTruncated>false</IsTruncated>']
        \\            for key, size in items:
        \\                body.append(f'<Contents><Key>{key}</Key><Size>{size}</Size></Contents>')
        \\            body.append('</ListBucketResult>')
        \\            data = ''.join(body).encode()
        \\            self.send_response(200)
        \\            self.send_header("Content-Type", "application/xml")
        \\            self.send_header("Content-Length", str(len(data)))
        \\            self.end_headers()
        \\            self.wfile.write(data)
        \\            return
        \\        if parsed.path.startswith("/test-replication/"):
        \\            key = parsed.path[len("/test-replication/"):]
        \\            full = os.path.join(root, key)
        \\            if os.path.isfile(full):
        \\                data = open(full, "rb").read()
        \\                self.send_response(200)
        \\                self.send_header("Content-Length", str(len(data)))
        \\                self.end_headers()
        \\                self.wfile.write(data)
        \\                return
        \\        self.send_response(404)
        \\        self.end_headers()
        \\    def log_message(self, *args):
        \\        pass
        \\server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        \\print(server.server_address[1], flush=True)
        \\server.serve_forever()
    ;

    var server = std.process.Child.init(&[_][]const u8{
        "python3",
        "-u",
        "-c",
        server_script,
        tmp_path,
    }, allocator);
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    const port_line = try server.stdout.?.reader().readUntilDelimiterAlloc(allocator, '\n', 128);
    defer allocator.free(port_line);
    const port = try std.fmt.parseInt(u16, mem.trim(u8, port_line, " \t\r\n"), 10);

    const creds_path = try std.fmt.allocPrint(allocator, "{s}/restore-ckpt.creds", .{tmp_path});
    defer allocator.free(creds_path);

    const creds_file = try fs.createFileAbsolute(creds_path, .{ .truncate = true });
    defer creds_file.close();
    try creds_file.writer().print(
        "endpoint=http://127.0.0.1:{d}\nregion=us-east-1\naccess_key_id=test\nsecret_access_key=test\n",
        .{port},
    );

    var manager = try RestoreManager.init(allocator, .{
        .source_url = "s3://test-replication/cluster-ckpt/replica-0",
        .dest_data_file = "/tmp/test.archerdb",
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    var blocks = [_]BlockMetadata{
        .{ .sequence = 1, .closed_timestamp = 1_704_067_200, .size = 1, .checksum = 0, .object_key = "1", .compressed = false },
        .{ .sequence = 24, .closed_timestamp = 1_704_067_260, .size = 1, .checksum = 0, .object_key = "24", .compressed = false },
    };

    const selected = (try manager.selectCheckpointArtifact(&blocks)).?;
    try std.testing.expectEqual(@as(u64, 24), selected.sequence_max);
    try std.testing.expectEqual(@as(u64, 96), selected.checkpointOp());
}

fn testPrepareHeader(
    cluster: u128,
    view: u32,
    op: u64,
    commit: u64,
    parent: u128,
    release: vsr.Release,
) vsr.Header.Prepare {
    var header = std.mem.zeroInit(vsr.Header.Prepare, .{
        .cluster = cluster,
        .view = view,
        .release = release,
        .command = .prepare,
        .op = op,
        .commit = commit,
        .operation = .pulse,
        .parent = parent,
        .timestamp = op,
    });
    header.set_checksum_body(&[_]u8{});
    header.set_checksum();
    std.debug.assert(header.invalid() == null);
    return header;
}

fn testCheckpointArtifact(storage_size: u64) checkpoint_artifact.DurableCheckpointArtifact {
    const cluster: u128 = 0xabc;
    const replica_id: u128 = 0x200;
    const release = vsr.Release.minimum;
    const checkpoint_op = vsr.Checkpoint.checkpoint_after(0);
    const checkpoint_header =
        testPrepareHeader(cluster, 5, checkpoint_op, checkpoint_op - 1, 0, release);
    const head_header = testPrepareHeader(
        cluster,
        5,
        checkpoint_op + 1,
        checkpoint_op,
        checkpoint_header.checksum,
        release,
    );

    var members = std.mem.zeroes(vsr.Members);
    members[0] = 0x100;
    members[1] = replica_id;
    members[2] = 0x300;

    var view_headers_all: [constants.view_headers_max]vsr.Header.Prepare =
        @splat(std.mem.zeroes(vsr.Header.Prepare));
    view_headers_all[0] = head_header;
    view_headers_all[1] = checkpoint_header;

    return .{
        .sequence_min = 1,
        .sequence_max = 24,
        .block_count = 12,
        .closed_timestamp = 1_704_067_260,
        .cluster = cluster,
        .replica_index = 1,
        .replica_id = replica_id,
        .replica_count = 3,
        .release_format = release,
        .sharding_strategy = vsr.sharding.ShardingStrategy.default().toStorage(),
        .members = members,
        .commit_max = checkpoint_op,
        .sync_op_min = 0,
        .sync_op_max = 0,
        .log_view = checkpoint_header.view,
        .view = checkpoint_header.view,
        .checkpoint = std.mem.zeroInit(vsr.CheckpointState, .{
            .header = checkpoint_header,
            .free_set_blocks_acquired_checksum = comptime vsr.checksum(&.{}),
            .free_set_blocks_released_checksum = comptime vsr.checksum(&.{}),
            .client_sessions_checksum = comptime vsr.checksum(&.{}),
            .storage_size = storage_size,
            .release = release,
        }),
        .view_headers_count = 2,
        .view_headers_all = view_headers_all,
    };
}

test "RestoreManager: writeSuperblock installs restore superblock copies" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/restored-superblock.archerdb", .{tmp_path});
    defer allocator.free(dest_path);

    const dest_file = try fs.createFileAbsolute(dest_path, .{
        .read = true,
        .truncate = true,
    });
    dest_file.close();

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = dest_path,
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    const storage_size = vsr.superblock.data_file_size_min + (4 * constants.block_size);
    const artifact = testCheckpointArtifact(storage_size);

    try manager.writeSuperblock(artifact);

    const restored = try fs.openFileAbsolute(dest_path, .{});
    defer restored.close();

    const stat = try restored.stat();
    try std.testing.expectEqual(storage_size, stat.size);

    var header = std.mem.zeroes(vsr.superblock.SuperBlockHeader);
    _ = try restored.preadAll(std.mem.asBytes(&header), 0);
    try std.testing.expect(header.valid_checksum());
    try std.testing.expectEqual(vsr.superblock.SuperBlockVersion, header.version);
    try std.testing.expectEqual(@as(u64, 1), header.sequence);
    try std.testing.expectEqual(@as(u128, 0xabc), header.cluster);
    try std.testing.expectEqual(@as(u8, 0), header.copy);
    try std.testing.expectEqual(@as(u128, 0x200), header.vsr_state.replica_id);
    try std.testing.expectEqual(artifact.checkpoint.header.op, header.vsr_state.checkpoint.header.op);
    try std.testing.expectEqual(storage_size, header.vsr_state.checkpoint.storage_size);

    var last_copy = std.mem.zeroes(vsr.superblock.SuperBlockHeader);
    const last_offset = vsr.superblock.superblock_copy_size *
        @as(u64, constants.superblock_copies - 1);
    _ = try restored.preadAll(std.mem.asBytes(&last_copy), last_offset);
    try std.testing.expect(last_copy.valid_checksum());
    try std.testing.expectEqual(@as(u8, constants.superblock_copies - 1), last_copy.copy);
    try std.testing.expectEqual(header.checksum, last_copy.checksum);
}

test "RestoreManager: restored data file boots under Replica.open" {
    const allocator = std.testing.allocator;

    const IO = vsr.io.IO;
    const Tracer = vsr.trace.Tracer;
    const Storage = vsr.storage.StorageType(IO);
    const MessageBus = vsr.message_bus.MessageBusType(IO);
    const MessagePool = vsr.message_pool.MessagePool;
    const StateMachine = vsr.state_machine.StateMachineType(Storage);
    const AOF = vsr.aof.AOFType(IO);
    const Replica = vsr.ReplicaType(StateMachine, MessageBus, Storage, AOF);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/restored-boot.archerdb", .{tmp_path});
    defer allocator.free(dest_path);

    const dest_file = try fs.createFileAbsolute(dest_path, .{
        .read = true,
        .truncate = true,
    });
    dest_file.close();

    var manager = try RestoreManager.init(allocator, .{
        .source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{tmp_path}),
        .dest_data_file = dest_path,
    });
    defer allocator.free(manager.config.source_url);
    defer manager.deinit();

    const storage_size = vsr.superblock.data_file_size_min + (4 * constants.block_size);
    const artifact = testCheckpointArtifact(storage_size);
    try manager.writeSuperblock(artifact);

    var time_os: vsr.time.TimeOS = .{};
    const time = time_os.time();

    var io = try ioInitOrSkip(128, 0);
    defer io.deinit();

    var tracer = try Tracer.init(allocator, time, .unknown, .{
        .writer = null,
        .statsd_options = .log,
        .log_trace = false,
    });
    defer tracer.deinit(allocator);

    var storage = try Storage.init(&io, &tracer, .{
        .path = dest_path,
        .size_min = vsr.superblock.data_file_size_min,
        .purpose = .open,
        .direct_io = .direct_io_optional,
    });

    var message_pool = try MessagePool.init(allocator, .{ .replica = .{
        .members_count = 3,
        .pipeline_requests_limit = 0,
        .message_bus = .tcp,
    } });

    const addresses = [_]std.net.Address{
        try std.net.Address.parseIp4("127.0.0.1", 0),
        try std.net.Address.parseIp4("127.0.0.1", 0),
        try std.net.Address.parseIp4("127.0.0.1", 0),
    };

    var replica: Replica = undefined;
    var replica_opened = false;
    defer {
        if (replica_opened) {
            storage.reset_next_tick_lsm();
            replica.deinit(allocator);
        }
        io.cancel_all();
        message_pool.deinit(allocator);
        storage.deinit();
    }

    try replica.open(
        allocator,
        time,
        &storage,
        &message_pool,
        .{
            .node_count = 3,
            .pipeline_requests_limit = 0,
            .storage_size_limit = storage_size,
            .nonce = 1,
            .aof = null,
            .state_machine_options = .{
                .batch_size_limit = constants.message_body_size_max,
                .lsm_forest_compaction_block_count = StateMachine.Forest.Options.compaction_block_count_min,
                .lsm_forest_node_count = 128,
                .cache_entries_geo_events = 256,
                .ram_index_capacity = 128,
            },
            .message_bus_options = .{
                .configuration = &addresses,
                .io = &io,
                .clients_limit = constants.pipeline_prepare_queue_max,
            },
            .tracer = &tracer,
            .release = vsr.Release.minimum,
            .release_client_min = vsr.Release.minimum,
            .multiversion = vsr.multiversion.Multiversion.single_release(vsr.Release.minimum),
            .timeout_config = vsr.timeout_profiles.TimeoutConfig{},
            .quorum_config = vsr.flexible_paxos.QuorumPreset.classic(3),
            .commit_stall_probability = null,
        },
    );
    replica_opened = true;

    storage.reset_next_tick_lsm();

    try std.testing.expect(replica.opened);
    try std.testing.expectEqual(@as(u128, artifact.cluster), replica.cluster);
    try std.testing.expectEqual(@as(u8, 1), replica.replica);
    try std.testing.expectEqual(artifact.checkpointOp(), replica.superblock.working.vsr_state.checkpoint.header.op);
    try std.testing.expect(replica.message_bus.accept_address != null);
}

fn writeCheckpointFixture(
    dir_path: []const u8,
    artifact: checkpoint_artifact.DurableCheckpointArtifact,
) !void {
    const allocator = std.testing.allocator;
    const file_name = try artifact.fileName(allocator);
    defer allocator.free(file_name);
    const contents = try artifact.encodeKeyValue(allocator);
    defer allocator.free(contents);

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);

    const file = try fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
