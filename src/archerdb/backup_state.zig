// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup State Persistence (F5.5.3)
//!
//! This module provides persistence for backup state, enabling incremental
//! backups by tracking which blocks have been uploaded. On restart, it loads
//! the state and resumes from where it left off.
//!
//! See: openspec/changes/add-geospatial-core/specs/backup-restore/spec.md
//!
//! Usage:
//! ```zig
//! var state_manager = try BackupStateManager.init(allocator, .{
//!     .data_dir = "/var/lib/archerdb",
//!     .cluster_id = 0x12345678,
//!     .replica_id = 0,
//! });
//! defer state_manager.deinit();
//!
//! // On startup, resume from last uploaded sequence
//! const last_seq = state_manager.getLastUploadedSequence();
//!
//! // After successful upload
//! try state_manager.markUploaded(1000);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fs = std.fs;
const log = std.log.scoped(.backup_state);

const backup_config = @import("backup_config.zig");
const BackupState = backup_config.BackupState;

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

/// State manager configuration.
pub const StateManagerOptions = struct {
    /// Directory where state file will be stored.
    data_dir: []const u8,
    /// Cluster ID (used in state file name).
    cluster_id: u128,
    /// Replica ID (used in state file name).
    replica_id: u8,
    /// How often to persist state (in uploads).
    persist_interval: u32 = 10,
};

/// Errors during state operations.
pub const StateError = error{
    /// Failed to read state file.
    ReadFailed,
    /// Failed to write state file.
    WriteFailed,
    /// State file is corrupted.
    Corrupted,
    /// Directory does not exist.
    DirectoryNotFound,
};

/// Magic bytes for state file identification.
const STATE_FILE_MAGIC: [8]u8 = "ARCHBKST".*;

/// State file version for format compatibility.
const STATE_FILE_VERSION: u32 = 1;

/// State file header (64 bytes).
const StateFileHeader = extern struct {
    /// Magic bytes for identification.
    magic: [8]u8,
    /// File format version.
    version: u32,
    /// Cluster ID.
    cluster_id: u128,
    /// Replica ID.
    replica_id: u8,
    /// Reserved for alignment.
    reserved: [27]u8 = [_]u8{0} ** 27,
};

/// State file body (64 bytes).
const StateFileBody = extern struct {
    /// Highest block sequence successfully uploaded.
    last_uploaded_sequence: u64,
    /// Timestamp of last successful upload (ns since epoch).
    last_upload_timestamp: i64,
    /// Number of blocks pending upload.
    pending_count: u32,
    /// Number of failed upload attempts.
    failed_count: u32,
    /// Number of blocks abandoned without backup.
    abandoned_count: u64,
    /// Checksum of the body (crc32).
    checksum: u32,
    /// Reserved for future use.
    reserved: [20]u8 = [_]u8{0} ** 20,
};

