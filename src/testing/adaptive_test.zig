// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Integration tests for adaptive compaction auto-tuning.
//!
//! These tests verify Phase 12 success criteria:
//! "Adaptive compaction auto-tunes based on workload patterns without manual intervention"
//!
//! The tests demonstrate:
//! - Workload shift detection (write -> read -> scan -> balanced)
//! - Dual trigger requirement (prevents unnecessary adjustments)
//! - Parameter adjustment based on detected workload
//! - Operator override precedence

const std = @import("std");
const testing = std.testing;

const compaction_adaptive = @import("../lsm/compaction_adaptive.zig");
const AdaptiveState = compaction_adaptive.AdaptiveState;
const AdaptiveConfig = compaction_adaptive.AdaptiveConfig;
const WorkloadType = compaction_adaptive.WorkloadType;

// =============================================================================
// Test 1: Workload shift detection (write_heavy -> read_heavy)
// =============================================================================

test "adaptive: detects workload shift from write-heavy to read-heavy" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Phase 1: Establish write-heavy baseline (90% writes)
    // Need 10+ samples to establish baseline
    for (0..10) |i| {
        state.sample(
            9000, // writes (90%)
            1000, // reads (10%)
            100, // scans
            1000, // elapsed_ms = 1 second
            1.5, // space amp below threshold
            3.0, // write amp
            config,
            @as(i128, @intCast(i)) * std.time.ns_per_s,
        );
    }
    try testing.expect(state.baseline_established);
    try testing.expectEqual(WorkloadType.write_heavy, state.detected_workload);

    // Get initial recommendations for write-heavy workload
    const write_rec = state.recommendAdjustments(config);
    // Write-heavy recommends L0 trigger of 12 (higher to delay compaction)
    try testing.expectEqual(@as(u32, 12), write_rec.l0_trigger);

    // Phase 2: Shift to read-heavy (90% reads)
    // Continue sampling with new workload pattern
    for (0..20) |i| {
        state.sample(
            500, // writes (10%)
            9000, // reads (90%)
            100, // scans
            1000, // elapsed_ms = 1 second
            2.5, // space amp above threshold (triggers adaptation)
            3.0, // write amp
            config,
            @as(i128, @intCast(10 + i)) * std.time.ns_per_s,
        );
    }

    // Verify workload detected as read-heavy after samples establish pattern
    try testing.expectEqual(WorkloadType.read_heavy, state.detected_workload);

    // Get recommendations for read-heavy workload
    const read_rec = state.recommendAdjustments(config);

    // Verify parameter adjustment: read-heavy should have lower L0 trigger
    // Read-heavy recommends L0 trigger of 4 (lower for better read latency)
    try testing.expectEqual(@as(u32, 4), read_rec.l0_trigger);
    try testing.expect(read_rec.l0_trigger < write_rec.l0_trigger);

    // Read-heavy uses 2 threads (vs 4 for write-heavy)
    try testing.expect(read_rec.compaction_threads <= write_rec.compaction_threads);

    // Verify partial compaction preferred for read latency
    try testing.expect(read_rec.prefer_partial_compaction);
}

// =============================================================================
// Test 2: Workload shift to scan-heavy
// =============================================================================

test "adaptive: detects workload shift to scan-heavy" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Establish balanced baseline (50% writes, 50% reads, low scans)
    for (0..10) |i| {
        state.sample(
            5000, // writes
            5000, // reads
            500, // scans (low)
            1000, // elapsed_ms
            1.5, // space amp
            3.0, // write amp
            config,
            @as(i128, @intCast(i)) * std.time.ns_per_s,
        );
    }
    try testing.expectEqual(WorkloadType.balanced, state.detected_workload);

    // Shift to scan-heavy (>30% scans of read operations)
    // scans / (reads + scans) > 0.30 = scan_heavy
    for (0..20) |i| {
        state.sample(
            2000, // writes (low enough to not be write_heavy)
            4000, // reads
            4000, // scans (50% of reads+scans, way above 30% threshold)
            1000, // elapsed_ms
            2.5, // space amp above threshold
            3.0, // write amp
            config,
            @as(i128, @intCast(10 + i)) * std.time.ns_per_s,
        );
    }

    try testing.expectEqual(WorkloadType.scan_heavy, state.detected_workload);

    // Verify scan-heavy recommendations
    const rec = state.recommendAdjustments(config);
    // Scan-heavy prefers partial compaction for predictable latency
    try testing.expect(rec.prefer_partial_compaction);
    // Scan-heavy uses L0 trigger of 6 (moderate)
    try testing.expectEqual(@as(u32, 6), rec.l0_trigger);
}

// =============================================================================
// Test 3: No adaptation when conditions not met (single trigger)
// =============================================================================

test "adaptive: no adaptation without dual trigger" {
    var state = AdaptiveState.init();
    const config = AdaptiveConfig{};

    // Establish baseline with 10 samples
    for (0..10) |i| {
        state.sample(
            5000, // writes
            5000, // reads
            500, // scans
            1000, // elapsed_ms
            1.5, // space amp
            3.0, // write amp
            config,
            @as(i128, @intCast(i)) * std.time.ns_per_s,
        );
    }
    try testing.expect(state.baseline_established);

    const initial_l0 = state.current_l0_trigger;

    // Case 1: Write change WITHOUT space amp threshold
    // Simulate 50% change in writes but space amp stays below 2.0
    state.writes_per_second = state.baseline_writes_per_second * 1.5; // 50% change
    state.current_space_amp = 1.5; // Below 2.0 threshold
    try testing.expect(!state.shouldAdapt(config)); // Should NOT adapt

    // Case 2: Space amp WITHOUT write change
    // Space amp above threshold but writes changed by only 10%
    state.writes_per_second = state.baseline_writes_per_second * 1.1; // 10% change
    state.current_space_amp = 2.5; // Above 2.0 threshold
    try testing.expect(!state.shouldAdapt(config)); // Should NOT adapt

    // Case 3: Both conditions met - SHOULD adapt
    state.writes_per_second = state.baseline_writes_per_second * 1.5; // 50% change
    state.current_space_amp = 2.5; // Above 2.0 threshold
    try testing.expect(state.shouldAdapt(config)); // Now it SHOULD adapt

    // Verify parameters unchanged until we explicitly apply recommendations
    try testing.expectEqual(initial_l0, state.current_l0_trigger);
}

// =============================================================================
// Test 4: Operator override takes precedence
// =============================================================================

test "adaptive: operator override takes precedence over adaptive values" {
    var state = AdaptiveState.init();

    // Set adaptive values (simulating what adaptive tuning would set)
    state.current_l0_trigger = 8;
    state.current_compaction_threads = 3;

    // Without override - use adaptive values
    try testing.expectEqual(@as(u32, 8), state.getL0Trigger(null));
    try testing.expectEqual(@as(u32, 3), state.getCompactionThreads(null));

    // With override - operator values take precedence
    try testing.expectEqual(@as(u32, 4), state.getL0Trigger(4));
    try testing.expectEqual(@as(u32, 1), state.getCompactionThreads(1));

    // Different override values
    try testing.expectEqual(@as(u32, 20), state.getL0Trigger(20));
    try testing.expectEqual(@as(u32, 4), state.getCompactionThreads(4));
}
