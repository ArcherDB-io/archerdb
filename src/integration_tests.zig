// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Integration tests for ArcherDB. Although the term is not particularly well-defined, here
//! it means a specific thing:
//!
//!   * the test binary itself doesn't contain any code from ArcherDB,
//!   * but it has access to a pre-build `./archerdb` binary.
//!
//! All the testing is done through interacting with a separate ArcherDB process.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;
const vsr = @import("vsr.zig");

const Shell = @import("./shell.zig");
const Snap = stdx.Snap;
const snap = Snap.snap_fn("src");
const TmpArcherDB = @import("./testing/tmp_archerdb.zig");

const stdx = @import("stdx");
const ratio = stdx.PRNG.ratio;

const vortex_exe: []const u8 = @import("test_options").vortex_exe;
const archerdb: []const u8 = @import("test_options").archerdb_exe;
const archerdb_past: []const u8 = @import("test_options").archerdb_exe_past;
const skip_upgrade: bool = @import("test_options").skip_upgrade;

comptime {
    _ = @import("clients/c/arch_client_header_test.zig");
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

test "repl integration" {
    const Context = struct {
        const Context = @This();

        shell: *Shell,
        archerdb_exe: []const u8,
        tmp_archerdb: TmpArcherDB,

        fn init() !Context {
            const shell = try Shell.create(std.testing.allocator);
            errdefer shell.destroy();

            var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
                .development = true,
                .prebuilt = archerdb,
            });
            errdefer tmp_archerdb.deinit(std.testing.allocator);

            return Context{
                .shell = shell,
                .archerdb_exe = archerdb,
                .tmp_archerdb = tmp_archerdb,
            };
        }

        fn deinit(context: *Context) void {
            context.tmp_archerdb.deinit(std.testing.allocator);
            context.shell.destroy();
            context.* = undefined;
        }

        fn repl_command(context: *Context, command: []const u8) ![]const u8 {
            return try context.shell.exec_stdout(
                \\{archerdb} repl --cluster=0 --addresses={addresses} --command={command}
            , .{
                .archerdb = context.archerdb_exe,
                .addresses = context.tmp_archerdb.port_str,
                .command = command,
            });
        }

        fn check(context: *Context, command: []const u8, want: Snap) !void {
            const got = try context.repl_command(command);
            try want.diff(got);
        }
    };

    var context = try Context.init();
    defer context.deinit();

    // Insert a geo event for entity 100 at NYC coordinates
    try context.check(
        "insert_events entity_id=100 lat_nano=40712800000000000 " ++
            "lon_nano=-74006000000000000 group_id=1",
        snap(@src(), ""),
    );

    // Insert another event for the same entity
    try context.check(
        \\insert_events entity_id=100 lat_nano=40714000000000000 lon_nano=-74005000000000000
        \\  group_id=1 velocity_mms=5000
    , snap(@src(), ""));

    // Query events by UUID (entity_id)
    try context.check(
        \\query_uuid entity_id=100
    , snap(@src(), ""));

    // Query latest events globally
    try context.check(
        \\query_latest limit=10
    , snap(@src(), ""));
}

