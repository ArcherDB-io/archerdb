// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Data Integrity Validation Tests
//!
//! These tests explicitly validate the data integrity requirements:
//! - DATA-01: WAL replay after crash restores exact state
//! - DATA-02: Checkpoint/restore cycle preserves all data
//! - DATA-06: Torn writes are detected and handled correctly
//!
//! Tests use the deterministic Cluster framework with fixed seeds for reproducibility.
//! They follow patterns from replica_test.zig and TigerBeetle's crash recovery tests.

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
        client_count: u8 = constants.clients_max,
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

    pub fn corrupt(t: *const TestReplicas, options: anytype) void {
        for (t.replicas.const_slice()) |r| {
            const storage = &t.cluster.storages[r];
            storage.memory_fault(options);
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
        return t.get(.op_checkpoint);
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
// DATA-01: WAL Replay Tests
// ============================================================================

/// DATA-01: WAL replay restores correct state after crash (R=3)
///
/// This test validates that when a replica's WAL is corrupted, the cluster can
/// recover via repair from other replicas, ensuring WAL replay restores exact state.
///
/// Scenario:
/// 1. Create 3-node cluster and commit 10+ operations
/// 2. Stop all replicas (simulating crash)
/// 3. Corrupt one replica's WAL at a specific slot
/// 4. Restart all replicas
/// 5. Verify: corrupted replica repairs from others and cluster reaches consensus
test "DATA-01: WAL replay restores correct state after crash (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations across multiple slots to ensure WAL has meaningful data
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop all replicas (crash simulation)
    t.replica(.R_).stop();

    // Corrupt one replica's WAL at slot 2 (an operation we committed)
    t.replica(.R0).corrupt(.{ .wal_prepare = 2 });

    // Restart replicas - R0 first, which should enter recovering_head due to corruption
    try t.replica(.R0).open();
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    // Restart remaining replicas - they will help R0 repair
    try t.replica(.R1).open();
    try t.replica(.R2).open();

    // Let cluster repair and stabilize
    t.run();

    // Verify all replicas have recovered and are in normal state
    try expectEqual(t.replica(.R_).status(), .normal);

    // Verify the commit position is correct (data restored)
    try expectEqual(t.replica(.R_).commit(), 10);

    // Cluster should be able to continue accepting new operations
    try c.request(15, 15);
    try expectEqual(t.replica(.R_).commit(), 15);
}

/// DATA-01: WAL replay with root corruption (R=3)
///
/// This test validates that a replica can recover from corruption of the root
/// prepare (slot 0), which is a critical edge case for WAL recovery.
///
/// Scenario:
/// 1. Create 3-node cluster
/// 2. Stop one replica
/// 3. Corrupt its root prepare (slot 0)
/// 4. Restart and verify recovery via cluster repair
test "DATA-01: WAL replay with root corruption (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt the root prepare (slot 0) - this is a critical edge case
    t.replica(.R0).corrupt(.{ .wal_prepare = 0 });

    // Restart the corrupted replica
    try t.replica(.R0).open();

    // Commit some operations - cluster should be able to function
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Verify the corrupted replica was repaired by checking:
    // 1. It's in normal status
    // 2. It has the correct commit position
    // 3. Its WAL slot 0 is no longer faulty
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), 5);

    // Verify the storage for R0 shows the fault was repaired
    const r0_storage = &t.cluster.storages[0];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 0 } }));
}

// ============================================================================
// DATA-02: Checkpoint/Restore Tests
// ============================================================================

/// DATA-02: Checkpoint/restore cycle preserves all data (R=3)
///
/// This test validates that after a checkpoint, corrupted grid blocks can be
/// repaired from other replicas, ensuring checkpoint/restore preserves all data.
///
/// Scenario:
/// 1. Create 3-node cluster
/// 2. Commit enough operations to trigger checkpoint
/// 3. Stop all replicas
/// 4. Corrupt grid blocks on each replica (disjoint corruption pattern)
/// 5. Restart and verify cluster recovers all data
/// 6. Continue to next checkpoint to verify full cycle
test "DATA-02: checkpoint/restore cycle preserves all data (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Checkpoint to ensure that replicas will use grid for recovery
    // All replicas must be at same commit to ensure grid repair won't fail
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    // Stop all replicas
    t.replica(.R_).stop();

    // Corrupt the grid with disjoint pattern:
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
            // Corrupt the other two
            replica_set.corrupt(.{ .grid_block = address + 1 });
            replica_set.corrupt(.{ .grid_block = address + 2 });
        }
    }

    // Restart all replicas
    try t.replica(.R_).open();

    // Let cluster repair grid and stabilize
    t.run();

    // Verify recovery: all replicas should be in normal state
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    // Continue to next checkpoint to verify full cycle works
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);
}

// ============================================================================
// DATA-03: Checksum Corruption Detection Tests
// ============================================================================

/// DATA-03: checksums detect WAL prepare corruption
///
/// This test validates that when a replica's WAL prepare is corrupted, the
/// checksum mismatch is detected and the cluster repairs the corrupted replica
/// from healthy replicas.
///
/// Scenario:
/// 1. Create 3-node cluster and commit operations
/// 2. Stop one replica
/// 3. Corrupt a WAL prepare (zeros the sector, invalidating checksum)
/// 4. Restart replica
/// 5. Verify: corruption detected (enters recovering_head)
/// 6. Verify: cluster repairs from healthy replicas
/// 7. Verify: after repair, area is no longer faulty
test "DATA-03: checksums detect WAL prepare corruption" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit operations to populate WAL
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);
    try expectEqual(t.replica(.R_).status(), .normal);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt a WAL prepare - this zeros the sector which invalidates checksum
    t.replica(.R0).corrupt(.{ .wal_prepare = 3 });

    // Restart corrupted replica - should detect corruption via checksum
    try t.replica(.R0).open();
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    // Let cluster repair corrupted replica from healthy replicas
    t.run();

    // Verify repair completed
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), 5);

    // Verify the corrupted area was repaired - area_faulty should return false
    const r0_storage = &t.cluster.storages[0];
    try expect(!r0_storage.area_faulty(.{ .wal_prepares = .{ .slot = 3 } }));

    // Cluster can continue accepting operations
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
}

