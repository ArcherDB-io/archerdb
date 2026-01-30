// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Workload-aware adaptive compaction auto-tuning.
//!
//! This module implements automatic compaction parameter adjustment based on
//! observed workload patterns. Most deployments shouldn't need manual compaction
//! tuning - the adaptive system detects workload type (write-heavy, read-heavy,
//! scan-heavy, balanced) and adjusts parameters accordingly.
//!
//! Key features:
//! - **Dual trigger**: Parameters only adjust when BOTH conditions are met:
//!   1. Write throughput change > threshold (e.g., 20%)
//!   2. Space amplification > threshold (e.g., 2x)
//!   This prevents unnecessary adjustments from transient changes.
//!
//! - **Workload classification**: Automatically detects:
//!   - write_heavy: >70% writes, optimize for write throughput
//!   - read_heavy: >70% reads, optimize for read latency
//!   - scan_heavy: >30% range scans, optimize for sequential reads
//!   - balanced: moderate mix, use default settings
//!
//! - **Guardrails**: All parameter adjustments are bounded to prevent
//!   extreme configurations. Operators can override adaptive settings.
//!
//! Reference: RocksDB Auto-tuning, TiKV Workload Detection.

const std = @import("std");
const assert = std.debug.assert;

/// Detected workload type based on operation mix.
pub const WorkloadType = enum(u8) {
    /// >70% writes - optimize for write throughput.
    /// Recommendation: higher L0 trigger, more compaction threads.
    write_heavy = 0,

    /// >70% reads - optimize for read latency.
    /// Recommendation: lower L0 trigger, fewer threads for less I/O interference.
    read_heavy = 1,

    /// 30-70% writes - use balanced settings.
    /// Recommendation: moderate L0 trigger and threads.
    balanced = 2,

    /// >30% range scans - optimize for sequential reads.
    /// Recommendation: prefer larger sorted runs, partial compaction.
    scan_heavy = 3,

    /// Convert to u8 for metrics export.
    pub fn toMetricValue(self: WorkloadType) u8 {
        return @intFromEnum(self);
    }

    /// Format for logging.
    pub fn name(self: WorkloadType) []const u8 {
        return switch (self) {
            .write_heavy => "write_heavy",
            .read_heavy => "read_heavy",
            .balanced => "balanced",
            .scan_heavy => "scan_heavy",
        };
    }
};

