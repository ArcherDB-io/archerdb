// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Coordinator for Complex Deployments - ArcherDB Query Router.
//!
//! Implements an optional coordinator/proxy for complex multi-shard deployments:
//! - Centralized topology management
//! - Fan-out queries to multiple shards
//! - Result aggregation and merging
//! - Load balancing across replicas
//! - Simple client interface (clients connect to coordinator only)
//!
//! Architecture:
//! ```
//! ┌────────┐      ┌─────────────┐      ┌─────────┐
//! │ Client │─────>│ Coordinator │─────>│ Shard 0 │
//! └────────┘      │   (Proxy)   │      └─────────┘
//!                 │             │      ┌─────────┐
//!                 │             │─────>│ Shard 1 │
//!                 │             │      └─────────┘
//!                 │             │      ┌─────────┐
//!                 │             │─────>│ Shard N │
//!                 └─────────────┘      └─────────┘
//! ```
//!
//! See specs/index-sharding/query-routing.md for full requirements.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const sharding = @import("sharding.zig");
const metrics = @import("archerdb/metrics.zig");
const geo_event = @import("geo_event.zig");
const GeoEvent = geo_event.GeoEvent;

/// Maximum number of shards supported.
pub const MAX_SHARDS: u32 = 256;

/// Maximum results per shard for fan-out queries.
pub const MAX_RESULTS_PER_SHARD: u32 = 1000;

/// Shard status.
pub const ShardStatus = enum {
    /// Shard is healthy and accepting requests.
    active,
    /// Shard is unavailable (connection failed).
    unavailable,
    /// Shard is in maintenance mode.
    maintenance,
    /// Shard is being migrated.
    migrating,
};

/// Information about a single shard.
pub const ShardInfo = struct {
    /// Shard ID (0 to num_shards - 1).
    id: u32,
    /// Primary replica address.
    primary: Address,
    /// Secondary replica addresses.
    replicas: [3]?Address,
    /// Current shard status.
    status: ShardStatus,
    /// Virtual node assignments for consistent hashing.
    bucket_mask: u64,
    /// Last health check timestamp.
    last_health_check_ns: u64,
    /// Consecutive failures count.
    failure_count: u32,
};

/// Network address.
pub const Address = struct {
    host: [64]u8,
    host_len: u8,
    port: u16,

    pub fn init(host: []const u8, port: u16) Address {
        var addr = Address{
            .host = [_]u8{0} ** 64,
            .host_len = @intCast(@min(host.len, 64)),
            .port = port,
        };
        // Use comptime-compatible copy when called at comptime
        if (@inComptime()) {
            for (0..addr.host_len) |i| {
                addr.host[i] = host[i];
            }
        } else {
            stdx.copy_disjoint(.exact, u8, addr.host[0..addr.host_len], host[0..addr.host_len]);
        }
        return addr;
    }

    pub fn getHost(self: *const Address) []const u8 {
        return self.host[0..self.host_len];
    }
};

/// Cluster topology snapshot.
pub const Topology = struct {
    /// Topology version (incremented on changes).
    version: u64,
    /// Number of active shards.
    num_shards: u32,
    /// Sharding strategy in use.
    strategy: sharding.ShardingStrategy,
    /// Shard information.
    shards: [MAX_SHARDS]ShardInfo,
    /// Last update timestamp.
    last_updated_ns: u64,

    pub fn init() Topology {
        return .{
            .version = 0,
            .num_shards = 0,
            .strategy = sharding.ShardingStrategy.default(),
            .shards = [_]ShardInfo{.{
                .id = 0,
                .primary = Address.init("", 0),
                .replicas = [_]?Address{null} ** 3,
                .status = .unavailable,
                .bucket_mask = 0,
                .last_health_check_ns = 0,
                .failure_count = 0,
            }} ** MAX_SHARDS,
            .last_updated_ns = 0,
        };
    }

    /// Get the shard responsible for an entity.
    pub fn getShardForEntity(self: *const Topology, entity_id: u128) u32 {
        const start_ns: i128 = std.time.nanoTimestamp();
        const shard_id = sharding.getShardForEntityWithStrategy(
            entity_id,
            self.num_shards,
            self.strategy,
            null,
        );
        const elapsed_ns: i128 = std.time.nanoTimestamp() - start_ns;
        const elapsed_u64: u64 = @intCast(@max(elapsed_ns, 0));

        switch (self.strategy) {
            .modulo => metrics.Registry.shard_lookup_latency_modulo.observeNs(elapsed_u64),
            .virtual_ring => metrics.Registry.shard_lookup_latency_virtual_ring
                .observeNs(elapsed_u64),
            .jump_hash => metrics.Registry.shard_lookup_latency_jump_hash.observeNs(elapsed_u64),
            .spatial => metrics.Registry.shard_lookup_latency_spatial.observeNs(elapsed_u64),
        }

        return shard_id;
    }

    /// Get all active shards.
    pub fn getActiveShards(self: *const Topology) []const ShardInfo {
        return self.shards[0..self.num_shards];
    }
};

