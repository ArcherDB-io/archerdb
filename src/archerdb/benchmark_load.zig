// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! ArcherDB Benchmark Entry Point
//!
//! This module forwards to the geospatial benchmark implementation.
//! ArcherDB is a geospatial-only database.

const std = @import("std");
const vsr = @import("vsr");
const IO = vsr.io.IO;
const Time = vsr.time.Time;
const cli = @import("./cli.zig");
const geo_benchmark_load = @import("geo_benchmark_load.zig");

/// Main benchmark entry point - routes to geospatial benchmark.
pub fn main(
    allocator: std.mem.Allocator,
    io: *IO,
    time: Time,
    addresses: []const std.net.Address,
    cli_args: *const cli.Command.Benchmark,
) !void {
    return geo_benchmark_load.main(allocator, io, time, addresses, cli_args);
}
