// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Dynamic cluster membership management.
//!
//! Implements the joint consensus protocol for safe membership changes:
//! - Learner promotion for new node catch-up
//! - Joint consensus for safe quorum transitions
//! - Graceful node removal with drain
//!
//! Reference: Ongaro, Diego. "Consensus: Bridging Theory and Practice" (2014), Chapter 4

const std = @import("std");
const log = std.log.scoped(.membership);
const constants = @import("../constants.zig");
const metrics = @import("../archerdb/metrics.zig");

/// Maximum number of nodes in a cluster configuration.
pub const MAX_NODES = constants.members_max;

/// Membership state - either stable or transitioning via joint consensus.
pub const MembershipState = enum {
    /// Normal operation with a single configuration.
    stable,
    /// Joint consensus: requires majority in BOTH old AND new configurations.
    joint,

    pub fn format(
        self: MembershipState,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(switch (self) {
            .stable => "stable",
            .joint => "joint",
        });
    }
};

/// Role of a node in the cluster.
pub const NodeRole = enum {
    /// New node receiving state transfer, cannot vote.
    learner,
    /// Normal replica, can vote but not be primary.
    follower,
    /// Follower attempting to become primary.
    candidate,
    /// Current cluster primary, coordinates writes.
    primary,

    pub fn canVote(self: NodeRole) bool {
        return self != .learner;
    }

    pub fn canLead(self: NodeRole) bool {
        return self == .primary;
    }

    pub fn format(
        self: NodeRole,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(switch (self) {
            .learner => "learner",
            .follower => "follower",
            .candidate => "candidate",
            .primary => "primary",
        });
    }
};

/// Node status in the cluster.
pub const NodeStatus = enum {
    /// Node is healthy and responsive.
    healthy,
    /// Node is unresponsive but not yet removed.
    unhealthy,
    /// Node is gracefully leaving the cluster.
    leaving,
    /// Node has been removed from cluster.
    removed,

    pub fn format(
        self: NodeStatus,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(switch (self) {
            .healthy => "healthy",
            .unhealthy => "unhealthy",
            .leaving => "leaving",
            .removed => "removed",
        });
    }
};

/// Information about a single node in the cluster.
pub const NodeInfo = struct {
    /// Node identifier (0-based index).
    id: u8,
    /// Current role in consensus protocol.
    role: NodeRole,
    /// Current health status.
    status: NodeStatus,
    /// Address: IP or hostname.
    address: [64]u8,
    /// Address length.
    address_len: u8,
    /// Port number.
    port: u16,
    /// Last known log index (for learner catch-up tracking).
    last_log_index: u64,
    /// Last successful heartbeat timestamp (nanoseconds).
    last_heartbeat_ns: u64,

    pub fn init(id: u8, address: []const u8, port: u16) NodeInfo {
        var info = NodeInfo{
            .id = id,
            .role = .follower,
            .status = .healthy,
            .address = [_]u8{0} ** 64,
            .address_len = @intCast(@min(address.len, 64)),
            .port = port,
            .last_log_index = 0,
            .last_heartbeat_ns = 0,
        };
        // Copy address at runtime (not comptime)
        for (0..info.address_len) |i| {
            info.address[i] = address[i];
        }
        return info;
    }

    pub fn getAddress(self: *const NodeInfo) []const u8 {
        return self.address[0..self.address_len];
    }
};

