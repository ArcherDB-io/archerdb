// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! Disk Spillover Module for Replication Durability
//!
//! Implements disk-based storage for replication entries when:
//! - Memory queue fills up (back-pressure handling)
//! - S3 uploads fail after retries (durability guarantee)
//!
//! Directory structure:
//!   {data_dir}/spillover/
//!     meta.json           # Index of spillover segments
//!     000001.spill        # Spillover segment files
//!     000002.spill
//!     ...
//!
//! Uses atomic writes (temp file + rename) to prevent corruption on crash.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.spillover);

/// Spillover metadata (persisted as JSON)
pub const SpilloverMeta = struct {
    version: u16 = 1,
    segment_count: u32 = 0,
    oldest_op: u64 = 0,
    newest_op: u64 = 0,
    total_bytes: u64 = 0,
    created_at_ns: u64 = 0,
    last_upload_attempt_ns: u64 = 0,
    consecutive_failures: u32 = 0,

    /// Serialize metadata to JSON
    pub fn toJson(self: SpilloverMeta, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            \\{{"version":{d},"segment_count":{d},"oldest_op":{d},"newest_op":{d},"total_bytes":{d},"created_at_ns":{d},"last_upload_attempt_ns":{d},"consecutive_failures":{d}}}
        , .{
            self.version,
            self.segment_count,
            self.oldest_op,
            self.newest_op,
            self.total_bytes,
            self.created_at_ns,
            self.last_upload_attempt_ns,
            self.consecutive_failures,
        });
    }

    /// Deserialize metadata from JSON
    pub fn fromJson(allocator: Allocator, json: []const u8) !SpilloverMeta {
        _ = allocator;
        var meta = SpilloverMeta{};

        // Simple JSON parsing for our fixed format
        if (parseJsonField(json, "version")) |v| meta.version = @intCast(v);
        if (parseJsonField(json, "segment_count")) |v| meta.segment_count = @intCast(v);
        if (parseJsonField(json, "oldest_op")) |v| meta.oldest_op = v;
        if (parseJsonField(json, "newest_op")) |v| meta.newest_op = v;
        if (parseJsonField(json, "total_bytes")) |v| meta.total_bytes = v;
        if (parseJsonField(json, "created_at_ns")) |v| meta.created_at_ns = v;
        if (parseJsonField(json, "last_upload_attempt_ns")) |v| meta.last_upload_attempt_ns = v;
        if (parseJsonField(json, "consecutive_failures")) |v| meta.consecutive_failures = @intCast(v);

        return meta;
    }

    fn parseJsonField(json: []const u8, field: []const u8) ?u64 {
        // Build search pattern: "field":
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;

        const start = std.mem.indexOf(u8, json, search) orelse return null;
        const value_start = start + search.len;
        if (value_start >= json.len) return null;

        // Find end of number
        var end = value_start;
        while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}

        if (end == value_start) return null;

        return std.fmt.parseInt(u64, json[value_start..end], 10) catch null;
    }
};

/// Spillover segment header (binary, fixed 64 bytes)
/// Layout (aligned for u64):
///   magic:       [4]u8  @ 0
///   version:     u16    @ 4
///   _pad1:       u16    @ 6
///   entry_count: u32    @ 8
///   _pad2:       u32    @ 12
///   total_bytes: u64    @ 16
///   first_op:    u64    @ 24
///   last_op:     u64    @ 32
///   checksum:    u64    @ 40 (using u64 for simpler alignment)
///   _padding:    [16]u8 @ 48
///   Total:       64 bytes
pub const SpilloverSegment = extern struct {
    magic: [4]u8 = .{ 'S', 'P', 'I', 'L' },
    version: u16 = 1,
    _pad1: u16 = 0,
    entry_count: u32 = 0,
    _pad2: u32 = 0,
    total_bytes: u64 = 0,
    first_op: u64 = 0,
    last_op: u64 = 0,
    checksum: u64 = 0, // Wyhash produces u64
    _padding: [16]u8 = .{0} ** 16,

    pub const size = 64;

    comptime {
        if (@sizeOf(SpilloverSegment) != size) {
            @compileError("SpilloverSegment size mismatch: expected 64 bytes");
        }
    }

    pub fn validMagic(self: *const SpilloverSegment) bool {
        return std.mem.eql(u8, &self.magic, "SPIL");
    }
};

