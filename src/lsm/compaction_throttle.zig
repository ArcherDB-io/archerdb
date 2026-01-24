// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Latency-driven compaction throttling with predictive and reactive controls.
//!
//! This module implements TiKV-style flow control for compaction to prevent I/O spikes
//! from impacting query latency. The throttle has two modes:
//!
//! 1. **Predictive (Primary)**: Monitors pending compaction bytes and proactively
//!    slows compaction before write stalls occur. This is the preferred path since
//!    it prevents degradation before it happens.
//!
//! 2. **Reactive (Fallback)**: Monitors P99 query latency and reduces compaction
//!    throughput when latency exceeds threshold. This catches cases where pending
//!    bytes tracking is insufficient.
//!
//! Key features:
//! - Hysteresis to prevent oscillation between throttled/unthrottled states
//! - Gradual recovery requiring consecutive good checks
//! - Minimum throughput floor to ensure compaction progresses
//! - Observable via Prometheus metrics

const std = @import("std");

/// Configuration for compaction throttling.
/// Combines TiKV-style predictive throttling with reactive P99 fallback.
pub const ThrottleConfig = struct {
    // =========================================================================
    // PREDICTIVE thresholds (primary - TiKV pattern)
    // Check pending compaction bytes FIRST to prevent stalls before they happen
    // =========================================================================

    /// Start slowing compaction when pending bytes exceed this threshold (64 GiB default).
    /// This is the "soft" limit where we begin gradual throttling.
    soft_pending_compaction_bytes: u64 = 64 * 1024 * 1024 * 1024,

    /// Aggressive slowdown when pending bytes exceed this threshold (256 GiB default).
    /// This is the "hard" limit where we immediately halve throughput.
    hard_pending_compaction_bytes: u64 = 256 * 1024 * 1024 * 1024,

    // =========================================================================
    // REACTIVE fallback thresholds (secondary - when pending bytes unavailable or low)
    // =========================================================================

    /// Start throttling when P99 query latency exceeds this threshold (milliseconds).
    /// This is the gradual slowdown threshold.
    p99_latency_threshold_ms: f64 = 50.0,

    /// Emergency throttle when P99 exceeds this threshold (milliseconds).
    /// Immediately drops to min_throughput_ratio.
    p99_latency_critical_ms: f64 = 100.0,

    // =========================================================================
    // Throttle behavior configuration
    // =========================================================================

    /// How often to check throttle conditions (milliseconds).
    check_interval_ms: u64 = 1000,

    /// Throughput adjustment step per check (10% = 0.1).
    /// Each throttle/recovery event adjusts by this amount.
    throttle_ratio_step: f64 = 0.1,

    /// Minimum throughput ratio - compaction never drops below this (10% = 0.1).
    /// Ensures compaction makes progress even under heavy load.
    min_throughput_ratio: f64 = 0.1,

    /// Hysteresis: latency must drop this much below threshold before recovery.
    /// Prevents rapid oscillation when latency hovers near threshold.
    recovery_hysteresis_ms: f64 = 10.0,

    /// Number of consecutive good checks required before increasing throughput.
    /// Ensures stable conditions before ramping back up.
    consecutive_good_checks_required: u32 = 3,
};

/// Metrics observed for throttle decisions.
pub const ThrottleMetrics = struct {
    /// Pending compaction bytes - primary signal from manifest/level tracking.
    pending_compaction_bytes: u64,

    /// Current P99 query latency in milliseconds - fallback signal from histogram.
    current_p99_ms: f64,
};

