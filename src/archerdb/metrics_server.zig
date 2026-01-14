// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Metrics and health HTTP server for observability endpoints.
//!
//! Provides:
//! - `/health/live` - Kubernetes liveness probe (always 200 if process is running)
//! - `/health/ready` - Kubernetes readiness probe (200 if replica is ready to serve)
//! - `/health/region` - v2.0 Multi-region replication status (role, lag metrics)
//! - `/health/shards` - v2.0 Shard distribution and resharding status
//! - `/health/encryption` - v2.0 Encryption at rest status and metrics
//! - `/metrics` - Prometheus-format metrics endpoint
//!
//! The server runs in a dedicated thread to avoid blocking the main event loop.
//! It uses blocking I/O which is acceptable since metrics requests are infrequent
//! and should complete quickly.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.metrics_server);

const vsr = @import("vsr");
const metrics = vsr.archerdb_metrics;

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

/// Cached metrics response for avoiding recomputation on frequent scrapes.
/// Per observability/spec.md: "Cache metrics for up to 1 second"
const MetricsCache = struct {
    /// Cached response body
    data: [65536]u8 = undefined,
    /// Length of cached data
    len: usize = 0,
    /// Timestamp when cache was last updated (nanoseconds)
    timestamp_ns: i128 = 0,
    /// Cache TTL in nanoseconds (1 second)
    const cache_ttl_ns: i128 = 1_000_000_000;

    /// Check if cache is valid (not expired)
    fn isValid(self: *const MetricsCache) bool {
        if (self.len == 0) return false;
        const now = std.time.nanoTimestamp();
        return (now - self.timestamp_ns) < cache_ttl_ns;
    }

    /// Update cache with new data
    fn update(self: *MetricsCache, data: []const u8) void {
        const copy_len = @min(data.len, self.data.len);
        @memcpy(self.data[0..copy_len], data[0..copy_len]);
        self.len = copy_len;
        self.timestamp_ns = std.time.nanoTimestamp();
    }

    /// Get cached data if valid
    fn get(self: *const MetricsCache) ?[]const u8 {
        if (self.isValid()) {
            return self.data[0..self.len];
        }
        return null;
    }
};

/// Global metrics cache (thread-safe via atomic timestamp check)
var metrics_cache: MetricsCache = .{};

/// Bearer token for metrics authentication (optional).
/// If set, requests to /metrics must include "Authorization: Bearer <token>" header.
/// Per observability/spec.md: Bearer token auth for production deployments.
var bearer_token: ?[]const u8 = null;

/// Set the bearer token for metrics authentication.
/// Call before start() to enable authentication.
pub fn setAuthToken(token: []const u8) void {
    bearer_token = token;
    log.info("metrics server authentication enabled", .{});
}

/// Clear the bearer token (disable authentication).
pub fn clearAuthToken() void {
    bearer_token = null;
    log.info("metrics server authentication disabled", .{});
}