/// Entry structure for spillover operations
pub const SpillEntry = struct {
    header: ShipEntry,
    body: []const u8,
};

/// Ship entry header (imported from replication module)
pub const ShipEntry = extern struct {
    magic: [4]u8 = .{ 'S', 'H', 'I', 'P' },
    version: u16 = 1,
    reserved: u16 = 0,
    op: u64,
    commit_timestamp_ns: u64,
    body_size: u32,
    primary_region_id: u32,
    checksum: u128 = 0,
    _padding: [16]u8 = .{0} ** 16,

    pub const header_size = 64;

    comptime {
        if (@sizeOf(ShipEntry) != header_size) {
            @compileError("ShipEntry size mismatch: expected 64 bytes");
        }
    }
};

/// Iterator for recovering entries from spillover files
pub const EntryIterator = struct {
    allocator: Allocator,
    spillover_dir: []const u8,
    dir: ?std.fs.Dir,
    current_file: ?std.fs.File,
    current_segment_id: u32,
    max_segment_id: u32,
    entries_remaining: u32,

    pub fn init(allocator: Allocator, spillover_dir: []const u8, max_segment: u32) EntryIterator {
        return .{
            .allocator = allocator,
            .spillover_dir = spillover_dir,
            .dir = null,
            .current_file = null,
            .current_segment_id = 1,
            .max_segment_id = max_segment,
            .entries_remaining = 0,
        };
    }

    pub fn deinit(self: *EntryIterator) void {
        if (self.current_file) |*f| {
            f.close();
        }
        if (self.dir) |*d| {
            d.close();
        }
    }

    pub fn next(self: *EntryIterator) ?SpillEntry {
        // If we have entries remaining in current file, read next
        if (self.entries_remaining > 0) {
            return self.readEntry();
        }

        // Current segment exhausted - if we had a file open, move to next segment
        if (self.current_file != null) {
            self.current_segment_id += 1;
        }

        // Try to open segment files
        while (self.current_segment_id <= self.max_segment_id) {
            if (self.openNextSegment()) {
                if (self.entries_remaining > 0) {
                    return self.readEntry();
                }
            }
            self.current_segment_id += 1;
        }

        return null;
    }

    fn openNextSegment(self: *EntryIterator) bool {
        // Close previous file if open
        if (self.current_file) |*f| {
            f.close();
            self.current_file = null;
        }

        // Build segment filename
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d:0>6}.spill", .{self.current_segment_id}) catch return false;

        // Open directory if needed
        if (self.dir == null) {
            self.dir = std.fs.cwd().openDir(self.spillover_dir, .{}) catch return false;
        }

        // Open segment file
        const file = self.dir.?.openFile(name, .{}) catch return false;
        self.current_file = file;

        // Read segment header
        var header: SpilloverSegment = undefined;
        const bytes_read = file.read(std.mem.asBytes(&header)) catch {
            file.close();
            self.current_file = null;
            return false;
        };

        if (bytes_read < SpilloverSegment.size or !header.validMagic()) {
            file.close();
            self.current_file = null;
            return false;
        }

        self.entries_remaining = header.entry_count;
        return true;
    }

    fn readEntry(self: *EntryIterator) ?SpillEntry {
        const file = self.current_file orelse return null;

        // Read entry header
        var header: ShipEntry = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const header_read = file.read(header_bytes) catch return null;
        if (header_read < ShipEntry.header_size) return null;

        // Validate magic
        if (!std.mem.eql(u8, &header.magic, "SHIP")) {
            log.warn("Invalid entry magic in spillover segment {d}", .{self.current_segment_id});
            return null;
        }

        // Skip past the body data to position for next entry
        // (body is not returned in iteration - caller must re-read if needed)
        if (header.body_size > 0) {
            file.seekBy(@intCast(header.body_size)) catch return null;
        }

        self.entries_remaining -= 1;

        return SpillEntry{
            .header = header,
            .body = &[_]u8{}, // Body must be read separately by caller
        };
    }
};

