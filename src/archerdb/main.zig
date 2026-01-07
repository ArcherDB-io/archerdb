// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;
const log = std.log.scoped(.main);

const vsr = @import("vsr");
const stdx = vsr.stdx;
const constants = vsr.constants;
const config = constants.config;
const archerdb_metrics = vsr.archerdb_metrics;

const benchmark_driver = @import("benchmark_driver.zig");
const cli = @import("cli.zig");
const inspect = @import("inspect.zig");
const metrics_server = @import("metrics_server.zig");
const tls_config = vsr.tls_config;
const signal_handler = vsr.signal_handler;

const IO = vsr.io.IO;
const Time = vsr.time.Time;
const TimeOS = vsr.time.TimeOS;
const Tracer = vsr.trace.Tracer;
pub const Storage = vsr.storage.StorageType(IO);
const AOF = vsr.aof.AOFType(IO);

const MessageBus = vsr.message_bus.MessageBusType(IO);
const MessagePool = vsr.message_pool.MessagePool;
pub const StateMachine = vsr.state_machine.StateMachineType(Storage);
pub const Grid = vsr.GridType(Storage);

const Client = vsr.ClientType(StateMachine.Operation, MessageBus);
pub const Replica = vsr.ReplicaType(StateMachine, MessageBus, Storage, AOF);
const ReplicaReformat =
    vsr.ReplicaReformatType(StateMachine, MessageBus, Storage);
const data_file_size_min = vsr.superblock.data_file_size_min;

const KiB = stdx.KiB;
const MiB = stdx.MiB;
const GiB = stdx.GiB;

/// The runtime maximum log level.
/// One of: .err, .warn, .info, .debug
pub var log_level_runtime: std.log.Level = .info;

/// The runtime log format.
/// One of: .text, .json
pub var log_format_runtime: cli.LogFormat = .text;

/// Rotating log file configuration.
pub const RotatingLog = struct {
    file: std.fs.File,
    path: []const u8,
    bytes_written: u64,
    rotate_size: u64,
    rotate_count: u32,
    mutex: std.Thread.Mutex,

    pub fn init(path: []const u8, rotate_size: u64, rotate_count: u32) !RotatingLog {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        // Seek to end for appending
        const stat = try file.stat();
        try file.seekTo(stat.size);
        return RotatingLog{
            .file = file,
            .path = path,
            .bytes_written = stat.size,
            .rotate_size = rotate_size,
            .rotate_count = rotate_count,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RotatingLog) void {
        self.file.close();
    }

    pub fn write(self: *RotatingLog, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if rotation needed before writing
        if (self.bytes_written + data.len > self.rotate_size) {
            self.rotateFiles();
        }

        // Write data
        _ = self.file.write(data) catch return;
        self.bytes_written += data.len;
    }

    fn rotateFiles(self: *RotatingLog) void {
        // Close current file
        self.file.close();

        // Shift rotated files: .N -> .N+1, deleting oldest if over count
        var i: u32 = self.rotate_count;
        while (i > 0) : (i -= 1) {
            var old_name_buf: [std.fs.max_path_bytes]u8 = undefined;
            var new_name_buf: [std.fs.max_path_bytes]u8 = undefined;

            const old_sfx_fmt = std.fmt.bufPrint(&old_name_buf, ".{d}", .{i - 1});
            const old_suffix = if (i == 1) "" else old_sfx_fmt catch continue;
            const new_suffix_fmt = std.fmt.bufPrint(&new_name_buf, ".{d}", .{i});
            const new_suffix = new_suffix_fmt catch continue;

            var old_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;

            const old_path_fmt = std.fmt.bufPrint(
                &old_path_buf,
                "{s}{s}",
                .{ self.path, old_suffix },
            );
            const old_path = if (i == 1) self.path else old_path_fmt catch continue;

            const new_path_fmt = std.fmt.bufPrint(
                &new_path_buf,
                "{s}{s}",
                .{ self.path, new_suffix },
            );
            const new_path = new_path_fmt catch continue;

            if (i == self.rotate_count) {
                // Delete oldest rotated file if it exists
                std.fs.cwd().deleteFile(new_path) catch {};
            }

            // Rename old to new
            std.fs.cwd().rename(old_path, new_path) catch {};
        }

        // Create new log file
        self.file = std.fs.cwd().createFile(self.path, .{ .truncate = true }) catch return;
        self.bytes_written = 0;
    }

    pub fn getWriter(self: *RotatingLog) std.fs.File.Writer {
        return self.file.writer();
    }
};

/// Global rotating log instance (null if logging to stderr).
pub var rotating_log: ?RotatingLog = null;

/// Global metrics server instance (null if not enabled).
var metrics_srv: ?*metrics_server.MetricsServer = null;

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // A microbenchmark places the cost of this if at somewhere around 1600us for 10 million calls.
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        switch (log_format_runtime) {
            .text => log_text(message_level, scope, format, args),
            .json => log_json(message_level, scope, format, args),
        }
    }
}

