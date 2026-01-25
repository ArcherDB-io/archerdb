// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//!
//! # Flexible Paxos: Configurable Quorums for Consensus
//!
//! This module implements Flexible Paxos quorum configuration, enabling reduced
//! commit latency through asymmetric quorum sizes.
//!
//! ## Background: Classic Paxos
//!
//! Classic Paxos requires majority quorums for both phases:
//! - Phase 1 (Prepare): Leader election, requires votes from > N/2 nodes
//! - Phase 2 (Accept): Commit, requires acknowledgments from > N/2 nodes
//!
//! For a 5-node cluster, this means Q1 = Q2 = 3 (majority).
//!
//! ## Flexible Paxos Insight
//!
//! Howard, Malkhi, and Spiegelman (2016) showed that the only requirement for
//! safety is that phase-1 and phase-2 quorums INTERSECT. Formally:
//!
//!     **Invariant: Q1 + Q2 > N**
//!
//! This ensures that any committed value is seen by any subsequent leader.
//! Classic Paxos is a special case where Q1 = Q2 = ceil((N+1)/2).
//!
//! ## Tradeoff Spectrum
//!
//! By varying Q1 and Q2 while maintaining Q1 + Q2 > N, we can optimize for
//! different workloads:
//!
//! ```text
//! Classic (N=5):      Fast Commit (N=5):     Strong Leader (N=5):
//!   Q1=3, Q2=3          Q1=4, Q2=2             Q1=5, Q2=1
//!   Election: 3/5       Election: 4/5          Election: 5/5
//!   Commit: 3/5         Commit: 2/5            Commit: 1/5
//! ```
//!
//! | Preset        | Q1      | Q2        | Commit Latency | Election Availability |
//! |---------------|---------|-----------|----------------|----------------------|
//! | Classic       | N/2 + 1 | N/2 + 1   | Medium         | Good                 |
//! | Fast Commit   | High    | Low       | Low            | Reduced              |
//! | Strong Leader | N       | 1         | Lowest         | Requires all nodes   |
//!
//! ## When to Use Each Preset
//!
//! - **Classic**: Default choice. Balanced performance. Safe for most deployments.
//!   Best when leader elections and commits are equally important.
//!
//! - **Fast Commit**: When commit latency is critical and leader elections are
//!   rare (stable leaders). Good for steady-state write-heavy workloads.
//!   Trade-off: Slower recovery when leader fails.
//!
//! - **Strong Leader**: Single datacenter deployments where all nodes are always
//!   available. Extreme commit speed (single ack). WARNING: If ANY node is down,
//!   leader election is impossible. Only use when you have strong availability
//!   guarantees for all replicas.
//!
//! ## Usage Example
//!
//! ```zig
//! const config = QuorumConfig.fast_commit(5);
//! try config.validate();
//! const paxos = FlexiblePaxos{ .config = config };
//! if (paxos.hasPhase2Quorum(ack_count)) { /* commit */ }
//! ```
//!
//! ## Reference
//!
//! Howard, H., Malkhi, D., & Spiegelman, A. (2016). "Flexible Paxos: Quorum
//! Intersection Revisited." arXiv:1608.06696.
//!
//! See also: superblock_quorums.zig for related flexible quorum usage in
//! superblock storage.

const std = @import("std");
const log = std.log.scoped(.flexible_paxos);

/// Error types for quorum configuration validation.
pub const QuorumError = error{
    /// Q1 + Q2 must be greater than N for quorum intersection.
    InvalidQuorumIntersection,
    /// Q1 and Q2 must be positive (at least 1).
    InvalidQuorumZero,
    /// Q1 and Q2 cannot exceed cluster size N.
    InvalidQuorumExceedsCluster,
    /// Cluster size must be at least 1.
    InvalidClusterSize,
};