/// Current throttle state tracking.
pub const ThrottleState = struct {
    /// Current throughput ratio: 1.0 = full speed, 0.1 = 10% throughput.
    current_throughput_ratio: f64 = 1.0,

    /// Timestamp of last throttle check (nanoseconds).
    last_check_ns: i128 = 0,

    /// Count of consecutive checks where both signals were good.
    consecutive_good_checks: u32 = 0,

    /// Whether we're currently in critical mode (P99 > critical threshold).
    in_critical: bool = false,

    /// Initialize a new throttle state at full throughput.
    pub fn init() ThrottleState {
        return .{};
    }

    /// Reset throttle state to initial values (full throughput).
    pub fn reset(self: *ThrottleState) void {
        self.* = ThrottleState.init();
    }

    /// Check if enough time has passed since last check.
    /// Returns true if we should run an update() call.
    pub fn shouldCheck(self: *const ThrottleState, current_time_ns: i128, config: ThrottleConfig) bool {
        const interval_ns = @as(i128, config.check_interval_ms) * std.time.ns_per_ms;
        return (current_time_ns - self.last_check_ns) >= interval_ns;
    }

    /// Update throttle state based on current metrics.
    /// This implements the predictive + reactive throttling logic.
    ///
    /// Order of checks:
    /// 1. PREDICTIVE PATH - pending compaction bytes (prevents stalls)
    /// 2. REACTIVE FALLBACK - P99 latency (catches remaining issues)
    /// 3. RECOVERY - when both signals are good
    pub fn update(self: *ThrottleState, metrics: ThrottleMetrics, config: ThrottleConfig, current_time_ns: i128) void {
        self.last_check_ns = current_time_ns;

        // =====================================================================
        // PREDICTIVE PATH (pending bytes) - prevents stalls before they happen
        // =====================================================================

        // Hard threshold: aggressive slowdown
        if (metrics.pending_compaction_bytes > config.hard_pending_compaction_bytes) {
            // Halve throughput immediately for hard threshold
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio * 0.5,
            );
            self.consecutive_good_checks = 0;
            self.in_critical = true;
            return;
        }

        // Soft threshold: gradual slowdown
        if (metrics.pending_compaction_bytes > config.soft_pending_compaction_bytes) {
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio - config.throttle_ratio_step,
            );
            self.consecutive_good_checks = 0;
            return;
        }

        // =====================================================================
        // REACTIVE FALLBACK (P99 latency) - when pending bytes tracking is low
        // =====================================================================

        // Critical P99: emergency throttle
        if (metrics.current_p99_ms > config.p99_latency_critical_ms) {
            self.current_throughput_ratio = config.min_throughput_ratio;
            self.consecutive_good_checks = 0;
            self.in_critical = true;
            return;
        }

        // Threshold P99: gradual slowdown
        if (metrics.current_p99_ms > config.p99_latency_threshold_ms) {
            self.current_throughput_ratio = @max(
                config.min_throughput_ratio,
                self.current_throughput_ratio - config.throttle_ratio_step,
            );
            self.consecutive_good_checks = 0;
            return;
        }

        // =====================================================================
        // RECOVERY (when both signals are good)
        // =====================================================================

        // Only recover if:
        // 1. Pending bytes are below soft threshold (checked above - we didn't return)
        // 2. P99 latency is well below threshold (with hysteresis)
        if (metrics.current_p99_ms < config.p99_latency_threshold_ms - config.recovery_hysteresis_ms) {
            self.consecutive_good_checks += 1;

            if (self.consecutive_good_checks >= config.consecutive_good_checks_required) {
                // Recovery: increase throughput
                self.current_throughput_ratio = @min(
                    1.0,
                    self.current_throughput_ratio + config.throttle_ratio_step,
                );
                // Don't reset consecutive_good_checks - allow continuous recovery

                // Exit critical mode once back to full throughput
                if (self.current_throughput_ratio >= 1.0) {
                    self.in_critical = false;
                }
            }
        }
        // Note: If P99 is between (threshold - hysteresis) and threshold, we don't
        // throttle more but also don't recover. This is the hysteresis band.
    }

    /// Calculate the delay to add between work units based on current throttle ratio.
    /// Given a work duration, returns how long to sleep to achieve the target throughput.
    ///
    /// Formula: delay = work_duration * (1/throughput_ratio - 1)
    ///
    /// Examples:
    /// - ratio=1.0: delay=0 (full speed)
    /// - ratio=0.5: delay=work_duration (50% throughput = equal work and sleep)
    /// - ratio=0.1: delay=9*work_duration (10% throughput)
    ///
    /// Returns delay in nanoseconds.
    pub fn getDelayNs(self: *const ThrottleState, work_duration_ns: u64) u64 {
        if (self.current_throughput_ratio >= 1.0) {
            return 0;
        }

        if (self.current_throughput_ratio <= 0.0) {
            // Shouldn't happen with min_throughput_ratio, but guard against it
            return std.math.maxInt(u64);
        }

        // delay = work_duration * (1/ratio - 1)
        const ratio_inverse: f64 = 1.0 / self.current_throughput_ratio;
        const delay_multiplier: f64 = ratio_inverse - 1.0;
        const delay_ns: f64 = @as(f64, @floatFromInt(work_duration_ns)) * delay_multiplier;

        return @intFromFloat(@min(delay_ns, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
    }

    /// Returns true if throttle is currently active (ratio < 1.0).
    pub fn isActive(self: *const ThrottleState) bool {
        return self.current_throughput_ratio < 1.0;
    }

    /// Returns the current throughput ratio scaled for metrics (0-1000).
    pub fn getThroughputRatioScaled(self: *const ThrottleState) u32 {
        return @intFromFloat(self.current_throughput_ratio * 1000.0);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "ThrottleState: predictive path - hard pending bytes triggers aggressive slowdown" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();

    // Exceed hard threshold
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 300 * 1024 * 1024 * 1024, // 300 GiB > 256 GiB
        .current_p99_ms = 10.0, // Low latency - shouldn't matter
    };

    // Start at full throughput
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), state.current_throughput_ratio, 0.001);

    state.update(metrics, config, 1_000_000_000);

    // Should halve throughput
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.current_throughput_ratio, 0.001);
    try std.testing.expect(state.in_critical);
    try std.testing.expectEqual(@as(u32, 0), state.consecutive_good_checks);
}