/// Manages backup state persistence.
pub const BackupStateManager = struct {
    allocator: mem.Allocator,
    options: StateManagerOptions,
    state: BackupState,

    /// Path to state file (owned).
    state_file_path: []u8,

    /// Count of uploads since last persist.
    uploads_since_persist: u32 = 0,

    /// Initialize state manager, loading existing state if available.
    pub fn init(allocator: mem.Allocator, options: StateManagerOptions) !BackupStateManager {
        // Build state file path
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/backup_state_{x:0>32}_r{d}.bin",
            .{ options.data_dir, options.cluster_id, options.replica_id },
        );
        errdefer allocator.free(path);

        var self = BackupStateManager{
            .allocator = allocator,
            .options = options,
            .state = .{},
            .state_file_path = path,
        };

        // Try to load existing state
        self.loadState() catch |err| switch (err) {
            error.FileNotFound => {
                // No existing state, start fresh
                logInfo("No existing backup state, starting fresh", .{});
            },
            else => {
                logWarn("Failed to load backup state: {}, starting fresh", .{err});
            },
        };

        return self;
    }

    /// Clean up resources.
    pub fn deinit(self: *BackupStateManager) void {
        self.allocator.free(self.state_file_path);
    }

    /// Get the last uploaded sequence number.
    pub fn getLastUploadedSequence(self: *const BackupStateManager) u64 {
        return self.state.last_uploaded_sequence;
    }

    /// Get current backup state.
    pub fn getState(self: *const BackupStateManager) BackupState {
        return self.state;
    }

    /// Mark a block as successfully uploaded.
    /// Updates state and periodically persists to disk.
    pub fn markUploaded(self: *BackupStateManager, sequence: u64) !void {
        // Update in-memory state
        if (sequence > self.state.last_uploaded_sequence) {
            self.state.last_uploaded_sequence = sequence;
        }
        self.state.last_upload_timestamp = std.time.timestamp();

        if (self.state.pending_count > 0) {
            self.state.pending_count -= 1;
        }

        self.uploads_since_persist += 1;

        // Persist periodically
        if (self.uploads_since_persist >= self.options.persist_interval) {
            try self.persist();
            self.uploads_since_persist = 0;
        }
    }

    /// Increment pending count.
    pub fn incrementPending(self: *BackupStateManager) void {
        self.state.pending_count += 1;
    }

    /// Increment failed count.
    pub fn incrementFailed(self: *BackupStateManager) void {
        self.state.failed_count += 1;
    }

    /// Increment abandoned count (best-effort mode).
    pub fn incrementAbandoned(self: *BackupStateManager) void {
        self.state.abandoned_count += 1;
    }

    /// Force persist state to disk.
    pub fn persist(self: *BackupStateManager) !void {
        const header = StateFileHeader{
            .magic = STATE_FILE_MAGIC,
            .version = STATE_FILE_VERSION,
            .cluster_id = self.options.cluster_id,
            .replica_id = self.options.replica_id,
            .reserved = [_]u8{0} ** 27,
        };

        var body = StateFileBody{
            .last_uploaded_sequence = self.state.last_uploaded_sequence,
            .last_upload_timestamp = self.state.last_upload_timestamp,
            .pending_count = self.state.pending_count,
            .failed_count = self.state.failed_count,
            .abandoned_count = self.state.abandoned_count,
            .checksum = 0,
            .reserved = [_]u8{0} ** 20,
        };

        // Calculate checksum over body (excluding checksum field itself)
        const body_bytes = mem.asBytes(&body);
        body.checksum = std.hash.crc.Crc32.hash(body_bytes[0 .. body_bytes.len - 24]);

        // Write to temp file then rename (atomic)
        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp",
            .{self.state_file_path},
        );
        defer self.allocator.free(tmp_path);

        // Open/create temp file
        const file = fs.cwd().createFile(tmp_path, .{}) catch |err| {
            logErr("Failed to create temp state file: {}", .{err});
            return StateError.WriteFailed;
        };
        defer file.close();

        // Write header and body
        file.writeAll(mem.asBytes(&header)) catch |err| {
            logErr("Failed to write state header: {}", .{err});
            return StateError.WriteFailed;
        };

        file.writeAll(mem.asBytes(&body)) catch |err| {
            logErr("Failed to write state body: {}", .{err});
            return StateError.WriteFailed;
        };

        // Atomic rename
        fs.cwd().rename(tmp_path, self.state_file_path) catch |err| {
            logErr("Failed to rename state file: {}", .{err});
            return StateError.WriteFailed;
        };

        logInfo("Persisted backup state: seq={}, pending={}", .{
            self.state.last_uploaded_sequence,
            self.state.pending_count,
        });
    }

    /// Load state from disk.
    fn loadState(self: *BackupStateManager) !void {
        const file = try fs.cwd().openFile(self.state_file_path, .{});
        defer file.close();

        // Read header
        var header: StateFileHeader = undefined;
        const header_bytes_read = try file.read(mem.asBytes(&header));
        if (header_bytes_read != @sizeOf(StateFileHeader)) {
            return StateError.Corrupted;
        }

        // Verify magic
        if (!mem.eql(u8, &header.magic, &STATE_FILE_MAGIC)) {
            logErr("Invalid state file magic", .{});
            return StateError.Corrupted;
        }

        // Verify version
        if (header.version != STATE_FILE_VERSION) {
            logErr("Unsupported state file version: {}", .{header.version});
            return StateError.Corrupted;
        }

        // Verify cluster/replica match
        if (header.cluster_id != self.options.cluster_id or
            header.replica_id != self.options.replica_id)
        {
            logErr("State file cluster/replica mismatch", .{});
            return StateError.Corrupted;
        }

        // Read body
        var body: StateFileBody = undefined;
        const body_bytes_read = try file.read(mem.asBytes(&body));
        if (body_bytes_read != @sizeOf(StateFileBody)) {
            return StateError.Corrupted;
        }

        // Verify checksum
        const body_bytes = mem.asBytes(&body);
        const computed_checksum = std.hash.crc.Crc32.hash(body_bytes[0 .. body_bytes.len - 24]);
        if (body.checksum != computed_checksum) {
            logErr("State file checksum mismatch", .{});
            return StateError.Corrupted;
        }

        // Load into state
        self.state = .{
            .last_uploaded_sequence = body.last_uploaded_sequence,
            .last_upload_timestamp = body.last_upload_timestamp,
            .pending_count = body.pending_count,
            .failed_count = body.failed_count,
            .abandoned_count = body.abandoned_count,
        };

        logInfo("Loaded backup state: seq={}, pending={}, abandoned={}", .{
            self.state.last_uploaded_sequence,
            self.state.pending_count,
            self.state.abandoned_count,
        });
    }

    /// Check if a block sequence needs to be uploaded.
    /// Returns true if sequence > last_uploaded_sequence.
    pub fn needsUpload(self: *const BackupStateManager, sequence: u64) bool {
        return sequence > self.state.last_uploaded_sequence;
    }

    /// Get the number of blocks that need to be uploaded given a current sequence.
    pub fn getUploadBacklog(self: *const BackupStateManager, current_sequence: u64) u64 {
        if (current_sequence <= self.state.last_uploaded_sequence) {
            return 0;
        }
        return current_sequence - self.state.last_uploaded_sequence;
    }

    /// Reset state (for testing or emergency recovery).
    pub fn reset(self: *BackupStateManager) !void {
        self.state = .{};
        self.uploads_since_persist = 0;

        // Delete state file if it exists
        fs.cwd().deleteFile(self.state_file_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return StateError.WriteFailed,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BackupStateManager: init and deinit" {
    var state_manager = try BackupStateManager.init(std.testing.allocator, .{
        .data_dir = "/tmp",
        .cluster_id = 0x12345678,
        .replica_id = 0,
    });
    defer state_manager.deinit();

    try std.testing.expectEqual(@as(u64, 0), state_manager.getLastUploadedSequence());
}

test "BackupStateManager: markUploaded updates state" {
    var state_manager = try BackupStateManager.init(std.testing.allocator, .{
        .data_dir = "/tmp",
        .cluster_id = 0xABCDEF,
        .replica_id = 1,
        .persist_interval = 100, // High to avoid actual disk writes in test
    });
    defer state_manager.deinit();

    try state_manager.markUploaded(1000);
    try std.testing.expectEqual(@as(u64, 1000), state_manager.getLastUploadedSequence());

    try state_manager.markUploaded(2000);
    try std.testing.expectEqual(@as(u64, 2000), state_manager.getLastUploadedSequence());

    // Out of order - should not decrease
    try state_manager.markUploaded(1500);
    try std.testing.expectEqual(@as(u64, 2000), state_manager.getLastUploadedSequence());
}

test "BackupStateManager: needsUpload" {
    var state_manager = try BackupStateManager.init(std.testing.allocator, .{
        .data_dir = "/tmp",
        .cluster_id = 0x123,
        .replica_id = 0,
        .persist_interval = 100,
    });
    defer state_manager.deinit();

    // Everything needs upload initially
    try std.testing.expect(state_manager.needsUpload(1));
    try std.testing.expect(state_manager.needsUpload(1000));

    // Mark sequence 500 as uploaded
    try state_manager.markUploaded(500);

    // Now only sequences > 500 need upload
    try std.testing.expect(!state_manager.needsUpload(100));
    try std.testing.expect(!state_manager.needsUpload(500));
    try std.testing.expect(state_manager.needsUpload(501));
    try std.testing.expect(state_manager.needsUpload(1000));
}

test "BackupStateManager: getUploadBacklog" {
    var state_manager = try BackupStateManager.init(std.testing.allocator, .{
        .data_dir = "/tmp",
        .cluster_id = 0x456,
        .replica_id = 0,
        .persist_interval = 100,
    });
    defer state_manager.deinit();

    try std.testing.expectEqual(@as(u64, 1000), state_manager.getUploadBacklog(1000));

    try state_manager.markUploaded(500);
    try std.testing.expectEqual(@as(u64, 500), state_manager.getUploadBacklog(1000));
    try std.testing.expectEqual(@as(u64, 0), state_manager.getUploadBacklog(500));
    try std.testing.expectEqual(@as(u64, 0), state_manager.getUploadBacklog(100));
}

test "BackupStateManager: persist and load" {
    const test_cluster: u128 = 0xDEADBEEF;
    const test_replica: u8 = 2;
    const state_path = "/tmp/backup_state_000000000000000000000000deadbeef_r2.bin";

    // Clean up any existing test file
    fs.cwd().deleteFile(state_path) catch {};

    {
        // Create state manager and persist
        var state_manager = try BackupStateManager.init(std.testing.allocator, .{
            .data_dir = "/tmp",
            .cluster_id = test_cluster,
            .replica_id = test_replica,
            .persist_interval = 1, // Persist immediately
        });
        defer state_manager.deinit();

        try state_manager.markUploaded(5000);
        state_manager.incrementAbandoned();
        try state_manager.persist();
    }

    {
        // Load state in new manager
        var state_manager = try BackupStateManager.init(std.testing.allocator, .{
            .data_dir = "/tmp",
            .cluster_id = test_cluster,
            .replica_id = test_replica,
        });
        defer state_manager.deinit();

        try std.testing.expectEqual(@as(u64, 5000), state_manager.getLastUploadedSequence());
        try std.testing.expectEqual(@as(u64, 1), state_manager.getState().abandoned_count);
    }

    // Clean up
    fs.cwd().deleteFile(state_path) catch {};
}

test "StateFileHeader: size check" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(StateFileHeader));
}

test "StateFileBody: size check" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(StateFileBody));
}
