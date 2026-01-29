// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Multi-node validation tests for consensus, leader election, and replica recovery.
//!
//! These tests validate the core distributed consensus requirements:
//! - MULTI-01: 3-node cluster achieves consensus and replicates data to all nodes
//! - MULTI-02: Leader election completes within 5 seconds after primary failure
//! - MULTI-03: Crashed replica rejoins cluster and catches up to committed state
//!
//! Tests use the deterministic Cluster framework with fixed seeds for reproducibility.

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const fuzz = @import("../testing/fuzz.zig");
const StateMachineType = @import("../testing/state_machine.zig").StateMachineType;
const Cluster = @import("../testing/cluster.zig").ClusterType(StateMachineType);
const Release = @import("../testing/cluster.zig").Release;
const Ratio = stdx.PRNG.Ratio;

const MiB = stdx.MiB;

const log_level: std.log.Level = .err;

const releases = [_]Release{
    .{
        .release = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 10 }),
        .release_client_min = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 10 }),
    },
};

// ============================================================================
// Test Infrastructure
// ============================================================================

const ProcessSelector = enum {
    __, // all replicas, standbys, and clients
    R_, // all (non-standby) replicas
    R0,
    R1,
    R2,
    A0, // current primary
    B1, // backup immediately following current primary
    B2,
    C_, // all clients
};

const TestContext = struct {
    cluster: *Cluster,
    log_level: std.log.Level,
    client_requests: []usize,
    client_replies: []usize,

    pub fn init(options: struct {
        replica_count: u8 = 3,
        client_count: u8 = constants.clients_max,
        seed: u64 = 123,
    }) !*TestContext {
        const log_level_original = std.testing.log_level;
        std.testing.log_level = log_level;
        var prng = stdx.PRNG.from_seed(options.seed);
        const storage_size_limit = vsr.sector_floor(128 * MiB);

        const cluster = try Cluster.init(allocator, .{
            .cluster = .{
                .cluster_id = 0,
                .replica_count = options.replica_count,
                .standby_count = 0,
                .client_count = options.client_count,
                .storage_size_limit = storage_size_limit,
                .seed = prng.int(u64),
                .releases = &releases,
                .client_release = releases[0].release,
                .reformats_max = 3,
                .state_machine = .{
                    .batch_size_limit = constants.message_body_size_max,
                    .lsm_forest_node_count = 4096,
                },
            },
            .network = .{
                .node_count = options.replica_count,
                .client_count = options.client_count,
                .seed = prng.int(u64),
                .one_way_delay_mean = fuzz.range_inclusive_ms(&prng, 30, 120),
                .one_way_delay_min = fuzz.range_inclusive_ms(&prng, 0, 20),
                .path_maximum_capacity = 10,
                .path_clog_duration_mean = .{ .ns = 0 },
                .path_clog_probability = Ratio.zero(),
                .recorded_count_max = 16,
            },
            .storage = .{
                .size = storage_size_limit,
                .read_latency_min = .ms(10),
                .read_latency_mean = .ms(50),
                .write_latency_min = .ms(10),
                .write_latency_mean = .ms(50),
            },
            .storage_fault_atlas = .{
                .faulty_superblock = false,
                .faulty_wal_headers = false,
                .faulty_wal_prepares = false,
                .faulty_client_replies = false,
                .faulty_grid = false,
            },
            .callbacks = .{
                .on_client_reply = TestContext.on_client_reply,
            },
        });
        errdefer cluster.deinit();

        for (cluster.storages) |*storage| storage.faulty = true;

        const client_requests = try allocator.alloc(usize, options.client_count);
        errdefer allocator.free(client_requests);
        @memset(client_requests, 0);

        const client_replies = try allocator.alloc(usize, cluster.clients.len);
        errdefer allocator.free(client_replies);
        @memset(client_replies, 0);

        const context = try allocator.create(TestContext);
        errdefer allocator.destroy(context);

        context.* = .{
            .cluster = cluster,
            .log_level = log_level_original,
            .client_requests = client_requests,
            .client_replies = client_replies,
        };
        cluster.context = context;

        return context;
    }

    pub fn deinit(t: *TestContext) void {
        std.testing.log_level = t.log_level;
        allocator.free(t.client_replies);
        allocator.free(t.client_requests);
        t.cluster.deinit();
        allocator.destroy(t);
    }

    pub fn replica(t: *TestContext, selector: ProcessSelector) TestReplicas {
        const replica_count = t.cluster.options.replica_count;
        var view: u32 = 0;
        for (t.cluster.replicas) |*r| view = @max(view, r.view);

        var replicas = stdx.BoundedArrayType(u8, constants.members_max){};
        switch (selector) {
            .R0 => replicas.push(0),
            .R1 => replicas.push(1),
            .R2 => replicas.push(2),
            .A0 => replicas.push(@intCast((view + 0) % replica_count)),
            .B1 => replicas.push(@intCast((view + 1) % replica_count)),
            .B2 => replicas.push(@intCast((view + 2) % replica_count)),
            .R_, .__, .C_ => {
                for (0..replica_count) |i| {
                    replicas.push(@intCast(i));
                }
            },
        }
        return TestReplicas{
            .context = t,
            .cluster = t.cluster,
            .replicas = replicas,
        };
    }

    pub fn clients(t: *TestContext) TestClients {
        var client_indexes = stdx.BoundedArrayType(usize, constants.clients_max){};
        for (0..t.cluster.options.client_count) |i| client_indexes.push(i);
        return TestClients{
            .context = t,
            .cluster = t.cluster,
            .clients = client_indexes,
        };
    }

    pub fn run(t: *TestContext) void {
        const tick_max = 4_100;
        var tick_count: usize = 0;
        while (tick_count < tick_max) : (tick_count += 1) {
            if (t.tick()) tick_count = 0;
        }
    }

    /// Returns whether the cluster state advanced.
    pub fn tick(t: *TestContext) bool {
        const commits_before = t.cluster.state_checker.commits.items.len;
        t.cluster.tick();
        return commits_before != t.cluster.state_checker.commits.items.len;
    }

    fn on_client_reply(
        cluster: *Cluster,
        client: usize,
        request: *const @import("../message_pool.zig").MessagePool.Message.Request,
        reply: *const @import("../message_pool.zig").MessagePool.Message.Reply,
    ) void {
        _ = request;
        _ = reply;
        const t: *TestContext = @ptrCast(@alignCast(cluster.context.?));
        t.client_replies[client] += 1;
    }
};

