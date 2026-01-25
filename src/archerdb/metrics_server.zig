// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Metrics and health HTTP server for observability endpoints.
//!
//! Provides:
//! - `/health/live` - Kubernetes liveness probe (always 200 if process is running)
//! - `/health/ready` - Kubernetes readiness probe (200 if replica is ready to serve)
//! - `/health/region` - Multi-region replication status (role, lag metrics)
//! - `/health/shards` - Shard distribution and resharding status
//! - `/health/encryption` - Encryption at rest status and metrics
//! - `/metrics` - Prometheus-format metrics endpoint
//!
//! The server runs in a dedicated thread to avoid blocking the main event loop.
//! It uses blocking I/O which is acceptable since metrics requests are infrequent
//! and should complete quickly.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.metrics_server);
const builtin = @import("builtin");

const vsr = @import("vsr");
const stdx = vsr.stdx;
const metrics = vsr.archerdb_metrics;
const cluster_metrics = vsr.cluster_metrics;
const load_shedding = @import("../load_shedding.zig");
const correlation = vsr.observability.correlation;

// =============================================================================
// Process Metrics Collection
// =============================================================================

/// Process start time (seconds since epoch), captured at startup
var process_start_time_seconds: u64 = 0;

/// Initialize process metrics (call once at startup)
pub fn initProcessMetrics() void {
    // Capture start time
    const ns = std.time.nanoTimestamp();
    if (ns > 0) {
        process_start_time_seconds = @intCast(@divFloor(ns, 1_000_000_000));
    }
}

/// Process metrics (standard Prometheus process_* metrics)
pub const ProcessMetrics = struct {
    /// Resident memory in bytes (VmRSS on Linux)
    resident_memory_bytes: u64 = 0,
    /// Virtual memory in bytes (VmSize on Linux)
    virtual_memory_bytes: u64 = 0,
    /// Total CPU time in seconds (user + system)
    cpu_seconds_total: f64 = 0.0,
    /// Number of open file descriptors
    open_fds: u64 = 0,
    /// Number of threads
    num_threads: u64 = 0,
    /// Start time (seconds since epoch)
    start_time_seconds: u64 = 0,
};

/// Collect process-level metrics from the operating system.
/// Returns ProcessMetrics struct with all values populated.
pub fn collectProcessMetrics() ProcessMetrics {
    var pm = ProcessMetrics{
        .start_time_seconds = process_start_time_seconds,
    };

    if (builtin.os.tag == .linux) {
        collectLinuxProcessMetrics(&pm);
    } else if (builtin.os.tag == .macos) {
        collectDarwinProcessMetrics(&pm);
    }

    return pm;
}

fn collectLinuxProcessMetrics(pm: *ProcessMetrics) void {
    // Read /proc/self/status for memory and thread count
    if (std.fs.openFileAbsolute("/proc/self/status", .{})) |file| {
        defer file.close();
        var buf: [8192]u8 = undefined;
        const bytes_read = file.read(&buf) catch 0;
        if (bytes_read > 0) {
            const content = buf[0..bytes_read];
            // Parse VmRSS (resident memory)
            if (parseStatusValue(content, "VmRSS:")) |vm_rss_kb| {
                pm.resident_memory_bytes = vm_rss_kb * 1024;
            }
            // Parse VmSize (virtual memory)
            if (parseStatusValue(content, "VmSize:")) |vm_size_kb| {
                pm.virtual_memory_bytes = vm_size_kb * 1024;
            }
            // Parse Threads count
            if (parseStatusValue(content, "Threads:")) |threads| {
                pm.num_threads = threads;
            }
        }
    } else |_| {}

    // Read /proc/self/stat for CPU time
    if (std.fs.openFileAbsolute("/proc/self/stat", .{})) |file| {
        defer file.close();
        var buf: [1024]u8 = undefined;
        const bytes_read = file.read(&buf) catch 0;
        if (bytes_read > 0) {
            const content = buf[0..bytes_read];
            if (parseCpuTime(content)) |cpu_secs| {
                pm.cpu_seconds_total = cpu_secs;
            }
        }
    } else |_| {}

    // Count open file descriptors by reading /proc/self/fd directory
    pm.open_fds = countOpenFds("/proc/self/fd");
}

fn collectDarwinProcessMetrics(pm: *ProcessMetrics) void {
    // On Darwin, use getrusage for CPU time
    // RUSAGE_SELF = 0 (get resource usage for calling process)
    const usage = posix.getrusage(0);
    // Convert timeval to seconds
    const user_secs = @as(f64, @floatFromInt(usage.utime.sec)) +
        @as(f64, @floatFromInt(usage.utime.usec)) / 1_000_000.0;
    const sys_secs = @as(f64, @floatFromInt(usage.stime.sec)) +
        @as(f64, @floatFromInt(usage.stime.usec)) / 1_000_000.0;
    pm.cpu_seconds_total = user_secs + sys_secs;

    // Darwin's maxrss is in bytes (not pages)
    pm.resident_memory_bytes = @intCast(usage.maxrss);

    // For virtual memory and threads on Darwin, would need mach_task_info
    // which requires additional mach headers. Leave at 0 for now.
    // Note: thread count could be obtained via MACH_TASK_BASIC_INFO
}

/// Parse a value from /proc/self/status format: "Key:\t<value> kB"
fn parseStatusValue(content: []const u8, key: []const u8) ?u64 {
    if (std.mem.indexOf(u8, content, key)) |key_start| {
        const value_start = key_start + key.len;
        // Skip whitespace
        var i = value_start;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) {
            i += 1;
        }
        // Read digits
        var j = i;
        while (j < content.len and content[j] >= '0' and content[j] <= '9') {
            j += 1;
        }
        if (j > i) {
            return std.fmt.parseInt(u64, content[i..j], 10) catch null;
        }
    }
    return null;
}

/// Parse CPU time from /proc/self/stat (fields 14 and 15: utime, stime in clock ticks)
fn parseCpuTime(content: []const u8) ?f64 {
    // Format: pid (comm) state ppid ... utime stime ...
    // utime is field 14 (0-indexed: 13), stime is field 15 (0-indexed: 14)
    // Fields are space-separated, but comm can contain spaces (in parentheses)

    // Find end of comm (closing parenthesis)
    const comm_end = std.mem.lastIndexOf(u8, content, ")") orelse return null;
    const rest = content[comm_end + 2 ..]; // Skip ") "

    var fields_seen: usize = 3; // pid, comm, state already consumed
    var i: usize = 0;

    // Skip to field 14 (utime)
    while (fields_seen < 13 and i < rest.len) {
        if (rest[i] == ' ') {
            fields_seen += 1;
        }
        i += 1;
    }

    // Parse utime
    var j = i;
    while (j < rest.len and rest[j] != ' ') j += 1;
    const utime = std.fmt.parseInt(u64, rest[i..j], 10) catch return null;

    // Skip to stime
    i = j + 1;
    j = i;
    while (j < rest.len and rest[j] != ' ') j += 1;
    const stime = std.fmt.parseInt(u64, rest[i..j], 10) catch return null;

    // Convert clock ticks to seconds (typically 100 ticks per second on Linux)
    const ticks_per_second: f64 = 100.0;
    return @as(f64, @floatFromInt(utime + stime)) / ticks_per_second;
}