/// Query type for fan-out determination.
pub const QueryType = enum {
    /// Single-entity lookup (routes to single shard).
    uuid_lookup,
    /// Batch UUID lookup (may route to multiple shards).
    uuid_batch,
    /// Radius query (fans out to all shards).
    radius,
    /// Polygon query (fans out to all shards).
    polygon,
    /// Latest N events (fans out to all shards).
    latest,
};

/// Fan-out policy for shard queries.
pub const FanOutPolicy = enum {
    /// Require all shards to succeed.
    all,
    /// Require a majority of shards to succeed.
    majority,
    /// Return partial results when possible.
    best_effort,
};

/// Per-shard error information for fan-out queries.
pub const FanOutShardError = struct {
    shard_id: u32,
    err: anyerror,
};

/// Fan-out query result.
pub const FanOutResult = struct {
    /// Merged results from all shards.
    events: []GeoEvent,
    /// Number of shards queried.
    shards_queried: u32,
    /// Number of shards that succeeded.
    shards_succeeded: u32,
    /// Number of shards that failed.
    shards_failed: u32,
    /// Whether the result is partial.
    partial: bool,
    /// Per-shard errors collected during fan-out.
    errors: []FanOutShardError,
    /// Total query time in nanoseconds.
    total_time_ns: u64,
};

/// Coordinator configuration.
pub const CoordinatorConfig = struct {
    /// Bind address for client connections.
    bind_address: Address = Address.init("0.0.0.0", 5000),
    /// Maximum concurrent client connections.
    max_connections: u32 = 10000,
    /// Query timeout in milliseconds.
    query_timeout_ms: u32 = 30_000,
    /// Health check interval in milliseconds.
    health_check_interval_ms: u32 = 5_000,
    /// Topology refresh interval in milliseconds.
    topology_refresh_interval_ms: u32 = 60_000,
    /// Maximum retries per shard.
    max_retries: u32 = 3,
    /// Enable read-from-replica for load balancing.
    read_from_replicas: bool = true,
};

/// Coordinator statistics.
pub const CoordinatorStats = struct {
    /// Total queries received.
    queries_total: u64 = 0,
    /// Single-shard queries.
    queries_single_shard: u64 = 0,
    /// Fan-out queries.
    queries_fan_out: u64 = 0,
    /// Query errors.
    queries_error: u64 = 0,
    /// Average query latency (nanoseconds).
    avg_latency_ns: u64 = 0,
    /// Total latency sum for averaging.
    total_latency_ns: u64 = 0,
    /// Current active connections.
    active_connections: u32 = 0,
    /// Topology updates received.
    topology_updates: u64 = 0,
    /// Shard failovers performed.
    failovers: u64 = 0,

    pub fn recordQuery(
        self: *CoordinatorStats,
        latency_ns: u64,
        is_fan_out: bool,
        success: bool,
    ) void {
        self.queries_total += 1;
        if (is_fan_out) {
            self.queries_fan_out += 1;
        } else {
            self.queries_single_shard += 1;
        }
        if (!success) {
            self.queries_error += 1;
        }
        self.total_latency_ns += latency_ns;
        if (self.queries_total > 0) {
            self.avg_latency_ns = self.total_latency_ns / self.queries_total;
        }
    }
};