/// Quorum configuration for Flexible Paxos.
///
/// Defines the cluster size N and independent quorum sizes for phase-1 (leader
/// election) and phase-2 (commit). The invariant Q1 + Q2 > N must hold.
pub const QuorumConfig = struct {
    const Self = @This();

    /// N: Total number of replicas in the cluster.
    cluster_size: u8,
    /// Q1: Quorum size for phase-1 (leader election/prepare).
    phase1_quorum: u8,
    /// Q2: Quorum size for phase-2 (commit/accept).
    phase2_quorum: u8,

    // Preset constructors (aliases for QuorumPreset functions)
    pub const classic = QuorumPreset.classic;
    pub const fast_commit = QuorumPreset.fast_commit;
    pub const strong_leader = QuorumPreset.strong_leader;

    /// Validate that this configuration satisfies the Flexible Paxos invariant.
    ///
    /// Returns an error if:
    /// - Q1 + Q2 <= N (quorums don't intersect)
    /// - Q1 or Q2 is 0
    /// - Q1 or Q2 exceeds N
    /// - N is 0
    pub fn validate(self: *const Self) QuorumError!void {
        // Cluster size must be positive
        if (self.cluster_size == 0) {
            return QuorumError.InvalidClusterSize;
        }

        // Q1 and Q2 must be positive
        if (self.phase1_quorum == 0 or self.phase2_quorum == 0) {
            return QuorumError.InvalidQuorumZero;
        }

        // Q1 and Q2 cannot exceed N
        if (self.phase1_quorum > self.cluster_size or self.phase2_quorum > self.cluster_size) {
            return QuorumError.InvalidQuorumExceedsCluster;
        }

        // Core Flexible Paxos invariant: Q1 + Q2 > N
        // This ensures phase-1 and phase-2 quorums always intersect.
        if (@as(u16, self.phase1_quorum) + @as(u16, self.phase2_quorum) <= @as(u16, self.cluster_size)) {
            return QuorumError.InvalidQuorumIntersection;
        }
    }

    /// Calculate the classic majority quorum size for a given cluster size.
    /// majority(N) = floor(N/2) + 1
    pub fn majority(cluster_size: u8) u8 {
        if (cluster_size == 0) return 0;
        return (cluster_size / 2) + 1;
    }

    /// Returns the fault tolerance for phase-1 (how many nodes can fail and
    /// still achieve Q1).
    pub fn phase1FaultTolerance(self: *const Self) u8 {
        return self.cluster_size - self.phase1_quorum;
    }

    /// Returns the fault tolerance for phase-2 (how many nodes can fail and
    /// still achieve Q2).
    pub fn phase2FaultTolerance(self: *const Self) u8 {
        return self.cluster_size - self.phase2_quorum;
    }

    /// Format the configuration for logging.
    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("QuorumConfig(N={}, Q1={}, Q2={})", .{
            self.cluster_size,
            self.phase1_quorum,
            self.phase2_quorum,
        });
    }
};

/// Preset quorum configurations for common use cases.
///
/// These presets provide sensible defaults while maintaining the Flexible Paxos
/// invariant (Q1 + Q2 > N).
pub const QuorumPreset = struct {
    /// Classic Paxos: Q1 = Q2 = majority.
    ///
    /// Balanced performance for both leader election and commits.
    /// This is the safest default for most deployments.
    ///
    /// For N=5: Q1=3, Q2=3
    /// Fault tolerance: 2 nodes for both phases.
    pub fn classic(n: u8) QuorumConfig {
        const maj = QuorumConfig.majority(n);
        return .{
            .cluster_size = n,
            .phase1_quorum = maj,
            .phase2_quorum = maj,
        };
    }

    /// Fast Commit: Reduced Q2 for lower commit latency.
    ///
    /// Optimizes for write-heavy workloads with stable leaders.
    /// Leader election is slower, but commits are faster.
    ///
    /// For N=5: Q1=4, Q2=2 (commit needs only 2 acks!)
    /// Trade-off: If leader fails, need 4/5 nodes for new election.
    ///
    /// Note: For N < 3, falls back to classic quorums.
    pub fn fast_commit(n: u8) QuorumConfig {
        if (n < 3) {
            // For tiny clusters, can't reduce Q2 meaningfully
            return classic(n);
        }

        const maj = QuorumConfig.majority(n);
        // Reduce Q2 by 1, but ensure Q2 >= 1
        const q2 = if (maj > 1) maj - 1 else 1;
        // Increase Q1 to maintain Q1 + Q2 > N
        // We need Q1 > N - Q2, so Q1 >= N - Q2 + 1
        const q1 = n - q2 + 1;

        return .{
            .cluster_size = n,
            .phase1_quorum = q1,
            .phase2_quorum = q2,
        };
    }

    /// Strong Leader: Q1 = N (unanimous), Q2 = 1 (single replica).
    ///
    /// Maximum commit speed - only one ack needed to commit!
    /// However, leader election requires ALL nodes to be available.
    ///
    /// WARNING: This is an extreme configuration. If ANY node is unavailable,
    /// the cluster cannot elect a new leader. Only use in environments where
    /// all nodes are guaranteed to be available (single datacenter, strong SLAs).
    ///
    /// For N=5: Q1=5, Q2=1
    /// Trade-off: Zero tolerance for failures during leader election.
    pub fn strong_leader(n: u8) QuorumConfig {
        return .{
            .cluster_size = n,
            .phase1_quorum = n, // Unanimous
            .phase2_quorum = 1, // Single ack
        };
    }
};

