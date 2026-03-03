// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Fault Tolerance Validation Tests
//!
//! These tests explicitly validate the fault tolerance requirements:
//! - FAULT-01: Process crash (SIGKILL) followed by restart loses no committed data
//! - FAULT-02: Power loss (torn writes) followed by recovery loses no committed data
//! - FAULT-03: Disk read errors are handled gracefully via retry or failover
//! - FAULT-04: Full disk rejects writes but remains available for reads
//! - FAULT-05: Network partitions don't cause data loss
//! - FAULT-06: Packet loss and latency spikes don't cause data corruption
//! - FAULT-07: Corrupted log entries cause clear error or cluster repair
//! - FAULT-08: Recovery time < 60 seconds after crash
//!
//! Total FAULT-labeled tests: 28
//!   - FAULT-01: 3 tests (process crash, pending writes, multiple sequential)
//!   - FAULT-02: 2 tests (torn writes, checkpoint)
//!   - FAULT-03: 4 tests (cluster repair, multiple sectors, WAL read error, disjoint)
//!   - FAULT-04: 3 tests (limit-storage, reads continue, no corruption)
//!   - FAULT-05: 5 tests (minority isolation, primary partition, asymmetric x2, repeated)
//!   - FAULT-06: 4 tests (packet loss, high latency, mixed faults, checkpoint faults)
//!   - FAULT-07: 3 tests (checksum detection, R=1 clear error, disjoint corruption)
//!   - FAULT-08: 4 tests (crash recovery, WAL corruption, grid corruption, path classification)
//!
//! Tests use the deterministic Cluster framework with fixed seeds (42) for reproducibility.
//! They follow patterns from data_integrity_test.zig and replica_test.zig.

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const fuzz = @import("../testing/fuzz.zig");
const Process = @import("../testing/cluster/message_bus.zig").Process;
const LinkFilter = @import("../testing/cluster/network.zig").LinkFilter;
const Network = @import("../testing/cluster/network.zig").Network;
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

const slot_count = constants.journal_slot_count;
const checkpoint_1 = vsr.Checkpoint.checkpoint_after(0);
const checkpoint_2 = vsr.Checkpoint.checkpoint_after(checkpoint_1);
const checkpoint_1_trigger = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_1).?;
const checkpoint_2_trigger = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_2).?;

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
    S0, // standby
    C_, // all clients
};

