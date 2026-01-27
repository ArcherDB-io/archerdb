// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Read replica routing for automatic read scaling.
//!
//! Routes read-only queries to healthy replicas and writes to the leader.
//! Replica selection uses round-robin with health filtering and fails over
//! to the leader when no healthy replicas are available.

const std = @import("std");

const cluster_metrics = @import("archerdb/cluster_metrics.zig");
const metrics = @import("archerdb/metrics.zig");

const ClusterMetrics = cluster_metrics.ClusterMetrics;

pub const RouteTarget = enum {
    leader,
    replica,
};

pub const RouteReason = enum {
    write_operation,
    read_to_replica,
    read_failover_leader,
    explicit_leader,
};

pub const RouteDecision = struct {
    target: RouteTarget,
    replica_id: ?u128,
    reason: RouteReason,
};

pub const QueryType = struct {
    has_mutation: bool,
    has_transaction: bool,

    pub fn isReadOnly(self: *const @This()) bool {
        return !self.has_mutation and !self.has_transaction;
    }
};

pub const ReplicaHealth = struct {
    const Self = @This();

    id: u128,
    is_healthy: std.atomic.Value(u8),
    last_heartbeat: std.atomic.Value(i64),
    replication_lag_ops: std.atomic.Value(u64),

    pub fn init(id: u128, healthy: bool, last_heartbeat_ms: i64, lag_ops: u64) Self {
        return .{
            .id = id,
            .is_healthy = std.atomic.Value(u8).init(if (healthy) 1 else 0),
            .last_heartbeat = std.atomic.Value(i64).init(last_heartbeat_ms),
            .replication_lag_ops = std.atomic.Value(u64).init(lag_ops),
        };
    }

    pub fn setHealthy(self: *Self, healthy: bool, now_ms: i64) void {
        self.is_healthy.store(if (healthy) 1 else 0, .monotonic);
        if (healthy) {
            self.last_heartbeat.store(now_ms, .monotonic);
        }
    }

    pub fn isHealthy(self: *const Self, now_ms: i64, interval_ms: u64) bool {
        if (self.is_healthy.load(.monotonic) == 0) return false;
        const last_ms = self.last_heartbeat.load(.monotonic);
        if (last_ms <= 0) return false;
        const elapsed_ms: u64 = if (now_ms > last_ms)
            @intCast(now_ms - last_ms)
        else
            0;
        return elapsed_ms <= interval_ms;
    }

    pub fn setReplicationLag(self: *Self, lag_ops: u64) void {
        self.replication_lag_ops.store(lag_ops, .monotonic);
    }

    pub fn getReplicationLag(self: *const Self) u64 {
        return self.replication_lag_ops.load(.monotonic);
    }
};

pub const ReadReplicaRouter = struct {
    const Self = @This();

    leader_id: u128,
    replicas: []ReplicaHealth,
    round_robin_index: std.atomic.Value(usize),
    metrics: *ClusterMetrics,
    health_check_interval_ms: u64,

    pub fn init(
        leader_id: u128,
        replicas: []ReplicaHealth,
        metrics_registry: *ClusterMetrics,
        health_check_interval_ms: u64,
    ) Self {
        return .{
            .leader_id = leader_id,
            .replicas = replicas,
            .round_robin_index = std.atomic.Value(usize).init(0),
            .metrics = metrics_registry,
            .health_check_interval_ms = health_check_interval_ms,
        };
    }

    pub fn route(self: *Self, query_type: QueryType) RouteDecision {
        if (!query_type.isReadOnly()) {
            self.metrics.recordRoutingWrite();
            return .{ .target = .leader, .replica_id = null, .reason = .write_operation };
        }

        self.metrics.recordRoutingRead();

        if (self.selectHealthyReplica()) |replica_id| {
            self.metrics.recordRoutingToReplica();
            return .{ .target = .replica, .replica_id = replica_id, .reason = .read_to_replica };
        }

        self.metrics.recordRoutingFailover();
        return .{ .target = .leader, .replica_id = null, .reason = .read_failover_leader };
    }

    fn selectHealthyReplica(self: *Self) ?u128 {
        const total = self.replicas.len;
        if (total == 0) return null;

        const start = self.round_robin_index.fetchAdd(1, .monotonic) % total;
        const now_ms = std.time.milliTimestamp();

        var checked: usize = 0;
        while (checked < total) : (checked += 1) {
            const idx = (start + checked) % total;
            if (self.replicas[idx].isHealthy(now_ms, self.health_check_interval_ms)) {
                const next_index = (idx + 1) % total;
                self.round_robin_index.store(next_index, .monotonic);
                self.metrics.recordRoutingRoundRobinIndex(next_index);
                return self.replicas[idx].id;
            }
        }

        return null;
    }

    pub fn updateReplicaHealth(self: *Self, replica_id: u128, healthy: bool) void {
        const now_ms = std.time.milliTimestamp();
        if (self.findReplica(replica_id)) |replica| {
            replica.setHealthy(healthy, now_ms);
        }
        self.metrics.updateRoutingReplicaHealth(replica_id, healthy);
    }

    pub fn updateReplicationLag(self: *Self, replica_id: u128, lag_ops: u64) void {
        if (self.findReplica(replica_id)) |replica| {
            replica.setReplicationLag(lag_ops);
        }
        self.metrics.updateRoutingReplicationLag(replica_id, lag_ops);
    }

    fn findReplica(self: *Self, replica_id: u128) ?*ReplicaHealth {
        for (self.replicas) |*replica| {
            if (replica.id == replica_id) return replica;
        }
        return null;
    }
};