fn log_text(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime message_level.asText();
    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const date_time = stdx.DateTimeUTC.now();

    // Format the complete log line into a buffer using two-step approach
    var log_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&log_buf);
    const writer = fbs.writer();

    nosuspend {
        // Write timestamp prefix
        date_time.format("", .{}, writer) catch return;
        // Write level, scope, and formatted message
        writer.print(" " ++ level_text ++ scope_prefix ++ format ++ "\n", args) catch return;
    }

    writeLogOutput(fbs.getWritten());
}

fn log_json(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime message_level.asText();
    const scope_name = comptime if (scope == .default) "default" else @tagName(scope);
    const date_time = stdx.DateTimeUTC.now();

    // Format the message first to escape it properly for JSON
    var msg_buf: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, format, args) catch "[message truncated]";

    // Build JSON output with escaping
    var log_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&log_buf);
    const writer = fbs.writer();

    nosuspend {
        const fmt_ts = "{{\"timestamp\":\"{d:0>4}-{d:0>2}-{d:0>2}T" ++
            "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\"," ++
            "\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"";
        writer.print(fmt_ts, .{
            date_time.year,
            date_time.month,
            date_time.day,
            date_time.hour,
            date_time.minute,
            date_time.second,
            date_time.millisecond,
            level_text,
            scope_name,
        }) catch return;

        // JSON-escape the message
        for (message) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return,
                '\\' => writer.writeAll("\\\\") catch return,
                '\n' => writer.writeAll("\\n") catch return,
                '\r' => writer.writeAll("\\r") catch return,
                '\t' => writer.writeAll("\\t") catch return,
                else => if (c < 0x20) {
                    writer.print("\\u{x:0>4}", .{c}) catch return;
                } else {
                    writer.writeByte(c) catch return;
                },
            }
        }

        writer.writeAll("\"}\n") catch return;
    }

    writeLogOutput(fbs.getWritten());
}

/// Write log output to either the rotating log file or stderr.
fn writeLogOutput(data: []const u8) void {
    if (rotating_log) |*rlog| {
        rlog.write(data);
    } else {
        const stderr = std.io.getStdErr();
        _ = stderr.write(data) catch {};
    }
}

pub const std_options: std.Options = .{
    // The comptime log_level. This needs to be debug - otherwise messages are compiled out.
    // The runtime filtering is handled by log_level_runtime.
    .log_level = .debug,
    .logFn = log_runtime,
};

