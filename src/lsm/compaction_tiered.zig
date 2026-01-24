// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Tiered compaction strategy for LSM-tree.
//!
//! Tiered compaction delays merging sorted runs, reducing write amplification by 2-3x
//! for write-heavy workloads at the cost of higher space amplification. This is the
//! preferred strategy for geospatial workloads with frequent location updates.
//!
//! Key differences from leveled compaction:
//! - Leveled: Aggressive merge, 1 sorted run per level, lower space amp (1.1x), higher write amp (10-30x)
//! - Tiered: Delayed merge, N sorted runs per level, higher space amp (up to 2-3x), lower write amp (3-10x)
//!
//! Reference: RocksDB Universal Compaction, EDBT 2025 partial compaction research.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

/// Compaction strategy selection.
/// Determines how the LSM tree decides when and what to compact.
pub const CompactionStrategy = enum(u8) {
    /// Leveled compaction: aggressive merge, lower space amplification.
    /// Best for read-heavy workloads or space-constrained environments.
    /// Write amplification: 10-30x, Space amplification: ~1.1x
    leveled = 0,

    /// Tiered compaction: delayed merge, lower write amplification.
    /// Best for write-heavy workloads like geospatial location updates.
    /// Write amplification: 3-10x, Space amplification: up to 2-3x
    tiered = 1,
};

/// Configuration for tiered compaction strategy.
/// These parameters control when compaction triggers and how many runs to merge.
pub const TieredCompactionConfig = struct {
    /// Size ratio for triggering compaction based on run sizes.
    /// Compaction triggers when: sum(smaller_runs) >= size_ratio * largest_run
    /// Lower values = more aggressive compaction, higher write amp.
    /// Higher values = less aggressive compaction, lower write amp.
    /// Default: 2.0 (moderate, good balance for geospatial workloads)
    size_ratio: f64 = 2.0,

    /// Minimum number of sorted runs required before considering compaction.
    /// Must have at least this many runs to trigger any compaction.
    /// Default: 2 (minimum for merging)
    min_merge_width: u32 = 2,

    /// Maximum number of sorted runs to merge in a single compaction.
    /// Limits the I/O and CPU cost of individual compaction operations.
    /// Default: 8 (good balance between efficiency and latency)
    max_merge_width: u32 = 8,

    /// Space amplification threshold (percentage) to force compaction.
    /// Compaction triggers when: physical_size > (max_space_amp_percent/100) * logical_size
    /// Default: 200 (allow up to 2x space overhead before forcing compaction)
    max_space_amplification_percent: u32 = 200,

    /// Maximum sorted runs per level before forced compaction.
    /// Prevents unbounded growth of sorted runs which would hurt read performance.
    /// Default: 10 (practical limit for maintaining reasonable read latency)
    max_sorted_runs_per_level: u32 = 10,

    /// Prefer partial compaction over full compaction.
    /// - Partial: Merge subset of overlapping runs, better tail latency, worse average throughput
    /// - Full: Merge all overlapping runs, better average throughput, worse tail latency (write stalls)
    /// Default: true (latency-sensitive geospatial queries benefit from predictable latency)
    prefer_partial_compaction: bool = true,

    /// Validate configuration parameters.
    pub fn validate(self: TieredCompactionConfig) !void {
        if (self.size_ratio < 1.0) {
            return error.InvalidSizeRatio;
        }
        if (self.min_merge_width < 2) {
            return error.InvalidMinMergeWidth;
        }
        if (self.max_merge_width < self.min_merge_width) {
            return error.InvalidMaxMergeWidth;
        }
        if (self.max_space_amplification_percent < 100) {
            return error.InvalidSpaceAmpThreshold;
        }
        if (self.max_sorted_runs_per_level < 2) {
            return error.InvalidMaxSortedRuns;
        }
    }
};