/// Flexible Paxos consensus helper.
///
/// Wraps a QuorumConfig and provides convenient methods for checking quorum
/// conditions during consensus protocol execution.
pub const FlexiblePaxos = struct {
    const Self = @This();

    /// The quorum configuration for this instance.
    config: QuorumConfig,

    /// Check if we have achieved phase-1 quorum (leader election).
    ///
    /// Returns true if `votes >= Q1`.
    pub fn hasPhase1Quorum(self: *const Self, votes: u8) bool {
        return votes >= self.config.phase1_quorum;
    }

    /// Check if we have achieved phase-2 quorum (commit).
    ///
    /// Returns true if `acks >= Q2`.
    pub fn hasPhase2Quorum(self: *const Self, acks: u8) bool {
        return acks >= self.config.phase2_quorum;
    }

    /// Get the number of additional votes needed to achieve phase-1 quorum.
    /// Returns 0 if quorum is already achieved.
    pub fn votesNeeded(self: *const Self, current_votes: u8) u8 {
        if (current_votes >= self.config.phase1_quorum) return 0;
        return self.config.phase1_quorum - current_votes;
    }

    /// Get the number of additional acks needed to achieve phase-2 quorum.
    /// Returns 0 if quorum is already achieved.
    pub fn acksNeeded(self: *const Self, current_acks: u8) u8 {
        if (current_acks >= self.config.phase2_quorum) return 0;
        return self.config.phase2_quorum - current_acks;
    }

    /// Log the current configuration.
    pub fn logConfig(self: *const Self) void {
        log.info("Flexible Paxos: N={}, Q1={} (election), Q2={} (commit), " ++
            "phase1_tolerance={}, phase2_tolerance={}", .{
            self.config.cluster_size,
            self.config.phase1_quorum,
            self.config.phase2_quorum,
            self.config.phase1FaultTolerance(),
            self.config.phase2FaultTolerance(),
        });
    }
};

/// Validate a quorum configuration.
///
/// Standalone validation function for use without a QuorumConfig instance.
/// Verifies the Flexible Paxos invariant: Q1 + Q2 > N.
pub fn validateQuorums(config: QuorumConfig) QuorumError!void {
    return config.validate();
}

// =============================================================================
// Tests
// =============================================================================

test "QuorumConfig.majority: calculates floor(N/2) + 1" {
    // Standard cluster sizes
    try std.testing.expectEqual(@as(u8, 1), QuorumConfig.majority(1)); // Single node
    try std.testing.expectEqual(@as(u8, 2), QuorumConfig.majority(2)); // 2-node (not recommended)
    try std.testing.expectEqual(@as(u8, 2), QuorumConfig.majority(3)); // 3-node
    try std.testing.expectEqual(@as(u8, 3), QuorumConfig.majority(4)); // 4-node
    try std.testing.expectEqual(@as(u8, 3), QuorumConfig.majority(5)); // 5-node
    try std.testing.expectEqual(@as(u8, 4), QuorumConfig.majority(6)); // 6-node
    try std.testing.expectEqual(@as(u8, 4), QuorumConfig.majority(7)); // 7-node

    // Edge case
    try std.testing.expectEqual(@as(u8, 0), QuorumConfig.majority(0));
}

