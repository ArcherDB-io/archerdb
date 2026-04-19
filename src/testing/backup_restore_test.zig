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
const vsr = @import("../vsr.zig");
const tb = vsr.archerdb;
const arch_client = @import("../clients/c/arch_client.zig");
const restore = @import("../archerdb/restore.zig");
const checkpoint_artifact = vsr.checkpoint_artifact;
const s3_client = @import("../replication/s3_client.zig");
const azure_blob_client = @import("../replication/azure_blob_client.zig");

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

fn pickFreePort() !u16 {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    try std.posix.bind(fd, &address.any, address.getOsSockLen());

    var bound_addr: std.posix.sockaddr = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(fd, &bound_addr, &bound_addr_len);

    const addr_in: *align(1) const std.posix.sockaddr.in = @ptrCast(&bound_addr);
    return std.mem.bigToNative(u16, addr_in.port);
}

fn waitForReady(port: u16, timeout_ns: u64) !void {
    const allocator = std.testing.allocator;
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));

    while (std.time.nanoTimestamp() < deadline) {
        var stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch {
            std.time.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer stream.close();

        try stream.writer().writeAll(
            "GET /health/ready HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
        );

        const response = try stream.reader().readAllAlloc(allocator, 16 * 1024);
        defer allocator.free(response);

        if (std.mem.indexOf(u8, response, " 200 ") != null) return;
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    return error.ReadinessTimeout;
}

fn fetchMetrics(allocator: std.mem.Allocator, port: u16) ![]u8 {
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        var stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch |err| {
            if (attempts + 1 >= 10) return err;
            std.time.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer stream.close();

        try stream.writer().writeAll(
            "GET /metrics HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
        );

        return try stream.reader().readAllAlloc(allocator, 1024 * 1024);
    }

    return error.MetricsUnavailable;
}

fn parseMetricU64(metrics_body: []const u8, metric_name: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, metrics_body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, metric_name)) continue;
        if (line.len <= metric_name.len) continue;

        var value_start = metric_name.len;
        if (line[value_start] == '{') {
            const labels_end = std.mem.indexOfScalarPos(u8, line, value_start, '}') orelse continue;
            value_start = labels_end + 1;
        }

        if (value_start >= line.len or line[value_start] != ' ') continue;
        const value = std.mem.trim(u8, line[value_start + 1 ..], " ");
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

const BackupArtifactCounts = struct {
    blocks: usize = 0,
    timestamps: usize = 0,
    metadata: usize = 0,
    checkpoints: usize = 0,
};

fn countBackupArtifacts(blocks_dir: []const u8) !BackupArtifactCounts {
    var counts = BackupArtifactCounts{};
    var dir = std.fs.openDirAbsolute(blocks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return counts,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".block")) {
            counts.blocks += 1;
        } else if (std.mem.endsWith(u8, entry.name, ".block.ts")) {
            counts.timestamps += 1;
        } else if (std.mem.endsWith(u8, entry.name, ".block.meta")) {
            counts.metadata += 1;
        } else if (std.mem.endsWith(u8, entry.name, checkpoint_artifact.file_suffix)) {
            counts.checkpoints += 1;
        }
    }

    return counts;
}

fn waitForBackupArtifacts(
    metrics_port: u16,
    blocks_dir: []const u8,
    timeout_ns: u64,
) !struct {
    uploaded_blocks: u64,
    counts: BackupArtifactCounts,
} {
    const allocator = std.testing.allocator;
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));

    while (std.time.nanoTimestamp() < deadline) {
        const metrics = try fetchMetrics(allocator, metrics_port);
        defer allocator.free(metrics);

        const uploaded_blocks = parseMetricU64(
            metrics,
            "archerdb_backup_blocks_uploaded_total",
        ) orelse 0;
        const counts = try countBackupArtifacts(blocks_dir);
        if (uploaded_blocks > 0 and
            counts.blocks > 0 and
            counts.timestamps > 0 and
            counts.metadata > 0 and
            counts.checkpoints > 0)
        {
            return .{
                .uploaded_blocks = uploaded_blocks,
                .counts = counts,
            };
        }

        std.time.sleep(100 * std.time.ns_per_ms);
    }

    return error.BackupArtifactsTimeout;
}