/// Coordinator state.
pub const CoordinatorState = enum {
    /// Not started.
    stopped,
    /// Starting up, discovering topology.
    starting,
    /// Running and accepting requests.
    running,
    /// Shutting down gracefully.
    shutting_down,
    /// Error state.
    error_state,
};

/// The Coordinator manages query routing for complex multi-shard deployments.
pub const Coordinator = struct {
    allocator: Allocator,
    config: CoordinatorConfig,
    state: CoordinatorState,
    topology: Topology,
    stats: CoordinatorStats,

    /// Pending fan-out queries.
    pending_queries: std.AutoHashMap(u64, PendingQuery),
    /// Next query ID.
    next_query_id: u64,

    /// Load balancer state for replica selection.
    replica_round_robin: [MAX_SHARDS]u8,

    const PendingQuery = struct {
        query_type: QueryType,
        start_time_ns: u64,
        shards_pending: u32,
        shards_completed: u32,
        results: std.ArrayList(GeoEvent),
    };

    /// Initialize coordinator.
    pub fn init(allocator: Allocator, config: CoordinatorConfig) Coordinator {
        return .{
            .allocator = allocator,
            .config = config,
            .state = .stopped,
            .topology = Topology.init(),
            .stats = .{},
            .pending_queries = std.AutoHashMap(u64, PendingQuery).init(allocator),
            .next_query_id = 0,
            .replica_round_robin = [_]u8{0} ** MAX_SHARDS,
        };
    }

    /// Deinitialize coordinator.
    pub fn deinit(self: *Coordinator) void {
        var iter = self.pending_queries.valueIterator();
        while (iter.next()) |pq| {
            pq.results.deinit();
        }
        self.pending_queries.deinit();
    }

    /// Start the coordinator.
    pub fn start(self: *Coordinator) !void {
        if (self.state != .stopped) return error.InvalidState;

        self.state = .starting;

        // Discover initial topology from seed nodes.
        // In real implementation, this would connect to seed nodes.
        // For now, we just mark as running.

        self.state = .running;
    }

    /// Stop the coordinator.
    pub fn stop(self: *Coordinator) void {
        self.state = .shutting_down;
        // Drain pending queries.
        self.state = .stopped;
    }

    /// Update topology from a shard response.
    pub fn updateTopology(self: *Coordinator, new_topology: Topology) void {
        if (new_topology.version > self.topology.version) {
            self.topology = new_topology;
            self.stats.topology_updates += 1;
        }
    }

    /// Add a shard to the topology.
    pub fn addShard(self: *Coordinator, shard_id: u32, primary: Address) !void {
        if (shard_id >= MAX_SHARDS) return error.ShardIdOutOfRange;
        if (shard_id >= self.topology.num_shards) {
            self.topology.num_shards = shard_id + 1;
        }

        self.topology.shards[shard_id] = .{
            .id = shard_id,
            .primary = primary,
            .replicas = [_]?Address{null} ** 3,
            .status = .active,
            .bucket_mask = 0,
            .last_health_check_ns = @intCast(std.time.nanoTimestamp()),
            .failure_count = 0,
        };
        self.topology.version += 1;
    }

    /// Route a single-entity query to the appropriate shard.
    pub fn routeQuery(self: *Coordinator, entity_id: u128) RouteResult {
        const shard_id = self.topology.getShardForEntity(entity_id);

        if (shard_id >= self.topology.num_shards) {
            return .{ .error_code = .no_shards_available };
        }

        const shard = &self.topology.shards[shard_id];

        if (shard.status != .active) {
            return .{ .error_code = .shard_unavailable };
        }

        // Select replica for load balancing.
        const target = if (self.config.read_from_replicas)
            self.selectReplica(shard_id, shard)
        else
            shard.primary;

        return .{
            .shard_id = shard_id,
            .target = target,
            .error_code = null,
        };
    }

    /// Select a replica using round-robin for load balancing.
    fn selectReplica(
        self: *Coordinator,
        shard_id: u32,
        shard: *const ShardInfo,
    ) Address {
        const rr_idx = &self.replica_round_robin[shard_id];
        rr_idx.* = (rr_idx.* + 1) % 4;

        if (rr_idx.* == 0) {
            return shard.primary;
        }

        const replica_idx = rr_idx.* - 1;
        if (shard.replicas[replica_idx]) |replica| {
            return replica;
        }

        return shard.primary;
    }

    /// Get shards for fan-out query.
    pub fn getFanOutShards(self: *const Coordinator) []const ShardInfo {
        return self.topology.getActiveShards();
    }

    /// Determine if query requires fan-out.
    pub fn requiresFanOut(query_type: QueryType) bool {
        return switch (query_type) {
            .uuid_lookup => false,
            .uuid_batch => true, // May span multiple shards.
            .radius => true,
            .polygon => true,
            .latest => true,
        };
    }

    /// Default fan-out policy per query type.
    pub fn defaultFanOutPolicy(query_type: QueryType) FanOutPolicy {
        return switch (query_type) {
            .uuid_lookup => .all,
            .uuid_batch => .all,
            .radius => .majority,
            .polygon => .majority,
            .latest => .majority,
        };
    }

    /// Execute a fan-out query concurrently across shards.
    pub fn fanOutQuery(
        self: *Coordinator,
        query_type: QueryType,
        shard_query: *const fn (ctx: *anyopaque, shard: ShardInfo) anyerror![]GeoEvent,
        ctx: *anyopaque,
        policy_override: ?FanOutPolicy,
    ) !FanOutResult {
        var shard_buffer: [MAX_SHARDS]ShardInfo = undefined;
        var shard_count: usize = 0;
        const shards = self.topology.getActiveShards();
        for (shards) |shard| {
            if (shard.status != .active) continue;
            shard_buffer[shard_count] = shard;
            shard_count += 1;
        }

        metrics.Registry.coordinator_queries_fanout.inc();
        metrics.Registry.coordinator_fanout_shards_queried.set(
            @as(i64, @intCast(shard_count)),
        );

        if (shard_count == 0) {
            metrics.Registry.coordinator_query_errors_unavailable.inc();
            return error.NoShardsAvailable;
        }

        const policy = policy_override orelse Coordinator.defaultFanOutPolicy(query_type);
        const start_ns: i128 = std.time.nanoTimestamp();

        const FanOutShared = struct {
            mutex: std.Thread.Mutex = .{},
            results: std.ArrayList(GeoEvent),
            errors: std.ArrayList(FanOutShardError),
            shards_succeeded: u32 = 0,
            shards_failed: u32 = 0,
            append_error: ?anyerror = null,
        };

        var shared = FanOutShared{
            .results = std.ArrayList(GeoEvent).init(self.allocator),
            .errors = std.ArrayList(FanOutShardError).init(self.allocator),
        };
        errdefer shared.results.deinit();
        errdefer shared.errors.deinit();

        const cpu_count = std.Thread.getCpuCount() catch 1;
        const max_jobs = @max(@as(usize, 1), @min(shard_count, cpu_count));
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = self.allocator, .n_jobs = max_jobs });
        defer pool.deinit();

        var wait_group: std.Thread.WaitGroup = .{};

        const Runner = struct {
            fn run(
                shared_ptr: *FanOutShared,
                query_fn: *const fn (ctx: *anyopaque, shard: ShardInfo) anyerror![]GeoEvent,
                ctx_ptr: *anyopaque,
                shard_info: ShardInfo,
            ) void {
                const query_result = query_fn(ctx_ptr, shard_info);
                if (query_result) |events| {
                    shared_ptr.mutex.lock();
                    defer shared_ptr.mutex.unlock();
                    if (shared_ptr.append_error != null) return;
                    if (shared_ptr.results.appendSlice(events)) |_| {
                        shared_ptr.shards_succeeded += 1;
                    } else |err| {
                        shared_ptr.append_error = err;
                        shared_ptr.shards_failed += 1;
                    }
                } else |err| {
                    if (err == error.Timeout or err == error.ConnectionTimedOut) {
                        metrics.Registry.coordinator_query_errors_timeout.inc();
                    } else {
                        metrics.Registry.coordinator_query_errors_unavailable.inc();
                    }
                    shared_ptr.mutex.lock();
                    defer shared_ptr.mutex.unlock();
                    if (shared_ptr.append_error == null) {
                        if (shared_ptr.errors.append(.{ .shard_id = shard_info.id, .err = err })) |_| {} else |append_err| {
                            shared_ptr.append_error = append_err;
                        }
                    }
                    shared_ptr.shards_failed += 1;
                }
            }
        };

        for (shard_buffer[0..shard_count]) |shard| {
            pool.spawnWg(&wait_group, Runner.run, .{ &shared, shard_query, ctx, shard });
        }
        wait_group.wait();

        const end_ns: i128 = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(@max(end_ns - start_ns, 0));
        metrics.Registry.coordinator_query_latency.observeNs(elapsed_ns);

        if (shared.append_error) |err| {
            metrics.Registry.coordinator_query_errors_unavailable.inc();
            self.stats.recordQuery(elapsed_ns, true, false);
            return err;
        }

        const shards_queried: u32 = @intCast(shard_count);
        const shards_succeeded = shared.shards_succeeded;
        const shards_failed = shared.shards_failed;
        const partial = shards_failed > 0;
        if (partial) {
            metrics.Registry.coordinator_fanout_partial_total.inc();
        }

        const policy_ok = switch (policy) {
            .all => shards_succeeded == shards_queried,
            .majority => shards_succeeded > shards_queried / 2,
            .best_effort => true,
        };

        if (!policy_ok) {
            metrics.Registry.coordinator_query_errors_unavailable.inc();
            self.stats.recordQuery(elapsed_ns, true, false);
            return error.FanOutPolicyUnsatisfied;
        }

        self.stats.recordQuery(elapsed_ns, true, true);

        return .{
            .events = shared.results.items,
            .shards_queried = shards_queried,
            .shards_succeeded = shards_succeeded,
            .shards_failed = shards_failed,
            .partial = partial,
            .errors = shared.errors.items,
            .total_time_ns = elapsed_ns,
        };
    }

    /// Start a fan-out query.
    pub fn startFanOutQuery(self: *Coordinator, query_type: QueryType) !u64 {
        const query_id = self.next_query_id;
        self.next_query_id += 1;

        const now: u64 = @intCast(std.time.nanoTimestamp());
        const shards_queried = self.topology.num_shards;

        switch (query_type) {
            .radius => metrics.Registry.query_shards_queried_radius.observe(
                @as(f64, @floatFromInt(shards_queried)),
            ),
            .polygon => metrics.Registry.query_shards_queried_polygon.observe(
                @as(f64, @floatFromInt(shards_queried)),
            ),
            else => {},
        }
        if (Coordinator.requiresFanOut(query_type)) {
            metrics.Registry.coordinator_fanout_shards_queried.set(
                @as(i64, @intCast(shards_queried)),
            );
        }

        try self.pending_queries.put(query_id, .{
            .query_type = query_type,
            .start_time_ns = now,
            .shards_pending = shards_queried,
            .shards_completed = 0,
            .results = std.ArrayList(GeoEvent).init(self.allocator),
        });

        return query_id;
    }

    /// Record results from a shard.
    pub fn recordShardResult(
        self: *Coordinator,
        query_id: u64,
        events: []const GeoEvent,
    ) !void {
        if (self.pending_queries.getPtr(query_id)) |pq| {
            try pq.results.appendSlice(events);
            pq.shards_completed += 1;
        }
    }

    /// Check if fan-out query is complete.
    pub fn isFanOutComplete(self: *const Coordinator, query_id: u64) bool {
        if (self.pending_queries.get(query_id)) |pq| {
            return pq.shards_completed >= pq.shards_pending;
        }
        return true;
    }

    /// Finalize and get fan-out query results.
    pub fn finalizeFanOutQuery(self: *Coordinator, query_id: u64) !FanOutResult {
        const pq = self.pending_queries.get(query_id) orelse return error.QueryNotFound;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        const latency = now - pq.start_time_ns;

        self.stats.recordQuery(latency, true, true);

        _ = self.pending_queries.remove(query_id);

        return .{
            .events = pq.results.items,
            .shards_queried = pq.shards_pending,
            .shards_succeeded = pq.shards_completed,
            .shards_failed = 0,
            .partial = false,
            .errors = &[_]FanOutShardError{},
            .total_time_ns = latency,
        };
    }

    /// Get current statistics.
    pub fn getStats(self: *const Coordinator) CoordinatorStats {
        return self.stats;
    }

    /// Get current topology.
    pub fn getTopology(self: *const Coordinator) Topology {
        return self.topology;
    }

    /// Mark a shard as unhealthy.
    pub fn markShardUnhealthy(self: *Coordinator, shard_id: u32) void {
        if (shard_id < self.topology.num_shards) {
            self.topology.shards[shard_id].failure_count += 1;
            if (self.topology.shards[shard_id].failure_count >= self.config.max_retries) {
                self.topology.shards[shard_id].status = .unavailable;
                self.stats.failovers += 1;
            }
        }
    }

    /// Mark a shard as healthy.
    pub fn markShardHealthy(self: *Coordinator, shard_id: u32) void {
        if (shard_id < self.topology.num_shards) {
            self.topology.shards[shard_id].failure_count = 0;
            self.topology.shards[shard_id].status = .active;
            const ns: u64 = @intCast(std.time.nanoTimestamp());
            self.topology.shards[shard_id].last_health_check_ns = ns;
        }
    }
};