pub fn main() !void {
    if (builtin.os.tag == .windows) try vsr.multiversion.wait_for_parent_to_exit();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    // Arena is an implementation detail, all memory must be freed.
    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    var command = cli.parse_args(&arg_iterator);

    if (command == .version) {
        try command_version(gpa, command.version.verbose);
        return; // Exit early before initializing IO.
    }

    if (command == .status) {
        try command_status(command.status.address, command.status.port);
        return; // Exit early before initializing IO.
    }

    log_level_runtime = switch (command) {
        .version => unreachable,
        .status => unreachable,
        .inspect => |inspect_cmd| switch (inspect_cmd) {
            .integrity => |integrity| integrity.log_level.toStdLogLevel(),
            else => .info,
        },
        inline else => |*args| args.log_level.toStdLogLevel(),
    };

    // Try and init IO early, before a file has even been created, so if it fails (eg, io_uring
    // is not available) there won't be a dangling file.
    var io = try IO.init(128, 0);
    defer io.deinit();

    var time_os: TimeOS = .{};
    const time = time_os.time();

    var trace_file: ?std.fs.File = null;
    defer if (trace_file) |file| file.close();

    // Cleanup rotating log on exit
    defer if (rotating_log) |*rlog| rlog.deinit();

    // Cleanup metrics server on exit
    defer if (metrics_srv) |srv| srv.stop();

    var statsd_address: ?std.net.Address = null;
    var log_trace = true;

    switch (command) {
        .start => |*args| {
            if (args.trace) |path| {
                trace_file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| {
                    log.err("error creating trace file '{s}': {}", .{ path, err });
                    return err;
                };
            }
            if (args.statsd) |address| statsd_address = address;
            log_trace = args.log_trace;
            log_format_runtime = args.log_format;

            // Initialize rotating log if --log-file is set
            if (args.log_file) |log_path| {
                const rotate_sz = args.log_rotate_size;
                const rotate_cnt = args.log_rotate_count;
                rotating_log = RotatingLog.init(log_path, rotate_sz, rotate_cnt) catch |err| {
                    // Fall back to stderr if we can't open the log file
                    log.err("error opening log file '{s}': {}", .{ log_path, err });
                    return err;
                };
            }

            // Initialize metrics server if --metrics-port is set
            if (args.metrics_port) |port| {
                const bind = args.metrics_bind;
                metrics_srv = metrics_server.MetricsServer.start(bind, port) catch |err| {
                    const err_msg = "error starting metrics server on {s}:{d}: {}";
                    log.err(err_msg, .{ bind, port, err });
                    return err;
                };
            }
        },
        .benchmark => {}, // Forwards trace and statsd argument to child archerdb.
        inline else => |args| comptime {
            assert(!@hasField(@TypeOf(args), "trace"));
            assert(!@hasField(@TypeOf(args), "statsd"));
        },
    }

    var tracer = try Tracer.init(gpa, time, .unknown, .{
        .writer = if (trace_file) |file| file.writer().any() else null,
        .statsd_options = if (statsd_address) |address| .{
            .udp = .{
                .io = &io,
                .address = address,
            },
        } else .log,
        .log_trace = log_trace,
    });
    defer tracer.deinit(gpa);

    switch (command) {
        .version => unreachable, // Handled earlier.
        .status => unreachable, // Handled earlier.
        inline .format, .start, .recover => |*args, command_storage| {
            const direct_io: vsr.io.DirectIO =
                if (!constants.direct_io)
                    .direct_io_disabled
                else if (args.development)
                    .direct_io_optional
                else
                    .direct_io_required;

            var storage = try Storage.init(&io, &tracer, .{
                .path = args.path,
                .size_min = data_file_size_min,
                .purpose = switch (command_storage) {
                    .format, .recover => .format,
                    .start => .open,
                    else => comptime unreachable,
                },
                .direct_io = direct_io,
            });
            defer storage.deinit();

            switch (command_storage) {
                .format => try command_format(gpa, &storage, args),
                .start => try command_start(gpa, &io, time, &tracer, &storage, args),
                .recover => try command_reformat(gpa, &io, time, &storage, args),
                else => comptime unreachable,
            }
        },
        .repl => |*args| try command_repl(gpa, &io, time, args),
        .benchmark => |*args| try benchmark_driver.command_benchmark(gpa, &io, time, args),
        .inspect => |*args| try inspect.command_inspect(gpa, &io, &tracer, args),
        .multiversion => |*args| {
            var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
            var stdout_writer = stdout_buffer.writer();
            const stdout = stdout_writer.any();

            try vsr.multiversion.print_information(gpa, args.path, stdout);
            try stdout_buffer.flush();
        },
        .amqp => |*args| try command_amqp(gpa, time, args),
    }
}

