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

const benchmark_driver = @import("benchmark_driver.zig");
const backup_runtime = @import("backup_runtime.zig");
const cli = @import("cli.zig");
const encryption = vsr.encryption;
const inspect = @import("inspect.zig");
const metrics_server = @import("metrics_server.zig");
const module_log_levels = @import("observability/module_log_levels.zig");
const observability = vsr.observability;
const coordinator = @import("../coordinator.zig");

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
            .status => |status| status.log_level.toStdLogLevel(),
            .sentinel => .info,
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
        .amqp => |*args| try command_amqp(gpa, &io, time, args),
        .@"export" => |*args| try command_export(gpa, &io, time, args),
        .import => |*args| try command_import(gpa, &io, time, args),
        .shard => |*args| try command_shard(gpa, &io, time, args),
        .ttl => |*args| try command_ttl(gpa, &io, time, args),
        .verify => |*args| try command_verify(gpa, &io, &tracer, args),
        .coordinator => |*args| try command_coordinator(gpa, &io, time, args),
        .cluster => |*args| try command_cluster(gpa, &io, time, args),
        .index => |*args| try command_index(gpa, &io, time, args),
        .upgrade => |*args| try command_upgrade(gpa, args),
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

fn send_reshard_request(metrics_address: std.net.Address, target_shards: u32) !void {
    const socket = std.posix.socket(metrics_address.any.family, std.posix.SOCK.STREAM, 0) catch |err| {
        return err;
    };
    defer std.posix.close(socket);

    std.posix.connect(socket, &metrics_address.any, metrics_address.getOsSockLen()) catch |err| {
        return err;
    };

    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET /control/reshard/{d} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{target_shards},
    ) catch return error.ResponseTooLarge;

    _ = std.posix.write(socket, request) catch |err| {
        return err;
    };

    var response_buf: [4096]u8 = undefined;
    const bytes_read = std.posix.read(socket, &response_buf) catch |err| {
        return err;
    };
    if (bytes_read == 0) return error.EmptyResponse;

    const response = response_buf[0..bytes_read];
    if (std.mem.indexOf(u8, response, " ")) |status_start| {
        const status_line = response[status_start + 1 ..];
        if (std.mem.indexOf(u8, status_line, " ")) |status_end| {
            const status_code = status_line[0..status_end];
            if (std.mem.eql(u8, status_code, "200")) {
                return;
            }
        }
    }

    return error.ReshardingRequestRejected;
}

fn send_index_resize_start_request(
    metrics_address: std.net.Address,
    target_capacity: u64,
) !void {
    const socket = std.posix.socket(metrics_address.any.family, std.posix.SOCK.STREAM, 0) catch |err| {
        return err;
    };
    defer std.posix.close(socket);

    std.posix.connect(socket, &metrics_address.any, metrics_address.getOsSockLen()) catch |err| {
        return err;
    };

    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET /control/index-resize/start/{d} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{target_capacity},
    ) catch return error.ResponseTooLarge;

    _ = std.posix.write(socket, request) catch |err| {
        return err;
    };

    var response_buf: [4096]u8 = undefined;
    const bytes_read = std.posix.read(socket, &response_buf) catch |err| {
        return err;
    };
    if (bytes_read == 0) return error.EmptyResponse;

    const response = response_buf[0..bytes_read];
    if (std.mem.indexOf(u8, response, " ")) |status_start| {
        const status_line = response[status_start + 1 ..];
        if (std.mem.indexOf(u8, status_line, " ")) |status_end| {
            const status_code = status_line[0..status_end];
            if (std.mem.eql(u8, status_code, "200")) return;
        }
    }

    return error.IndexResizeRequestRejected;
}

fn send_index_resize_abort_request(metrics_address: std.net.Address) !void {
    const socket = std.posix.socket(metrics_address.any.family, std.posix.SOCK.STREAM, 0) catch |err| {
        return err;
    };
    defer std.posix.close(socket);

    std.posix.connect(socket, &metrics_address.any, metrics_address.getOsSockLen()) catch |err| {
        return err;
    };

    const request =
        "GET /control/index-resize/abort HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    _ = std.posix.write(socket, request) catch |err| {
        return err;
    };

    var response_buf: [4096]u8 = undefined;
    const bytes_read = std.posix.read(socket, &response_buf) catch |err| {
        return err;
    };
    if (bytes_read == 0) return error.EmptyResponse;

    const response = response_buf[0..bytes_read];
    if (std.mem.indexOf(u8, response, " ")) |status_start| {
        const status_line = response[status_start + 1 ..];
        if (std.mem.indexOf(u8, status_line, " ")) |status_end| {
            const status_code = status_line[0..status_end];
            if (std.mem.eql(u8, status_code, "200")) return;
        }
    }

    return error.IndexResizeAbortRejected;
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
        .development = args.development,
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
    var release_buf: [32]u8 = undefined;
    const release_text = std.fmt.bufPrint(&release_buf, "{}", .{config.process.release}) catch
        "0.0.1";
    const git_commit_text: []const u8 = if (config.process.git_commit) |commit|
        commit[0..]
    else
        "unknown";
    archerdb_metrics.Registry.initBuildInfo(release_text, git_commit_text);
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
                .ram_index_capacity = args.ram_index_capacity,
                // Per ttl-retention/spec.md: Global default TTL configuration
                .default_ttl_days = args.default_ttl_days,
                .memory_mapped_index_enabled = args.memory_mapped_index_enabled,
                .memory_mapped_index_path = mmap_index_path,
                .topology_addresses = args.addresses.const_slice(),
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

    var backup_rt: ?backup_runtime.BackupRuntime = null;
    defer if (backup_rt) |*runtime| runtime.deinit();

    if (args.backup_enabled) {
        backup_rt = backup_runtime.BackupRuntime.init(gpa, .{
            .data_file_path = args.path,
            .cluster_id = replica.cluster,
            .replica_id = replica.replica,
            .replica_count = replica.replica_count,
            .initial_view = replica.view,
            .backup_options = .{
                .enabled = true,
                .provider = args.backup_provider,
                .bucket = args.backup_bucket,
                .region = args.backup_region,
                .endpoint = args.backup_endpoint,
                .credentials_path = args.backup_credentials,
                .access_key_id = args.backup_access_key_id,
                .secret_access_key = args.backup_secret_access_key,
                .url_style = args.backup_url_style,
                .mode = args.backup_mode,
                .encryption = args.backup_encryption,
                .kms_key_id = args.backup_kms_key_id,
                .compression = args.backup_compress,
                .queue_soft_limit = args.backup_queue_soft_limit,
                .queue_hard_limit = args.backup_queue_hard_limit,
                .retention_days = args.backup_retention_days,
                .primary_only = args.backup_primary_only,
            },
        }) catch |err| {
            vsr.fatal(.cli, "backup runtime init failed: {}", .{err});
        };

        const backup_event_bridge = struct {
            fn onReplicaEvent(replica_: *const Replica, event: vsr.ReplicaEvent) void {
                const runtime: *backup_runtime.BackupRuntime = @ptrCast(@alignCast(
                    replica_.test_context.?,
                ));

                switch (event) {
                    .checkpoint_completed => runtime.captureCheckpoint(replica_) catch |err| {
                        log.err("backup checkpoint capture failed: {}", .{err});
                    },
                    else => {},
                }
            }
        };

        replica.test_context = &backup_rt.?;
        replica.event_callback = backup_event_bridge.onReplicaEvent;
    }

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

    const current_shards: u32 = @as(u32, constants.shard_count);
    var topology_manager = sharding.OnlineReshardingController.TopologyManager.init(
        replica.cluster,
        current_shards,
    );
    const online_config = sharding.OnlineReshardingConfig{};
    var resharding_controller = sharding.OnlineReshardingController.init(
        gpa,
        current_shards,
        online_config,
        &topology_manager,
    );
    defer resharding_controller.deinit();

    var resharding_active = false;
    var resharding_remaining: u64 = 0;
    var resharding_batch_index: u64 = 0;
    var resharding_next_entity_id: u128 = 1;
    var resharding_target_shards: u32 = 0;
    var resharding_last_batch_ns: i128 = 0;
    var index_resize_cursor: u64 = 0;
    const index_resize_batch_size: u64 = args.index_resize_batch_size;

    // Track previous view for detecting view changes
    var prev_view: u32 = replica.view;

    // Track whether we've marked the server as initialized for the readiness probe
    var server_marked_initialized = false;

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

        // Mark server as initialized once replica reaches normal status
        // This enables the /health/ready endpoint to return 200 OK
        if (!server_marked_initialized and replica.status == .normal) {
            metrics_server.markInitialized();
            server_marked_initialized = true;
        }

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

        const shard_count_val = archerdb_metrics.Registry.shard_count.load(.monotonic);
        var hot_shard_id: i64 = -1;
        var hot_shard_score: f64 = 0.0;
        const rebalance_decision = metrics_server.computeRebalanceDecision(
            shard_count_val,
            resharding_active,
            &hot_shard_id,
            &hot_shard_score,
        );
        if (!resharding_active and rebalance_decision.rebalance_needed == 1 and
            rebalance_decision.target_shards > 0)
        {
            if (metrics_server.queueReshardingRequest(rebalance_decision.target_shards)) {
                metrics_server.recordRebalanceTrigger();
                log.info(
                    "auto-reshard trigger: target_shards={d}",
                    .{rebalance_decision.target_shards},
                );
            }
        }

        if (!resharding_active) {
            if (metrics_server.takeReshardingRequest()) |target_shards| {
                const batch_size: u64 = @max(@as(u64, online_config.batch_size), 1);
                const total_entities: u64 = batch_size * 8;

                resharding_target_shards = target_shards;
                resharding_remaining = total_entities;
                resharding_batch_index = 0;
                resharding_next_entity_id = 1;
                resharding_last_batch_ns = 0;

                log.info(
                    "online resharding: preparing migration of {} entities to {d} shards",
                    .{ total_entities, target_shards },
                );
                if (resharding_controller.startOnlineResharding(
                    target_shards,
                    total_entities,
                )) |_| {
                    resharding_active = true;
                } else |err| {
                    log.err("online resharding: start failed: {}", .{err});
                }
            }
        }

        if (resharding_active) {
            const now_ns_raw = std.time.nanoTimestamp();
            const now_ns: i128 = if (now_ns_raw < 0) 0 else now_ns_raw;
            const delay_ns: i128 = @as(i128, @intCast(online_config.batch_delay_ms)) *
                std.time.ns_per_ms;

            if (resharding_last_batch_ns == 0 or now_ns - resharding_last_batch_ns >= delay_ns) {
                const count: u64 = @min(
                    @as(u64, @max(@as(u64, online_config.batch_size), 1)),
                    resharding_remaining,
                );
                if (count == 0) {
                    var did_cutover = false;
                    if (resharding_controller.maybeCutover()) |cutover| {
                        did_cutover = cutover;
                    } else |err| {
                        log.err("online resharding: cutover failed: {}", .{err});
                        resharding_controller.cancel("online resharding failed");
                        resharding_active = false;
                    }
                    if (did_cutover) {
                        log.info("online resharding: finalizing cutover", .{});
                        resharding_active = false;
                    }
                } else {
                    const source_shard: u32 = @intCast(resharding_batch_index % current_shards);
                    const target_shard: u32 = @intCast(resharding_batch_index % resharding_target_shards);

                    var batch = sharding.makeSequentialMigrationBatch(
                        gpa,
                        source_shard,
                        target_shard,
                        resharding_next_entity_id,
                        @intCast(count),
                        resharding_batch_index + 1,
                    ) catch |err| {
                        log.err("online resharding: batch alloc failed: {}", .{err});
                        resharding_controller.cancel("online resharding failed");
                        resharding_active = false;
                        continue;
                    };
                    defer batch.deinit();

                    var processed = false;
                    if (resharding_controller.tickMigration(&batch)) |ok| {
                        processed = ok;
                    } else |err| {
                        log.err("online resharding: migration batch failed: {}", .{err});
                        resharding_controller.cancel("online resharding failed");
                        resharding_active = false;
                    }

                    resharding_last_batch_ns = now_ns;
                    if (processed) {
                        resharding_remaining -= count;
                        resharding_next_entity_id += @as(u128, count);
                        resharding_batch_index += 1;

                        var did_cutover = false;
                        if (resharding_controller.maybeCutover()) |cutover| {
                            did_cutover = cutover;
                        } else |err| {
                            log.err("online resharding: cutover failed: {}", .{err});
                            resharding_controller.cancel("online resharding failed");
                            resharding_active = false;
                        }
                        if (did_cutover) {
                            log.info("online resharding: finalizing cutover", .{});
                            resharding_active = false;
                        } else if (resharding_remaining == 0) {
                            log.err("online resharding: cutover did not trigger", .{});
                            resharding_controller.cancel("online resharding failed");
                            resharding_active = false;
                        }
                    }
                }
            }
        }

        if (metrics_server.takeIndexResizeRequest()) |target_capacity| {
            replica.state_machine.ram_index.startResize(gpa, target_capacity) catch |err| {
                log.err("index resize: start failed for capacity {d}: {}", .{
                    target_capacity,
                    err,
                });
            };
            index_resize_cursor = 0;
        }

        if (metrics_server.takeIndexResizeAbort()) {
            replica.state_machine.ram_index.abortResize(gpa);
            index_resize_cursor = 0;
        }

        const resize_progress = replica.state_machine.ram_index.getResizeProgress();
        switch (resize_progress.state) {
            .resizing => {
                _ = replica.state_machine.ram_index.migrateEntryBatch(
                    index_resize_cursor,
                    index_resize_batch_size,
                );
                index_resize_cursor += index_resize_batch_size;

                const progress_after = replica.state_machine.ram_index.getResizeProgress();
                if (progress_after.total_entries == 0 or
                    progress_after.entries_migrated >= progress_after.total_entries or
                    index_resize_cursor >= progress_after.old_capacity)
                {
                    replica.state_machine.ram_index.completeResize(gpa) catch |err| {
                        log.err("index resize: complete failed: {}", .{err});
                    };
                    index_resize_cursor = 0;
                }
            },
            .completing => {
                replica.state_machine.ram_index.completeResize(gpa) catch |err| {
                    log.err("index resize: complete failed: {}", .{err});
                };
                index_resize_cursor = 0;
            },
            .normal, .aborted => index_resize_cursor = 0,
        }

        if (backup_rt) |*runtime| {
            runtime.tick(&replica, storage);
        }

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
        .development = args.development,
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