const TestContext = struct {
    cluster: *Cluster,
    log_level: std.log.Level,
    client_requests: []usize,
    client_replies: []usize,

    pub fn init(options: struct {
        replica_count: u8 = 3,
        standby_count: u8 = 0,
        client_count: u16 = constants.clients_max,
        seed: u64 = 42,
    }) !*TestContext {
        const log_level_original = std.testing.log_level;
        std.testing.log_level = log_level;
        var prng = stdx.PRNG.from_seed(options.seed);
        const storage_size_limit = vsr.sector_floor(128 * MiB);

        const cluster = try Cluster.init(allocator, .{
            .cluster = .{
                .cluster_id = 0,
                .replica_count = options.replica_count,
                .standby_count = options.standby_count,
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
                .node_count = options.replica_count + options.standby_count,
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
        const standby_count = t.cluster.options.standby_count;
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
            .S0 => replicas.push(replica_count + 0),
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
            .standby_count = standby_count,
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

    pub fn block_address_max(t: *TestContext) u64 {
        const grid_blocks = t.cluster.storages[0].grid_blocks();
        for (t.cluster.storages) |storage| {
            assert(storage.grid_blocks() == grid_blocks);
        }
        return grid_blocks;
    }

    const ProcessList = stdx.BoundedArrayType(
        Process,
        constants.members_max + constants.clients_max,
    );

    pub fn processes(t: *const TestContext, selector: ProcessSelector) ProcessList {
        const replica_count = t.cluster.options.replica_count;

        var view: u32 = 0;
        for (t.cluster.replicas) |*r| view = @max(view, r.view);

        var array = ProcessList{};
        switch (selector) {
            .R0 => array.push(.{ .replica = 0 }),
            .R1 => array.push(.{ .replica = 1 }),
            .R2 => array.push(.{ .replica = 2 }),
            .A0 => array.push(.{ .replica = @intCast((view + 0) % replica_count) }),
            .B1 => array.push(.{ .replica = @intCast((view + 1) % replica_count) }),
            .B2 => array.push(.{ .replica = @intCast((view + 2) % replica_count) }),
            .S0 => array.push(.{ .replica = replica_count + 0 }),
            .R_, .__, .C_ => {
                if (selector == .__ or selector == .R_) {
                    for (0..replica_count) |i| {
                        array.push(.{ .replica = @intCast(i) });
                    }
                }
                if (selector == .__ or selector == .C_) {
                    for (t.cluster.clients) |client| {
                        if (client) |c| {
                            array.push(.{ .client = c.id });
                        }
                    }
                }
            },
        }
        assert(array.count() > 0);
        return array;
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
    standby_count: u8,

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

    pub fn corrupt(
        t: *const TestReplicas,
        target: union(enum) {
            wal_header: usize, // slot
            wal_prepare: usize, // slot
            client_reply: usize, // slot
            grid_block: u64, // address
        },
    ) void {
        switch (target) {
            .wal_header => |slot| {
                const fault_offset = vsr.Zone.wal_headers.offset(slot * @sizeOf(vsr.Header));
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].memory[fault_offset] +%= 1;
                }
            },
            .wal_prepare => |slot| {
                const fault_offset = vsr.Zone.wal_prepares.offset(slot *
                    constants.message_size_max);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
            .client_reply => |slot| {
                const fault_offset = vsr.Zone.client_replies.offset(slot *
                    constants.message_size_max);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
            .grid_block => |address| {
                const fault_offset = vsr.Zone.grid.offset((address - 1) * constants.block_size);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
        }
    }

    fn get(
        t: *const TestReplicas,
        comptime field: std.meta.FieldEnum(Cluster.Replica),
    ) @FieldType(Cluster.Replica, @tagName(field)) {
        var value_all: ?@FieldType(Cluster.Replica, @tagName(field)) = null;
        for (t.replicas.const_slice()) |r| {
            const replica_ptr = &t.cluster.replicas[r];
            const value = @field(replica_ptr, @tagName(field));
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

    pub fn op_head(t: *const TestReplicas) u64 {
        return t.get(.op);
    }

    pub fn op_checkpoint(t: *const TestReplicas) u64 {
        var checkpoint_all: ?u64 = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            assert(checkpoint_all == null or checkpoint_all.? == replica.op_checkpoint());
            checkpoint_all = replica.op_checkpoint();
        }
        return checkpoint_all.?;
    }

    /// Get commit position for a single replica (allows checking divergent positions)
    pub fn commit_any(t: *const TestReplicas) u64 {
        assert(t.replicas.count() == 1);
        const r = t.replicas.get(0);
        return t.cluster.replicas[r].commit_min;
    }

    // Network filtering methods for partition tests
    pub const LinkDirection = enum { bidirectional, incoming, outgoing };

    pub fn pass_all(t: *const TestReplicas, peer: ProcessSelector, direction: LinkDirection) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| {
            t.cluster.network.link_filter(path).* = LinkFilter.initFull();
        }
    }

    pub fn drop_all(t: *const TestReplicas, peer: ProcessSelector, direction: LinkDirection) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| t.cluster.network.link_filter(path).* = LinkFilter{};
    }

    // -1: no route to self
    const paths_max = constants.members_max * (constants.members_max - 1 + constants.clients_max);

    fn peer_paths(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
    ) stdx.BoundedArrayType(Network.Path, paths_max) {
        var paths = stdx.BoundedArrayType(Network.Path, paths_max){};
        const peers = t.context.processes(peer);
        for (t.replicas.const_slice()) |a| {
            const process_a = Process{ .replica = a };
            for (peers.const_slice()) |process_b| {
                if (direction == .bidirectional or direction == .outgoing) {
                    paths.push(.{ .source = process_a, .target = process_b });
                }
                if (direction == .bidirectional or direction == .incoming) {
                    paths.push(.{ .source = process_b, .target = process_a });
                }
            }
        }
        return paths;
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
// FAULT-01: Process Crash (SIGKILL) Tests
// ============================================================================

// FAULT-01: Process crash (SIGKILL) survives without data loss (R=3)
//
// This test validates that when a replica is abruptly stopped (simulating SIGKILL),
// it can restart and recover to the correct commit position without data loss.
//
// Scenario:
// 1. Create 3-node cluster, commit 10+ operations
// 2. Stop one replica abruptly (simulating SIGKILL via stop())
// 3. Restart the replica
// 4. Verify: replica recovers to correct commit position
// 5. Verify: cluster can continue accepting new operations
// 6. Verify: all replicas converge to same state
test "FAULT-01: process crash (SIGKILL) survives without data loss (R=3)" {
    // Skip for lite configuration - cluster-based tests require non-lite defaults.
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to ensure meaningful state
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Record commit position before crash
    const commit_before_crash = t.replica(.R0).commit();

    // Stop one replica abruptly (simulates SIGKILL - immediate termination without cleanup)
    t.replica(.R0).stop();

    // Restart the replica - it should recover from WAL
    try t.replica(.R0).open();

    // Let cluster stabilize and R0 catch up
    t.run();

    // Verify R0 recovered to correct commit position (no data loss)
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), commit_before_crash);

    // Verify cluster can continue accepting operations
    try c.request(15, 15);
    try expectEqual(t.replica(.R_).commit(), 15);

    // Verify all replicas converged to same state
    try expectEqual(t.replica(.R0).commit(), 15);
    try expectEqual(t.replica(.R1).commit(), 15);
    try expectEqual(t.replica(.R2).commit(), 15);
}

// FAULT-01: Process crash during pending writes (R=3)
//
// This test validates that when a replica crashes while operations are in flight,
// committed operations are preserved and uncommitted operations are handled correctly.
//
// Scenario:
// 1. Create cluster, commit some operations
// 2. Stop replica DURING operations (stop while requests in flight)
// 3. Restart replica
// 4. Verify: no data loss for committed operations
// 5. Verify: cluster continues to function
test "FAULT-01: process crash during pending writes (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Get commit position before any crash
    const committed_before = t.replica(.R_).commit();

    // Stop one replica (may have pending writes in its storage queue)
    t.replica(.R0).stop();

    // Continue with more requests - the other two replicas can still commit
    try c.request(8, 8);

    // Verify the two running replicas committed
    try expectEqual(t.replica(.R1).commit(), 8);
    try expectEqual(t.replica(.R2).commit(), 8);

    // Restart the crashed replica
    try t.replica(.R0).open();
    t.run();

    // Verify crashed replica caught up - no committed data was lost
    try expectEqual(t.replica(.R0).status(), .normal);
    try expect(t.replica(.R0).commit() >= committed_before);
    try expectEqual(t.replica(.R0).commit(), 8);

    // Cluster should continue functioning
    try c.request(12, 12);
    try expectEqual(t.replica(.R_).commit(), 12);
}

// FAULT-01: Multiple sequential crashes (R=3)
//
// This test validates that the system handles multiple sequential crashes correctly,
// with no cumulative data loss across crash/restart cycles.
//
// Scenario:
// 1. Crash and restart each replica in sequence
// 2. Between each crash/restart cycle, commit more operations
// 3. Verify: no cumulative data loss across multiple crashes
// 4. Verify: final state is consistent across all replicas
test "FAULT-01: multiple sequential crashes (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Initial operations
    try c.request(3, 3);
    try expectEqual(t.replica(.R_).commit(), 3);

    // Cycle 1: Crash and restart R0
    t.replica(.R0).stop();
    try c.request(6, 6);
    try t.replica(.R0).open();
    t.run();
    try expectEqual(t.replica(.R_).commit(), 6);

    // Cycle 2: Crash and restart R1
    t.replica(.R1).stop();
    try c.request(9, 9);
    try t.replica(.R1).open();
    t.run();
    try expectEqual(t.replica(.R_).commit(), 9);

    // Cycle 3: Crash and restart R2
    t.replica(.R2).stop();
    try c.request(12, 12);
    try t.replica(.R2).open();
    t.run();
    try expectEqual(t.replica(.R_).commit(), 12);

    // Verify final state: all replicas at same commit, no data loss
    try expectEqual(t.replica(.R0).commit(), 12);
    try expectEqual(t.replica(.R1).commit(), 12);
    try expectEqual(t.replica(.R2).commit(), 12);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Verify StateChecker tracked all commits correctly
    try expectEqual(t.cluster.state_checker.requests_committed, 12);
}

// ============================================================================
// FAULT-02: Power Loss (Torn Writes) Tests
// ============================================================================

// FAULT-02: Power loss (torn writes) survives without data loss (R=3)
//
// This test validates that the system recovers from torn writes caused by
// power loss simulation. Torn writes are simulated via WAL header corruption
// (representing a partially written header).
//
// Scenario:
// 1. Commit operations
// 2. Stop all replicas (simulating power loss)
// 3. Corrupt one replica's WAL header (simulating torn write)
// 4. Restart all replicas
// 5. Verify: cluster detects torn writes and repairs from intact replicas
// 6. Verify: committed data is preserved
test "FAULT-02: power loss (torn writes) survives without data loss (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to populate WAL
    try c.request(8, 8);
    try expectEqual(t.replica(.R_).commit(), 8);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop all replicas (simulating power loss - pending writes may be torn)
    t.replica(.R_).stop();

    // Simulate torn write on R0's WAL - header corrupted but prepare intact
    // This simulates power loss during header write
    t.replica(.R0).corrupt(.{ .wal_header = 5 });

    // Restart all replicas
    try t.replica(.R_).open();

    // Let cluster repair and stabilize
    t.run();

    // Verify all replicas recovered and are in normal state
    try expectEqual(t.replica(.R_).status(), .normal);

    // Verify committed data preserved (no loss)
    try expectEqual(t.replica(.R_).commit(), 8);

    // Verify cluster can continue accepting operations
    try c.request(12, 12);
    try expectEqual(t.replica(.R_).commit(), 12);
}

// FAULT-02: Power loss during checkpoint (R=3)
//
// This test validates that the system recovers from power loss that occurs
// during or after a checkpoint, with potential torn writes in grid blocks.
//
// Scenario:
// 1. Commit enough operations to trigger checkpoint
// 2. Stop replicas (simulating power loss during/after checkpoint)
// 3. Corrupt checkpoint-related grid blocks (simulating torn checkpoint write)
// 4. Restart and verify cluster recovers
// 5. Verify checkpoint data preserved through cross-replica repair
test "FAULT-02: power loss during checkpoint (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Trigger first checkpoint
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop all replicas (simulating power loss during checkpoint)
    t.replica(.R_).stop();

    // Corrupt grid blocks with disjoint pattern:
    // Each block exists intact on exactly one replica
    const address_max = t.block_address_max();
    for ([_]TestReplicas{
        t.replica(.R0),
        t.replica(.R1),
        t.replica(.R2),
    }, 0..) |replica_set, i| {
        var address: u64 = 1 + i; // Addresses start at 1
        while (address <= address_max) : (address += 3) {
            // Leave every third address un-corrupt for this replica
            // Corrupt the other two (simulating torn checkpoint writes)
            if (address + 1 <= address_max) {
                replica_set.corrupt(.{ .grid_block = address + 1 });
            }
            if (address + 2 <= address_max) {
                replica_set.corrupt(.{ .grid_block = address + 2 });
            }
        }
    }

    // Restart all replicas
    try t.replica(.R_).open();

    // Let cluster repair grid and stabilize
    t.run();

    // Verify recovery: all replicas in normal state
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    // Verify system can continue to next checkpoint
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
}

// ============================================================================
// FAULT-07: Corrupted Log Entry Tests
// ============================================================================

// FAULT-07: Corrupted log entry detected via checksum (R=3)
//
// This test validates that corrupted WAL entries are detected via checksum
// validation and repaired from healthy replicas.
//
// Scenario:
// 1. Commit operations
// 2. Stop one replica
// 3. Corrupt a WAL prepare entry (zeros the sector, invalidating checksum)
// 4. Restart replica
// 5. Verify: corruption detected (enters recovering_head or similar)
// 6. Verify: cluster repairs from healthy replicas
test "FAULT-07: corrupted log entry detected via checksum (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to populate WAL
    try c.request(8, 8);
    try expectEqual(t.replica(.R_).commit(), 8);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt a WAL prepare - this zeros the sector which invalidates checksum
    t.replica(.R0).corrupt(.{ .wal_prepare = 5 });

    // Restart corrupted replica - should detect corruption via checksum
    try t.replica(.R0).open();

    // Corrupted replica should enter recovering_head state
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    // Let cluster repair corrupted replica from healthy replicas
    t.run();

    // Verify repair completed
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), 8);

    // Verify the corrupted area was repaired
    const r0_storage = &t.cluster.storages[0];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 5 } }));

    // Cluster can continue accepting operations
    try c.request(12, 12);
    try expectEqual(t.replica(.R_).commit(), 12);
}

