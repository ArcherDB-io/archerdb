//! Skip-Scan Optimization for Spatial Range Queries (F3.3.4)
//!
//! This module implements block-level min/max filtering to skip irrelevant
//! blocks during LSM tree range scans, providing up to 90% I/O reduction
//! for selective spatial queries.
//!
//! ## Algorithm
//!
//! Skip-scan uses block header metadata (min_id, max_id) to determine if
//! a block can be skipped without reading its body:
//!
//! ```
//! For each block in table.blocks:
//!   header = read_block_header(block)  // 256 bytes, fast
//!
//!   if header.max_id < query_range.start:
//!     continue  // Block entirely before range, skip
//!
//!   if header.min_id > query_range.end:
//!     continue  // Block entirely after range, skip
//!
//!   body = read_block_body(block)  // Full block read, expensive
//!   // Process records in body that match range...
//! ```
//!
//! ## Performance Impact
//!
//! - Without skip-scan: Read all 1000 blocks × 64KB = 64MB
//! - With skip-scan (10% match): Read 100 blocks × 64KB = 6.4MB
//! - Savings: 90% I/O reduction for selective queries
//!
//! ## Current Status
//!
//! This module provides the skip-scan utilities. Integration with LSM Forest
//! scanning is pending (blocked on Forest integration tasks).
//!
//! When Forest is integrated, the query engine should use these utilities
//! in the prefetch phase to minimize I/O.

const std = @import("std");

/// Composite ID range for skip-scan filtering.
/// Represents a query range [start, end) for GeoEvent composite IDs.
pub const IdRange = struct {
    /// Inclusive start of range
    start: u128,
    /// Exclusive end of range
    end: u128,

    /// Check if a single ID falls within this range.
    pub fn contains(self: IdRange, id: u128) bool {
        return id >= self.start and id < self.end;
    }

    /// Check if two ranges overlap.
    pub fn overlaps(self: IdRange, other: IdRange) bool {
        return self.start < other.end and other.start < self.end;
    }
};

/// Block header metadata for skip-scan decisions.
/// This structure represents the min/max information stored in LSM block headers.
pub const BlockMetadata = struct {
    /// Minimum composite ID in this block
    min_id: u128,
    /// Maximum composite ID in this block
    max_id: u128,
    /// Number of records in this block
    count: u32,
    /// Block address (for I/O)
    address: u64,

    /// Determine if this block can be skipped for a given query range.
    ///
    /// Returns true if the block is entirely outside the query range
    /// and can be safely skipped without reading its body.
    pub fn canSkip(self: BlockMetadata, query: IdRange) bool {
        // Block entirely before range
        if (self.max_id < query.start) {
            return true;
        }

        // Block entirely after range
        if (self.min_id >= query.end) {
            return true;
        }

        // Block intersects range, cannot skip
        return false;
    }

    /// Determine if this block is entirely contained within the query range.
    ///
    /// If true, all records in the block match the range and no per-record
    /// filtering is needed.
    pub fn isFullyContained(self: BlockMetadata, query: IdRange) bool {
        return self.min_id >= query.start and self.max_id < query.end;
    }
};