fn command_version(gpa: mem.Allocator, verbose: bool) !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    try std.fmt.format(stdout, "ArcherDB version {}\n", .{constants.semver});
    try stdout.writeAll("Copyright (c) 2026 ArcherDB by Gevorg Galstyan\n");
    try stdout.writeAll("https://archerdb.io\n");

    if (verbose) {
        try stdout.writeAll("\n");
        inline for (.{ "mode", "zig_version" }) |declaration| {
            try print_value(stdout, "build." ++ declaration, @field(builtin, declaration));
        }

        // Zig 0.10 doesn't see field_name as comptime if this `comptime` isn't used.
        try stdout.writeAll("\n");
        inline for (comptime std.meta.fieldNames(@TypeOf(config.cluster))) |field_name| {
            try print_value(
                stdout,
                "cluster." ++ field_name,
                @field(config.cluster, field_name),
            );
        }

        try stdout.writeAll("\n");
        inline for (comptime std.meta.fieldNames(@TypeOf(config.process))) |field_name| {
            try print_value(
                stdout,
                "process." ++ field_name,
                @field(config.process, field_name),
            );
        }

        try stdout.writeAll("\n");
        const self_exe_path = try vsr.multiversion.self_exe_path(gpa);
        defer gpa.free(self_exe_path);

        vsr.multiversion.print_information(gpa, self_exe_path, stdout) catch {};
    }
    try stdout_buffer.flush();
}

fn command_status(address: []const u8, port: u16) !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    // Connect to the metrics server health endpoint
    const addr = std.net.Address.parseIp4(address, port) catch |err| {
        try std.fmt.format(stdout, "Error: invalid address {s}:{d}: {}\n", .{ address, port, err });
        try stdout_buffer.flush();
        return;
    };

    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch |err| {
        try std.fmt.format(stdout, "Error: failed to create socket: {}\n", .{err});
        try stdout_buffer.flush();
        return;
    };
    defer std.posix.close(socket);

    std.posix.connect(socket, &addr.any, addr.getOsSockLen()) catch |err| {
        const err_msg = "Error: failed to connect to {s}:{d}: {}\n";
        try std.fmt.format(stdout, err_msg, .{ address, port, err });
        try stdout_buffer.flush();
        return;
    };

    // Send HTTP GET request for health status
    const request = "GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = std.posix.write(socket, request) catch |err| {
        try std.fmt.format(stdout, "Error: failed to send request: {}\n", .{err});
        try stdout_buffer.flush();
        return;
    };

    // Read response
    var response_buf: [4096]u8 = undefined;
    const bytes_read = std.posix.read(socket, &response_buf) catch |err| {
        try std.fmt.format(stdout, "Error: failed to read response: {}\n", .{err});
        try stdout_buffer.flush();
        return;
    };

    if (bytes_read == 0) {
        try stdout.writeAll("Error: empty response from server\n");
        try stdout_buffer.flush();
        return;
    }

    const response = response_buf[0..bytes_read];

    // Parse HTTP response
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |body_start| {
        const body = response[body_start + 4 ..];

        // Extract HTTP status code
        if (std.mem.indexOf(u8, response, " ")) |status_start| {
            const status_line = response[status_start + 1 ..];
            if (std.mem.indexOf(u8, status_line, " ")) |status_end| {
                const status_code = status_line[0..status_end];

                if (std.mem.eql(u8, status_code, "200")) {
                    try std.fmt.format(stdout, "ArcherDB Status: READY\n", .{});
                } else if (std.mem.eql(u8, status_code, "503")) {
                    try std.fmt.format(stdout, "ArcherDB Status: NOT READY\n", .{});
                } else {
                    const unk_fmt = "ArcherDB Status: UNKNOWN (HTTP {s})\n";
                    try std.fmt.format(stdout, unk_fmt, .{status_code});
                }

                try std.fmt.format(stdout, "Response: {s}\n", .{body});
            }
        }
    } else {
        try stdout.writeAll("Error: malformed HTTP response\n");
    }

    try stdout_buffer.flush();
}

