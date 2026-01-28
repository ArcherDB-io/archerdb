// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const fuzz = @import("../testing/fuzz.zig");
const segmented_array = @import("segmented_array.zig");

pub fn main(gpa: std.mem.Allocator, fuzz_args: fuzz.FuzzArgs) !void {
    if (fuzz_args.events_max != null) {
        try segmented_array.run_fuzz(gpa, fuzz_args.seed, .{
            .verify = true,
            .smoke = true,
        });
    } else {
        try segmented_array.run_fuzz(gpa, fuzz_args.seed, .{
            .verify = true,
            .smoke = false,
        });
    }
}