test "benchmark/inspect smoke" {
    const data_file = data_file: {
        var random_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const random_suffix: [8]u8 = std.fmt.bytesToHex(random_bytes, .lower);
        break :data_file "0_0-" ++ random_suffix ++ ".archerdb.benchmark";
    };
    defer std.fs.cwd().deleteFile(data_file) catch {};

    const trace_file = data_file ++ ".json";
    defer std.fs.cwd().deleteFile(trace_file) catch {};

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{archerdb} benchmark" ++
            " --event-count=10_000" ++
            " --event-batch-size=10" ++
            " --validate" ++
            " --trace={trace_file}" ++
            " --statsd=127.0.0.1:65535" ++
            " --file={data_file}",
        .{
            .archerdb = archerdb,
            .trace_file = trace_file,
            .data_file = data_file,
        },
    );

    inline for (.{
        "{archerdb} inspect constants",
        "{archerdb} inspect metrics",
    }) |command| {
        log.debug("{s}", .{command});
        try shell.exec(command, .{ .archerdb = archerdb });
    }

    inline for (.{
        "{archerdb} inspect superblock              {path}",
        "{archerdb} inspect wal --slot=0            {path}",
        "{archerdb} inspect replies                 {path}",
        "{archerdb} inspect replies --slot=0        {path}",
        "{archerdb} inspect grid                    {path}",
        "{archerdb} inspect manifest                {path}",
        "{archerdb} inspect tables --tree=geo_events {path}",
        "{archerdb} inspect integrity               {path}",
    }) |command| {
        log.debug("{s}", .{command});

        try shell.exec(
            command,
            .{ .archerdb = archerdb, .path = data_file },
        );
    }

    // Corrupt the data file, and ensure the integrity check fails. Use the WAL headers zone so the
    // check stays fast even when the grid is large.
    const offset = vsr.Zone.wal_headers.start();

    {
        const file = try std.fs.cwd().openFile(data_file, .{ .mode = .read_write });
        defer file.close();

        var prng = stdx.PRNG.from_seed_testing();
        var random_bytes: [256]u8 = undefined;
        prng.fill(&random_bytes);

        try file.pwriteAll(&random_bytes, offset);
    }

    // `shell.exec` assumes that success is a zero exit code; but in this case the test expects
    // corruption to be found and wants to assert a non-zero exit code.
    var child = std.process.Child.init(
        &.{ archerdb, "inspect", "integrity", "--skip-client-replies", "--skip-grid", data_file },
        std.testing.allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited, .Signal => |value| try std.testing.expect(value != 0),
        else => unreachable,
    }
}

test "metrics endpoint includes index health metrics" {
    const metrics_port = try pickFreePort();

    var tmp_archerdb = try TmpArcherDB.init(std.testing.allocator, .{
        .development = true,
        .prebuilt = archerdb,
        .metrics_port = metrics_port,
        .metrics_bind = "127.0.0.1",
    });
    defer tmp_archerdb.deinit(std.testing.allocator);

    const response = try fetchMetrics(std.testing.allocator, metrics_port);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "archerdb_index_entries_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "archerdb_index_memory_bytes") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, response, "archerdb_index_lookup_latency_seconds") != null,
    );
}

test "help/version smoke" {
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    // The substring is chosen to be mostly stable, but from (near) the end of the output, to catch
    // a missed buffer flush.
    inline for (.{
        .{ .command = "{archerdb} --help", .substring = "archerdb repl" },
        .{ .command = "{archerdb} inspect --help", .substring = "tables --tree" },
        .{ .command = "{archerdb} version", .substring = "ArcherDB version" },
        .{ .command = "{archerdb} version --verbose", .substring = "process.aof_recovery=" },
    }) |check| {
        const output = try shell.exec_stdout(check.command, .{ .archerdb = archerdb });
        try std.testing.expect(output.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, output, check.substring) != null);
    }
}

test "in-place upgrade" {
    // Smoke test that in-place upgrades work.
    //
    // Starts a cluster of three replicas using the previous release of ArcherDB and then
    // replaces the binaries on disk with a new version.
    //
    // Against this upgrading cluster, we are running a benchmark load and checking that it finishes
    // with a zero status.
    //
    // To spice things up, replicas are periodically killed and restarted.

    if (skip_upgrade) {
        return error.SkipZigTest;
    }

    if (builtin.target.os.tag == .windows) {
        return error.SkipZigTest; // Coming soon!
    }

    const replica_count = TmpCluster.replica_count;

    var cluster = try TmpCluster.init();
    defer cluster.deinit();

    for (0..replica_count) |replica_index| {
        try cluster.replica_install(replica_index, .past);
        try cluster.replica_format(replica_index);
    }
    try cluster.workload_start(.{ .event_count = 2_000_000 });

    for (0..replica_count) |replica_index| {
        try cluster.replica_spawn(replica_index);
    }

    const ticks_max = 50;
    var upgrade_tick: [replica_count]u8 = @splat(0);
    for (0..replica_count) |replica_index| {
        upgrade_tick[replica_index] = cluster.prng.int_inclusive(u8, ticks_max - 1);
    }

    for (0..ticks_max) |tick| {
        std.time.sleep(2 * std.time.ns_per_s);

        for (0..replica_count) |replica_index| {
            if (tick == upgrade_tick[replica_index]) {
                assert(!cluster.replica_upgraded[replica_index]);
                try cluster.replica_upgrade(replica_index);
                assert(cluster.replica_upgraded[replica_index]);
            }
        }

        const replica_index = cluster.prng.index(cluster.replicas);
        const crash = cluster.prng.chance(ratio(1, 4));
        const restart = cluster.prng.chance(ratio(1, 2));

        if (cluster.replicas[replica_index] == null and restart) {
            try cluster.replica_spawn(replica_index);
        } else if (cluster.replicas[replica_index] != null and crash) {
            try cluster.replica_kill(replica_index);
        }
    }

    for (0..replica_count) |replica_index| {
        assert(cluster.replica_upgraded[replica_index]);
        if (cluster.replicas[replica_index] == null) {
            try cluster.replica_spawn(replica_index);
        }
    }

    cluster.workload_finish();
}