fn command_format(
    gpa: mem.Allocator,
    storage: *Storage,
    args: *const cli.Command.Format,
) !void {
    try vsr.format(Storage, gpa, storage, .{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .release = config.process.release,
        .view = null,
    });

    log.info("{}: formatted: cluster={} replica_count={}", .{
        args.replica,
        args.cluster,
        args.replica_count,
    });
}

fn command_start(
    base_allocator: mem.Allocator,
    io: *IO,
    time: vsr.time.Time,
    tracer: *Tracer,
    storage: *Storage,
    args: *const cli.Command.Start,
) !void {
    var counting_allocator = vsr.CountingAllocator.init(base_allocator);
    const gpa = counting_allocator.allocator();

    // Initialize TLS configuration (F5.4.1 - Security)
    // Validates certificate paths and loads certificates if TLS is required.
    var tls = tls_config.TlsConfig.init(gpa, .{
        .required = args.tls_required,
        .cert_path = args.tls_cert_path,
        .key_path = args.tls_key_path,
        .ca_path = args.tls_ca_path,
    }) catch |err| {
        log.err("TLS configuration error: {}", .{err});
        return err;
    };
    defer tls.deinit();

    // Update TLS metrics
    archerdb_metrics.Registry.setTlsEnabled(tls.isEnabled());

    // Install SIGHUP handler for certificate reload (F5.4.3)
    if (tls.isEnabled()) {
        signal_handler.install();
    }

    // TODO Panic if the data file's size is larger that args.storage_size_limit.
    // (Here or in Replica.open()?).

    var message_pool = try MessagePool.init(gpa, .{ .replica = .{
        .members_count = args.addresses.count_as(u8),
        .pipeline_requests_limit = args.pipeline_requests_limit,
        .message_bus = .tcp,
    } });
    defer message_pool.deinit(gpa);

    var aof: ?AOF = if (args.aof_file) |*aof_file| blk: {
        const aof_dir = std.fs.path.dirname(aof_file.const_slice()) orelse ".";
        const aof_dir_fd = try IO.open_dir(aof_dir);
        defer std.posix.close(aof_dir_fd);

        break :blk try AOF.init(io, .{
            .dir_fd = aof_dir_fd,
            .relative_path = std.fs.path.basename(aof_file.const_slice()),
        });
    } else null;
    defer if (aof != null) aof.?.close();

    const grid_cache_size = @as(u64, args.cache_grid_blocks) * constants.block_size;
    const grid_cache_size_min = constants.block_size * Grid.Cache.value_count_max_multiple;

    // The amount of bytes in `--cache-grid` must be a multiple of
    // `constants.block_size` and `SetAssociativeCache.value_count_max_multiple`,
    // and it may have been converted to zero if a smaller value is passed in.
    if (grid_cache_size == 0) {
        if (comptime (grid_cache_size_min >= MiB)) {
            vsr.fatal(.cli, "Grid cache must be greater than {}MiB. See --cache-grid", .{
                @divExact(grid_cache_size_min, MiB),
            });
        } else {
            vsr.fatal(.cli, "Grid cache must be greater than {}KiB. See --cache-grid", .{
                @divExact(grid_cache_size_min, KiB),
            });
        }
    }
    assert(grid_cache_size >= grid_cache_size_min);

    const grid_cache_size_warn = 1 * GiB;
    if (grid_cache_size < grid_cache_size_warn) {
        log.warn("Grid cache size of {}MiB is small. See --cache-grid", .{
            @divExact(grid_cache_size, MiB),
        });
    }

    const nonce = stdx.unique_u128();

    var self_exe_path: ?[:0]const u8 = null;
    defer if (self_exe_path) |path| gpa.free(path);

    var multiversion_os: ?vsr.multiversion.MultiversionOS = null;
    defer if (multiversion_os != null) multiversion_os.?.deinit(gpa);

    const multiversion: vsr.multiversion.Multiversion = blk: {
        if (constants.config.process.release.value ==
            vsr.multiversion.Release.minimum.value)
        {
            log.info("multiversioning: upgrades disabled for development ({}) release.", .{
                constants.config.process.release,
            });
            break :blk .single_release(constants.config.process.release);
        }
        if (constants.aof_recovery) {
            log.info("multiversioning: upgrades disabled due to aof_recovery.", .{});
            break :blk .single_release(constants.config.process.release);
        }

        if (args.addresses_zero) {
            log.info("multiversioning: upgrades disabled due to --addresses=0", .{});
            break :blk .single_release(constants.config.process.release);
        }

        self_exe_path = try vsr.multiversion.self_exe_path(gpa);
        multiversion_os = try vsr.multiversion.MultiversionOS.init(
            gpa,
            io,
            self_exe_path.?,
            .native,
        );
        // The error from .open_sync() is ignored - timeouts and checking for new binaries are still
        // enabled even if the first version fails to load.
        multiversion_os.?.open_sync() catch {};

        break :blk multiversion_os.?.multiversion();
    };

    log.info("release={}", .{config.process.release});
    log.info("release_client_min={}", .{config.process.release_client_min});
    log.info("releases_bundled={any}", .{multiversion.releases_bundled().slice()});
    log.info("git_commit={?s}", .{config.process.git_commit});

    const clients_limit = constants.pipeline_prepare_queue_max + args.pipeline_requests_limit;

    var replica: Replica = undefined;
    replica.open(
        gpa,
        time,
        storage,
        &message_pool,
        .{
            .node_count = args.addresses.count_as(u8),
            .release = config.process.release,
            .release_client_min = config.process.release_client_min,
            .multiversion = multiversion,
            .pipeline_requests_limit = args.pipeline_requests_limit,
            .storage_size_limit = args.storage_size_limit,
            .aof = if (aof != null) &aof.? else null,
            .nonce = nonce,
            .timeout_prepare_ticks = args.timeout_prepare_ticks,
            .timeout_grid_repair_message_ticks = args.timeout_grid_repair_message_ticks,
            .commit_stall_probability = args.commit_stall_probability,
            .state_machine_options = .{
                .batch_size_limit = args.request_size_limit - @sizeOf(vsr.Header),
                .lsm_forest_compaction_block_count = args.lsm_forest_compaction_block_count,
                .lsm_forest_node_count = args.lsm_forest_node_count,
                .cache_entries_geo_events = args.cache_geo_events,
            },
            .message_bus_options = .{
                .configuration = args.addresses.const_slice(),
                .io = io,
                .clients_limit = clients_limit,
            },
            .grid_cache_blocks_count = args.cache_grid_blocks,
            .tracer = tracer,
            .replicate_options = .{
                .star = args.replicate_star,
            },
        },
    ) catch |err| switch (err) {
        error.NoAddress => vsr.fatal(.cli, "all --addresses must be provided", .{}),
        else => |e| return e,
    };

    // Mark grid cache as MADV_DONTDUMP, after transitioning to static in replica.open, to reduce
    // core dump size.
    replica.grid.madv_dont_dump() catch |e| {
        log.warn("unable to mark grid cache as MADV_DONTDUMP - " ++
            "core dumps will be large: {}", .{e});
    };

    if (multiversion_os != null) {
        if (args.development) {
            log.info("multiversioning: upgrade polling disabled due to --development.", .{});
        } else {
            multiversion_os.?.timeout_start(replica.replica);
        }

        if (args.experimental) {
            log.warn("multiversioning: upgrade polling and --experimental enabled - " ++
                "make sure to check CLI argument compatibility before upgrading.", .{});
            log.warn("If the cluster upgrades automatically, and incompatible experimental " ++
                "CLI arguments are set, it will crash.", .{});
        }
    }

    // Note that this does not account for the fact that any allocations will be rounded up to
    // the nearest page by `std.heap.page_allocator`.
    log.info("{}: Allocated {}MiB during replica init", .{
        replica.replica,
        @divFloor(counting_allocator.live_size(), MiB),
    });
    log.info("{}: Grid cache: {}MiB, LSM-tree manifests: {}MiB", .{
        replica.replica,
        @divFloor(grid_cache_size, MiB),
        @divFloor(args.lsm_forest_node_count * constants.lsm_manifest_node_size, MiB),
    });

    log.info("{}: cluster={}: listening on {}", .{
        replica.replica,
        replica.cluster,
        replica.message_bus.accept_address.?,
    });

    if (constants.aof_recovery) {
        log.warn(
            "{}: started in AOF recovery mode. This is potentially dangerous - if it's" ++
                " unexpected, please recompile ArcherDB with -Dconfig-aof-recovery=false.",
            .{replica.replica},
        );
    }

    if (constants.verify) {
        log.info("{}: started with extra verification checks", .{replica.replica});
    }

    if (replica.aof != null) {
        log.warn(
            "{}: started with --aof - expect much reduced performance.",
            .{replica.replica},
        );
    }

    // It is possible to start archerdb passing `0` as an address:
    //     $ archerdb start --addresses=0 0_0.archerdb
    // This enables a couple of special behaviors, useful in tests:
    // - The operating system picks a free port, avoiding "address already in use" errors.
    // - The port, and only the port, is printed to the stdout, so that the parent process
    //   can learn it.
    // - archerdb process exits when its stdin gets closed.
    if (args.addresses_zero) {
        const port_actual = replica.message_bus.accept_address.?.getPort();
        const stdout = std.io.getStdOut();
        try stdout.writer().print("{}\n", .{port_actual});
        stdout.close();

        // While it is possible to integrate stdin with our io_uring loop, using a dedicated
        // thread is simpler, and gives us _un_graceful shutdown, which is exactly what we want
        // to keep behavior close to the normal case.
        const watchdog = try std.Thread.spawn(.{}, struct {
            fn thread_main() void {
                var buf: [1]u8 = .{0};
                _ = std.io.getStdIn().read(&buf) catch {};
                log.info("stdin closed, exiting", .{});
                std.process.exit(0);
            }
        }.thread_main, .{});
        watchdog.detach();
    }

    if (!args.development) {
        // Try to lock all memory in the process to avoid the kernel swapping pages to disk and
        // potentially introducing undetectable disk corruption into memory.
        // This is a best-effort attempt and not a hard rule as it may not cover all memory edge
        // case. So warn on error to notify the operator to adjust conditions if possible.
        stdx.memory_lock_allocated(.{
            .allocated_size = counting_allocator.live_size(),
        }) catch {
            log.warn(
                "If this is a production replica, consider either " ++
                    "running the replica with CAP_IPC_LOCK privilege, " ++
                    "increasing the MEMLOCK process limit, " ++
                    "or disabling swap system-wide.",
                .{},
            );
        };

        if (replica.cluster == 0) {
            log.warn("a cluster id of 0 is reserved for testing and benchmarking, " ++
                "do not use in production", .{});
        }
    }

    // Track previous view for detecting view changes
    var prev_view: u32 = replica.view;

    while (true) {
        replica.tick();

        // Check for SIGHUP-triggered certificate reload (F5.4.3)
        if (tls.isEnabled() and signal_handler.shouldReloadCertificates()) {
            log.info("SIGHUP received, reloading TLS certificates", .{});
            if (tls.reload()) |_| {
                log.info("TLS certificates reloaded successfully", .{});
                archerdb_metrics.Registry.recordCertReload();
            } else |err| {
                log.err("certificate reload failed: {} - keeping old certificates", .{err});
                archerdb_metrics.Registry.recordCertReloadFailure();
            }
        }

        // Update VSR metrics (F5.2.2 - Observability)
        const status_code: i64 = switch (replica.status) {
            .normal => 0,
            .view_change => 1,
            .recovering => 2,
            .recovering_head => 3,
        };
        const is_primary = replica.primary_index(replica.view) == replica.replica;
        archerdb_metrics.Registry.updateVsrMetrics(
            replica.view,
            status_code,
            is_primary,
            replica.commit_min,
        );

        // Track view changes
        if (replica.view != prev_view) {
            archerdb_metrics.Registry.recordViewChange();
            prev_view = replica.view;
        }

        // Update replica state for health endpoint
        metrics_server.replica_state = switch (replica.status) {
            .normal => .ready,
            .view_change => .view_change,
            .recovering, .recovering_head => .recovering,
        };

        // Update resource metrics (F5.2 - Observability: memory, disk)
        archerdb_metrics.Registry.updateResourceMetrics(
            counting_allocator.alloc_size,
            counting_allocator.live_size(),
            replica.superblock.staging.vsr_state.checkpoint.storage_size,
            0, // TODO: Index entries - requires LSM tree traversal
            0, // TODO: Index capacity - requires configuration access
        );

        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }
}