fn command_amqp(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.AMQP,
) !void {
    const amqp = vsr.cdc.amqp;
    const data_export = vsr.data_export;
    const archerdb_types = vsr.archerdb;

    const stderr = std.io.getStdErr().writer();
    const tick_ns = constants.tick_ms * std.time.ns_per_ms;
    const publish_exchange = args.publish_exchange orelse "";
    const publish_routing_key = args.publish_routing_key;
    const event_count_limit: usize = args.event_count_max orelse std.math.maxInt(u32);
    const idle_interval_ns: u64 = @as(u64, args.idle_interval_ms orelse 0) * std.time.ns_per_ms;
    const request_interval_ns: u64 = if (args.requests_per_second_limit) |limit|
        @divFloor(std.time.ns_per_s, limit)
    else
        0;

    const WaitState = struct {
        var pending: bool = false;
        fn callback(_: *amqp.Client) void {
            @This().pending = false;
        }
    };

    const MessageBody = struct {
        fn fromSlice(bytes: *const []const u8) amqp.Encoder.Body {
            const VTable = struct {
                fn write(context: *const anyopaque, buffer: []u8) usize {
                    const slice: *const []const u8 = @ptrCast(@alignCast(context));
                    @memcpy(buffer[0..slice.*.len], slice.*);
                    return slice.*.len;
                }
            };
            return .{
                .context = @ptrCast(bytes),
                .vtable = &.{
                    .write = VTable.write,
                },
            };
        }
    };

    try stderr.print(
        \\ArcherDB AMQP Bridge
        \\====================
        \\Exchange: {s}
        \\Routing: {s}
        \\Since:   {d}
        \\Limit:   {}
        \\
    , .{
        if (publish_exchange.len > 0) publish_exchange else "<default>",
        publish_routing_key orelse "<dynamic geo.events.*>",
        args.timestamp_last orelse 0,
        event_count_limit,
    });

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
            .eviction_callback = &export_client_eviction_callback,
        },
    );
    defer client.deinit(gpa);

    var amqp_client = try amqp.Client.init(gpa, .{
        .io = io,
        .message_count_max = 1024,
        .message_body_size_max = 4096,
        .reply_timeout_ticks = 10_000,
    });
    defer amqp_client.deinit(gpa);

    const Pump = struct {
        fn tick(io_ptr: *IO, db_client: *Client, broker_client: *amqp.Client) !void {
            db_client.tick();
            broker_client.tick();
            try io_ptr.run_for_ns(tick_ns);
        }

        fn wait(
            io_ptr: *IO,
            db_client: *Client,
            broker_client: *amqp.Client,
            max_ticks: usize,
        ) !void {
            for (0..max_ticks) |_| {
                try tick(io_ptr, db_client, broker_client);
                if (!WaitState.pending) return;
            }
            return error.Timeout;
        }

        fn sleep(
            io_ptr: *IO,
            db_client: *Client,
            broker_client: *amqp.Client,
            duration_ns: u64,
        ) !void {
            var remaining = duration_ns;
            while (remaining > 0) {
                try tick(io_ptr, db_client, broker_client);
                remaining -|= @min(remaining, tick_ns);
            }
        }
    };

    var registered = false;
    client.register(&export_register_callback, @intFromPtr(&registered));
    while (!registered) {
        client.tick();
        try io.run_for_ns(tick_ns);
    }

    WaitState.pending = true;
    try amqp_client.connect(WaitState.callback, .{
        .host = args.host,
        .user_name = args.user,
        .password = args.password,
        .vhost = args.vhost,
    });
    try Pump.wait(io, &client, &amqp_client, 10_000);

    if (publish_exchange.len > 0) {
        WaitState.pending = true;
        amqp_client.exchange_declare(WaitState.callback, .{
            .exchange = publish_exchange,
            .type = "topic",
            .passive = false,
            .durable = true,
            .auto_delete = false,
            .internal = false,
        });
        try Pump.wait(io, &client, &amqp_client, 10_000);
    }

    var exporter = data_export.DataExporter.init(gpa, .{
        .format = .ndjson,
        .include_metadata = false,
        .pretty = false,
    });

    var watermark = args.timestamp_last orelse 0;
    var published_total: usize = 0;
    var poll_round: usize = 0;

    try stderr.print("Connected. Polling and publishing...\n", .{});

    while (published_total < event_count_limit) {
        poll_round += 1;

        var events_to_publish = std.ArrayList(archerdb_types.GeoEvent).init(gpa);
        defer events_to_publish.deinit();

        var cursor_timestamp: u64 = 0;
        const newest_seen_before_round = watermark;

        while (published_total + events_to_publish.items.len < event_count_limit) {
            const remaining = event_count_limit - published_total - events_to_publish.items.len;
            const page_limit: u32 = @intCast(@min(@as(usize, 1000), remaining));
            if (page_limit == 0) break;

            var filter = archerdb_types.QueryLatestFilter{
                .limit = page_limit,
                .group_id = 0,
                .cursor_timestamp = cursor_timestamp,
            };

            var response_state = ExportResponseState{
                .received = false,
                .results = null,
                .results_len = 0,
                .has_more = false,
                .next_cursor = 0,
            };

            client.request(
                &export_request_callback,
                @intFromPtr(&response_state),
                .query_latest,
                std.mem.asBytes(&filter),
            );

            while (!response_state.received) {
                try Pump.tick(io, &client, &amqp_client);
            }

            if (response_state.results == null or response_state.results_len == 0) break;

            const page_events = @as(
                [*]const archerdb_types.GeoEvent,
                @ptrCast(@alignCast(response_state.results.?)),
            )[0..response_state.results_len];

            var reached_watermark = false;
            for (page_events) |event| {
                if (watermark > 0 and event.timestamp <= watermark) {
                    reached_watermark = true;
                    break;
                }
                try events_to_publish.append(event);
            }

            if (reached_watermark or !response_state.has_more) break;
            cursor_timestamp = response_state.next_cursor;
        }

        if (events_to_publish.items.len == 0) {
            if (idle_interval_ns == 0) break;
            try Pump.sleep(io, &client, &amqp_client, idle_interval_ns);
            continue;
        }

        var newest_published = newest_seen_before_round;
        var json_buffer: [4096]u8 = undefined;
        var index = events_to_publish.items.len;
        while (index > 0) : (index -= 1) {
            const event = events_to_publish.items[index - 1];
            var stream = std.io.fixedBufferStream(&json_buffer);
            try exporter.writeEvent(stream.writer(), &event);
            var payload = stream.getWritten();
            if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                payload = payload[0 .. payload.len - 1];
            }

            var routing_key_buffer: [96]u8 = undefined;
            const routing_key = if (publish_routing_key) |key|
                key
            else
                try std.fmt.bufPrint(&routing_key_buffer, "geo.events.{x}", .{
                    @as(u64, @truncate(event.entity_id)),
                });

            amqp_client.publish_enqueue(.{
                .exchange = publish_exchange,
                .routing_key = routing_key,
                .mandatory = false,
                .immediate = false,
                .properties = .{
                    .content_type = "application/json",
                    .delivery_mode = .persistent,
                    .timestamp = @intCast(@divFloor(event.timestamp, std.time.ns_per_s)),
                },
                .body = MessageBody.fromSlice(&payload),
            });

            newest_published = @max(newest_published, event.timestamp);
            published_total += 1;
        }

        WaitState.pending = true;
        amqp_client.publish_send(WaitState.callback);
        try Pump.wait(io, &client, &amqp_client, 10_000);

        watermark = newest_published;
        try stderr.print(
            "  round {}: published {} events, watermark={}\n",
            .{ poll_round, events_to_publish.items.len, watermark },
        );

        if (published_total >= event_count_limit) break;
        if (idle_interval_ns == 0) break;
        if (request_interval_ns > 0) {
            try Pump.sleep(io, &client, &amqp_client, request_interval_ns);
        } else {
            try Pump.sleep(io, &client, &amqp_client, idle_interval_ns);
        }
    }

    try stderr.print(
        \\
        \\Publish complete: {} events published. Final watermark={}
        \\
    , .{ published_total, watermark });
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
//
// Connects to a running ArcherDB cluster via the client protocol and exports
// events using the query_latest operation with cursor-based pagination.
// Supports JSON, GeoJSON, NDJSON, and CSV output formats.
fn command_export(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Export,
) !void {
    const data_export = vsr.data_export;
    const data_export_csv = vsr.data_export_csv;
    const archerdb_types = vsr.archerdb;

    const stderr = std.io.getStdErr().writer();

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

    try stderr.print(
        \\ArcherDB Export
        \\===============
        \\Format: {s}
        \\Output: {s}
        \\
    , .{
        @tagName(args.format),
        args.output orelse "stdout",
    });

    if (args.entity_id) |eid| {
        try stderr.print("Entity filter: {s}\n", .{eid});
    }
    if (args.limit > 0) {
        try stderr.print("Limit: {} events\n", .{args.limit});
    }
    try stderr.print("Connecting to cluster...\n", .{});

    // Initialize message pool and client to connect to the running cluster
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
            .eviction_callback = &export_client_eviction_callback,
        },
    );
    defer client.deinit(gpa);

    // Register client session with the cluster
    var registered = false;
    client.register(&export_register_callback, @intFromPtr(&registered));

    while (!registered) {
        client.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }

    try stderr.print("Connected. Exporting events...\n", .{});

    // Set up the format-specific exporter and write header
    var json_exporter: data_export.DataExporter = undefined;
    var csv_exporter: data_export_csv.CsvExporter = undefined;
    const is_csv = args.format == .csv;

    if (is_csv) {
        csv_exporter = data_export_csv.CsvExporter.init(gpa, .{});
        try csv_exporter.writeHeader(output_writer);
    } else {
        const export_format: data_export.ExportFormat = switch (args.format) {
            .json => .json,
            .geojson => .geojson,
            .ndjson => .ndjson,
            .csv => unreachable,
        };
        json_exporter = data_export.DataExporter.init(gpa, .{
            .format = export_format,
            .include_metadata = args.include_metadata,
            .pretty = args.pretty,
        });
        try json_exporter.writeHeader(output_writer);
    }

    // Paginated export using query_latest with cursor
    var cursor_timestamp: u64 = 0; // 0 = start from latest
    var total_exported: usize = 0;
    var done = false;
    const page_limit: u32 = 1000;

    while (!done) {
        // Build the query_latest filter
        var filter = archerdb_types.QueryLatestFilter{
            .limit = page_limit,
            .group_id = 0, // All groups
            .cursor_timestamp = cursor_timestamp,
        };
        _ = &filter;

        // Send request and wait for response
        var response_state = ExportResponseState{
            .received = false,
            .results = null,
            .results_len = 0,
            .has_more = false,
            .next_cursor = 0,
        };

        client.request(
            &export_request_callback,
            @intFromPtr(&response_state),
            .query_latest,
            std.mem.asBytes(&filter),
        );

        // Drive IO until we get a response
        while (!response_state.received) {
            client.tick();
            try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
        }

        // Process the response
        if (response_state.results) |results_ptr| {
            const events_in_page = response_state.results_len;

            if (events_in_page == 0) {
                done = true;
                break;
            }

            const events = @as(
                [*]const archerdb_types.GeoEvent,
                @ptrCast(@alignCast(results_ptr)),
            )[0..events_in_page];

            for (events) |*event| {
                // Apply client-side filters
                if (args.start_time) |start| {
                    if (event.timestamp < start) continue;
                }
                if (args.end_time) |end| {
                    if (event.timestamp > end) continue;
                }

                // Write event in the chosen format
                if (is_csv) {
                    try csv_exporter.writeRow(output_writer, event);
                } else {
                    try json_exporter.writeEvent(output_writer, event);
                }

                total_exported += 1;

                // Check limit
                if (args.limit > 0 and total_exported >= args.limit) {
                    done = true;
                    break;
                }
            }

            // Advance cursor for next page
            if (response_state.has_more and !done) {
                cursor_timestamp = response_state.next_cursor;
            } else {
                done = true;
            }
        } else {
            // No results or error
            done = true;
        }

        // Periodic progress on stderr
        if (total_exported > 0 and total_exported % 10000 == 0) {
            try stderr.print("  ... exported {} events\n", .{total_exported});
        }
    }

    // Write format footer
    if (!is_csv) {
        try json_exporter.writeFooter(output_writer);
    }

    // Flush output
    try output_buffered.flush();

    try stderr.print(
        \\
        \\Export complete: {} events exported.
        \\
    , .{total_exported});
}