/// Result of routing a query.
pub const RouteResult = struct {
    shard_id: u32 = 0,
    target: Address = Address.init("", 0),
    error_code: ?RouteError = null,
};

/// Routing errors.
pub const RouteError = enum {
    no_shards_available,
    shard_unavailable,
    invalid_entity_id,
};

// =============================================================================
// Tests
// =============================================================================


test "Coordinator: initialization" {
    const allocator = std.testing.allocator;

    var coordinator = Coordinator.init(allocator, .{});
    defer coordinator.deinit();

    try std.testing.expectEqual(CoordinatorState.stopped, coordinator.state);
    try std.testing.expectEqual(@as(u32, 0), coordinator.topology.num_shards);
}

test "Coordinator: add shards" {
    const allocator = std.testing.allocator;

    var coordinator = Coordinator.init(allocator, .{});
    defer coordinator.deinit();

    try coordinator.addShard(0, Address.init("node-0", 5000));
    try coordinator.addShard(1, Address.init("node-1", 5000));
    try coordinator.addShard(2, Address.init("node-2", 5000));

    try std.testing.expectEqual(@as(u32, 3), coordinator.topology.num_shards);
    try std.testing.expectEqual(@as(u64, 3), coordinator.topology.version);
}

test "Coordinator: route query" {
    const allocator = std.testing.allocator;

    var coordinator = Coordinator.init(allocator, .{});
    defer coordinator.deinit();

    // Add shards.
    try coordinator.addShard(0, Address.init("node-0", 5000));
    try coordinator.addShard(1, Address.init("node-1", 5000));

    try coordinator.start();
    try std.testing.expectEqual(CoordinatorState.running, coordinator.state);

    // Route a query.
    const result = coordinator.routeQuery(0x12345678);
    try std.testing.expect(result.error_code == null);
    try std.testing.expect(result.shard_id < 2);
}