test "recover smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const replica_count = TmpCluster.replica_count;

    var cluster = try TmpCluster.init();
    defer cluster.deinit();

    for (0..replica_count) |replica_index| {
        try cluster.replica_install(replica_index, .past);
    }
    try cluster.replica_format(0);
    try cluster.replica_format(1);
    try cluster.replica_format(2);
    try cluster.workload_start(.{ .event_count = 200_000 });
    try cluster.replica_spawn(0);
    try cluster.replica_spawn(1);
    try cluster.replica_spawn(2);
    std.time.sleep(2 * std.time.ns_per_s);

    try cluster.replica_kill(2);
    try cluster.replica_reformat(2);

    try cluster.replica_kill(1);
    try cluster.replica_spawn(2);
    cluster.workload_finish();
}

test "vortex smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{vortex_exe} supervisor --test-duration=1s --replica-count=1",
        .{ .vortex_exe = vortex_exe },
    );
}

// ============================================================================
// v2.0 Multi-Region Replication Integration Tests
// ============================================================================

// NOTE: Multi-region replication tests require:
// - --region-role=primary|follower CLI flags
// - WAL shipping infrastructure
// - Follower read-only enforcement (error 213)
//
// These tests verify the Phase 1 v2.0 multi-region features:
// - Primary region accepts writes
// - Follower region rejects writes with FOLLOWER_READ_ONLY (213)
// - Follower region can serve reads
// - Replication lag metrics are exposed
//
// To run: zig build test:integration -- --test-filter "primary-follower"

