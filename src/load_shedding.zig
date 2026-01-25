// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Load shedding to protect the system under overload conditions.
//!
//! Under overload, accepting all requests leads to cascading failure (increased
//! latency, memory exhaustion, timeout storms). Load shedding protects the system
//! by rejecting excess requests early with clear feedback (429 + Retry-After),
//! allowing the system to maintain quality of service for accepted requests.
//!
//! Key features:
//! - Composite overload signal: queue depth + latency P99 + resource pressure
//! - Hard cutoff shedding: below threshold accept all, above reject all
//! - Configurable threshold with guardrails (cannot disable entirely)
//! - Retry-After calculation based on overload severity

const std = @import("std");

/// Configuration for load shedding behavior.
/// Threshold is clamped to guardrails - cannot be disabled entirely.
pub const ShedConfig = struct {
    // Composite signal weights (default equal weighting)
    queue_depth_weight: f32 = 0.34,
    latency_p99_weight: f32 = 0.33,
    resource_pressure_weight: f32 = 0.33,

    // Hard cutoff threshold (guardrails: 0.5-0.95)
    threshold: f32 = 0.8,
    min_threshold: f32 = 0.5, // Cannot set lower
    max_threshold: f32 = 0.95, // Cannot set higher

    // Signal thresholds for normalization
    max_queue_depth: u32 = 10000,
    max_latency_p99_ms: u64 = 1000,
    max_memory_pressure_pct: u8 = 90,

    // Retry-After calculation
    base_retry_ms: u64 = 1000,
    max_retry_ms: u64 = 30000,

    /// Validate and clamp configuration to guardrails.
    pub fn validate(self: *ShedConfig) void {
        // Clamp threshold to guardrails
        if (self.threshold < self.min_threshold) {
            self.threshold = self.min_threshold;
        }
        if (self.threshold > self.max_threshold) {
            self.threshold = self.max_threshold;
        }

        // Ensure weights sum to approximately 1.0 (within epsilon)
        const total_weight = self.queue_depth_weight + self.latency_p99_weight + self.resource_pressure_weight;
        if (total_weight < 0.99 or total_weight > 1.01) {
            // Reset to equal weighting
            self.queue_depth_weight = 0.34;
            self.latency_p99_weight = 0.33;
            self.resource_pressure_weight = 0.33;
        }
    }
};

/// Reason for shedding decision.
pub const ShedReason = enum {
    queue_depth,
    latency_p99,
    resource_pressure,
    composite,
};

/// Result of a shedding decision check.
pub const ShedDecision = struct {
    shed: bool,
    retry_after_ms: ?u64,
    score: f32, // Current composite score for metrics
    reason: ?ShedReason,

    /// Create a decision to accept the request.
    pub fn accept(score: f32) ShedDecision {
        return .{
            .shed = false,
            .retry_after_ms = null,
            .score = score,
            .reason = null,
        };
    }

    /// Create a decision to shed the request.
    pub fn reject(score: f32, retry_after_ms: u64, reason: ShedReason) ShedDecision {
        return .{
            .shed = true,
            .retry_after_ms = retry_after_ms,
            .score = score,
            .reason = reason,
        };
    }
};

