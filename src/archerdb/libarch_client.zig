// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Entry point for exporting the `arch_client` library.
//! Used by language clients that rely on the shared or static library exposed by `arch_client.h`.
//! For an idiomatic Zig API, use `vsr.arch_client` directly instead.
const builtin = @import("builtin");
const std = @import("std");

pub const vsr = @import("vsr");
const exports = vsr.arch_client.exports;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = exports.Logging.application_logger,
};

comptime {
    if (!builtin.link_libc) {
        @compileError("Must be built with libc to export arch_client symbols.");
    }

    @export(&exports.init, .{ .name = "arch_client_init", .linkage = .strong });
    @export(&exports.init_echo, .{ .name = "arch_client_init_echo", .linkage = .strong });
    @export(&exports.submit, .{ .name = "arch_client_submit", .linkage = .strong });
    @export(&exports.deinit, .{ .name = "arch_client_deinit", .linkage = .strong });
    @export(
        &exports.completion_context,
        .{ .name = "arch_client_completion_context", .linkage = .strong },
    );
    @export(
        &exports.register_log_callback,
        .{ .name = "arch_client_register_log_callback", .linkage = .strong },
    );
    @export(
        &exports.init_parameters,
        .{ .name = "arch_client_init_parameters", .linkage = .strong },
    );
}