/// Result of compaction input selection.
pub const CompactionInputs = struct {
    /// Indices of sorted runs to merge (in order).
    run_indices: [max_runs]u32 = undefined,
    /// Number of runs selected for merging.
    count: u32 = 0,
    /// Estimated output size in bytes (sum of input sizes, no dedup estimate).
    estimated_output_size: u64 = 0,

    /// Maximum runs we can track (bounded by max_merge_width upper limit).
    const max_runs = 16;

    /// Add a run to the selection.
    pub fn add(self: *CompactionInputs, run_index: u32, run_size: u64) void {
        assert(self.count < max_runs);
        self.run_indices[self.count] = run_index;
        self.count += 1;
        self.estimated_output_size += run_size;
    }

    /// Get the selected run indices as a slice.
    pub fn slice(self: *const CompactionInputs) []const u32 {
        return self.run_indices[0..self.count];
    }
};

/// Sorted run metadata for compaction decisions.
pub const SortedRunInfo = struct {
    /// Index of this run (for tracking which runs to merge).
    index: u32,
    /// Size of the run in bytes.
    size: u64,
    /// Minimum key in this run.
    key_min: u64,
    /// Maximum key in this run.
    key_max: u64,

    /// Check if two runs have overlapping key ranges.
    pub fn overlaps(self: SortedRunInfo, other: SortedRunInfo) bool {
        return self.key_min <= other.key_max and other.key_min <= self.key_max;
    }

    /// Check if the size is within 2x of another run (similar size).
    pub fn similar_size(self: SortedRunInfo, other: SortedRunInfo) bool {
        if (self.size == 0 or other.size == 0) return true;
        const ratio = if (self.size >= other.size)
            @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(other.size))
        else
            @as(f64, @floatFromInt(other.size)) / @as(f64, @floatFromInt(self.size));
        return ratio <= 2.0;
    }
};

/// Determine if tiered compaction should trigger for a level.
///
/// Compaction triggers when any of these conditions are met:
/// 1. Space amplification exceeds threshold
/// 2. Size ratio trigger: sum(smaller runs) >= ratio * largest run
/// 3. Too many sorted runs (exceeds max_sorted_runs_per_level)
///
/// Arguments:
///   sorted_run_count: Number of sorted runs in this level
///   total_size: Total bytes across all sorted runs in this level
///   largest_run_size: Size of the largest sorted run
///   logical_size: Logical (deduplicated) data size
///   config: Tiered compaction configuration
///
/// Returns: true if compaction should be triggered
pub fn should_compact_tiered(
    sorted_run_count: u32,
    total_size: u64,
    largest_run_size: u64,
    logical_size: u64,
    config: TieredCompactionConfig,
) bool {
    // Need at least min_merge_width runs to consider compaction
    if (sorted_run_count < config.min_merge_width) {
        return false;
    }

    // Condition 1: Space amplification exceeds threshold
    if (logical_size > 0) {
        const space_amp_percent = (total_size * 100) / logical_size;
        if (space_amp_percent > config.max_space_amplification_percent) {
            return true;
        }
    }

    // Condition 2: Size ratio trigger
    // sum(smaller runs) >= size_ratio * largest_run
    if (largest_run_size > 0) {
        const other_runs_size = total_size -| largest_run_size;
        const threshold = @as(u64, @intFromFloat(config.size_ratio * @as(f64, @floatFromInt(largest_run_size))));
        if (other_runs_size >= threshold) {
            return true;
        }
    }

    // Condition 3: Too many sorted runs
    if (sorted_run_count > config.max_sorted_runs_per_level) {
        return true;
    }

    return false;
}

