// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");

const Shell = @import("../../shell.zig");
const TmpArcherDB = @import("../../testing/tmp_archerdb.zig");

pub fn tests(shell: *Shell, gpa: std.mem.Allocator) !void {
    try shell.exec_zig("build clients:rust -Drelease", .{});
    try shell.exec("cargo test --all", .{});
    try shell.exec("cargo fmt --check", .{});
    try shell.exec("cargo clippy -- -D clippy::all", .{});

    inline for (.{ "basic", "two-phase", "two-phase-many", "walkthrough" }) |sample| {
        try shell.pushd("./samples/" ++ sample);
        defer shell.popd();

        try shell.exec("cargo fmt --check", .{});
        try shell.exec("cargo clippy -- -D clippy::all", .{});

        var tmp_archerdb = try TmpArcherDB.init(gpa, .{
            .development = true,
        });
        defer tmp_archerdb.deinit(gpa);
        errdefer tmp_archerdb.log_stderr();

        try shell.env.put("ARCHERDB_ADDRESS", tmp_archerdb.port_str);
        try shell.exec("cargo run", .{});
    }
}

pub fn validate_release(shell: *Shell, gpa: std.mem.Allocator, options: struct {
    version: []const u8,
    archerdb: []const u8,
}) !void {
    _ = shell;
    _ = gpa;
    _ = options;
    // The Rust client is not yet published.

    // const tmp_dir = try shell.create_tmp_dir();
    // defer shell.cwd.deleteTree(tmp_dir) catch {};

    // try shell.pushd(tmp_dir);
    // defer shell.popd();

    // var tmp_archerdb = try TmpArcherDB.init(gpa, .{
    //     .development = true,
    //     .prebuilt = options.archerdb,
    // });
    // defer tmp_archerdb.deinit(gpa);
    // errdefer tmp_archerdb.log_stderr();

    // try shell.env.put("ARCHERDB_ADDRESS", tmp_archerdb.port_str);

    // // Create a new Rust project to test the published crate
    // try shell.exec("cargo init --name test_archerdb", .{});

    // // Add archerdb dependency to Cargo.toml
    // try shell.exec("cargo add archerdb@{version}", .{ .version = options.version });
    // try shell.exec("cargo add futures@0.3", .{});

    // try Shell.copy_path(
    //     shell.project_root,
    //     "src/clients/rust/samples/basic/src/main.rs",
    //     shell.cwd,
    //     "src/main.rs",
    // );
    // try shell.exec("cargo run", .{});
}

pub fn release_published_latest(shell: *Shell) ![]const u8 {
    _ = shell;
    return "unimplemented";
}