/// Cluster membership configuration.
pub const MembershipConfig = struct {
    /// Configuration epoch/version (incremented on each change).
    epoch: u64,
    /// Number of nodes in current configuration.
    node_count: u8,
    /// Node information array.
    nodes: [MAX_NODES]NodeInfo,
    /// Current membership state.
    state: MembershipState,
    /// For joint consensus: the new configuration being transitioned to.
    new_config: ?JointConfig,

    /// Joint consensus configuration during transitions.
    pub const JointConfig = struct {
        /// New node count after transition completes.
        node_count: u8,
        /// New node information.
        nodes: [MAX_NODES]NodeInfo,
    };

    /// Initialize a new membership configuration.
    pub fn init(node_count: u8) MembershipConfig {
        return .{
            .epoch = 1,
            .node_count = node_count,
            .nodes = [_]NodeInfo{NodeInfo.init(0, "", 0)} ** MAX_NODES,
            .state = .stable,
            .new_config = null,
        };
    }

    /// Calculate quorum size for current configuration.
    pub fn quorumSize(self: *const MembershipConfig) u8 {
        return (self.node_count / 2) + 1;
    }

    /// Check if we have a quorum with given vote count.
    /// For joint consensus, must have majority in BOTH configurations.
    pub fn hasQuorum(self: *const MembershipConfig, votes: u8) bool {
        const old_quorum = self.quorumSize();
        if (self.state == .joint) {
            if (self.new_config) |new| {
                const new_quorum = (new.node_count / 2) + 1;
                // Must have majority in both old AND new configurations
                return votes >= old_quorum and votes >= new_quorum;
            }
        }
        return votes >= old_quorum;
    }

    /// Check if a specific node can vote (must have voting role AND be healthy).
    pub fn canNodeVote(self: *const MembershipConfig, node_id: u8) bool {
        if (node_id >= self.node_count) return false;
        return self.nodes[node_id].role.canVote() and self.nodes[node_id].status == .healthy;
    }

    /// Get nodes that can vote in the current configuration.
    pub fn getVotingNodes(self: *const MembershipConfig) []const NodeInfo {
        var count: u8 = 0;
        for (0..self.node_count) |i| {
            if (self.nodes[i].role.canVote()) {
                count += 1;
            }
        }
        // Return slice of all nodes (caller filters by role)
        return self.nodes[0..self.node_count];
    }

    /// Begin transition to a new configuration (enter joint consensus).
    pub fn beginTransition(self: *MembershipConfig, new_config: JointConfig) !void {
        if (self.state != .stable) {
            return error.AlreadyInTransition;
        }
        self.state = .joint;
        self.new_config = new_config;
        self.epoch += 1;
        log.info("begun membership transition, epoch={}, old_nodes={}, new_nodes={}", .{
            self.epoch,
            self.node_count,
            new_config.node_count,
        });

        // Update metrics.
        metrics.Registry.membership_state.set(1); // joint
        metrics.Registry.membership_transitions_in_progress.set(1);
        metrics.Registry.membership_transition_progress.set(0);
        metrics.Registry.membership_changes_total.inc();
    }

    /// Complete transition to new configuration (exit joint consensus).
    pub fn completeTransition(self: *MembershipConfig) !void {
        if (self.state != .joint) {
            return error.NotInTransition;
        }
        if (self.new_config) |new| {
            self.node_count = new.node_count;
            self.nodes = new.nodes;
            self.state = .stable;
            self.new_config = null;
            self.epoch += 1;
            log.info("completed membership transition, epoch={}, nodes={}", .{
                self.epoch,
                self.node_count,
            });

            // Update metrics.
            metrics.Registry.membership_state.set(0); // stable
            metrics.Registry.membership_transitions_in_progress.set(0);
            metrics.Registry.membership_transition_progress.set(10000); // 100%
            self.updateNodeMetrics();
        } else {
            return error.NoNewConfig;
        }
    }

    /// Abort transition and revert to old configuration.
    pub fn abortTransition(self: *MembershipConfig) void {
        if (self.state == .joint) {
            self.state = .stable;
            self.new_config = null;
            log.warn("aborted membership transition, epoch={}", .{self.epoch});

            // Update metrics.
            metrics.Registry.membership_state.set(0); // stable
            metrics.Registry.membership_transitions_in_progress.set(0);
        }
    }

    /// Add a new node as a learner.
    pub fn addLearner(self: *MembershipConfig, address: []const u8, port: u16) !u8 {
        if (self.node_count >= MAX_NODES) {
            return error.ClusterFull;
        }
        if (self.state != .stable) {
            return error.TransitionInProgress;
        }

        const new_id = self.node_count;
        var node = NodeInfo.init(new_id, address, port);
        node.role = .learner;
        node.status = .healthy;

        self.nodes[new_id] = node;
        self.node_count += 1;
        self.epoch += 1;

        log.info("added learner node, id={}, address={s}:{}, epoch={}", .{
            new_id,
            address,
            port,
            self.epoch,
        });

        // Update metrics.
        self.updateNodeMetrics();
        metrics.Registry.membership_changes_total.inc();

        return new_id;
    }

    /// Promote a learner to follower (once caught up).
    pub fn promoteLearner(self: *MembershipConfig, node_id: u8) !void {
        if (node_id >= self.node_count) {
            return error.InvalidNodeId;
        }
        if (self.nodes[node_id].role != .learner) {
            return error.NotALearner;
        }

        // Create joint config with promoted node
        var new_config = MembershipConfig.JointConfig{
            .node_count = self.node_count,
            .nodes = self.nodes,
        };
        new_config.nodes[node_id].role = .follower;

        try self.beginTransition(new_config);
        log.info("promoting learner to follower, id={}", .{node_id});

        // Update metrics.
        metrics.Registry.membership_promotions_total.inc();
    }

    /// Mark a node as leaving (begin graceful removal).
    pub fn beginNodeRemoval(self: *MembershipConfig, node_id: u8) !void {
        if (node_id >= self.node_count) {
            return error.InvalidNodeId;
        }
        if (self.state != .stable) {
            return error.TransitionInProgress;
        }
        if (self.node_count <= 1) {
            return error.CannotRemoveLastNode;
        }

        self.nodes[node_id].status = .leaving;

        // Create new config without the node
        var new_nodes: [MAX_NODES]NodeInfo = [_]NodeInfo{NodeInfo.init(0, "", 0)} ** MAX_NODES;
        var new_count: u8 = 0;

        for (0..self.node_count) |i| {
            if (i != node_id) {
                new_nodes[new_count] = self.nodes[i];
                new_nodes[new_count].id = new_count;
                new_count += 1;
            }
        }

        try self.beginTransition(.{
            .node_count = new_count,
            .nodes = new_nodes,
        });

        log.info("begun node removal, id={}, remaining_nodes={}", .{ node_id, new_count });

        // Update metrics.
        metrics.Registry.membership_removals_total.inc();
    }

    /// Update node's last log index (for learner catch-up tracking).
    pub fn updateNodeProgress(self: *MembershipConfig, node_id: u8, log_index: u64) void {
        if (node_id < self.node_count) {
            self.nodes[node_id].last_log_index = log_index;
        }
    }

    /// Update node's heartbeat timestamp.
    pub fn updateHeartbeat(self: *MembershipConfig, node_id: u8, timestamp_ns: u64) void {
        if (node_id < self.node_count) {
            self.nodes[node_id].last_heartbeat_ns = timestamp_ns;
        }
    }

    /// Mark a node as unhealthy.
    pub fn markUnhealthy(self: *MembershipConfig, node_id: u8) void {
        if (node_id < self.node_count) {
            self.nodes[node_id].status = .unhealthy;
            log.warn("marked node unhealthy, id={}", .{node_id});
        }
    }

    /// Mark a node as healthy.
    pub fn markHealthy(self: *MembershipConfig, node_id: u8) void {
        if (node_id < self.node_count) {
            if (self.nodes[node_id].status == .unhealthy) {
                self.nodes[node_id].status = .healthy;
                log.info("marked node healthy, id={}", .{node_id});
            }
        }
    }

    /// Check if a learner is sufficiently caught up for promotion.
    /// Learner should be within `max_lag` entries of the primary.
    pub fn isLearnerCaughtUp(
        self: *const MembershipConfig,
        node_id: u8,
        primary_log_index: u64,
        max_lag: u64,
    ) bool {
        if (node_id >= self.node_count) return false;
        if (self.nodes[node_id].role != .learner) return false;

        const learner_index = self.nodes[node_id].last_log_index;
        if (primary_log_index <= max_lag) {
            return learner_index >= primary_log_index;
        }
        return learner_index >= (primary_log_index - max_lag);
    }

    /// Update node count metrics based on current configuration.
    fn updateNodeMetrics(self: *const MembershipConfig) void {
        var voters: i64 = 0;
        var learners: i64 = 0;

        for (0..self.node_count) |i| {
            switch (self.nodes[i].role) {
                .learner => learners += 1,
                .follower, .candidate, .primary => voters += 1,
            }
        }

        metrics.Registry.membership_voters_count.set(voters);
        metrics.Registry.membership_learners_count.set(learners);
    }

    /// Publish the current membership state and node counts to process metrics.
    pub fn publishMetrics(self: *const MembershipConfig) void {
        metrics.Registry.membership_state.set(switch (self.state) {
            .stable => 0,
            .joint => 1,
        });
        self.updateNodeMetrics();
    }

    /// Check if removing a node would require a view change.
    /// Returns true if the node being removed is the current primary.
    pub fn requiresViewChangeForRemoval(self: *const MembershipConfig, node_id: u8) bool {
        if (node_id >= self.node_count) return false;
        return self.nodes[node_id].role == .primary;
    }

    /// Get the node ID of the current primary, if any.
    pub fn getPrimaryId(self: *const MembershipConfig) ?u8 {
        for (0..self.node_count) |i| {
            if (self.nodes[i].role == .primary) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Get the number of healthy voters in the current configuration.
    pub fn getHealthyVoterCount(self: *const MembershipConfig) u8 {
        var count: u8 = 0;
        for (0..self.node_count) |i| {
            if (self.nodes[i].role.canVote() and self.nodes[i].status == .healthy) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if the cluster has quorum with current healthy voters.
    pub fn hasHealthyQuorum(self: *const MembershipConfig) bool {
        return self.hasQuorum(self.getHealthyVoterCount());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MembershipState: formatting" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try stream.writer().print("{}", .{MembershipState.stable});
    try std.testing.expectEqualStrings("stable", stream.getWritten());
}

test "NodeRole: canVote" {
    try std.testing.expect(!NodeRole.learner.canVote());
    try std.testing.expect(NodeRole.follower.canVote());
    try std.testing.expect(NodeRole.candidate.canVote());
    try std.testing.expect(NodeRole.primary.canVote());
}

test "NodeRole: canLead" {
    try std.testing.expect(!NodeRole.learner.canLead());
    try std.testing.expect(!NodeRole.follower.canLead());
    try std.testing.expect(!NodeRole.candidate.canLead());
    try std.testing.expect(NodeRole.primary.canLead());
}

test "NodeInfo: initialization" {
    const node = NodeInfo.init(1, "192.168.1.1", 3000);
    try std.testing.expectEqual(@as(u8, 1), node.id);
    try std.testing.expectEqual(NodeRole.follower, node.role);
    try std.testing.expectEqual(NodeStatus.healthy, node.status);
    try std.testing.expectEqualStrings("192.168.1.1", node.getAddress());
    try std.testing.expectEqual(@as(u16, 3000), node.port);
}

test "MembershipConfig: quorum calculation" {
    var config = MembershipConfig.init(3);
    try std.testing.expectEqual(@as(u8, 2), config.quorumSize());

    config.node_count = 5;
    try std.testing.expectEqual(@as(u8, 3), config.quorumSize());

    config.node_count = 7;
    try std.testing.expectEqual(@as(u8, 4), config.quorumSize());
}

test "MembershipConfig: hasQuorum stable" {
    var config = MembershipConfig.init(3);
    try std.testing.expect(!config.hasQuorum(0));
    try std.testing.expect(!config.hasQuorum(1));
    try std.testing.expect(config.hasQuorum(2));
    try std.testing.expect(config.hasQuorum(3));
}

test "MembershipConfig: addLearner" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
    }

    const learner_id = try config.addLearner("192.168.1.10", 3003);
    try std.testing.expectEqual(@as(u8, 3), learner_id);
    try std.testing.expectEqual(@as(u8, 4), config.node_count);
    try std.testing.expectEqual(NodeRole.learner, config.nodes[learner_id].role);
    try std.testing.expectEqualStrings("192.168.1.10", config.nodes[learner_id].getAddress());
}

test "MembershipConfig: joint consensus quorum" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        config.nodes[i].role = .follower;
    }

    // Start transition to 5-node cluster
    var new_nodes: [MAX_NODES]NodeInfo = [_]NodeInfo{NodeInfo.init(0, "", 0)} ** MAX_NODES;
    for (0..5) |i| {
        new_nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        new_nodes[i].role = .follower;
    }

    try config.beginTransition(.{
        .node_count = 5,
        .nodes = new_nodes,
    });

    try std.testing.expectEqual(MembershipState.joint, config.state);

    // In joint consensus: need majority in both old (2/3) AND new (3/5)
    try std.testing.expect(!config.hasQuorum(1)); // 1 is not majority in old (2) or new (3)
    try std.testing.expect(!config.hasQuorum(2)); // 2 is majority in old but not new (3)
    try std.testing.expect(config.hasQuorum(3)); // 3 is majority in both old (2) and new (3)
}

test "MembershipConfig: complete transition" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
    }

    var new_nodes: [MAX_NODES]NodeInfo = [_]NodeInfo{NodeInfo.init(0, "", 0)} ** MAX_NODES;
    for (0..5) |i| {
        new_nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
    }

    try config.beginTransition(.{ .node_count = 5, .nodes = new_nodes });
    try config.completeTransition();

    try std.testing.expectEqual(MembershipState.stable, config.state);
    try std.testing.expectEqual(@as(u8, 5), config.node_count);
    try std.testing.expect(config.new_config == null);
}