/// State passed through user_data pointer for export request callbacks.
const ExportResponseState = struct {
    received: bool,
    results: ?[*]const u8,
    results_len: usize,
    has_more: bool,
    next_cursor: u64,
};

fn export_request_callback(
    user_data: u128,
    operation: vsr.Operation,
    timestamp: u64,
    results: []u8,
) void {
    _ = operation;
    _ = timestamp;
    const archerdb_types = vsr.archerdb;

    const state: *ExportResponseState = @ptrFromInt(@as(usize, @intCast(user_data)));
    state.received = true;

    // Parse QueryResponse header followed by GeoEvent array
    if (results.len >= @sizeOf(archerdb_types.QueryResponse)) {
        const response_header = std.mem.bytesAsValue(
            archerdb_types.QueryResponse,
            results[0..@sizeOf(archerdb_types.QueryResponse)],
        );

        const event_data = results[@sizeOf(archerdb_types.QueryResponse)..];
        const event_count = response_header.count;

        if (event_count > 0 and event_data.len >= event_count * @sizeOf(archerdb_types.GeoEvent)) {
            state.results = event_data.ptr;
            state.results_len = event_count;
            state.has_more = response_header.has_more == 1;

            // Extract cursor from the last event's timestamp for pagination
            const events = @as(
                [*]const archerdb_types.GeoEvent,
                @ptrCast(@alignCast(event_data.ptr)),
            )[0..event_count];
            state.next_cursor = events[event_count - 1].timestamp;
        } else {
            state.results = null;
            state.results_len = 0;
            state.has_more = false;
        }
    } else {
        state.results = null;
        state.results_len = 0;
        state.has_more = false;
    }
}

fn export_register_callback(user_data: u128, result: *const vsr.RegisterResult) void {
    _ = result;
    const registered: *bool = @ptrFromInt(@as(usize, @intCast(user_data)));
    registered.* = true;
}

fn export_client_eviction_callback(
    client: *Client,
    eviction: *const MessagePool.Message.Eviction,
) void {
    _ = client;
    log.err("export client evicted: {s}", .{@tagName(eviction.header.reason)});
}

// Data Import command (F-Data-Portability)
fn command_import(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Import,
) !void {
    const GeoEvent = vsr.archerdb.GeoEvent;
    const Operation = StateMachine.Operation;
    // Use vsr module's data_export to avoid duplicate module issues
    const data_export = vsr.data_export;
    const data_export_csv = vsr.data_export_csv;

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

    // Phase 1: Parse all events into a buffer
    var parsed_events = std.ArrayList(GeoEvent).init(gpa);
    defer parsed_events.deinit();

    var parse_failed: usize = 0;

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
                    if (result) |event| {
                        try parsed_events.append(event);
                    } else |_| {
                        parse_failed += 1;
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
                        if (result) |event| {
                            try parsed_events.append(event);
                        } else |_| {
                            parse_failed += 1;
                            if (!args.skip_errors) break;
                        }
                    }
                    pos = feature_end;
                }
            }
        },
        .csv => {
            try stderr.print("CSV import parsing...\n", .{});

            var importer = try data_export_csv.CsvImporter.init(gpa, .{});
            defer importer.deinit();

            var lines = std.mem.splitScalar(u8, content.items, '\n');
            var first_nonempty_line = true;

            while (lines.next()) |raw_line| {
                const line = std.mem.trimRight(u8, raw_line, "\r");
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

                if (first_nonempty_line) {
                    first_nonempty_line = false;

                    const looks_like_header =
                        std.mem.indexOf(u8, line, "latitude") != null or
                        std.mem.indexOf(u8, line, "longitude") != null or
                        std.mem.indexOf(u8, line, "entity_id") != null or
                        std.mem.indexOf(u8, line, "timestamp") != null;

                    if (looks_like_header) {
                        importer.parseHeader(line) catch |err| {
                            parse_failed += 1;
                            if (!args.skip_errors) return err;
                        };
                        continue;
                    }
                }

                const result = importer.parseRow(line);
                if (result) |event| {
                    try parsed_events.append(event);
                } else |_| {
                    parse_failed += 1;
                    if (!args.skip_errors) {
                        log.err("Failed to parse CSV row, stopping import", .{});
                        break;
                    }
                }
            }
        },
    }

    const total_parsed = parsed_events.items.len;

    if (args.progress) {
        try stderr.print("Parsed {} events ({} parse failures)\n", .{ total_parsed, parse_failed });
    }

    // Phase 2: Send parsed events to the cluster (unless dry-run)
    var events_sent: usize = 0;
    var events_send_failed: usize = 0;

    if (!args.dry_run and total_parsed > 0) {
        try stderr.print("Registering client session with cluster...\n", .{});

        // Register client session with the cluster (required before sending requests)
        import_register_done = false;
        client.register(&import_register_callback, 0);
        while (!import_register_done) {
            client.tick();
            try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
        }

        try stderr.print("Sending {} events to cluster...\n", .{total_parsed});

        // Calculate maximum events per batch based on the client's batch_size_limit
        const batch_size_limit = client.batch_size_limit orelse constants.message_body_size_max;
        const max_events_per_batch = batch_size_limit / @sizeOf(GeoEvent);
        if (max_events_per_batch == 0) {
            log.err("batch_size_limit ({}) too small for a single GeoEvent ({})", .{
                batch_size_limit,
                @sizeOf(GeoEvent),
            });
            return error.BatchSizeTooSmall;
        }
        const configured_batch_size = @max(@as(usize, args.batch_size), 1);
        const events_per_batch = @min(max_events_per_batch, configured_batch_size);

        // Send events in batches
        var offset: usize = 0;
        var batch_num: usize = 0;
        while (offset < total_parsed) {
            const batch_end = @min(offset + events_per_batch, total_parsed);
            const batch = parsed_events.items[offset..batch_end];
            const batch_bytes = std.mem.sliceAsBytes(batch);

            // Submit request and wait for completion
            import_request_done = false;
            import_request_err = false;
            client.request(
                &import_request_callback,
                0,
                Operation.insert_events,
                batch_bytes,
            );

            // Drive the IO loop until the request completes
            while (!import_request_done) {
                client.tick();
                try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
            }

            if (import_request_err) {
                events_send_failed += batch.len;
            } else {
                events_sent += batch.len;
            }

            batch_num += 1;
            offset = batch_end;

            // Progress reporting every 10 batches or on the last batch
            if (args.progress and (batch_num % 10 == 0 or offset == total_parsed)) {
                try stderr.print(
                    "  Progress: {}/{} events sent ({} batches)\n",
                    .{ offset, total_parsed, batch_num },
                );
            }
        }
    }

    if (args.progress) {
        try stderr.print(
            \\
            \\Import Summary
            \\==============
            \\Events parsed: {}
            \\Parse failures: {}
            \\Events sent: {}
            \\Send failures: {}
            \\Dry run: {}
            \\
        , .{
            total_parsed,
            parse_failed,
            events_sent,
            events_send_failed,
            args.dry_run,
        });
    }

    if (args.dry_run and total_parsed > 0) {
        try stderr.print(
            "Dry run complete. {} events validated successfully.\n",
            .{total_parsed},
        );
    }
}

