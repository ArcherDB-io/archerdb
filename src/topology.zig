// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Cluster Topology Management
//!
//! This module provides topology discovery and management for smart clients.
//! Clients use the topology to route requests to the appropriate shards.
//!
//! Per index-sharding/spec.md and query-routing.md:
//! - Clients request topology via `get_topology` operation
//! - Topology includes shard-to-node mapping
//! - Clients subscribe to topology change notifications
//! - Topology refresh occurs on connection errors
//!
//! ## Topology Format
//!
//! ```json
//! {
//!   "version": 42,
//!   "shards": [
//!     {
//!       "id": 0,
//!       "primary": "node-0:5000",
//!       "replicas": ["node-1:5000", "node-2:5000"],
//!       "status": "active"
//!     }
//!   ],
//!   "num_shards": 16
//! }
//! ```

const std = @import("std");
const assert = std.debug.assert;

/// Maximum number of shards supported.
pub const max_shards: u32 = 256;

/// Maximum number of replicas per shard.
pub const max_replicas_per_shard: u8 = 6;

/// Maximum length of a node address string.
pub const max_address_len: usize = 64;

/// Maximum number of concurrent subscribers for topology changes.
pub const max_subscribers: usize = 1024;

/// Maximum pending notifications in the queue.
pub const max_pending_notifications: usize = 64;

/// Shard status indicating health and availability.
pub const ShardStatus = enum(u8) {
    /// Shard is active and accepting requests.
    active = 0,
    /// Shard is syncing data (read-only).
    syncing = 1,
    /// Shard is unavailable.
    unavailable = 2,
    /// Shard is being migrated during resharding.
    migrating = 3,
    /// Shard is being decommissioned.
    decommissioning = 4,

    pub fn toString(self: ShardStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .syncing => "syncing",
            .unavailable => "unavailable",
            .migrating => "migrating",
            .decommissioning => "decommissioning",
        };
    }
};

/// Address stored as fixed-size byte array for wire format.
pub const Address = [max_address_len]u8;

/// Zero-initialized address.
pub const empty_address: Address = [_]u8{0} ** max_address_len;

/// Information about a single shard.
pub const ShardInfo = struct {
    /// Shard ID (0 to num_shards-1).
    id: u32,

    /// Primary/leader node address (e.g., "192.168.1.10:5000").
    primary: Address,

    /// Replica node addresses.
    replicas: [max_replicas_per_shard]Address,

    /// Number of active replicas.
    replica_count: u8,

    /// Current shard status.
    status: ShardStatus,

    /// Entity count (approximate).
    entity_count: u64,

    /// Size in bytes (approximate).
    size_bytes: u64,

    /// Initialize with defaults.
    pub fn init(shard_id: u32) ShardInfo {
        return .{
            .id = shard_id,
            .primary = empty_address,
            .replicas = [_]Address{empty_address} ** max_replicas_per_shard,
            .replica_count = 0,
            .status = .unavailable,
            .entity_count = 0,
            .size_bytes = 0,
        };
    }

    /// Set primary address from string.
    pub fn setPrimary(self: *ShardInfo, addr: []const u8) void {
        self.primary = empty_address;
        const len = @min(addr.len, max_address_len);
        @memcpy(self.primary[0..len], addr[0..len]);
    }

    /// Get primary address as string slice.
    pub fn getPrimary(self: *const ShardInfo) []const u8 {
        return std.mem.sliceTo(&self.primary, 0);
    }

    /// Add a replica address.
    pub fn addReplica(self: *ShardInfo, addr: []const u8) bool {
        if (self.replica_count >= max_replicas_per_shard) return false;
        const idx = self.replica_count;
        self.replicas[idx] = empty_address;
        const len = @min(addr.len, max_address_len);
        @memcpy(self.replicas[idx][0..len], addr[0..len]);
        self.replica_count += 1;
        return true;
    }

    /// Get replica address as string slice.
    pub fn getReplica(self: *const ShardInfo, idx: u8) ?[]const u8 {
        if (idx >= self.replica_count) return null;
        return std.mem.sliceTo(&self.replicas[idx], 0);
    }
};