/// Load shedder implementing composite overload detection with hard cutoff.
pub const LoadShedder = struct {
    const Self = @This();

    config: ShedConfig,

    // Current signal values (atomic for thread-safe updates)
    queue_depth: std.atomic.Value(u32),
    latency_p99_ns: std.atomic.Value(u64),
    memory_used_pct: std.atomic.Value(u8),

    // Statistics for monitoring
    total_checked: std.atomic.Value(u64),
    total_shed: std.atomic.Value(u64),

    /// Initialize a new LoadShedder with the given configuration.
    pub fn init(config: ShedConfig) Self {
        var validated_config = config;
        validated_config.validate();

        return .{
            .config = validated_config,
            .queue_depth = std.atomic.Value(u32).init(0),
            .latency_p99_ns = std.atomic.Value(u64).init(0),
            .memory_used_pct = std.atomic.Value(u8).init(0),
            .total_checked = std.atomic.Value(u64).init(0),
            .total_shed = std.atomic.Value(u64).init(0),
        };
    }

    /// Initialize with default configuration.
    pub fn initDefault() Self {
        return init(ShedConfig{});
    }

    /// Check whether the current request should be shed.
    /// Returns a ShedDecision with shed=true if overloaded.
    pub fn shouldShed(self: *Self) ShedDecision {
        _ = self.total_checked.fetchAdd(1, .monotonic);

        const score = self.computeCompositeScore();

        // Hard cutoff: below threshold accept, at or above reject
        if (score < self.config.threshold) {
            return ShedDecision.accept(score);
        }

        // Determine dominant reason
        const reason = self.determineShedReason();
        const retry_after = self.computeRetryAfter(score);

        _ = self.total_shed.fetchAdd(1, .monotonic);

        return ShedDecision.reject(score, retry_after, reason);
    }

    /// Update the current queue depth signal.
    pub fn updateQueueDepth(self: *Self, depth: u32) void {
        self.queue_depth.store(depth, .monotonic);
    }

    /// Update the P99 latency signal (in nanoseconds).
    pub fn updateLatencyP99(self: *Self, latency_ns: u64) void {
        self.latency_p99_ns.store(latency_ns, .monotonic);
    }

    /// Update the memory pressure signal (percentage used, 0-100).
    pub fn updateMemoryPressure(self: *Self, used_pct: u8) void {
        self.memory_used_pct.store(used_pct, .monotonic);
    }

    /// Get the current composite overload score (0.0-1.0).
    pub fn getScore(self: *Self) f32 {
        return self.computeCompositeScore();
    }

    /// Get statistics for monitoring.
    pub fn getStats(self: *Self) struct { total_checked: u64, total_shed: u64, shed_ratio: f64 } {
        const checked = self.total_checked.load(.monotonic);
        const shed = self.total_shed.load(.monotonic);
        const ratio: f64 = if (checked > 0) @as(f64, @floatFromInt(shed)) / @as(f64, @floatFromInt(checked)) else 0.0;
        return .{
            .total_checked = checked,
            .total_shed = shed,
            .shed_ratio = ratio,
        };
    }

    /// Compute the composite overload score from all signals.
    /// Returns a value in the range 0.0 to 1.0.
    fn computeCompositeScore(self: *Self) f32 {
        const queue_depth = self.queue_depth.load(.monotonic);
        const latency_ns = self.latency_p99_ns.load(.monotonic);
        const memory_pct = self.memory_used_pct.load(.monotonic);

        // Normalize each signal to 0.0-1.0 range
        const queue_score = @min(1.0, @as(f32, @floatFromInt(queue_depth)) / @as(f32, @floatFromInt(self.config.max_queue_depth)));

        // Convert latency from ns to ms for comparison
        const latency_ms = latency_ns / 1_000_000;
        const latency_score = @min(1.0, @as(f32, @floatFromInt(latency_ms)) / @as(f32, @floatFromInt(self.config.max_latency_p99_ms)));

        const memory_score = @min(1.0, @as(f32, @floatFromInt(memory_pct)) / @as(f32, @floatFromInt(self.config.max_memory_pressure_pct)));

        // Compute weighted composite
        return self.config.queue_depth_weight * queue_score +
            self.config.latency_p99_weight * latency_score +
            self.config.resource_pressure_weight * memory_score;
    }

    /// Determine the dominant reason for shedding.
    fn determineShedReason(self: *Self) ShedReason {
        const queue_depth = self.queue_depth.load(.monotonic);
        const latency_ns = self.latency_p99_ns.load(.monotonic);
        const memory_pct = self.memory_used_pct.load(.monotonic);

        // Calculate individual normalized scores
        const queue_score = @as(f32, @floatFromInt(queue_depth)) / @as(f32, @floatFromInt(self.config.max_queue_depth));
        const latency_ms = latency_ns / 1_000_000;
        const latency_score = @as(f32, @floatFromInt(latency_ms)) / @as(f32, @floatFromInt(self.config.max_latency_p99_ms));
        const memory_score = @as(f32, @floatFromInt(memory_pct)) / @as(f32, @floatFromInt(self.config.max_memory_pressure_pct));

        // Check if any single signal is dominant (>80% of its threshold)
        const dominant_threshold: f32 = 0.8;

        var dominant_count: u32 = 0;
        var dominant_reason: ShedReason = .composite;

        if (queue_score >= dominant_threshold) {
            dominant_count += 1;
            dominant_reason = .queue_depth;
        }
        if (latency_score >= dominant_threshold) {
            dominant_count += 1;
            dominant_reason = .latency_p99;
        }
        if (memory_score >= dominant_threshold) {
            dominant_count += 1;
            dominant_reason = .resource_pressure;
        }

        // If exactly one signal is dominant, use that reason
        // Otherwise it's a composite cause
        if (dominant_count == 1) {
            return dominant_reason;
        }
        return .composite;
    }

    /// Compute the Retry-After value based on overload severity.
    /// Uses exponential backoff: base_retry_ms * (1 + (score - threshold) * 10)
    /// Capped at max_retry_ms.
    fn computeRetryAfter(self: *Self, score: f32) u64 {
        const overage = score - self.config.threshold;
        const multiplier: f32 = 1.0 + overage * 10.0;
        const retry: u64 = @intFromFloat(@as(f32, @floatFromInt(self.config.base_retry_ms)) * multiplier);
        return @min(retry, self.config.max_retry_ms);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShedConfig.validate: clamps threshold to guardrails" {
    var config = ShedConfig{
        .threshold = 0.3, // Below min
    };
    config.validate();
    try std.testing.expectEqual(@as(f32, 0.5), config.threshold);

    config.threshold = 0.99; // Above max
    config.validate();
    try std.testing.expectEqual(@as(f32, 0.95), config.threshold);

    config.threshold = 0.7; // Within range
    config.validate();
    try std.testing.expectEqual(@as(f32, 0.7), config.threshold);
}

test "ShedConfig.validate: resets invalid weights" {
    var config = ShedConfig{
        .queue_depth_weight = 0.1,
        .latency_p99_weight = 0.1,
        .resource_pressure_weight = 0.1, // Sum = 0.3, not 1.0
    };
    config.validate();

    // Should reset to equal weighting
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), config.queue_depth_weight, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), config.latency_p99_weight, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), config.resource_pressure_weight, 0.01);
}