// Import command state for async callbacks.
// These file-level variables are used to synchronize the import command's
// synchronous send loop with the client's asynchronous callback mechanism.
var import_register_done: bool = false;
var import_request_done: bool = false;
var import_request_err: bool = false;

fn import_register_callback(user_data: u128, result: *const vsr.RegisterResult) void {
    _ = user_data;
    _ = result;
    import_register_done = true;
}

fn import_request_callback(
    user_data: u128,
    operation: vsr.Operation,
    timestamp: u64,
    results: []u8,
) void {
    _ = user_data;
    _ = operation;
    _ = timestamp;

    // Check individual event results for errors
    const InsertGeoEventsResult = vsr.archerdb.InsertGeoEventsResult;
    if (results.len > 0 and results.len % @sizeOf(InsertGeoEventsResult) == 0) {
        const result_slice = stdx.bytes_as_slice(.exact, InsertGeoEventsResult, results);
        for (result_slice) |r| {
            if (r.result != .ok) {
                import_request_err = true;
                log.warn("insert error at index {}: {}", .{ r.index, r.result });
            }
        }
    }

    import_request_done = true;
}

fn import_client_eviction_callback(
    client: *Client,
    eviction: *const MessagePool.Message.Eviction,
) void {
    _ = client;
    log.err("import client evicted: {s}", .{@tagName(eviction.header.reason)});
    // Signal request done so the import loop can exit gracefully
    import_request_done = true;
    import_request_err = true;
    import_register_done = true;
}

const SyncRegisterState = struct {
    registered: bool = false,
};

const SyncRequestState = struct {
    received: bool = false,
    response_buffer: []u8,
    response_len: usize = 0,
    response_truncated: bool = false,
    timestamp: u64 = 0,
};

const NodeStatusResult = struct {
    ok: bool = false,
    response: vsr.archerdb.StatusResponse = std.mem.zeroes(vsr.archerdb.StatusResponse),
    error_name: ?[]const u8 = null,
};

fn sync_register_callback(user_data: u128, result: *const vsr.RegisterResult) void {
    _ = result;
    const state: *SyncRegisterState = @ptrFromInt(@as(usize, @intCast(user_data)));
    state.registered = true;
}

fn sync_request_callback(
    user_data: u128,
    operation: vsr.Operation,
    timestamp: u64,
    results: []u8,
) void {
    _ = operation;

    const state: *SyncRequestState = @ptrFromInt(@as(usize, @intCast(user_data)));
    const copy_len = @min(results.len, state.response_buffer.len);
    if (copy_len > 0) {
        @memcpy(state.response_buffer[0..copy_len], results[0..copy_len]);
    }
    state.received = true;
    state.response_len = copy_len;
    state.response_truncated = results.len > state.response_buffer.len;
    state.timestamp = timestamp;
}

fn sync_client_eviction_callback(
    client: *Client,
    eviction: *const MessagePool.Message.Eviction,
) void {
    _ = client;
    log.warn("control client evicted: {s}", .{@tagName(eviction.header.reason)});
}

fn register_client_sync(client: *Client, io: *IO) !void {
    var state = SyncRegisterState{};
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = 10 * std.time.ns_per_s;

    client.register(&sync_register_callback, @intFromPtr(&state));

    while (!state.registered) {
        if (std.time.nanoTimestamp() - start_ns > timeout_ns) {
            return error.Timeout;
        }

        client.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }
}

fn request_client_sync(
    client: *Client,
    io: *IO,
    operation: StateMachine.Operation,
    payload: []const u8,
    response_buffer: []u8,
) ![]const u8 {
    var state = SyncRequestState{ .response_buffer = response_buffer };
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = 10 * std.time.ns_per_s;

    client.request(&sync_request_callback, @intFromPtr(&state), operation, payload);

    while (!state.received) {
        if (std.time.nanoTimestamp() - start_ns > timeout_ns) {
            return error.Timeout;
        }

        client.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }

    if (state.response_truncated) return error.ResponseTooLarge;
    return response_buffer[0..state.response_len];
}

fn query_single_node_status(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    cluster_id: u128,
    address: std.net.Address,
) NodeStatusResult {
    var message_pool = MessagePool.init(gpa, .client) catch |err| {
        return .{ .error_name = @errorName(err) };
    };
    defer message_pool.deinit(gpa);

    const addresses = [_]std.net.Address{address};
    var client = Client.init(
        gpa,
        time,
        &message_pool,
        .{
            .id = stdx.unique_u128(),
            .cluster = cluster_id,
            .replica_count = 1,
            .message_bus_options = .{
                .configuration = &addresses,
                .io = io,
                .clients_limit = null,
            },
            .eviction_callback = &sync_client_eviction_callback,
        },
    ) catch |err| {
        return .{ .error_name = @errorName(err) };
    };
    defer {
        client.shutdown(io, 5 * std.time.ns_per_s) catch |err| {
            log.warn("query_single_node_status: client shutdown error={s}", .{
                @errorName(err),
            });
        };
        client.deinit(gpa);
    }

    register_client_sync(&client, io) catch |err| {
        return .{ .error_name = @errorName(err) };
    };

    var request = vsr.archerdb.StatusRequest{};
    var response_buffer: [@sizeOf(vsr.archerdb.StatusResponse)]u8 = undefined;
    const response_bytes = request_client_sync(
        &client,
        io,
        .archerdb_get_status,
        mem.asBytes(&request),
        &response_buffer,
    ) catch |err| {
        return .{ .error_name = @errorName(err) };
    };

    if (response_bytes.len < @sizeOf(vsr.archerdb.StatusResponse)) {
        return .{ .error_name = "short_response" };
    }

    return .{
        .ok = true,
        .response = mem.bytesAsValue(
            vsr.archerdb.StatusResponse,
            response_bytes[0..@sizeOf(vsr.archerdb.StatusResponse)],
        ).*,
    };
}

fn format_net_address(address: std.net.Address, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{}", .{address}) catch "<invalid-address>";
}

fn print_not_implemented(
    stdout: anytype,
    format: cli.Command.OutputFormat,
    feature: []const u8,
    detail: []const u8,
) !void {
    switch (format) {
        .json => try stdout.print(
            "{{\"error\":\"not_implemented\",\"feature\":\"{s}\",\"message\":\"{s}\"}}\n",
            .{ feature, detail },
        ),
        .text => try stdout.print("{s}: {s}\n", .{ feature, detail }),
    }
}

