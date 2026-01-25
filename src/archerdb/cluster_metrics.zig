// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Cluster-specific Prometheus metrics for connection pooling and cluster health.
//!
//! Provides metrics for tracking:
//! - Connection pool state (active, idle, total connections)
//! - Acquire/release operations and timeouts
//! - Health check statistics
//! - Memory pressure events
//!
//! All metrics follow Prometheus naming conventions (archerdb_pool_*).

const std = @import("std");
const metrics = @import("metrics.zig");

const Gauge = metrics.Gauge;
const Counter = metrics.Counter;

// ============================================================================
// Connection Pool State Metrics
// ============================================================================

/// Currently in-use connections.
/// This is the number of connections actively serving requests.
pub var archerdb_pool_connections_active = Gauge.init(
    "archerdb_pool_connections_active",
    "Number of currently in-use connections",
    null,
);

/// Available idle connections.
/// Connections that are ready to be acquired without creating new ones.
pub var archerdb_pool_connections_idle = Gauge.init(
    "archerdb_pool_connections_idle",
    "Number of available idle connections in the pool",
    null,
);

/// Total connections created since startup.
/// Monotonically increasing counter of all connections ever created.
pub var archerdb_pool_connections_total = Counter.init(
    "archerdb_pool_connections_total",
    "Total connections created since server startup",
    null,
);

// ============================================================================
// Connection Pool Operation Metrics
// ============================================================================

/// Total acquire operations.
/// Incremented every time a client requests a connection from the pool.
pub var archerdb_pool_acquire_total = Counter.init(
    "archerdb_pool_acquire_total",
    "Total connection acquire operations",
    null,
);

/// Acquire operations that timed out.
/// Client waited too long (exceeded acquire_timeout_ms) without getting a connection.
pub var archerdb_pool_acquire_timeout_total = Counter.init(
    "archerdb_pool_acquire_timeout_total",
    "Acquire operations that timed out waiting for a connection",
    null,
);

/// Total release operations.
/// Incremented every time a connection is returned to the pool.
pub var archerdb_pool_release_total = Counter.init(
    "archerdb_pool_release_total",
    "Total connection release operations",
    null,
);

// ============================================================================
// Health Check Metrics
// ============================================================================

/// Health checks performed.
/// Periodic health checks run to detect unhealthy connections.
pub var archerdb_pool_health_check_total = Counter.init(
    "archerdb_pool_health_check_total",
    "Total health checks performed on pooled connections",
    null,
);

/// Failed health checks.
/// Connections that failed health check and were closed.
pub var archerdb_pool_health_check_failed_total = Counter.init(
    "archerdb_pool_health_check_failed_total",
    "Health checks that failed (unhealthy connections closed)",
    null,
);

// ============================================================================
// Resource Pressure Metrics
// ============================================================================

/// Memory pressure events detected.
/// Triggered when available memory falls below 20% of total.
pub var archerdb_pool_memory_pressure_detected_total = Counter.init(
    "archerdb_pool_memory_pressure_detected_total",
    "Times memory pressure was detected (triggers faster idle timeout)",
    null,
);

/// Connections reaped due to idle timeout.
/// Counter for connections closed because they were idle too long.
pub var archerdb_pool_connections_reaped_total = Counter.init(
    "archerdb_pool_connections_reaped_total",
    "Idle connections closed due to timeout",
    null,
);

/// Current memory pressure state (0 = normal, 1 = pressure).
pub var archerdb_pool_memory_pressure_state = Gauge.init(
    "archerdb_pool_memory_pressure_state",
    "Current memory pressure state (0=normal, 1=under pressure)",
    null,
);

/// Waiter queue length.
/// Number of acquire requests waiting for a connection.
pub var archerdb_pool_waiters = Gauge.init(
    "archerdb_pool_waiters",
    "Number of acquire requests waiting for a connection",
    null,
);

// ============================================================================
// Per-Client Metrics (Top-N Tracking)
// ============================================================================

/// Configuration for top-N client tracking.
pub const TopClientConfig = struct {
    /// Maximum number of clients to track individually (default: 10)
    max_tracked_clients: u8 = 10,
};