/// Request for topology information.
/// Empty request - no parameters needed.
pub const TopologyRequest = struct {
    /// Reserved for future use (e.g., specific shard query).
    reserved: u64 = 0,
};

/// Response containing cluster topology.
pub const TopologyResponse = struct {
    /// Topology version number (increments on changes).
    version: u64,

    /// Number of shards in the cluster.
    num_shards: u32,

    /// Cluster name/identifier.
    cluster_id: u128,

    /// Timestamp of last topology change (nanoseconds since epoch).
    last_change_ns: i128,

    /// Resharding status (0=idle, 1=preparing, 2=migrating, 3=finalizing).
    resharding_status: u8,

    /// Reserved for future flags.
    flags: u8,

    /// Padding for alignment.
    _padding: [6]u8 = [_]u8{0} ** 6,

    /// Shard information array.
    /// Only first `num_shards` entries are valid.
    shards: [max_shards]ShardInfo,

    /// Initialize with defaults.
    pub fn init() TopologyResponse {
        var response = TopologyResponse{
            .version = 0,
            .num_shards = 0,
            .cluster_id = 0,
            .last_change_ns = 0,
            .resharding_status = 0,
            .flags = 0,
            .shards = undefined,
        };
        for (&response.shards, 0..) |*shard, i| {
            shard.* = ShardInfo.init(@intCast(i));
        }
        return response;
    }

    /// Get a shard by ID.
    pub fn getShard(self: *const TopologyResponse, shard_id: u32) ?*const ShardInfo {
        if (shard_id >= self.num_shards) return null;
        return &self.shards[shard_id];
    }

    /// Compute which shard an entity belongs to.
    pub fn computeShard(self: *const TopologyResponse, entity_id: u128) u32 {
        const sharding = @import("sharding.zig");
        const shard_key = sharding.computeShardKey(entity_id);
        return sharding.computeShardBucket(shard_key, self.num_shards);
    }
};

/// Topology change notification (pushed to clients).
pub const TopologyChangeNotification = struct {
    /// New topology version.
    new_version: u64,

    /// Previous topology version.
    old_version: u64,

    /// Change type.
    change_type: ChangeType,

    /// Affected shard ID (if applicable).
    affected_shard: u32,

    /// Timestamp of change.
    timestamp_ns: i128,

    pub const ChangeType = enum(u8) {
        /// Shard leader changed (failover).
        leader_change = 0,
        /// Replica added to shard.
        replica_added = 1,
        /// Replica removed from shard.
        replica_removed = 2,
        /// Resharding started.
        resharding_started = 3,
        /// Resharding completed.
        resharding_completed = 4,
        /// Shard status changed.
        status_change = 5,
    };

    /// Serialize notification to bytes for wire format.
    pub fn toBytes(self: *const TopologyChangeNotification) [48]u8 {
        var bytes: [48]u8 = undefined;
        @memcpy(bytes[0..8], std.mem.asBytes(&self.new_version));
        @memcpy(bytes[8..16], std.mem.asBytes(&self.old_version));
        bytes[16] = @intFromEnum(self.change_type);
        @memcpy(bytes[17..21], std.mem.asBytes(&self.affected_shard));
        bytes[21..24].* = [_]u8{ 0, 0, 0 }; // padding
        @memcpy(bytes[24..40], std.mem.asBytes(&self.timestamp_ns));
        bytes[40..48].* = [_]u8{0} ** 8; // reserved
        return bytes;
    }
};

/// Callback type for topology change subscribers.
/// The callback receives the notification and user context.
pub const TopologyChangeCallback = *const fn (
    notification: *const TopologyChangeNotification,
    context: ?*anyopaque,
) void;