// ==========================================================================
// Unit Tests
// ==========================================================================

const testing = std.testing;

fn makeRouter(
    leader_id: u128,
    replicas: []ReplicaHealth,
    metrics_registry: *ClusterMetrics,
) ReadReplicaRouter {
    return ReadReplicaRouter.init(leader_id, replicas, metrics_registry, 10_000);
}

test "read_replica_router: write operation routes to leader" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(1, true, std.time.milliTimestamp(), 0),
    };
    var router = makeRouter(10, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = true, .has_transaction = false });

    try testing.expectEqual(RouteTarget.leader, decision.target);
    try testing.expectEqual(RouteReason.write_operation, decision.reason);
    try testing.expect(decision.replica_id == null);
}

test "read_replica_router: read operation routes to healthy replica" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(42, true, std.time.milliTimestamp(), 0),
    };
    var router = makeRouter(7, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = false, .has_transaction = false });

    try testing.expectEqual(RouteTarget.replica, decision.target);
    try testing.expectEqual(RouteReason.read_to_replica, decision.reason);
    try testing.expectEqual(@as(u128, 42), decision.replica_id.?);
}

test "read_replica_router: read fails over to leader when replicas unhealthy" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(1, false, 0, 0),
        ReplicaHealth.init(2, false, 0, 0),
    };
    var router = makeRouter(9, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = false, .has_transaction = false });

    try testing.expectEqual(RouteTarget.leader, decision.target);
    try testing.expectEqual(RouteReason.read_failover_leader, decision.reason);
}

test "read_replica_router: round-robin distributes across replicas" {
    var metrics_state = ClusterMetrics.init();
    const now_ms = std.time.milliTimestamp();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(11, true, now_ms, 0),
        ReplicaHealth.init(22, true, now_ms, 0),
    };
    var router = makeRouter(5, replicas[0..], &metrics_state);

    const first = router.route(.{ .has_mutation = false, .has_transaction = false });
    const second = router.route(.{ .has_mutation = false, .has_transaction = false });

    try testing.expectEqual(@as(u128, 11), first.replica_id.?);
    try testing.expectEqual(@as(u128, 22), second.replica_id.?);
}

test "read_replica_router: unhealthy replicas are skipped" {
    var metrics_state = ClusterMetrics.init();
    const now_ms = std.time.milliTimestamp();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(11, false, now_ms, 0),
        ReplicaHealth.init(22, true, now_ms, 0),
    };
    var router = makeRouter(5, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = false, .has_transaction = false });
    try testing.expectEqual(@as(u128, 22), decision.replica_id.?);
}

test "read_replica_router: updateReplicaHealth updates state" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(55, false, 0, 0),
    };
    var router = makeRouter(1, replicas[0..], &metrics_state);

    router.updateReplicaHealth(55, true);
    const now_ms = std.time.milliTimestamp();

    try testing.expect(router.replicas[0].isHealthy(now_ms, router.health_check_interval_ms));
}

test "read_replica_router: updateReplicationLag updates lag" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(77, true, std.time.milliTimestamp(), 0),
    };
    var router = makeRouter(1, replicas[0..], &metrics_state);

    router.updateReplicationLag(77, 1234);

    try testing.expectEqual(@as(u64, 1234), router.replicas[0].getReplicationLag());
}

test "read_replica_router: query type classification" {
    const read_only = QueryType{ .has_mutation = false, .has_transaction = false };
    const mutating = QueryType{ .has_mutation = true, .has_transaction = false };
    const transactional = QueryType{ .has_mutation = false, .has_transaction = true };

    try testing.expect(read_only.isReadOnly());
    try testing.expect(!mutating.isReadOnly());
    try testing.expect(!transactional.isReadOnly());
}

test "read_replica_router: transaction operations route to leader" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(1, true, std.time.milliTimestamp(), 0),
    };
    var router = makeRouter(99, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = false, .has_transaction = true });

    try testing.expectEqual(RouteTarget.leader, decision.target);
    try testing.expectEqual(RouteReason.write_operation, decision.reason);
}

test "read_replica_router: empty replica list routes to leader" {
    var metrics_state = ClusterMetrics.init();
    var replicas: [0]ReplicaHealth = .{};
    var router = makeRouter(88, replicas[0..], &metrics_state);

    const decision = router.route(.{ .has_mutation = false, .has_transaction = false });

    try testing.expectEqual(RouteTarget.leader, decision.target);
    try testing.expectEqual(RouteReason.read_failover_leader, decision.reason);
}

