// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Metrics and health HTTP server for observability endpoints.
//!
//! Provides:
//! - `/health/live` - Kubernetes liveness probe (always 200 if process is running)
//! - `/health/ready` - Kubernetes readiness probe (200 if replica is ready to serve)
//! - `/metrics` - Prometheus-format metrics endpoint
//!
//! The server runs in a dedicated thread to avoid blocking the main event loop.
//! It uses blocking I/O which is acceptable since metrics requests are infrequent
//! and should complete quickly.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.metrics_server);

/// State of the replica for health checks.
pub const ReplicaState = enum {
    /// Replica is starting up, not ready to serve.
    starting,
    /// Replica is healthy and ready to serve requests.
    ready,
    /// Replica is in view change, temporarily unavailable.
    view_change,
    /// Replica is recovering, not ready for new requests.
    recovering,
    /// Replica is shutting down, not accepting new requests.
    shutting_down,

    pub fn isReady(self: ReplicaState) bool {
        return self == .ready;
    }

    pub fn reason(self: ReplicaState) []const u8 {
        return switch (self) {
            .starting => "starting",
            .ready => "ok",
            .view_change => "view_change",
            .recovering => "recovering",
            .shutting_down => "shutting_down",
        };
    }
};

/// Global replica state for health checks.
/// Updated by the main replica code.
pub var replica_state: ReplicaState = .starting;

/// Metrics server instance.
pub const MetricsServer = struct {
    server_fd: posix.socket_t,
    thread: std.Thread,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn start(bind_address: []const u8, port: u16) !*Self {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Parse bind address
        const address = std.net.Address.parseIp4(bind_address, port) catch |err| {
            log.err("invalid metrics bind address '{s}': {}", .{ bind_address, err });
            return error.InvalidAddress;
        };

        // Create socket
        self.server_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(self.server_fd);

        // Set socket options
        const enable: u32 = 1;
        try posix.setsockopt(self.server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

        // Bind and listen
        try posix.bind(self.server_fd, &address.any, address.getOsSockLen());
        try posix.listen(self.server_fd, 16);

        self.running = std.atomic.Value(bool).init(true);

        // Get the actual bound address (in case port 0 was used)
        var bound_addr: posix.sockaddr = undefined;
        var bound_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.server_fd, &bound_addr, &bound_addr_len);

        const bound_port = std.mem.bigToNative(u16, @as(*align(1) const posix.sockaddr.in, @ptrCast(&bound_addr)).port);
        log.info("metrics server listening on {s}:{d}", .{ bind_address, bound_port });

        // Security warning for binding to all interfaces
        if (std.mem.eql(u8, bind_address, "0.0.0.0")) {
            log.warn("metrics server bound to all interfaces (0.0.0.0) - consider using authentication in production", .{});
        }

        // Start server thread
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        return self;
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        // Close socket to interrupt accept()
        posix.close(self.server_fd);

        // Wait for thread to finish
        self.thread.join();

        log.info("metrics server stopped", .{});

        std.heap.page_allocator.destroy(self);
    }

    fn serverLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            var client_addr: posix.sockaddr = undefined;
            var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const client_fd = posix.accept(self.server_fd, &client_addr, &client_addr_len, 0) catch |err| {
                if (!self.running.load(.acquire)) break; // Normal shutdown
                log.warn("accept error: {}", .{err});
                continue;
            };
            defer posix.close(client_fd);

            handleRequest(client_fd) catch |err| {
                log.warn("request handling error: {}", .{err});
            };
        }
    }

    fn handleRequest(client_fd: posix.socket_t) !void {
        var buf: [4096]u8 = undefined;

        // Read request
        const bytes_read = try posix.read(client_fd, &buf);
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Parse HTTP request line (minimal parsing - just get the path)
        const path = parsePath(request) orelse {
            try sendResponse(client_fd, .bad_request, "text/plain", "Bad Request");
            return;
        };

        // Route request
        if (std.mem.eql(u8, path, "/health/live")) {
            try handleHealthLive(client_fd);
        } else if (std.mem.eql(u8, path, "/health/ready")) {
            try handleHealthReady(client_fd);
        } else if (std.mem.eql(u8, path, "/health")) {
            try handleHealthReady(client_fd);
        } else if (std.mem.eql(u8, path, "/metrics")) {
            try handleMetrics(client_fd);
        } else {
            try sendResponse(client_fd, .not_found, "text/plain", "Not Found");
        }
    }

    fn parsePath(request: []const u8) ?[]const u8 {
        // Find end of first line
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse std.mem.indexOf(u8, request, "\n") orelse return null;
        const first_line = request[0..line_end];

        // Parse "GET /path HTTP/1.1"
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = parts.next() orelse return null; // Method (ignored, we accept any)
        const path = parts.next() orelse return null;

        // Strip query string if present
        if (std.mem.indexOf(u8, path, "?")) |query_start| {
            return path[0..query_start];
        }
        return path;
    }

    fn handleHealthLive(client_fd: posix.socket_t) !void {
        // Liveness probe: always 200 if the process is running
        const body =
            \\{"status":"ok"}
        ;
        try sendResponse(client_fd, .ok, "application/json", body);
    }

    fn handleHealthReady(client_fd: posix.socket_t) !void {
        const state = replica_state;

        if (state.isReady()) {
            const body =
                \\{"status":"ok"}
            ;
            try sendResponse(client_fd, .ok, "application/json", body);
        } else {
            var body_buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"status\":\"unavailable\",\"reason\":\"{s}\"}}", .{state.reason()}) catch |err| switch (err) {
                error.NoSpaceLeft => "{\"status\":\"unavailable\"}",
            };
            try sendResponse(client_fd, .service_unavailable, "application/json", body);
        }
    }

    fn handleMetrics(client_fd: posix.socket_t) !void {
        // TODO: Implement actual metrics collection (issue #380)
        // For now, return a placeholder with basic info
        const body =
            \\# HELP archerdb_info ArcherDB build information
            \\# TYPE archerdb_info gauge
            \\archerdb_info{version="0.0.1"} 1
            \\
            \\# HELP archerdb_health_status Current health status (1 = healthy)
            \\# TYPE archerdb_health_status gauge
            \\archerdb_health_status{status="ready"} 1
            \\
        ;
        try sendResponse(client_fd, .ok, "text/plain; version=0.0.4", body);
    }

    const HttpStatus = enum {
        ok,
        bad_request,
        not_found,
        service_unavailable,

        fn code(self: HttpStatus) []const u8 {
            return switch (self) {
                .ok => "200 OK",
                .bad_request => "400 Bad Request",
                .not_found => "404 Not Found",
                .service_unavailable => "503 Service Unavailable",
            };
        }
    };

    fn sendResponse(client_fd: posix.socket_t, status: HttpStatus, content_type: []const u8, body: []const u8) !void {
        var response_buf: [8192]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            status.code(),
            content_type,
            body.len,
            body,
        }) catch return error.ResponseTooLarge;

        _ = try posix.write(client_fd, response);
    }
};