/// Subscriber entry for topology change notifications.
pub const TopologySubscriber = struct {
    /// Callback to invoke on topology change.
    callback: TopologyChangeCallback,
    /// User-provided context passed to callback.
    context: ?*anyopaque,
    /// Subscriber ID for unsubscribe.
    id: u64,
    /// Whether this slot is active.
    active: bool,

    pub const empty = TopologySubscriber{
        .callback = undefined,
        .context = null,
        .id = 0,
        .active = false,
    };
};

/// Pending notification queue entry.
pub const PendingNotification = struct {
    notification: TopologyChangeNotification,
    /// Retry count for delivery.
    retry_count: u8,
    /// Whether this entry is valid.
    valid: bool,

    pub const empty = PendingNotification{
        .notification = undefined,
        .retry_count = 0,
        .valid = false,
    };
};

/// Topology manager maintains the current cluster topology.
pub const TopologyManager = struct {
    const Self = @This();

    /// Current topology.
    topology: TopologyResponse,

    /// Lock for thread-safe access.
    mutex: std.Thread.Mutex,

    /// Registered subscribers for change notifications.
    subscribers: [max_subscribers]TopologySubscriber,

    /// Number of active subscribers.
    subscriber_count: u32,

    /// Next subscriber ID to assign.
    next_subscriber_id: u64,

    /// Pending notifications queue (circular buffer).
    pending_notifications: [max_pending_notifications]PendingNotification,

    /// Head index for pending queue.
    pending_head: usize,

    /// Tail index for pending queue.
    pending_tail: usize,

    /// Total notifications sent (for metrics).
    notifications_sent: u64,

    /// Total notifications failed (for metrics).
    notifications_failed: u64,

    /// Initialize the topology manager.
    pub fn init(cluster_id: u128, num_shards: u32) Self {
        var manager = Self{
            .topology = TopologyResponse.init(),
            .mutex = .{},
            .subscribers = [_]TopologySubscriber{TopologySubscriber.empty} ** max_subscribers,
            .subscriber_count = 0,
            .next_subscriber_id = 1,
            .pending_notifications = [_]PendingNotification{PendingNotification.empty} ** max_pending_notifications,
            .pending_head = 0,
            .pending_tail = 0,
            .notifications_sent = 0,
            .notifications_failed = 0,
        };
        manager.topology.cluster_id = cluster_id;
        manager.topology.num_shards = num_shards;
        manager.topology.version = 1;
        manager.topology.last_change_ns = std.time.nanoTimestamp();

        // Initialize all shards as active
        for (0..num_shards) |i| {
            manager.topology.shards[i].status = .active;
        }

        return manager;
    }

    /// Get current topology (thread-safe copy).
    pub fn getTopology(self: *Self) TopologyResponse {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.topology;
    }

    /// Get current topology version.
    pub fn getVersion(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.topology.version;
    }

    /// Update shard primary address.
    pub fn updateShardPrimary(self: *Self, shard_id: u32, address: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (shard_id >= self.topology.num_shards) {
            return error.InvalidShardId;
        }

        self.topology.shards[shard_id].setPrimary(address);
        self.topology.version += 1;
        self.topology.last_change_ns = std.time.nanoTimestamp();
    }

    /// Update shard status.
    pub fn updateShardStatus(self: *Self, shard_id: u32, status: ShardStatus) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (shard_id >= self.topology.num_shards) {
            return error.InvalidShardId;
        }

        self.topology.shards[shard_id].status = status;
        self.topology.version += 1;
        self.topology.last_change_ns = std.time.nanoTimestamp();
    }

    /// Update shard metrics (entity count, size).
    pub fn updateShardMetrics(self: *Self, shard_id: u32, entity_count: u64, size_bytes: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (shard_id >= self.topology.num_shards) {
            return error.InvalidShardId;
        }

        self.topology.shards[shard_id].entity_count = entity_count;
        self.topology.shards[shard_id].size_bytes = size_bytes;
        // Metrics update doesn't change topology version
    }

    /// Set resharding status.
    pub fn setReshardingStatus(self: *Self, status: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.topology.resharding_status = status;
        if (status != 0) {
            self.topology.version += 1;
            self.topology.last_change_ns = std.time.nanoTimestamp();
        }
    }

    /// Update number of shards (after resharding completes).
    pub fn updateShardCount(self: *Self, new_count: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.topology.num_shards = new_count;
        self.topology.version += 1;
        self.topology.last_change_ns = std.time.nanoTimestamp();
    }

    /// Add a replica to a shard.
    pub fn addShardReplica(self: *Self, shard_id: u32, address: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (shard_id >= self.topology.num_shards) {
            return error.InvalidShardId;
        }

        if (!self.topology.shards[shard_id].addReplica(address)) {
            return error.TooManyReplicas;
        }

        self.topology.version += 1;
        self.topology.last_change_ns = std.time.nanoTimestamp();
    }

    // ========================================================================
    // Subscription Management (F5.1.3)
    // ========================================================================

    /// Subscribe to topology change notifications.
    /// Returns a subscriber ID that can be used to unsubscribe.
    /// Returns null if max subscribers reached.
    pub fn subscribe(
        self: *Self,
        callback: TopologyChangeCallback,
        context: ?*anyopaque,
    ) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find an empty slot
        for (&self.subscribers) |*sub| {
            if (!sub.active) {
                const id = self.next_subscriber_id;
                self.next_subscriber_id +%= 1;

                sub.* = .{
                    .callback = callback,
                    .context = context,
                    .id = id,
                    .active = true,
                };
                self.subscriber_count += 1;
                return id;
            }
        }

        // No slots available
        return null;
    }

    /// Unsubscribe from topology change notifications.
    /// Returns true if subscriber was found and removed.
    pub fn unsubscribe(self: *Self, subscriber_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.subscribers) |*sub| {
            if (sub.active and sub.id == subscriber_id) {
                sub.active = false;
                self.subscriber_count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Get current subscriber count.
    pub fn getSubscriberCount(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.subscriber_count;
    }

    // ========================================================================
    // Notification Broadcasting (F5.1.3)
    // ========================================================================

    /// Broadcast a topology change notification to all subscribers.
    /// This is called internally when topology changes.
    /// Notification delivery is best-effort (per spec).
    pub fn notifySubscribers(
        self: *Self,
        change_type: TopologyChangeNotification.ChangeType,
        affected_shard: u32,
    ) void {
        // Build notification with current state
        const old_version = self.topology.version -| 1;
        const notification = TopologyChangeNotification{
            .new_version = self.topology.version,
            .old_version = old_version,
            .change_type = change_type,
            .affected_shard = affected_shard,
            .timestamp_ns = self.topology.last_change_ns,
        };

        // Deliver to all active subscribers
        var delivered: u64 = 0;

        for (&self.subscribers) |*sub| {
            if (sub.active) {
                // Best-effort delivery - don't fail on individual subscriber errors
                sub.callback(&notification, sub.context);
                delivered += 1;
            }
        }

        self.notifications_sent += delivered;
    }

    /// Queue a notification for later delivery (for async scenarios).
    /// Returns false if queue is full.
    pub fn queueNotification(
        self: *Self,
        change_type: TopologyChangeNotification.ChangeType,
        affected_shard: u32,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if queue is full
        const next_tail = (self.pending_tail + 1) % max_pending_notifications;
        if (next_tail == self.pending_head) {
            return false; // Queue full
        }

        // Build notification
        self.pending_notifications[self.pending_tail] = .{
            .notification = .{
                .new_version = self.topology.version,
                .old_version = self.topology.version -| 1,
                .change_type = change_type,
                .affected_shard = affected_shard,
                .timestamp_ns = std.time.nanoTimestamp(),
            },
            .retry_count = 0,
            .valid = true,
        };

        self.pending_tail = next_tail;
        return true;
    }

    /// Process pending notifications from the queue.
    /// Returns number of notifications delivered.
    pub fn processPendingNotifications(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var processed: u32 = 0;

        while (self.pending_head != self.pending_tail) {
            const entry = &self.pending_notifications[self.pending_head];
            if (entry.valid) {
                // Deliver to all subscribers (best-effort)
                for (&self.subscribers) |*sub| {
                    if (sub.active) {
                        sub.callback(&entry.notification, sub.context);
                    }
                }
                entry.valid = false;
                processed += 1;
            }
            self.pending_head = (self.pending_head + 1) % max_pending_notifications;
        }

        self.notifications_sent += processed;
        return processed;
    }

    /// Get pending notification count.
    pub fn getPendingCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_tail >= self.pending_head) {
            return self.pending_tail - self.pending_head;
        } else {
            return max_pending_notifications - self.pending_head + self.pending_tail;
        }
    }

    /// Get notification metrics.
    pub fn getNotificationMetrics(self: *Self) struct { sent: u64, failed: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .sent = self.notifications_sent, .failed = self.notifications_failed };
    }
};