test "QuorumPreset.classic: produces majority quorums" {
    // Table-driven tests for common cluster sizes
    const TestCase = struct { n: u8, expected_q1: u8, expected_q2: u8 };
    const test_cases = [_]TestCase{
        .{ .n = 1, .expected_q1 = 1, .expected_q2 = 1 },
        .{ .n = 2, .expected_q1 = 2, .expected_q2 = 2 },
        .{ .n = 3, .expected_q1 = 2, .expected_q2 = 2 },
        .{ .n = 5, .expected_q1 = 3, .expected_q2 = 3 },
        .{ .n = 7, .expected_q1 = 4, .expected_q2 = 4 },
    };

    for (test_cases) |tc| {
        const config = QuorumPreset.classic(tc.n);
        try std.testing.expectEqual(tc.n, config.cluster_size);
        try std.testing.expectEqual(tc.expected_q1, config.phase1_quorum);
        try std.testing.expectEqual(tc.expected_q2, config.phase2_quorum);

        // All classic presets should pass validation
        try config.validate();
    }
}

test "QuorumPreset.fast_commit: reduces Q2 and increases Q1" {
    // Table from plan: | N | Classic Q1 | Classic Q2 | Fast Q2 | Fast Q1 |
    const TestCase = struct { n: u8, expected_q1: u8, expected_q2: u8 };
    const test_cases = [_]TestCase{
        // N=3: Classic Q1=2, Q2=2 -> Fast Q1=3, Q2=1 (need Q1+Q2 > 3, so 3+1=4 > 3)
        .{ .n = 3, .expected_q1 = 3, .expected_q2 = 1 },
        // N=5: Classic Q1=3, Q2=3 -> Fast Q1=4, Q2=2 (need Q1+Q2 > 5, so 4+2=6 > 5)
        .{ .n = 5, .expected_q1 = 4, .expected_q2 = 2 },
        // N=7: Classic Q1=4, Q2=4 -> Fast Q1=5, Q2=3 (need Q1+Q2 > 7, so 5+3=8 > 7)
        .{ .n = 7, .expected_q1 = 5, .expected_q2 = 3 },
    };

    for (test_cases) |tc| {
        const config = QuorumPreset.fast_commit(tc.n);
        try std.testing.expectEqual(tc.n, config.cluster_size);
        try std.testing.expectEqual(tc.expected_q1, config.phase1_quorum);
        try std.testing.expectEqual(tc.expected_q2, config.phase2_quorum);

        // All fast_commit presets should pass validation
        try config.validate();

        // Q2 should be less than classic Q2
        const classic = QuorumPreset.classic(tc.n);
        try std.testing.expect(config.phase2_quorum < classic.phase2_quorum);
        // Q1 should be greater than classic Q1
        try std.testing.expect(config.phase1_quorum > classic.phase1_quorum);
    }
}

test "QuorumPreset.fast_commit: falls back to classic for small N" {
    // For N < 3, fast_commit should equal classic
    for ([_]u8{ 1, 2 }) |n| {
        const fast = QuorumPreset.fast_commit(n);
        const classic = QuorumPreset.classic(n);
        try std.testing.expectEqual(classic.phase1_quorum, fast.phase1_quorum);
        try std.testing.expectEqual(classic.phase2_quorum, fast.phase2_quorum);
    }
}

test "QuorumPreset.strong_leader: Q1=N, Q2=1" {
    const test_sizes = [_]u8{ 1, 3, 5, 7 };

    for (test_sizes) |n| {
        const config = QuorumPreset.strong_leader(n);
        try std.testing.expectEqual(n, config.cluster_size);
        try std.testing.expectEqual(n, config.phase1_quorum); // Unanimous
        try std.testing.expectEqual(@as(u8, 1), config.phase2_quorum); // Single ack

        // Should pass validation
        try config.validate();
    }
}

test "QuorumConfig.validate: passes for valid configurations" {
    // All presets should be valid
    for ([_]u8{ 1, 2, 3, 5, 7 }) |n| {
        try QuorumPreset.classic(n).validate();
        try QuorumPreset.fast_commit(n).validate();
        try QuorumPreset.strong_leader(n).validate();
    }

    // Custom valid configurations
    const valid_configs = [_]QuorumConfig{
        .{ .cluster_size = 5, .phase1_quorum = 3, .phase2_quorum = 3 }, // Classic
        .{ .cluster_size = 5, .phase1_quorum = 4, .phase2_quorum = 2 }, // Fast
        .{ .cluster_size = 5, .phase1_quorum = 5, .phase2_quorum = 1 }, // Strong
        .{ .cluster_size = 5, .phase1_quorum = 3, .phase2_quorum = 4 }, // Asymmetric
        .{ .cluster_size = 5, .phase1_quorum = 2, .phase2_quorum = 4 }, // Q1+Q2=6>5
    };

    for (valid_configs) |config| {
        try config.validate();
    }
}