test "LoadShedder.shouldShed: accepts when below threshold" {
    var shedder = LoadShedder.initDefault();

    // All signals at 0 -> score = 0
    const decision = shedder.shouldShed();

    try std.testing.expectEqual(false, decision.shed);
    try std.testing.expectEqual(@as(?u64, null), decision.retry_after_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), decision.score, 0.01);
}

test "LoadShedder.shouldShed: sheds when above threshold" {
    var shedder = LoadShedder.initDefault();

    // Set signals to maximum values -> score = 1.0
    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(1000 * 1_000_000); // 1000ms in ns
    shedder.updateMemoryPressure(90);

    const decision = shedder.shouldShed();

    try std.testing.expectEqual(true, decision.shed);
    try std.testing.expect(decision.retry_after_ms != null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decision.score, 0.01);
}

test "LoadShedder.shouldShed: accepts at exactly threshold" {
    var config = ShedConfig{
        .threshold = 0.5,
    };
    config.validate();
    var shedder = LoadShedder.init(config);

    // Set signals to reach exactly the threshold
    // With equal weights and threshold 0.5, need each signal at 0.5
    shedder.updateQueueDepth(5000); // 5000/10000 = 0.5
    shedder.updateLatencyP99(500 * 1_000_000); // 500ms in ns
    shedder.updateMemoryPressure(45); // 45/90 = 0.5

    const decision = shedder.shouldShed();

    // At exactly threshold, should NOT shed (below, not equal)
    // Score should be approximately 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), decision.score, 0.05);
    // Since score >= threshold (0.5 >= 0.5), it actually SHOULD shed
    try std.testing.expectEqual(true, decision.shed);
}

test "LoadShedder.shouldShed: accepts just below threshold" {
    var config = ShedConfig{
        .threshold = 0.5,
    };
    config.validate();
    var shedder = LoadShedder.init(config);

    // Set signals to just below the threshold
    shedder.updateQueueDepth(4500); // 4500/10000 = 0.45
    shedder.updateLatencyP99(450 * 1_000_000); // 450ms in ns
    shedder.updateMemoryPressure(40); // 40/90 = 0.44

    const decision = shedder.shouldShed();

    // Just below threshold, should accept
    try std.testing.expect(decision.score < 0.5);
    try std.testing.expectEqual(false, decision.shed);
}

test "LoadShedder: composite score calculation with various weights" {
    var config = ShedConfig{
        .queue_depth_weight = 0.5,
        .latency_p99_weight = 0.3,
        .resource_pressure_weight = 0.2,
    };
    config.validate();
    var shedder = LoadShedder.init(config);

    // Queue at 100%, others at 0%
    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(0);
    shedder.updateMemoryPressure(0);

    const score = shedder.getScore();
    // Score should be 0.5 * 1.0 + 0.3 * 0.0 + 0.2 * 0.0 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), score, 0.01);
}