// ============================================================================
// JSON Serialization (for REST API / debugging)
// ============================================================================

/// Serialize topology to JSON format.
pub fn topologyToJson(topology: *const TopologyResponse, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    const writer = buffer.writer();

    try writer.writeAll("{\n");
    try writer.print("  \"version\": {d},\n", .{topology.version});
    try writer.print("  \"cluster_id\": \"{x}\",\n", .{topology.cluster_id});
    try writer.print("  \"num_shards\": {d},\n", .{topology.num_shards});
    try writer.print("  \"resharding_status\": {d},\n", .{topology.resharding_status});
    try writer.writeAll("  \"shards\": [\n");

    for (0..topology.num_shards) |i| {
        const shard = &topology.shards[i];
        try writer.writeAll("    {\n");
        try writer.print("      \"id\": {d},\n", .{shard.id});
        try writer.print("      \"primary\": \"{s}\",\n", .{shard.getPrimary()});
        try writer.writeAll("      \"replicas\": [");
        for (0..shard.replica_count) |r| {
            if (r > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{shard.getReplica(@intCast(r)).?});
        }
        try writer.writeAll("],\n");
        try writer.print("      \"status\": \"{s}\",\n", .{shard.status.toString()});
        try writer.print("      \"entity_count\": {d},\n", .{shard.entity_count});
        try writer.print("      \"size_bytes\": {d}\n", .{shard.size_bytes});
        try writer.writeAll("    }");
        if (i < topology.num_shards - 1) try writer.writeAll(",");
        try writer.writeAll("\n");
    }

    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");

    return buffer.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "ShardInfo basic operations" {
    var shard = ShardInfo.init(5);
    try std.testing.expectEqual(@as(u32, 5), shard.id);
    try std.testing.expectEqual(ShardStatus.unavailable, shard.status);
    try std.testing.expectEqual(@as(u8, 0), shard.replica_count);

    shard.setPrimary("192.168.1.10:5000");
    try std.testing.expectEqualStrings("192.168.1.10:5000", shard.getPrimary());

    try std.testing.expect(shard.addReplica("192.168.1.11:5000"));
    try std.testing.expect(shard.addReplica("192.168.1.12:5000"));
    try std.testing.expectEqual(@as(u8, 2), shard.replica_count);
    try std.testing.expectEqualStrings("192.168.1.11:5000", shard.getReplica(0).?);
    try std.testing.expectEqualStrings("192.168.1.12:5000", shard.getReplica(1).?);
    try std.testing.expect(shard.getReplica(2) == null);
}

test "TopologyResponse initialization" {
    var topology = TopologyResponse.init();
    try std.testing.expectEqual(@as(u64, 0), topology.version);
    try std.testing.expectEqual(@as(u32, 0), topology.num_shards);

    topology.num_shards = 4;
    topology.version = 1;

    for (0..4) |i| {
        topology.shards[i].status = .active;
        topology.shards[i].setPrimary("127.0.0.1:5000");
    }

    const shard = topology.getShard(2);
    try std.testing.expect(shard != null);
    try std.testing.expectEqual(@as(u32, 2), shard.?.id);
    try std.testing.expect(topology.getShard(10) == null);
}

test "TopologyResponse computeShard" {
    var topology = TopologyResponse.init();
    topology.num_shards = 8;

    const entity1: u128 = 0x1234567890ABCDEF;
    const entity2: u128 = 0xFEDCBA0987654321;

    const shard1 = topology.computeShard(entity1);
    const shard2 = topology.computeShard(entity2);

    try std.testing.expect(shard1 < 8);
    try std.testing.expect(shard2 < 8);

    // Same entity should always map to same shard
    try std.testing.expectEqual(shard1, topology.computeShard(entity1));
}

test "TopologyManager operations" {
    var manager = TopologyManager.init(0x12345678, 4);
    try std.testing.expectEqual(@as(u64, 1), manager.getVersion());

    const topology = manager.getTopology();
    try std.testing.expectEqual(@as(u32, 4), topology.num_shards);
    try std.testing.expectEqual(@as(u128, 0x12345678), topology.cluster_id);

    // Update shard primary
    try manager.updateShardPrimary(0, "192.168.1.10:5000");
    try std.testing.expectEqual(@as(u64, 2), manager.getVersion());

    // Update shard status
    try manager.updateShardStatus(1, .syncing);
    try std.testing.expectEqual(@as(u64, 3), manager.getVersion());

    // Verify changes
    const updated = manager.getTopology();
    try std.testing.expectEqualStrings("192.168.1.10:5000", updated.shards[0].getPrimary());
    try std.testing.expectEqual(ShardStatus.syncing, updated.shards[1].status);
}

test "TopologyManager invalid shard" {
    var manager = TopologyManager.init(0, 4);

    const result = manager.updateShardPrimary(10, "test");
    try std.testing.expectError(error.InvalidShardId, result);
}

test "TopologyManager resharding status" {
    var manager = TopologyManager.init(0, 8);
    const initial_version = manager.getVersion();

    manager.setReshardingStatus(1); // preparing
    try std.testing.expect(manager.getVersion() > initial_version);
    try std.testing.expectEqual(@as(u8, 1), manager.getTopology().resharding_status);

    manager.setReshardingStatus(0); // idle - no version bump
    try std.testing.expectEqual(@as(u8, 0), manager.getTopology().resharding_status);
}

test "topologyToJson" {
    var topology = TopologyResponse.init();
    topology.version = 42;
    topology.cluster_id = 0xABCD;
    topology.num_shards = 2;

    topology.shards[0].status = .active;
    topology.shards[0].setPrimary("node-0:5000");
    _ = topology.shards[0].addReplica("node-1:5000");
    topology.shards[0].entity_count = 1000;

    topology.shards[1].status = .syncing;
    topology.shards[1].setPrimary("node-2:5000");
    topology.shards[1].entity_count = 1500;

    const json = try topologyToJson(&topology, std.testing.allocator);
    defer std.testing.allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"num_shards\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "node-0:5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"syncing\"") != null);
}