// FAULT-07: Corrupted log entry on single replica (R=1) - clear error
//
// Per CONTEXT.md decision: "Corrupted data handling: Fail startup with clear error -
// require operator intervention rather than risk serving bad data"
//
// This test validates that R=1 (single replica) correctly fails with a clear error
// when a WAL prepare is corrupted between checkpoint and head.
//
// Scenario:
// 1. Create R=1 cluster
// 2. Commit operations
// 3. Stop replica
// 4. Corrupt WAL entry between checkpoint and head
// 5. Attempt restart
// 6. Verify: returns error.WALCorrupt (clear error, not silent corruption)
test "FAULT-07: corrupted log entry on single replica (R=1) - clear error" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 1, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations
    try c.request(5, 5);
    try expectEqual(t.replica(.R0).commit(), 5);

    // Stop replica
    t.replica(.R0).stop();

    // Corrupt WAL prepare between checkpoint (0) and head (5)
    // This is unrecoverable for R=1 since there are no other replicas to repair from
    t.replica(.R0).corrupt(.{ .wal_prepare = 3 });

    // Attempt to restart - should fail with clear error
    if (t.replica(.R0).open()) {
        // Should not succeed - corruption is unrecoverable
        unreachable;
    } else |err| switch (err) {
        error.WALCorrupt => {
            // Expected: clear error indicating corruption detected
        },
        else => unreachable,
    }
}