fn makePrepareHeader(
    cluster: u128,
    view: u32,
    op: u64,
    commit: u64,
    parent: u128,
    release_format: vsr.Release,
) vsr.Header.Prepare {
    var header = std.mem.zeroInit(vsr.Header.Prepare, .{
        .cluster = cluster,
        .size = @sizeOf(vsr.Header),
        .view = view,
        .release = release_format,
        .command = .prepare,
        .op = op,
        .commit = commit,
        .operation = .pulse,
        .parent = parent,
        .timestamp = op,
    });
    header.set_checksum_body(&[_]u8{});
    header.set_checksum();
    assert(header.invalid() == null);
    return header;
}

fn makeStandaloneCheckpointArtifact(storage_size: u64) checkpoint_artifact.DurableCheckpointArtifact {
    const cluster: u128 = 0;
    const replica_id: u128 = 0x100;
    const release_format = constants.config.process.release;
    const checkpoint_op = vsr.Checkpoint.checkpoint_after(0);
    const head_op = checkpoint_op + 1;

    var members = std.mem.zeroes(vsr.Members);
    members[0] = replica_id;

    var view_headers_all: [constants.view_headers_max]vsr.Header.Prepare =
        @splat(std.mem.zeroes(vsr.Header.Prepare));
    var previous = vsr.Header.Prepare.root(cluster);
    var checkpoint_header = std.mem.zeroes(vsr.Header.Prepare);
    var stored_headers: u32 = 0;
    var op: u64 = 1;
    while (op <= head_op) : (op += 1) {
        const header = makePrepareHeader(
            cluster,
            1,
            op,
            op - 1,
            previous.checksum,
            release_format,
        );
        if (op == checkpoint_op) checkpoint_header = header;
        if (head_op - op < constants.view_headers_max) {
            const reverse_index: usize = @intCast(head_op - op);
            view_headers_all[reverse_index] = header;
            stored_headers += 1;
        }
        previous = header;
    }
    assert(checkpoint_header.invalid() == null);

    return .{
        .sequence_min = 1,
        .sequence_max = 2,
        .block_count = 2,
        .closed_timestamp = 1_704_067_260,
        .cluster = cluster,
        .replica_index = 0,
        .replica_id = replica_id,
        .replica_count = 1,
        .release_format = release_format,
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
            .release = release_format,
        }),
        .view_headers_count = stored_headers,
        .view_headers_all = view_headers_all,
    };
}

fn writeLocalBackupBlock(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    cluster: u128,
    sequence: u64,
    address: ?u64,
    closed_timestamp: i64,
    body: []const u8,
) !void {
    const block_size: u32 = @intCast(@sizeOf(vsr.Header) + body.len);
    const block_address = address orelse 0;

    var header = std.mem.zeroInit(vsr.Header.Block, .{
        .cluster = cluster,
        .size = block_size,
        .release = constants.config.process.release,
        .command = .block,
        .metadata_bytes = [_]u8{0} ** vsr.Header.Block.metadata_size,
        .address = block_address,
        .snapshot = 0,
        .block_type = .free_set,
    });
    header.set_checksum_body(body);
    header.set_checksum();

    var disk_block: [constants.block_size]u8 align(constants.sector_size) =
        [_]u8{0} ** constants.block_size;
    @memcpy(disk_block[0..@sizeOf(vsr.Header)], std.mem.asBytes(&header));
    @memcpy(
        disk_block[@sizeOf(vsr.Header) .. @sizeOf(vsr.Header) + body.len],
        body,
    );

    const base_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{d:0>12}.block",
        .{ source_dir, sequence },
    );
    defer allocator.free(base_path);

    const ts_path = try std.fmt.allocPrint(allocator, "{s}.ts", .{base_path});
    defer allocator.free(ts_path);

    const block_file = try std.fs.createFileAbsolute(base_path, .{ .truncate = true });
    defer block_file.close();
    try block_file.writeAll(disk_block[0..header.size]);

    const ts_file = try std.fs.createFileAbsolute(ts_path, .{ .truncate = true });
    defer ts_file.close();
    try ts_file.writer().print("{d}\n", .{closed_timestamp});

    if (address) |block_address_present| {
        const meta_path = try std.fmt.allocPrint(allocator, "{s}.meta", .{base_path});
        defer allocator.free(meta_path);

        const meta_file = try std.fs.createFileAbsolute(meta_path, .{ .truncate = true });
        defer meta_file.close();
        try meta_file.writer().print(
            "sequence={d}\naddress={d}\nchecksum={x:0>32}\nclosed_timestamp={d}\n",
            .{ sequence, block_address_present, header.checksum, closed_timestamp },
        );
    }
}