fn command_reformat(
    gpa: mem.Allocator,
    io: *IO,
    time: vsr.time.Time,
    storage: *Storage,
    args: *const cli.Command.Recover,
) !void {
    var message_pool = try MessagePool.init(gpa, .client);
    defer message_pool.deinit(gpa);

    var client = try Client.init(
        gpa,
        time,
        &message_pool,
        .{
            .id = stdx.unique_u128(),
            .cluster = args.cluster,
            .replica_count = args.replica_count,

            .message_bus_options = .{
                .configuration = args.addresses.const_slice(),
                .io = io,
                .clients_limit = null,
            },
            .eviction_callback = &reformat_client_eviction_callback,
        },
    );
    defer client.deinit(gpa);

    var reformatter = try ReplicaReformat.init(gpa, &client, storage, .{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .release = config.process.release,
        .view = null,
    });
    defer reformatter.deinit(gpa);

    reformatter.start();
    while (reformatter.done() == null) {
        client.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }
    switch (reformatter.done().?) {
        .failed => |err| {
            log.err("{}: error: {s}", .{ args.replica, @errorName(err) });
            return err;
        },
        .ok => log.info("{}: success", .{args.replica}),
    }
}

fn reformat_client_eviction_callback(
    client: *Client,
    eviction: *const MessagePool.Message.Eviction,
) void {
    _ = client;
    std.debug.panic("error: client evicted: {s}", .{@tagName(eviction.header.reason)});
}