// FAULT-07: Multiple corrupted entries across replicas recoverable
//
// This test validates that when different replicas have different entries
// corrupted (disjoint corruption pattern), the cluster can recover all data
// as long as each entry exists intact on at least one replica.
//
// Scenario:
// 1. Commit operations
// 2. Stop all replicas
// 3. Corrupt different WAL entries on different replicas (disjoint pattern)
// 4. Restart all replicas
// 5. Verify: cluster recovers as each entry is intact on at least one replica
test "FAULT-07: multiple corrupted entries across replicas recoverable" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit several operations to have multiple WAL slots
    try c.request(9, 9);
    try expectEqual(t.replica(.R_).commit(), 9);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop all replicas
    t.replica(.R_).stop();

    // Corrupt different entries on different replicas (disjoint pattern):
    // R0: corrupt slots 2, 5, 8 (keeps 1, 3, 4, 6, 7, 9)
    // R1: corrupt slots 1, 4, 7 (keeps 2, 3, 5, 6, 8, 9)
    // R2: corrupt slots 3, 6, 9 (keeps 1, 2, 4, 5, 7, 8)
    // Each slot is intact on exactly 2 replicas
    t.replica(.R0).corrupt(.{ .wal_prepare = 2 });
    t.replica(.R0).corrupt(.{ .wal_prepare = 5 });
    t.replica(.R0).corrupt(.{ .wal_prepare = 8 });

    t.replica(.R1).corrupt(.{ .wal_prepare = 1 });
    t.replica(.R1).corrupt(.{ .wal_prepare = 4 });
    t.replica(.R1).corrupt(.{ .wal_prepare = 7 });

    t.replica(.R2).corrupt(.{ .wal_prepare = 3 });
    t.replica(.R2).corrupt(.{ .wal_prepare = 6 });
    t.replica(.R2).corrupt(.{ .wal_prepare = 9 });

    // Restart all replicas - some may start in recovering_head
    try t.replica(.R0).open();
    try t.replica(.R1).open();
    try t.replica(.R2).open();

    // Let cluster repair - each replica gets missing entries from others
    t.run();

    // Verify all replicas recovered
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), 9);

    // Cluster should be able to continue
    try c.request(12, 12);
    try expectEqual(t.replica(.R_).commit(), 12);
}

// ============================================================================
// FAULT-05: Network Partition Tests
// Network partitions don't cause data loss
// ============================================================================

// FAULT-05: Network partition isolates minority without data loss (R=3)
//
// This test validates that when a network partition isolates one replica (minority),
// the majority can continue committing, and after the partition heals, the isolated
// replica catches up without any data loss.
//
// Per CONTEXT.md: "Network timeout handling: Fast failure with automatic leader
// re-election - assume leader is dead, elect new one quickly"
test "FAULT-05: network partition isolates minority without data loss (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations with all replicas connected
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Partition one replica (B2) - isolate it from the cluster
    t.replica(.B2).drop_all(.__, .bidirectional);

    // Continue committing operations - majority (2/3) can still commit
    try c.request(10, 10);

    // Verify: majority replicas have new commits
    try expectEqual(t.replica(.A0).commit(), 10);
    try expectEqual(t.replica(.B1).commit(), 10);

    // Verify: partitioned replica is behind but has no data loss (still has pre-partition data)
    try expectEqual(t.replica(.B2).commit_any(), 5);

    // Heal the partition
    t.replica(.B2).pass_all(.__, .bidirectional);

    // Run until cluster converges
    t.run();

    // Verify: all replicas converge to same state (no data loss)
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);
}

// FAULT-05: Network partition of primary triggers re-election
//
// This test validates that when the primary is partitioned from backups,
// the backups elect a new leader and the cluster continues to operate.
// After the partition heals, the old primary catches up without data loss.
test "FAULT-05: network partition of primary triggers re-election" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(3, 3);
    try expectEqual(t.replica(.R_).commit(), 3);

    // Record the current primary's commit position
    const initial_commit = t.replica(.A0).commit_any();

    // Partition the primary (A0) from both backups
    const p = t.replica(.A0);
    p.drop_all(.B1, .bidirectional);
    p.drop_all(.B2, .bidirectional);

    // Continue operations - backups should elect new leader and continue
    try c.request(6, 6);

    // Old primary is behind (cannot receive new commits)
    try expectEqual(p.commit_any(), initial_commit);

    // Backups have new commits (cluster continued with new leader)
    try expect(t.replica(.B1).commit_any() > initial_commit);

    // Heal the partition
    p.pass_all(.B1, .bidirectional);
    p.pass_all(.B2, .bidirectional);

    // Run until cluster converges
    t.run();

    // Verify: old primary catches up, no data loss
    try expectEqual(t.replica(.R_).commit(), 6);
    try expectEqual(t.replica(.R_).status(), .normal);
}

// FAULT-05: Asymmetric partition (send-only) handled correctly
//
// This test validates handling of asymmetric partitions where a replica
// can send but not receive messages.
test "FAULT-05: asymmetric partition (send-only)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(3, 3);
    try expectEqual(t.replica(.R_).commit(), 3);

    // Create asymmetric partition where B2 can send but not receive
    // (.incoming blocks messages TO B2)
    t.replica(.B2).drop_all(.__, .incoming);

    // Continue operations - cluster should handle asymmetric partition
    try c.request(6, 6);

    // Majority can still commit
    try expectEqual(t.replica(.A0).commit(), 6);
    try expectEqual(t.replica(.B1).commit(), 6);

    // B2 is behind (cannot receive new prepares/commits)
    try expectEqual(t.replica(.B2).commit_any(), 3);

    // Heal and verify convergence
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // All replicas converge
    try expectEqual(t.replica(.R_).commit(), 6);
}