/// Skip-scan statistics for monitoring and optimization.
pub const SkipScanStats = struct {
    /// Total blocks examined (headers read)
    blocks_examined: u64 = 0,
    /// Blocks skipped (body not read)
    blocks_skipped: u64 = 0,
    /// Blocks read (body read for record matching)
    blocks_read: u64 = 0,
    /// Records examined within read blocks
    records_examined: u64 = 0,
    /// Records matched (passed range filter)
    records_matched: u64 = 0,

    /// Reset statistics for a new query.
    pub fn reset(self: *SkipScanStats) void {
        self.* = .{};
    }

    /// Calculate skip ratio (0.0 = no skipping, 1.0 = all skipped).
    pub fn skipRatio(self: SkipScanStats) f64 {
        if (self.blocks_examined == 0) return 0.0;
        return @as(f64, @floatFromInt(self.blocks_skipped)) /
            @as(f64, @floatFromInt(self.blocks_examined));
    }

    /// Calculate I/O savings estimate (bytes not read).
    /// Assumes 64KB blocks.
    pub fn ioSavedBytes(self: SkipScanStats) u64 {
        const block_body_size: u64 = 64 * 1024 - 256; // 64KB - 256B header
        return self.blocks_skipped * block_body_size;
    }

    /// Export statistics in Prometheus format.
    pub fn toPrometheus(self: SkipScanStats, writer: anytype) !void {
        try writer.print("archerdb_skipscan_blocks_examined {d}\n", .{self.blocks_examined});
        try writer.print("archerdb_skipscan_blocks_skipped {d}\n", .{self.blocks_skipped});
        try writer.print("archerdb_skipscan_blocks_read {d}\n", .{self.blocks_read});
        try writer.print("archerdb_skipscan_records_examined {d}\n", .{self.records_examined});
        try writer.print("archerdb_skipscan_records_matched {d}\n", .{self.records_matched});
        try writer.print("archerdb_skipscan_skip_ratio {d:.4}\n", .{self.skipRatio()});
    }
};

/// Result of evaluating a block against a set of query ranges.
pub const BlockDecision = enum {
    /// Block can be skipped entirely (no overlap with any range)
    skip,
    /// Block may contain matching records (overlaps at least one range)
    scan,
    /// Block is fully contained in at least one range (all records match)
    full_match,
};

/// Evaluate a block against multiple query ranges (from S2 covering).
///
/// For spatial queries, we typically have multiple non-contiguous cell ranges.
/// A block can be skipped only if it doesn't overlap ANY of the ranges.
pub fn evaluateBlockMultiRange(
    block: BlockMetadata,
    ranges: []const IdRange,
) BlockDecision {
    var any_overlap = false;
    var all_contained = false;

    for (ranges) |range| {
        if (!block.canSkip(range)) {
            any_overlap = true;
            if (block.isFullyContained(range)) {
                all_contained = true;
                break; // Full match, no need to check more ranges
            }
        }
    }

    if (all_contained) {
        return .full_match;
    } else if (any_overlap) {
        return .scan;
    } else {
        return .skip;
    }
}

/// Convert S2 cell ranges to ID ranges for skip-scan filtering.
///
/// The composite ID format is [S2 Cell ID (upper 64) | Timestamp (lower 64)].
/// This function creates ID ranges that cover all timestamps for the given
/// cell ranges.
pub fn cellRangesToIdRanges(
    cell_ranges: []const CellRange,
    timestamp_min: u64,
    timestamp_max: u64,
    output: []IdRange,
) usize {
    var count: usize = 0;

    for (cell_ranges) |cell_range| {
        if (count >= output.len) break;

        // Skip empty ranges
        if (cell_range.start == 0 and cell_range.end == 0) {
            continue;
        }

        // Create composite ID range
        // [cell_start:timestamp_min, cell_end:timestamp_max)
        const start_id = (@as(u128, cell_range.start) << 64) | @as(u128, timestamp_min);
        const end_id = (@as(u128, cell_range.end) << 64) | @as(u128, timestamp_max);

        output[count] = .{
            .start = start_id,
            .end = end_id,
        };
        count += 1;
    }

    return count;
}

/// Cell range type (re-exported from s2_index for convenience).
pub const CellRange = struct {
    start: u64,
    end: u64,
};

// =============================================================================
// Tests
// =============================================================================

test "IdRange: contains" {
    const range = IdRange{ .start = 100, .end = 200 };

    // Inside range
    try std.testing.expect(range.contains(100));
    try std.testing.expect(range.contains(150));
    try std.testing.expect(range.contains(199));

    // Outside range
    try std.testing.expect(!range.contains(99));
    try std.testing.expect(!range.contains(200)); // End is exclusive
    try std.testing.expect(!range.contains(300));
}

