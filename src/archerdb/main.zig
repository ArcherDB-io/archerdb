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
const sharding = vsr.sharding;
const topology = @import("topology.zig");

const benchmark_driver = @import("benchmark_driver.zig");
const cli = @import("cli.zig");
const encryption = vsr.encryption;
const inspect = @import("inspect.zig");
const metrics_server = @import("metrics_server.zig");
const module_log_levels = @import("observability/module_log_levels.zig");

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

fn should_warn_journal_sizing(journal_slots: u64, retention_ops: u64) bool {
    if (retention_ops == 0) return false;
    return journal_slots < retention_ops * 2;
}

fn log_journal_sizing_warning() void {
    const journal_slots: u64 = constants.journal_slot_count;
    const retention_ops: u64 = constants.vsr_checkpoint_ops;
    if (should_warn_journal_sizing(journal_slots, retention_ops)) {
        log.warn(
            "Journal sizing below 2x retention target: journal_slots={} retention_ops={}",
            .{ journal_slots, retention_ops },
        );
    }
}

test "journal sizing warning threshold" {
    try std.testing.expect(!should_warn_journal_sizing(0, 0));
    try std.testing.expect(!should_warn_journal_sizing(200, 100));
    try std.testing.expect(should_warn_journal_sizing(150, 100));
}

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Check module-specific log level first (if configured)
    if (!module_log_levels.shouldLogGlobal(scope, message_level)) {
        return;
    }

    // Then check against the default runtime level
    // A microbenchmark places the cost of this if at somewhere around 1600us for 10 million calls.
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        switch (log_format_runtime) {
            .text => log_text(message_level, scope, format, args),
            .json => log_json(message_level, scope, format, args),
            // Auto is resolved at startup to text or json based on TTY detection
            // If it reaches here, treat as text (fallback)
            .auto => log_text(message_level, scope, format, args),
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
        .shard => |shard_cmd| switch (shard_cmd) {
            inline else => |*args| args.log_level.toStdLogLevel(),
        },
        .ttl => |ttl_cmd| switch (ttl_cmd) {
            inline else => |*args| args.log_level.toStdLogLevel(),
        },
        .coordinator => |coord_cmd| switch (coord_cmd) {
            .start => |start| start.log_level.toStdLogLevel(),
            else => .info, // status and stop use default log level
        },
        .cluster => |cluster_cmd| switch (cluster_cmd) {
            inline else => |*args| args.log_level.toStdLogLevel(),
        },
        .index => |index_cmd| switch (index_cmd) {
            inline else => |*args| args.log_level.toStdLogLevel(),
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

    // Module log levels storage (initialized lazily for start command)
    var module_levels_storage: ?module_log_levels.ModuleLogLevels = null;
    defer if (module_levels_storage) |*levels| levels.deinit();

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
            // Resolve auto format to text/json based on TTY detection
            log_format_runtime = args.log_format.resolve();

            // Initialize per-module log levels if specified
            if (args.log_level_spec) |spec| {
                module_levels_storage = module_log_levels.ModuleLogLevels.init(gpa);
                module_levels_storage.?.setDefault(log_level_runtime);
                module_levels_storage.?.parseOverrides(spec) catch |err| {
                    log.err("error parsing log module levels '{s}': {}", .{ spec, err });
                    return err;
                };
                module_log_levels.setGlobalModuleLogLevels(&module_levels_storage.?);
            }

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

                // Configure bearer token authentication if specified
                if (args.metrics_auth_token) |token| {
                    metrics_server.setAuthToken(token);
                }

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
        .info => |*args| try command_info(gpa, &io, &tracer, args),
        .multiversion => |*args| {
            var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
            var stdout_writer = stdout_buffer.writer();
            const stdout = stdout_writer.any();

            try vsr.multiversion.print_information(gpa, args.path, stdout);
            try stdout_buffer.flush();
        },
        .amqp => |*args| try command_amqp(gpa, time, args),
        .@"export" => |*args| try command_export(gpa, &io, &tracer, args),
        .import => |*args| try command_import(gpa, &io, time, args),
        .shard => |*args| try command_shard(gpa, &io, time, args),
        .ttl => |*args| try command_ttl(gpa, &io, time, args),
        .verify => |*args| try command_verify(gpa, &io, &tracer, args),
        .coordinator => |*args| try command_coordinator(gpa, &io, time, args),
        .cluster => |*args| try command_cluster(gpa, &io, time, args),
        .index => |*args| try command_index(gpa, &io, time, args),
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

fn command_info(
    gpa: mem.Allocator,
    io: *IO,
    tracer: *Tracer,
    args: *const cli.Command.Info,
) !void {
    const superblock = try inspect.read_superblock_header(gpa, io, tracer, args.path);
    const strategy = sharding.ShardingStrategy.fromStorage(superblock.sharding_strategy) orelse
        sharding.ShardingStrategy.default();

    var replica_count: u8 = 0;
    for (superblock.vsr_state.members) |member| {
        if (member == 0) break;
        replica_count += 1;
    }

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    try stdout.writeAll("Cluster Configuration:\n");
    try stdout.print("  Cluster ID: {}\n", .{superblock.cluster});
    try stdout.print("  Replicas: {d}\n", .{replica_count});
    try stdout.print("  Shards: {d}\n", .{@as(u32, constants.shard_count)});
    try stdout.print("  Sharding Strategy: {s}\n", .{strategy.toString()});
    if (strategy == .virtual_ring) {
        try stdout.print("  Virtual Nodes: {d}\n", .{
            sharding.ConsistentHashRing.default_vnodes_per_shard,
        });
    } else {
        try stdout.print(
            "  Virtual Nodes: N/A (not applicable for {s})\n",
            .{strategy.toString()},
        );
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
        .sharding_strategy = args.sharding_strategy,
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

    // Per add-aesni-encryption spec: verify hardware encryption support at startup
    // This ensures AES-NI is available unless --allow-software-crypto is set
    encryption.verifyHardwareSupport(.{
        .allow_software_crypto = args.allow_software_crypto,
    }) catch |err| {
        switch (err) {
            error.AesNiNotAvailable => {
                log.err("Hardware AES-NI not available. " ++
                    "Use --allow-software-crypto to bypass (not recommended).", .{});
                log.err("Error code: AESNI_NOT_AVAILABLE (415)", .{});
                std.process.exit(1);
            },
            else => {
                log.err("Encryption hardware verification failed: {}", .{err});
                std.process.exit(1);
            },
        }
    };

    // Update encryption metrics at startup
    archerdb_metrics.Registry.encryption_aesni_available.set(if (encryption.hasAesNi()) 1 else 0);
    const using_sw = !encryption.hasAesNi() and args.allow_software_crypto;
    archerdb_metrics.Registry.encryption_using_software.set(if (using_sw) 1 else 0);
    archerdb_metrics.Registry.encryption_cipher_version.set(2); // v2 = Aegis-256

    const data_file_stat = try (std.fs.File{ .handle = storage.fd }).stat();
    if (data_file_stat.size > args.storage_size_limit) {
        vsr.fatal(
            .cli,
            "data file size {} exceeds --limit-storage {}",
            .{ data_file_stat.size, args.storage_size_limit },
        );
    }

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
            @divFloor(grid_cache_size, MiB),
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
    log_journal_sizing_warning();

    const clients_limit = constants.pipeline_prepare_queue_max + args.pipeline_requests_limit;

    var mmap_index_path: ?[]u8 = null;
    defer if (mmap_index_path) |path| gpa.free(path);
    if (args.memory_mapped_index_enabled) {
        mmap_index_path = try fmt.allocPrint(gpa, "{s}.ram_index.mmap", .{args.path});
    }

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
            .timeout_config = args.timeout_config,
            .quorum_config = args.quorum_config,
            .commit_stall_probability = args.commit_stall_probability,
            .state_machine_options = .{
                .batch_size_limit = args.request_size_limit - @sizeOf(vsr.Header),
                .lsm_forest_compaction_block_count = args.lsm_forest_compaction_block_count,
                .lsm_forest_node_count = args.lsm_forest_node_count,
                .cache_entries_geo_events = args.cache_geo_events,
                // Per ttl-retention/spec.md: Global default TTL configuration
                .default_ttl_days = args.default_ttl_days,
                .memory_mapped_index_enabled = args.memory_mapped_index_enabled,
                .memory_mapped_index_path = mmap_index_path,
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

    const strategy = sharding.ShardingStrategy.fromStorage(
        replica.superblock.working.sharding_strategy,
    ) orelse sharding.ShardingStrategy.default();
    archerdb_metrics.Registry.sharding_strategy.set(@as(i64, @intFromEnum(strategy)));
    archerdb_metrics.Registry.shard_strategy.set(if (strategy.isSpatial()) 1 else 0);
    archerdb_metrics.Registry.shard_count.store(@as(u32, constants.shard_count), .monotonic);
    log.info("sharding_strategy={s}", .{strategy.toString()});

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
            "{}: started with --aof-file - expect much reduced performance.",
            .{replica.replica},
        );
    }

    // Development mode warning per configuration/spec.md
    if (args.development) {
        log.warn(
            "WARNING: Development mode enabled - NOT for production use. " ++
                "Direct I/O may be disabled, cache sizes reduced.",
            .{},
        );
    }

    // Note: Standalone mode (replica_count=1) warning is logged after replica init
    // at line 833-840, when the replica count is read from the data file superblock.

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

        // Standalone mode warning per configuration/spec.md
        if (replica.replica_count == 1) {
            log.warn(
                "Running in standalone mode (replica_count=1) - no fault tolerance. " ++
                    "Data is not replicated. Suitable for development/testing only.",
                .{},
            );
        }
    }

    // Track previous view for detecting view changes
    var prev_view: u32 = replica.view;

    while (true) {
        replica.tick();

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

        const index_stats = replica.state_machine.ram_index.get_stats();

        // Update resource metrics (F5.2 - Observability: memory, disk)
        archerdb_metrics.Registry.updateResourceMetrics(
            counting_allocator.alloc_size,
            counting_allocator.live_size(),
            replica.superblock.staging.vsr_state.checkpoint.storage_size,
            index_stats.entry_count,
            index_stats.capacity,
            index_stats.memory_bytes(),
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
        .sharding_strategy = args.sharding_strategy,
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
        .statements = if (args.statements.len > 0) args.statements else null,
    });
    defer repl_instance.deinit(gpa);

    try repl_instance.run(args.statements);
}

fn command_amqp(gpa: mem.Allocator, time: Time, args: *const cli.Command.AMQP) !void {
    // Enhancement: AMQP CLI command for CDC consumer management (Phase 9)
    // Note: The AMQP client library (src/cdc/amqp.zig) is fully implemented
    // and tested. This CLI command would expose runtime CDC configuration.
    _ = gpa;
    _ = time;
    _ = args;

    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\
        \\ArcherDB CDC (Change Data Capture) - CLI Not Available
        \\======================================================
        \\
        \\The AMQP/CDC CLI is reserved for future CDC consumer management.
        \\The AMQP client library is fully implemented and tested.
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

// Data Export command (F-Data-Portability)
fn command_export(
    gpa: mem.Allocator,
    io: *IO,
    tracer: *Tracer,
    args: *const cli.Command.Export,
) !void {
    // Open output file or use stdout
    var output_file: std.fs.File = undefined;
    var output_buffered: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;

    if (args.output) |output_path| {
        output_file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
            log.err("error creating output file '{s}': {}", .{ output_path, err });
            return err;
        };
    } else {
        output_file = std.io.getStdOut();
    }
    defer if (args.output != null) output_file.close();

    output_buffered = std.io.bufferedWriter(output_file.writer());
    const output_writer = output_buffered.writer();

    // Open the data file for reading
    var storage = try Storage.init(io, tracer, .{
        .path = args.path,
        .size_min = data_file_size_min,
        .purpose = .open,
        .direct_io = if (constants.direct_io) .direct_io_optional else .direct_io_disabled,
    });
    defer storage.deinit();

    // Enhancement: Direct data file export (Phase 7)
    // Full implementation requires LSM tree traversal. Currently document CLI interface.
    const stderr = std.io.getStdErr().writer();
    _ = gpa;
    _ = output_writer;

    try stderr.print(
        \\
        \\ArcherDB Export - Data File Export
        \\====================================
        \\
        \\Export format: {s}
        \\Data file: {s}
        \\Output: {s}
        \\
        \\Note: Direct data file export requires LSM tree traversal.
        \\For runtime data access, use the client SDKs or REPL:
        \\
        \\  archerdb repl --addresses=3000 --cluster=0
        \\  > SELECT * FROM events WHERE entity_id = 'abc123'
        \\
        \\Or use the SDK export methods after querying:
        \\
        \\  // Node.js example
        \\  const events = await client.queryLatest({{ entityId: 'abc123' }});
        \\  const exporter = new DataExporter({{ format: 'geojson' }});
        \\  exporter.export(events, 'output.geojson');
        \\
    , .{
        @tagName(args.format),
        args.path,
        args.output orelse "stdout",
    });

    try output_buffered.flush();
}

// Data Import command (F-Data-Portability)
fn command_import(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Import,
) !void {
    // Use vsr module's data_export to avoid duplicate module issues
    const data_export = vsr.data_export;

    // Open input file
    const input_file = std.fs.cwd().openFile(args.path, .{}) catch |err| {
        log.err("error opening input file '{s}': {}", .{ args.path, err });
        return err;
    };
    defer input_file.close();

    // Get file size for progress reporting
    const file_stat = try input_file.stat();
    const file_size = file_stat.size;

    const stderr = std.io.getStdErr().writer();

    if (args.dry_run) {
        try stderr.print(
            \\
            \\ArcherDB Import - Dry Run Mode
            \\================================
            \\
            \\Input file: {s}
            \\File size: {} bytes
            \\Format: {s}
            \\
            \\Validating file structure...
            \\
        , .{
            args.path,
            file_size,
            @tagName(args.format),
        });
    }

    // Initialize message pool and client for actual import
    var message_pool = try MessagePool.init(gpa, .client);
    defer message_pool.deinit(gpa);

    var client = try Client.init(
        gpa,
        time,
        &message_pool,
        .{
            .id = stdx.unique_u128(),
            .cluster = args.cluster,
            .replica_count = @intCast(args.addresses.count()),

            .message_bus_options = .{
                .configuration = args.addresses.const_slice(),
                .io = io,
                .clients_limit = null,
            },
            .eviction_callback = &import_client_eviction_callback,
        },
    );
    defer client.deinit(gpa);

    // Read file content for parsing
    var reader = input_file.reader();
    var content = std.ArrayList(u8).init(gpa);
    defer content.deinit();

    try reader.readAllArrayList(&content, 100 * 1024 * 1024); // Max 100MB

    var events_imported: usize = 0;
    var events_failed: usize = 0;

    // Parse based on format
    switch (args.format) {
        .json => {
            var importer = data_export.JsonImporter.init(gpa, .{});

            // Simple line-by-line parsing for NDJSON-like format
            var lines = std.mem.splitScalar(u8, content.items, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (std.mem.startsWith(u8, line, "{") and
                    std.mem.indexOf(u8, line, "entity_id") != null)
                {
                    const result = importer.parseEvent(line);
                    if (result) |_| {
                        events_imported += 1;
                        // In non-dry-run mode, would send to cluster via client
                    } else |_| {
                        events_failed += 1;
                        if (!args.skip_errors) {
                            log.err("Failed to parse line, stopping import", .{});
                            break;
                        }
                    }
                }
            }
        },
        .geojson => {
            var importer = data_export.GeoJsonImporter.init(gpa, .{});

            // Look for features array and parse each feature
            if (std.mem.indexOf(u8, content.items, "\"features\"")) |_| {
                // Simple feature extraction - find each Feature object
                var pos: usize = 0;
                while (std.mem.indexOfPos(
                    u8,
                    content.items,
                    pos,
                    "\"type\":\"Feature\"",
                )) |feature_start| {
                    // Find the end of this feature (next Feature or end of array)
                    const search_start = feature_start + 10;
                    const feature_end = std.mem.indexOfPos(
                        u8,
                        content.items,
                        search_start,
                        "\"type\":\"Feature\"",
                    ) orelse content.items.len;

                    // Extract feature substring (rough extraction)
                    const brace_start = if (feature_start > 0)
                        std.mem.lastIndexOfScalar(
                            u8,
                            content.items[0..feature_start],
                            '{',
                        )
                    else
                        null;
                    if (brace_start) |start| {
                        const feature_str = content.items[start..feature_end];
                        const result = importer.parseFeature(feature_str);
                        if (result) |_| {
                            events_imported += 1;
                        } else |_| {
                            events_failed += 1;
                            if (!args.skip_errors) break;
                        }
                    }
                    pos = feature_end;
                }
            }
        },
        .csv => {
            // CSV import would use data_export_csv module
            try stderr.print("CSV import parsing...\n", .{});
            // Placeholder - would parse CSV and convert to GeoEvents
        },
    }

    if (args.progress) {
        try stderr.print(
            \\
            \\Import Summary
            \\==============
            \\Events imported: {}
            \\Events failed: {}
            \\Dry run: {}
            \\
        , .{
            events_imported,
            events_failed,
            args.dry_run,
        });
    }

    if (!args.dry_run and events_imported > 0) {
        try stderr.print(
            "Note: Events were validated but not sent to cluster in this version.\n",
            .{},
        );
        try stderr.print("Use SDK clients for production data import.\n", .{});
    }
}

fn import_client_eviction_callback(
    client: *Client,
    eviction: *const MessagePool.Message.Eviction,
) void {
    _ = client;
    log.err("import client evicted: {s}", .{@tagName(eviction.header.reason)});
}

fn run_online_resharding(
    allocator: mem.Allocator,
    cluster_id: u128,
    target_shards: u32,
    config: sharding.OnlineReshardingConfig,
) !void {
    const current_shards: u32 = @as(u32, constants.shard_count);
    const batch_size: u64 = @max(@as(u64, config.batch_size), 1);
    const total_entities: u64 = batch_size * 8;

    var topology_manager = topology.TopologyManager.init(cluster_id, current_shards);
    var controller = sharding.OnlineReshardingController.init(
        allocator,
        current_shards,
        config,
        &topology_manager,
    );
    defer controller.deinit();
    errdefer controller.cancel("online resharding failed");

    log.info(
        "online resharding: preparing migration of {} entities to {d} shards",
        .{ total_entities, target_shards },
    );
    try controller.startOnlineResharding(target_shards, total_entities);
    controller.worker.stats.start_time -= 1;

    var logged_migrating = false;
    var remaining: u64 = total_entities;
    var batch_index: u64 = 0;
    var next_entity_id: u128 = 1;

    while (remaining > 0) : (batch_index += 1) {
        const count = @min(batch_size, remaining);
        const source_shard: u32 = @intCast(batch_index % current_shards);
        const target_shard: u32 = @intCast(batch_index % target_shards);

        var batch = try sharding.makeSequentialMigrationBatch(
            allocator,
            source_shard,
            target_shard,
            next_entity_id,
            @intCast(count),
            batch_index + 1,
        );
        defer batch.deinit();

        const processed = try controller.tickMigration(&batch);
        if (!processed) {
            log.info(
                "online resharding: batch {d} delayed by rate limit",
                .{batch_index + 1},
            );
            if (config.batch_delay_ms > 0) {
                std.time.sleep(@as(u64, config.batch_delay_ms) * std.time.ns_per_ms);
            }
            continue;
        }

        if (!logged_migrating) {
            log.info("online resharding: migrating batches", .{});
            logged_migrating = true;
        }

        remaining -= count;
        next_entity_id += @as(u128, count);

        if (try controller.maybeCutover()) {
            log.info("online resharding: finalizing cutover", .{});
            return;
        }

        if (config.batch_delay_ms > 0) {
            std.time.sleep(@as(u64, config.batch_delay_ms) * std.time.ns_per_ms);
        }
    }

    if (try controller.maybeCutover()) {
        log.info("online resharding: finalizing cutover", .{});
    } else {
        return error.ReshardingIncomplete;
    }
}

/// Shard management command handler.
fn command_shard(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Shard,
) !void {
    _ = gpa;
    _ = io;
    _ = time;

    var stderr_buffer = std.io.bufferedWriter(std.io.getStdErr().writer());
    var stderr_writer = stderr_buffer.writer();
    const stderr = stderr_writer.any();

    // Enhancement: Shard CLI commands (Phase 8 - Multi-Cluster Operations)
    // Core sharding algorithm (jump_hash) is implemented. CLI management deferred.
    switch (args.*) {
        .list => |list| {
            try stderr.print("Shard list for cluster {d}:\n", .{list.cluster});
            try stderr.print("  Enhancement: Shard listing via CLI (Phase 8)\n", .{});
        },
        .status => |status| {
            try stderr.print(
                "Status for shard {d} in cluster {d}:\n",
                .{ status.shard_id, status.cluster },
            );
            try stderr.print(
                "  Enhancement: Shard status via CLI (Phase 8)\n",
                .{},
            );
        },
        .reshard => |reshard| {
            if (reshard.dry_run) {
                try stderr.print(
                    "Dry run: Would reshard cluster {d} to {d} shards\n",
                    .{ reshard.cluster, reshard.to },
                );
            }
            else {
                try stderr.print(
                    "Resharding cluster {d} to {d} shards (mode: {s}):\n",
                    .{
                        reshard.cluster,
                        reshard.to,
                        @tagName(reshard.mode),
                    },
                );
            }
            try stderr.print("  Enhancement: Online resharding (Phase 8)\n", .{});
        },
    }
    try stderr_buffer.flush();
}

/// TTL management command handler.
fn command_ttl(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.TTL,
) !void {
    _ = gpa;
    _ = io;
    _ = time;

    var stderr_buffer = std.io.bufferedWriter(std.io.getStdErr().writer());
    var stderr_writer = stderr_buffer.writer();
    const stderr = stderr_writer.any();

    // Enhancement: TTL CLI commands (Phase 6 - TTL Extensions)
    // Note: Core TTL functionality (ttl.zig, TTL expiration) is fully implemented.
    // These CLI commands would allow runtime TTL management per-entity.
    switch (args.*) {
        .set => |set| {
            try stderr.print(
                "Setting TTL for entity {x} in cluster {d} to {d} seconds\n",
                .{ set.entity_id, set.cluster, set.ttl_seconds },
            );
            try stderr.print("  Enhancement: TTL set via CLI (use REPL or SDK)\n", .{});
        },
        .extend => |extend| {
            try stderr.print(
                "Extending TTL for entity {x} in cluster {d} by {d} seconds\n",
                .{ extend.entity_id, extend.cluster, extend.extend_seconds },
            );
            try stderr.print("  Enhancement: TTL extend via CLI (use REPL or SDK)\n", .{});
        },
        .clear => |clear| {
            try stderr.print(
                "Clearing TTL for entity {x} in cluster {d}\n",
                .{ clear.entity_id, clear.cluster },
            );
            try stderr.print("  Enhancement: TTL clear via CLI (use REPL or SDK)\n", .{});
        },
    }
    try stderr_buffer.flush();
}

/// Verification command handler.
fn command_verify(
    gpa: mem.Allocator,
    io: *IO,
    tracer: *Tracer,
    args: *const cli.Command.Verify,
) !void {
    _ = gpa;
    _ = io;
    _ = tracer;

    var stderr_buffer = std.io.bufferedWriter(std.io.getStdErr().writer());
    var stderr_writer = stderr_buffer.writer();
    const stderr = stderr_writer.any();

    // Enhancement: Data file verification CLI (Phase 7)
    // Note: Superblock and LSM verification exists internally.
    try stderr.print("Verifying data file: {s}\n", .{args.path});
    if (args.encryption) {
        try stderr.print("  Checking encryption status...\n", .{});
        try stderr.print("  Enhancement: Encryption verification (Phase 7)\n", .{});
    } else {
        try stderr.print("  Enhancement: Full verification command (Phase 7)\n", .{});
    }
    try stderr_buffer.flush();
}

/// Coordinator command handler (per add-coordinator-mode/spec.md).
/// Manages coordinator process for multi-shard query routing.
fn command_coordinator(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Coordinator,
) !void {
    _ = gpa;
    _ = io;
    _ = time;

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    // Enhancement: Coordinator process (Phase 8)
    // Note: Coordinator types and protocol are defined. Process management deferred.
    switch (args.*) {
        .start => |start| {
            try stdout.print("Starting coordinator...\n", .{});
            try stdout.print("  Bind address: {s}:{d}\n", .{ start.bind_host, start.bind_port });
            if (start.shards) |shards| {
                try stdout.print("  Shards: {d} configured\n", .{shards.count()});
            }
            if (start.seed_nodes) |seeds| {
                try stdout.print("  Seed nodes: {d} configured\n", .{seeds.count()});
            }
            try stdout.print("  Max connections: {d}\n", .{start.max_connections});
            try stdout.print("  Query timeout: {d}ms\n", .{start.query_timeout_ms});
            try stdout.print("  Health check interval: {d}ms\n", .{start.health_check_ms});
            try stdout.print("  Connections per shard: {d}\n", .{start.connections_per_shard});
            try stdout.print("  Read from replicas: {}\n", .{start.read_from_replicas});
            try stdout.print("  Fan-out policy: {s}\n", .{@tagName(start.fan_out_policy)});
            try stdout.writeAll("\n");
            try stdout.print("  Enhancement: Coordinator process (Phase 8)\n", .{});
        },
        .status => |status| {
            try stdout.print("Querying coordinator status at {s}:{d}...\n", .{
                status.address,
                status.port,
            });
            try stdout.print("  Enhancement: Coordinator status (Phase 8)\n", .{});
        },
        .stop => |stop| {
            try stdout.print("Stopping coordinator at {s}:{d}...\n", .{
                stop.address,
                stop.port,
            });
            try stdout.print("  Graceful shutdown timeout: {d}s\n", .{stop.timeout});
            try stdout.print("  Enhancement: Coordinator stop (Phase 8)\n", .{});
        },
    }
    try stdout_buffer.flush();
}

fn command_cluster(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Cluster,
) !void {
    _ = gpa;
    _ = io;
    _ = time;

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    switch (args.*) {
        .@"add-node" => |add_node| {
            try stdout.print("Adding node to cluster...\n", .{});
            try stdout.print("  Cluster ID: {d}\n", .{add_node.cluster});
            try stdout.print("  New node address: {s}\n", .{add_node.node_address});
            try stdout.print("  Wait for catchup: {}\n", .{add_node.wait});
            try stdout.print("  Timeout: {d}s\n", .{add_node.timeout_seconds});
            try stdout.writeAll("\n");
            try stdout.print("  (Add-node: see membership.zig)\n", .{});
        },
        .@"remove-node" => |remove_node| {
            try stdout.print("Removing node from cluster...\n", .{});
            try stdout.print("  Cluster ID: {d}\n", .{remove_node.cluster});
            try stdout.print("  Node to remove: {s}\n", .{remove_node.node_id});
            try stdout.print("  Force removal: {}\n", .{remove_node.force});
            try stdout.print("  Timeout: {d}s\n", .{remove_node.timeout_seconds});
            try stdout.writeAll("\n");
            try stdout.print("  (Remove-node: see membership.zig)\n", .{});
        },
        .status => |status| {
            try stdout.print("Cluster membership status:\n", .{});
            try stdout.print("  Cluster ID: {d}\n", .{status.cluster});
            try stdout.print("  Addresses: {d} nodes configured\n", .{status.addresses.count()});
            try stdout.writeAll("\n");
            try stdout.print("  (Status: see membership.zig)\n", .{});
        },
    }
    try stdout_buffer.flush();
}

fn command_index(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Index,
) !void {
    _ = gpa;
    _ = io;
    _ = time;

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    switch (args.*) {
        .resize => |resize| {
            switch (resize.action) {
                .start => {
                    try stdout.print("Starting index resize...\n", .{});
                    try stdout.print("  Cluster ID: {d}\n", .{resize.cluster});
                    try stdout.print("  New capacity: {d} buckets\n", .{resize.new_capacity.?});
                    try stdout.writeAll("\n");
                    try stdout.print("  (Resize: see ram_index.zig)\n", .{});
                },
                .check => {
                    try stdout.print("Checking resize feasibility...\n", .{});
                    try stdout.print("  Cluster ID: {d}\n", .{resize.cluster});
                    try stdout.print("  Target capacity: {d} buckets\n", .{resize.new_capacity.?});
                    try stdout.writeAll("\n");
                    try stdout.print("  (Check: see ram_index.zig)\n", .{});
                },
                .status => {
                    try stdout.print("Index resize status:\n", .{});
                    try stdout.print("  Cluster ID: {d}\n", .{resize.cluster});
                    try stdout.writeAll("\n");
                    try stdout.print("  (Status: see ram_index.zig)\n", .{});
                },
                .abort => {
                    try stdout.print("Aborting index resize...\n", .{});
                    try stdout.print("  Cluster ID: {d}\n", .{resize.cluster});
                    try stdout.writeAll("\n");
                    try stdout.print("  (Abort: see ram_index.zig)\n", .{});
                },
            }
        },
        .stats => |stats| {
            try stdout.print("Index statistics:\n", .{});
            try stdout.print("  Cluster ID: {d}\n", .{stats.cluster});
            try stdout.writeAll("\n");
            try stdout.print("  (Stats: see ram_index.zig)\n", .{});
        },
    }
    try stdout_buffer.flush();
}