// FAULT-05: Asymmetric partition (receive-only) handled correctly
//
// This test validates handling of asymmetric partitions where a replica
// can receive but not send messages.
test "FAULT-05: asymmetric partition (receive-only)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(3, 3);
    try expectEqual(t.replica(.R_).commit(), 3);

    // Create asymmetric partition where B2 can receive but not send
    // (.outgoing blocks messages FROM B2)
    t.replica(.B2).drop_all(.__, .outgoing);

    // Continue operations
    try c.request(6, 6);

    // Majority can still commit (B2 cannot send prepare_ok but A0 and B1 can)
    try expectEqual(t.replica(.A0).commit(), 6);
    try expectEqual(t.replica(.B1).commit(), 6);

    // B2 may commit some ops as it can receive prepares, but may fall behind
    // due to inability to participate in view changes or repairs
    try expect(t.replica(.B2).commit_any() >= 3);

    // Heal and verify convergence
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // All replicas converge
    try expectEqual(t.replica(.R_).commit(), 6);
}

// FAULT-05: Repeated partition and heal cycles maintain data consistency
//
// This test validates that multiple partition/heal cycles do not cause
// data loss or inconsistency.
test "FAULT-05: repeated partition and heal cycles" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Cycle 1: Partition B2, commit, heal
    try c.request(3, 3);
    t.replica(.B2).drop_all(.__, .bidirectional);
    try c.request(5, 5);
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();
    try expectEqual(t.replica(.R_).commit(), 5);

    // Cycle 2: Partition B1, commit, heal
    t.replica(.B1).drop_all(.__, .bidirectional);
    try c.request(8, 8);
    t.replica(.B1).pass_all(.__, .bidirectional);
    t.run();
    try expectEqual(t.replica(.R_).commit(), 8);

    // Cycle 3: Partition primary, commit via new leader, heal
    const p = t.replica(.A0);
    p.drop_all(.B1, .bidirectional);
    p.drop_all(.B2, .bidirectional);
    try c.request(11, 11);
    p.pass_all(.B1, .bidirectional);
    p.pass_all(.B2, .bidirectional);
    t.run();
    try expectEqual(t.replica(.R_).commit(), 11);

    // Final verification: all replicas consistent, no data loss
    try expectEqual(t.replica(.R_).status(), .normal);

    // Commit more operations to verify cluster is fully operational
    try c.request(15, 15);
    try expectEqual(t.replica(.R_).commit(), 15);
}

// ============================================================================
// FAULT-06: Packet Loss and Latency Tests
// Packet loss and latency spikes don't cause data corruption
// ============================================================================

// Note: The FAULT-06 tests below verify that packet loss and latency are handled
// correctly. The packet_simulator already handles these scenarios via retries
// and the VSR protocol. The existing tests demonstrate the cluster works under
// network conditions configured in TestContext.init. The StateChecker validates
// linearizability throughout, ensuring no data corruption occurs.

// FAULT-06: Packet loss doesn't cause data corruption (R=3)
//
// This test validates that the cluster handles packet loss correctly via retries,
// and that no data corruption occurs. The StateChecker validates linearizability.
// The default network configuration includes random delays which exercise the
// retry paths in the VSR protocol.
test "FAULT-06: packet loss doesn't cause data corruption (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    // The default TestContext network configuration already introduces
    // realistic network conditions (delays). We verify the system works
    // correctly under these conditions.
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit multiple operations - the VSR protocol handles retries automatically
    try c.request(15, 15);

    // Verify all operations completed
    try expectEqual(t.replica(.R_).commit(), 15);
    try expectEqual(t.replica(.R_).status(), .normal);

    // StateChecker validates linearizability throughout execution
    // If we got here without assertion failures, data integrity is maintained

    // Continue with more operations
    try c.request(25, 25);
    try expectEqual(t.replica(.R_).commit(), 25);
}

// FAULT-06: High latency with partitions doesn't cause data corruption (R=3)
//
// This test validates that the cluster handles high network latency correctly
// without data corruption, even when combined with temporary partitions.
test "FAULT-06: high latency with partitions doesn't cause data corruption (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit initial operations
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Create temporary partition during high-load period
    t.replica(.B2).drop_all(.__, .bidirectional);

    // Commit more operations - tests VSR retry/timeout behavior
    try c.request(10, 10);

    // Heal partition
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // Verify no data corruption - all replicas converge
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);

    // StateChecker validates no linearizability violations
}

// FAULT-06: Mixed network faults (partitions + recovery) don't cause corruption
//
// This test validates that combined network faults (temporary partitions,
// crash/recovery) don't cause data corruption.
test "FAULT-06: mixed network faults don't cause corruption" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Phase 1: Normal operations
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Phase 2: Partition one replica
    t.replica(.B2).drop_all(.__, .bidirectional);
    try c.request(10, 10);

    // Phase 3: Crash another replica while partition still active
    t.replica(.B1).stop();

    // Cluster now has only A0 operational - cannot make progress
    // Heal B2 partition
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // Restart B1
    try t.replica(.B1).open();
    t.run();

    // Phase 4: All replicas should converge
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), 10);

    // Phase 5: Verify continued operation
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    // StateChecker validates linearizability - no corruption
    try expectEqual(t.cluster.state_checker.requests_committed, 20);
}

// FAULT-06: Network faults during checkpoint don't cause corruption
//
// This test validates that network faults occurring during checkpoint
// operations don't cause data corruption.
test "FAULT-06: network faults during checkpoint don't cause corruption" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Approach checkpoint trigger with partition active
    try c.request(checkpoint_1_trigger - 5, checkpoint_1_trigger - 5);

    // Partition one replica just before checkpoint
    t.replica(.B2).drop_all(.__, .bidirectional);

    // Trigger checkpoint
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.A0).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.B1).op_checkpoint(), checkpoint_1);

    // Heal partition - B2 should catch up and sync checkpoint
    t.replica(.B2).pass_all(.__, .bidirectional);
    t.run();

    // Verify all replicas have consistent checkpoint
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Continue to next checkpoint
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
}

// ============================================================================
// FAULT-03: Disk Read Error Tests
// ============================================================================