/// Configuration for adaptive compaction behavior.
/// All thresholds have sensible defaults. Operators can adjust these
/// based on their specific workload characteristics.
pub const AdaptiveConfig = struct {
    /// Enable adaptive compaction tuning.
    /// When disabled, all parameters use static defaults.
    enabled: bool = true,

    /// Write throughput change threshold to trigger evaluation.
    /// Adaptation only occurs when writes/sec changes by this percentage
    /// from the baseline. Prevents reacting to minor fluctuations.
    /// Default: 0.20 (20% change required).
    write_throughput_change_threshold: f64 = 0.20,

    /// Space amplification threshold for triggering adaptation.
    /// Adaptation only occurs when physical/logical size ratio exceeds this.
    /// Combined with write_throughput_change for dual trigger.
    /// Default: 2.0 (2x logical size = 2x space amplification).
    space_amp_threshold: f64 = 2.0,

    /// Sliding window duration for workload detection (milliseconds).
    /// Statistics are computed over this window to smooth short-term spikes.
    /// Longer windows = more stable detection, slower adaptation.
    /// Default: 60,000ms (1 minute).
    window_duration_ms: u64 = 60_000,

    /// Sample interval for collecting workload statistics (milliseconds).
    /// More frequent sampling = more accurate detection, higher overhead.
    /// Default: 1,000ms (1 second).
    sample_interval_ms: u64 = 1000,

    /// EMA smoothing factor for statistics (0.0 to 1.0).
    /// Higher = more responsive to recent changes, more volatile.
    /// Lower = smoother, slower to adapt.
    /// Default: 0.1 (alpha for exponential moving average).
    ema_alpha: f64 = 0.1,

    // =========================================================================
    // Guardrails - prevent extreme configurations
    // =========================================================================

    /// Minimum L0 compaction trigger (tables in L0 before flush to L1).
    /// Lower bound prevents too-frequent compactions.
    /// Default: 2.
    min_l0_trigger: u32 = 2,

    /// Maximum L0 compaction trigger.
    /// Upper bound prevents L0 from growing too large (read amplification).
    /// Default: 20.
    max_l0_trigger: u32 = 20,

    /// Minimum compaction threads.
    /// Lower bound ensures compaction makes progress.
    /// Default: 1.
    min_compaction_threads: u32 = 1,

    /// Maximum compaction threads.
    /// Upper bound prevents I/O saturation.
    /// Default: 4.
    max_compaction_threads: u32 = 4,

    // =========================================================================
    // Workload classification thresholds
    // =========================================================================

    /// Write ratio threshold for write_heavy classification.
    /// If writes / (writes + reads) > this, workload is write_heavy.
    /// Default: 0.70 (70% writes).
    write_heavy_threshold: f64 = 0.70,

    /// Read ratio threshold for read_heavy classification.
    /// If reads / (writes + reads) > this, workload is read_heavy.
    /// Default: 0.70 (70% reads).
    read_heavy_threshold: f64 = 0.70,

    /// Scan ratio threshold for scan_heavy classification.
    /// If scans / (reads + scans) > this AND not write_heavy, workload is scan_heavy.
    /// Default: 0.30 (30% scans).
    scan_heavy_threshold: f64 = 0.30,

    /// Validate configuration parameters.
    pub fn validate(self: AdaptiveConfig) !void {
        if (self.write_throughput_change_threshold < 0.05 or
            self.write_throughput_change_threshold > 0.5)
        {
            return error.InvalidWriteChangeThreshold;
        }
        if (self.space_amp_threshold < 1.5 or self.space_amp_threshold > 5.0) {
            return error.InvalidSpaceAmpThreshold;
        }
        if (self.min_l0_trigger < 1 or self.min_l0_trigger > self.max_l0_trigger) {
            return error.InvalidL0TriggerRange;
        }
        if (self.max_l0_trigger > 100) {
            return error.InvalidMaxL0Trigger;
        }
        if (self.min_compaction_threads < 1 or
            self.min_compaction_threads > self.max_compaction_threads)
        {
            return error.InvalidThreadRange;
        }
        if (self.ema_alpha <= 0.0 or self.ema_alpha > 1.0) {
            return error.InvalidEmaAlpha;
        }
    }
};

/// Recommended parameter adjustments from adaptive tuning.
pub const Recommendations = struct {
    /// Recommended L0 compaction trigger.
    l0_trigger: u32,

    /// Recommended compaction thread count.
    compaction_threads: u32,

    /// Whether to prefer partial compaction (better tail latency).
    prefer_partial_compaction: bool,

    /// Detected workload type that led to these recommendations.
    workload: WorkloadType,
};