test "IdRange: overlaps" {
    const range1 = IdRange{ .start = 100, .end = 200 };
    const range2 = IdRange{ .start = 150, .end = 250 };
    const range3 = IdRange{ .start = 200, .end = 300 }; // Adjacent but not overlapping
    const range4 = IdRange{ .start = 50, .end = 100 }; // Adjacent but not overlapping

    try std.testing.expect(range1.overlaps(range2));
    try std.testing.expect(!range1.overlaps(range3));
    try std.testing.expect(!range1.overlaps(range4));
}

test "BlockMetadata: canSkip" {
    const block = BlockMetadata{
        .min_id = 100,
        .max_id = 200,
        .count = 50,
        .address = 0x1000,
    };

    // Range entirely after block
    try std.testing.expect(block.canSkip(.{ .start = 300, .end = 400 }));

    // Range entirely before block
    try std.testing.expect(block.canSkip(.{ .start = 0, .end = 50 }));

    // Range overlaps block
    try std.testing.expect(!block.canSkip(.{ .start = 150, .end = 250 }));

    // Range contains block
    try std.testing.expect(!block.canSkip(.{ .start = 50, .end = 300 }));
}

test "BlockMetadata: isFullyContained" {
    const block = BlockMetadata{
        .min_id = 100,
        .max_id = 200,
        .count = 50,
        .address = 0x1000,
    };

    // Block fully contained in range
    try std.testing.expect(block.isFullyContained(.{ .start = 50, .end = 300 }));

    // Block partially in range
    try std.testing.expect(!block.isFullyContained(.{ .start = 150, .end = 300 }));

    // Block not in range at all
    try std.testing.expect(!block.isFullyContained(.{ .start = 300, .end = 400 }));
}

test "SkipScanStats: skipRatio" {
    var stats = SkipScanStats{
        .blocks_examined = 100,
        .blocks_skipped = 75,
        .blocks_read = 25,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 0.75), stats.skipRatio(), 0.001);

    // Edge case: no blocks examined
    stats.reset();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), stats.skipRatio(), 0.001);
}

test "evaluateBlockMultiRange: skip decision" {
    const block = BlockMetadata{
        .min_id = 100,
        .max_id = 200,
        .count = 50,
        .address = 0x1000,
    };

    // No overlapping ranges -> skip
    const ranges_skip = [_]IdRange{
        .{ .start = 0, .end = 50 },
        .{ .start = 300, .end = 400 },
    };
    try std.testing.expectEqual(BlockDecision.skip, evaluateBlockMultiRange(block, &ranges_skip));

    // One overlapping range -> scan
    const ranges_scan = [_]IdRange{
        .{ .start = 0, .end = 50 },
        .{ .start = 150, .end = 250 },
    };
    try std.testing.expectEqual(BlockDecision.scan, evaluateBlockMultiRange(block, &ranges_scan));

    // Block fully contained in one range -> full_match
    const ranges_full = [_]IdRange{
        .{ .start = 0, .end = 50 },
        .{ .start = 50, .end = 300 },
    };
    const result = evaluateBlockMultiRange(block, &ranges_full);
    try std.testing.expectEqual(BlockDecision.full_match, result);
}

test "cellRangesToIdRanges: conversion" {
    const cell_ranges = [_]CellRange{
        .{ .start = 0x1000, .end = 0x2000 },
        .{ .start = 0x3000, .end = 0x4000 },
        .{ .start = 0, .end = 0 }, // Empty, should be skipped
    };

    var id_ranges: [4]IdRange = undefined;
    const count = cellRangesToIdRanges(&cell_ranges, 0, std.math.maxInt(u64), &id_ranges);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u128, 0x1000) << 64, id_ranges[0].start);
    try std.testing.expectEqual((@as(u128, 0x2000) << 64) | std.math.maxInt(u64), id_ranges[0].end);
}