test "read_replica_router: concurrent routing balances replicas" {
    var metrics_state = ClusterMetrics.init();
    const now_ms = std.time.milliTimestamp();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(1, true, now_ms, 0),
        ReplicaHealth.init(2, true, now_ms, 0),
    };
    var router = makeRouter(10, replicas[0..], &metrics_state);

    var counts = [_]std.atomic.Value(u64){
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    };

    const ThreadContext = struct {
        router: *ReadReplicaRouter,
        counts: *[2]std.atomic.Value(u64),
        fn run(ctx: *@This()) void {
            for (0..500) |_| {
                const decision = ctx.router.route(.{ .has_mutation = false, .has_transaction = false });
                if (decision.replica_id) |id| {
                    if (id == 1) {
                        _ = ctx.counts[0].fetchAdd(1, .monotonic);
                    } else if (id == 2) {
                        _ = ctx.counts[1].fetchAdd(1, .monotonic);
                    }
                }
            }
        }
    };

    var contexts = [_]ThreadContext{
        .{ .router = &router, .counts = &counts },
        .{ .router = &router, .counts = &counts },
        .{ .router = &router, .counts = &counts },
        .{ .router = &router, .counts = &counts },
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[idx]});
    }
    for (threads) |thread| {
        thread.join();
    }

    const count_a = counts[0].load(.monotonic);
    const count_b = counts[1].load(.monotonic);
    const diff = if (count_a > count_b) count_a - count_b else count_b - count_a;

    try testing.expect(count_a > 0);
    try testing.expect(count_b > 0);
    // Allow up to 5% variance (100 out of 2000 total requests) for concurrent test timing
    try testing.expect(diff <= 100);
}

test "read_replica_router: concurrent health updates are safe" {
    var metrics_state = ClusterMetrics.init();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(9, false, 0, 0),
    };
    var router = makeRouter(10, replicas[0..], &metrics_state);

    const ThreadContext = struct {
        router: *ReadReplicaRouter,
        lag_value: u64,
        fn run(ctx: *@This()) void {
            ctx.router.updateReplicaHealth(9, true);
            ctx.router.updateReplicationLag(9, ctx.lag_value);
        }
    };

    var contexts = [_]ThreadContext{
        .{ .router = &router, .lag_value = 10 },
        .{ .router = &router, .lag_value = 20 },
        .{ .router = &router, .lag_value = 30 },
        .{ .router = &router, .lag_value = 40 },
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[idx]});
    }
    for (threads) |thread| {
        thread.join();
    }

    const lag = router.replicas[0].getReplicationLag();
    try testing.expect(lag == 10 or lag == 20 or lag == 30 or lag == 40);
    try testing.expect(router.replicas[0].is_healthy.load(.monotonic) <= 1);
}

test "read_replica_router: routing metrics record decisions" {
    cluster_metrics.archerdb_routing_reads_total = metrics.Counter.init(
        "archerdb_routing_reads_total",
        "Total read queries routed through read replica router",
        null,
    );
    cluster_metrics.archerdb_routing_writes_total = metrics.Counter.init(
        "archerdb_routing_writes_total",
        "Total write queries routed to leader",
        null,
    );
    cluster_metrics.archerdb_routing_to_replica_total = metrics.Counter.init(
        "archerdb_routing_to_replica_total",
        "Read queries routed to healthy replicas",
        null,
    );
    cluster_metrics.archerdb_routing_failover_total = metrics.Counter.init(
        "archerdb_routing_failover_total",
        "Read queries failed over to leader due to unhealthy replicas",
        null,
    );
    cluster_metrics.archerdb_routing_round_robin_index = metrics.Gauge.init(
        "archerdb_routing_round_robin_index",
        "Current round-robin index for replica selection",
        null,
    );

    var metrics_state = ClusterMetrics.init();
    const now_ms = std.time.milliTimestamp();
    var replicas = [_]ReplicaHealth{
        ReplicaHealth.init(1, true, now_ms, 0),
        ReplicaHealth.init(2, false, now_ms, 0),
    };
    var router = makeRouter(10, replicas[0..], &metrics_state);

    _ = router.route(.{ .has_mutation = true, .has_transaction = false });
    _ = router.route(.{ .has_mutation = false, .has_transaction = false });
    router.updateReplicaHealth(2, false);

    try testing.expectEqual(@as(u64, 1), cluster_metrics.archerdb_routing_writes_total.get());
    try testing.expectEqual(@as(u64, 1), cluster_metrics.archerdb_routing_reads_total.get());
    try testing.expectEqual(@as(u64, 1), cluster_metrics.archerdb_routing_to_replica_total.get());
    try testing.expectEqual(@as(i64, 1), cluster_metrics.archerdb_routing_round_robin_index.get());
}