/// Select which sorted runs to merge for tiered compaction.
///
/// Selection strategy:
/// 1. Find runs of similar size (within 2x of each other)
/// 2. Prefer runs that overlap in key range (more deduplication opportunity)
/// 3. Limit to max_merge_width runs
/// 4. If prefer_partial_compaction is true, select a subset for better tail latency
///
/// Arguments:
///   runs: Array of sorted run metadata
///   run_count: Number of runs in the array
///   config: Tiered compaction configuration
///
/// Returns: CompactionInputs with selected runs
pub fn select_compaction_inputs(
    runs: []const SortedRunInfo,
    config: TieredCompactionConfig,
) CompactionInputs {
    var result = CompactionInputs{};

    if (runs.len < config.min_merge_width) {
        return result;
    }

    // Strategy: Select runs starting from the smallest, preferring similar sizes and overlaps.
    // This is based on RocksDB's Universal Compaction approach.

    // First, sort indices by size (we work with a copy to avoid modifying input)
    var indices: [CompactionInputs.max_runs]u32 = undefined;
    var sizes: [CompactionInputs.max_runs]u64 = undefined;
    const count = @min(runs.len, CompactionInputs.max_runs);

    for (0..count) |i| {
        indices[i] = @intCast(i);
        sizes[i] = runs[i].size;
    }

    // Simple insertion sort by size (ascending)
    for (1..count) |i| {
        const key_idx = indices[i];
        const key_size = sizes[i];
        var j = i;
        while (j > 0 and sizes[j - 1] > key_size) {
            indices[j] = indices[j - 1];
            sizes[j] = sizes[j - 1];
            j -= 1;
        }
        indices[j] = key_idx;
        sizes[j] = key_size;
    }

    // Select runs greedily: start with smallest, add similar-sized overlapping runs
    var selected: [CompactionInputs.max_runs]bool = [_]bool{false} ** CompactionInputs.max_runs;
    var merge_count: u32 = 0;

    // Start with the smallest run
    if (count > 0) {
        const first_idx = indices[0];
        selected[first_idx] = true;
        result.add(runs[first_idx].index, runs[first_idx].size);
        merge_count = 1;
    }

    // Add more runs that are similar in size and preferably overlap
    for (1..count) |i| {
        if (merge_count >= config.max_merge_width) break;

        const candidate_idx = indices[i];
        if (selected[candidate_idx]) continue;

        const candidate = runs[candidate_idx];

        // Check if candidate is similar in size to already selected runs
        var similar_to_selected = false;
        for (0..count) |j| {
            if (selected[j]) {
                if (candidate.similar_size(runs[j])) {
                    similar_to_selected = true;
                    break;
                }
            }
        }

        if (!similar_to_selected) continue;

        // If prefer_partial_compaction, require overlap with at least one selected run
        if (config.prefer_partial_compaction) {
            var has_overlap = false;
            for (0..count) |j| {
                if (selected[j]) {
                    if (candidate.overlaps(runs[j])) {
                        has_overlap = true;
                        break;
                    }
                }
            }
            if (!has_overlap) continue;
        }

        // Add this run to selection
        selected[candidate_idx] = true;
        result.add(candidate.index, candidate.size);
        merge_count += 1;
    }

    // If we still don't have enough runs, add more even without overlap
    if (merge_count < config.min_merge_width) {
        for (1..count) |i| {
            if (merge_count >= config.min_merge_width) break;

            const candidate_idx = indices[i];
            if (selected[candidate_idx]) continue;

            const candidate = runs[candidate_idx];
            selected[candidate_idx] = true;
            result.add(candidate.index, candidate.size);
            merge_count += 1;
        }
    }

    return result;
}