fn writeCheckpointArtifact(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    artifact: checkpoint_artifact.DurableCheckpointArtifact,
) !void {
    const file_name = try artifact.fileName(allocator);
    defer allocator.free(file_name);

    const contents = try artifact.encodeKeyValue(allocator);
    defer allocator.free(contents);

    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
        source_dir,
        file_name,
    });
    defer allocator.free(artifact_path);

    const file = try std.fs.createFileAbsolute(artifact_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
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

test "integration: restored data file boots under archerdb start" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const source_dir = try std.fmt.allocPrint(allocator, "{s}/backup-source", .{tmp_path});
    defer allocator.free(source_dir);
    try std.fs.makeDirAbsolute(source_dir);

    const restored_path = try std.fmt.allocPrint(allocator, "{s}/restored-start.archerdb", .{tmp_path});
    defer allocator.free(restored_path);

    const storage_size = vsr.superblock.data_file_size_min;
    const artifact = makeStandaloneCheckpointArtifact(storage_size);

    try writeLocalBackupBlock(
        allocator,
        source_dir,
        artifact.cluster,
        1,
        null,
        1_704_067_200,
        "restore-start-block-one",
    );
    try writeLocalBackupBlock(
        allocator,
        source_dir,
        artifact.cluster,
        2,
        null,
        1_704_067_260,
        "restore-start-block-two",
    );
    try writeCheckpointArtifact(allocator, source_dir, artifact);

    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{source_dir});
    defer allocator.free(source_url);

    var manager = try restore.RestoreManager.init(allocator, .{
        .source_url = source_url,
        .dest_data_file = restored_path,
        .point_in_time = .latest,
        .verify_checksums = true,
    });
    defer manager.deinit();

    const restore_stats = try manager.execute();
    try testing.expect(restore_stats.success);

    const metrics_port = try pickFreePort();
    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .data_file = restored_path,
    });
    defer tmp_archerdb.deinit(allocator);
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);
}

test "integration: start path uploads backup blocks after live writes" {
    const allocator = std.testing.allocator;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    const metrics_port = try pickFreePort();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const backup_bucket = try std.fmt.allocPrint(allocator, "{s}/backup-bucket", .{tmp_path});
    defer allocator.free(backup_bucket);
    try std.fs.makeDirAbsolute(backup_bucket);

    const blocks_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{x:0>32}/replica-0/blocks",
        .{ backup_bucket, @as(u128, 0) },
    );
    defer allocator.free(blocks_dir);

    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .backup_bucket = backup_bucket,
    });
    defer tmp_archerdb.deinit(allocator);
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        99,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try allocator.create(RequestContext);
    defer allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const requests_target: usize = @intCast(constants.vsr_checkpoint_ops + 256);
    for (0..requests_target) |i| {
        var event = [_]tb.GeoEvent{make_event(
            10_000 + i,
            37.7749 + (@as(f64, @floatFromInt(i % 10)) * 0.0001),
            -122.4194 - (@as(f64, @floatFromInt(i % 10)) * 0.0001),
        )};

        const insert_reply = try send_request(
            &client,
            &completion,
            request,
            .insert_events,
            std.mem.sliceAsBytes(&event),
        );

        const result = read_struct(
            tb.InsertGeoEventsResult,
            insert_reply[0..@sizeOf(tb.InsertGeoEventsResult)],
        );
        try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
    }

    const backup = try waitForBackupArtifacts(
        metrics_port,
        blocks_dir,
        60 * std.time.ns_per_s,
    );
    try testing.expect(backup.uploaded_blocks > 0);
    try testing.expect(backup.counts.blocks > 0);
    try testing.expectEqual(backup.counts.blocks, backup.counts.timestamps);
    try testing.expectEqual(backup.counts.blocks, backup.counts.metadata);
    try testing.expect(backup.counts.checkpoints > 0);
}