/// Per-client connection statistics.
pub const ClientStats = struct {
    /// Client identifier (e.g., IP address or authenticated user)
    client_id: [64]u8 = [_]u8{0} ** 64,
    client_id_len: usize = 0,
    /// Number of active connections held by this client
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Total acquires by this client
    total_acquires: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total releases by this client
    total_releases: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Last activity timestamp (milliseconds since epoch)
    last_activity_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn setClientId(self: *ClientStats, id: []const u8) void {
        const copy_len = @min(id.len, self.client_id.len);
        @memcpy(self.client_id[0..copy_len], id[0..copy_len]);
        self.client_id_len = copy_len;
    }

    pub fn getClientId(self: *const ClientStats) []const u8 {
        return self.client_id[0..self.client_id_len];
    }
};

/// ClusterMetrics manages pool metrics with optional per-client tracking.
pub const ClusterMetrics = struct {
    /// Top-N client tracking slots
    top_clients: [10]ClientStats,
    /// Configuration
    config: TopClientConfig,

    const Self = @This();

    /// Initialize cluster metrics.
    pub fn init() Self {
        return .{
            .top_clients = [_]ClientStats{.{}} ** 10,
            .config = .{},
        };
    }

    /// Initialize with custom configuration.
    pub fn initWithConfig(config: TopClientConfig) Self {
        return .{
            .top_clients = [_]ClientStats{.{}} ** 10,
            .config = config,
        };
    }

    /// Record a connection acquire.
    pub fn recordAcquire(self: *Self, client_id: ?[]const u8) void {
        archerdb_pool_acquire_total.inc();

        if (client_id) |id| {
            self.updateClientStats(id, true);
        }
    }

    /// Record a connection release.
    pub fn recordRelease(self: *Self, client_id: ?[]const u8) void {
        archerdb_pool_release_total.inc();

        if (client_id) |id| {
            self.updateClientStats(id, false);
        }
    }

    /// Record an acquire timeout.
    pub fn recordAcquireTimeout(self: *Self) void {
        archerdb_pool_acquire_timeout_total.inc();
    }

    /// Record a health check result.
    pub fn recordHealthCheck(self: *Self, passed: bool) void {
        archerdb_pool_health_check_total.inc();
        if (!passed) {
            archerdb_pool_health_check_failed_total.inc();
        }
    }

    /// Record memory pressure detection.
    pub fn recordMemoryPressure(self: *Self, under_pressure: bool) void {
        _ = self;
        archerdb_pool_memory_pressure_state.set(if (under_pressure) 1 else 0);
        if (under_pressure) {
            archerdb_pool_memory_pressure_detected_total.inc();
        }
    }

    /// Record connection reaping.
    pub fn recordReap(self: *Self, count: u32) void {
        _ = self;
        archerdb_pool_connections_reaped_total.add(count);
    }

    /// Update pool state gauges.
    pub fn updatePoolState(self: *Self, active: u32, idle: u32, waiters: u32) void {
        _ = self;
        archerdb_pool_connections_active.set(@intCast(active));
        archerdb_pool_connections_idle.set(@intCast(idle));
        archerdb_pool_waiters.set(@intCast(waiters));
    }

    /// Record a new connection creation.
    pub fn recordNewConnection(self: *Self) void {
        _ = self;
        archerdb_pool_connections_total.inc();
    }

    /// Update per-client statistics.
    fn updateClientStats(self: *Self, client_id: []const u8, is_acquire: bool) void {
        const now_ms = std.time.milliTimestamp();

        // Find existing slot or LRU slot
        var found_slot: ?*ClientStats = null;
        var lru_slot: *ClientStats = &self.top_clients[0];
        var lru_time: i64 = std.math.maxInt(i64);

        for (&self.top_clients) |*slot| {
            const slot_id = slot.getClientId();
            if (slot_id.len == client_id.len and
                std.mem.eql(u8, slot_id, client_id))
            {
                found_slot = slot;
                break;
            }

            // Track LRU for eviction
            const slot_time = slot.last_activity_ms.load(.monotonic);
            if (slot_time < lru_time) {
                lru_time = slot_time;
                lru_slot = slot;
            }
        }

        // Use found slot or evict LRU
        const slot = found_slot orelse blk: {
            lru_slot.setClientId(client_id);
            lru_slot.active_connections.store(0, .monotonic);
            lru_slot.total_acquires.store(0, .monotonic);
            lru_slot.total_releases.store(0, .monotonic);
            break :blk lru_slot;
        };

        // Update stats
        slot.last_activity_ms.store(now_ms, .monotonic);
        if (is_acquire) {
            _ = slot.total_acquires.fetchAdd(1, .monotonic);
            _ = slot.active_connections.fetchAdd(1, .monotonic);
        } else {
            _ = slot.total_releases.fetchAdd(1, .monotonic);
            const prev = slot.active_connections.fetchSub(1, .monotonic);
            // Prevent underflow
            if (prev == 0) {
                slot.active_connections.store(0, .monotonic);
            }
        }
    }

    /// Format all cluster metrics in Prometheus text format.
    pub fn format(self: *const Self, writer: anytype) !void {
        // Pool state gauges
        try archerdb_pool_connections_active.format(writer);
        try archerdb_pool_connections_idle.format(writer);
        try archerdb_pool_waiters.format(writer);
        try archerdb_pool_memory_pressure_state.format(writer);
        try writer.writeAll("\n");

        // Operation counters
        try archerdb_pool_connections_total.format(writer);
        try archerdb_pool_acquire_total.format(writer);
        try archerdb_pool_acquire_timeout_total.format(writer);
        try archerdb_pool_release_total.format(writer);
        try writer.writeAll("\n");

        // Health check counters
        try archerdb_pool_health_check_total.format(writer);
        try archerdb_pool_health_check_failed_total.format(writer);
        try writer.writeAll("\n");

        // Resource pressure counters
        try archerdb_pool_memory_pressure_detected_total.format(writer);
        try archerdb_pool_connections_reaped_total.format(writer);
        try writer.writeAll("\n");

        // Per-client metrics (top-N only)
        try writer.writeAll("# HELP archerdb_pool_client_connections_active Active connections per tracked client\n");
        try writer.writeAll("# TYPE archerdb_pool_client_connections_active gauge\n");

        const max_tracked = self.config.max_tracked_clients;
        for (self.top_clients[0..max_tracked]) |*slot| {
            const client_id = slot.getClientId();
            if (client_id.len > 0) {
                const active = slot.active_connections.load(.monotonic);
                try writer.print("archerdb_pool_client_connections_active{{client=\"{s}\"}} {d}\n", .{
                    client_id,
                    active,
                });
            }
        }
        try writer.writeAll("\n");
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ClusterMetrics: init creates valid instance" {
    const cm = ClusterMetrics.init();
    try std.testing.expectEqual(@as(u8, 10), cm.config.max_tracked_clients);
}

test "ClusterMetrics: recordAcquire increments counter" {
    // Reset for test isolation
    archerdb_pool_acquire_total = Counter.init(
        "archerdb_pool_acquire_total",
        "Total connection acquire operations",
        null,
    );

    var cm = ClusterMetrics.init();
    cm.recordAcquire(null);
    cm.recordAcquire(null);
    cm.recordAcquire(null);

    try std.testing.expectEqual(@as(u64, 3), archerdb_pool_acquire_total.get());
}

test "ClusterMetrics: recordRelease increments counter" {
    // Reset for test isolation
    archerdb_pool_release_total = Counter.init(
        "archerdb_pool_release_total",
        "Total connection release operations",
        null,
    );

    var cm = ClusterMetrics.init();
    cm.recordRelease(null);
    cm.recordRelease(null);

    try std.testing.expectEqual(@as(u64, 2), archerdb_pool_release_total.get());
}

test "ClusterMetrics: recordHealthCheck tracks pass/fail" {
    // Reset for test isolation
    archerdb_pool_health_check_total = Counter.init(
        "archerdb_pool_health_check_total",
        "Total health checks performed on pooled connections",
        null,
    );
    archerdb_pool_health_check_failed_total = Counter.init(
        "archerdb_pool_health_check_failed_total",
        "Health checks that failed (unhealthy connections closed)",
        null,
    );

    var cm = ClusterMetrics.init();
    cm.recordHealthCheck(true);
    cm.recordHealthCheck(true);
    cm.recordHealthCheck(false);

    try std.testing.expectEqual(@as(u64, 3), archerdb_pool_health_check_total.get());
    try std.testing.expectEqual(@as(u64, 1), archerdb_pool_health_check_failed_total.get());
}

test "ClusterMetrics: updatePoolState sets gauges" {
    // Reset for test isolation
    archerdb_pool_connections_active = Gauge.init(
        "archerdb_pool_connections_active",
        "Number of currently in-use connections",
        null,
    );
    archerdb_pool_connections_idle = Gauge.init(
        "archerdb_pool_connections_idle",
        "Number of available idle connections in the pool",
        null,
    );
    archerdb_pool_waiters = Gauge.init(
        "archerdb_pool_waiters",
        "Number of acquire requests waiting for a connection",
        null,
    );

    var cm = ClusterMetrics.init();
    cm.updatePoolState(5, 10, 2);

    try std.testing.expectEqual(@as(i64, 5), archerdb_pool_connections_active.get());
    try std.testing.expectEqual(@as(i64, 10), archerdb_pool_connections_idle.get());
    try std.testing.expectEqual(@as(i64, 2), archerdb_pool_waiters.get());
}

test "ClusterMetrics: per-client tracking" {
    var cm = ClusterMetrics.init();

    // Record acquires for different clients
    cm.recordAcquire("client-a");
    cm.recordAcquire("client-a");
    cm.recordAcquire("client-b");

    // Find client-a stats
    var found_a = false;
    for (&cm.top_clients) |*slot| {
        const id = slot.getClientId();
        if (std.mem.eql(u8, id, "client-a")) {
            found_a = true;
            try std.testing.expectEqual(@as(u32, 2), slot.active_connections.load(.monotonic));
            try std.testing.expectEqual(@as(u64, 2), slot.total_acquires.load(.monotonic));
        }
    }
    try std.testing.expect(found_a);

    // Release for client-a
    cm.recordRelease("client-a");

    for (&cm.top_clients) |*slot| {
        const id = slot.getClientId();
        if (std.mem.eql(u8, id, "client-a")) {
            try std.testing.expectEqual(@as(u32, 1), slot.active_connections.load(.monotonic));
            try std.testing.expectEqual(@as(u64, 1), slot.total_releases.load(.monotonic));
        }
    }
}

test "ClusterMetrics: LRU eviction" {
    var cm = ClusterMetrics.initWithConfig(.{ .max_tracked_clients = 2 });

    // Fill up tracked clients
    cm.recordAcquire("client-1");
    std.time.sleep(1_000_000); // 1ms delay to ensure different timestamps
    cm.recordAcquire("client-2");
    std.time.sleep(1_000_000);

    // Add new client - should evict LRU (client-1)
    cm.recordAcquire("client-3");

    // client-3 should be tracked
    var found_3 = false;
    for (&cm.top_clients) |*slot| {
        const id = slot.getClientId();
        if (std.mem.eql(u8, id, "client-3")) {
            found_3 = true;
        }
    }
    try std.testing.expect(found_3);
}

test "ClusterMetrics: format produces valid output" {
    var cm = ClusterMetrics.init();
    cm.recordAcquire("test-client");
    cm.updatePoolState(1, 5, 0);

    var buffer: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try cm.format(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pool_connections_active") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pool_connections_idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pool_acquire_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_pool_client_connections_active") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test-client") != null);
}

test "ClusterMetrics: memory pressure tracking" {
    // Reset for test isolation
    archerdb_pool_memory_pressure_state = Gauge.init(
        "archerdb_pool_memory_pressure_state",
        "Current memory pressure state (0=normal, 1=under pressure)",
        null,
    );
    archerdb_pool_memory_pressure_detected_total = Counter.init(
        "archerdb_pool_memory_pressure_detected_total",
        "Times memory pressure was detected (triggers faster idle timeout)",
        null,
    );

    var cm = ClusterMetrics.init();

    cm.recordMemoryPressure(false);
    try std.testing.expectEqual(@as(i64, 0), archerdb_pool_memory_pressure_state.get());
    try std.testing.expectEqual(@as(u64, 0), archerdb_pool_memory_pressure_detected_total.get());

    cm.recordMemoryPressure(true);
    try std.testing.expectEqual(@as(i64, 1), archerdb_pool_memory_pressure_state.get());
    try std.testing.expectEqual(@as(u64, 1), archerdb_pool_memory_pressure_detected_total.get());
}