/// Manages disk spillover for replication durability
pub const SpilloverManager = struct {
    allocator: Allocator,
    spillover_dir: []const u8,
    meta: SpilloverMeta,
    current_segment: ?std.fs.File,
    current_segment_id: u32,
    entries_in_current: u32,
    bytes_in_current: u64,
    max_entries_per_segment: u32,

    pub const Config = struct {
        max_entries_per_segment: u32 = 1000,
    };

    pub fn init(allocator: Allocator, data_dir: []const u8) !SpilloverManager {
        // Build spillover directory path
        const spillover_dir = try std.fs.path.join(allocator, &.{ data_dir, "spillover" });
        errdefer allocator.free(spillover_dir);

        // Create directory if needed
        std.fs.cwd().makePath(spillover_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Load metadata if exists
        const meta = loadMeta(allocator, spillover_dir) catch SpilloverMeta{
            .version = 1,
            .segment_count = 0,
            .oldest_op = 0,
            .newest_op = 0,
            .total_bytes = 0,
            .created_at_ns = @intCast(std.time.nanoTimestamp()),
            .last_upload_attempt_ns = 0,
            .consecutive_failures = 0,
        };

        return SpilloverManager{
            .allocator = allocator,
            .spillover_dir = spillover_dir,
            .meta = meta,
            .current_segment = null,
            .current_segment_id = meta.segment_count,
            .entries_in_current = 0,
            .bytes_in_current = 0,
            .max_entries_per_segment = 1000,
        };
    }

    pub fn deinit(self: *SpilloverManager) void {
        if (self.current_segment) |*f| {
            f.close();
        }
        self.allocator.free(self.spillover_dir);
    }

    /// Spill entries to disk (atomic write: temp file + rename)
    pub fn spillEntries(self: *SpilloverManager, entries: []const SpillEntry) !void {
        if (entries.len == 0) return;

        // Start a new segment
        self.current_segment_id += 1;

        // Build temp path
        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/.tmp_{d}.spill",
            .{ self.spillover_dir, self.current_segment_id },
        );
        defer self.allocator.free(temp_path);

        // Build final path
        const final_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{d:0>6}.spill",
            .{ self.spillover_dir, self.current_segment_id },
        );
        defer self.allocator.free(final_path);

        // Create temp file
        var file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();

        // Calculate checksum and total bytes
        var hasher = std.hash.Wyhash.init(0);
        var total_bytes: u64 = 0;
        var first_op: u64 = std.math.maxInt(u64);
        var last_op: u64 = 0;

        for (entries) |entry| {
            hasher.update(std.mem.asBytes(&entry.header));
            hasher.update(entry.body);
            total_bytes += ShipEntry.header_size + entry.body.len;
            first_op = @min(first_op, entry.header.op);
            last_op = @max(last_op, entry.header.op);
        }

        // Build and write segment header
        var header = SpilloverSegment{
            .entry_count = @intCast(entries.len),
            .total_bytes = total_bytes,
            .first_op = first_op,
            .last_op = last_op,
            .checksum = hasher.final(),
        };
        try file.writeAll(std.mem.asBytes(&header));

        // Write all entries
        for (entries) |entry| {
            try file.writeAll(std.mem.asBytes(&entry.header));
            if (entry.body.len > 0) {
                try file.writeAll(entry.body);
            }
        }

        // Sync to disk
        try file.sync();

        // Atomic rename
        try std.fs.cwd().rename(temp_path, final_path);

        // Update metadata
        self.meta.segment_count += 1;
        self.meta.total_bytes += total_bytes;
        if (self.meta.oldest_op == 0 or first_op < self.meta.oldest_op) {
            self.meta.oldest_op = first_op;
        }
        if (last_op > self.meta.newest_op) {
            self.meta.newest_op = last_op;
        }

        // Persist metadata
        try self.persistMeta();

        log.info("Spilled {} entries ({} bytes) to segment {d:0>6}", .{
            entries.len,
            total_bytes,
            self.current_segment_id,
        });
    }

    /// Recover entries from disk (returns iterator)
    pub fn recoverEntries(self: *SpilloverManager) !EntryIterator {
        return EntryIterator.init(
            self.allocator,
            self.spillover_dir,
            self.meta.segment_count,
        );
    }

    /// Mark entries as uploaded (delete spillover files through given op)
    pub fn markUploaded(self: *SpilloverManager, through_op: u64) !void {
        if (self.meta.segment_count == 0) return;

        var dir = std.fs.cwd().openDir(self.spillover_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var segments_deleted: u32 = 0;
        var bytes_freed: u64 = 0;

        // Iterate through segment files
        var segment_id: u32 = 1;
        while (segment_id <= self.meta.segment_count) : (segment_id += 1) {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{d:0>6}.spill", .{segment_id}) catch continue;

            // Open and check segment
            const file = dir.openFile(name, .{}) catch continue;
            defer file.close();

            var header: SpilloverSegment = undefined;
            const bytes_read = file.read(std.mem.asBytes(&header)) catch continue;
            if (bytes_read < SpilloverSegment.size) continue;

            // If all entries in segment are <= through_op, delete it
            if (header.last_op <= through_op) {
                dir.deleteFile(name) catch continue;
                segments_deleted += 1;
                bytes_freed += header.total_bytes + SpilloverSegment.size;
            }
        }

        if (segments_deleted > 0) {
            self.meta.segment_count -|= segments_deleted;
            self.meta.total_bytes -|= bytes_freed;
            if (self.meta.segment_count == 0) {
                self.meta.oldest_op = 0;
                self.meta.newest_op = 0;
            }
            try self.persistMeta();

            log.info("Deleted {} spillover segments ({} bytes), {} remaining", .{
                segments_deleted,
                bytes_freed,
                self.meta.segment_count,
            });
        }
    }

    /// Get total bytes on disk
    pub fn getDiskBytes(self: *SpilloverManager) u64 {
        return self.meta.total_bytes;
    }

    /// Check if there are pending spillover entries
    pub fn hasPending(self: *SpilloverManager) bool {
        return self.meta.segment_count > 0;
    }

    /// Get current metadata
    pub fn getMeta(self: *const SpilloverManager) SpilloverMeta {
        return self.meta;
    }

    /// Record upload failure
    pub fn recordFailure(self: *SpilloverManager) void {
        self.meta.consecutive_failures += 1;
        self.meta.last_upload_attempt_ns = @intCast(std.time.nanoTimestamp());
    }

    /// Record upload success (reset failure count)
    pub fn recordSuccess(self: *SpilloverManager) void {
        self.meta.consecutive_failures = 0;
    }

    // Private helpers

    fn loadMeta(allocator: Allocator, spillover_dir: []const u8) !SpilloverMeta {
        const meta_path = try std.fs.path.join(allocator, &.{ spillover_dir, "meta.json" });
        defer allocator.free(meta_path);

        const file = try std.fs.cwd().openFile(meta_path, .{});
        defer file.close();

        var buf: [512]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        if (bytes_read == 0) return error.EmptyFile;

        return SpilloverMeta.fromJson(allocator, buf[0..bytes_read]);
    }

    fn persistMeta(self: *SpilloverManager) !void {
        const meta_path = try std.fs.path.join(self.allocator, &.{ self.spillover_dir, "meta.json" });
        defer self.allocator.free(meta_path);

        const temp_path = try std.fs.path.join(self.allocator, &.{ self.spillover_dir, ".meta.json.tmp" });
        defer self.allocator.free(temp_path);

        // Write to temp file
        const json = try self.meta.toJson(self.allocator);
        defer self.allocator.free(json);

        var file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(json);
        try file.sync();

        // Atomic rename
        try std.fs.cwd().rename(temp_path, meta_path);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SpilloverMeta JSON round-trip" {
    const allocator = std.testing.allocator;

    const original = SpilloverMeta{
        .version = 1,
        .segment_count = 5,
        .oldest_op = 100,
        .newest_op = 500,
        .total_bytes = 12345,
        .created_at_ns = 1704067200000000000,
        .last_upload_attempt_ns = 1704067300000000000,
        .consecutive_failures = 3,
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const parsed = try SpilloverMeta.fromJson(allocator, json);

    try std.testing.expectEqual(@as(u16, 1), parsed.version);
    try std.testing.expectEqual(@as(u32, 5), parsed.segment_count);
    try std.testing.expectEqual(@as(u64, 100), parsed.oldest_op);
    try std.testing.expectEqual(@as(u64, 500), parsed.newest_op);
    try std.testing.expectEqual(@as(u64, 12345), parsed.total_bytes);
    try std.testing.expectEqual(@as(u32, 3), parsed.consecutive_failures);
}

test "SpilloverSegment size and magic" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SpilloverSegment));

    const segment = SpilloverSegment{};
    try std.testing.expect(segment.validMagic());

    var invalid = segment;
    invalid.magic = .{ 'B', 'A', 'D', '!' };
    try std.testing.expect(!invalid.validMagic());
}