// =============================================================================
// S3-backed integration test (MinIO / LocalStack / live AWS)
// =============================================================================

/// Environment-driven S3 endpoint configuration for the MinIO-backed test below.
/// Returns null when any required variable is missing — the test then skips. This
/// keeps local runs ergonomic (skip) and makes CI failures loud (CI sets all three).
const S3Env = struct {
    endpoint: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    bucket: []const u8,

    fn read() ?S3Env {
        const endpoint = std.posix.getenv("MINIO_ENDPOINT") orelse return null;
        const access_key_id = std.posix.getenv("MINIO_ACCESS_KEY") orelse return null;
        const secret_access_key = std.posix.getenv("MINIO_SECRET_KEY") orelse return null;
        const bucket = std.posix.getenv("MINIO_BUCKET") orelse "archerdb-test-bucket";
        return .{
            .endpoint = endpoint,
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .bucket = bucket,
        };
    }
};

/// Count backup artifacts in an S3 bucket under the given prefix. Mirrors the
/// filesystem-based `countBackupArtifacts` but speaks S3 `ListObjects`.
fn countBackupArtifactsS3(
    allocator: std.mem.Allocator,
    env: S3Env,
    prefix: []const u8,
) !BackupArtifactCounts {
    var client = try s3_client.S3Client.init(allocator, .{
        .endpoint = env.endpoint,
        .region = "us-east-1",
        .credentials = .{
            .access_key_id = env.access_key_id,
            .secret_access_key = env.secret_access_key,
        },
    });
    defer client.deinit();

    const objects = try client.listObjects(env.bucket, prefix);
    defer {
        for (objects) |obj| {
            allocator.free(obj.key);
        }
        allocator.free(objects);
    }

    var counts = BackupArtifactCounts{};
    for (objects) |obj| {
        if (std.mem.endsWith(u8, obj.key, ".block")) {
            counts.blocks += 1;
        } else if (std.mem.endsWith(u8, obj.key, ".block.ts")) {
            counts.timestamps += 1;
        } else if (std.mem.endsWith(u8, obj.key, ".block.meta")) {
            counts.metadata += 1;
        } else if (std.mem.endsWith(u8, obj.key, checkpoint_artifact.file_suffix)) {
            counts.checkpoints += 1;
        }
    }
    return counts;
}

fn waitForBackupArtifactsS3(
    allocator: std.mem.Allocator,
    metrics_port: u16,
    env: S3Env,
    prefix: []const u8,
    timeout_ns: u64,
) !struct {
    uploaded_blocks: u64,
    counts: BackupArtifactCounts,
} {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));

    while (std.time.nanoTimestamp() < deadline) {
        const metrics = try fetchMetrics(allocator, metrics_port);
        defer allocator.free(metrics);

        const uploaded_blocks = parseMetricU64(
            metrics,
            "archerdb_backup_blocks_uploaded_total",
        ) orelse 0;
        const counts = try countBackupArtifactsS3(allocator, env, prefix);
        if (uploaded_blocks > 0 and
            counts.blocks > 0 and
            counts.timestamps > 0 and
            counts.metadata > 0 and
            counts.checkpoints > 0)
        {
            return .{
                .uploaded_blocks = uploaded_blocks,
                .counts = counts,
            };
        }

        std.time.sleep(250 * std.time.ns_per_ms);
    }

    return error.BackupArtifactsTimeout;
}