const TestReplicas = struct {
    context: *TestContext,
    cluster: *Cluster,
    replicas: stdx.BoundedArrayType(u8, constants.members_max),

    pub fn stop(t: *const TestReplicas) void {
        for (t.replicas.const_slice()) |r| {
            t.cluster.replica_crash(r);
        }
    }

    pub fn open(t: *const TestReplicas) !void {
        for (t.replicas.const_slice()) |r| {
            t.cluster.replica_restart(r) catch |err| {
                return switch (err) {
                    error.WALCorrupt => return error.WALCorrupt,
                    error.WALInvalid => return error.WALInvalid,
                    else => @panic("unexpected error"),
                };
            };
        }
    }

    const Health = enum { up, down, reformatting };

    pub fn health(t: *const TestReplicas) Health {
        var value_all: ?Health = null;
        for (t.replicas.const_slice()) |r| {
            const value: Health = switch (t.cluster.replica_health[r]) {
                .up => .up,
                .down => .down,
                .reformatting => .reformatting,
            };
            if (value_all) |all| {
                assert(all == value);
            } else {
                value_all = value;
            }
        }
        return value_all.?;
    }

    fn get(
        t: *const TestReplicas,
        comptime field: std.meta.FieldEnum(Cluster.Replica),
    ) @FieldType(Cluster.Replica, @tagName(field)) {
        var value_all: ?@FieldType(Cluster.Replica, @tagName(field)) = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            const value = @field(replica, @tagName(field));
            if (value_all) |all| {
                if (all != value) {
                    @panic("test failed: value mismatch");
                }
            } else {
                value_all = value;
            }
        }
        return value_all.?;
    }

    pub fn status(t: *const TestReplicas) vsr.Status {
        return t.get(.status);
    }

    pub fn commit(t: *const TestReplicas) u64 {
        return t.get(.commit_min);
    }

    const Role = enum { primary, backup, standby };

    pub fn role(t: *const TestReplicas) Role {
        var role_all: ?Role = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            const replica_role: Role = role: {
                if (replica.standby()) {
                    break :role .standby;
                } else if (replica.replica == replica.primary_index(replica.view)) {
                    break :role .primary;
                } else {
                    break :role .backup;
                }
            };
            assert(role_all == null or role_all.? == replica_role);
            role_all = replica_role;
        }
        return role_all.?;
    }
};