test "MembershipConfig: learner caught up detection" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
    }

    const learner_id = try config.addLearner("192.168.1.10", 3003);

    // Primary is at index 1000, learner is at 0
    try std.testing.expect(!config.isLearnerCaughtUp(learner_id, 1000, 100));

    // Update learner progress to 950 (within 100 of 1000)
    config.updateNodeProgress(learner_id, 950);
    try std.testing.expect(config.isLearnerCaughtUp(learner_id, 1000, 100));

    // Learner at 899 is not caught up (more than 100 behind)
    config.updateNodeProgress(learner_id, 899);
    try std.testing.expect(!config.isLearnerCaughtUp(learner_id, 1000, 100));
}

test "MembershipConfig: node removal" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
    }

    try config.beginNodeRemoval(1);

    try std.testing.expectEqual(MembershipState.joint, config.state);
    try std.testing.expectEqual(NodeStatus.leaving, config.nodes[1].status);

    if (config.new_config) |new| {
        try std.testing.expectEqual(@as(u8, 2), new.node_count);
    } else {
        return error.ExpectedNewConfig;
    }

    try config.completeTransition();
    try std.testing.expectEqual(@as(u8, 2), config.node_count);
}

test "MembershipConfig: requiresViewChangeForRemoval" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        config.nodes[i].role = .follower;
    }

    // Set node 0 as primary
    config.nodes[0].role = .primary;

    // Removing primary should require view change
    try std.testing.expect(config.requiresViewChangeForRemoval(0));

    // Removing follower should not require view change
    try std.testing.expect(!config.requiresViewChangeForRemoval(1));
    try std.testing.expect(!config.requiresViewChangeForRemoval(2));

    // Invalid node ID should return false
    try std.testing.expect(!config.requiresViewChangeForRemoval(5));
}