/// Adaptive compaction state tracking and parameter recommendations.
///
/// This struct maintains workload statistics using exponential moving averages
/// and provides parameter recommendations based on detected workload patterns.
pub const AdaptiveState = struct {
    /// Currently detected workload type.
    detected_workload: WorkloadType = .balanced,

    // =========================================================================
    // Rolling statistics (EMA-smoothed)
    // =========================================================================

    /// Smoothed writes per second.
    writes_per_second: f64 = 0,

    /// Smoothed reads per second (point queries).
    reads_per_second: f64 = 0,

    /// Smoothed scans per second (range queries).
    scans_per_second: f64 = 0,

    /// Current space amplification (physical / logical).
    current_space_amp: f64 = 1.0,

    /// Current write amplification (bytes written / bytes inserted).
    current_write_amp: f64 = 1.0,

    // =========================================================================
    // Baseline tracking for change detection
    // =========================================================================

    /// Baseline writes per second for change detection.
    /// Updated after each adaptation to detect next significant change.
    baseline_writes_per_second: f64 = 0,

    /// Whether baseline has been established.
    baseline_established: bool = false,

    // =========================================================================
    // Timing
    // =========================================================================

    /// Timestamp of last sample (nanoseconds).
    last_sample_ns: i128 = 0,

    /// Number of samples in current window.
    samples_in_window: u32 = 0,

    // =========================================================================
    // Current tuned parameters
    // =========================================================================

    /// Current L0 compaction trigger (tables before flush).
    /// Default: 8 (write-heavy optimized) - ArcherDB is designed for IoT/telemetry
    /// with 90%+ writes, so we start with write-heavy defaults rather than balanced.
    /// Higher L0 trigger delays compaction, reducing write stalls.
    /// Optimization note (05-02): Changed from 4 to 8 to reduce initial write stalls
    /// during benchmark workloads before adaptive tuning kicks in.
    current_l0_trigger: u32 = 8,

    /// Current compaction thread count.
    /// Default: 3 (write-heavy optimized) - allows parallel compaction to keep up
    /// with high write rates while leaving headroom for query threads.
    /// Optimization note (05-02): Changed from 2 to 3 for write-heavy workloads.
    current_compaction_threads: u32 = 3,

    /// Current partial compaction preference.
    /// Default: false for write-heavy workloads - full compaction provides better
    /// sustained write throughput even though tail latency is slightly higher.
    /// Optimization note (05-02): Changed from true to false for write-heavy default.
    prefer_partial_compaction: bool = false,

    /// Initialize adaptive state with default values.
    pub fn init() AdaptiveState {
        return .{};
    }

    /// Reset state to initial values.
    pub fn reset(self: *AdaptiveState) void {
        self.* = AdaptiveState.init();
    }

    /// Check if enough time has passed since last sample.
    pub fn shouldSample(self: *const AdaptiveState, current_time_ns: i128, config: AdaptiveConfig) bool {
        if (!config.enabled) return false;
        const interval_ns: i128 = @as(i128, config.sample_interval_ms) * std.time.ns_per_ms;
        return (current_time_ns - self.last_sample_ns) >= interval_ns;
    }

    /// Sample current workload metrics.
    ///
    /// Called periodically (e.g., every second) to update rolling statistics.
    /// Uses exponential moving average (EMA) for smoothing:
    ///   new_value = alpha * sample + (1 - alpha) * old_value
    ///
    /// Arguments:
    ///   writes: Write operations since last sample
    ///   reads: Point read operations since last sample
    ///   scans: Range scan operations since last sample
    ///   elapsed_ms: Milliseconds since last sample
    ///   space_amp: Current space amplification ratio
    ///   write_amp: Current write amplification ratio
    ///   config: Adaptive configuration
    ///   current_time_ns: Current timestamp in nanoseconds
    pub fn sample(
        self: *AdaptiveState,
        writes: u64,
        reads: u64,
        scans: u64,
        elapsed_ms: u64,
        space_amp: f64,
        write_amp: f64,
        config: AdaptiveConfig,
        current_time_ns: i128,
    ) void {
        if (!config.enabled or elapsed_ms == 0) return;

        self.last_sample_ns = current_time_ns;

        // Calculate rates
        const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const writes_rate = @as(f64, @floatFromInt(writes)) / elapsed_sec;
        const reads_rate = @as(f64, @floatFromInt(reads)) / elapsed_sec;
        const scans_rate = @as(f64, @floatFromInt(scans)) / elapsed_sec;

        // EMA smoothing
        const alpha = config.ema_alpha;
        const one_minus_alpha = 1.0 - alpha;

        if (self.samples_in_window == 0) {
            // First sample - initialize directly
            self.writes_per_second = writes_rate;
            self.reads_per_second = reads_rate;
            self.scans_per_second = scans_rate;
        } else {
            // EMA update
            self.writes_per_second = alpha * writes_rate + one_minus_alpha * self.writes_per_second;
            self.reads_per_second = alpha * reads_rate + one_minus_alpha * self.reads_per_second;
            self.scans_per_second = alpha * scans_rate + one_minus_alpha * self.scans_per_second;
        }

        self.current_space_amp = space_amp;
        self.current_write_amp = write_amp;
        self.samples_in_window += 1;

        // Establish baseline after sufficient samples
        if (!self.baseline_established and self.samples_in_window >= 10) {
            self.baseline_writes_per_second = self.writes_per_second;
            self.baseline_established = true;
        }

        // Update workload classification
        self.detected_workload = self.detectWorkload(config);
    }

    /// Detect current workload type based on operation mix.
    fn detectWorkload(self: *const AdaptiveState, config: AdaptiveConfig) WorkloadType {
        const total_point_ops = self.writes_per_second + self.reads_per_second;
        const total_read_ops = self.reads_per_second + self.scans_per_second;

        // Avoid division by zero
        if (total_point_ops < 0.001 and total_read_ops < 0.001) {
            return .balanced;
        }

        // Calculate ratios
        const write_ratio = if (total_point_ops > 0.001)
            self.writes_per_second / total_point_ops
        else
            0.5;

        const scan_ratio = if (total_read_ops > 0.001)
            self.scans_per_second / total_read_ops
        else
            0.0;

        // Classify workload
        if (write_ratio > config.write_heavy_threshold) {
            return .write_heavy;
        }

        if (write_ratio < (1.0 - config.read_heavy_threshold)) {
            // More reads than writes
            if (scan_ratio > config.scan_heavy_threshold) {
                return .scan_heavy;
            }
            return .read_heavy;
        }

        // Check if scan-heavy even with balanced writes/reads
        if (scan_ratio > config.scan_heavy_threshold) {
            return .scan_heavy;
        }

        return .balanced;
    }

    /// Check if adaptation should occur based on dual trigger.
    ///
    /// Both conditions must be met:
    /// 1. Write throughput has changed significantly from baseline
    /// 2. Space amplification exceeds threshold
    ///
    /// This prevents unnecessary parameter churn from transient changes.
    pub fn shouldAdapt(self: *const AdaptiveState, config: AdaptiveConfig) bool {
        if (!config.enabled) return false;
        if (!self.baseline_established) return false;

        // Condition 1: Write throughput change
        const write_change: f64 = blk: {
            if (self.baseline_writes_per_second > 0.001) {
                break :blk @abs(self.writes_per_second - self.baseline_writes_per_second) /
                    self.baseline_writes_per_second;
            } else if (self.writes_per_second > 0.001) {
                break :blk 1.0; // Went from ~0 to some writes = 100% change
            } else {
                break :blk 0.0; // Both ~0 = no change
            }
        };

        const throughput_changed = write_change > config.write_throughput_change_threshold;

        // Condition 2: Space amplification
        const space_amp_exceeded = self.current_space_amp > config.space_amp_threshold;

        // Dual trigger: both conditions must be true
        return throughput_changed and space_amp_exceeded;
    }

    /// Get parameter recommendations based on detected workload.
    ///
    /// Recommendations are bounded by guardrails to prevent extreme configurations.
    /// The detected workload type determines the optimization strategy:
    ///
    /// - write_heavy: Higher L0 trigger (delay compaction), more threads
    /// - read_heavy: Lower L0 trigger (frequent compaction), fewer threads
    /// - scan_heavy: Prefer larger runs (less fragmentation), partial compaction
    /// - balanced: Moderate settings
    pub fn recommendAdjustments(self: *const AdaptiveState, config: AdaptiveConfig) Recommendations {
        var l0_trigger: u32 = undefined;
        var threads: u32 = undefined;
        var partial_compaction: bool = undefined;

        switch (self.detected_workload) {
            .write_heavy => {
                // Optimize for write throughput:
                // - Higher L0 trigger delays compaction, reducing write amplification
                // - More threads to handle burst compaction work
                l0_trigger = 12;
                threads = 4;
                partial_compaction = false; // Full compaction better for sustained writes
            },
            .read_heavy => {
                // Optimize for read latency:
                // - Lower L0 trigger keeps L0 small (fewer levels to search)
                // - Fewer threads reduce I/O interference with reads
                l0_trigger = 4;
                threads = 2;
                partial_compaction = true; // Better tail latency for reads
            },
            .scan_heavy => {
                // Optimize for range scans:
                // - Moderate L0 trigger balances write/read
                // - Prefer larger sorted runs for sequential access
                // - Partial compaction for predictable latency
                l0_trigger = 6;
                threads = 2;
                partial_compaction = true;
            },
            .balanced => {
                // Moderate defaults
                l0_trigger = 6;
                threads = 2;
                partial_compaction = true;
            },
        }

        // Apply guardrails
        l0_trigger = @max(config.min_l0_trigger, @min(config.max_l0_trigger, l0_trigger));
        threads = @max(config.min_compaction_threads, @min(config.max_compaction_threads, threads));

        return Recommendations{
            .l0_trigger = l0_trigger,
            .compaction_threads = threads,
            .prefer_partial_compaction = partial_compaction,
            .workload = self.detected_workload,
        };
    }

    /// Apply recommendations and update baseline.
    ///
    /// Called after adaptation to:
    /// 1. Store new parameter values
    /// 2. Reset baseline for next change detection cycle
    pub fn applyRecommendations(self: *AdaptiveState, recommendations: Recommendations) void {
        self.current_l0_trigger = recommendations.l0_trigger;
        self.current_compaction_threads = recommendations.compaction_threads;
        self.prefer_partial_compaction = recommendations.prefer_partial_compaction;

        // Update baseline for next adaptation cycle
        self.baseline_writes_per_second = self.writes_per_second;
    }

    /// Get L0 trigger, respecting operator override if set.
    pub fn getL0Trigger(self: *const AdaptiveState, override: ?u32) u32 {
        return override orelse self.current_l0_trigger;
    }

    /// Get compaction threads, respecting operator override if set.
    pub fn getCompactionThreads(self: *const AdaptiveState, override: ?u32) u32 {
        return override orelse self.current_compaction_threads;
    }

    /// Get current workload type as metric value (0-3).
    pub fn getWorkloadMetric(self: *const AdaptiveState) u8 {
        return self.detected_workload.toMetricValue();
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "AdaptiveConfig: default values are valid" {
    const config = AdaptiveConfig{};
    try config.validate();
}

test "AdaptiveConfig: validation rejects invalid write change threshold" {
    const config_low = AdaptiveConfig{ .write_throughput_change_threshold = 0.01 };
    try std.testing.expectError(error.InvalidWriteChangeThreshold, config_low.validate());

    const config_high = AdaptiveConfig{ .write_throughput_change_threshold = 0.6 };
    try std.testing.expectError(error.InvalidWriteChangeThreshold, config_high.validate());
}

test "AdaptiveConfig: validation rejects invalid space amp threshold" {
    const config_low = AdaptiveConfig{ .space_amp_threshold = 1.0 };
    try std.testing.expectError(error.InvalidSpaceAmpThreshold, config_low.validate());

    const config_high = AdaptiveConfig{ .space_amp_threshold = 6.0 };
    try std.testing.expectError(error.InvalidSpaceAmpThreshold, config_high.validate());
}

test "AdaptiveConfig: validation rejects invalid L0 trigger range" {
    const config = AdaptiveConfig{ .min_l0_trigger = 10, .max_l0_trigger = 5 };
    try std.testing.expectError(error.InvalidL0TriggerRange, config.validate());
}

test "AdaptiveState: workload classification - write heavy" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Simulate high write workload: 1000 writes, 100 reads, 10 scans per second
    state.sample(10000, 1000, 100, 10000, 1.5, 5.0, config, 10_000_000_000);

    try std.testing.expectEqual(WorkloadType.write_heavy, state.detected_workload);
}

test "AdaptiveState: workload classification - read heavy" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Simulate high read workload: 100 writes, 1000 reads, 50 scans per second
    state.sample(1000, 10000, 500, 10000, 1.5, 5.0, config, 10_000_000_000);

    try std.testing.expectEqual(WorkloadType.read_heavy, state.detected_workload);
}

