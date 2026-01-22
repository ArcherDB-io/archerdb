// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const builtin = @import("builtin");
const std = @import("std");
const os = std.os;

const stdx = @import("stdx.zig");

const log = std.log.scoped(.mlock);

const MemoryLockError = error{memory_not_locked} || std.posix.UnexpectedError;

const mlockall_error = "Unable to lock pages in memory ({s})" ++
    " - kernel swap would otherwise bypass ArcherDB's storage fault tolerance. ";

/// Pin virtual memory pages allocated so far to physical pages in RAM, preventing the pages from
/// being swapped out and introducing storage error into memory, bypassing ECC RAM.
pub fn memory_lock_allocated(options: struct { allocated_size: usize }) MemoryLockError!void {
    _ = options;
    switch (builtin.os.tag) {
        .linux => try memory_lock_allocated_linux(),
        .macos => {
            // macOS has mlock() but not mlockall(). mlock() requires an address range which
            // would be difficult to gather for non-heap memory that is also faulted in,
            // such as the stack, globals, etc.
        },
        else => @compileError("memory_lock_allocated is not supported for this platform. ArcherDB requires Linux or macOS."),
    }
}

fn memory_lock_allocated_linux() MemoryLockError!void {
    // https://github.com/torvalds/linux/blob/v6.12/include/uapi/asm-generic/mman.h#L18-L20
    const MCL_CURRENT = 1; // Lock all currently mapped pages.
    const MCL_ONFAULT = 4; // Lock all pages faulted in (i.e. stack space).
    const result = os.linux.syscall1(.mlockall, MCL_CURRENT | MCL_ONFAULT);
    switch (os.linux.E.init(result)) {
        .SUCCESS => return,
        .AGAIN => log.warn(mlockall_error, .{"some addresses could not be locked"}),
        .NOMEM => log.warn(mlockall_error, .{"memory would exceed RLIMIT_MEMLOCK"}),
        .PERM => log.warn(mlockall_error, .{
            "insufficient privileges to lock memory",
        }),
        .INVAL => unreachable, // MCL_ONFAULT specified without MCL_CURRENT.
        else => |err| return stdx.unexpected_errno("mlockall", err),
    }
    return error.memory_not_locked;
}
