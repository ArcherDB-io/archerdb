// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const mem = std.mem;
const constants = @import("../constants.zig");
const multiversion = @import("../multiversion.zig");
const Header = @import("../vsr/message_header.zig").Header;
const superblock = @import("../vsr/superblock.zig");

const Release = multiversion.Release;
const Members = [constants.members_max]u128;
const CheckpointState = superblock.SuperBlockHeader.CheckpointState;

pub const file_prefix = "checkpoint-";
pub const file_suffix = ".ckpt";
pub const format_version = "archerdb-checkpoint-v1";

pub const ArtifactError = error{
    InvalidArtifact,
    MissingField,
    UnsupportedVersion,
};

pub const DurableCheckpointArtifact = struct {
    sequence_min: u64,
    sequence_max: u64,
    block_count: u64,
    closed_timestamp: i64,
    cluster: u128,
    replica_index: u8,
    replica_id: u128,
    replica_count: u8,
    release_format: Release,
    sharding_strategy: u8,
    members: Members,
    commit_max: u64,
    sync_op_min: u64,
    sync_op_max: u64,
    log_view: u32,
    view: u32,
    checkpoint: CheckpointState,
    view_headers_count: u32,
    view_headers_all: [constants.view_headers_max]Header.Prepare,

    pub fn fromWorkingHeader(
        working: anytype,
        replica_index: u8,
        sequence_min: u64,
        sequence_max: u64,
        block_count: u64,
        closed_timestamp: i64,
    ) DurableCheckpointArtifact {
        return .{
            .sequence_min = sequence_min,
            .sequence_max = sequence_max,
            .block_count = block_count,
            .closed_timestamp = closed_timestamp,
            .cluster = working.cluster,
            .replica_index = replica_index,
            .replica_id = working.vsr_state.replica_id,
            .replica_count = working.vsr_state.replica_count,
            .release_format = working.release_format,
            .sharding_strategy = working.sharding_strategy,
            .members = working.vsr_state.members,
            .commit_max = working.vsr_state.commit_max,
            .sync_op_min = working.vsr_state.sync_op_min,
            .sync_op_max = working.vsr_state.sync_op_max,
            .log_view = working.vsr_state.log_view,
            .view = working.vsr_state.view,
            .checkpoint = working.vsr_state.checkpoint,
            .view_headers_count = working.view_headers_count,
            .view_headers_all = working.view_headers_all,
        };
    }

    pub fn checkpointOp(self: *const DurableCheckpointArtifact) u64 {
        return self.checkpoint.header.op;
    }

    pub fn fileName(self: *const DurableCheckpointArtifact, allocator: mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            file_prefix ++ "{d:0>12}" ++ file_suffix,
            .{self.sequence_max},
        );
    }

    pub fn encodeKeyValue(
        self: *const DurableCheckpointArtifact,
        allocator: mem.Allocator,
    ) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        const writer = output.writer();
        try writer.print("format={s}\n", .{format_version});
        try writer.print("sequence_min={d}\n", .{self.sequence_min});
        try writer.print("sequence_max={d}\n", .{self.sequence_max});
        try writer.print("block_count={d}\n", .{self.block_count});
        try writer.print("closed_timestamp={d}\n", .{self.closed_timestamp});
        try writer.print("cluster={x:0>32}\n", .{self.cluster});
        try writer.print("replica_index={d}\n", .{self.replica_index});
        try writer.print("replica_id={x:0>32}\n", .{self.replica_id});
        try writer.print("replica_count={d}\n", .{self.replica_count});
        try writer.print("release_format={d}\n", .{self.release_format.value});
        try writer.print("sharding_strategy={d}\n", .{self.sharding_strategy});
        try writer.print("commit_max={d}\n", .{self.commit_max});
        try writer.print("sync_op_min={d}\n", .{self.sync_op_min});
        try writer.print("sync_op_max={d}\n", .{self.sync_op_max});
        try writer.print("log_view={d}\n", .{self.log_view});
        try writer.print("view={d}\n", .{self.view});
        try writer.print("checkpoint_op={d}\n", .{self.checkpointOp()});
        try writer.print(
            "members_hex={s}\n",
            .{std.fmt.fmtSliceHexLower(std.mem.asBytes(&self.members))},
        );
        try writer.print(
            "checkpoint_state_hex={s}\n",
            .{std.fmt.fmtSliceHexLower(std.mem.asBytes(&self.checkpoint))},
        );
        try writer.print("view_headers_count={d}\n", .{self.view_headers_count});
        try writer.print(
            "view_headers_hex={s}\n",
            .{
                std.fmt.fmtSliceHexLower(
                    std.mem.sliceAsBytes(self.view_headers_all[0..self.view_headers_count]),
                ),
            },
        );

        return output.toOwnedSlice();
    }

    pub fn parseKeyValue(contents: []const u8) ArtifactError!DurableCheckpointArtifact {
        const format = try getRequired(contents, "format");
        if (!mem.eql(u8, format, format_version)) return error.UnsupportedVersion;

        var members_bytes: [@sizeOf(Members)]u8 = undefined;
        const members_hex = try getRequired(contents, "members_hex");
        if (members_hex.len != members_bytes.len * 2) return error.InvalidArtifact;
        _ = std.fmt.hexToBytes(&members_bytes, members_hex) catch return error.InvalidArtifact;
        const members = mem.bytesAsValue(Members, &members_bytes).*;

        var checkpoint_bytes: [@sizeOf(CheckpointState)]u8 = undefined;
        const checkpoint_hex = try getRequired(contents, "checkpoint_state_hex");
        if (checkpoint_hex.len != checkpoint_bytes.len * 2) return error.InvalidArtifact;
        _ = std.fmt.hexToBytes(&checkpoint_bytes, checkpoint_hex) catch
            return error.InvalidArtifact;
        const checkpoint = mem.bytesAsValue(CheckpointState, &checkpoint_bytes).*;

        const view_headers_count = try parseU32(contents, "view_headers_count");
        if (view_headers_count > constants.view_headers_max) return error.InvalidArtifact;

        var view_headers_all: [constants.view_headers_max]Header.Prepare =
            @splat(mem.zeroes(Header.Prepare));
        const view_headers_hex = try getRequired(contents, "view_headers_hex");
        const expected_view_headers_hex_len =
            @as(usize, view_headers_count) * @sizeOf(Header.Prepare) * 2;
        if (view_headers_hex.len != expected_view_headers_hex_len) return error.InvalidArtifact;
        _ = std.fmt.hexToBytes(
            std.mem.sliceAsBytes(view_headers_all[0..view_headers_count]),
            view_headers_hex,
        ) catch return error.InvalidArtifact;

        const artifact = DurableCheckpointArtifact{
            .sequence_min = try parseU64(contents, "sequence_min"),
            .sequence_max = try parseU64(contents, "sequence_max"),
            .block_count = try parseU64(contents, "block_count"),
            .closed_timestamp = try parseI64(contents, "closed_timestamp"),
            .cluster = try parseU128Hex(contents, "cluster"),
            .replica_index = try parseU8(contents, "replica_index"),
            .replica_id = try parseU128Hex(contents, "replica_id"),
            .replica_count = try parseU8(contents, "replica_count"),
            .release_format = .{ .value = try parseU32(contents, "release_format") },
            .sharding_strategy = try parseU8(contents, "sharding_strategy"),
            .members = members,
            .commit_max = try parseU64(contents, "commit_max"),
            .sync_op_min = try parseU64(contents, "sync_op_min"),
            .sync_op_max = try parseU64(contents, "sync_op_max"),
            .log_view = try parseU32(contents, "log_view"),
            .view = try parseU32(contents, "view"),
            .checkpoint = checkpoint,
            .view_headers_count = view_headers_count,
            .view_headers_all = view_headers_all,
        };

        const checkpoint_op = try parseU64(contents, "checkpoint_op");
        if (checkpoint_op != artifact.checkpoint.header.op) return error.InvalidArtifact;
        if (artifact.block_count > 0 and artifact.sequence_max < artifact.sequence_min) {
            return error.InvalidArtifact;
        }

        return artifact;
    }
};