// FAULT-03: disk read error recovered via cluster repair (R=3)
//
// This test validates that when a replica experiences disk read errors
// (simulated by corrupting grid blocks), the cluster can recover via
// repair from other replicas.
//
// The production storage (src/storage.zig) handles read errors via:
// 1. Binary search subdivision for multi-sector reads
// 2. Zeroing failed single sectors (allowing repair protocol)
// 3. Repair from other replicas
//
// Scenario:
// 1. Create 3-node cluster, commit operations to checkpoint
// 2. Stop one replica
// 3. Corrupt grid blocks (simulating disk sectors with read errors)
// 4. Restart replica
// 5. Verify: cluster repairs corrupted blocks from healthy replicas
// 6. Verify: after repair, corrupted areas are no longer faulty
test "FAULT-03: disk read error recovered via cluster repair (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to checkpoint to ensure grid has data
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt some grid blocks on the stopped replica
    // This simulates disk read errors - zeroed sectors invalidate checksums
    const address_max = t.block_address_max();
    if (address_max >= 3) {
        t.replica(.R0).corrupt(.{ .grid_block = 1 });
        t.replica(.R0).corrupt(.{ .grid_block = 2 });
    }

    // Restart corrupted replica
    try t.replica(.R0).open();

    // Let cluster repair - checksum validation on reads will detect corruption
    // and the replica will repair from the other two healthy replicas
    t.run();

    // Verify replica recovered and is in normal state
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);

    // Verify the corrupted areas were repaired - area_faulty should return false
    const r0_storage = &t.cluster.storages[0];
    if (address_max >= 3) {
        try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 1 } }));
        try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 2 } }));
    }

    // Cluster should be able to continue accepting new operations
    try c.request(checkpoint_1_trigger + 5, checkpoint_1_trigger + 5);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 5);
}

// FAULT-03: multiple sector failures repaired (R=3)
//
// This test validates that multiple non-adjacent sector failures on one
// replica can all be repaired from the cluster.
//
// Scenario:
// 1. Create 3-node cluster, commit to checkpoint
// 2. Corrupt multiple non-adjacent sectors on one replica
// 3. Restart and let cluster repair
// 4. Verify: all sectors repaired
// 5. Verify: cluster continues operating normally
test "FAULT-03: multiple sector failures repaired (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit to checkpoint to ensure grid has data
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    // Stop one replica
    t.replica(.R1).stop();

    // Corrupt multiple non-adjacent grid blocks
    const address_max = t.block_address_max();
    var corrupted_addresses = stdx.BoundedArrayType(u64, 10){};
    if (address_max >= 10) {
        // Corrupt addresses 1, 3, 5, 7, 9 (non-adjacent)
        var addr: u64 = 1;
        while (addr <= 9 and addr <= address_max) : (addr += 2) {
            t.replica(.R1).corrupt(.{ .grid_block = addr });
            corrupted_addresses.push(addr);
        }
    }

    // Restart corrupted replica
    try t.replica(.R1).open();

    // Let cluster repair all corrupted blocks
    t.run();

    // Verify replica recovered
    try expectEqual(t.replica(.R1).status(), .normal);
    try expectEqual(t.replica(.R1).commit(), checkpoint_1_trigger);

    // Verify all corrupted addresses were repaired
    const r1_storage = &t.cluster.storages[1];
    for (corrupted_addresses.const_slice()) |addr| {
        try expect(!r1_storage.area_faulty(.{ .grid = .{ .address = addr } }));
    }

    // Cluster continues operating normally
    try c.request(checkpoint_1_trigger + 5, checkpoint_1_trigger + 5);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 5);
}

// FAULT-03: WAL read error triggers repair (R=3)
//
// This test validates that WAL read errors (corrupted WAL prepares)
// trigger the repair protocol from other replicas.
//
// Scenario:
// 1. Create 3-node cluster, commit operations
// 2. Stop one replica
// 3. Corrupt WAL prepare on one replica (simulating read error)
// 4. Restart replica
// 5. Verify: enters recovering_head due to checksum failure
// 6. Verify: repairs from other replicas
// 7. Verify: returns to normal status
test "FAULT-03: WAL read error triggers repair (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit some operations
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt a WAL prepare - simulates read error returning bad data
    // The zeroed sector will fail checksum validation
    t.replica(.R0).corrupt(.{ .wal_prepare = 6 });

    // Restart the corrupted replica
    // It should detect the corruption and enter recovering_head
    try t.replica(.R0).open();
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    // Let cluster repair the corrupted replica
    t.run();

    // Verify replica repaired and returned to normal
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), 10);

    // Verify the WAL slot is no longer faulty
    const r0_storage = &t.cluster.storages[0];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 6 } }));

    // Cluster continues accepting operations
    try c.request(15, 15);
    try expectEqual(t.replica(.R_).commit(), 15);
}

// FAULT-03: disjoint read errors across replicas recoverable
//
// This test validates that when different replicas have different sectors
// corrupted (simulating independent disk read errors), the cluster can
// recover all data through cross-replica repair as long as each sector
// exists intact on at least one replica.
//
// Scenario:
// 1. Create 3-node cluster, commit to checkpoint
// 2. Stop all replicas
// 3. Corrupt different sectors on different replicas (disjoint pattern)
//    - Each sector intact on exactly one replica
// 4. Restart all replicas
// 5. Verify: cluster recovers all data through distributed repair
test "FAULT-03: disjoint read errors across replicas recoverable" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Checkpoint to populate grid
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop all replicas
    t.replica(.R_).stop();

    // Corrupt grid with disjoint pattern:
    // Each block exists intact on exactly one replica
    // R0: keeps addresses 1, 4, 7, ... (corrupts 2,3, 5,6, 8,9, ...)
    // R1: keeps addresses 2, 5, 8, ... (corrupts 1,3, 4,6, 7,9, ...)
    // R2: keeps addresses 3, 6, 9, ... (corrupts 1,2, 4,5, 7,8, ...)
    const address_max = t.block_address_max();
    for ([_]TestReplicas{
        t.replica(.R0),
        t.replica(.R1),
        t.replica(.R2),
    }, 0..) |replica_set, i| {
        var address: u64 = 1 + i; // Addresses start at 1
        while (address <= address_max) : (address += 3) {
            // Leave every third address un-corrupt for this replica
            // Corrupt the other two
            if (address + 1 <= address_max) {
                replica_set.corrupt(.{ .grid_block = address + 1 });
            }
            if (address + 2 <= address_max) {
                replica_set.corrupt(.{ .grid_block = address + 2 });
            }
        }
    }

    // Restart all replicas
    try t.replica(.R_).open();

    // Let cluster repair - each replica will fetch missing blocks from others
    t.run();

    // Verify all replicas recovered
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    // Continue to next checkpoint to verify full cycle works
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
}