test "ShardStatus toString" {
    try std.testing.expectEqualStrings("active", ShardStatus.active.toString());
    try std.testing.expectEqualStrings("syncing", ShardStatus.syncing.toString());
    try std.testing.expectEqualStrings("unavailable", ShardStatus.unavailable.toString());
    try std.testing.expectEqualStrings("migrating", ShardStatus.migrating.toString());
    try std.testing.expectEqualStrings("decommissioning", ShardStatus.decommissioning.toString());
}

// ============================================================================
// Subscription and Notification Tests (F5.1.3)
// ============================================================================

test "TopologyManager subscribe and unsubscribe" {
    var manager = TopologyManager.init(12345, 4);

    // Track notification count
    const Context = struct {
        count: u32 = 0,

        fn callback(notification: *const TopologyChangeNotification, ctx: ?*anyopaque) void {
            _ = notification;
            if (ctx) |c| {
                const self: *@This() = @ptrCast(@alignCast(c));
                self.count += 1;
            }
        }
    };

    var ctx = Context{};

    // Subscribe
    const id = manager.subscribe(Context.callback, &ctx);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(u32, 1), manager.getSubscriberCount());

    // Unsubscribe
    try std.testing.expect(manager.unsubscribe(id.?));
    try std.testing.expectEqual(@as(u32, 0), manager.getSubscriberCount());

    // Double unsubscribe should fail
    try std.testing.expect(!manager.unsubscribe(id.?));
}