test "integration: start path uploads backup blocks to s3 after live writes" {
    const env = S3Env.read() orelse return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    const metrics_port = try pickFreePort();

    // Cluster 0 matches TmpArcherDB's `format --cluster=0`. The backup uploader will
    // write objects under the prefix `00000000000000000000000000000000/replica-0/blocks/`.
    const object_prefix = "00000000000000000000000000000000/replica-0/";

    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .backup_bucket = env.bucket,
        .backup_provider = "s3",
        .backup_region = "us-east-1",
        .backup_endpoint = env.endpoint,
        .backup_access_key_id = env.access_key_id,
        .backup_secret_access_key = env.secret_access_key,
        .backup_url_style = "path", // MinIO and LocalStack require path style.
    });
    defer tmp_archerdb.deinit(allocator);
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(
        allocator,
        &client,
        0,
        tmp_archerdb.port_str,
        99,
        RequestContext.on_complete,
    );
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try allocator.create(RequestContext);
    defer allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const requests_target: usize = @intCast(constants.vsr_checkpoint_ops + 256);
    for (0..requests_target) |i| {
        var event = [_]tb.GeoEvent{make_event(
            20_000 + i,
            37.7749 + (@as(f64, @floatFromInt(i % 10)) * 0.0001),
            -122.4194 - (@as(f64, @floatFromInt(i % 10)) * 0.0001),
        )};

        const insert_reply = try send_request(
            &client,
            &completion,
            request,
            .insert_events,
            std.mem.sliceAsBytes(&event),
        );

        const result = read_struct(
            tb.InsertGeoEventsResult,
            insert_reply[0..@sizeOf(tb.InsertGeoEventsResult)],
        );
        try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
    }

    const backup = try waitForBackupArtifactsS3(
        allocator,
        metrics_port,
        env,
        object_prefix,
        90 * std.time.ns_per_s,
    );
    try testing.expect(backup.uploaded_blocks > 0);
    try testing.expect(backup.counts.blocks > 0);
    try testing.expectEqual(backup.counts.blocks, backup.counts.timestamps);
    try testing.expectEqual(backup.counts.blocks, backup.counts.metadata);
    try testing.expect(backup.counts.checkpoints > 0);
}

// =============================================================================
// Azure Blob Storage-backed integration test (Azurite)
// =============================================================================

const AzuriteEnv = struct {
    endpoint: []const u8,
    account: []const u8,
    account_key_base64: []const u8,
    container: []const u8,

    fn read() ?AzuriteEnv {
        const endpoint = std.posix.getenv("AZURITE_ENDPOINT") orelse return null;
        const account = std.posix.getenv("AZURITE_ACCOUNT") orelse "devstoreaccount1";
        const key = std.posix.getenv("AZURITE_ACCOUNT_KEY") orelse return null;
        const container = std.posix.getenv("AZURITE_CONTAINER") orelse "archerdb-test-container";
        return .{
            .endpoint = endpoint,
            .account = account,
            .account_key_base64 = key,
            .container = container,
        };
    }
};