/// DATA-03: checksums detect grid block corruption
///
/// This test validates that corrupted grid blocks are detected via checksum
/// and repaired from other replicas.
///
/// Scenario:
/// 1. Create 3-node cluster and checkpoint to populate grid
/// 2. Stop one replica
/// 3. Corrupt grid blocks (zeros sectors, invalidating checksums)
/// 4. Restart replica
/// 5. Verify: cluster repairs corrupted grid blocks
/// 6. Verify: repaired blocks are readable (no checksum errors)
test "DATA-03: checksums detect grid block corruption" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Checkpoint to populate grid with data
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt some grid blocks on the stopped replica
    // This zeros the sectors which invalidates the Aegis128 checksums
    const address_max = t.block_address_max();
    if (address_max >= 5) {
        t.replica(.R0).corrupt(.{ .grid_block = 1 });
        t.replica(.R0).corrupt(.{ .grid_block = 2 });
        t.replica(.R0).corrupt(.{ .grid_block = 3 });
    }

    // Restart corrupted replica
    try t.replica(.R0).open();

    // Let cluster repair - checksum validation on reads will detect corruption
    t.run();

    // Verify replica recovered and is in normal state
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);

    // Continue to next checkpoint to verify grid is usable
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
}

/// DATA-03: disjoint corruption across replicas recoverable
///
/// This test validates that when different replicas have different blocks
/// corrupted, the cluster can recover all data through cross-replica repair,
/// as long as each block exists intact on at least one replica.
///
/// Scenario:
/// 1. Create 3-node cluster and checkpoint
/// 2. Stop all replicas
/// 3. Corrupt different blocks on different replicas (disjoint pattern)
///    - Each block intact on exactly one replica
/// 4. Restart cluster
/// 5. Verify: cluster recovers all blocks through distributed repair
test "DATA-03: disjoint corruption across replicas recoverable" {
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
// DATA-06: Torn Write Tests
// ============================================================================

/// DATA-06: Torn writes detected and handled (R=3)
///
/// This test validates that torn writes (simulated by WAL header corruption)
/// are detected during recovery and the replica can repair from the cluster.
///
/// Scenario:
/// 1. Commit operations
/// 2. Stop one replica
/// 3. Corrupt WAL header (not prepare) - simulating torn write
/// 4. Restart replica
/// 5. Verify it detects corruption and repairs from cluster
test "DATA-06: torn writes detected and handled (R=3)" {
    const t = try TestContext.init(.{ .replica_count = 3, .seed = 42 });
    defer t.deinit();

    var c = t.clients();

    // Commit some operations
    try c.request(5, 5);
    try expectEqual(t.replica(.R_).commit(), 5);

    // Stop one replica
    t.replica(.R0).stop();

    // Corrupt WAL header at slot 3 - simulates torn write where header
    // doesn't match prepare (header written but prepare corrupted/incomplete)
    t.replica(.R0).corrupt(.{ .wal_header = 3 });

    // Restart the replica - it should detect the torn write
    try t.replica(.R0).open();

    // Let cluster run to allow repair
    t.run();

    // Verify replica recovered
    try expectEqual(t.replica(.R0).status(), .normal);
    try expectEqual(t.replica(.R0).commit(), 5);

    // Verify cluster is healthy and can continue
    try c.request(10, 10);
    try expectEqual(t.replica(.R_).commit(), 10);
}

/// DATA-06: Torn writes with standby (R=1 S=1)
///
/// This test validates that R=1 can recover from a torn write when a standby
/// is present to provide the intact prepare.
///
/// Based on replica_test.zig pattern:
/// "Cluster: recovery: WAL torn prepare, standby with intact prepare (R=1 S=1)"
///
/// Scenario:
/// 1. R=1 with S=1 standby commits operations
/// 2. R=1 stops, header corrupted (torn write)
/// 3. R=1 restarts, truncates torn prepare, increments view
/// 4. Standby can continue with cluster
test "DATA-06: torn writes with standby (R=1 S=1)" {
    const t = try TestContext.init(.{
        .replica_count = 1,
        .standby_count = 1,
        .seed = 42,
    });
    defer t.deinit();

    var c = t.clients();

    // Commit some operations
    try c.request(2, 2);
    try expectEqual(t.replica(.R0).commit(), 2);
    try expectEqual(t.replica(.S0).commit(), 2);

    // Stop the primary
    t.replica(.R0).stop();

    // Corrupt the WAL header for the last operation (torn write simulation)
    // The standby received this prepare intact
    t.replica(.R0).corrupt(.{ .wal_header = 2 });

    // Restart R0 - it will detect torn write and truncate
    // It increments its view so standby discards the truncated prepare
    try t.replica(.R0).open();

    // Continue with more operations - this validates recovery worked
    try c.request(5, 5);

    // Verify both replica and standby are in sync
    try expectEqual(t.replica(.R0).commit(), 5);
    try expectEqual(t.replica(.S0).commit(), 5);
}