test "TopologyManager notification delivery" {
    var manager = TopologyManager.init(12345, 4);

    const Context = struct {
        count: u32 = 0,
        last_change_type: ?TopologyChangeNotification.ChangeType = null,

        fn callback(notification: *const TopologyChangeNotification, ctx: ?*anyopaque) void {
            if (ctx) |c| {
                const self: *@This() = @ptrCast(@alignCast(c));
                self.count += 1;
                self.last_change_type = notification.change_type;
            }
        }
    };

    var ctx1 = Context{};
    var ctx2 = Context{};

    // Subscribe two handlers
    _ = manager.subscribe(Context.callback, &ctx1);
    _ = manager.subscribe(Context.callback, &ctx2);
    try std.testing.expectEqual(@as(u32, 2), manager.getSubscriberCount());

    // Notify subscribers
    manager.notifySubscribers(.leader_change, 0);

    // Both should have received notification
    try std.testing.expectEqual(@as(u32, 1), ctx1.count);
    try std.testing.expectEqual(@as(u32, 1), ctx2.count);
    try std.testing.expectEqual(TopologyChangeNotification.ChangeType.leader_change, ctx1.last_change_type.?);

    // Verify metrics
    const metrics = manager.getNotificationMetrics();
    try std.testing.expectEqual(@as(u64, 2), metrics.sent);
}