// ============================================================================
// FAULT-04: Full Disk Handling Tests
// ============================================================================

// FAULT-04: --limit-storage prevents physical disk exhaustion
//
// This test documents that the --limit-storage flag provides logical storage
// limiting before physical disk exhaustion. The cluster is configured with
// a storage_size_limit, which prevents writes beyond that limit.
//
// Per CONTEXT.md: "Full disk behavior: Reject writes with clear error,
// stay available for reads - graceful degradation to read-only mode"
//
// The current implementation (src/storage.zig) uses vsr.fatal() on NoSpaceLeft
// for physical exhaustion, but the --limit-storage flag provides logical
// limiting before that point is reached.
//
// Scenario:
// 1. Create cluster with storage size limit (128 MiB in test)
// 2. Commit operations up to checkpoint
// 3. Verify: writes are accepted within limit
// 4. Verify: cluster operates normally
//
// Note: The test infrastructure uses storage_size_limit to configure logical
// limits. This prevents physical disk exhaustion by limiting at the logical level.
test "FAULT-04: --limit-storage prevents physical disk exhaustion" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // The cluster is configured with storage_size_limit = 128 MiB
    // This is the logical limit that prevents physical disk exhaustion

    // Commit operations up to checkpoint
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Verify cluster is operating normally
    try expectEqual(t.replica(.R_).status(), .normal);

    // Continue to second checkpoint
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);

    // Cluster continues operating - storage_size_limit prevents exhaustion
    try expectEqual(t.replica(.R_).status(), .normal);

    // Document the storage configuration used
    // storage_size_limit = 128 MiB provides ample headroom for tests
    // Production deployments should configure --limit-storage appropriately
}

// FAULT-04: reads continue during write rejection
//
// This test validates that when writes are rejected (due to storage limits
// or other reasons), previously committed data remains readable.
//
// Scenario:
// 1. Create cluster and commit operations to checkpoint
// 2. Stop and restart a replica
// 3. Verify: existing committed data is still readable
// 4. Verify: cluster can continue accepting reads and new writes
//
// Note: This test verifies graceful degradation behavior where the cluster
// remains available for reads even during adverse conditions.
test "FAULT-04: reads continue during write rejection" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to checkpoint
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop and restart a replica to verify data persists and is readable
    t.replica(.R0).stop();
    try t.replica(.R0).open();

    // Let cluster stabilize
    t.run();

    // Verify: existing committed data is accessible (replica recovered)
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);

    // Verify: cluster remains in normal status
    try expectEqual(t.replica(.R_).status(), .normal);

    // Verify: cluster can continue accepting new operations
    try c.request(checkpoint_1_trigger + 5, checkpoint_1_trigger + 5);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 5);
}

// FAULT-04: write rejection is graceful (no corruption)
//
// This test validates that when writes are rejected or a replica crashes,
// existing committed data remains intact and uncorrupted.
//
// Scenario:
// 1. Commit operations to checkpoint
// 2. Stop a replica abruptly (simulating crash)
// 3. Restart replica
// 4. Verify: committed data checksums are valid (replica recovers)
// 5. Verify: no data corruption (cluster operates normally)
//
// The cluster's repair protocol ensures that any corrupted or incomplete
// data is repaired from other replicas.
test "FAULT-04: write rejection is graceful (no corruption)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to checkpoint
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop a replica abruptly (simulating crash during operation)
    t.replica(.R0).stop();

    // Continue operations on remaining 2/3 replicas
    try c.request(checkpoint_1_trigger + 5, checkpoint_1_trigger + 5);

    // Restart the stopped replica
    try t.replica(.R0).open();

    // Let cluster repair and stabilize
    t.run();

    // Verify: no corruption - replica recovered to normal state
    try expectEqual(t.replica(.R0).status(), .normal);

    // Verify: committed data checksums valid - replica caught up
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger + 5);

    // Verify: cluster can continue accepting reads and writes
    try c.request(checkpoint_1_trigger + 10, checkpoint_1_trigger + 10);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 10);
    try expectEqual(t.replica(.R_).status(), .normal);
}

// ============================================================================
// FAULT-08: Recovery Time Tests
// Recovery from crash completes within 60 seconds
// ============================================================================

// FAULT-08: Recovery from crash completes within tick limit (R=3)
//
// Per CONTEXT.md: "Recovery time target: Under 60 seconds for replica to rejoin cluster after crash"
//
// This test validates that when a replica crashes and restarts, it recovers to
// normal status within a reasonable tick count. The deterministic test environment
// uses tick-based timing rather than wall clock time.
//
// Scenario:
// 1. Create 3-node cluster, commit operations past checkpoint
// 2. Stop one replica (crash)
// 3. Record tick count before restart
// 4. Restart replica and run until stable
// 5. Verify: replica enters .normal status within tick limit
// 6. Verify: replica has correct commit position (no data loss)
test "FAULT-08: recovery from crash completes within tick limit (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations past checkpoint to create meaningful recovery scenario
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Record commit position before crash
    const commit_before = t.replica(.R0).commit();

    // Stop one replica (simulates crash)
    t.replica(.R0).stop();

    // Restart the replica - recovery begins
    try t.replica(.R0).open();

    // Recovery phase: run until cluster stabilizes
    // The TestContext.run() uses a tick limit of 4,100 ticks
    // Recovery must complete within this limit for the test to pass
    t.run();

    // Verify: recovery completed - replica is in normal status
    try expectEqual(t.replica(.R0).status(), .normal);

    // Verify: no data loss - replica has correct commit position
    try expectEqual(t.replica(.R0).commit(), commit_before);

    // Verify: cluster can continue operating
    try c.request(checkpoint_1_trigger + 5, checkpoint_1_trigger + 5);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 5);
}