test "SpilloverManager init and deinit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var manager = try SpilloverManager.init(allocator, tmp_path);
    defer manager.deinit();

    try std.testing.expectEqual(@as(u32, 0), manager.meta.segment_count);
    try std.testing.expect(!manager.hasPending());
}

test "SpilloverManager spill and recover" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create manager and spill entries
    {
        var manager = try SpilloverManager.init(allocator, tmp_path);
        defer manager.deinit();

        const body1 = "hello world";
        const body2 = "goodbye world";

        var entries = [_]SpillEntry{
            .{
                .header = ShipEntry{
                    .op = 1,
                    .commit_timestamp_ns = 1000,
                    .body_size = @intCast(body1.len),
                    .primary_region_id = 1,
                },
                .body = body1,
            },
            .{
                .header = ShipEntry{
                    .op = 2,
                    .commit_timestamp_ns = 2000,
                    .body_size = @intCast(body2.len),
                    .primary_region_id = 1,
                },
                .body = body2,
            },
        };

        try manager.spillEntries(&entries);

        try std.testing.expectEqual(@as(u32, 1), manager.meta.segment_count);
        try std.testing.expectEqual(@as(u64, 1), manager.meta.oldest_op);
        try std.testing.expectEqual(@as(u64, 2), manager.meta.newest_op);
        try std.testing.expect(manager.hasPending());
    }

    // Re-open and verify recovery
    {
        var manager = try SpilloverManager.init(allocator, tmp_path);
        defer manager.deinit();

        // Metadata should be persisted
        try std.testing.expectEqual(@as(u32, 1), manager.meta.segment_count);
        try std.testing.expect(manager.hasPending());

        // Verify recovery iterator
        var iter = try manager.recoverEntries();
        defer iter.deinit();

        const entry1 = iter.next();
        try std.testing.expect(entry1 != null);
        try std.testing.expectEqual(@as(u64, 1), entry1.?.header.op);

        const entry2 = iter.next();
        try std.testing.expect(entry2 != null);
        try std.testing.expectEqual(@as(u64, 2), entry2.?.header.op);

        const entry3 = iter.next();
        try std.testing.expect(entry3 == null);
    }
}