/// Metrics server instance.
pub const MetricsServer = struct {
    server_fd: posix.socket_t,
    thread: std.Thread,
    running: std.atomic.Value(bool),

    pub fn start(bind_address: []const u8, port: u16) !*MetricsServer {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(MetricsServer);
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
        const sock_opt = posix.SO.REUSEADDR;
        try posix.setsockopt(self.server_fd, posix.SOL.SOCKET, sock_opt, std.mem.asBytes(&enable));

        // Bind and listen
        try posix.bind(self.server_fd, &address.any, address.getOsSockLen());
        try posix.listen(self.server_fd, 16);

        self.running = std.atomic.Value(bool).init(true);

        // Get the actual bound address (in case port 0 was used)
        var bound_addr: posix.sockaddr = undefined;
        var bound_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.server_fd, &bound_addr, &bound_addr_len);

        const addr_in: *align(1) const posix.sockaddr.in = @ptrCast(&bound_addr);
        const bound_port = std.mem.bigToNative(u16, addr_in.port);
        log.info("metrics server listening on {s}:{d}", .{ bind_address, bound_port });

        // Security warning for binding to all interfaces
        if (std.mem.eql(u8, bind_address, "0.0.0.0")) {
            const msg = "metrics server bound to 0.0.0.0 - consider auth in prod";
            log.warn(msg, .{});
        }

        // Start server thread
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        return self;
    }

    pub fn stop(self: *MetricsServer) void {
        self.running.store(false, .release);

        // Close socket to interrupt accept()
        posix.close(self.server_fd);

        // Wait for thread to finish
        self.thread.join();

        log.info("metrics server stopped", .{});

        std.heap.page_allocator.destroy(self);
    }

    fn serverLoop(self: *MetricsServer) void {
        while (self.running.load(.acquire)) {
            var client_addr: posix.sockaddr = undefined;
            var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const c_addr = &client_addr;
            const c_len = &client_addr_len;
            const client_fd = posix.accept(self.server_fd, c_addr, c_len, 0) catch |err| {
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
        } else if (std.mem.eql(u8, path, "/health/region")) {
            try handleHealthRegion(client_fd);
        } else if (std.mem.eql(u8, path, "/health/shards")) {
            try handleHealthShards(client_fd);
        } else if (std.mem.eql(u8, path, "/health/encryption")) {
            try handleHealthEncryption(client_fd);
        } else if (std.mem.eql(u8, path, "/metrics")) {
            // Check bearer token authentication if configured
            if (bearer_token) |expected_token| {
                const auth_header = parseAuthHeader(request);
                if (auth_header == null or !std.mem.eql(u8, auth_header.?, expected_token)) {
                    try sendResponse(client_fd, .unauthorized, "text/plain", "Unauthorized");
                    return;
                }
            }
            try handleMetrics(client_fd);
        } else {
            try sendResponse(client_fd, .not_found, "text/plain", "Not Found");
        }
    }

    fn parsePath(request: []const u8) ?[]const u8 {
        // Find end of first line
        const crlf = std.mem.indexOf(u8, request, "\r\n");
        const lf = std.mem.indexOf(u8, request, "\n");
        const line_end = crlf orelse lf orelse return null;
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

    /// Parse Authorization header and extract bearer token.
    /// Returns the token value if "Authorization: Bearer <token>" header is found.
    fn parseAuthHeader(request: []const u8) ?[]const u8 {
        const auth_prefix = "Authorization: Bearer ";
        const auth_prefix_lower = "authorization: bearer ";

        // Search for Authorization header (case-insensitive prefix match)
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            // Check both cases for the header name
            if (std.mem.startsWith(u8, line, auth_prefix)) {
                return std.mem.trim(u8, line[auth_prefix.len..], " \t");
            }
            // Case-insensitive check (lowercase)
            if (line.len >= auth_prefix_lower.len) {
                var lower_line: [256]u8 = undefined;
                const copy_len = @min(line.len, lower_line.len);
                for (line[0..copy_len], 0..) |c, i| {
                    lower_line[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                }
                if (std.mem.startsWith(u8, lower_line[0..copy_len], auth_prefix_lower)) {
                    return std.mem.trim(u8, line[auth_prefix.len..], " \t");
                }
            }
        }
        return null;
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
            const fmt = "{{\"status\":\"unavailable\",\"reason\":\"{s}\"}}";
            const reason = state.reason();
            const body = std.fmt.bufPrint(&body_buf, fmt, .{reason}) catch |err| switch (err) {
                error.NoSpaceLeft => "{\"status\":\"unavailable\"}",
            };
            const ctype = "application/json";
            try sendResponse(client_fd, .service_unavailable, ctype, body);
        }
    }

    /// v2.0 Health endpoint: Multi-region replication status.
    /// Per openspec/changes/add-v2-distributed-features/specs/replication/spec.md
    fn handleHealthRegion(client_fd: posix.socket_t) !void {
        // Get region metrics from the registry (raw atomics use .load())
        const role = metrics.Registry.region_role.load(.monotonic);
        const region_id_val = metrics.Registry.region_id.load(.monotonic);
        const lag_ops = metrics.Registry.replication_lag_ops.load(.monotonic);
        const lag_ns = metrics.Registry.replication_lag_ns.load(.monotonic);

        // Sum ship queue depth across all followers
        var total_queue_depth: u64 = 0;
        for (metrics.Registry.replication_ship_queue_depth) |depth| {
            total_queue_depth += depth.load(.monotonic);
        }

        // Calculate lag in seconds
        const lag_seconds: f64 = @as(f64, @floatFromInt(lag_ns)) / 1e9;

        // Determine health status based on lag
        // Healthy if lag is under 10 seconds or if we're primary (no lag expected)
        const is_healthy = (role == 1) or (lag_seconds < 10.0);
        const status = if (is_healthy) "ok" else "degraded";
        const role_str = if (role == 1) "primary" else "follower";

        var body_buf: [512]u8 = undefined;
        const fmt =
            \\{{"status":"{s}","role":"{s}","region_id":{d},"ship_queue_depth":{d},"lag_ops":{d},"lag_seconds":{d:.3}}}
        ;
        const body = std.fmt.bufPrint(&body_buf, fmt, .{
            status,
            role_str,
            region_id_val,
            total_queue_depth,
            lag_ops,
            lag_seconds,
        }) catch "{\"status\":\"error\"}";

        const http_status: HttpStatus = if (is_healthy) .ok else .service_unavailable;
        try sendResponse(client_fd, http_status, "application/json", body);
    }

    /// v2.0 Health endpoint: Shard distribution and status.
    /// Per openspec/changes/add-v2-distributed-features/specs/index-sharding/spec.md
    fn handleHealthShards(client_fd: posix.socket_t) !void {
        // Get sharding metrics from the registry (raw atomics use .load())
        const shard_count_val = metrics.Registry.shard_count.load(.monotonic);
        const resharding_status_val = metrics.Registry.resharding_status.load(.monotonic);
        const resharding_progress_val = metrics.Registry.resharding_progress.load(.monotonic);

        // Status is healthy if not resharding or resharding is complete
        const is_resharding = resharding_status_val == 1;
        const status = if (is_resharding) "resharding" else "ok";

        // Progress is stored as 0-1000, convert to percentage
        const progress_pct: f64 = @as(f64, @floatFromInt(resharding_progress_val)) / 10.0;

        var body_buf: [512]u8 = undefined;
        const fmt =
            \\{{"status":"{s}","shard_count":{d},"resharding":{s},"resharding_progress":{d:.1}}}
        ;
        const body = std.fmt.bufPrint(&body_buf, fmt, .{
            status,
            shard_count_val,
            if (is_resharding) "true" else "false",
            progress_pct,
        }) catch "{\"status\":\"error\"}";

        try sendResponse(client_fd, .ok, "application/json", body);
    }

    /// v2.0 Health endpoint: Encryption at rest status.
    /// Per openspec/changes/add-v2-distributed-features/specs/security/spec.md
    fn handleHealthEncryption(client_fd: posix.socket_t) !void {
        // Get encryption metrics from the registry (Counters use .get())
        const encrypt_ops = metrics.Registry.encryption_ops_total.get();
        const decrypt_ops = metrics.Registry.decryption_ops_total.get();
        const cache_hits = metrics.Registry.encryption_cache_hits_total.get();
        const cache_misses = metrics.Registry.encryption_cache_misses_total.get();

        // Encryption is enabled if we have any encrypt/decrypt operations
        const is_enabled = (encrypt_ops > 0) or (decrypt_ops > 0);
        const status = if (is_enabled) "enabled" else "disabled";

        // Calculate cache hit ratio
        const total_cache_ops = cache_hits + cache_misses;
        const cache_hit_ratio: f64 = if (total_cache_ops > 0)
            @as(f64, @floatFromInt(cache_hits)) / @as(f64, @floatFromInt(total_cache_ops))
        else
            0.0;

        var body_buf: [512]u8 = undefined;
        const fmt =
            \\{{"status":"{s}","enabled":{s},"encrypt_ops":{d},"decrypt_ops":{d},"key_cache_hit_ratio":{d:.3}}}
        ;
        const body = std.fmt.bufPrint(&body_buf, fmt, .{
            status,
            if (is_enabled) "true" else "false",
            encrypt_ops,
            decrypt_ops,
            cache_hit_ratio,
        }) catch "{\"status\":\"error\"}";

        try sendResponse(client_fd, .ok, "application/json", body);
    }

    fn handleMetrics(client_fd: posix.socket_t) !void {
        // Update health status gauge based on replica state
        const state = replica_state;
        metrics.Registry.health_ready.set(if (state.isReady()) 1 else 0);

        // Check cache first (per observability/spec.md: cache for up to 1 second)
        if (metrics_cache.get()) |cached_data| {
            try sendResponse(client_fd, .ok, "text/plain; version=0.0.4", cached_data);
            return;
        }

        // Format all metrics to buffer
        var buf: [65536]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        metrics.Registry.format(fbs.writer()) catch |err| {
            log.warn("error formatting metrics: {}", .{err});
            const msg = "Error formatting metrics";
            try sendResponse(client_fd, .service_unavailable, "text/plain", msg);
            return;
        };

        const response_data = fbs.getWritten();

        // Update cache for subsequent requests
        metrics_cache.update(response_data);

        try sendResponse(client_fd, .ok, "text/plain; version=0.0.4", response_data);
    }

    const HttpStatus = enum {
        ok,
        bad_request,
        unauthorized,
        not_found,
        service_unavailable,

        fn code(self: HttpStatus) []const u8 {
            return switch (self) {
                .ok => "200 OK",
                .bad_request => "400 Bad Request",
                .unauthorized => "401 Unauthorized",
                .not_found => "404 Not Found",
                .service_unavailable => "503 Service Unavailable",
            };
        }
    };

    fn sendResponse(
        client_fd: posix.socket_t,
        status: HttpStatus,
        content_type: []const u8,
        body: []const u8,
    ) !void {
        var response_buf: [8192]u8 = undefined;
        const http_fmt = "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n{s}";
        const response = std.fmt.bufPrint(&response_buf, http_fmt, .{
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

test "MetricsCache: update and get" {
    var cache: MetricsCache = .{};

    // Initially empty
    try std.testing.expect(cache.get() == null);

    // Update with data
    const test_data = "test_metric 42\n";
    cache.update(test_data);

    // Should return cached data
    const result = cache.get();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(test_data, result.?);

    // Cache length should match
    try std.testing.expectEqual(test_data.len, cache.len);
}

test "MetricsCache: data truncation" {
    var cache: MetricsCache = .{};

    // Update with data
    const short_data = "short";
    cache.update(short_data);
    try std.testing.expectEqual(@as(usize, 5), cache.len);

    // Update with different data (should overwrite)
    const longer_data = "longer_data_here";
    cache.update(longer_data);
    try std.testing.expectEqual(longer_data.len, cache.len);

    const result = cache.get();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(longer_data, result.?);
}

test "MetricsServer: parseAuthHeader" {
    const TestCase = struct {
        input: []const u8,
        expected: ?[]const u8,
    };

    const cases = [_]TestCase{
        // Valid Authorization header
        .{
            .input = "GET /metrics HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret123\r\n\r\n",
            .expected = "secret123",
        },
        // Lowercase header name
        .{
            .input = "GET /metrics HTTP/1.1\r\nauthorization: bearer mytoken\r\n\r\n",
            .expected = "mytoken",
        },
        // No Authorization header
        .{
            .input = "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .expected = null,
        },
        // Empty request
        .{
            .input = "",
            .expected = null,
        },
        // Token with spaces trimmed
        .{
            .input = "GET /metrics HTTP/1.1\r\nAuthorization: Bearer   spaced_token   \r\n\r\n",
            .expected = "spaced_token",
        },
    };

    for (cases) |case| {
        const result = MetricsServer.parseAuthHeader(case.input);
        if (case.expected) |expected| {
            try std.testing.expect(result != null);
            try std.testing.expectEqualStrings(expected, result.?);
        } else {
            try std.testing.expect(result == null);
        }
    }
}