test "QuorumConfig.validate: fails when Q1 + Q2 <= N" {
    const invalid_configs = [_]QuorumConfig{
        .{ .cluster_size = 5, .phase1_quorum = 2, .phase2_quorum = 2 }, // 2+2=4 <= 5
        .{ .cluster_size = 5, .phase1_quorum = 2, .phase2_quorum = 3 }, // 2+3=5 <= 5
        .{ .cluster_size = 5, .phase1_quorum = 1, .phase2_quorum = 2 }, // 1+2=3 <= 5
        .{ .cluster_size = 7, .phase1_quorum = 3, .phase2_quorum = 3 }, // 3+3=6 <= 7
        .{ .cluster_size = 7, .phase1_quorum = 3, .phase2_quorum = 4 }, // 3+4=7 <= 7
    };

    for (invalid_configs) |config| {
        try std.testing.expectError(QuorumError.InvalidQuorumIntersection, config.validate());
    }
}

test "QuorumConfig.validate: fails when Q1 or Q2 is zero" {
    const zero_q1 = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 0, .phase2_quorum = 3 };
    try std.testing.expectError(QuorumError.InvalidQuorumZero, zero_q1.validate());

    const zero_q2 = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 3, .phase2_quorum = 0 };
    try std.testing.expectError(QuorumError.InvalidQuorumZero, zero_q2.validate());

    const both_zero = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 0, .phase2_quorum = 0 };
    try std.testing.expectError(QuorumError.InvalidQuorumZero, both_zero.validate());
}

test "QuorumConfig.validate: fails when Q1 or Q2 exceeds N" {
    const q1_exceeds = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 6, .phase2_quorum = 3 };
    try std.testing.expectError(QuorumError.InvalidQuorumExceedsCluster, q1_exceeds.validate());

    const q2_exceeds = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 3, .phase2_quorum = 6 };
    try std.testing.expectError(QuorumError.InvalidQuorumExceedsCluster, q2_exceeds.validate());

    const both_exceed = QuorumConfig{ .cluster_size = 3, .phase1_quorum = 5, .phase2_quorum = 5 };
    try std.testing.expectError(QuorumError.InvalidQuorumExceedsCluster, both_exceed.validate());
}

test "QuorumConfig.validate: fails when N is zero" {
    const zero_n = QuorumConfig{ .cluster_size = 0, .phase1_quorum = 1, .phase2_quorum = 1 };
    try std.testing.expectError(QuorumError.InvalidClusterSize, zero_n.validate());
}

test "FlexiblePaxos.hasPhase1Quorum: returns true when votes >= Q1" {
    const config = QuorumPreset.classic(5); // Q1=3
    const paxos = FlexiblePaxos{ .config = config };

    try std.testing.expect(!paxos.hasPhase1Quorum(0));
    try std.testing.expect(!paxos.hasPhase1Quorum(1));
    try std.testing.expect(!paxos.hasPhase1Quorum(2));
    try std.testing.expect(paxos.hasPhase1Quorum(3)); // Exactly Q1
    try std.testing.expect(paxos.hasPhase1Quorum(4)); // Above Q1
    try std.testing.expect(paxos.hasPhase1Quorum(5)); // All nodes
}

test "FlexiblePaxos.hasPhase2Quorum: returns true when acks >= Q2" {
    const config = QuorumPreset.fast_commit(5); // Q2=2
    const paxos = FlexiblePaxos{ .config = config };

    try std.testing.expect(!paxos.hasPhase2Quorum(0));
    try std.testing.expect(!paxos.hasPhase2Quorum(1));
    try std.testing.expect(paxos.hasPhase2Quorum(2)); // Exactly Q2
    try std.testing.expect(paxos.hasPhase2Quorum(3)); // Above Q2
    try std.testing.expect(paxos.hasPhase2Quorum(4));
    try std.testing.expect(paxos.hasPhase2Quorum(5));
}

