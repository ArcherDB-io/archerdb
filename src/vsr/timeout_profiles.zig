// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! VSR Timeout Profiles for Cluster Consensus
//!
//! Fixed timeout values don't adapt to network conditions. Cloud environments have higher
//! latency variance than datacenters due to cross-AZ communication, virtualization overhead,
//! and shared network infrastructure. This module provides configurable timeout profiles
//! that operators can tune for their specific deployment environment.
//!
//! ## Profile Selection Guide
//!
//! - **Cloud profile**: Use for AWS, GCP, Azure deployments with cross-AZ/cross-region
//!   communication. Higher timeouts accommodate network variance without triggering
//!   unnecessary view changes.
//!
//! - **Datacenter profile**: Use for on-premises deployments with dedicated, low-latency
//!   networking. Lower timeouts enable faster leader failover during actual failures.
//!
//! - **Custom profile**: Start from a base profile and override specific values. Useful
//!   when you need datacenter-like heartbeats but cloud-like view change timeouts.
//!
//! ## Jitter and Thundering Herd Prevention
//!
//! All timeouts have jitter applied to prevent the "thundering herd" problem where
//! multiple replicas timeout simultaneously and flood the network with view change
//! messages. The jitter_range_pct parameter controls the randomization range:
//! a value of 20 means +/- 20% variation around the base timeout value.
//!
//! Reference: RESEARCH.md "Timeout Thundering Herd" pitfall documentation.
//!
//! ## Usage
//!
//!     const config = TimeoutConfig{
//!         .profile = .cloud,
//!         .jitter_range_pct = 20,
//!         .overrides = .{ .heartbeat_interval_ms = 300 },
//!     };
//!     const values = config.getEffectiveValues();
//!     const jittered = config.applyJitter(values.election_timeout_ms, prng);
//!
//! ## Aggressive View Change Detection
//!
//! Both profiles use aggressive view change detection ratios:
//! - Election timeout is 4x heartbeat (cloud) or 5x heartbeat (datacenter)
//! - This minimizes the unavailability window during actual leader failures
//! - The difference accounts for cloud's higher network variance

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");

/// Environment profile for VSR timeout configuration.
///
/// Profiles provide sensible defaults optimized for common deployment scenarios.
/// Use `.custom` when you need fine-grained control over individual timeout values.
pub const TimeoutProfile = enum {
    /// High variance network (AWS, GCP, Azure cross-AZ/region deployments).
    /// Higher timeouts accommodate jitter from virtualization and shared infrastructure.
    cloud,

    /// Low latency, predictable network (on-premises with dedicated networking).
    /// Lower timeouts enable faster leader failover.
    datacenter,

    /// Start from profile defaults, override specific values via TimeoutConfig.overrides.
    /// When used alone without overrides, behaves identically to `.cloud`.
    custom,
};

/// Preset timeout values optimized for common deployment environments.
///
/// These values are based on typical network characteristics:
/// - Cloud: RTT 1-10ms within AZ, 5-50ms cross-AZ, occasional 100ms+ spikes
/// - Datacenter: RTT <1ms typical, rarely exceeds 5ms
pub const ProfilePresets = struct {
    /// Cloud profile: Higher timeouts for cross-AZ variance.
    ///
    /// Rationale for specific values:
    /// - heartbeat_interval_ms: 500ms allows for network variance without excessive traffic
    /// - election_timeout_ms: 2000ms = 4x heartbeat, aggressive but not oversensitive
    /// - request_timeout_ms: 5000ms accommodates slow cross-AZ responses
    /// - connection_timeout_ms: 10000ms handles TCP establishment over variable links
    /// - view_change_timeout_ms: 3000ms allows view changes to complete across AZs
    pub const cloud = TimeoutValues{
        .heartbeat_interval_ms = 500,
        .election_timeout_ms = 2000,
        .request_timeout_ms = 5000,
        .connection_timeout_ms = 10000,
        .view_change_timeout_ms = 3000,
    };

    /// Datacenter profile: Lower timeouts for fast failover.
    ///
    /// Rationale for specific values:
    /// - heartbeat_interval_ms: 100ms for rapid failure detection
    /// - election_timeout_ms: 500ms = 5x heartbeat, detects failure in half a second
    /// - request_timeout_ms: 1000ms, generous for local network operations
    /// - connection_timeout_ms: 2000ms, handles slow server startups
    /// - view_change_timeout_ms: 750ms enables sub-second leader transitions
    pub const datacenter = TimeoutValues{
        .heartbeat_interval_ms = 100,
        .election_timeout_ms = 500,
        .request_timeout_ms = 1000,
        .connection_timeout_ms = 2000,
        .view_change_timeout_ms = 750,
    };

    /// Returns preset values for a given profile.
    pub fn get(profile: TimeoutProfile) TimeoutValues {
        return switch (profile) {
            .cloud, .custom => cloud,
            .datacenter => datacenter,
        };
    }
};