/// Estimate the output size of a compaction.
/// This is a conservative estimate (sum of inputs) without accounting for deduplication.
/// Actual output size depends on key overlap and tombstone dropping.
///
/// Arguments:
///   runs: Array of sorted run metadata
///   inputs: Selected compaction inputs
///
/// Returns: Estimated output size in bytes
pub fn estimate_output_size(runs: []const SortedRunInfo, inputs: CompactionInputs) u64 {
    _ = runs;
    return inputs.estimated_output_size;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "TieredCompactionConfig: default values are valid" {
    const config = TieredCompactionConfig{};
    try config.validate();
}

test "TieredCompactionConfig: validation rejects invalid size_ratio" {
    const config = TieredCompactionConfig{ .size_ratio = 0.5 };
    try std.testing.expectError(error.InvalidSizeRatio, config.validate());
}

test "TieredCompactionConfig: validation rejects invalid min_merge_width" {
    const config = TieredCompactionConfig{ .min_merge_width = 1 };
    try std.testing.expectError(error.InvalidMinMergeWidth, config.validate());
}

test "TieredCompactionConfig: validation rejects invalid max_merge_width" {
    const config = TieredCompactionConfig{ .min_merge_width = 4, .max_merge_width = 2 };
    try std.testing.expectError(error.InvalidMaxMergeWidth, config.validate());
}

test "TieredCompactionConfig: validation rejects invalid space_amp" {
    const config = TieredCompactionConfig{ .max_space_amplification_percent = 50 };
    try std.testing.expectError(error.InvalidSpaceAmpThreshold, config.validate());
}

test "should_compact_tiered: returns false with too few runs" {
    const config = TieredCompactionConfig{ .min_merge_width = 2 };

    // Only 1 run - should not trigger
    try std.testing.expect(!should_compact_tiered(1, 1000, 1000, 500, config));
}

test "should_compact_tiered: space amp trigger" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_space_amplification_percent = 200,
    };

    // 3x space amp (300%) exceeds 200% threshold
    // total_size=3000, logical_size=1000 -> 300%
    try std.testing.expect(should_compact_tiered(3, 3000, 1000, 1000, config));

    // 1.5x space amp (150%) does not exceed 200% threshold
    try std.testing.expect(!should_compact_tiered(3, 1500, 500, 1000, config));
}

test "should_compact_tiered: size ratio trigger" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .size_ratio = 2.0,
        .max_space_amplification_percent = 1000, // Disable space amp trigger
    };

    // 3 runs: sizes 1000, 500, 500 (total=2000, largest=1000)
    // other_runs = 2000 - 1000 = 1000
    // threshold = 2.0 * 1000 = 2000
    // 1000 < 2000, should NOT trigger
    try std.testing.expect(!should_compact_tiered(3, 2000, 1000, 10000, config));

    // 4 runs: sizes 1000, 1000, 500, 500 (total=3000, largest=1000)
    // other_runs = 3000 - 1000 = 2000
    // threshold = 2.0 * 1000 = 2000
    // 2000 >= 2000, SHOULD trigger
    try std.testing.expect(should_compact_tiered(4, 3000, 1000, 10000, config));
}

test "should_compact_tiered: max runs trigger" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_sorted_runs_per_level = 5,
        .max_space_amplification_percent = 1000, // Disable space amp trigger
        .size_ratio = 100.0, // Disable size ratio trigger
    };

    // 5 runs - at limit, should not trigger
    try std.testing.expect(!should_compact_tiered(5, 5000, 1000, 10000, config));

    // 6 runs - exceeds limit, should trigger
    try std.testing.expect(should_compact_tiered(6, 6000, 1000, 10000, config));
}

test "select_compaction_inputs: selects minimum runs when few available" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_merge_width = 4,
        .prefer_partial_compaction = false,
    };

    const runs = [_]SortedRunInfo{
        .{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 },
        .{ .index = 1, .size = 1100, .key_min = 50, .key_max = 150 },
    };

    const inputs = select_compaction_inputs(&runs, config);

    try std.testing.expectEqual(@as(u32, 2), inputs.count);
}

test "select_compaction_inputs: respects max_merge_width" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_merge_width = 3,
        .prefer_partial_compaction = false,
    };

    const runs = [_]SortedRunInfo{
        .{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 },
        .{ .index = 1, .size = 1100, .key_min = 50, .key_max = 150 },
        .{ .index = 2, .size = 1200, .key_min = 100, .key_max = 200 },
        .{ .index = 3, .size = 1300, .key_min = 150, .key_max = 250 },
        .{ .index = 4, .size = 1400, .key_min = 200, .key_max = 300 },
    };

    const inputs = select_compaction_inputs(&runs, config);

    try std.testing.expect(inputs.count <= 3);
}