test "Coordinator: fan-out determination" {
    try std.testing.expect(!Coordinator.requiresFanOut(.uuid_lookup));
    try std.testing.expect(Coordinator.requiresFanOut(.radius));
    try std.testing.expect(Coordinator.requiresFanOut(.polygon));
    try std.testing.expect(Coordinator.requiresFanOut(.latest));
}

test "Coordinator: shard health tracking" {
    const allocator = std.testing.allocator;

    var coordinator = Coordinator.init(allocator, .{ .max_retries = 3 });
    defer coordinator.deinit();

    try coordinator.addShard(0, Address.init("node-0", 5000));

    // Initial state is healthy.
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[0].status);

    // Mark unhealthy multiple times.
    coordinator.markShardUnhealthy(0);
    coordinator.markShardUnhealthy(0);
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[0].status);

    // Third failure triggers unavailable.
    coordinator.markShardUnhealthy(0);
    try std.testing.expectEqual(ShardStatus.unavailable, coordinator.topology.shards[0].status);
    try std.testing.expectEqual(@as(u64, 1), coordinator.stats.failovers);

    // Mark healthy again.
    coordinator.markShardHealthy(0);
    try std.testing.expectEqual(ShardStatus.active, coordinator.topology.shards[0].status);
    try std.testing.expectEqual(@as(u32, 0), coordinator.topology.shards[0].failure_count);
}