test "ThrottleState: predictive path - soft pending bytes triggers gradual slowdown" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();

    // Exceed soft threshold but not hard
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 100 * 1024 * 1024 * 1024, // 100 GiB (between 64 and 256)
        .current_p99_ms = 10.0,
    };

    state.update(metrics, config, 1_000_000_000);

    // Should decrease by step (0.1)
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), state.current_throughput_ratio, 0.001);
    try std.testing.expect(!state.in_critical);
    try std.testing.expectEqual(@as(u32, 0), state.consecutive_good_checks);
}

test "ThrottleState: reactive fallback - P99 critical triggers immediate min" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();

    // Low pending bytes but high P99
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 0,
        .current_p99_ms = 150.0, // > 100ms critical threshold
    };

    state.update(metrics, config, 1_000_000_000);

    // Should drop to min immediately
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.current_throughput_ratio, 0.001);
    try std.testing.expect(state.in_critical);
}

test "ThrottleState: reactive fallback - P99 threshold triggers gradual slowdown" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();

    // Low pending bytes but threshold-exceeding P99
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 0,
        .current_p99_ms = 60.0, // > 50ms threshold, < 100ms critical
    };

    state.update(metrics, config, 1_000_000_000);

    // Should decrease by step
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), state.current_throughput_ratio, 0.001);
    try std.testing.expect(!state.in_critical);
}

test "ThrottleState: hysteresis prevents oscillation" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();
    state.current_throughput_ratio = 0.8;

    // P99 in hysteresis band: above (threshold - hysteresis) but below threshold
    // threshold=50, hysteresis=10, so band is 40-50ms
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 0,
        .current_p99_ms = 45.0, // In the hysteresis band
    };

    const initial_ratio = state.current_throughput_ratio;
    const initial_checks = state.consecutive_good_checks;

    state.update(metrics, config, 1_000_000_000);

    // Should NOT change - in hysteresis band
    try std.testing.expectApproxEqAbs(initial_ratio, state.current_throughput_ratio, 0.001);
    try std.testing.expectEqual(initial_checks, state.consecutive_good_checks);
}

