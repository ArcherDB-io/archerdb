// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Cluster-specific Prometheus metrics for connection pooling and cluster health.
//!
//! Provides metrics for tracking:
//! - Connection pool state (active, idle, total connections)
//! - Acquire/release operations and timeouts
//! - Health check statistics
//! - Memory pressure events
//! - Load shedding decisions (overload score, shed requests, retry-after values)
//!
//! All metrics follow Prometheus naming conventions (archerdb_pool_*, archerdb_shed_*).

const std = @import("std");
const metrics = @import("metrics.zig");
const constants = @import("../constants.zig");

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
// Load Shedding Metrics
// ============================================================================

/// Total requests shed (rejected with 429).
pub var archerdb_shed_requests_total = Counter.init(
    "archerdb_shed_requests_total",
    "Total requests shed due to overload",
    null,
);

/// Current composite overload score (0-100 scaled for integer).
/// 0 = no load, 100 = fully overloaded.
pub var archerdb_shed_score = Gauge.init(
    "archerdb_shed_score",
    "Current composite overload score (0-100, where 100 = fully overloaded)",
    null,
);

/// Current queue depth used for shedding decision.
pub var archerdb_shed_queue_depth = Gauge.init(
    "archerdb_shed_queue_depth",
    "Current queue depth used for load shedding decision",
    null,
);

/// Current P99 latency in milliseconds used for shedding decision.
pub var archerdb_shed_latency_p99_ms = Gauge.init(
    "archerdb_shed_latency_p99_ms",
    "Current P99 latency in milliseconds for load shedding",
    null,
);

/// Current memory pressure percentage used for shedding decision.
pub var archerdb_shed_memory_pressure_pct = Gauge.init(
    "archerdb_shed_memory_pressure_pct",
    "Current memory pressure percentage (0-100)",
    null,
);

/// Current configured shedding threshold (scaled 0-100).
/// Useful for alerting when threshold is changed.
pub var archerdb_shed_threshold = Gauge.init(
    "archerdb_shed_threshold",
    "Current configured shedding threshold (0-100)",
    null,
);

/// Histogram of Retry-After values sent in milliseconds.
/// Buckets: 1s, 2s, 5s, 10s, 15s, 20s, 30s
pub const ShedRetryHistogram = metrics.HistogramType(7);
pub var archerdb_shed_retry_after_ms = ShedRetryHistogram.init(
    "archerdb_shed_retry_after_ms",
    "Distribution of Retry-After values sent to clients (milliseconds)",
    null,
    .{ 1000, 2000, 5000, 10000, 15000, 20000, 30000 },
);

// ============================================================================
// Read Replica Routing Metrics
// ============================================================================

/// Total read queries routed (including failover to leader).
pub var archerdb_routing_reads_total = Counter.init(
    "archerdb_routing_reads_total",
    "Total read queries routed through read replica router",
    null,
);

/// Total write queries routed.
pub var archerdb_routing_writes_total = Counter.init(
    "archerdb_routing_writes_total",
    "Total write queries routed to leader",
    null,
);

/// Total reads successfully routed to a replica.
pub var archerdb_routing_to_replica_total = Counter.init(
    "archerdb_routing_to_replica_total",
    "Read queries routed to healthy replicas",
    null,
);

/// Total reads failed over to leader due to unhealthy replicas.
pub var archerdb_routing_failover_total = Counter.init(
    "archerdb_routing_failover_total",
    "Read queries failed over to leader due to unhealthy replicas",
    null,
);

/// Current round-robin index used for replica selection.
pub var archerdb_routing_round_robin_index = Gauge.init(
    "archerdb_routing_round_robin_index",
    "Current round-robin index for replica selection",
    null,
);

// ============================================================================
// Load Shedding Helper Functions
// ============================================================================

/// Update load shedding metrics from shedder state.
pub fn updateShedMetrics(
    score: f32,
    queue_depth: u32,
    latency_p99_ms: u64,
    memory_pct: u8,
    threshold: f32,
) void {
    // Scale score and threshold to 0-100 integer range
    archerdb_shed_score.set(@intFromFloat(score * 100));
    archerdb_shed_threshold.set(@intFromFloat(threshold * 100));

    archerdb_shed_queue_depth.set(@intCast(queue_depth));
    archerdb_shed_latency_p99_ms.set(@intCast(latency_p99_ms));
    archerdb_shed_memory_pressure_pct.set(@intCast(memory_pct));
}

/// Record a shed decision (request rejected).
pub fn recordShedRequest(retry_after_ms: u64) void {
    archerdb_shed_requests_total.inc();
    // Convert to seconds for histogram observation
    const retry_sec: f64 = @as(f64, @floatFromInt(retry_after_ms)) / 1000.0;
    archerdb_shed_retry_after_ms.observe(retry_sec);
}

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