/// Count open file descriptors by iterating directory entries
fn countOpenFds(fd_dir: []const u8) u64 {
    var count: u64 = 0;
    var dir = std.fs.openDirAbsolute(fd_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |_| {
        count += 1;
    }

    // Subtract 1 because we have one fd open for the directory itself
    return if (count > 0) count - 1 else 0;
}

/// Format process metrics in Prometheus format and write to a writer
pub fn formatProcessMetrics(pm: ProcessMetrics, writer: anytype) !void {
    // process_resident_memory_bytes
    try writer.writeAll("# HELP process_resident_memory_bytes Resident memory size in bytes.\n");
    try writer.writeAll("# TYPE process_resident_memory_bytes gauge\n");
    try writer.print("process_resident_memory_bytes {d}\n\n", .{pm.resident_memory_bytes});

    // process_virtual_memory_bytes
    try writer.writeAll("# HELP process_virtual_memory_bytes Virtual memory size in bytes.\n");
    try writer.writeAll("# TYPE process_virtual_memory_bytes gauge\n");
    try writer.print("process_virtual_memory_bytes {d}\n\n", .{pm.virtual_memory_bytes});

    // process_cpu_seconds_total
    try writer.writeAll("# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.\n");
    try writer.writeAll("# TYPE process_cpu_seconds_total counter\n");
    try writer.print("process_cpu_seconds_total {d:.6}\n\n", .{pm.cpu_seconds_total});

    // process_open_fds
    try writer.writeAll("# HELP process_open_fds Number of open file descriptors.\n");
    try writer.writeAll("# TYPE process_open_fds gauge\n");
    try writer.print("process_open_fds {d}\n\n", .{pm.open_fds});

    // process_threads (custom, not standard Prometheus but useful)
    try writer.writeAll("# HELP process_threads Number of OS threads in the process.\n");
    try writer.writeAll("# TYPE process_threads gauge\n");
    try writer.print("process_threads {d}\n\n", .{pm.num_threads});

    // process_start_time_seconds
    try writer.writeAll("# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.\n");
    try writer.writeAll("# TYPE process_start_time_seconds gauge\n");
    try writer.print("process_start_time_seconds {d}\n\n", .{pm.start_time_seconds});
}

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

// =============================================================================
// Health Endpoint Support
// =============================================================================

/// Server start time (nanoseconds since epoch), for uptime calculation
var server_start_time_ns: i128 = 0;

/// Whether the server has completed initialization
var server_initialized: bool = false;

/// Track previous write error count for delta detection
var last_write_errors: u64 = 0;

/// Timestamp of the last rebalance trigger (nanoseconds since epoch)
var last_rebalance_ns: i128 = 0;

/// Active rebalance moves currently in progress
var rebalance_active_moves: u32 = 0;

/// Set the server start time (call at startup)
pub fn setStartTime() void {
    server_start_time_ns = std.time.nanoTimestamp();
}

/// Mark the server as fully initialized (call when ready to serve)
pub fn markInitialized() void {
    server_initialized = true;
    log.info("server marked as initialized", .{});
}

/// Check if server is initialized
pub fn isInitialized() bool {
    return server_initialized;
}

/// Get server uptime in seconds
fn getUptimeSeconds() u64 {
    if (server_start_time_ns == 0) return 0;
    const now = std.time.nanoTimestamp();
    const elapsed_ns = now - server_start_time_ns;
    if (elapsed_ns < 0) return 0;
    return @intCast(@divFloor(elapsed_ns, 1_000_000_000));
}

/// Get build version string from metrics registry
fn getBuildVersion() []const u8 {
    return metrics.Registry.build_version[0..metrics.Registry.build_version_len];
}

/// Get build commit hash from metrics registry
fn getBuildCommit() []const u8 {
    return metrics.Registry.build_commit[0..metrics.Registry.build_commit_len];
}

/// Overall health status for the system
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,

    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
};

/// Individual component check status
pub const CheckStatus = enum {
    pass,
    warn,
    fail,

    pub fn toString(self: CheckStatus) []const u8 {
        return switch (self) {
            .pass => "pass",
            .warn => "warn",
            .fail => "fail",
        };
    }
};

/// Result of a component health check
pub const ComponentCheck = struct {
    name: []const u8,
    status: CheckStatus,
    message: ?[]const u8,
    duration_ms: ?u32,
};

/// Cached metrics response for avoiding recomputation on frequent scrapes.
/// Per observability/spec.md: "Cache metrics for up to 1 second"
const metrics_buffer_size = 256 * 1024;
const MetricsCache = struct {
    /// Cached response body
    data: [metrics_buffer_size]u8 = undefined,
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
        stdx.copy_disjoint(.exact, u8, self.data[0..copy_len], data[0..copy_len]);
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

// =============================================================================
// Geo-Routing Configuration
// =============================================================================

/// Maximum number of regions supported.
pub const MAX_REGIONS = 16;

/// Region health status.
pub const RegionHealth = enum {
    /// Region is healthy and accepting requests.
    healthy,
    /// Region is degraded but operational.
    degraded,
    /// Region is unhealthy and should not receive traffic.
    unhealthy,
    /// Region health is unknown (no recent health check).
    unknown,

    pub fn toString(self: RegionHealth) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
            .unknown => "unknown",
        };
    }
};