test "AdaptiveState: workload classification - scan heavy" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Simulate scan-heavy workload: 200 writes, 300 reads, 400 scans per second
    state.sample(2000, 3000, 4000, 10000, 1.5, 5.0, config, 10_000_000_000);

    try std.testing.expectEqual(WorkloadType.scan_heavy, state.detected_workload);
}

test "AdaptiveState: workload classification - balanced" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Simulate balanced workload: 500 writes, 500 reads, 100 scans per second
    state.sample(5000, 5000, 1000, 10000, 1.5, 5.0, config, 10_000_000_000);

    try std.testing.expectEqual(WorkloadType.balanced, state.detected_workload);
}

test "AdaptiveState: dual trigger - both conditions required" {
    var config = AdaptiveConfig{};
    config.write_throughput_change_threshold = 0.20;
    config.space_amp_threshold = 2.0;

    var state = AdaptiveState.init();

    // Establish baseline with 10 samples
    for (0..10) |i| {
        state.sample(1000, 500, 100, 1000, 1.5, 3.0, config, @as(i128, @intCast(i)) * 1_000_000_000);
    }
    try std.testing.expect(state.baseline_established);

    // Case 1: Only write change, no space amp - should NOT adapt
    state.writes_per_second = state.baseline_writes_per_second * 1.5; // 50% change
    state.current_space_amp = 1.5; // Below 2.0 threshold
    try std.testing.expect(!state.shouldAdapt(config));

    // Case 2: Only space amp, no write change - should NOT adapt
    state.writes_per_second = state.baseline_writes_per_second * 1.1; // 10% change (below 20%)
    state.current_space_amp = 2.5; // Above 2.0 threshold
    try std.testing.expect(!state.shouldAdapt(config));

    // Case 3: Both conditions met - SHOULD adapt
    state.writes_per_second = state.baseline_writes_per_second * 1.5; // 50% change
    state.current_space_amp = 2.5; // Above 2.0 threshold
    try std.testing.expect(state.shouldAdapt(config));
}

