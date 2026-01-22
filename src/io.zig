// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

const IO_Linux = @import("io/linux.zig").IO;
const IO_Darwin = @import("io/darwin.zig").IO;

pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    else => @compileError("IO is not supported for this platform. ArcherDB requires Linux or macOS."),
};

pub const DirectIO = enum {
    direct_io_required,
    direct_io_optional,
    direct_io_disabled,
};

pub fn buffer_limit(buffer_len: usize) usize {
    // Linux limits how much may be written in a `pwrite()/pread()` call, which is `0x7ffff000` on
    // both 64-bit and 32-bit systems, due to using a signed C int as the return value, as well as
    // stuffing the errno codes into the last `4096` values.
    // Darwin limits writes to `0x7fffffff` bytes, more than that returns `EINVAL`.
    const limit: usize = switch (builtin.target.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => @compileError("buffer_limit is not supported for this platform. ArcherDB requires Linux or macOS."),
    };
    return @min(limit, buffer_len);
}