test "CoordinatorStats: recording" {
    var stats = CoordinatorStats{};

    stats.recordQuery(1000, false, true);
    try std.testing.expectEqual(@as(u64, 1), stats.queries_total);
    try std.testing.expectEqual(@as(u64, 1), stats.queries_single_shard);

    stats.recordQuery(2000, true, true);
    try std.testing.expectEqual(@as(u64, 2), stats.queries_total);
    try std.testing.expectEqual(@as(u64, 1), stats.queries_fan_out);

    stats.recordQuery(3000, false, false);
    try std.testing.expectEqual(@as(u64, 1), stats.queries_error);
}

test "Address: initialization" {
    const addr = Address.init("localhost", 5000);
    try std.testing.expectEqualStrings("localhost", addr.getHost());
    try std.testing.expectEqual(@as(u16, 5000), addr.port);
}

test "Topology: shard routing" {
    var topology = Topology.init();
    topology.num_shards = 4;

    // Different entity IDs should route to different shards.
    const shard_1 = topology.getShardForEntity(0x1111);
    const shard_2 = topology.getShardForEntity(0x2222);
    const shard_3 = topology.getShardForEntity(0x3333);

    // All should be valid shard IDs.
    try std.testing.expect(shard_1 < 4);
    try std.testing.expect(shard_2 < 4);
    try std.testing.expect(shard_3 < 4);

    // Same entity should always route to same shard.
    try std.testing.expectEqual(shard_1, topology.getShardForEntity(0x1111));
}