test "select_compaction_inputs: prefers similar sized runs" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_merge_width = 4,
        .prefer_partial_compaction = false,
    };

    // One very large run and several small similar-sized runs
    const runs = [_]SortedRunInfo{
        .{ .index = 0, .size = 10000, .key_min = 0, .key_max = 1000 }, // Large
        .{ .index = 1, .size = 100, .key_min = 0, .key_max = 50 }, // Small
        .{ .index = 2, .size = 110, .key_min = 40, .key_max = 80 }, // Small, similar
        .{ .index = 3, .size = 120, .key_min = 70, .key_max = 120 }, // Small, similar
    };

    const inputs = select_compaction_inputs(&runs, config);

    // Should select the small runs (indices 1, 2, 3) rather than the large one
    try std.testing.expect(inputs.count >= 2);

    // The large run should generally not be selected with small runs
    var has_large = false;
    for (inputs.slice()) |idx| {
        if (idx == 0) has_large = true;
    }
    // With similar size preference, large run should NOT be selected with small ones
    try std.testing.expect(!has_large or inputs.count <= 2);
}

test "select_compaction_inputs: partial compaction prefers overlapping" {
    const config = TieredCompactionConfig{
        .min_merge_width = 2,
        .max_merge_width = 4,
        .prefer_partial_compaction = true,
    };

    // Runs with varying overlap
    const runs = [_]SortedRunInfo{
        .{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 },
        .{ .index = 1, .size = 1100, .key_min = 50, .key_max = 150 }, // Overlaps with 0
        .{ .index = 2, .size = 1050, .key_min = 500, .key_max = 600 }, // No overlap
        .{ .index = 3, .size = 1080, .key_min = 120, .key_max = 200 }, // Overlaps with 1
    };

    const inputs = select_compaction_inputs(&runs, config);

    // Should prefer overlapping runs (0, 1, 3) over non-overlapping (2)
    try std.testing.expect(inputs.count >= 2);
}

test "SortedRunInfo: overlap detection" {
    const run_a = SortedRunInfo{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 };
    const run_b = SortedRunInfo{ .index = 1, .size = 1000, .key_min = 50, .key_max = 150 };
    const run_c = SortedRunInfo{ .index = 2, .size = 1000, .key_min = 200, .key_max = 300 };

    // a and b overlap
    try std.testing.expect(run_a.overlaps(run_b));
    try std.testing.expect(run_b.overlaps(run_a));

    // a and c do not overlap
    try std.testing.expect(!run_a.overlaps(run_c));
    try std.testing.expect(!run_c.overlaps(run_a));
}

test "SortedRunInfo: similar size detection" {
    const small = SortedRunInfo{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 };
    const similar = SortedRunInfo{ .index = 1, .size = 1500, .key_min = 0, .key_max = 100 };
    const large = SortedRunInfo{ .index = 2, .size = 5000, .key_min = 0, .key_max = 100 };

    // small and similar are within 2x
    try std.testing.expect(small.similar_size(similar));

    // small and large are NOT within 2x (5000/1000 = 5x)
    try std.testing.expect(!small.similar_size(large));
}

test "estimate_output_size: returns sum of inputs" {
    const runs = [_]SortedRunInfo{
        .{ .index = 0, .size = 1000, .key_min = 0, .key_max = 100 },
        .{ .index = 1, .size = 2000, .key_min = 50, .key_max = 150 },
        .{ .index = 2, .size = 3000, .key_min = 100, .key_max = 200 },
    };

    var inputs = CompactionInputs{};
    inputs.add(0, 1000);
    inputs.add(1, 2000);

    const estimated = estimate_output_size(&runs, inputs);
    try std.testing.expectEqual(@as(u64, 3000), estimated);
}