test "MembershipConfig: getPrimaryId" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        config.nodes[i].role = .follower;
    }

    // No primary initially
    try std.testing.expect(config.getPrimaryId() == null);

    // Set node 1 as primary
    config.nodes[1].role = .primary;
    try std.testing.expectEqual(@as(?u8, 1), config.getPrimaryId());
}

test "MembershipConfig: canNodeVote" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        config.nodes[i].role = .follower;
        config.nodes[i].status = .healthy;
    }

    // Healthy follower can vote
    try std.testing.expect(config.canNodeVote(0));

    // Unhealthy follower cannot vote
    config.nodes[1].status = .unhealthy;
    try std.testing.expect(!config.canNodeVote(1));

    // Learner cannot vote even if healthy
    const learner_id = try config.addLearner("192.168.1.10", 3003);
    try std.testing.expect(!config.canNodeVote(learner_id));
}

test "MembershipConfig: getHealthyVoterCount and hasHealthyQuorum" {
    var config = MembershipConfig.init(3);
    for (0..3) |i| {
        config.nodes[i] = NodeInfo.init(@intCast(i), "localhost", 3000 + @as(u16, @intCast(i)));
        config.nodes[i].role = .follower;
        config.nodes[i].status = .healthy;
    }

    // All 3 healthy voters
    try std.testing.expectEqual(@as(u8, 3), config.getHealthyVoterCount());
    try std.testing.expect(config.hasHealthyQuorum()); // 3 >= 2 (majority of 3)

    // Mark one unhealthy
    config.nodes[0].status = .unhealthy;
    try std.testing.expectEqual(@as(u8, 2), config.getHealthyVoterCount());
    try std.testing.expect(config.hasHealthyQuorum()); // 2 >= 2

    // Mark another unhealthy - now no quorum
    config.nodes[1].status = .unhealthy;
    try std.testing.expectEqual(@as(u8, 1), config.getHealthyVoterCount());
    try std.testing.expect(!config.hasHealthyQuorum()); // 1 < 2
}