fn command_repl(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Repl,
) !void {
    const Repl = vsr.repl.ReplType(vsr.message_bus.MessageBusType(IO));

    var repl_instance = try Repl.init(gpa, io, time, .{
        .cluster_id = args.cluster,
        .addresses = args.addresses.const_slice(),
        .verbose = args.verbose,
    });
    defer repl_instance.deinit(gpa);

    try repl_instance.run(args.statements);
}

fn command_amqp(gpa: mem.Allocator, time: Time, args: *const cli.Command.AMQP) !void {
    // ArcherDB CDC/AMQP is not yet implemented - stub out with clear error message
    _ = gpa;
    _ = time;
    _ = args;

    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\
        \\ArcherDB CDC (Change Data Capture) - Not Yet Implemented
        \\============================================================
        \\
        \\The AMQP/CDC feature is not yet implemented for ArcherDB's
        \\geospatial operations.
        \\
        \\For real-time event streaming, use the client SDKs with:
        \\  - query_latest: Poll for most recent events
        \\  - query_uuid: Track specific entities
        \\  - query_radius: Monitor geographic areas
        \\
        \\For more information: https://archerdb.io/docs
        \\
    , .{});

    return error.NotImplemented;
}

fn print_value(
    writer: anytype,
    field: []const u8,
    value: anytype,
) !void {
    if (@TypeOf(value) == ?[40]u8) {
        assert(std.mem.eql(u8, field, "process.git_commit"));
        return std.fmt.format(writer, "{s}=\"{?s}\"\n", .{
            field,
            value,
        });
    }

    switch (@typeInfo(@TypeOf(value))) {
        .@"fn" => {}, // Ignore the log() function.
        .pointer => try std.fmt.format(writer, "{s}=\"{s}\"\n", .{
            field,
            std.fmt.fmtSliceEscapeLower(value),
        }),
        else => try std.fmt.format(writer, "{s}={any}\n", .{
            field,
            value,
        }),
    }
}