test "benchmark: routing overhead is less than 1ms" {
    // This test verifies that the routing decision overhead is minimal.
    // Spec requirement: "Performance overhead <1ms"
    // The coordinator's routing decision should add negligible latency.

    var topology = Topology.init();
    topology.num_shards = 16;

    // Initialize shards as active
    for (0..16) |i| {
        topology.shards[i].id = @intCast(i);
        topology.shards[i].status = .active;
    }

    const iterations: usize = 10000;
    var total_ns: u64 = 0;

    for (0..iterations) |i| {
        const entity_id: u128 = @intCast(i * 12345 + 67890);
        const start = std.time.nanoTimestamp();
        _ = topology.getShardForEntity(entity_id);
        const end = std.time.nanoTimestamp();
        total_ns += @intCast(@as(i128, end - start));
    }

    const avg_ns = total_ns / iterations;
    const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;

    std.log.info("Routing overhead: avg {} ns ({d:.3} us) per operation", .{ avg_ns, avg_us });

    // Verify overhead is less than 1ms (1,000,000 ns).
    // In practice, routing should be < 1us, so 1ms is a very generous threshold.
    try std.testing.expect(avg_ns < 1_000_000);

    // For debug builds, also verify it's reasonable (< 100us)
    try std.testing.expect(avg_ns < 100_000);
}

test "benchmark: fan-out shard selection overhead" {
    // Tests the overhead of determining which shards to query for fan-out.

    var topology = Topology.init();
    topology.num_shards = 64;

    // Initialize all shards as active
    for (0..64) |i| {
        topology.shards[i].id = @intCast(i);
        topology.shards[i].status = .active;
    }

    const iterations: usize = 1000;
    var total_ns: u64 = 0;

    var final_count: u32 = 0;
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        // Fan-out requires checking all active shards
        var active_count: u32 = 0;
        for (0..topology.num_shards) |i| {
            if (topology.shards[i].status == .active) {
                active_count += 1;
            }
        }
        const end = std.time.nanoTimestamp();
        total_ns += @intCast(@as(i128, end - start));
        final_count = active_count;
    }
    // Use final_count to prevent optimization
    try std.testing.expect(final_count > 0);

    const avg_ns = total_ns / iterations;
    std.log.info("Fan-out shard selection: avg {} ns per operation", .{avg_ns});

    // Fan-out selection should also be < 1ms
    try std.testing.expect(avg_ns < 1_000_000);
}