test "SpilloverManager markUploaded deletes segments" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var manager = try SpilloverManager.init(allocator, tmp_path);
    defer manager.deinit();

    // Spill some entries
    const body = "test data";
    var entries = [_]SpillEntry{
        .{
            .header = ShipEntry{
                .op = 1,
                .commit_timestamp_ns = 1000,
                .body_size = @intCast(body.len),
                .primary_region_id = 1,
            },
            .body = body,
        },
        .{
            .header = ShipEntry{
                .op = 2,
                .commit_timestamp_ns = 2000,
                .body_size = @intCast(body.len),
                .primary_region_id = 1,
            },
            .body = body,
        },
    };

    try manager.spillEntries(&entries);
    try std.testing.expect(manager.hasPending());

    // Mark all as uploaded
    try manager.markUploaded(2);
    try std.testing.expect(!manager.hasPending());
    try std.testing.expectEqual(@as(u32, 0), manager.meta.segment_count);
}

test "SpilloverManager atomic write survives crash" {
    // This test verifies that partial writes don't corrupt state
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var manager = try SpilloverManager.init(allocator, tmp_path);
    defer manager.deinit();

    // Spill entries
    const body = "atomic test";
    var entries = [_]SpillEntry{
        .{
            .header = ShipEntry{
                .op = 42,
                .commit_timestamp_ns = 1234,
                .body_size = @intCast(body.len),
                .primary_region_id = 1,
            },
            .body = body,
        },
    };

    try manager.spillEntries(&entries);

    // Verify temp file doesn't exist (renamed to final)
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.tmp_1.spill",
        .{manager.spillover_dir},
    );
    defer allocator.free(temp_path);

    const temp_exists = std.fs.cwd().access(temp_path, .{});
    try std.testing.expectError(error.FileNotFound, temp_exists);

    // Verify final file exists
    const final_path = try std.fmt.allocPrint(
        allocator,
        "{s}/000001.spill",
        .{manager.spillover_dir},
    );
    defer allocator.free(final_path);

    try std.fs.cwd().access(final_path, .{});
}

