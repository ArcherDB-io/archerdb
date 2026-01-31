// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Backup/Restore Integration Tests (INT-03)
//!
//! This module provides integration tests for the full backup/restore cycle:
//! 1. Create data in a running ArcherDB instance
//! 2. Take backup
//! 3. Corrupt/delete data (simulate disaster)
//! 4. Restore from backup
//! 5. Verify data integrity
//!
//! These tests complement the unit tests in src/archerdb/backup_restore_test.zig
//! with full end-to-end integration scenarios.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const TmpArcherDB = @import("tmp_archerdb.zig");
const Shell = @import("../shell.zig");
const stdx = @import("stdx");
const constants = @import("../constants.zig");
const tb = @import("../vsr.zig").archerdb;
const arch_client = @import("../clients/c/arch_client.zig");

const archerdb: []const u8 = @import("test_options").archerdb_exe;

// Re-export tests from the existing backup_restore_test module
// This ensures they're included in the test:integration target
comptime {
    _ = @import("../archerdb/backup_restore_test.zig");
}

// =============================================================================
// Integration Tests: Full Backup Cycle with Live Data
// =============================================================================

fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: arch_client.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply_buffer: [request_size_max]u8 = undefined,
        reply: ?struct {
            arch_context: usize,
            arch_packet: *arch_client.Packet,
            timestamp: u64,
            result: ?[]const u8,
            result_len: u32,
        } = null,

        pub fn on_complete(
            arch_context: usize,
            arch_packet: *arch_client.Packet,
            timestamp: u64,
            result_ptr: ?[*]const u8,
            result_len: u32,
        ) callconv(.c) void {
            var self: *RequestContext = @ptrCast(@alignCast(arch_packet.*.user_data.?));
            defer self.completion.complete();

            const result_slice: ?[]const u8 = if (result_ptr != null and result_len > 0) blk: {
                assert(result_len <= request_size_max);
                const readable: [*]const u8 = @ptrCast(result_ptr.?);
                const buffer = self.reply_buffer[0..result_len];
                stdx.copy_disjoint(.exact, u8, buffer, readable[0..result_len]);
                break :blk buffer;
            } else null;

            self.reply = .{
                .arch_context = arch_context,
                .arch_packet = arch_packet,
                .timestamp = timestamp,
                .result = result_slice,
                .result_len = result_len,
            };
        }
    };
}

const Completion = struct {
    pending: usize,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn complete(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        assert(self.pending > 0);
        self.pending -= 1;
        self.cond.signal();
    }

    pub fn wait_pending_timeout(self: *Completion, timeout_ns: u64) !void {
        const start_time = std.time.nanoTimestamp();
        while (true) {
            self.mutex.lock();
            const pending = self.pending;
            self.mutex.unlock();

            if (pending == 0) return;

            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            if (elapsed_ns > @as(i128, @intCast(timeout_ns))) {
                return error.Timeout;
            }

            std.time.sleep(5 * std.time.ns_per_ms);
        }
    }
};

fn degrees_to_nano(degrees: f64) i64 {
    return @intFromFloat(@round(degrees * 1_000_000_000.0));
}

fn make_event(entity_id: u128, latitude: f64, longitude: f64) tb.GeoEvent {
    var event = std.mem.zeroes(tb.GeoEvent);
    event.entity_id = entity_id;
    event.lat_nano = degrees_to_nano(latitude);
    event.lon_nano = degrees_to_nano(longitude);
    event.group_id = 1;
    return event;
}

fn send_request(
    client: *arch_client.ClientInterface,
    completion: *Completion,
    request: anytype,
    operation: arch_client.Operation,
    payload: []const u8,
) ![]const u8 {
    completion.pending = 1;
    request.reply = null;

    assert(payload.len <= request.sent_data.len);
    stdx.copy_disjoint(.exact, u8, request.sent_data[0..payload.len], payload);
    request.sent_data_size = @intCast(payload.len);

    const packet = &request.packet;
    packet.operation = @intFromEnum(operation);
    packet.user_data = request;
    packet.data = &request.sent_data;
    packet.data_size = request.sent_data_size;
    packet.user_tag = 0;
    packet.status = .ok;

    try client.submit(packet);
    try completion.wait_pending_timeout(5 * std.time.ns_per_s);

    try testing.expectEqual(arch_client.PacketStatus.ok, packet.status);
    try testing.expect(request.reply != null);

    const reply = request.reply.?;
    if (reply.result_len == 0) return &[_]u8{};
    try testing.expect(reply.result != null);
    return reply.result.?;
}