fn run_online_resharding(
    allocator: mem.Allocator,
    cluster_id: u128,
    target_shards: u32,
    online_config: sharding.OnlineReshardingConfig,
) !void {
    const current_shards: u32 = @as(u32, constants.shard_count);
    const batch_size: u64 = @max(@as(u64, online_config.batch_size), 1);
    const total_entities: u64 = batch_size * 8;

    var topology_manager = sharding.OnlineReshardingController.TopologyManager.init(
        cluster_id,
        current_shards,
    );
    var controller = sharding.OnlineReshardingController.init(
        allocator,
        current_shards,
        online_config,
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
            if (online_config.batch_delay_ms > 0) {
                std.time.sleep(@as(u64, online_config.batch_delay_ms) * std.time.ns_per_ms);
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

        if (online_config.batch_delay_ms > 0) {
            std.time.sleep(@as(u64, online_config.batch_delay_ms) * std.time.ns_per_ms);
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
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    switch (args.*) {
        .list => |list| {
            const addresses = list.addresses.const_slice();
            if (list.format == .json) {
                try stdout.writeAll("[\n");
                for (addresses, 0..) |address, index| {
                    const status = query_single_node_status(gpa, io, time, list.cluster, address);
                    var address_buf: [128]u8 = undefined;
                    const address_text = format_net_address(address, &address_buf);

                    if (index > 0) try stdout.writeAll(",\n");
                    if (status.ok) {
                        try stdout.print(
                            "  {{\"shard_id\":{d},\"address\":\"{s}\",\"status\":\"active\",\"ram_index_count\":{d},\"ram_index_capacity\":{d},\"ram_index_load_pct\":{d},\"ttl_expirations\":{d},\"deletion_count\":{d}}}",
                            .{
                                index,
                                address_text,
                                status.response.ram_index_count,
                                status.response.ram_index_capacity,
                                status.response.ram_index_load_pct,
                                status.response.ttl_expirations,
                                status.response.deletion_count,
                            },
                        );
                    } else {
                        try stdout.print(
                            "  {{\"shard_id\":{d},\"address\":\"{s}\",\"status\":\"unavailable\",\"error\":\"{s}\"}}",
                            .{ index, address_text, status.error_name orelse "unknown" },
                        );
                    }
                }
                try stdout.writeAll("\n]\n");
            } else {
                try stdout.print("Shard list for cluster {d}:\n", .{list.cluster});
                for (addresses, 0..) |address, index| {
                    const status = query_single_node_status(gpa, io, time, list.cluster, address);
                    const load_pct = if (status.ok)
                        @as(f64, @floatFromInt(status.response.ram_index_load_pct)) / 100.0
                    else
                        0.0;

                    if (status.ok) {
                        try stdout.print(
                            "  shard {d}: {} active ram_index={d}/{d} load={d:.2}% ttl_expirations={d} deletions={d}\n",
                            .{
                                index,
                                address,
                                status.response.ram_index_count,
                                status.response.ram_index_capacity,
                                load_pct,
                                status.response.ttl_expirations,
                                status.response.deletion_count,
                            },
                        );
                    } else {
                        try stdout.print(
                            "  shard {d}: {} unavailable ({s})\n",
                            .{ index, address, status.error_name orelse "unknown" },
                        );
                    }
                }
            }
        },
        .status => |status| {
            const addresses = status.addresses.const_slice();
            const shard_index: usize = std.math.cast(usize, status.shard_id) orelse
                return error.ShardIdOutOfRange;
            if (shard_index >= addresses.len) return error.ShardIdOutOfRange;

            const address = addresses[shard_index];
            const result = query_single_node_status(gpa, io, time, status.cluster, address);
            var address_buf: [128]u8 = undefined;
            const address_text = format_net_address(address, &address_buf);

            if (status.format == .json) {
                if (result.ok) {
                    try stdout.print(
                        "{{\"cluster\":{d},\"shard_id\":{d},\"address\":\"{s}\",\"status\":\"active\",\"ram_index_count\":{d},\"ram_index_capacity\":{d},\"ram_index_load_pct\":{d},\"tombstone_count\":{d},\"ttl_expirations\":{d},\"deletion_count\":{d}}}\n",
                        .{
                            status.cluster,
                            status.shard_id,
                            address_text,
                            result.response.ram_index_count,
                            result.response.ram_index_capacity,
                            result.response.ram_index_load_pct,
                            result.response.tombstone_count,
                            result.response.ttl_expirations,
                            result.response.deletion_count,
                        },
                    );
                } else {
                    try stdout.print(
                        "{{\"cluster\":{d},\"shard_id\":{d},\"address\":\"{s}\",\"status\":\"unavailable\",\"error\":\"{s}\"}}\n",
                        .{
                            status.cluster,
                            status.shard_id,
                            address_text,
                            result.error_name orelse "unknown",
                        },
                    );
                }
            } else {
                try stdout.print("Status for shard {d} in cluster {d}:\n", .{
                    status.shard_id,
                    status.cluster,
                });
                try stdout.print("  Address: {s}\n", .{address_text});

                if (!result.ok) {
                    try stdout.print("  Status: unavailable ({s})\n", .{
                        result.error_name orelse "unknown",
                    });
                } else {
                    try stdout.writeAll("  Status: active\n");
                    try stdout.print("  RAM index: {d}/{d}\n", .{
                        result.response.ram_index_count,
                        result.response.ram_index_capacity,
                    });
                    try stdout.print("  RAM load: {d:.2}%\n", .{
                        @as(f64, @floatFromInt(result.response.ram_index_load_pct)) / 100.0,
                    });
                    try stdout.print("  Tombstones: {d}\n", .{result.response.tombstone_count});
                    try stdout.print("  TTL expirations: {d}\n", .{result.response.ttl_expirations});
                    try stdout.print("  Deletions: {d}\n", .{result.response.deletion_count});
                }
            }
        },
        .reshard => |reshard| {
            const mode_label = @tagName(reshard.mode);
            if (reshard.dry_run) {
                try stdout.print(
                    "Dry run: Would reshard cluster {d} to {d} shards (mode: {s})\n",
                    .{ reshard.cluster, reshard.to, mode_label },
                );
                try stdout_buffer.flush();
                return;
            }

            try stdout.print(
                "Resharding cluster {d} to {d} shards (mode: {s}):\n",
                .{ reshard.cluster, reshard.to, mode_label },
            );

            switch (reshard.mode) {
                .offline => {
                    try stdout.writeAll(
                        "  Offline resharding is planning-only in this CLI; use --dry-run for planning or --mode=online for live execution.\n",
                    );
                    return error.NotImplemented;
                },
                .online => {
                    const metrics_port: u16 = reshard.metrics_port orelse 9091;
                    var metrics_address = reshard.addresses.const_slice()[0];
                    metrics_address.setPort(metrics_port);

                    try send_reshard_request(metrics_address, reshard.to);
                    try stdout.print(
                        "  Online resharding request submitted (metrics: {any})\n",
                        .{metrics_address},
                    );
                },
            }
        },
    }
    try stdout_buffer.flush();
}

/// TTL management command handler.
fn command_ttl(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.TTL,
) !void {
    const cluster_id = switch (args.*) {
        .set => |set| set.cluster,
        .extend => |extend| extend.cluster,
        .clear => |clear| clear.cluster,
    };
    const addresses = switch (args.*) {
        .set => |set| set.addresses.const_slice(),
        .extend => |extend| extend.addresses.const_slice(),
        .clear => |clear| clear.addresses.const_slice(),
    };

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    var message_pool = try MessagePool.init(gpa, .client);
    defer message_pool.deinit(gpa);

    var client = try Client.init(
        gpa,
        time,
        &message_pool,
        .{
            .id = stdx.unique_u128(),
            .cluster = cluster_id,
            .replica_count = @intCast(addresses.len),
            .message_bus_options = .{
                .configuration = addresses,
                .io = io,
                .clients_limit = null,
            },
            .eviction_callback = &sync_client_eviction_callback,
        },
    );
    defer client.deinit(gpa);

    try register_client_sync(&client, io);

    switch (args.*) {
        .set => |set| {
            const ttl_seconds = std.math.cast(u32, set.ttl_seconds) orelse
                return error.TtlValueTooLarge;
            var request = vsr.archerdb.TtlSetRequest{
                .entity_id = set.entity_id,
                .ttl_seconds = ttl_seconds,
            };
            var response_buffer: [@sizeOf(vsr.archerdb.TtlSetResponse)]u8 = undefined;
            const response_bytes = try request_client_sync(
                &client,
                io,
                .ttl_set,
                mem.asBytes(&request),
                &response_buffer,
            );
            if (response_bytes.len < @sizeOf(vsr.archerdb.TtlSetResponse)) {
                return error.InvalidResponse;
            }
            const response = mem.bytesAsValue(
                vsr.archerdb.TtlSetResponse,
                response_bytes[0..@sizeOf(vsr.archerdb.TtlSetResponse)],
            ).*;

            try stdout.print("TTL set for entity {x} in cluster {d}\n", .{
                set.entity_id,
                set.cluster,
            });
            try stdout.print("  Previous TTL: {d}s\n", .{response.previous_ttl_seconds});
            try stdout.print("  New TTL: {d}s\n", .{response.new_ttl_seconds});
            try stdout.print("  Result: {s}\n", .{@tagName(response.result)});
            if (response.result != .success) return error.TtlOperationFailed;
        },
        .extend => |extend| {
            const extend_seconds = std.math.cast(u32, extend.extend_seconds) orelse
                return error.TtlValueTooLarge;
            var request = vsr.archerdb.TtlExtendRequest{
                .entity_id = extend.entity_id,
                .extend_by_seconds = extend_seconds,
            };
            var response_buffer: [@sizeOf(vsr.archerdb.TtlExtendResponse)]u8 = undefined;
            const response_bytes = try request_client_sync(
                &client,
                io,
                .ttl_extend,
                mem.asBytes(&request),
                &response_buffer,
            );
            if (response_bytes.len < @sizeOf(vsr.archerdb.TtlExtendResponse)) {
                return error.InvalidResponse;
            }
            const response = mem.bytesAsValue(
                vsr.archerdb.TtlExtendResponse,
                response_bytes[0..@sizeOf(vsr.archerdb.TtlExtendResponse)],
            ).*;

            try stdout.print("TTL extended for entity {x} in cluster {d}\n", .{
                extend.entity_id,
                extend.cluster,
            });
            try stdout.print("  Previous TTL: {d}s\n", .{response.previous_ttl_seconds});
            try stdout.print("  New TTL: {d}s\n", .{response.new_ttl_seconds});
            try stdout.print("  Result: {s}\n", .{@tagName(response.result)});
            if (response.result != .success) return error.TtlOperationFailed;
        },
        .clear => |clear| {
            var request = vsr.archerdb.TtlClearRequest{
                .entity_id = clear.entity_id,
            };
            var response_buffer: [@sizeOf(vsr.archerdb.TtlClearResponse)]u8 = undefined;
            const response_bytes = try request_client_sync(
                &client,
                io,
                .ttl_clear,
                mem.asBytes(&request),
                &response_buffer,
            );
            if (response_bytes.len < @sizeOf(vsr.archerdb.TtlClearResponse)) {
                return error.InvalidResponse;
            }
            const response = mem.bytesAsValue(
                vsr.archerdb.TtlClearResponse,
                response_bytes[0..@sizeOf(vsr.archerdb.TtlClearResponse)],
            ).*;

            try stdout.print("TTL cleared for entity {x} in cluster {d}\n", .{
                clear.entity_id,
                clear.cluster,
            });
            try stdout.print("  Previous TTL: {d}s\n", .{response.previous_ttl_seconds});
            try stdout.print("  Result: {s}\n", .{@tagName(response.result)});
            if (response.result != .success) return error.TtlOperationFailed;
        },
    }
    try stdout_buffer.flush();
}

/// Verification command handler.
fn command_verify(
    gpa: mem.Allocator,
    io: *IO,
    tracer: *Tracer,
    args: *const cli.Command.Verify,
) !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    const file = if (std.fs.path.isAbsolute(args.path))
        try std.fs.openFileAbsolute(args.path, .{})
    else
        try std.fs.cwd().openFile(args.path, .{});
    defer file.close();
    const stat = try file.stat();

    try stdout.print("Verifying data file: {s}\n", .{args.path});
    try stdout.print("  Size: {} bytes\n", .{stat.size});

    if (args.encryption) {
        if (encryption.isEncryptedFile(args.path)) {
            try stdout.writeAll("  Encryption: ARCE header detected\n");

            const key_path = std.process.getEnvVarOwned(
                gpa,
                "ARCHERDB_ENCRYPTION_KEY_PATH",
            ) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            defer if (key_path) |path| gpa.free(path);

            const key_id = std.process.getEnvVarOwned(
                gpa,
                "ARCHERDB_ENCRYPTION_KEY_ID",
            ) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            defer if (key_id) |id| gpa.free(id);

            if (key_path) |path| {
                var key_provider = try encryption.FileKeyProvider.init(
                    gpa,
                    path,
                    key_id orelse "archerdb-verify",
                );
                defer key_provider.deinit();

                const verify_result = encryption.verifyEncryptedFile(
                    gpa,
                    args.path,
                    key_provider.provider(),
                );
                try stdout.print("  Encryption header valid: {}\n", .{
                    verify_result.has_valid_header,
                });
                try stdout.print("  DEK unwrap valid: {}\n", .{
                    verify_result.dek_valid,
                });
                try stdout.print("  Encryption integrity valid: {}\n", .{
                    verify_result.integrity_valid,
                });
                if (verify_result.error_message) |message| {
                    try stdout.print("  Encryption note: {s}\n", .{message});
                }
                if (!(verify_result.has_valid_header and
                    verify_result.dek_valid and
                    verify_result.integrity_valid))
                {
                    try stdout_buffer.flush();
                    return error.EncryptionVerificationFailed;
                }
            } else {
                try stdout.writeAll(
                    "  Encryption detail: set ARCHERDB_ENCRYPTION_KEY_PATH to verify DEK unwrap and auth tags\n",
                );
            }
        } else {
            try stdout.writeAll("  Encryption: not detected\n");
        }
    }

    try stdout.writeAll("  Integrity: running offline scrubber\n");
    try stdout_buffer.flush();

    const path_z = try gpa.dupeZ(u8, args.path);
    defer gpa.free(path_z);

    var inspect_args = cli.Command.Inspect{
        .integrity = .{
            .log_level = args.log_level,
            .seed = null,
            .lsm_forest_node_count = @intCast(@divExact(
                constants.lsm_manifest_memory_size_default,
                constants.lsm_manifest_node_size,
            )),
            .skip_wal = false,
            .skip_client_replies = false,
            .skip_grid = false,
            .path = path_z,
        },
    };
    try inspect.command_inspect(gpa, io, tracer, &inspect_args);

    try stdout.print("Verification complete for {s}\n", .{args.path});
    try stdout_buffer.flush();
}

/// Coordinator command handler (per add-coordinator-mode/spec.md).
/// Manages coordinator process for multi-shard query routing.
fn command_coordinator(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Coordinator,
) !void {
    _ = io;
    _ = time;

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

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

            var trace_exporter: ?*observability.OtlpTraceExporter = null;
            defer if (trace_exporter) |exporter| {
                exporter.flush();
                exporter.deinit();
            };

            if (start.trace_export_enabled) {
                const endpoint = start.otlp_endpoint orelse
                    "http://localhost:4318/v1/traces";
                trace_exporter = try observability.OtlpTraceExporter.init(gpa, endpoint);
            }

            var service = coordinator.Service.init(gpa, .{
                .bind_address = coordinator.Address.init(start.bind_host, start.bind_port),
                .max_connections = start.max_connections,
                .query_timeout_ms = start.query_timeout_ms,
                .health_check_interval_ms = start.health_check_ms,
                .read_from_replicas = start.read_from_replicas,
                .trace_exporter = trace_exporter,
            });
            defer service.deinit();

            try service.coordinator.start();
            if (start.shards) |shards| {
                try seedCoordinatorShards(&service.coordinator, shards.const_slice());
            } else if (start.seed_nodes) |seeds| {
                try seedCoordinatorShards(&service.coordinator, seeds.const_slice());
            }

            try coordinatorProbeQuery(&service.coordinator, stdout);
            try stdout.writeAll("  Control endpoint: GET /status, POST /stop\n");
            try stdout.writeAll("  Service mode: foreground\n");
            try stdout_buffer.flush();

            try service.serve();
        },
        .status => |status| {
            const body = try coordinator.queryStatus(
                gpa,
                status.address,
                status.port,
                @tagName(status.format),
            );
            defer gpa.free(body);
            try stdout.writeAll(body);
            if (body.len == 0 or body[body.len - 1] != '\n') {
                try stdout.writeByte('\n');
            }
        },
        .stop => |stop| {
            _ = stop.timeout;
            const body = try coordinator.requestStop(gpa, stop.address, stop.port);
            defer gpa.free(body);
            try stdout.writeAll(body);
            if (body.len == 0 or body[body.len - 1] != '\n') {
                try stdout.writeByte('\n');
            }
        },
    }
    try stdout_buffer.flush();
}

