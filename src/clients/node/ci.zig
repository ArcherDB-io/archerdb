// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;

const Shell = @import("../../shell.zig");
const TmpArcherDB = @import("../../testing/tmp_archerdb.zig");

pub fn tests(shell: *Shell, gpa: std.mem.Allocator) !void {
    assert(shell.file_exists("package.json"));

    try shell.exec_zig("build clients:node -Drelease", .{});

    // Integration tests.

    // We need to build the archerdb-node library manually for samples/testers to work.
    try shell.exec("npm install", .{});

    for ([_][]const u8{ "test", "benchmark" }) |tester| {
        log.info("testing {s}s", .{tester});

        var tmp_archerdb = try TmpArcherDB.init(gpa, .{
            .development = true,
        });
        defer tmp_archerdb.deinit(gpa);
        errdefer tmp_archerdb.log_stderr();

        try shell.env.put("ARCHERDB_ADDRESS", tmp_archerdb.port_str);
        try shell.exec("node ./dist/{tester}", .{ .tester = tester });
    }

    inline for ([_][]const u8{ "basic", "two-phase", "two-phase-many", "walkthrough" }) |sample| {
        log.info("testing sample '{s}'", .{sample});

        try shell.pushd("./samples/" ++ sample);
        defer shell.popd();

        var tmp_archerdb = try TmpArcherDB.init(gpa, .{
            .development = true,
        });
        defer tmp_archerdb.deinit(gpa);
        errdefer tmp_archerdb.log_stderr();

        try shell.env.put("ARCHERDB_ADDRESS", tmp_archerdb.port_str);
        try shell.exec("npm install", .{});
        try shell.exec("node main.js", .{});
    }

    // Container smoke tests.
    if (builtin.target.os.tag == .linux) {
        try shell.exec("npm pack --quiet", .{});

        for ([_][]const u8{ "node:18", "node:18-alpine" }) |image| {
            log.info("testing docker image: '{s}'", .{image});

            try shell.exec(
                \\docker run
                \\--security-opt seccomp=unconfined
                \\--volume ./:/host
                \\{image}
                \\sh
                \\-c {script}
            , .{
                .image = image,
                .script =
                \\set -ex
                \\mkdir test-project && cd test-project
                \\npm install /host/archerdb-node-*.tgz
                \\node -e 'require("archerdb-node"); console.log("SUCCESS!")'
                ,
            });
        }
    }
}

pub fn validate_release(shell: *Shell, gpa: std.mem.Allocator, options: struct {
    version: []const u8,
    archerdb: []const u8,
}) !void {
    var tmp_archerdb = try TmpArcherDB.init(gpa, .{
        .development = true,
        .prebuilt = options.archerdb,
    });
    defer tmp_archerdb.deinit(gpa);
    errdefer tmp_archerdb.log_stderr();

    try shell.env.put("ARCHERDB_ADDRESS", tmp_archerdb.port_str);

    try shell.exec("npm install archerdb-node@{version}", .{
        .version = options.version,
    });

    try Shell.copy_path(
        shell.project_root,
        "src/clients/node/samples/basic/main.js",
        shell.cwd,
        "main.js",
    );
    try shell.exec("node main.js", .{});
}

pub fn release_published_latest(shell: *Shell) ![]const u8 {
    return try shell.exec_stdout("npm view archerdb-node version", .{});
}
