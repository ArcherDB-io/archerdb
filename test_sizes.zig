// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const topology = @import("src/topology.zig");
const archerdb = @import("src/archerdb.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("ShardInfo size: {} bytes\n", .{@sizeOf(topology.ShardInfo)});
    try stdout.print("TopologyResponse size: {} bytes\n", .{@sizeOf(topology.TopologyResponse)});
    try stdout.print("max_shards: {}\n", .{topology.max_shards});
    try stdout.print("message_body_size_max: {} bytes\n", .{@import("src/vsr.zig").constants.message_body_size_max});

    const op = archerdb.Operation.get_topology;
    try stdout.print("\nget_topology operation:\n", .{});
    try stdout.print("  event_size: {} bytes\n", .{op.event_size()});
    try stdout.print("  result_size: {} bytes\n", .{op.result_size()});
    try stdout.print("  result_max (batch_size_limit=1MiB): {}\n", .{op.result_max(1024 * 1024)});
    try stdout.print("  result_count_expected: 1\n", .{});
}