test "MetricsServer: parsePath" {
    const TestCase = struct {
        input: []const u8,
        expected: ?[]const u8,
    };

    const cases = [_]TestCase{
        .{ .input = "GET /health/live HTTP/1.1\r\n", .expected = "/health/live" },
        .{ .input = "GET /health/ready HTTP/1.1\r\n", .expected = "/health/ready" },
        .{ .input = "GET /metrics HTTP/1.1\r\n", .expected = "/metrics" },
        .{ .input = "GET /metrics?foo=bar HTTP/1.1\r\n", .expected = "/metrics" },
        .{ .input = "POST /health HTTP/1.1\r\n", .expected = "/health" },
        .{ .input = "invalid", .expected = null },
        .{ .input = "", .expected = null },
    };

    for (cases) |case| {
        const result = MetricsServer.parsePath(case.input);
        if (case.expected) |expected| {
            try std.testing.expect(result != null);
            try std.testing.expectEqualStrings(expected, result.?);
        } else {
            try std.testing.expect(result == null);
        }
    }
}

test "ReplicaState: isReady" {
    try std.testing.expect(!ReplicaState.starting.isReady());
    try std.testing.expect(ReplicaState.ready.isReady());
    try std.testing.expect(!ReplicaState.view_change.isReady());
    try std.testing.expect(!ReplicaState.recovering.isReady());
    try std.testing.expect(!ReplicaState.shutting_down.isReady());
}