pub fn isCheckpointFile(name: []const u8) bool {
    return parseSequenceMaxFromFileName(name) != null;
}

pub fn parseSequenceMaxFromFileName(name: []const u8) ?u64 {
    if (!mem.startsWith(u8, name, file_prefix)) return null;
    if (!mem.endsWith(u8, name, file_suffix)) return null;

    const digits = name[file_prefix.len .. name.len - file_suffix.len];
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

fn getRequired(contents: []const u8, key: []const u8) ArtifactError![]const u8 {
    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        const equals = mem.indexOfScalar(u8, line, '=') orelse continue;
        const line_key = mem.trim(u8, line[0..equals], " \t\r\n");
        if (!mem.eql(u8, line_key, key)) continue;
        return mem.trim(u8, line[equals + 1 ..], " \t\r\n");
    }
    return error.MissingField;
}

fn parseU8(contents: []const u8, key: []const u8) ArtifactError!u8 {
    return std.fmt.parseInt(u8, try getRequired(contents, key), 10) catch
        return error.InvalidArtifact;
}

fn parseU32(contents: []const u8, key: []const u8) ArtifactError!u32 {
    return std.fmt.parseInt(u32, try getRequired(contents, key), 10) catch
        return error.InvalidArtifact;
}

fn parseU64(contents: []const u8, key: []const u8) ArtifactError!u64 {
    return std.fmt.parseInt(u64, try getRequired(contents, key), 10) catch
        return error.InvalidArtifact;
}