/// Per-replica routing statistics (health and lag).
pub const RoutingReplicaStats = struct {
    replica_id: u128 = 0,
    health: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    replication_lag_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_update_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

/// ClusterMetrics manages pool metrics with optional per-client tracking.
pub const ClusterMetrics = struct {
    /// Top-N client tracking slots
    top_clients: [10]ClientStats,
    /// Configuration
    config: TopClientConfig,
    /// Per-replica routing stats (bounded cardinality)
    routing_replicas: [constants.replicas_max]RoutingReplicaStats,

    const Self = @This();

    /// Initialize cluster metrics.
    pub fn init() Self {
        return .{
            .top_clients = [_]ClientStats{.{}} ** 10,
            .config = .{},
            .routing_replicas = [_]RoutingReplicaStats{.{}} ** constants.replicas_max,
        };
    }

    /// Initialize with custom configuration.
    pub fn initWithConfig(config: TopClientConfig) Self {
        return .{
            .top_clients = [_]ClientStats{.{}} ** 10,
            .config = config,
            .routing_replicas = [_]RoutingReplicaStats{.{}} ** constants.replicas_max,
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

    /// Record a read routed through the replica router.
    pub fn recordRoutingRead(self: *Self) void {
        _ = self;
        archerdb_routing_reads_total.inc();
    }

    /// Record a write routed to the leader.
    pub fn recordRoutingWrite(self: *Self) void {
        _ = self;
        archerdb_routing_writes_total.inc();
    }

    /// Record a read routed to a replica.
    pub fn recordRoutingToReplica(self: *Self) void {
        _ = self;
        archerdb_routing_to_replica_total.inc();
    }

    /// Record a read failed over to the leader.
    pub fn recordRoutingFailover(self: *Self) void {
        _ = self;
        archerdb_routing_failover_total.inc();
    }

    /// Update the round-robin index gauge.
    pub fn recordRoutingRoundRobinIndex(self: *Self, index: usize) void {
        _ = self;
        archerdb_routing_round_robin_index.set(@intCast(index));
    }

    /// Update per-replica health gauge.
    pub fn updateRoutingReplicaHealth(self: *Self, replica_id: u128, healthy: bool) void {
        const now_ms = std.time.milliTimestamp();
        const slot = self.upsertRoutingReplica(replica_id);
        slot.health.store(if (healthy) 1 else 0, .monotonic);
        slot.last_update_ms.store(now_ms, .monotonic);
    }

    /// Update per-replica replication lag gauge.
    pub fn updateRoutingReplicationLag(self: *Self, replica_id: u128, lag_ops: u64) void {
        const now_ms = std.time.milliTimestamp();
        const slot = self.upsertRoutingReplica(replica_id);
        slot.replication_lag_ops.store(lag_ops, .monotonic);
        slot.last_update_ms.store(now_ms, .monotonic);
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

    fn upsertRoutingReplica(self: *Self, replica_id: u128) *RoutingReplicaStats {
        var empty_slot: ?*RoutingReplicaStats = null;
        var lru_slot: *RoutingReplicaStats = &self.routing_replicas[0];
        var lru_time: i64 = std.math.maxInt(i64);

        for (&self.routing_replicas) |*slot| {
            const last_seen = slot.last_update_ms.load(.monotonic);
            if (slot.replica_id == replica_id and last_seen != 0) {
                return slot;
            }

            if (last_seen == 0 and empty_slot == null) {
                empty_slot = slot;
            }

            if (last_seen < lru_time) {
                lru_time = last_seen;
                lru_slot = slot;
            }
        }

        const slot = empty_slot orelse lru_slot;
        if (slot.replica_id != replica_id) {
            slot.replica_id = replica_id;
            slot.health.store(0, .monotonic);
            slot.replication_lag_ops.store(0, .monotonic);
        }
        return slot;
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

        // Load shedding metrics
        try archerdb_shed_requests_total.format(writer);
        try archerdb_shed_score.format(writer);
        try archerdb_shed_queue_depth.format(writer);
        try archerdb_shed_latency_p99_ms.format(writer);
        try archerdb_shed_memory_pressure_pct.format(writer);
        try archerdb_shed_threshold.format(writer);
        try archerdb_shed_retry_after_ms.format(writer);
        try writer.writeAll("\n");

        // Read replica routing metrics
        try archerdb_routing_reads_total.format(writer);
        try archerdb_routing_writes_total.format(writer);
        try archerdb_routing_to_replica_total.format(writer);
        try archerdb_routing_failover_total.format(writer);
        try archerdb_routing_round_robin_index.format(writer);
        try writer.writeAll("\n");

        // Per-replica routing metrics (bounded cardinality)
        try writer.writeAll("# HELP archerdb_routing_replica_health Replica health (1=healthy, 0=unhealthy)\n");
        try writer.writeAll("# TYPE archerdb_routing_replica_health gauge\n");
        for (&self.routing_replicas) |*slot| {
            const last_seen = slot.last_update_ms.load(.monotonic);
            if (last_seen != 0) {
                const health = slot.health.load(.monotonic);
                try writer.print(
                    "archerdb_routing_replica_health{{replica_id=\"0x{x}\"}} {d}\n",
                    .{ slot.replica_id, health },
                );
            }
        }
        try writer.writeAll("\n");

        try writer.writeAll("# HELP archerdb_routing_replication_lag_ops Replication lag per replica (ops)\n");
        try writer.writeAll("# TYPE archerdb_routing_replication_lag_ops gauge\n");
        for (&self.routing_replicas) |*slot| {
            const last_seen = slot.last_update_ms.load(.monotonic);
            if (last_seen != 0) {
                const lag_ops = slot.replication_lag_ops.load(.monotonic);
                try writer.print(
                    "archerdb_routing_replication_lag_ops{{replica_id=\"0x{x}\"}} {d}\n",
                    .{ slot.replica_id, lag_ops },
                );
            }
        }
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

// ============================================================================
// Load Shedding Metrics Tests
// ============================================================================

test "updateShedMetrics: scales score to 0-100" {
    // Reset for test isolation
    archerdb_shed_score = Gauge.init(
        "archerdb_shed_score",
        "Current composite overload score (0-100, where 100 = fully overloaded)",
        null,
    );
    archerdb_shed_threshold = Gauge.init(
        "archerdb_shed_threshold",
        "Current configured shedding threshold (0-100)",
        null,
    );
    archerdb_shed_queue_depth = Gauge.init(
        "archerdb_shed_queue_depth",
        "Current queue depth used for load shedding decision",
        null,
    );
    archerdb_shed_latency_p99_ms = Gauge.init(
        "archerdb_shed_latency_p99_ms",
        "Current P99 latency in milliseconds for load shedding",
        null,
    );
    archerdb_shed_memory_pressure_pct = Gauge.init(
        "archerdb_shed_memory_pressure_pct",
        "Current memory pressure percentage (0-100)",
        null,
    );

    updateShedMetrics(0.75, 5000, 250, 60, 0.8);

    try std.testing.expectEqual(@as(i64, 75), archerdb_shed_score.get());
    try std.testing.expectEqual(@as(i64, 80), archerdb_shed_threshold.get());
    try std.testing.expectEqual(@as(i64, 5000), archerdb_shed_queue_depth.get());
    try std.testing.expectEqual(@as(i64, 250), archerdb_shed_latency_p99_ms.get());
    try std.testing.expectEqual(@as(i64, 60), archerdb_shed_memory_pressure_pct.get());
}

test "recordShedRequest: increments counter and records histogram" {
    // Reset for test isolation
    archerdb_shed_requests_total = Counter.init(
        "archerdb_shed_requests_total",
        "Total requests shed due to overload",
        null,
    );
    archerdb_shed_retry_after_ms = ShedRetryHistogram.init(
        "archerdb_shed_retry_after_ms",
        "Distribution of Retry-After values sent to clients (milliseconds)",
        null,
        .{ 1000, 2000, 5000, 10000, 15000, 20000, 30000 },
    );

    recordShedRequest(1500);
    recordShedRequest(5000);
    recordShedRequest(25000);

    try std.testing.expectEqual(@as(u64, 3), archerdb_shed_requests_total.get());
    try std.testing.expectEqual(@as(u64, 3), archerdb_shed_retry_after_ms.getCount());
}

test "ClusterMetrics: format includes shed metrics" {
    // Reset shed metrics
    archerdb_shed_score = Gauge.init(
        "archerdb_shed_score",
        "Current composite overload score (0-100, where 100 = fully overloaded)",
        null,
    );
    archerdb_shed_requests_total = Counter.init(
        "archerdb_shed_requests_total",
        "Total requests shed due to overload",
        null,
    );

    updateShedMetrics(0.5, 1000, 100, 50, 0.8);

    var cm = ClusterMetrics.init();
    var buffer: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try cm.format(writer);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_score") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_queue_depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_latency_p99_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_memory_pressure_pct") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_threshold") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archerdb_shed_retry_after_ms") != null);
}