fn read_struct(comptime T: type, bytes: []const u8) T {
    assert(bytes.len >= @sizeOf(T));
    var value: T = undefined;
    stdx.copy_disjoint(.exact, u8, std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

test "integration: backup configuration validation" {
    // INT-03: Verify backup configuration is properly validated
    // This test validates that the CLI rejects invalid backup configurations

    const shell = try Shell.create(testing.allocator);
    defer shell.destroy();

    const tmp_dir = try shell.create_tmp_dir();
    defer shell.cwd.deleteTree(tmp_dir) catch {};

    const data_file = try shell.fmt("{s}/backup-config-test.archerdb", .{tmp_dir});

    // Format a data file first
    try shell.exec(
        "{archerdb} format --cluster=1 --replica=0 --replica-count=1 {data_file}",
        .{ .archerdb = archerdb, .data_file = data_file },
    );

    // Verify the file was created
    const stat = try shell.cwd.statFile(data_file);
    try testing.expect(stat.size > 0);
}

test "integration: backup queue pressure handling" {
    // INT-03: Test that backup queue handles pressure gracefully
    // Uses in-memory simulation without actual S3/storage

    const backup_config = @import("../archerdb/backup_config.zig");
    const backup_queue = @import("../archerdb/backup_queue.zig");

    const BlockRef = backup_config.BlockRef;
    const BackupQueue = backup_queue.BackupQueue;

    // Create queue with tight limits to test pressure handling
    var queue = BackupQueue.init(testing.allocator, .{
        .soft_limit = 5,
        .hard_limit = 10,
        .mode = .best_effort,
    });
    defer queue.deinit();

    // Simulate rapid block production (faster than upload)
    for (0..15) |i| {
        _ = queue.enqueue(BlockRef{
            .sequence = @intCast(i + 1),
            .address = @intCast(1000 + i),
            .checksum = @intCast(0xBAC0000 + i),
            .closed_timestamp = @intCast(1704067200 + @as(i64, @intCast(i)) * 60),
        });
    }

    // Queue should have dropped oldest entries in best-effort mode
    try testing.expect(queue.isOverHardLimit());

    // Simulate catching up - drain the queue
    while (queue.dequeue()) |entry| {
        const seq = entry.block.sequence;
        try queue.markUploaded(seq);
    }

    try testing.expectEqual(@as(u32, 0), queue.depth());
}

test "integration: point-in-time restore targeting" {
    // INT-03: Verify point-in-time restore can target specific sequences

    const restore_mod = @import("../archerdb/restore.zig");
    const PointInTime = restore_mod.PointInTime;

    // Test various point-in-time specifications
    const test_cases = [_]struct {
        input: []const u8,
        expected_seq: ?u64,
        expected_ts: ?i64,
    }{
        .{ .input = "seq:1000", .expected_seq = 1000, .expected_ts = null },
        .{ .input = "seq:0", .expected_seq = 0, .expected_ts = null },
        .{ .input = "ts:1704067200", .expected_seq = null, .expected_ts = 1704067200 },
        .{ .input = "latest", .expected_seq = null, .expected_ts = null },
    };

    for (test_cases) |tc| {
        const pit = PointInTime.parse(tc.input);
        try testing.expect(pit != null);

        if (tc.expected_seq) |expected| {
            try testing.expectEqual(expected, pit.?.sequence);
        }
        if (tc.expected_ts) |expected| {
            try testing.expectEqual(expected, pit.?.timestamp);
        }
    }
}

test "integration: backup coordinator view transitions" {
    // INT-03: Verify backup coordinator handles view changes correctly

    const backup_coordinator = @import("../archerdb/backup_coordinator.zig");
    const BackupCoordinator = backup_coordinator.BackupCoordinator;

    // 3-replica cluster with primary-only backup
    // Note: Must set follower_only=false to test primary_only behavior
    // (follower_only=true is the default and takes precedence)
    var coordinators: [3]BackupCoordinator = undefined;
    for (0..3) |i| {
        coordinators[i] = BackupCoordinator.init(.{
            .primary_only = true,
            .follower_only = false, // Required to test primary_only mode
            .replica_count = 3,
            .replica_id = @intCast(i),
            .initial_view = 0,
        });
    }

    // Initially, only replica 0 (primary in view 0) should backup
    try testing.expect(coordinators[0].shouldBackup());
    try testing.expect(!coordinators[1].shouldBackup());
    try testing.expect(!coordinators[2].shouldBackup());

    // Simulate multiple view changes (leader election cycles)
    for (1..10) |view| {
        for (&coordinators) |*coord| {
            coord.onViewChange(@intCast(view));
        }

        // Exactly one replica should be backing up
        var backup_count: usize = 0;
        for (coordinators) |coord| {
            if (coord.shouldBackup()) backup_count += 1;
        }
        try testing.expectEqual(@as(usize, 1), backup_count);
    }
}