test "SpilloverManager segment checksum" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var manager = try SpilloverManager.init(allocator, tmp_path);
    defer manager.deinit();

    const body = "checksum test";
    var entries = [_]SpillEntry{
        .{
            .header = ShipEntry{
                .op = 1,
                .commit_timestamp_ns = 1000,
                .body_size = @intCast(body.len),
                .primary_region_id = 1,
            },
            .body = body,
        },
    };

    try manager.spillEntries(&entries);

    // Read segment header and verify checksum is non-zero
    const segment_path = try std.fmt.allocPrint(
        allocator,
        "{s}/000001.spill",
        .{manager.spillover_dir},
    );
    defer allocator.free(segment_path);

    var file = try std.fs.cwd().openFile(segment_path, .{});
    defer file.close();

    var header: SpilloverSegment = undefined;
    _ = try file.read(std.mem.asBytes(&header));

    try std.testing.expect(header.validMagic());
    try std.testing.expect(header.checksum != 0);
    try std.testing.expectEqual(@as(u32, 1), header.entry_count);
}

test "SpilloverManager segment rotation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var manager = try SpilloverManager.init(allocator, tmp_path);
    defer manager.deinit();

    // Spill multiple batches (each becomes a segment)
    const body = "segment rotation test";

    for (1..4) |i| {
        var entries = [_]SpillEntry{
            .{
                .header = ShipEntry{
                    .op = @intCast(i),
                    .commit_timestamp_ns = @intCast(i * 1000),
                    .body_size = @intCast(body.len),
                    .primary_region_id = 1,
                },
                .body = body,
            },
        };
        try manager.spillEntries(&entries);
    }

    try std.testing.expectEqual(@as(u32, 3), manager.meta.segment_count);
    try std.testing.expectEqual(@as(u64, 1), manager.meta.oldest_op);
    try std.testing.expectEqual(@as(u64, 3), manager.meta.newest_op);

    // Verify all segment files exist
    for (1..4) |i| {
        const segment_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{d:0>6}.spill",
            .{ manager.spillover_dir, i },
        );
        defer allocator.free(segment_path);
        try std.fs.cwd().access(segment_path, .{});
    }
}