test "TopologyManager pending notification queue" {
    var manager = TopologyManager.init(12345, 4);

    // Queue some notifications
    try std.testing.expect(manager.queueNotification(.resharding_started, 0));
    try std.testing.expect(manager.queueNotification(.resharding_completed, 0));
    try std.testing.expectEqual(@as(usize, 2), manager.getPendingCount());

    const Context = struct {
        count: u32 = 0,

        fn callback(_: *const TopologyChangeNotification, ctx: ?*anyopaque) void {
            if (ctx) |c| {
                const self: *@This() = @ptrCast(@alignCast(c));
                self.count += 1;
            }
        }
    };

    var ctx = Context{};
    _ = manager.subscribe(Context.callback, &ctx);

    // Process pending notifications
    const processed = manager.processPendingNotifications();
    try std.testing.expectEqual(@as(u32, 2), processed);
    try std.testing.expectEqual(@as(u32, 2), ctx.count);
    try std.testing.expectEqual(@as(usize, 0), manager.getPendingCount());
}

test "TopologyChangeNotification toBytes" {
    const notification = TopologyChangeNotification{
        .new_version = 42,
        .old_version = 41,
        .change_type = .leader_change,
        .affected_shard = 3,
        .timestamp_ns = 1234567890,
    };

    const bytes = notification.toBytes();
    try std.testing.expectEqual(@as(usize, 48), bytes.len);

    // Verify version is encoded correctly (little-endian)
    const decoded_version = std.mem.bytesToValue(u64, bytes[0..8]);
    try std.testing.expectEqual(@as(u64, 42), decoded_version);
}