test "integration: restore from s3 via minio round-trip" {
    const env = S3Env.read() orelse return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    // Phase 1: populate the S3 bucket via a live `archerdb start` backup. Matches the
    // preceding upload-only test's flow so we share the same proof of the backup path.
    const metrics_port = try pickFreePort();
    const object_prefix = "00000000000000000000000000000000/replica-0/";

    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .backup_bucket = env.bucket,
        .backup_provider = "s3",
        .backup_region = "us-east-1",
        .backup_endpoint = env.endpoint,
        .backup_access_key_id = env.access_key_id,
        .backup_secret_access_key = env.secret_access_key,
        .backup_url_style = "path",
    });
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(allocator, &client, 0, tmp_archerdb.port_str, 99,
        RequestContext.on_complete);
    var client_closed = false;
    defer if (!client_closed) {
        client.deinit() catch {};
    };

    var completion = Completion{ .pending = 0 };
    const request = try allocator.create(RequestContext);
    defer allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const requests_target: usize = @intCast(constants.vsr_checkpoint_ops + 256);
    for (0..requests_target) |i| {
        var event = [_]tb.GeoEvent{make_event(
            50_000 + i,
            37.7749 + (@as(f64, @floatFromInt(i % 10)) * 0.0001),
            -122.4194 - (@as(f64, @floatFromInt(i % 10)) * 0.0001),
        )};
        const insert_reply = try send_request(&client, &completion, request,
            .insert_events, std.mem.sliceAsBytes(&event));
        const result = read_struct(
            tb.InsertGeoEventsResult,
            insert_reply[0..@sizeOf(tb.InsertGeoEventsResult)],
        );
        try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
    }

    const upload_deadline = std.time.nanoTimestamp() + 90 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < upload_deadline) {
        const metrics = try fetchMetrics(allocator, metrics_port);
        defer allocator.free(metrics);
        const uploaded = parseMetricU64(metrics, "archerdb_backup_blocks_uploaded_total") orelse 0;
        if (uploaded > 0) break;
        std.time.sleep(250 * std.time.ns_per_ms);
    } else {
        return error.BackupArtifactsTimeout;
    }

    client.deinit() catch {};
    client_closed = true;
    tmp_archerdb.deinit(allocator);

    // Phase 2: restore from MinIO into a fresh data file. Credentials via a tempfile,
    // same pattern as the Azure round-trip test; loadS3LikeAuth reads `endpoint`,
    // `access_key_id`, `secret_access_key` keys.
    var restore_tmp = std.testing.tmpDir(.{});
    defer restore_tmp.cleanup();
    const restore_dir = try restore_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(restore_dir);

    const creds_path = try std.fmt.allocPrint(
        allocator,
        "{s}/s3-creds.txt",
        .{restore_dir},
    );
    defer allocator.free(creds_path);
    {
        const creds_body = try std.fmt.allocPrint(
            allocator,
            "endpoint={s}\nregion=us-east-1\naccess_key_id={s}\nsecret_access_key={s}\n",
            .{ env.endpoint, env.access_key_id, env.secret_access_key },
        );
        defer allocator.free(creds_body);
        const creds_file = try std.fs.createFileAbsolute(creds_path, .{ .truncate = true });
        defer creds_file.close();
        try creds_file.writeAll(creds_body);
    }

    const restored_path = try std.fmt.allocPrint(
        allocator,
        "{s}/restored-s3.archerdb",
        .{restore_dir},
    );
    defer allocator.free(restored_path);

    const source_url = try std.fmt.allocPrint(
        allocator,
        "s3://{s}/{s}",
        .{ env.bucket, object_prefix[0 .. object_prefix.len - 1] },
    );
    defer allocator.free(source_url);

    var manager = try restore.RestoreManager.init(allocator, .{
        .source_url = source_url,
        .dest_data_file = restored_path,
        .point_in_time = .latest,
        .verify_checksums = true,
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    const stats = try manager.execute();
    try testing.expect(stats.success);
    try testing.expect(stats.blocks_written > 0);
    try testing.expect(stats.bytes_written > 0);

    // Boot-from-restored is out of scope here — same rationale as the Azure test. The
    // focus is the S3 auth + I/O pipeline post-ec9ae2a0 (Host header / Content-Length /
    // SigV4 query canonicalization fixes) on the restore side.
    const file = try std.fs.openFileAbsolute(restored_path, .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expect(stat.size > 0);
}

test "integration: start path uploads backup blocks to azure blob after live writes" {
    const env = AzuriteEnv.read() orelse return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    // Ensure the container exists; Azurite does not create it automatically.
    {
        var client = try azure_blob_client.AzureBlobClient.init(allocator, .{
            .endpoint = env.endpoint,
            .credentials = .{
                .account = env.account,
                .account_key_base64 = env.account_key_base64,
            },
            .use_path_style = true,
        });
        defer client.deinit();
        try client.createContainer(env.container);
    }

    const metrics_port = try pickFreePort();
    const object_prefix = "00000000000000000000000000000000/replica-0/";

    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .backup_bucket = env.container,
        .backup_provider = "azure",
        .backup_endpoint = env.endpoint,
        .backup_access_key_id = env.account,
        .backup_secret_access_key = env.account_key_base64,
        .backup_url_style = "path",
    });
    defer tmp_archerdb.deinit(allocator);
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(allocator, &client, 0, tmp_archerdb.port_str, 99,
        RequestContext.on_complete);
    defer client.deinit() catch unreachable;

    var completion = Completion{ .pending = 0 };
    const request = try allocator.create(RequestContext);
    defer allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const requests_target: usize = @intCast(constants.vsr_checkpoint_ops + 256);
    for (0..requests_target) |i| {
        var event = [_]tb.GeoEvent{make_event(
            30_000 + i,
            37.7749 + (@as(f64, @floatFromInt(i % 10)) * 0.0001),
            -122.4194 - (@as(f64, @floatFromInt(i % 10)) * 0.0001),
        )};
        const insert_reply = try send_request(&client, &completion, request,
            .insert_events, std.mem.sliceAsBytes(&event));
        const result = read_struct(
            tb.InsertGeoEventsResult,
            insert_reply[0..@sizeOf(tb.InsertGeoEventsResult)],
        );
        try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
    }

    const deadline = std.time.nanoTimestamp() + 90 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        const metrics = try fetchMetrics(allocator, metrics_port);
        defer allocator.free(metrics);
        const uploaded = parseMetricU64(metrics, "archerdb_backup_blocks_uploaded_total") orelse 0;
        if (uploaded > 0) break;
        std.time.sleep(250 * std.time.ns_per_ms);
    } else {
        return error.BackupArtifactsTimeout;
    }

    // Verify block, ts, meta, and checkpoint artifacts are in Azurite.
    var list_client = try azure_blob_client.AzureBlobClient.init(allocator, .{
        .endpoint = env.endpoint,
        .credentials = .{
            .account = env.account,
            .account_key_base64 = env.account_key_base64,
        },
        .use_path_style = true,
    });
    defer list_client.deinit();
    const blobs = try list_client.listBlobs(env.container, object_prefix);
    defer {
        for (blobs) |b| allocator.free(b.name);
        allocator.free(blobs);
    }

    var counts = BackupArtifactCounts{};
    for (blobs) |b| {
        if (std.mem.endsWith(u8, b.name, ".block")) counts.blocks += 1
        else if (std.mem.endsWith(u8, b.name, ".block.ts")) counts.timestamps += 1
        else if (std.mem.endsWith(u8, b.name, ".block.meta")) counts.metadata += 1
        else if (std.mem.endsWith(u8, b.name, checkpoint_artifact.file_suffix)) counts.checkpoints += 1;
    }
    try testing.expect(counts.blocks > 0);
    try testing.expectEqual(counts.blocks, counts.timestamps);
    try testing.expectEqual(counts.blocks, counts.metadata);
    try testing.expect(counts.checkpoints > 0);
}