fn seedCoordinatorShards(
    coordinator_instance: *coordinator.Coordinator,
    addresses: []const std.net.Address,
) !void {
    for (addresses, 0..) |address, index| {
        const shard_address = coordinatorAddressFromNet(address);
        try coordinator_instance.addShard(@intCast(index), shard_address);
    }
}

fn coordinatorAddressFromNet(address: std.net.Address) coordinator.Address {
    var addr_buf: [64]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{}", .{address}) catch "";
    var host_slice = addr_str;

    if (addr_str.len > 0 and addr_str[0] == '[') {
        if (std.mem.indexOfScalar(u8, addr_str, ']')) |end| {
            host_slice = addr_str[1..end];
        }
    } else if (std.mem.indexOfScalar(u8, addr_str, ':')) |colon| {
        host_slice = addr_str[0..colon];
    }

    return coordinator.Address.init(host_slice, address.getPort());
}

fn coordinatorProbeQuery(
    coordinator_instance: *coordinator.Coordinator,
    stdout: anytype,
) !void {
    var ctx_marker: u8 = 0;
    var traceparent_buf: [64]u8 = undefined;
    var traceparent: ?[]const u8 = null;

    if (coordinator_instance.config.trace_exporter != null) {
        var root_ctx = observability.CorrelationContext.newRoot(0);
        traceparent = root_ctx.toTraceparent(&traceparent_buf);
    }

    const request = coordinator.CoordinatorQuery{
        .query_type = .latest,
        .shard_query = coordinatorStubShardQuery,
        .ctx = &ctx_marker,
        .traceparent = traceparent,
    };

    if (coordinator_instance.executeQuery(request)) |response| {
        defer coordinator_instance.deinitQueryResponse(response);

        if (response.fan_out) |fan_out| {
            try stdout.print(
                "  Fan-out probe: shards={d} succeeded={d} failed={d} partial={}\n",
                .{
                    fan_out.shards_queried,
                    fan_out.shards_succeeded,
                    fan_out.shards_failed,
                    fan_out.partial,
                },
            );
        }
    } else |err| {
        log.warn("coordinator probe query failed: {}", .{err});
    }
}

fn coordinatorStubShardQuery(
    ctx: *anyopaque,
    shard: coordinator.ShardInfo,
) anyerror![]coordinator.GeoEvent {
    _ = ctx;
    _ = shard;
    const empty: [0]coordinator.GeoEvent = .{};
    return @constCast(empty[0..]);
}

fn command_cluster(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Cluster,
) !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    switch (args.*) {
        .status => |status| {
            const addresses = status.addresses.const_slice();
    var active_nodes: usize = 0;
    var unavailable_nodes: usize = 0;
    var total_ram_index_count: u64 = 0;
    var total_ram_index_capacity: u64 = 0;
    var total_tombstones: u64 = 0;
    var total_ttl_expirations: u64 = 0;
    var total_deletions: u64 = 0;
    var membership_consistent = true;
    var cluster_membership_state: ?u8 = null;
    var cluster_membership_voters: ?u32 = null;
    var cluster_membership_learners: ?u32 = null;
    var resize_consistent = true;
    var cluster_resize_status: ?u8 = null;
    var cluster_resize_progress: ?u32 = null;

    if (status.format == .json) {
        try stdout.print(
            "{{\"cluster\":{d},\"total_nodes\":{d},\"nodes\":[",
            .{ status.cluster, addresses.len },
        );
        for (addresses, 0..) |address, index| {
            const result = query_single_node_status(gpa, io, time, status.cluster, address);
            var address_buf: [128]u8 = undefined;
            const address_text = format_net_address(address, &address_buf);

            if (index > 0) try stdout.writeAll(",");

            if (result.ok) {
                active_nodes += 1;
                total_ram_index_count += result.response.ram_index_count;
                total_ram_index_capacity += result.response.ram_index_capacity;
                total_tombstones += result.response.tombstone_count;
                total_ttl_expirations += result.response.ttl_expirations;
                total_deletions += result.response.deletion_count;
                if (cluster_membership_state) |value| {
                    membership_consistent = membership_consistent and
                        value == result.response.membership_state and
                        cluster_membership_voters.? == result.response.membership_voters_count and
                        cluster_membership_learners.? == result.response.membership_learners_count;
                } else {
                    cluster_membership_state = result.response.membership_state;
                    cluster_membership_voters = result.response.membership_voters_count;
                    cluster_membership_learners = result.response.membership_learners_count;
                }
                if (cluster_resize_status) |value| {
                    resize_consistent = resize_consistent and
                        value == result.response.index_resize_status and
                        cluster_resize_progress.? == result.response.index_resize_progress;
                } else {
                    cluster_resize_status = result.response.index_resize_status;
                    cluster_resize_progress = result.response.index_resize_progress;
                }

                try stdout.print(
                    "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"active\",\"ram_index_count\":{d},\"ram_index_capacity\":{d},\"ram_index_load_pct\":{d},\"tombstone_count\":{d},\"ttl_expirations\":{d},\"deletion_count\":{d},\"membership_state\":\"{s}\",\"membership_voters_count\":{d},\"membership_learners_count\":{d},\"index_resize_status\":\"{s}\",\"index_resize_progress_pct\":{d:.2}}}",
                    .{
                        index,
                        address_text,
                        result.response.ram_index_count,
                        result.response.ram_index_capacity,
                        result.response.ram_index_load_pct,
                        result.response.tombstone_count,
                        result.response.ttl_expirations,
                        result.response.deletion_count,
                        result.response.membershipStateName(),
                        result.response.membership_voters_count,
                        result.response.membership_learners_count,
                        result.response.indexResizeStatusName(),
                        result.response.indexResizeProgressPct(),
                    },
                );
            } else {
                unavailable_nodes += 1;
                try stdout.print(
                    "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"unavailable\",\"error\":\"{s}\"}}",
                    .{ index, address_text, result.error_name orelse "unknown" },
                );
            }
        }
        try stdout.print(
            "],\"active_nodes\":{d},\"unavailable_nodes\":{d},\"ram_index_count\":{d},\"ram_index_capacity\":{d},\"tombstone_count\":{d},\"ttl_expirations\":{d},\"deletion_count\":{d},\"membership_consistent\":{},\"index_resize_consistent\":{}",
            .{
                active_nodes,
                unavailable_nodes,
                total_ram_index_count,
                total_ram_index_capacity,
                total_tombstones,
                total_ttl_expirations,
                total_deletions,
                membership_consistent,
                resize_consistent,
            },
        );
        if (active_nodes > 0 and membership_consistent) {
            try stdout.print(
                ",\"membership_state\":\"{s}\",\"membership_voters_count\":{d},\"membership_learners_count\":{d}",
                .{
                    vsr.archerdb.statusMembershipStateName(cluster_membership_state.?),
                    cluster_membership_voters.?,
                    cluster_membership_learners.?,
                },
            );
        }
        if (active_nodes > 0 and resize_consistent) {
            try stdout.print(
                ",\"index_resize_status\":\"{s}\",\"index_resize_progress_pct\":{d:.2}",
                .{
                    vsr.archerdb.statusIndexResizeName(cluster_resize_status.?),
                    @as(f64, @floatFromInt(cluster_resize_progress.?)) / 100.0,
                },
            );
        }
        try stdout.writeAll("}\n");
    } else {
        try stdout.print("Cluster status for cluster {d}:\n", .{status.cluster});
        try stdout.print("  Nodes configured: {d}\n", .{addresses.len});

        for (addresses, 0..) |address, index| {
            const result = query_single_node_status(gpa, io, time, status.cluster, address);
            var address_buf: [128]u8 = undefined;
            const address_text = format_net_address(address, &address_buf);

            if (result.ok) {
                active_nodes += 1;
                total_ram_index_count += result.response.ram_index_count;
                total_ram_index_capacity += result.response.ram_index_capacity;
                total_tombstones += result.response.tombstone_count;
                total_ttl_expirations += result.response.ttl_expirations;
                total_deletions += result.response.deletion_count;
                if (cluster_membership_state) |value| {
                    membership_consistent = membership_consistent and
                        value == result.response.membership_state and
                        cluster_membership_voters.? == result.response.membership_voters_count and
                        cluster_membership_learners.? == result.response.membership_learners_count;
                } else {
                    cluster_membership_state = result.response.membership_state;
                    cluster_membership_voters = result.response.membership_voters_count;
                    cluster_membership_learners = result.response.membership_learners_count;
                }
                if (cluster_resize_status) |value| {
                    resize_consistent = resize_consistent and
                        value == result.response.index_resize_status and
                        cluster_resize_progress.? == result.response.index_resize_progress;
                } else {
                    cluster_resize_status = result.response.index_resize_status;
                    cluster_resize_progress = result.response.index_resize_progress;
                }

                try stdout.print(
                    "  node {d}: {s} active ram_index={d}/{d} load={d:.2}% tombstones={d} ttl_expirations={d} deletions={d} membership={s} voters={d} learners={d} resize={s}({d:.2}%)\n",
                    .{
                        index,
                        address_text,
                        result.response.ram_index_count,
                        result.response.ram_index_capacity,
                        @as(f64, @floatFromInt(result.response.ram_index_load_pct)) / 100.0,
                        result.response.tombstone_count,
                        result.response.ttl_expirations,
                        result.response.deletion_count,
                        result.response.membershipStateName(),
                        result.response.membership_voters_count,
                        result.response.membership_learners_count,
                        result.response.indexResizeStatusName(),
                        result.response.indexResizeProgressPct(),
                    },
                );
            } else {
                unavailable_nodes += 1;
                try stdout.print(
                    "  node {d}: {s} unavailable ({s})\n",
                    .{ index, address_text, result.error_name orelse "unknown" },
                );
            }
        }

        try stdout.print("  Active nodes: {d}\n", .{active_nodes});
        try stdout.print("  Unavailable nodes: {d}\n", .{unavailable_nodes});
        try stdout.print("  Aggregate RAM index: {d}/{d}\n", .{
            total_ram_index_count,
            total_ram_index_capacity,
        });
        try stdout.print("  Aggregate tombstones: {d}\n", .{total_tombstones});
        try stdout.print("  Aggregate TTL expirations: {d}\n", .{total_ttl_expirations});
        try stdout.print("  Aggregate deletions: {d}\n", .{total_deletions});
        if (active_nodes > 0) {
            try stdout.print("  Membership consistent: {}\n", .{membership_consistent});
            if (membership_consistent) {
                try stdout.print("  Membership state: {s} voters={d} learners={d}\n", .{
                    vsr.archerdb.statusMembershipStateName(cluster_membership_state.?),
                    cluster_membership_voters.?,
                    cluster_membership_learners.?,
                });
            } else {
                try stdout.writeAll("  Membership state: mixed across active nodes\n");
            }
            try stdout.print("  Index resize consistent: {}\n", .{resize_consistent});
            if (resize_consistent) {
                try stdout.print("  Index resize: {s} ({d:.2}%)\n", .{
                    vsr.archerdb.statusIndexResizeName(cluster_resize_status.?),
                    @as(f64, @floatFromInt(cluster_resize_progress.?)) / 100.0,
                });
            } else {
                try stdout.writeAll("  Index resize: mixed across active nodes\n");
            }
        }
    }

        },
        .sentinel => unreachable,
    }

    try stdout_buffer.flush();
}