test "AdaptiveState: recommendations respect guardrails" {
    const config = AdaptiveConfig{
        .min_l0_trigger = 2,
        .max_l0_trigger = 10,
        .min_compaction_threads = 1,
        .max_compaction_threads = 3,
    };

    var state = AdaptiveState.init();

    // Even with extreme workload detection, recommendations stay within bounds
    state.detected_workload = .write_heavy;
    const rec = state.recommendAdjustments(config);

    try std.testing.expect(rec.l0_trigger >= config.min_l0_trigger);
    try std.testing.expect(rec.l0_trigger <= config.max_l0_trigger);
    try std.testing.expect(rec.compaction_threads >= config.min_compaction_threads);
    try std.testing.expect(rec.compaction_threads <= config.max_compaction_threads);
}

test "AdaptiveState: recommendations vary by workload" {
    const config = AdaptiveConfig{};
    var state = AdaptiveState.init();

    // Write-heavy should recommend higher L0 trigger than read-heavy
    state.detected_workload = .write_heavy;
    const write_rec = state.recommendAdjustments(config);

    state.detected_workload = .read_heavy;
    const read_rec = state.recommendAdjustments(config);

    try std.testing.expect(write_rec.l0_trigger > read_rec.l0_trigger);
    try std.testing.expect(write_rec.compaction_threads >= read_rec.compaction_threads);
}