/// Timeout values in milliseconds for VSR protocol operations.
///
/// All values are in milliseconds to match common operator expectations
/// and configuration file conventions.
pub const TimeoutValues = struct {
    /// Interval between heartbeat messages from leader to followers.
    /// Lower values detect failures faster but increase network traffic.
    heartbeat_interval_ms: u64,

    /// Maximum time to wait for heartbeat before initiating leader election.
    /// Should be significantly larger than heartbeat_interval to avoid false positives.
    /// Typical ratio: 4-5x heartbeat_interval.
    election_timeout_ms: u64,

    /// Maximum time to wait for a client request to complete.
    /// Includes time for replication across the cluster.
    request_timeout_ms: u64,

    /// Maximum time to wait for TCP connection establishment.
    /// Should account for DNS resolution and network path setup.
    connection_timeout_ms: u64,

    /// Maximum time to wait for a view change to complete.
    /// Includes time for replicas to exchange state and reach consensus on new view.
    view_change_timeout_ms: u64,
};

/// Optional overrides for individual timeout values.
///
/// When using `.custom` profile, set specific fields to override the base
/// profile values. Unset fields (null) use the base profile's defaults.
pub const TimeoutOverrides = struct {
    heartbeat_interval_ms: ?u64 = null,
    election_timeout_ms: ?u64 = null,
    request_timeout_ms: ?u64 = null,
    connection_timeout_ms: ?u64 = null,
    view_change_timeout_ms: ?u64 = null,
};