fn command_index(
    gpa: mem.Allocator,
    io: *IO,
    time: Time,
    args: *const cli.Command.Index,
) !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    switch (args.*) {
        .resize => |resize| {
            switch (resize.action) {
                .start => {
                    const target_capacity = resize.new_capacity orelse return error.MissingCapacity;
                    const metrics_port = resize.metrics_port;
                    const addresses = resize.addresses.const_slice();
                    var accepted_nodes: usize = 0;

                    for (addresses) |address| {
                        var metrics_address = address;
                        metrics_address.setPort(metrics_port);
                        send_index_resize_start_request(metrics_address, target_capacity) catch |err| {
                            log.warn("index resize start rejected by {any}: {}", .{
                                metrics_address,
                                err,
                            });
                            continue;
                        };
                        accepted_nodes += 1;
                    }

                    if (accepted_nodes == 0) return error.NoActiveNodes;

                    if (resize.format == .json) {
                        try stdout.print(
                            "{{\"cluster\":{d},\"target_capacity\":{d},\"metrics_port\":{d},\"accepted_nodes\":{d}}}\n",
                            .{ resize.cluster, target_capacity, metrics_port, accepted_nodes },
                        );
                    } else {
                        try stdout.print(
                            "Index resize request submitted for cluster {d}: target_capacity={d}, metrics_port={d}, accepted_nodes={d}\n",
                            .{ resize.cluster, target_capacity, metrics_port, accepted_nodes },
                        );
                    }
                },
                .check => {
                    const target_capacity = resize.new_capacity orelse return error.MissingCapacity;
                    const addresses = resize.addresses.const_slice();
                    var active_nodes: usize = 0;
                    var current_capacity_min: u64 = std.math.maxInt(u64);
                    var current_capacity_max: u64 = 0;
                    var current_entries_max: u64 = 0;

                    for (addresses) |address| {
                        const result = query_single_node_status(gpa, io, time, resize.cluster, address);
                        if (!result.ok) continue;

                        active_nodes += 1;
                        current_capacity_min = @min(
                            current_capacity_min,
                            result.response.ram_index_capacity,
                        );
                        current_capacity_max = @max(
                            current_capacity_max,
                            result.response.ram_index_capacity,
                        );
                        current_entries_max = @max(
                            current_entries_max,
                            result.response.ram_index_count,
                        );
                    }

                    if (active_nodes == 0) return error.NoActiveNodes;

                    const capacity_consistent = current_capacity_min == current_capacity_max;
                    const above_current_capacity = target_capacity > current_capacity_max;
                    const above_current_entries = target_capacity > current_entries_max;
                    const recommended = target_capacity >= current_entries_max * 2;

                    if (resize.format == .json) {
                        try stdout.print(
                            "{{\"cluster\":{d},\"active_nodes\":{d},\"target_capacity\":{d},\"current_capacity_min\":{d},\"current_capacity_max\":{d},\"current_entries_max\":{d},\"capacity_consistent\":{},\"above_current_capacity\":{},\"above_current_entries\":{},\"recommended\":{}}}\n",
                            .{
                                resize.cluster,
                                active_nodes,
                                target_capacity,
                                current_capacity_min,
                                current_capacity_max,
                                current_entries_max,
                                capacity_consistent,
                                above_current_capacity,
                                above_current_entries,
                                recommended,
                            },
                        );
                    } else {
                        try stdout.print("Index resize feasibility for cluster {d}:\n", .{
                            resize.cluster,
                        });
                        try stdout.print("  Active nodes: {d}\n", .{active_nodes});
                        try stdout.print("  Target capacity: {d}\n", .{target_capacity});
                        try stdout.print("  Current capacity range: {d}..{d}\n", .{
                            current_capacity_min,
                            current_capacity_max,
                        });
                        try stdout.print("  Current max entries: {d}\n", .{current_entries_max});
                        try stdout.print("  Capacity consistent across nodes: {}\n", .{
                            capacity_consistent,
                        });
                        try stdout.print("  Greater than current capacity: {}\n", .{
                            above_current_capacity,
                        });
                        try stdout.print("  Greater than current entries: {}\n", .{
                            above_current_entries,
                        });
                        try stdout.print("  Recommended headroom (>=2x entries): {}\n", .{
                            recommended,
                        });
                    }
                },
                .status => {
                    const addresses = resize.addresses.const_slice();
                    var active_nodes: usize = 0;
                    var unavailable_nodes: usize = 0;
                    var resize_consistent = true;
                    var cluster_resize_status: ?u8 = null;
                    var cluster_resize_progress: ?u32 = null;

                    if (resize.format == .json) {
                        try stdout.print("{{\"cluster\":{d},\"nodes\":[", .{resize.cluster});
                        for (addresses, 0..) |address, index| {
                            const result = query_single_node_status(
                                gpa,
                                io,
                                time,
                                resize.cluster,
                                address,
                            );
                            var address_buf: [128]u8 = undefined;
                            const address_text = format_net_address(address, &address_buf);

                            if (index > 0) try stdout.writeAll(",");

                            if (result.ok) {
                                active_nodes += 1;
                                if (cluster_resize_status) |value| {
                                    resize_consistent = resize_consistent and
                                        value == result.response.index_resize_status and
                                        cluster_resize_progress.? == result.response.index_resize_progress;
                                } else {
                                    cluster_resize_status = result.response.index_resize_status;
                                    cluster_resize_progress = result.response.index_resize_progress;
                                }

                                try stdout.print(
                                    "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"active\",\"index_resize_status\":\"{s}\",\"index_resize_progress_pct\":{d:.2},\"ram_index_capacity\":{d},\"ram_index_count\":{d}}}",
                                    .{
                                        index,
                                        address_text,
                                        result.response.indexResizeStatusName(),
                                        result.response.indexResizeProgressPct(),
                                        result.response.ram_index_capacity,
                                        result.response.ram_index_count,
                                    },
                                );
                            } else {
                                unavailable_nodes += 1;
                                try stdout.print(
                                    "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"unavailable\",\"error\":\"{s}\"}}",
                                    .{ index, address_text, result.error_name orelse "unknown" },
                                );
                            }
                        }
                        try stdout.print(
                            "],\"active_nodes\":{d},\"unavailable_nodes\":{d},\"resize_consistent\":{}",
                            .{ active_nodes, unavailable_nodes, resize_consistent },
                        );
                        if (active_nodes > 0 and resize_consistent) {
                            try stdout.print(
                                ",\"index_resize_status\":\"{s}\",\"index_resize_progress_pct\":{d:.2}",
                                .{
                                    vsr.archerdb.statusIndexResizeName(cluster_resize_status.?),
                                    @as(f64, @floatFromInt(cluster_resize_progress.?)) / 100.0,
                                },
                            );
                        }
                        try stdout.writeAll("}\n");
                    } else {
                        try stdout.print("Index resize status for cluster {d}:\n", .{
                            resize.cluster,
                        });
                        for (addresses, 0..) |address, index| {
                            const result = query_single_node_status(
                                gpa,
                                io,
                                time,
                                resize.cluster,
                                address,
                            );
                            var address_buf: [128]u8 = undefined;
                            const address_text = format_net_address(address, &address_buf);

                            if (result.ok) {
                                active_nodes += 1;
                                if (cluster_resize_status) |value| {
                                    resize_consistent = resize_consistent and
                                        value == result.response.index_resize_status and
                                        cluster_resize_progress.? == result.response.index_resize_progress;
                                } else {
                                    cluster_resize_status = result.response.index_resize_status;
                                    cluster_resize_progress = result.response.index_resize_progress;
                                }

                                try stdout.print(
                                    "  node {d}: {s} {s} ({d:.2}%) entries={d}/{d}\n",
                                    .{
                                        index,
                                        address_text,
                                        result.response.indexResizeStatusName(),
                                        result.response.indexResizeProgressPct(),
                                        result.response.ram_index_count,
                                        result.response.ram_index_capacity,
                                    },
                                );
                            } else {
                                unavailable_nodes += 1;
                                try stdout.print(
                                    "  node {d}: {s} unavailable ({s})\n",
                                    .{ index, address_text, result.error_name orelse "unknown" },
                                );
                            }
                        }
                        try stdout.print("  Active nodes: {d}\n", .{active_nodes});
                        try stdout.print("  Unavailable nodes: {d}\n", .{unavailable_nodes});
                        try stdout.print("  Index resize consistent: {}\n", .{resize_consistent});
                        if (active_nodes > 0 and resize_consistent) {
                            try stdout.print("  Cluster resize state: {s} ({d:.2}%)\n", .{
                                vsr.archerdb.statusIndexResizeName(cluster_resize_status.?),
                                @as(f64, @floatFromInt(cluster_resize_progress.?)) / 100.0,
                            });
                        }
                    }
                },
                .abort => {
                    const metrics_port = resize.metrics_port;
                    const addresses = resize.addresses.const_slice();
                    var accepted_nodes: usize = 0;

                    for (addresses) |address| {
                        var metrics_address = address;
                        metrics_address.setPort(metrics_port);
                        send_index_resize_abort_request(metrics_address) catch |err| {
                            log.warn("index resize abort rejected by {any}: {}", .{
                                metrics_address,
                                err,
                            });
                            continue;
                        };
                        accepted_nodes += 1;
                    }

                    if (accepted_nodes == 0) return error.NoActiveNodes;

                    if (resize.format == .json) {
                        try stdout.print(
                            "{{\"cluster\":{d},\"metrics_port\":{d},\"accepted_nodes\":{d}}}\n",
                            .{ resize.cluster, metrics_port, accepted_nodes },
                        );
                    } else {
                        try stdout.print(
                            "Index resize abort submitted for cluster {d}: metrics_port={d}, accepted_nodes={d}\n",
                            .{ resize.cluster, metrics_port, accepted_nodes },
                        );
                    }
                },
            }
        },
        .stats => |stats| {
            const addresses = stats.addresses.const_slice();
            var active_nodes: usize = 0;
            var unavailable_nodes: usize = 0;
            var total_count: u64 = 0;
            var total_capacity: u64 = 0;
            var total_tombstones: u64 = 0;

            if (stats.format == .json) {
                try stdout.print("{{\"cluster\":{d},\"nodes\":[", .{stats.cluster});
                for (addresses, 0..) |address, index| {
                    const result = query_single_node_status(gpa, io, time, stats.cluster, address);
                    var address_buf: [128]u8 = undefined;
                    const address_text = format_net_address(address, &address_buf);

                    if (index > 0) try stdout.writeAll(",");

                    if (result.ok) {
                        active_nodes += 1;
                        total_count += result.response.ram_index_count;
                        total_capacity += result.response.ram_index_capacity;
                        total_tombstones += result.response.tombstone_count;

                        try stdout.print(
                            "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"active\",\"count\":{d},\"capacity\":{d},\"load_pct\":{d},\"tombstone_count\":{d}}}",
                            .{
                                index,
                                address_text,
                                result.response.ram_index_count,
                                result.response.ram_index_capacity,
                                result.response.ram_index_load_pct,
                                result.response.tombstone_count,
                            },
                        );
                    } else {
                        unavailable_nodes += 1;
                        try stdout.print(
                            "{{\"node_id\":{d},\"address\":\"{s}\",\"status\":\"unavailable\",\"error\":\"{s}\"}}",
                            .{ index, address_text, result.error_name orelse "unknown" },
                        );
                    }
                }
                try stdout.print(
                    "],\"active_nodes\":{d},\"unavailable_nodes\":{d},\"total_count\":{d},\"total_capacity\":{d},\"total_tombstones\":{d}}}\n",
                    .{
                        active_nodes,
                        unavailable_nodes,
                        total_count,
                        total_capacity,
                        total_tombstones,
                    },
                );
            } else {
                try stdout.print("Index statistics for cluster {d}:\n", .{stats.cluster});
                for (addresses, 0..) |address, index| {
                    const result = query_single_node_status(gpa, io, time, stats.cluster, address);
                    var address_buf: [128]u8 = undefined;
                    const address_text = format_net_address(address, &address_buf);

                    if (result.ok) {
                        active_nodes += 1;
                        total_count += result.response.ram_index_count;
                        total_capacity += result.response.ram_index_capacity;
                        total_tombstones += result.response.tombstone_count;

                        try stdout.print(
                            "  node {d}: {s} count={d} capacity={d} load={d:.2}% tombstones={d}\n",
                            .{
                                index,
                                address_text,
                                result.response.ram_index_count,
                                result.response.ram_index_capacity,
                                @as(f64, @floatFromInt(result.response.ram_index_load_pct)) / 100.0,
                                result.response.tombstone_count,
                            },
                        );
                    } else {
                        unavailable_nodes += 1;
                        try stdout.print(
                            "  node {d}: {s} unavailable ({s})\n",
                            .{ index, address_text, result.error_name orelse "unknown" },
                        );
                    }
                }

                try stdout.print("  Active nodes: {d}\n", .{active_nodes});
                try stdout.print("  Unavailable nodes: {d}\n", .{unavailable_nodes});
                try stdout.print("  Aggregate entries: {d}\n", .{total_count});
                try stdout.print("  Aggregate capacity: {d}\n", .{total_capacity});
                try stdout.print("  Aggregate tombstones: {d}\n", .{total_tombstones});
            }
        },
    }
    try stdout_buffer.flush();
}