test "AdaptiveState: operator override takes precedence" {
    var state = AdaptiveState.init();
    // Note: Default init values are write-heavy optimized (L0=8, threads=3)
    // Set explicit values to test override behavior
    state.current_l0_trigger = 6;
    state.current_compaction_threads = 2;

    // No override - use current adaptive values (which we just set)
    try std.testing.expectEqual(@as(u32, 6), state.getL0Trigger(null));
    try std.testing.expectEqual(@as(u32, 2), state.getCompactionThreads(null));

    // With override - use override values
    try std.testing.expectEqual(@as(u32, 10), state.getL0Trigger(10));
    try std.testing.expectEqual(@as(u32, 4), state.getCompactionThreads(4));
}

test "AdaptiveState: EMA smoothing" {
    const config = AdaptiveConfig{ .ema_alpha = 0.5 }; // 50% weight to new sample
    var state = AdaptiveState.init();

    // First sample: direct assignment
    state.sample(1000, 500, 100, 1000, 1.5, 3.0, config, 1_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), state.writes_per_second, 0.1);

    // Second sample: EMA smoothing
    // new = 0.5 * 2000 + 0.5 * 1000 = 1500
    state.sample(2000, 500, 100, 1000, 1.5, 3.0, config, 2_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1500.0), state.writes_per_second, 0.1);

    // Third sample: EMA continues
    // new = 0.5 * 1000 + 0.5 * 1500 = 1250
    state.sample(1000, 500, 100, 1000, 1.5, 3.0, config, 3_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1250.0), state.writes_per_second, 0.1);
}