test "FlexiblePaxos.votesNeeded and acksNeeded" {
    const config = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 4, .phase2_quorum = 2 };
    const paxos = FlexiblePaxos{ .config = config };

    // Votes needed for phase-1 (Q1=4)
    try std.testing.expectEqual(@as(u8, 4), paxos.votesNeeded(0));
    try std.testing.expectEqual(@as(u8, 3), paxos.votesNeeded(1));
    try std.testing.expectEqual(@as(u8, 2), paxos.votesNeeded(2));
    try std.testing.expectEqual(@as(u8, 1), paxos.votesNeeded(3));
    try std.testing.expectEqual(@as(u8, 0), paxos.votesNeeded(4)); // At quorum
    try std.testing.expectEqual(@as(u8, 0), paxos.votesNeeded(5)); // Above quorum

    // Acks needed for phase-2 (Q2=2)
    try std.testing.expectEqual(@as(u8, 2), paxos.acksNeeded(0));
    try std.testing.expectEqual(@as(u8, 1), paxos.acksNeeded(1));
    try std.testing.expectEqual(@as(u8, 0), paxos.acksNeeded(2)); // At quorum
    try std.testing.expectEqual(@as(u8, 0), paxos.acksNeeded(3)); // Above quorum
}

test "QuorumConfig.phase1FaultTolerance and phase2FaultTolerance" {
    // Classic 5-node: Q1=3, Q2=3 -> tolerance = 5-3 = 2
    const classic = QuorumPreset.classic(5);
    try std.testing.expectEqual(@as(u8, 2), classic.phase1FaultTolerance());
    try std.testing.expectEqual(@as(u8, 2), classic.phase2FaultTolerance());

    // Fast commit 5-node: Q1=4, Q2=2 -> phase1_tol=1, phase2_tol=3
    const fast = QuorumPreset.fast_commit(5);
    try std.testing.expectEqual(@as(u8, 1), fast.phase1FaultTolerance());
    try std.testing.expectEqual(@as(u8, 3), fast.phase2FaultTolerance());

    // Strong leader 5-node: Q1=5, Q2=1 -> phase1_tol=0, phase2_tol=4
    const strong = QuorumPreset.strong_leader(5);
    try std.testing.expectEqual(@as(u8, 0), strong.phase1FaultTolerance());
    try std.testing.expectEqual(@as(u8, 4), strong.phase2FaultTolerance());
}

test "validateQuorums: standalone function" {
    try validateQuorums(QuorumPreset.classic(5));
    try validateQuorums(QuorumPreset.fast_commit(5));
    try validateQuorums(QuorumPreset.strong_leader(5));

    // Invalid
    const invalid = QuorumConfig{ .cluster_size = 5, .phase1_quorum = 2, .phase2_quorum = 2 };
    try std.testing.expectError(QuorumError.InvalidQuorumIntersection, validateQuorums(invalid));
}

test "Edge cases: single node cluster" {
    const config = QuorumPreset.classic(1);
    try std.testing.expectEqual(@as(u8, 1), config.cluster_size);
    try std.testing.expectEqual(@as(u8, 1), config.phase1_quorum);
    try std.testing.expectEqual(@as(u8, 1), config.phase2_quorum);
    try config.validate();

    const paxos = FlexiblePaxos{ .config = config };
    try std.testing.expect(!paxos.hasPhase1Quorum(0));
    try std.testing.expect(paxos.hasPhase1Quorum(1));
    try std.testing.expect(!paxos.hasPhase2Quorum(0));
    try std.testing.expect(paxos.hasPhase2Quorum(1));
}

test "Edge cases: two node cluster" {
    const config = QuorumPreset.classic(2);
    try std.testing.expectEqual(@as(u8, 2), config.cluster_size);
    try std.testing.expectEqual(@as(u8, 2), config.phase1_quorum);
    try std.testing.expectEqual(@as(u8, 2), config.phase2_quorum);
    try config.validate();

    // For N=2, both nodes must agree for quorum
    const paxos = FlexiblePaxos{ .config = config };
    try std.testing.expect(!paxos.hasPhase1Quorum(1));
    try std.testing.expect(paxos.hasPhase1Quorum(2));
}

test "QuorumConfig.format: produces readable output" {
    const config = QuorumPreset.fast_commit(5);
    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try stream.writer().print("{}", .{config});
    try std.testing.expectEqualStrings("QuorumConfig(N=5, Q1=4, Q2=2)", stream.getWritten());
}