/// Complete timeout configuration combining profile selection with optional overrides.
///
/// The configuration pipeline:
/// 1. Select base profile (cloud, datacenter, or custom)
/// 2. Apply any overrides to specific timeout values
/// 3. Apply jitter when using timeouts to prevent thundering herd
pub const TimeoutConfig = struct {
    const Self = @This();

    /// Base profile to use for default timeout values.
    profile: TimeoutProfile = .cloud,

    /// Jitter range as a percentage (+/- this value).
    /// A value of 20 means timeouts will vary by +/- 20% of the base value.
    /// Set to 0 to disable jitter (not recommended in production).
    jitter_range_pct: u8 = 20,

    /// Optional overrides for specific timeout values.
    /// Only applies when profile is `.custom`, ignored otherwise.
    overrides: ?TimeoutOverrides = null,

    /// Returns the effective timeout values after applying profile defaults and overrides.
    ///
    /// Override precedence:
    /// - If profile is `.custom` and overrides is non-null, individual override values
    ///   take precedence over cloud defaults
    /// - If profile is `.cloud` or `.datacenter`, overrides are ignored
    pub fn getEffectiveValues(self: *const Self) TimeoutValues {
        const base = ProfilePresets.get(self.profile);

        // Only apply overrides for custom profile
        if (self.profile != .custom) {
            return base;
        }

        const overrides = self.overrides orelse return base;

        return TimeoutValues{
            .heartbeat_interval_ms = overrides.heartbeat_interval_ms orelse base.heartbeat_interval_ms,
            .election_timeout_ms = overrides.election_timeout_ms orelse base.election_timeout_ms,
            .request_timeout_ms = overrides.request_timeout_ms orelse base.request_timeout_ms,
            .connection_timeout_ms = overrides.connection_timeout_ms orelse base.connection_timeout_ms,
            .view_change_timeout_ms = overrides.view_change_timeout_ms orelse base.view_change_timeout_ms,
        };
    }

    /// Applies jitter to a base timeout value to prevent thundering herd.
    ///
    /// The jitter is uniformly distributed in the range:
    /// [base_value - jitter%, base_value + jitter%]
    ///
    /// For example, with jitter_range_pct=20 and base_value=1000:
    /// - Minimum: 800 (1000 - 20%)
    /// - Maximum: 1200 (1000 + 20%)
    ///
    /// Edge case: If jitter_range_pct is 0, returns the exact base_value.
    pub fn applyJitter(self: *const Self, base_value: u64, prng: *stdx.PRNG) u64 {
        if (self.jitter_range_pct == 0) {
            return base_value;
        }

        // Calculate jitter range: +/- jitter_range_pct of base_value
        const jitter_amount = (base_value * @as(u64, self.jitter_range_pct)) / 100;

        // Calculate min and max bounds
        const min_value = base_value -| jitter_amount; // Saturating subtraction
        const max_value = base_value +| jitter_amount; // Saturating addition

        // Ensure we have a valid range
        if (min_value >= max_value) {
            return base_value;
        }

        // Generate uniformly distributed value in [min_value, max_value]
        return prng.range_inclusive(u64, min_value, max_value);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "timeout_profiles: cloud profile returns expected default values" {
    const cloud = ProfilePresets.cloud;

    try testing.expectEqual(@as(u64, 500), cloud.heartbeat_interval_ms);
    try testing.expectEqual(@as(u64, 2000), cloud.election_timeout_ms);
    try testing.expectEqual(@as(u64, 5000), cloud.request_timeout_ms);
    try testing.expectEqual(@as(u64, 10000), cloud.connection_timeout_ms);
    try testing.expectEqual(@as(u64, 3000), cloud.view_change_timeout_ms);

    // Verify election timeout is 4x heartbeat (aggressive detection)
    try testing.expectEqual(cloud.heartbeat_interval_ms * 4, cloud.election_timeout_ms);
}

test "timeout_profiles: datacenter profile returns expected default values" {
    const datacenter = ProfilePresets.datacenter;

    try testing.expectEqual(@as(u64, 100), datacenter.heartbeat_interval_ms);
    try testing.expectEqual(@as(u64, 500), datacenter.election_timeout_ms);
    try testing.expectEqual(@as(u64, 1000), datacenter.request_timeout_ms);
    try testing.expectEqual(@as(u64, 2000), datacenter.connection_timeout_ms);
    try testing.expectEqual(@as(u64, 750), datacenter.view_change_timeout_ms);

    // Verify election timeout is 5x heartbeat (aggressive detection)
    try testing.expectEqual(datacenter.heartbeat_interval_ms * 5, datacenter.election_timeout_ms);
}

test "timeout_profiles: custom profile with overrides applies overrides correctly" {
    const config = TimeoutConfig{
        .profile = .custom,
        .overrides = .{
            .heartbeat_interval_ms = 300,
            .election_timeout_ms = 1200,
            // Leave other values as null to use defaults
        },
    };

    const values = config.getEffectiveValues();

    // Overridden values
    try testing.expectEqual(@as(u64, 300), values.heartbeat_interval_ms);
    try testing.expectEqual(@as(u64, 1200), values.election_timeout_ms);

    // Default values (from cloud profile, which is base for custom)
    try testing.expectEqual(@as(u64, 5000), values.request_timeout_ms);
    try testing.expectEqual(@as(u64, 10000), values.connection_timeout_ms);
    try testing.expectEqual(@as(u64, 3000), values.view_change_timeout_ms);
}

test "timeout_profiles: jitter stays within specified range" {
    var prng = stdx.PRNG.from_seed(12345);

    const config = TimeoutConfig{
        .profile = .cloud,
        .jitter_range_pct = 20,
    };

    const base_value: u64 = 1000;
    const min_expected: u64 = 800; // 1000 - 20%
    const max_expected: u64 = 1200; // 1000 + 20%

    // Generate many jittered values and verify all are within range
    for (0..1000) |_| {
        const jittered = config.applyJitter(base_value, &prng);
        try testing.expect(jittered >= min_expected);
        try testing.expect(jittered <= max_expected);
    }
}

test "timeout_profiles: jitter produces different values across calls" {
    var prng = stdx.PRNG.from_seed(54321);

    const config = TimeoutConfig{
        .profile = .cloud,
        .jitter_range_pct = 20,
    };

    const base_value: u64 = 1000;

    // Collect multiple jittered values
    var values: [10]u64 = undefined;
    for (&values) |*v| {
        v.* = config.applyJitter(base_value, &prng);
    }

    // Verify at least some values are different (not all identical)
    var all_same = true;
    for (values[1..]) |v| {
        if (v != values[0]) {
            all_same = false;
            break;
        }
    }

    try testing.expect(!all_same);
}

test "timeout_profiles: getEffectiveValues merges profile defaults with overrides" {
    // Test that custom profile starts from cloud defaults
    const config_no_overrides = TimeoutConfig{
        .profile = .custom,
        .overrides = null,
    };
    const values_no_overrides = config_no_overrides.getEffectiveValues();
    try testing.expectEqual(ProfilePresets.cloud.heartbeat_interval_ms, values_no_overrides.heartbeat_interval_ms);

    // Test that non-custom profiles ignore overrides
    const config_cloud_with_overrides = TimeoutConfig{
        .profile = .cloud,
        .overrides = .{ .heartbeat_interval_ms = 999 },
    };
    const values_cloud = config_cloud_with_overrides.getEffectiveValues();
    try testing.expectEqual(ProfilePresets.cloud.heartbeat_interval_ms, values_cloud.heartbeat_interval_ms);

    // Test that datacenter profile returns datacenter values
    const config_datacenter = TimeoutConfig{
        .profile = .datacenter,
    };
    const values_datacenter = config_datacenter.getEffectiveValues();
    try testing.expectEqual(ProfilePresets.datacenter.heartbeat_interval_ms, values_datacenter.heartbeat_interval_ms);
}

test "timeout_profiles: zero percent jitter returns exact base value" {
    var prng = stdx.PRNG.from_seed(99999);

    const config = TimeoutConfig{
        .profile = .cloud,
        .jitter_range_pct = 0, // No jitter
    };

    const base_value: u64 = 1000;

    // With 0% jitter, should always return exact base value
    for (0..100) |_| {
        const jittered = config.applyJitter(base_value, &prng);
        try testing.expectEqual(base_value, jittered);
    }
}

test "timeout_profiles: ProfilePresets.get returns correct profile" {
    try testing.expectEqual(ProfilePresets.cloud, ProfilePresets.get(.cloud));
    try testing.expectEqual(ProfilePresets.datacenter, ProfilePresets.get(.datacenter));
    try testing.expectEqual(ProfilePresets.cloud, ProfilePresets.get(.custom)); // custom defaults to cloud
}