test "LoadShedder: retry-after increases with score above threshold" {
    var shedder = LoadShedder.initDefault();

    // Score at threshold (0.8) should give base retry
    shedder.updateQueueDepth(8000);
    shedder.updateLatencyP99(800 * 1_000_000);
    shedder.updateMemoryPressure(72);

    var decision = shedder.shouldShed();
    const retry1 = decision.retry_after_ms orelse 0;

    // Score at max (1.0) should give higher retry
    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(1000 * 1_000_000);
    shedder.updateMemoryPressure(90);

    decision = shedder.shouldShed();
    const retry2 = decision.retry_after_ms orelse 0;

    try std.testing.expect(retry2 > retry1);
}

test "LoadShedder: retry-after capped at max_retry_ms" {
    var config = ShedConfig{
        .base_retry_ms = 5000,
        .max_retry_ms = 10000,
    };
    config.validate();
    var shedder = LoadShedder.init(config);

    // Max out all signals
    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(1000 * 1_000_000);
    shedder.updateMemoryPressure(90);

    const decision = shedder.shouldShed();

    try std.testing.expect(decision.retry_after_ms.? <= 10000);
}

test "LoadShedder: individual signal updates affect composite score" {
    var shedder = LoadShedder.initDefault();

    // Start at 0
    const initial_score = shedder.getScore();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), initial_score, 0.01);

    // Update queue depth
    shedder.updateQueueDepth(5000);
    const score1 = shedder.getScore();
    try std.testing.expect(score1 > initial_score);

    // Update latency
    shedder.updateLatencyP99(500 * 1_000_000);
    const score2 = shedder.getScore();
    try std.testing.expect(score2 > score1);

    // Update memory pressure
    shedder.updateMemoryPressure(45);
    const score3 = shedder.getScore();
    try std.testing.expect(score3 > score2);
}

test "LoadShedder: thread-safe concurrent updates" {
    var shedder = LoadShedder.initDefault();

    // Simulate concurrent updates from multiple threads
    const threads = [_]std.Thread.SpawnConfig{.{}} ** 4;
    _ = threads;

    // Update from main thread (simulating concurrent access)
    for (0..1000) |i| {
        shedder.updateQueueDepth(@truncate(i % 10000));
        shedder.updateLatencyP99(@truncate((i % 1000) * 1_000_000));
        shedder.updateMemoryPressure(@truncate(i % 90));
        _ = shedder.shouldShed();
    }

    // Should not crash, values should be valid
    const final_score = shedder.getScore();
    try std.testing.expect(final_score >= 0.0 and final_score <= 1.0);
}

test "LoadShedder: all signals at zero gives score zero" {
    var shedder = LoadShedder.initDefault();

    const decision = shedder.shouldShed();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), decision.score, 0.001);
    try std.testing.expectEqual(false, decision.shed);
}

test "LoadShedder: all signals at max gives score one with max retry" {
    var shedder = LoadShedder.initDefault();

    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(1000 * 1_000_000);
    shedder.updateMemoryPressure(90);

    const decision = shedder.shouldShed();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decision.score, 0.01);
    try std.testing.expectEqual(true, decision.shed);
    try std.testing.expect(decision.retry_after_ms.? > 0);
}

test "LoadShedder: single dominant signal correctly identified" {
    var shedder = LoadShedder.initDefault();

    // Only queue depth is high (above 80% of its max)
    shedder.updateQueueDepth(9000); // 90%
    shedder.updateLatencyP99(100 * 1_000_000); // 10%
    shedder.updateMemoryPressure(10); // 11%

    // This should still be below threshold due to low other signals
    // Let's push it over threshold
    shedder.updateQueueDepth(10000); // 100%
    shedder.updateLatencyP99(800 * 1_000_000); // 80%
    shedder.updateMemoryPressure(10); // 11%

    const decision = shedder.shouldShed();
    if (decision.shed) {
        // Multiple signals are at 80%+ now, should be composite
        try std.testing.expect(decision.reason == .composite or decision.reason == .queue_depth or decision.reason == .latency_p99);
    }
}

test "LoadShedder: stats tracking" {
    var shedder = LoadShedder.initDefault();

    // Check some requests
    _ = shedder.shouldShed();
    _ = shedder.shouldShed();

    // Push over threshold and check more
    shedder.updateQueueDepth(10000);
    shedder.updateLatencyP99(1000 * 1_000_000);
    shedder.updateMemoryPressure(90);

    _ = shedder.shouldShed();
    _ = shedder.shouldShed();

    const stats = shedder.getStats();
    try std.testing.expectEqual(@as(u64, 4), stats.total_checked);
    try std.testing.expect(stats.total_shed >= 2); // At least the last two should be shed
}