fn parseI64(contents: []const u8, key: []const u8) ArtifactError!i64 {
    return std.fmt.parseInt(i64, try getRequired(contents, key), 10) catch
        return error.InvalidArtifact;
}

fn parseU128Hex(contents: []const u8, key: []const u8) ArtifactError!u128 {
    return std.fmt.parseInt(u128, try getRequired(contents, key), 16) catch
        return error.InvalidArtifact;
}

test "DurableCheckpointArtifact: encode/decode roundtrip" {
    const allocator = std.testing.allocator;

    var members = std.mem.zeroes(Members);
    members[0] = 0x100;
    members[1] = 0x200;

    var view_headers_all: [constants.view_headers_max]Header.Prepare =
        @splat(mem.zeroes(Header.Prepare));
    view_headers_all[0] = std.mem.zeroInit(Header.Prepare, .{
        .cluster = 0xabc,
        .view = 7,
        .release = Release.minimum,
        .command = .prepare,
        .op = 129,
        .commit = 128,
        .operation = .noop,
    });

    const artifact = DurableCheckpointArtifact{
        .sequence_min = 123,
        .sequence_max = 148,
        .block_count = 26,
        .closed_timestamp = 1_704_067_200,
        .cluster = 0xabc,
        .replica_index = 1,
        .replica_id = 0x200,
        .replica_count = 3,
        .release_format = Release.minimum,
        .sharding_strategy = 2,
        .members = members,
        .commit_max = 140,
        .sync_op_min = 128,
        .sync_op_max = 144,
        .log_view = 7,
        .view = 7,
        .checkpoint = std.mem.zeroInit(CheckpointState, .{
            .header = std.mem.zeroInit(Header.Prepare, .{
                .cluster = 0xabc,
                .view = 7,
                .release = Release.minimum,
                .command = .prepare,
                .op = 128,
                .commit = 128,
                .operation = .noop,
            }),
            .manifest_block_count = 2,
            .storage_size = 8192,
            .release = Release.minimum,
        }),
        .view_headers_count = 1,
        .view_headers_all = view_headers_all,
    };

    const encoded = try artifact.encodeKeyValue(allocator);
    defer allocator.free(encoded);

    const parsed = try DurableCheckpointArtifact.parseKeyValue(encoded);
    try std.testing.expectEqual(artifact.sequence_min, parsed.sequence_min);
    try std.testing.expectEqual(artifact.sequence_max, parsed.sequence_max);
    try std.testing.expectEqual(artifact.block_count, parsed.block_count);
    try std.testing.expectEqual(artifact.closed_timestamp, parsed.closed_timestamp);
    try std.testing.expectEqual(artifact.cluster, parsed.cluster);
    try std.testing.expectEqual(artifact.replica_index, parsed.replica_index);
    try std.testing.expectEqual(artifact.replica_id, parsed.replica_id);
    try std.testing.expectEqual(artifact.replica_count, parsed.replica_count);
    try std.testing.expectEqual(artifact.release_format.value, parsed.release_format.value);
    try std.testing.expectEqual(artifact.sharding_strategy, parsed.sharding_strategy);
    try std.testing.expectEqual(artifact.commit_max, parsed.commit_max);
    try std.testing.expectEqual(artifact.sync_op_min, parsed.sync_op_min);
    try std.testing.expectEqual(artifact.sync_op_max, parsed.sync_op_max);
    try std.testing.expectEqual(artifact.log_view, parsed.log_view);
    try std.testing.expectEqual(artifact.view, parsed.view);
    try std.testing.expectEqual(artifact.view_headers_count, parsed.view_headers_count);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&artifact.members), std.mem.asBytes(&parsed.members));
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&artifact.checkpoint),
        std.mem.asBytes(&parsed.checkpoint),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(artifact.view_headers_all[0..artifact.view_headers_count]),
        std.mem.sliceAsBytes(parsed.view_headers_all[0..parsed.view_headers_count]),
    );
}