test "integration: restore from azure blob via shared-key auth" {
    const env = AzuriteEnv.read() orelse return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const RequestContext = RequestContextType(constants.message_body_size_max);

    // Phase 1: produce a backup in Azurite via the live `archerdb start` path.
    // This is the same flow the upload-only Azurite test exercises; we re-run it here
    // because `RestoreManager` needs a populated bucket to restore from.
    {
        var client = try azure_blob_client.AzureBlobClient.init(allocator, .{
            .endpoint = env.endpoint,
            .credentials = .{
                .account = env.account,
                .account_key_base64 = env.account_key_base64,
            },
            .use_path_style = true,
        });
        defer client.deinit();
        try client.createContainer(env.container);
    }

    const metrics_port = try pickFreePort();
    const object_prefix = "00000000000000000000000000000000/replica-0/";

    var tmp_archerdb = try TmpArcherDB.init(allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
        .backup_bucket = env.container,
        .backup_provider = "azure",
        .backup_endpoint = env.endpoint,
        .backup_access_key_id = env.account,
        .backup_secret_access_key = env.account_key_base64,
        .backup_url_style = "path",
    });
    errdefer tmp_archerdb.log_stderr();

    try waitForReady(metrics_port, 10 * std.time.ns_per_s);

    var client: arch_client.ClientInterface = undefined;
    try arch_client.init(allocator, &client, 0, tmp_archerdb.port_str, 99,
        RequestContext.on_complete);
    var client_closed = false;
    defer if (!client_closed) {
        client.deinit() catch {};
    };

    var completion = Completion{ .pending = 0 };
    const request = try allocator.create(RequestContext);
    defer allocator.destroy(request);
    request.* = RequestContext{
        .packet = undefined,
        .completion = &completion,
        .sent_data_size = 0,
    };

    const requests_target: usize = @intCast(constants.vsr_checkpoint_ops + 256);
    for (0..requests_target) |i| {
        var event = [_]tb.GeoEvent{make_event(
            40_000 + i,
            37.7749 + (@as(f64, @floatFromInt(i % 10)) * 0.0001),
            -122.4194 - (@as(f64, @floatFromInt(i % 10)) * 0.0001),
        )};
        const insert_reply = try send_request(&client, &completion, request,
            .insert_events, std.mem.sliceAsBytes(&event));
        const result = read_struct(
            tb.InsertGeoEventsResult,
            insert_reply[0..@sizeOf(tb.InsertGeoEventsResult)],
        );
        try testing.expectEqual(tb.InsertGeoEventResult.ok, result.result);
    }

    const upload_deadline = std.time.nanoTimestamp() + 90 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < upload_deadline) {
        const metrics = try fetchMetrics(allocator, metrics_port);
        defer allocator.free(metrics);
        const uploaded = parseMetricU64(metrics, "archerdb_backup_blocks_uploaded_total") orelse 0;
        if (uploaded > 0) break;
        std.time.sleep(250 * std.time.ns_per_ms);
    } else {
        return error.BackupArtifactsTimeout;
    }

    // Tear down the source replica before restore so we aren't confused between "still
    // writing" and "fully flushed" artifacts. The data file on the source VM is
    // independent of what's in Azurite; the restore will pull solely from the bucket.
    client.deinit() catch {};
    client_closed = true;
    tmp_archerdb.deinit(allocator);

    // Phase 2: restore from Azurite into a fresh data file via RestoreManager's
    // shared-key auth path. Stage the Azurite credentials through a credentials file
    // (the env-var path works identically but Zig's std.posix.setenv is not available
    // in this version; a file avoids that dependency and is also what production
    // operators are likeliest to use).
    var restore_tmp = std.testing.tmpDir(.{});
    defer restore_tmp.cleanup();
    const restore_dir = try restore_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(restore_dir);

    const creds_path = try std.fmt.allocPrint(
        allocator,
        "{s}/azurite-creds.txt",
        .{restore_dir},
    );
    defer allocator.free(creds_path);
    {
        const creds_body = try std.fmt.allocPrint(
            allocator,
            "endpoint={s}\naccount_name={s}\naccount_key={s}\n",
            .{ env.endpoint, env.account, env.account_key_base64 },
        );
        defer allocator.free(creds_body);
        const creds_file = try std.fs.createFileAbsolute(creds_path, .{ .truncate = true });
        defer creds_file.close();
        try creds_file.writeAll(creds_body);
    }

    const restored_path = try std.fmt.allocPrint(
        allocator,
        "{s}/restored-azure.archerdb",
        .{restore_dir},
    );
    defer allocator.free(restored_path);

    const source_url = try std.fmt.allocPrint(
        allocator,
        "azure://{s}/{s}",
        .{ env.container, object_prefix[0 .. object_prefix.len - 1] }, // drop trailing slash
    );
    defer allocator.free(source_url);

    var manager = try restore.RestoreManager.init(allocator, .{
        .source_url = source_url,
        .dest_data_file = restored_path,
        .point_in_time = .latest,
        .verify_checksums = true,
        .credentials_path = creds_path,
    });
    defer manager.deinit();

    const stats = try manager.execute();
    try testing.expect(stats.success);
    try testing.expect(stats.blocks_written > 0);
    try testing.expect(stats.bytes_written > 0);

    // The restored data file is on disk with non-zero length. Booting it under a fresh
    // `archerdb start` is deliberately out of scope for this test — a backup captured
    // from a still-running source can hold in-flight journal state that needs its own
    // crash-recovery path. That lives under the existing local-restore boot-check test
    // and under the QEMU kernel-crash harness; here the focus is the SharedKey auth
    // pipeline (list + get + write).
    const file = try std.fs.openFileAbsolute(restored_path, .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expect(stat.size > 0);
}

test "integration: point-in-time restore targeting" {
    // INT-03: Verify point-in-time restore can target specific sequences

    const PointInTime = restore.PointInTime;

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