const TmpCluster = struct {
    const replica_count = 3;
    // The test uses this hard-coded address, so only one instance can be running at a time.
    const addresses = "127.0.0.1:7121,127.0.0.1:7122,127.0.0.1:7123";

    shell: *Shell,
    tmp: []const u8,

    prng: stdx.PRNG,
    replicas: [replica_count]?std.process.Child = @splat(null),
    replica_exe: [replica_count][]const u8,
    replica_datafile: [replica_count][]const u8,
    replica_upgraded: [replica_count]bool = @splat(false),

    workload_thread: ?std.Thread = null,
    workload_exit_ok: bool = false,

    fn init() !TmpCluster {
        const shell = try Shell.create(std.testing.allocator);
        errdefer shell.destroy();

        const tmp = try shell.fmt("./.zig-cache/tmp/{}", .{std.crypto.random.int(u64)});
        errdefer shell.cwd.deleteTree(tmp) catch {};

        try shell.cwd.makePath(tmp);

        var replica_exe: [replica_count][]const u8 = @splat("");
        var replica_datafile: [replica_count][]const u8 = @splat("");
        for (0..replica_count) |replica_index| {
            replica_exe[replica_index] = try shell.fmt("{s}/archerdb{}{s}", .{
                tmp,
                replica_index,
                builtin.target.exeFileExt(),
            });
            replica_datafile[replica_index] = try shell.fmt("{s}/0_{}.archerdb", .{
                tmp,
                replica_index,
            });
        }

        const prng = stdx.PRNG.from_seed_testing();
        return .{
            .shell = shell,
            .tmp = tmp,
            .prng = prng,
            .replica_exe = replica_exe,
            .replica_datafile = replica_datafile,
        };
    }

    fn deinit(cluster: *TmpCluster) void {
        // Sadly, killing workload process is not easy, so, in case of an error, we'll wait
        // for full timeout.
        if (cluster.workload_thread) |workload_thread| {
            workload_thread.join();
        }

        for (&cluster.replicas) |*replica| {
            if (replica.*) |*alive| {
                _ = alive.kill() catch {};
            }
        }

        cluster.shell.cwd.deleteTree(cluster.tmp) catch {};
        cluster.shell.destroy();
        cluster.* = undefined;
    }

    fn replica_install(
        cluster: *TmpCluster,
        replica_index: usize,
        version: enum { past, current },
    ) !void {
        const destination = cluster.replica_exe[replica_index];
        try cluster.shell.cwd.copyFile(
            switch (version) {
                .past => if (skip_upgrade) archerdb else archerdb_past,
                .current => archerdb,
            },
            cluster.shell.cwd,
            destination,
            .{},
        );
        try cluster.shell.file_make_executable(destination);
    }

    fn replica_format(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);

        try cluster.shell.exec(
            \\{archerdb} format --cluster=0 --replica={replica} --replica-count=3 {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .replica = replica_index,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_reformat(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);

        cluster.shell.cwd.deleteFile(cluster.replica_datafile[replica_index]) catch {};

        try cluster.shell.exec(
            \\{archerdb} recover
            \\    --cluster=0
            \\    --replica={replica}
            \\    --replica-count=3
            \\    --addresses={addresses}
            \\    {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .replica = replica_index,
            .addresses = addresses,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_upgrade(cluster: *TmpCluster, replica_index: usize) !void {
        assert(!cluster.replica_upgraded[replica_index]);

        const upgrade_requires_restart = builtin.os.tag != .linux;
        if (upgrade_requires_restart) {
            if (cluster.replicas[replica_index] != null) {
                try cluster.replica_kill(replica_index);
            }
            assert(cluster.replicas[replica_index] == null);
        }

        cluster.shell.cwd.deleteFile(cluster.replica_exe[replica_index]) catch {};
        try cluster.replica_install(replica_index, .current);
        cluster.replica_upgraded[replica_index] = true;

        if (upgrade_requires_restart) {
            assert(cluster.replicas[replica_index] == null);
            try cluster.replica_spawn(replica_index);
            assert(cluster.replicas[replica_index] != null);
        }
    }

    fn replica_spawn(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] == null);
        cluster.replicas[replica_index] = try cluster.shell.spawn(.{},
            \\{archerdb} start --addresses={addresses} {datafile}
        , .{
            .archerdb = cluster.replica_exe[replica_index],
            .addresses = addresses,
            .datafile = cluster.replica_datafile[replica_index],
        });
    }

    fn replica_kill(cluster: *TmpCluster, replica_index: usize) !void {
        assert(cluster.replicas[replica_index] != null);
        _ = cluster.replicas[replica_index].?.kill() catch {};
        cluster.replicas[replica_index] = null;
    }

    const WorkloadStartOptions = struct {
        event_count: usize,
    };

    fn workload_start(cluster: *TmpCluster, options: WorkloadStartOptions) !void {
        assert(cluster.workload_thread == null);
        assert(!cluster.workload_exit_ok);
        // Run workload in a separate thread, to collect it's stdout and stderr, and to
        // forcefully terminate it after 10 minutes.
        cluster.workload_thread = try std.Thread.spawn(.{}, struct {
            fn thread_main(
                workload_exit_ok_ptr: *bool,
                archerdb_path: []const u8,
                benchmark_options: WorkloadStartOptions,
            ) !void {
                const shell = try Shell.create(std.testing.allocator);
                defer shell.destroy();

                try shell.exec_options(.{ .timeout = .minutes(10) },
                    \\{archerdb} benchmark
                    \\    --print-batch-timings
                    \\    --event-count={event_count}
                    \\    --addresses={addresses}
                , .{
                    .archerdb = archerdb_path,
                    .addresses = addresses,
                    .event_count = benchmark_options.event_count,
                });
                workload_exit_ok_ptr.* = true;
            }
        }.thread_main, .{
            &cluster.workload_exit_ok,
            if (skip_upgrade) archerdb else archerdb_past,
            options,
        });
    }

    fn workload_finish(cluster: *TmpCluster) void {
        cluster.workload_thread.?.join();
        cluster.workload_thread = null;
        assert(cluster.workload_exit_ok);
    }
};
