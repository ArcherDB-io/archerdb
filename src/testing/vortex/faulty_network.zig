// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! The `Network` is a set of proxies used to inject network faults in a Vortex test cluster. We
//! create one `Proxy` per replica in the test cluster. Each proxy has a set of available
//! `Connection`s, which model the communication through the proxy (replica-to-replica or
//! client-to-replica). Each `Connection` has two pipes, connecting the peers' inputs and outputs
//! (recv and send).
//!
//! The _mappings_ are pairs of addresses:
//!
//! * _origin_: the address on which the proxy listens for connections from _origin_ peers
//! * _remote_: the address the proxy connects to, to communicate with the _remote_ peers
//!
//! A pipe runs, alternating recv and send, until it sees that the connection is no longer proxying
//! or if there's an error or EOF, in which case it also closes the parent connection.
//!
//! When the `Faults` struct is populated with non-null configurations, the pipes inject
//! corresponding faults according to the probabilities.
//!
//! NOTE: The pipe is not yet message-aware (and perhaps shouldn't be?), which means that we deal
//! with whatever chunks of bytes we receive immediately, instead of collecting a buffer with a
//! full message before piping it through.
const std = @import("std");
const stdx = @import("stdx");
const IO = @import("../../io.zig").IO;
const constants = @import("constants.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.faulty_network);
const Ratio = stdx.PRNG.Ratio;

const Faults = struct {
    const Delay = struct {
        time_ms: u32,
        jitter_ms: u32,
    };

    const Rate = struct {
        bytes_per_second: u32,
        burst_bytes: u32,
    };

    delay: ?Delay = null,
    lose: ?Ratio = null,
    corrupt: ?Ratio = null,
    duplicate: ?Ratio = null,
    reorder: ?Ratio = null,
    rate: ?Rate = null,

    pub fn heal(faults: *Faults) void {
        faults.delay = null;
        faults.lose = null;
        faults.corrupt = null;
        faults.duplicate = null;
        faults.reorder = null;
        faults.rate = null;
    }

    pub fn is_healed(faults: *const Faults) bool {
        return faults.delay == null and
            faults.lose == null and
            faults.corrupt == null and
            faults.duplicate == null and
            faults.reorder == null and
            faults.rate == null;
    }
};

const Pipe = struct {
    const SendSource = enum {
        current,
        duplicate,
        reorder,
    };

    const NextAction = enum {
        recv,
        send_active_chunk,
        schedule_timeout,
    };

    io: *IO,
    connection: *Connection,
    input: ?std.posix.socket_t = null,
    output: ?std.posix.socket_t = null,
    buffer: [constants.vsr.message_size_max]u8 = undefined,
    reorder_buffer: [constants.vsr.message_size_max]u8 = undefined,
    send_inflight: bool = false,
    recv_inflight: bool = false,
    timer_inflight: bool = false,
    recv_count: usize = 0,
    send_count: usize = 0,
    duplicate_send_count: usize = 0,
    reorder_recv_count: usize = 0,
    reorder_send_count: usize = 0,
    duplicate_pending: bool = false,
    send_source: SendSource = .current,

    recv_completion: IO.Completion = undefined,
    send_completion: IO.Completion = undefined,
    timer_completion: IO.Completion = undefined,

    fn open(
        pipe: *Pipe,
        input: std.posix.socket_t,
        output: std.posix.socket_t,
    ) void {
        assert(pipe.connection.state == .proxying);

        pipe.input = input;
        pipe.output = output;
        pipe.recv_count = 0;
        pipe.send_count = 0;
        pipe.duplicate_send_count = 0;
        pipe.reorder_recv_count = 0;
        pipe.reorder_send_count = 0;
        pipe.duplicate_pending = false;
        pipe.send_source = .current;

        // Kick off the recv/send loop.
        pipe.recv();
    }

    fn has_inflight_operations(pipe: *const Pipe) bool {
        return pipe.recv_inflight or pipe.send_inflight or pipe.timer_inflight;
    }

    fn recv(pipe: *Pipe) void {
        assert(!pipe.recv_inflight);
        assert(pipe.connection.state == .proxying);

        pipe.recv_count = 0;
        pipe.send_count = 0;
        pipe.recv_inflight = true;

        // We don't need to recv a certain count of bytes, because whatever we recv, we send along.
        pipe.connection.io.recv(
            *Pipe,
            pipe,
            on_recv,
            &pipe.recv_completion,
            pipe.input.?,
            pipe.buffer[0..],
        );
    }

    fn on_recv(pipe: *Pipe, _: *IO.Completion, result: IO.RecvError!usize) void {
        assert(pipe.recv_inflight);
        pipe.recv_inflight = false;

        if (pipe.connection.state != .proxying) {
            return;
        }

        pipe.recv_count = result catch |err| {
            log.warn("recv error ({d},{d}): {any}", .{
                pipe.connection.replica_index,
                pipe.connection.connection_index,
                err,
            });
            return pipe.connection.try_close();
        };
        if (pipe.recv_count == 0) {
            // Zero bytes means EOF.
            return pipe.connection.try_close();
        }

        pipe.send_source = .current;
        pipe.send_count = 0;
        pipe.duplicate_send_count = 0;
        pipe.duplicate_pending = false;

        if (pipe.connection.network.faults.lose) |lose| {
            if (pipe.connection.network.prng.chance(lose)) {
                log.debug("losing {d} bytes ({d},{d})", .{
                    pipe.recv_count,
                    pipe.connection.replica_index,
                    pipe.connection.connection_index,
                });
                pipe.recv();
                return;
            }
        }

        if (pipe.connection.network.faults.corrupt) |corrupt| {
            if (pipe.connection.network.prng.chance(corrupt)) {
                switch (pipe.connection.network.prng.enum_uniform(enum { shuffle, zero })) {
                    .shuffle => {
                        log.debug("shuffling {d} bytes ({d},{d})", .{
                            pipe.recv_count,
                            pipe.connection.replica_index,
                            pipe.connection.connection_index,
                        });
                        pipe.connection.network.prng.shuffle(u8, pipe.buffer[0..pipe.recv_count]);
                    },
                    .zero => {
                        log.debug("zeroing {d} bytes ({d},{d})", .{
                            pipe.recv_count,
                            pipe.connection.replica_index,
                            pipe.connection.connection_index,
                        });
                        @memset(pipe.buffer[0..pipe.recv_count], 0);
                    },
                }
            }
        }

        if (pipe.reorder_recv_count == 0) {
            if (pipe.connection.network.faults.reorder) |reorder| {
                if (pipe.connection.network.prng.chance(reorder)) {
                    log.debug("holding {d} bytes for reordering ({d},{d})", .{
                        pipe.recv_count,
                        pipe.connection.replica_index,
                        pipe.connection.connection_index,
                    });
                    @memcpy(
                        pipe.reorder_buffer[0..pipe.recv_count],
                        pipe.buffer[0..pipe.recv_count],
                    );
                    pipe.reorder_recv_count = pipe.recv_count;
                    pipe.reorder_send_count = 0;
                    pipe.recv();
                    return;
                }
            }
        }

        if (pipe.connection.network.faults.duplicate) |duplicate| {
            if (pipe.connection.network.prng.chance(duplicate)) {
                pipe.duplicate_pending = true;
                log.debug("duplicating {d} bytes ({d},{d})", .{
                    pipe.recv_count,
                    pipe.connection.replica_index,
                    pipe.connection.connection_index,
                });
            }
        }

        if (pipe.connection.network.faults.delay) |delay| {
            const timeout_duration_ns = pipe.compute_delay_timeout_ns(delay);
            log.debug("delaying {} ({d},{d})", .{
                std.fmt.fmtDuration(timeout_duration_ns),
                pipe.connection.replica_index,
                pipe.connection.connection_index,
            });
            pipe.schedule_timeout(timeout_duration_ns);
        } else {
            pipe.send_active_chunk();
        }
    }

    fn on_timeout(pipe: *Pipe, _: *IO.Completion, result: IO.TimeoutError!void) void {
        assert(pipe.timer_inflight);
        pipe.timer_inflight = false;
        if (pipe.connection.state != .proxying) {
            return;
        }
        result catch @panic("timeout error");
        pipe.send_active_chunk();
    }

    fn send(pipe: *Pipe, buffer: []u8) void {
        assert(!pipe.send_inflight);
        assert(pipe.connection.state == .proxying);

        pipe.send_inflight = true;
        pipe.io.send(
            *Pipe,
            pipe,
            on_send,
            &pipe.send_completion,
            pipe.output.?,
            buffer,
        );
    }

    fn on_send(pipe: *Pipe, _: *IO.Completion, result: IO.SendError!usize) void {
        assert(pipe.send_inflight);
        pipe.send_inflight = false;

        if (pipe.connection.state != .proxying) return;

        const send_count = result catch |err| {
            log.warn("send error ({d},{d}): {any}", .{
                pipe.connection.replica_index,
                pipe.connection.connection_index,
                err,
            });
            return pipe.connection.try_close();
        };
        switch (pipe.advance_after_send(send_count)) {
            .schedule_timeout => {
                const rate = pipe.connection.network.faults.rate.?;
                const timeout_duration_ns = Pipe.rate_delay_ns(rate, send_count);
                log.debug("rate limiting {} ({d},{d})", .{
                    std.fmt.fmtDuration(timeout_duration_ns),
                    pipe.connection.replica_index,
                    pipe.connection.connection_index,
                });
                pipe.schedule_timeout(timeout_duration_ns);
            },
            .send_active_chunk => pipe.send_active_chunk(),
            .recv => pipe.recv(),
        }
    }

    fn schedule_timeout(pipe: *Pipe, nanoseconds: u63) void {
        assert(!pipe.timer_inflight);
        pipe.timer_inflight = true;
        pipe.io.timeout(
            *Pipe,
            pipe,
            on_timeout,
            &pipe.timer_completion,
            nanoseconds,
        );
    }

    fn compute_delay_timeout_ns(pipe: *Pipe, delay: Faults.Delay) u63 {
        assert(delay.jitter_ms <= delay.time_ms);
        const jitter_size = pipe.connection.network.prng.int_inclusive(u32, delay.jitter_ms);
        const jitter_diff_ms: i32 = @as(i32, @intCast(jitter_size)) *
            (if (pipe.connection.network.prng.boolean()) @as(i32, 1) else -1);
        return @as(
            u63,
            @intCast(@as(i32, @intCast(delay.time_ms)) + jitter_diff_ms),
        ) * std.time.ns_per_ms;
    }

    fn active_sent_count(pipe: *const Pipe) usize {
        return switch (pipe.send_source) {
            .current => pipe.send_count,
            .duplicate => pipe.duplicate_send_count,
            .reorder => pipe.reorder_send_count,
        };
    }

    fn active_total_count(pipe: *const Pipe) usize {
        return switch (pipe.send_source) {
            .current, .duplicate => pipe.recv_count,
            .reorder => pipe.reorder_recv_count,
        };
    }

    fn active_sent_count_add(pipe: *Pipe, count: usize) void {
        switch (pipe.send_source) {
            .current => pipe.send_count += count,
            .duplicate => pipe.duplicate_send_count += count,
            .reorder => pipe.reorder_send_count += count,
        }
    }

    fn active_slice(pipe: *Pipe) []u8 {
        return switch (pipe.send_source) {
            .current, .duplicate => pipe.buffer[0..pipe.recv_count],
            .reorder => pipe.reorder_buffer[0..pipe.reorder_recv_count],
        };
    }

    fn send_active_chunk(pipe: *Pipe) void {
        const slice = pipe.active_slice();
        const sent = pipe.active_sent_count();
        const remaining = slice[sent..];
        if (remaining.len == 0) return;

        const send_len = if (pipe.connection.network.faults.rate) |rate|
            Pipe.rate_chunk_size(rate, remaining.len)
        else
            remaining.len;
        pipe.send(remaining[0..send_len]);
    }

    fn rate_chunk_size(rate: Faults.Rate, remaining: usize) usize {
        const burst_bytes: usize = @max(@as(usize, rate.burst_bytes), 1);
        return @min(remaining, burst_bytes);
    }

    fn rate_delay_ns(rate: Faults.Rate, bytes_sent: usize) u63 {
        const bps: u64 = @max(@as(u64, rate.bytes_per_second), 1);
        const numerator: u128 = @as(u128, bytes_sent) * std.time.ns_per_s;
        return @intCast(@max((numerator + bps - 1) / bps, 1));
    }

    fn advance_after_send(pipe: *Pipe, send_count: usize) NextAction {
        pipe.active_sent_count_add(send_count);

        if (pipe.active_sent_count() < pipe.active_total_count()) {
            return if (pipe.connection.network.faults.rate != null)
                .schedule_timeout
            else
                .send_active_chunk;
        }

        switch (pipe.send_source) {
            .current => {
                if (pipe.duplicate_pending) {
                    pipe.send_source = .duplicate;
                    pipe.duplicate_send_count = 0;
                    return .send_active_chunk;
                }
                if (pipe.reorder_recv_count > 0) {
                    pipe.send_source = .reorder;
                    pipe.reorder_send_count = 0;
                    return .send_active_chunk;
                }
                return .recv;
            },
            .duplicate => {
                pipe.duplicate_pending = false;
                pipe.duplicate_send_count = 0;
                if (pipe.reorder_recv_count > 0) {
                    pipe.send_source = .reorder;
                    pipe.reorder_send_count = 0;
                    return .send_active_chunk;
                }
                pipe.send_source = .current;
                return .recv;
            },
            .reorder => {
                pipe.send_source = .current;
                pipe.reorder_recv_count = 0;
                pipe.reorder_send_count = 0;
                return .recv;
            },
        }
    }
};

test "Faults heal clears all injected network modes" {
    var faults = Faults{
        .delay = .{ .time_ms = 10, .jitter_ms = 2 },
        .lose = Ratio{ .numerator = 1, .denominator = 10 },
        .corrupt = Ratio{ .numerator = 1, .denominator = 20 },
        .duplicate = Ratio{ .numerator = 1, .denominator = 30 },
        .reorder = Ratio{ .numerator = 1, .denominator = 40 },
        .rate = .{ .bytes_per_second = 1024, .burst_bytes = 64 },
    };
    try std.testing.expect(!faults.is_healed());
    faults.heal();
    try std.testing.expect(faults.is_healed());
}

test "Pipe rate helpers bound chunk size and compute delay" {
    const rate = Faults.Rate{
        .bytes_per_second = 1000,
        .burst_bytes = 128,
    };

    try std.testing.expectEqual(@as(usize, 128), Pipe.rate_chunk_size(rate, 4096));
    try std.testing.expectEqual(@as(usize, 64), Pipe.rate_chunk_size(rate, 64));
    try std.testing.expectEqual(@as(u63, 128_000_000), Pipe.rate_delay_ns(rate, 128));
}

fn pipeForTest(faults: Faults) Pipe {
    const network_storage = struct {
        var prng = stdx.PRNG.from_seed(1);
        var network = Network{
            .io = undefined,
            .prng = &prng,
            .proxies = &.{},
            .faults = faults,
        };
        var connection = Connection{
            .io = undefined,
            .network = &network,
            .state = .proxying,
            .replica_index = 0,
            .connection_index = 0,
            .origin_to_remote_pipe = undefined,
            .remote_to_origin_pipe = undefined,
        };
    };

    const pipe = Pipe{
        .io = undefined,
        .connection = &network_storage.connection,
    };
    network_storage.connection.origin_to_remote_pipe = pipe;
    return pipe;
}

test "Pipe advance_after_send transitions into duplicate replay" {
    var pipe = pipeForTest(.{});
    pipe.recv_count = 32;
    pipe.send_count = 16;
    pipe.duplicate_pending = true;

    try std.testing.expectEqual(
        Pipe.NextAction.send_active_chunk,
        pipe.advance_after_send(16),
    );
    try std.testing.expectEqual(Pipe.SendSource.duplicate, pipe.send_source);
    try std.testing.expectEqual(@as(usize, 0), pipe.duplicate_send_count);
}

test "Pipe advance_after_send transitions into reordered replay" {
    var pipe = pipeForTest(.{});
    pipe.recv_count = 24;
    pipe.send_count = 24;
    pipe.reorder_recv_count = 24;
    @memcpy(pipe.reorder_buffer[0..24], "reordered-buffer-payload!"[0..24]);

    try std.testing.expectEqual(
        Pipe.NextAction.send_active_chunk,
        pipe.advance_after_send(0),
    );
    try std.testing.expectEqual(Pipe.SendSource.reorder, pipe.send_source);
    try std.testing.expectEqual(@as(usize, 0), pipe.reorder_send_count);
}

test "Pipe advance_after_send rate limits partial sends" {
    var pipe = pipeForTest(.{
        .rate = .{
            .bytes_per_second = 1024,
            .burst_bytes = 8,
        },
    });
    pipe.recv_count = 32;
    pipe.send_count = 0;

    try std.testing.expectEqual(
        Pipe.NextAction.schedule_timeout,
        pipe.advance_after_send(8),
    );
    try std.testing.expectEqual(@as(usize, 8), pipe.send_count);
}

test "Pipe advance_after_send clears reorder state after replay" {
    var pipe = pipeForTest(.{});
    pipe.send_source = .reorder;
    pipe.reorder_recv_count = 20;
    pipe.reorder_send_count = 12;

    try std.testing.expectEqual(Pipe.NextAction.recv, pipe.advance_after_send(8));
    try std.testing.expectEqual(Pipe.SendSource.current, pipe.send_source);
    try std.testing.expectEqual(@as(usize, 0), pipe.reorder_recv_count);
    try std.testing.expectEqual(@as(usize, 0), pipe.reorder_send_count);
}

const Connection = struct {
    io: *IO,
    network: *Network,
    state: enum {
        free,
        accepting,
        connecting,
        proxying,
        closing,
        closing_origin,
        closing_remote,
    } = .free,

    replica_index: usize,
    connection_index: usize,

    origin_fd: ?std.posix.socket_t = null,
    remote_fd: ?std.posix.socket_t = null,

    origin_to_remote_pipe: Pipe,
    remote_to_origin_pipe: Pipe,

    remote_address: ?std.net.Address = null,

    accept_completion: IO.Completion = undefined,
    connect_completion: IO.Completion = undefined,
    close_completion: IO.Completion = undefined,

    fn on_accept(
        connection: *Connection,
        _: *IO.Completion,
        result: IO.AcceptError!std.posix.socket_t,
    ) void {
        assert(connection.state == .accepting);
        defer assert(connection.state == .connecting);

        assert(connection.origin_fd == null);
        defer assert(connection.origin_fd != null);

        assert(connection.remote_fd == null);
        defer assert(connection.remote_fd != null);
        assert(connection.remote_address != null);

        const fd = result catch |err| {
            log.warn("accept failed ({d},{d}): {}", .{
                connection.replica_index,
                connection.connection_index,
                err,
            });
            return connection.try_close();
        };
        connection.origin_fd = fd;

        const remote_fd = connection.io.open_socket_tcp(
            connection.remote_address.?.any.family,
            tcp_options,
        ) catch |err| {
            log.warn("couldn't open socket for remote ({d},{d}): {}", .{
                connection.replica_index,
                connection.connection_index,
                err,
            });
            return connection.try_close();
        };
        connection.remote_fd = remote_fd;

        connection.state = .connecting;

        connection.io.connect(
            *Connection,
            connection,
            Connection.on_connect,
            &connection.connect_completion,
            connection.remote_fd.?,
            connection.remote_address.?,
        );
    }

    fn on_connect(
        connection: *Connection,
        _: *IO.Completion,
        result: IO.ConnectError!void,
    ) void {
        assert(connection.state == .connecting);
        assert(connection.origin_fd != null);
        assert(connection.remote_fd != null);

        result catch |err| {
            log.warn("connect failed ({d},{d}): {}", .{
                connection.replica_index,
                connection.connection_index,
                err,
            });
            return connection.try_close();
        };
        connection.state = .proxying;
        connection.origin_to_remote_pipe.open(connection.origin_fd.?, connection.remote_fd.?);
        connection.remote_to_origin_pipe.open(connection.remote_fd.?, connection.origin_fd.?);
    }

    fn try_close(connection: *Connection) void {
        assert(connection.state != .free);

        if (connection.state == .closing_origin or
            connection.state == .closing_remote) return;

        const has_inflight_operations =
            connection.origin_to_remote_pipe.has_inflight_operations() or
            connection.remote_to_origin_pipe.has_inflight_operations();

        if (connection.state != .closing and has_inflight_operations) {
            log.debug("try_close ({d},{d}): marking connection as closing", .{
                connection.replica_index,
                connection.connection_index,
            });
            connection.state = .closing;
            std.posix.shutdown(connection.origin_fd.?, .both) catch |err| {
                switch (err) {
                    error.SocketNotConnected => {},
                    else => log.warn("shutdown origin_fd ({d},{d}) failed: {}", .{
                        connection.replica_index, connection.connection_index, err,
                    }),
                }
            };
            std.posix.shutdown(connection.remote_fd.?, .both) catch |err| {
                switch (err) {
                    error.SocketNotConnected => {},
                    else => log.warn("shutdown remote_fd ({d},{d}) failed: {}", .{
                        connection.replica_index, connection.connection_index, err,
                    }),
                }
            };
        }

        if (!has_inflight_operations) {
            // Kick off the close sequence.
            connection.state = .closing_origin;
            connection.io.close(
                *Connection,
                connection,
                on_close_origin,
                &connection.close_completion,
                connection.origin_fd.?,
            );
            return;
        }

        assert(connection.state == .closing);
    }

    fn on_close_origin(
        connection: *Connection,
        _: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        assert(connection.state == .closing_origin);
        defer assert(connection.state == .closing_remote);

        assert(connection.origin_fd != null);
        defer assert(connection.origin_fd == null);

        result catch |err| {
            log.warn("on_close_origin ({d},{d}) error: {any}", .{
                connection.replica_index,
                connection.connection_index,
                err,
            });
        };

        connection.state = .closing_remote;
        connection.origin_fd = null;
        connection.io.close(
            *Connection,
            connection,
            on_close_remote,
            &connection.close_completion,
            connection.remote_fd.?,
        );
    }

    fn on_close_remote(
        connection: *Connection,
        _: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        assert(connection.state == .closing_remote);
        defer assert(connection.state == .free);

        assert(connection.remote_fd != null);
        defer assert(connection.remote_fd == null);

        result catch |err| {
            log.warn("on_close_remote ({d},{d}) error: {any}", .{
                connection.replica_index,
                connection.connection_index,
                err,
            });
        };

        log.debug("on_close_remote ({d},{d}): marking connection as free", .{
            connection.replica_index,
            connection.connection_index,
        });
        connection.state = .free;
        connection.remote_fd = null;
    }
};

const Proxy = struct {
    io: *IO,
    accept_fd: std.posix.socket_t,
    origin_address: std.net.Address, // The proxy's address.
    remote_address: std.net.Address, // The replica's address.
    connections: [constants.vortex.connections_count_max]Connection,

    fn deinit(proxy: *Proxy) void {
        proxy.io.close_socket(proxy.accept_fd);
        proxy.* = undefined;
    }
};

const tcp_options: IO.TCPOptions = .{
    .rcvbuf = 0,
    .sndbuf = 0,
    .keepalive = null,
    .user_timeout_ms = 0,
    .nodelay = false,
};

pub const Network = struct {
    io: *IO,
    prng: *stdx.PRNG,
    proxies: []Proxy,
    faults: Faults,

    pub fn listen(
        allocator: std.mem.Allocator,
        prng: *stdx.PRNG,
        io: *IO,
        replica_ports: []const u16,
    ) !*Network {
        const network = try allocator.create(Network);
        errdefer allocator.destroy(network);

        const proxies = try allocator.alloc(Proxy, replica_ports.len);
        errdefer allocator.free(proxies);

        network.* = .{
            .io = io,
            .prng = prng,
            .proxies = proxies,
            .faults = std.mem.zeroes(Faults),
        };

        var proxies_initialized: usize = 0;
        errdefer for (proxies[0..proxies_initialized]) |*proxy| proxy.deinit();

        // Proxies get an unused port from the ephemeral port range (usually 32768-60999; see
        // /proc/sys/net/ipv4/ip_local_port_range) by listening on port=0.
        // We assume that replicas' ports are from outside of that range and cannot conflict.
        for (proxies, replica_ports, 0..) |*proxy, replica_port, replica_index| {
            const Address = std.net.Address;
            const replica_address = Address.parseIp("127.0.0.1", replica_port) catch unreachable;
            const listen_address = Address.parseIp("127.0.0.1", 0) catch unreachable;
            const listen_fd = try io.open_socket_tcp(std.posix.AF.INET, tcp_options);
            errdefer io.close_socket(listen_fd);

            const origin_address = try io.listen(listen_fd, listen_address, .{ .backlog = 64 });
            proxy.* = .{
                .io = io,
                .accept_fd = listen_fd,
                .origin_address = origin_address,
                .remote_address = replica_address,
                .connections = undefined,
            };

            for (&proxy.connections, 0..) |*connection, connection_index| {
                connection.* = .{
                    .io = io,
                    .network = network,
                    .state = .free,
                    .replica_index = replica_index,
                    .connection_index = connection_index,
                    .origin_to_remote_pipe = .{ .io = io, .connection = connection },
                    .remote_to_origin_pipe = .{ .io = io, .connection = connection },
                };
            }
            proxies_initialized += 1;

            log.debug("proxying {any} -> {any}", .{ origin_address, replica_address });
        }

        return network;
    }

    pub fn destroy(network: *Network, allocator: std.mem.Allocator) void {
        for (network.proxies) |*proxy| proxy.deinit();
        allocator.free(network.proxies);
        allocator.destroy(network);
    }

    pub fn tick(network: *Network) void {
        for (network.proxies) |*proxy| {
            for (&proxy.connections) |*connection| {
                if (connection.state == .closing) {
                    connection.try_close();
                    continue;
                }
                // This proxy tries to accept with connections that are free. The pipes must also
                // have no outstanding IO submissions racing with reusing the pipes for new
                // connections.
                if (connection.state == .free) {
                    assert(!connection.origin_to_remote_pipe.has_inflight_operations());
                    assert(!connection.remote_to_origin_pipe.has_inflight_operations());

                    log.debug("accepting ({d},{d})", .{
                        connection.replica_index,
                        connection.connection_index,
                    });

                    connection.state = .accepting;
                    connection.remote_address = proxy.remote_address;
                    connection.origin_fd = null;
                    connection.remote_fd = null;

                    network.io.accept(
                        *Connection,
                        connection,
                        Connection.on_accept,
                        &connection.accept_completion,
                        proxy.accept_fd,
                    );
                }
            }
        }
    }
};