/// Information about a single region.
pub const RegionInfo = struct {
    /// Region identifier (e.g., "us-east-1", "eu-west-1").
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    /// Region display name (e.g., "US East (N. Virginia)").
    display_name: [64]u8 = [_]u8{0} ** 64,
    display_name_len: u8 = 0,
    /// Endpoint address for this region.
    endpoint: [128]u8 = [_]u8{0} ** 128,
    endpoint_len: u8 = 0,
    /// Port number for the endpoint.
    port: u16 = 0,
    /// Geographic latitude (degrees).
    latitude: f64 = 0.0,
    /// Geographic longitude (degrees).
    longitude: f64 = 0.0,
    /// Current health status.
    health: RegionHealth = .unknown,
    /// Last health check timestamp (nanoseconds since epoch).
    last_health_check_ns: i128 = 0,
    /// Average latency to this region (milliseconds), 0 if unknown.
    avg_latency_ms: u32 = 0,

    pub fn getName(self: *const RegionInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getDisplayName(self: *const RegionInfo) []const u8 {
        return self.display_name[0..self.display_name_len];
    }

    pub fn getEndpoint(self: *const RegionInfo) []const u8 {
        return self.endpoint[0..self.endpoint_len];
    }

    pub fn setName(self: *RegionInfo, name: []const u8) void {
        self.name_len = @intCast(@min(name.len, 32));
        for (0..self.name_len) |i| {
            self.name[i] = name[i];
        }
    }

    pub fn setDisplayName(self: *RegionInfo, display_name: []const u8) void {
        self.display_name_len = @intCast(@min(display_name.len, 64));
        for (0..self.display_name_len) |i| {
            self.display_name[i] = display_name[i];
        }
    }

    pub fn setEndpoint(self: *RegionInfo, endpoint: []const u8) void {
        self.endpoint_len = @intCast(@min(endpoint.len, 128));
        for (0..self.endpoint_len) |i| {
            self.endpoint[i] = endpoint[i];
        }
    }
};

/// Global geo-routing configuration.
pub const GeoRoutingConfig = struct {
    /// Whether geo-routing is enabled.
    enabled: bool = false,
    /// This region's identifier.
    local_region: [32]u8 = [_]u8{0} ** 32,
    local_region_len: u8 = 0,
    /// Number of configured regions.
    region_count: u8 = 0,
    /// Configured regions.
    regions: [MAX_REGIONS]RegionInfo = [_]RegionInfo{.{}} ** MAX_REGIONS,
    /// Health check interval (milliseconds).
    health_check_interval_ms: u32 = 30_000,
    /// Last update timestamp.
    last_update_ns: i128 = 0,

    pub fn getLocalRegion(self: *const GeoRoutingConfig) []const u8 {
        return self.local_region[0..self.local_region_len];
    }

    pub fn setLocalRegion(self: *GeoRoutingConfig, region: []const u8) void {
        self.local_region_len = @intCast(@min(region.len, 32));
        for (0..self.local_region_len) |i| {
            self.local_region[i] = region[i];
        }
    }

    /// Add a region to the configuration.
    pub fn addRegion(self: *GeoRoutingConfig, region: RegionInfo) !void {
        if (self.region_count >= MAX_REGIONS) {
            return error.TooManyRegions;
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;
        self.last_update_ns = std.time.nanoTimestamp();
    }

    /// Get all configured regions.
    pub fn getRegions(self: *const GeoRoutingConfig) []const RegionInfo {
        return self.regions[0..self.region_count];
    }

    /// Update health status for a region by name.
    pub fn updateRegionHealth(
        self: *GeoRoutingConfig,
        name: []const u8,
        health: RegionHealth,
    ) void {
        for (0..self.region_count) |i| {
            if (std.mem.eql(u8, self.regions[i].getName(), name)) {
                self.regions[i].health = health;
                self.regions[i].last_health_check_ns = std.time.nanoTimestamp();
                return;
            }
        }
    }
};

/// Global geo-routing configuration (mutable at runtime).
pub var geo_routing_config: GeoRoutingConfig = .{};

/// Enable geo-routing with the local region name.
pub fn enableGeoRouting(local_region: []const u8) void {
    geo_routing_config.enabled = true;
    geo_routing_config.setLocalRegion(local_region);
    log.info("geo-routing enabled for region: {s}", .{local_region});
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

        // Establish correlation context from trace headers (or create new root)
        // This enables trace correlation in logs for metrics/health requests
        var ctx = extractCorrelationContext(request);
        correlation.setCurrent(&ctx);
        defer correlation.setCurrent(null);

        // Parse HTTP request line (minimal parsing - just get the path)
        const path = parsePath(request) orelse {
            try sendResponse(client_fd, .bad_request, "text/plain", "Bad Request");
            return;
        };

        const cluster_metrics_snapshot = metrics.Registry.clusterMetrics();
        const shed_threshold = cluster_metrics_snapshot.shedThreshold();
        const shed_score = cluster_metrics_snapshot.shedScore();
        if (shed_threshold > 0 and shed_score >= shed_threshold) {
            const retry_after_last = cluster_metrics_snapshot.shedRetryAfterLastMs();
            const retry_after_ms: u64 = if (retry_after_last > 0) @intCast(retry_after_last) else 0;
            const retry_after_sec = @max(@as(u64, 1), (retry_after_ms + 999) / 1000);
            var header_buf: [64]u8 = undefined;
            const retry_header = std.fmt.bufPrint(
                &header_buf,
                "Retry-After: {d}\r\n",
                .{retry_after_sec},
            ) catch return error.ResponseTooLarge;
            try sendResponseWithHeaders(
                client_fd,
                .too_many_requests,
                "text/plain",
                "Too Many Requests",
                retry_header,
            );
            return;
        }

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
        } else if (std.mem.eql(u8, path, "/health/detailed")) {
            try handleHealthDetailed(client_fd);
        } else if (std.mem.eql(u8, path, "/regions")) {
            try handleRegions(client_fd);
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

    /// Extract correlation context from HTTP request headers.
    ///
    /// Attempts to parse trace context in priority order:
    /// 1. W3C traceparent header
    /// 2. B3 headers (X-B3-TraceId, X-B3-SpanId, X-B3-Sampled)
    /// 3. Falls back to creating a new root context
    fn extractCorrelationContext(request: []const u8) correlation.CorrelationContext {
        // Try W3C traceparent first
        if (extractHeader(request, "traceparent")) |traceparent| {
            if (correlation.CorrelationContext.fromTraceparent(traceparent)) |ctx| {
                return ctx;
            }
        }

        // Try B3 headers
        const b3_trace_id = extractHeader(request, "x-b3-traceid");
        const b3_span_id = extractHeader(request, "x-b3-spanid");
        const b3_sampled = extractHeader(request, "x-b3-sampled");

        if (b3_trace_id != null) {
            if (correlation.CorrelationContext.fromB3Headers(b3_trace_id, b3_span_id, b3_sampled)) |ctx| {
                return ctx;
            }
        }

        // Create new root context for untraced requests
        return correlation.CorrelationContext.newRoot(0);
    }

    /// Extract HTTP header value (case-insensitive).
    ///
    /// Searches for "Header-Name: value\r\n" pattern and returns the value.
    /// Returns null if header not found.
    fn extractHeader(request: []const u8, name: []const u8) ?[]const u8 {
        // Search line by line
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            // Skip if line is too short
            if (line.len < name.len + 2) continue;

            // Case-insensitive header name comparison
            var matches = true;
            for (name, 0..) |c, i| {
                const line_c = if (line[i] >= 'A' and line[i] <= 'Z')
                    line[i] + 32 // lowercase
                else
                    line[i];
                const name_c = if (c >= 'A' and c <= 'Z')
                    c + 32 // lowercase
                else
                    c;
                if (line_c != name_c) {
                    matches = false;
                    break;
                }
            }

            if (!matches) continue;

            // Check for ": " after header name
            if (line.len > name.len + 1 and line[name.len] == ':') {
                var value_start = name.len + 1;
                // Skip optional whitespace after colon
                while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) {
                    value_start += 1;
                }
                return line[value_start..];
            }
        }
        return null;
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
        // Liveness probe: ALWAYS returns 200 if process is running
        // Per CONTEXT.md: "never check external dependencies" for liveness
        const uptime = getUptimeSeconds();
        const version = getBuildVersion();
        const commit = getBuildCommit();

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"status\":\"ok\",\"uptime_seconds\":{d},\"version\":\"{s}\",\"commit_hash\":\"{s}\"}}",
            .{ uptime, version, commit },
        ) catch "{\"status\":\"ok\"}";

        try sendResponse(client_fd, .ok, "application/json", body);
    }

    fn handleHealthReady(client_fd: posix.socket_t) !void {
        const uptime = getUptimeSeconds();
        const version = getBuildVersion();
        const commit = getBuildCommit();

        // Must be initialized first (returns 503 until initialization complete)
        if (!server_initialized) {
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf,
                "{{\"status\":\"initializing\",\"reason\":\"server starting\",\"uptime_seconds\":{d},\"version\":\"{s}\",\"commit_hash\":\"{s}\"}}",
                .{ uptime, version, commit },
            ) catch "{\"status\":\"initializing\",\"reason\":\"server starting\"}";
            try sendResponse(client_fd, .service_unavailable, "application/json", body);
            return;
        }

        const state = replica_state;

        if (state.isReady()) {
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf,
                "{{\"status\":\"ok\",\"uptime_seconds\":{d},\"version\":\"{s}\",\"commit_hash\":\"{s}\"}}",
                .{ uptime, version, commit },
            ) catch "{\"status\":\"ok\"}";
            try sendResponse(client_fd, .ok, "application/json", body);
        } else {
            var body_buf: [512]u8 = undefined;
            const fmt = "{{\"status\":\"unavailable\",\"reason\":\"{s}\",\"uptime_seconds\":{d},\"version\":\"{s}\",\"commit_hash\":\"{s}\"}}";
            const reason = state.reason();
            const body = std.fmt.bufPrint(&body_buf, fmt, .{ reason, uptime, version, commit }) catch |err| switch (err) {
                error.NoSpaceLeft => "{\"status\":\"unavailable\"}",
            };
            const ctype = "application/json";
            try sendResponse(client_fd, .service_unavailable, ctype, body);
        }
    }

    /// Health endpoint: Multi-region replication status.
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
            \\{{"status":"{s}","role":"{s}","region_id":{d},
        ++
            \\"ship_queue_depth":{d},"lag_ops":{d},"lag_seconds":{d:.3}}}
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

    const HotShardSignal = struct {
        shard_id: i64,
        score: f64,
    };

    fn computeHotShardSignal(active_shards: u32) HotShardSignal {
        if (active_shards == 0) {
            return .{ .shard_id = -1, .score = 0.0 };
        }

        const shard_limit = @min(active_shards, metrics.Registry.max_shards);
        var total_throughput: u64 = 0;
        for (0..shard_limit) |shard| {
            const reads = metrics.Registry.shard_read_rate[shard].load(.monotonic);
            const writes = metrics.Registry.shard_write_rate[shard].load(.monotonic);
            total_throughput += reads + writes;
        }

        const avg_throughput: f64 = if (shard_limit > 0)
            @as(f64, @floatFromInt(total_throughput)) / @as(f64, @floatFromInt(shard_limit))
        else
            0.0;

        const shed_config = load_shedding.ShedConfig{};
        const queue_depth_raw = cluster_metrics.archerdb_shed_queue_depth.get();
        const queue_depth = if (queue_depth_raw > 0) @as(u64, @intCast(queue_depth_raw)) else 0;
        const queue_score_raw: f64 = if (shed_config.max_queue_depth > 0)
            @as(f64, @floatFromInt(queue_depth)) / @as(f64, @floatFromInt(shed_config.max_queue_depth))
        else
            0.0;
        const queue_score = std.math.clamp(queue_score_raw, 0.0, 1.0);

        const latency_stats = metrics.Registry.read_latency.getExtendedStats();
        const latency_ms = latency_stats.p99 * 1000.0;
        const latency_score_raw: f64 = if (shed_config.max_latency_p99_ms > 0)
            latency_ms / @as(f64, @floatFromInt(shed_config.max_latency_p99_ms))
        else
            0.0;
        const latency_score = std.math.clamp(latency_score_raw, 0.0, 1.0);

        var hottest_score: f64 = -1.0;
        var hottest_shard: i64 = -1;
        for (0..shard_limit) |shard| {
            const reads = metrics.Registry.shard_read_rate[shard].load(.monotonic);
            const writes = metrics.Registry.shard_write_rate[shard].load(.monotonic);
            const throughput = reads + writes;
            const throughput_score_raw: f64 = if (avg_throughput > 0.0)
                @as(f64, @floatFromInt(throughput)) / avg_throughput
            else
                0.0;
            const throughput_score = std.math.clamp(throughput_score_raw, 0.0, 1.0);

            const score = 0.34 * throughput_score + 0.33 * latency_score + 0.33 * queue_score;
            if (score > hottest_score) {
                hottest_score = score;
                hottest_shard = @intCast(shard);
            }
        }

        if (hottest_score < 0.0) {
            return .{ .shard_id = -1, .score = 0.0 };
        }

        return .{ .shard_id = hottest_shard, .score = hottest_score };
    }

    /// Health endpoint: Shard distribution and status.
    fn handleHealthShards(client_fd: posix.socket_t) !void {
        // Get sharding metrics from the registry (raw atomics use .load())
        const shard_count_val = metrics.Registry.shard_count.load(.monotonic);
        const resharding_status_val = metrics.Registry.resharding_status.load(.monotonic);
        const resharding_progress_val = metrics.Registry.resharding_progress.load(.monotonic);

        // Status is healthy if not resharding or resharding is complete
        const is_resharding = resharding_status_val == 1;
        const status = if (is_resharding) "resharding" else "ok";

        const resharding_mode_val = metrics.Registry.resharding_mode.load(.monotonic);
        const resharding_source_shards_val = metrics.Registry.resharding_source_shards.load(.monotonic);
        const resharding_target_shards_val = metrics.Registry.resharding_target_shards.load(.monotonic);
        const resharding_eta_seconds_val = metrics.Registry.resharding_eta_seconds.load(.monotonic);
        const resharding_dual_write_val = metrics.Registry.resharding_dual_write_enabled.load(.monotonic) != 0;

        // Progress is stored as 0-1000, convert to percentage
        const progress_pct: f64 = @as(f64, @floatFromInt(resharding_progress_val)) / 10.0;

        const hot_signal = computeHotShardSignal(shard_count_val);
        const hot_score_scaled = std.math.clamp(hot_signal.score * 100.0, 0.0, 100.0);
        const hot_ratio_scaled = metrics.Registry.shard_hottest_ratio.load(.monotonic);
        const hot_ratio: f64 = @as(f64, @floatFromInt(hot_ratio_scaled)) / 10000.0;

        const rebalance_threshold: f64 = 0.70;
        const ratio_guard: f64 = 1.5;
        const cooldown_seconds: u64 = 300;
        const max_concurrent_moves: u32 = 2;
        const ns_per_s: i128 = @as(i128, @intCast(std.time.ns_per_s));
        const cooldown_ns: i128 = @as(i128, @intCast(cooldown_seconds)) * ns_per_s;
        const now_ns_raw = std.time.nanoTimestamp();
        const now_ns: i128 = if (now_ns_raw < 0) 0 else now_ns_raw;

        if (rebalance_active_moves > 0 and last_rebalance_ns > 0 and now_ns >= last_rebalance_ns) {
            const elapsed_ns = now_ns - last_rebalance_ns;
            if (elapsed_ns >= cooldown_ns) {
                rebalance_active_moves -= 1;
                if (rebalance_active_moves == 0) {
                    last_rebalance_ns = 0;
                } else {
                    last_rebalance_ns = now_ns;
                }
            }
        }

        const elapsed_ns_since_rebalance: i128 = if (last_rebalance_ns > 0 and now_ns >= last_rebalance_ns)
            now_ns - last_rebalance_ns
        else
            0;

        var cooldown_remaining_seconds: i64 = 0;
        if (elapsed_ns_since_rebalance > 0 and elapsed_ns_since_rebalance < cooldown_ns) {
            cooldown_remaining_seconds = @intCast(@divFloor(cooldown_ns - elapsed_ns_since_rebalance, ns_per_s));
        }

        var rebalance_needed: i64 = 0;
        const hot_signal_active = hot_signal.score >= rebalance_threshold and hot_ratio >= ratio_guard;
        const cooldown_elapsed = last_rebalance_ns == 0 or elapsed_ns_since_rebalance >= cooldown_ns;
        if (hot_signal_active and cooldown_elapsed and rebalance_active_moves < max_concurrent_moves) {
            rebalance_needed = 1;
            last_rebalance_ns = now_ns;
            rebalance_active_moves += 1;
            cooldown_remaining_seconds = @intCast(cooldown_seconds);
        }

        metrics.Registry.shard_hot_id.set(hot_signal.shard_id);
        metrics.Registry.shard_hot_score.set(@intFromFloat(hot_score_scaled));
        metrics.Registry.shard_rebalance_needed.set(rebalance_needed);
        metrics.Registry.shard_rebalance_active_moves.set(@intCast(rebalance_active_moves));
        metrics.Registry.shard_rebalance_cooldown_seconds.set(cooldown_remaining_seconds);

        var body_buf: [1024]u8 = undefined;
        const fmt =
            \\{{"status":"{s}","shard_count":{d},"resharding":{s},"resharding_progress":{d:.1},
        ++
            \\"resharding_mode":{d},"resharding_source_shards":{d},"resharding_target_shards":{d},
        ++
            \\"resharding_eta_seconds":{d},"resharding_dual_write":{s},
        ++
            \\"hot_shard_id":{d},"hot_shard_score":{d:.2},"rebalance_needed":{d},"rebalance_active_moves":{d}}}
        ;
        const body = std.fmt.bufPrint(&body_buf, fmt, .{
            status,
            shard_count_val,
            if (is_resharding) "true" else "false",
            progress_pct,
            resharding_mode_val,
            resharding_source_shards_val,
            resharding_target_shards_val,
            resharding_eta_seconds_val,
            if (resharding_dual_write_val) "true" else "false",
            hot_signal.shard_id,
            hot_score_scaled,
            rebalance_needed,
            rebalance_active_moves,
        }) catch "{\"status\":\"error\"}";

        try sendResponse(client_fd, .ok, "application/json", body);
    }

    /// Health endpoint: Encryption at rest status.
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

    /// Health endpoint: Detailed component-level health breakdown.
    /// Returns overall status, uptime, version, commit, and per-component checks.
    /// HTTP status codes: 200 = healthy, 429 = degraded, 503 = unhealthy
    fn handleHealthDetailed(client_fd: posix.socket_t) !void {
        const uptime = getUptimeSeconds();
        const version = getBuildVersion();
        const commit = getBuildCommit();

        // Perform component health checks
        var checks: [8]ComponentCheck = undefined;
        var check_count: usize = 0;

        // Check 1: Replica status
        const replica_ready = replica_state.isReady();
        checks[check_count] = .{
            .name = "replica",
            .status = if (replica_ready) .pass else .fail,
            .message = if (!replica_ready) replica_state.reason() else null,
            .duration_ms = null,
        };
        check_count += 1;

        // Check 2: Memory usage
        const mem_allocated = metrics.Registry.memory_allocated_bytes.get();
        // Use resident memory from process metrics if available
        const pm = collectProcessMetrics();
        const mem_used: u64 = if (pm.resident_memory_bytes > 0)
            pm.resident_memory_bytes
        else
            @intCast(if (mem_allocated > 0) mem_allocated else 0);

        // Memory limit estimation: 16GB default (or use configured limit)
        // In production, this should come from config or cgroup limits
        const mem_limit: u64 = 16 * 1024 * 1024 * 1024; // 16GB
        const mem_pct: u64 = if (mem_limit > 0) @divFloor(mem_used * 100, mem_limit) else 0;

        const mem_status: CheckStatus = if (mem_pct > 95)
            .fail
        else if (mem_pct > 90)
            .warn
        else
            .pass;
        const mem_msg: ?[]const u8 = if (mem_pct > 90) "high memory usage" else null;

        checks[check_count] = .{
            .name = "memory",
            .status = mem_status,
            .message = mem_msg,
            .duration_ms = null,
        };
        check_count += 1;

        // Check 3: Storage (based on recent write errors)
        const write_errors = metrics.Registry.write_errors_total.get();
        const error_delta = write_errors -| last_write_errors;
        const storage_status: CheckStatus = if (error_delta > 10) .fail else .pass;
        const storage_msg: ?[]const u8 = if (write_errors > 0) "write errors detected" else null;

        checks[check_count] = .{
            .name = "storage",
            .status = storage_status,
            .message = storage_msg,
            .duration_ms = null,
        };
        check_count += 1;

        // Update last write errors for next check
        last_write_errors = write_errors;

        // Check 4: Replication lag (if replication is active)
        const repl_lag_ns = metrics.Registry.replication_lag_ns.load(.monotonic);
        if (repl_lag_ns > 0) {
            const lag_seconds = @divFloor(repl_lag_ns, 1_000_000_000);
            const repl_status: CheckStatus = if (lag_seconds > 60)
                .fail
            else if (lag_seconds > 30)
                .warn
            else
                .pass;
            const repl_msg: ?[]const u8 = if (lag_seconds > 30) "high replication lag" else null;

            checks[check_count] = .{
                .name = "replication",
                .status = repl_status,
                .message = repl_msg,
                .duration_ms = null,
            };
            check_count += 1;
        }

        // Determine overall status from component checks
        var overall: HealthStatus = .healthy;
        for (checks[0..check_count]) |check| {
            if (check.status == .fail) {
                overall = .unhealthy;
                break;
            }
            if (check.status == .warn and overall != .unhealthy) {
                overall = .degraded;
            }
        }

        // Format JSON response
        var body_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const writer = fbs.writer();

        // Start JSON object
        writer.print("{{\"status\":\"{s}\",\"uptime_seconds\":{d},\"version\":\"{s}\",\"commit_hash\":\"{s}\",\"checks\":[", .{
            overall.toString(),
            uptime,
            version,
            commit,
        }) catch {
            try sendResponse(client_fd, .service_unavailable, "application/json", "{\"status\":\"error\"}");
            return;
        };

        // Format each component check
        for (checks[0..check_count], 0..) |check, i| {
            if (i > 0) writer.writeAll(",") catch {};

            // Format check object
            writer.print("{{\"name\":\"{s}\",\"status\":\"{s}\"", .{
                check.name,
                check.status.toString(),
            }) catch {};

            // Add optional message
            if (check.message) |msg| {
                writer.print(",\"message\":\"{s}\"", .{msg}) catch {};
            }

            // Add optional duration
            if (check.duration_ms) |dur| {
                writer.print(",\"duration_ms\":{d}", .{dur}) catch {};
            }

            writer.writeAll("}") catch {};
        }

        // Close JSON
        writer.writeAll("]}") catch {};

        const body = fbs.getWritten();

        // Determine HTTP status code based on overall health
        const http_status: HttpStatus = switch (overall) {
            .healthy => .ok,
            .degraded => .too_many_requests, // 429 for degraded
            .unhealthy => .service_unavailable, // 503 for unhealthy
        };

        try sendResponse(client_fd, http_status, "application/json", body);
    }

    /// Geo-routing endpoint: Returns all known regions with health status.
    fn handleRegions(client_fd: posix.socket_t) !void {
        const config = &geo_routing_config;

        if (!config.enabled) {
            const body =
                \\{"enabled":false,"regions":[]}
            ;
            try sendResponse(client_fd, .ok, "application/json", body);
            return;
        }

        // Build JSON response with all regions
        var body_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const writer = fbs.writer();

        try writer.print("{{\"enabled\":true,\"local_region\":\"{s}\",\"regions\":[", .{
            config.getLocalRegion(),
        });

        const regions = config.getRegions();
        for (regions, 0..) |region, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print(
                \\{{"name":"{s}","display_name":"{s}","endpoint":"{s}",
            ++
                \\"port":{d},"latitude":{d:.6},"longitude":{d:.6},
            ++
                \\"health":"{s}","avg_latency_ms":{d}}}
            , .{
                region.getName(),
                region.getDisplayName(),
                region.getEndpoint(),
                region.port,
                region.latitude,
                region.longitude,
                region.health.toString(),
                region.avg_latency_ms,
            });
        }

        try writer.writeAll("]}");

        const body = fbs.getWritten();
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

        // Collect process metrics from OS (Linux/Darwin)
        const pm = collectProcessMetrics();

        // Format all metrics to buffer
        var buf: [metrics_buffer_size]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write process metrics first (standard Prometheus process_* metrics)
        formatProcessMetrics(pm, writer) catch |err| {
            log.warn("error formatting process metrics: {}", .{err});
            const msg = "Error formatting metrics";
            try sendResponse(client_fd, .service_unavailable, "text/plain", msg);
            return;
        };

        // Write application metrics
        metrics.Registry.format(writer) catch |err| {
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
        too_many_requests, // 429 - used for degraded health status
        service_unavailable,

        fn code(self: HttpStatus) []const u8 {
            return switch (self) {
                .ok => "200 OK",
                .bad_request => "400 Bad Request",
                .unauthorized => "401 Unauthorized",
                .not_found => "404 Not Found",
                .too_many_requests => "429 Too Many Requests",
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
        try sendResponseWithHeaders(client_fd, status, content_type, body, null);
    }

    fn sendResponseWithHeaders(
        client_fd: posix.socket_t,
        status: HttpStatus,
        content_type: []const u8,
        body: []const u8,
        extra_headers: ?[]const u8,
    ) !void {
        var header_buf: [512]u8 = undefined;
        const extra = extra_headers orelse "";
        const http_fmt = "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "{s}" ++
            "Connection: close\r\n\r\n";
        const header = std.fmt.bufPrint(&header_buf, http_fmt, .{
            status.code(),
            content_type,
            body.len,
            extra,
        }) catch return error.ResponseTooLarge;

        _ = try posix.write(client_fd, header);
        if (body.len > 0) {
            _ = try posix.write(client_fd, body);
        }
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

test "MetricsServer: sendResponse handles large body" {
    var body: [9000]u8 = [_]u8{'a'} ** 9000;
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try MetricsServer.sendResponse(fds[1], .ok, "text/plain", &body);

    var buffer: [16384]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const read_len = try posix.read(fds[0], buffer[total..]);
        if (read_len == 0) break;
        total += read_len;
        if (total == buffer.len) break;
    }

    const response = buffer[0..total];
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 9000") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, &body));
}

test "MetricsServer: sendResponseWithHeaders emits retry-after" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try MetricsServer.sendResponseWithHeaders(
        fds[1],
        .too_many_requests,
        "text/plain",
        "Too Many Requests",
        "Retry-After: 3\r\n",
    );

    var buffer: [2048]u8 = undefined;
    const read_len = try posix.read(fds[0], &buffer);
    const response = buffer[0..read_len];

    try std.testing.expect(std.mem.indexOf(u8, response, "429 Too Many Requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Retry-After: 3") != null);
}

test "MetricsServer: overload response includes retry-after header" {
    const fds = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const cluster_metrics_snapshot = metrics.Registry.clusterMetrics();
    cluster_metrics_snapshot.updateShedSignals(1.0, 0, 0, 0, 0.5);
    cluster_metrics_snapshot.recordShedRetryAfter(3000);

    _ = try posix.write(fds[0], "GET /metrics HTTP/1.1\r\n\r\n");
    try MetricsServer.handleRequest(fds[1]);

    var buffer: [4096]u8 = undefined;
    const read_len = try posix.read(fds[0], &buffer);
    const response = buffer[0..read_len];

    try std.testing.expect(std.mem.indexOf(u8, response, "429 Too Many Requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Retry-After: 3") != null);

    cluster_metrics_snapshot.updateShedSignals(0.0, 0, 0, 0, 0.0);
    cluster_metrics_snapshot.recordShedRetryAfter(0);
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
            .input = "GET /metrics HTTP/1.1\r\nHost: localhost\r\n" ++
                "Authorization: Bearer secret123\r\n\r\n",
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

// =============================================================================
// Health Endpoint Tests
// =============================================================================

test "MetricsServer: /health/shards includes rebalance fields" {
    const fds = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const old_shard_count = metrics.Registry.shard_count.load(.monotonic);
    const old_shard0_read = metrics.Registry.shard_read_rate[0].load(.monotonic);
    const old_shard0_write = metrics.Registry.shard_write_rate[0].load(.monotonic);
    const old_shard1_read = metrics.Registry.shard_read_rate[1].load(.monotonic);
    const old_shard1_write = metrics.Registry.shard_write_rate[1].load(.monotonic);
    const old_hottest_ratio = metrics.Registry.shard_hottest_ratio.load(.monotonic);
    const old_resharding_status = metrics.Registry.resharding_status.load(.monotonic);
    const old_resharding_progress = metrics.Registry.resharding_progress.load(.monotonic);
    const old_resharding_mode = metrics.Registry.resharding_mode.load(.monotonic);
    const old_source_shards = metrics.Registry.resharding_source_shards.load(.monotonic);
    const old_target_shards = metrics.Registry.resharding_target_shards.load(.monotonic);
    const old_eta_seconds = metrics.Registry.resharding_eta_seconds.load(.monotonic);
    const old_dual_write = metrics.Registry.resharding_dual_write_enabled.load(.monotonic);
    const old_queue_depth = cluster_metrics.archerdb_shed_queue_depth.get();
    const old_read_latency = metrics.Registry.read_latency;
    const old_last_rebalance = last_rebalance_ns;
    const old_active_moves = rebalance_active_moves;

    defer metrics.Registry.shard_count.store(old_shard_count, .monotonic);
    defer metrics.Registry.shard_read_rate[0].store(old_shard0_read, .monotonic);
    defer metrics.Registry.shard_write_rate[0].store(old_shard0_write, .monotonic);
    defer metrics.Registry.shard_read_rate[1].store(old_shard1_read, .monotonic);
    defer metrics.Registry.shard_write_rate[1].store(old_shard1_write, .monotonic);
    defer metrics.Registry.shard_hottest_ratio.store(old_hottest_ratio, .monotonic);
    defer metrics.Registry.resharding_status.store(old_resharding_status, .monotonic);
    defer metrics.Registry.resharding_progress.store(old_resharding_progress, .monotonic);
    defer metrics.Registry.resharding_mode.store(old_resharding_mode, .monotonic);
    defer metrics.Registry.resharding_source_shards.store(old_source_shards, .monotonic);
    defer metrics.Registry.resharding_target_shards.store(old_target_shards, .monotonic);
    defer metrics.Registry.resharding_eta_seconds.store(old_eta_seconds, .monotonic);
    defer metrics.Registry.resharding_dual_write_enabled.store(old_dual_write, .monotonic);
    defer cluster_metrics.archerdb_shed_queue_depth.set(old_queue_depth);
    defer metrics.Registry.read_latency = old_read_latency;
    defer last_rebalance_ns = old_last_rebalance;
    defer rebalance_active_moves = old_active_moves;

    metrics.Registry.shard_count.store(2, .monotonic);
    metrics.Registry.shard_read_rate[0].store(100, .monotonic);
    metrics.Registry.shard_write_rate[0].store(0, .monotonic);
    metrics.Registry.shard_read_rate[1].store(200, .monotonic);
    metrics.Registry.shard_write_rate[1].store(0, .monotonic);
    metrics.Registry.shard_hottest_ratio.store(16000, .monotonic);
    metrics.Registry.resharding_status.store(1, .monotonic);
    metrics.Registry.resharding_progress.store(250, .monotonic);
    metrics.Registry.resharding_mode.store(2, .monotonic);
    metrics.Registry.resharding_source_shards.store(2, .monotonic);
    metrics.Registry.resharding_target_shards.store(4, .monotonic);
    metrics.Registry.resharding_eta_seconds.store(120, .monotonic);
    metrics.Registry.resharding_dual_write_enabled.store(1, .monotonic);
    metrics.Registry.read_latency = metrics.latencyHistogram(
        "archerdb_read_latency_seconds",
        "Read operation latency histogram",
        null,
    );
    metrics.Registry.read_latency.observe(0.1);
    cluster_metrics.archerdb_shed_queue_depth.set(10000);
    last_rebalance_ns = 0;
    rebalance_active_moves = 0;

    _ = try posix.write(fds[0], "GET /health/shards HTTP/1.1\r\n\r\n");
    try MetricsServer.handleRequest(fds[1]);

    var buffer: [4096]u8 = undefined;
    const read_len = try posix.read(fds[0], &buffer);
    const response = buffer[0..read_len];

    try std.testing.expect(std.mem.indexOf(u8, response, "\"resharding_mode\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"resharding_source_shards\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"resharding_target_shards\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"resharding_eta_seconds\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"resharding_dual_write\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"hot_shard_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"hot_shard_score\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"rebalance_needed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"rebalance_active_moves\":1") != null);
}

test "getUptimeSeconds calculates correctly" {
    // Save current state
    const old_start = server_start_time_ns;
    defer server_start_time_ns = old_start;

    // Set start time to 2 seconds ago
    const now = std.time.nanoTimestamp();
    server_start_time_ns = now - 2_000_000_000;

    const uptime = getUptimeSeconds();
    try std.testing.expect(uptime >= 2);
    try std.testing.expect(uptime < 5); // Should be close to 2
}

test "getUptimeSeconds returns 0 if not set" {
    // Save current state
    const old_start = server_start_time_ns;
    defer server_start_time_ns = old_start;

    server_start_time_ns = 0;
    const uptime = getUptimeSeconds();
    try std.testing.expectEqual(@as(u64, 0), uptime);
}

test "setStartTime sets time" {
    // Save current state
    const old_start = server_start_time_ns;
    defer server_start_time_ns = old_start;

    server_start_time_ns = 0;
    setStartTime();
    try std.testing.expect(server_start_time_ns > 0);
}

test "markInitialized and isInitialized" {
    // Save current state
    const old_init = server_initialized;
    defer server_initialized = old_init;

    server_initialized = false;
    try std.testing.expect(!isInitialized());

    markInitialized();
    try std.testing.expect(isInitialized());
}

test "HealthStatus toString" {
    try std.testing.expectEqualStrings("healthy", HealthStatus.healthy.toString());
    try std.testing.expectEqualStrings("degraded", HealthStatus.degraded.toString());
    try std.testing.expectEqualStrings("unhealthy", HealthStatus.unhealthy.toString());
}

test "CheckStatus toString" {
    try std.testing.expectEqualStrings("pass", CheckStatus.pass.toString());
    try std.testing.expectEqualStrings("warn", CheckStatus.warn.toString());
    try std.testing.expectEqualStrings("fail", CheckStatus.fail.toString());
}

test "ComponentCheck struct initialization" {
    const check = ComponentCheck{
        .name = "test_component",
        .status = .pass,
        .message = "all good",
        .duration_ms = 42,
    };

    try std.testing.expectEqualStrings("test_component", check.name);
    try std.testing.expectEqual(CheckStatus.pass, check.status);
    try std.testing.expectEqualStrings("all good", check.message.?);
    try std.testing.expectEqual(@as(u32, 42), check.duration_ms.?);
}

test "ComponentCheck with null optionals" {
    const check = ComponentCheck{
        .name = "minimal",
        .status = .fail,
        .message = null,
        .duration_ms = null,
    };

    try std.testing.expectEqualStrings("minimal", check.name);
    try std.testing.expectEqual(CheckStatus.fail, check.status);
    try std.testing.expect(check.message == null);
    try std.testing.expect(check.duration_ms == null);
}

test "getBuildVersion returns registry version" {
    // Initialize with known value
    metrics.Registry.initBuildInfo("1.2.3-test", "abc123");

    const version = getBuildVersion();
    try std.testing.expectEqualStrings("1.2.3-test", version);
}

test "getBuildCommit returns registry commit" {
    // Initialize with known value
    metrics.Registry.initBuildInfo("1.2.3", "testcommit123");

    const commit = getBuildCommit();
    try std.testing.expectEqualStrings("testcommit123", commit);
}

test "health endpoint: replica state affects ready status" {
    // Save current state
    const old_state = replica_state;
    const old_init = server_initialized;
    defer {
        replica_state = old_state;
        server_initialized = old_init;
    }

    // Test all states
    server_initialized = true;

    replica_state = .starting;
    try std.testing.expect(!replica_state.isReady());

    replica_state = .ready;
    try std.testing.expect(replica_state.isReady());

    replica_state = .view_change;
    try std.testing.expect(!replica_state.isReady());

    replica_state = .recovering;
    try std.testing.expect(!replica_state.isReady());

    replica_state = .shutting_down;
    try std.testing.expect(!replica_state.isReady());
}

test "health detailed: overall status aggregation logic" {
    // Test the aggregation logic:
    // - All pass -> healthy
    // - Any warn, no fail -> degraded
    // - Any fail -> unhealthy

    // Simulate all pass
    var overall: HealthStatus = .healthy;
    const all_pass = [_]CheckStatus{ .pass, .pass, .pass };
    for (all_pass) |status| {
        if (status == .fail) {
            overall = .unhealthy;
            break;
        }
        if (status == .warn and overall != .unhealthy) {
            overall = .degraded;
        }
    }
    try std.testing.expectEqual(HealthStatus.healthy, overall);

    // Simulate one warn
    overall = .healthy;
    const one_warn = [_]CheckStatus{ .pass, .warn, .pass };
    for (one_warn) |status| {
        if (status == .fail) {
            overall = .unhealthy;
            break;
        }
        if (status == .warn and overall != .unhealthy) {
            overall = .degraded;
        }
    }
    try std.testing.expectEqual(HealthStatus.degraded, overall);

    // Simulate one fail
    overall = .healthy;
    const one_fail = [_]CheckStatus{ .pass, .fail, .warn };
    for (one_fail) |status| {
        if (status == .fail) {
            overall = .unhealthy;
            break;
        }
        if (status == .warn and overall != .unhealthy) {
            overall = .degraded;
        }
    }
    try std.testing.expectEqual(HealthStatus.unhealthy, overall);
}

test "HttpStatus code includes 429 for degraded" {
    try std.testing.expectEqualStrings("200 OK", MetricsServer.HttpStatus.ok.code());
    try std.testing.expectEqualStrings("429 Too Many Requests", MetricsServer.HttpStatus.too_many_requests.code());
    try std.testing.expectEqualStrings("503 Service Unavailable", MetricsServer.HttpStatus.service_unavailable.code());
}

test "extractHeader: finds header case-insensitively" {
    const request =
        "GET /metrics HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\r\n" ++
        "X-B3-TraceId: abc123\r\n" ++
        "\r\n";

    // Should find lowercase header
    const traceparent = MetricsServer.extractHeader(request, "traceparent");
    try std.testing.expect(traceparent != null);
    try std.testing.expectEqualStrings(
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        traceparent.?,
    );

    // Should find mixed-case header (case-insensitive)
    const b3_trace = MetricsServer.extractHeader(request, "x-b3-traceid");
    try std.testing.expect(b3_trace != null);
    try std.testing.expectEqualStrings("abc123", b3_trace.?);

    // Should not find non-existent header
    const missing = MetricsServer.extractHeader(request, "x-b3-spanid");
    try std.testing.expect(missing == null);
}

test "extractCorrelationContext: from traceparent" {
    const request =
        "GET /health HTTP/1.1\r\n" ++
        "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\r\n" ++
        "\r\n";

    const ctx = MetricsServer.extractCorrelationContext(request);

    // Verify trace_id was extracted
    const trace_hex = ctx.traceIdHex();
    try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &trace_hex);

    // Verify span_id was extracted
    const span_hex = ctx.spanIdHex();
    try std.testing.expectEqualStrings("b7ad6b7169203331", &span_hex);

    // Verify sampled flag
    try std.testing.expect(ctx.isSampled());
}

test "extractCorrelationContext: from B3 headers" {
    const request =
        "GET /metrics HTTP/1.1\r\n" ++
        "x-b3-traceid: 0af7651916cd43dd8448eb211c80319c\r\n" ++
        "x-b3-spanid: b7ad6b7169203331\r\n" ++
        "x-b3-sampled: 1\r\n" ++
        "\r\n";

    const ctx = MetricsServer.extractCorrelationContext(request);

    // Verify trace_id was extracted
    const trace_hex = ctx.traceIdHex();
    try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &trace_hex);

    // Verify sampled flag
    try std.testing.expect(ctx.isSampled());
}

test "extractCorrelationContext: creates new root when no headers" {
    const request =
        "GET /health HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "\r\n";

    const ctx = MetricsServer.extractCorrelationContext(request);

    // Should have generated a valid trace_id (not all zeros)
    var all_zero = true;
    for (ctx.trace_id) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);

    // New root traces are sampled by default
    try std.testing.expect(ctx.isSampled());
}