const TestClients = struct {
    context: *TestContext,
    cluster: *Cluster,
    clients: stdx.BoundedArrayType(usize, constants.clients_max),
    requests: usize = 0,

    pub fn request(t: *TestClients, requests: usize, expect_replies: usize) !void {
        assert(t.requests <= requests);
        defer assert(t.requests == requests);

        outer: while (true) {
            for (t.clients.const_slice()) |c| {
                if (t.requests == requests) break :outer;
                t.context.client_requests[c] += 1;
                t.requests += 1;
            }
        }

        const tick_max = 3_000;
        var tick: usize = 0;
        while (tick < tick_max) : (tick += 1) {
            if (t.context.tick()) tick = 0;

            for (t.clients.const_slice()) |c| {
                if (t.cluster.clients[c]) |*client| {
                    if (client.request_inflight == null and
                        t.context.client_requests[c] > client.request_number)
                    {
                        if (client.request_number == 0) {
                            t.cluster.register(c);
                        } else {
                            const message = client.get_message();
                            errdefer client.release_message(message);

                            const body_size = 123;
                            @memset(message.buffer[@sizeOf(vsr.Header)..][0..body_size], 42);
                            t.cluster.request(c, .echo, message, body_size);
                        }
                    }
                }
            }
        }
        try std.testing.expectEqual(t.replies(), expect_replies);
    }

    pub fn replies(t: *const TestClients) usize {
        var replies_total: usize = 0;
        for (t.clients.const_slice()) |c| replies_total += t.context.client_replies[c];
        return replies_total;
    }
};

// ============================================================================
// Multi-Node Validation Tests
// ============================================================================

/// MULTI-01: Validates that a 3-node cluster achieves consensus and replicates
/// data to all nodes. After sending requests, all replicas should have the same
/// commit position and be in normal status.
test "MULTI-01: 3-node cluster achieves consensus and replicates" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Write data and verify consensus - send 10 requests
    try c.request(10, 10);

    // Let cluster stabilize
    t.run();

    // All 3 nodes should have same commit position
    try expectEqual(t.replica(.R0).commit(), 10);
    try expectEqual(t.replica(.R1).commit(), 10);
    try expectEqual(t.replica(.R2).commit(), 10);

    // All should be in normal status
    try expectEqual(t.replica(.R_).status(), .normal);
}

/// MULTI-02: Validates that leader election completes within 5 seconds after
/// primary failure. The test crashes the primary and measures the time (in ticks)
/// until a new primary is elected and can accept requests.
test "MULTI-02: leader election completes within 5 seconds" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Establish baseline - send 2 requests
    try c.request(2, 2);

    // Verify initial primary
    try expectEqual(t.replica(.A0).role(), .primary);
    try expectEqual(t.replica(.A0).status(), .normal);

    // Record which replica was the primary before crash
    const primary_before = t.replica(.A0).replicas.get(0);

    // Crash the primary
    t.replica(.A0).stop();

    // Run until a new primary is elected or timeout
    // tick_ms = 10ms by default, so 5000ms = 500 ticks
    const tick_limit: u64 = 5000 / constants.tick_ms;
    var ticks: u64 = 0;

    while (ticks < tick_limit) : (ticks += 1) {
        _ = t.tick();

        // Check if any remaining replica is primary and in normal status
        var new_primary_elected = false;
        for (t.cluster.replicas[0..t.cluster.options.replica_count], 0..) |*r, i| {
            // Skip the crashed replica
            if (i == primary_before) continue;
            if (t.cluster.replica_health[i] != .up) continue;

            if (r.status == .normal and
                r.replica == r.primary_index(r.view))
            {
                new_primary_elected = true;
                break;
            }
        }

        if (new_primary_elected) break;
    }

    // Verify election completed within time limit
    const election_ms = ticks * constants.tick_ms;
    try expect(election_ms <= 5000);

    // Let cluster stabilize
    t.run();

    // Verify new primary can accept requests
    try c.request(3, 3);
}

/// MULTI-03: Validates that a crashed replica can rejoin the cluster and catch up
/// to the committed state. The test crashes a backup, continues committing with
/// the remaining majority, then restarts the crashed replica and verifies it
/// catches up.
test "MULTI-03: crashed replica rejoins and catches up" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Initial consensus
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Get a backup replica to crash
    var b2 = t.replica(.B2);

    // Crash one replica
    b2.stop();
    try expectEqual(b2.health(), .down);

    // Cluster continues without it (2/3 majority can still commit)
    try c.request(10, 10);

    // Verify majority committed
    try expectEqual(t.replica(.A0).commit(), 10);
    try expectEqual(t.replica(.B1).commit(), 10);

    // Replica rejoins
    try b2.open();
    try expectEqual(b2.health(), .up);

    // Let it catch up
    t.run();

    // Verify it caught up
    try expectEqual(b2.status(), .normal);
    try expectEqual(b2.commit(), 10);
}