fn command_upgrade(
    gpa: mem.Allocator,
    args: *const cli.Command.Upgrade,
) !void {
    const upgrade = @import("upgrade.zig");

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout_buffer.writer();
    const stdout = stdout_writer.any();

    // Build addresses string from parsed addresses
    var addresses_buf: [4096]u8 = undefined;
    var addresses_len: usize = 0;
    for (args.addresses.const_slice(), 0..) |addr, i| {
        if (i > 0) {
            addresses_buf[addresses_len] = ',';
            addresses_len += 1;
        }
        const addr_str = std.fmt.bufPrint(
            addresses_buf[addresses_len..],
            "{}",
            .{addr},
        ) catch unreachable;
        addresses_len += addr_str.len;
    }
    const addresses_str = addresses_buf[0..addresses_len];

    switch (args.action) {
        .status => {
            var upgrader = upgrade.Upgrader.init(gpa, .{
                .addresses = addresses_str,
                .metrics_port = args.metrics_port,
            });
            defer upgrader.deinit();

            // Discover replicas and get status
            upgrader.discoverReplicas() catch |err| {
                if (args.format == .json) {
                    try stdout.print(
                        "{{\"error\":\"{s}\",\"message\":\"failed to discover replicas\"}}\n",
                        .{@errorName(err)},
                    );
                } else {
                    try stdout.print("Error discovering replicas: {any}\n", .{err});
                }
                try stdout_buffer.flush();
                return;
            };

            _ = upgrader.identifyPrimary() catch null;

            const status = upgrader.getStatus() catch |err| {
                if (args.format == .json) {
                    try stdout.print(
                        "{{\"error\":\"{s}\",\"message\":\"failed to get upgrade status\"}}\n",
                        .{@errorName(err)},
                    );
                } else {
                    try stdout.print("Error getting status: {any}\n", .{err});
                }
                try stdout_buffer.flush();
                return;
            };

            if (args.format == .json) {
                try std.json.stringify(status, .{}, stdout);
                try stdout.writeByte('\n');
            } else {
                try stdout.print("Cluster Upgrade Status\n", .{});
                try stdout.print("======================\n\n", .{});
                try stdout.print("{}\n", .{status});
            }
        },
        .start => {
            const target_version = args.target_version orelse {
                if (args.format == .json) {
                    try stdout.writeAll(
                        "{\"error\":\"MissingTargetVersion\",\"message\":\"--target-version is required\"}\n",
                    );
                } else {
                    try stdout.print("Error: --target-version is required\n", .{});
                }
                try stdout_buffer.flush();
                return;
            };

            if (!args.dry_run) {
                try print_not_implemented(
                    stdout,
                    args.format,
                    "upgrade start",
                    "live rollout actuation is owned by external deployment tooling; use --dry-run for planning and `upgrade status` for live checks",
                );
                try stdout_buffer.flush();
                return error.NotImplemented;
            }

            var upgrader = upgrade.Upgrader.init(gpa, .{
                .addresses = addresses_str,
                .target_version = target_version,
                .dry_run = args.dry_run,
                .metrics_port = args.metrics_port,
                .health_thresholds = .{
                    .p99_latency_multiplier = args.p99_threshold,
                    .error_rate_threshold_pct = args.error_threshold,
                    .catchup_timeout_seconds = args.catchup_timeout,
                },
            });
            defer upgrader.deinit();

            const result = upgrader.execute() catch |err| {
                if (args.format == .json) {
                    try stdout.print(
                        "{{\"error\":\"{s}\",\"message\":\"upgrade dry-run failed\"}}\n",
                        .{@errorName(err)},
                    );
                } else {
                    try stdout.print("Upgrade failed: {any}\n", .{err});
                }
                try stdout_buffer.flush();
                return;
            };

            if (args.format == .json) {
                try std.json.stringify(.{
                    .mode = "dry_run",
                    .target_version = target_version,
                    .p99_threshold = args.p99_threshold,
                    .error_threshold = args.error_threshold,
                    .catchup_timeout = args.catchup_timeout,
                    .result = result,
                }, .{}, stdout);
                try stdout.writeByte('\n');
            } else {
                try stdout.print("[DRY RUN] Rolling Upgrade Plan\n", .{});
                try stdout.print("=========================\n\n", .{});
                try stdout.print("Target version: {s}\n", .{target_version});
                try stdout.print("P99 threshold:  {d:.1}x baseline\n", .{args.p99_threshold});
                try stdout.print("Error threshold: {d:.1}%\n", .{args.error_threshold});
                try stdout.print("Catchup timeout: {d}s\n\n", .{args.catchup_timeout});
                try stdout.print("{}\n", .{result});
            }
        },
    }
    try stdout_buffer.flush();
}