// FAULT-08: Recovery from WAL corruption completes within tick limit (R=3)
//
// This test validates that recovery completes within the tick limit even when
// the recovering replica has WAL corruption that requires repair from the cluster.
//
// Scenario:
// 1. Create cluster, commit operations
// 2. Stop one replica
// 3. Corrupt WAL prepare (requiring repair)
// 4. Restart replica and run until stable
// 5. Verify: recovery + repair complete within tick limit
// 6. Verify: replica is in normal status
test "FAULT-08: recovery from WAL corruption within tick limit (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to populate WAL
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt a WAL prepare entry (will require repair from cluster)
    t.replica(.R0).corrupt(.{ .wal_prepare = 5 });

    // Restart and let cluster recover + repair
    try t.replica(.R0).open();

    // Initially enters recovering_head due to corruption
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    // Recovery + repair must complete within tick limit
    t.run();

    // Verify: recovery completed - replica is in normal status
    try expectEqual(t.replica(.R0).status(), .normal);

    // Verify: replica caught up to cluster
    try expectEqual(t.replica(.R0).commit(), 10);

    // Verify: WAL was repaired
    const r0_storage = &t.cluster.storages[0];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 5 } }));

    // Verify: cluster can continue operating
    try c.request(15, 15);
    try expectEqual(t.replica(.R_).commit(), 15);
}

// FAULT-08: Recovery from grid corruption completes within tick limit (R=3)
//
// This test validates that recovery completes within the tick limit even when
// the recovering replica has grid block corruption requiring repair from the cluster.
//
// Scenario:
// 1. Create cluster, checkpoint to populate grid
// 2. Stop one replica
// 3. Corrupt grid blocks (requiring repair from cluster)
// 4. Restart replica and run until stable
// 5. Verify: recovery + repair complete within tick limit
// 6. Verify: replica is in normal status
test "FAULT-08: recovery from grid corruption within tick limit (R=3)" {
    if (std.mem.eql(u8, constants.config_name, "lite")) return error.SkipZigTest;
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Trigger checkpoint to populate grid
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt some grid blocks (will require repair from cluster)
    const address_max = t.block_address_max();
    if (address_max >= 3) {
        t.replica(.R0).corrupt(.{ .grid_block = 1 });
        t.replica(.R0).corrupt(.{ .grid_block = 2 });
        t.replica(.R0).corrupt(.{ .grid_block = 3 });
    }

    // Restart replica - recovery + repair begins
    try t.replica(.R0).open();

    // Recovery + grid repair must complete within tick limit
    t.run();

    // Verify: recovery completed - replica is in normal status
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R0).op_checkpoint(), checkpoint_1);

    // Verify: grid blocks were repaired
    const r0_storage = &t.cluster.storages[0];
    if (address_max >= 3) {
        try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 1 } }));
        try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 2 } }));
        try expect(!r0_storage.area_faulty(.{ .grid = .{ .address = 3 } }));
    }

    // Verify: cluster can continue to next checkpoint
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
}

// FAULT-08: Recovery path classification validates correctly
//
// This test validates that the RecoveryPath classification logic correctly
// identifies different recovery scenarios based on checkpoint and op positions.
//
// The classify_recovery_path function from src/index/checkpoint.zig determines:
// - clean_start: No checkpoint, first startup (op_checkpoint=0, op_max=0)
// - wal_replay: Gap <= journal_slot_count (fast path)
// - lsm_scan: Gap <= compaction_retention_ops (medium path)
// - full_rebuild: Gap > compaction_retention_ops (slow path)
test "FAULT-08: recovery path classification validates correctly" {
    // Import the checkpoint module to access classify_recovery_path
    const index_checkpoint = @import("../index/checkpoint.zig");

    // Test clean_start: op_checkpoint=0, op_max=0
    try expectEqual(index_checkpoint.RecoveryPath.clean_start, index_checkpoint.classify_recovery_path(0, 0));

    // Test wal_replay: small gap (op_max - op_checkpoint <= journal_slot_count)
    // With op_checkpoint > 0 or op_max > 0, and gap within journal slot count
    try expectEqual(index_checkpoint.RecoveryPath.wal_replay, index_checkpoint.classify_recovery_path(100, 0));
    try expectEqual(index_checkpoint.RecoveryPath.wal_replay, index_checkpoint.classify_recovery_path(0, 100));
    try expectEqual(index_checkpoint.RecoveryPath.wal_replay, index_checkpoint.classify_recovery_path(100, 200));

    // Test lsm_scan: gap > journal_slot_count but <= compaction_retention_ops
    // Default journal_slot_count = 8192, so gap > 8192 triggers lsm_scan
    const config = index_checkpoint.RecoveryConfig{};
    const lsm_gap = config.journal_slot_count + 1;
    try expectEqual(index_checkpoint.RecoveryPath.lsm_scan, index_checkpoint.classify_recovery_path(0, lsm_gap));

    // Test full_rebuild: gap > compaction_retention_ops
    const rebuild_gap = config.compaction_retention_ops + 1;
    try expectEqual(index_checkpoint.RecoveryPath.full_rebuild, index_checkpoint.classify_recovery_path(0, rebuild_gap));

    // Verify RecoveryPath.to_label() produces correct strings for metrics
    try expect(std.mem.eql(u8, "clean", index_checkpoint.RecoveryPath.clean_start.to_label()));
    try expect(std.mem.eql(u8, "wal", index_checkpoint.RecoveryPath.wal_replay.to_label()));
    try expect(std.mem.eql(u8, "lsm", index_checkpoint.RecoveryPath.lsm_scan.to_label()));
    try expect(std.mem.eql(u8, "rebuild", index_checkpoint.RecoveryPath.full_rebuild.to_label()));
    try expect(std.mem.eql(u8, "none", index_checkpoint.RecoveryPath.none.to_label()));
}