test "ThrottleState: recovery after consecutive good checks" {
    var config = ThrottleConfig{};
    config.consecutive_good_checks_required = 3;

    var state = ThrottleState.init();
    state.current_throughput_ratio = 0.5; // Start throttled

    // Good metrics (both signals below thresholds with hysteresis)
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 0,
        .current_p99_ms = 20.0, // Well below 40ms (threshold - hysteresis)
    };

    // First two good checks: no recovery yet
    state.update(metrics, config, 1_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.current_throughput_ratio, 0.001);
    try std.testing.expectEqual(@as(u32, 1), state.consecutive_good_checks);

    state.update(metrics, config, 2_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.current_throughput_ratio, 0.001);
    try std.testing.expectEqual(@as(u32, 2), state.consecutive_good_checks);

    // Third good check: recovery
    state.update(metrics, config, 3_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.current_throughput_ratio, 0.001);
    try std.testing.expectEqual(@as(u32, 3), state.consecutive_good_checks);

    // Continue recovery
    state.update(metrics, config, 4_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), state.current_throughput_ratio, 0.001);
}

test "ThrottleState: min throughput floor" {
    const config = ThrottleConfig{};
    var state = ThrottleState.init();
    state.current_throughput_ratio = 0.15; // Near minimum

    // Repeated throttling shouldn't go below min
    const metrics = ThrottleMetrics{
        .pending_compaction_bytes = 100 * 1024 * 1024 * 1024,
        .current_p99_ms = 60.0,
    };

    // Multiple updates
    state.update(metrics, config, 1_000_000_000);
    state.update(metrics, config, 2_000_000_000);
    state.update(metrics, config, 3_000_000_000);

    // Should be at minimum, not below
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.current_throughput_ratio, 0.001);
}

test "ThrottleState: getDelayNs calculation" {
    var state = ThrottleState.init();

    // Full throughput: no delay
    state.current_throughput_ratio = 1.0;
    try std.testing.expectEqual(@as(u64, 0), state.getDelayNs(1_000_000));

    // 50% throughput: delay equals work duration
    state.current_throughput_ratio = 0.5;
    try std.testing.expectEqual(@as(u64, 1_000_000), state.getDelayNs(1_000_000));

    // 10% throughput: delay is 9x work duration
    state.current_throughput_ratio = 0.1;
    try std.testing.expectEqual(@as(u64, 9_000_000), state.getDelayNs(1_000_000));
}

test "ThrottleState: shouldCheck respects interval" {
    const config = ThrottleConfig{
        .check_interval_ms = 1000,
    };
    var state = ThrottleState.init();
    state.last_check_ns = 0;

    // Not enough time passed
    try std.testing.expect(!state.shouldCheck(500_000_000, config)); // 500ms

    // Exactly at interval
    try std.testing.expect(state.shouldCheck(1_000_000_000, config)); // 1000ms

    // Past interval
    try std.testing.expect(state.shouldCheck(2_000_000_000, config)); // 2000ms
}

test "ThrottleState: isActive and getThroughputRatioScaled" {
    var state = ThrottleState.init();

    // Full speed
    state.current_throughput_ratio = 1.0;
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(u32, 1000), state.getThroughputRatioScaled());

    // Throttled
    state.current_throughput_ratio = 0.5;
    try std.testing.expect(state.isActive());
    try std.testing.expectEqual(@as(u32, 500), state.getThroughputRatioScaled());

    // Minimum
    state.current_throughput_ratio = 0.1;
    try std.testing.expect(state.isActive());
    try std.testing.expectEqual(@as(u32, 100), state.getThroughputRatioScaled());
}