test "AdaptiveState: apply recommendations updates baseline" {
    var state = AdaptiveState.init();
    state.writes_per_second = 1000.0;
    state.baseline_writes_per_second = 500.0;
    state.baseline_established = true;

    const rec = Recommendations{
        .l0_trigger = 8,
        .compaction_threads = 3,
        .prefer_partial_compaction = false,
        .workload = .write_heavy,
    };

    state.applyRecommendations(rec);

    // Parameters updated
    try std.testing.expectEqual(@as(u32, 8), state.current_l0_trigger);
    try std.testing.expectEqual(@as(u32, 3), state.current_compaction_threads);
    try std.testing.expect(!state.prefer_partial_compaction);

    // Baseline updated to current
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), state.baseline_writes_per_second, 0.1);
}

test "AdaptiveState: disabled config prevents sampling and adaptation" {
    const config = AdaptiveConfig{ .enabled = false };
    var state = AdaptiveState.init();

    // Should not sample when disabled
    try std.testing.expect(!state.shouldSample(1_000_000_000, config));

    // Should not adapt when disabled
    state.baseline_established = true;
    state.writes_per_second = 1000.0;
    state.baseline_writes_per_second = 100.0;
    state.current_space_amp = 3.0;
    try std.testing.expect(!state.shouldAdapt(config));
}

test "WorkloadType: metric values are correct" {
    try std.testing.expectEqual(@as(u8, 0), WorkloadType.write_heavy.toMetricValue());
    try std.testing.expectEqual(@as(u8, 1), WorkloadType.read_heavy.toMetricValue());
    try std.testing.expectEqual(@as(u8, 2), WorkloadType.balanced.toMetricValue());
    try std.testing.expectEqual(@as(u8, 3), WorkloadType.scan_heavy.toMetricValue());
}

test "WorkloadType: names are correct" {
    try std.testing.expectEqualStrings("write_heavy", WorkloadType.write_heavy.name());
    try std.testing.expectEqualStrings("read_heavy", WorkloadType.read_heavy.name());
    try std.testing.expectEqualStrings("balanced", WorkloadType.balanced.name());
    try std.testing.expectEqualStrings("scan_heavy", WorkloadType.scan_heavy.name());
}
